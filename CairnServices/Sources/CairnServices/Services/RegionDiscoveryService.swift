import Foundation
import MeshCore

/// Discovers and tracks *firmware-mesh regions* — named flood-routing scopes
/// advertised by repeaters via `DISCOVER_REQ` / 0x04 filter.
///
/// Vocabulary note: `RegionalAreas` and `RegionResolver` (introduced in the
/// onboarding redesign) use "region" to mean *user geographic location*. These
/// two concepts share a word but no semantic overlap.
public enum RegionDiscoveryService {
  /// Filter value for DISCOVER_REQ that requests only repeaters.
  /// Mirrors `NodeDiscoveryFilter.repeaters.filterValue` in the app target.
  public static let repeatersFilter: UInt8 = 0x04

  /// How long to listen for DISCOVER_RESP before closing the event stream: the longest
  /// window Scan for Nodes listens for (`DiscoverListenWindow.maximum`), so replies from
  /// repeaters that widen their answer window with neighbour density still land.
  public static let listenDuration: Duration = .seconds(DiscoverListenWindow.maximum)

  /// The name region discovery holds the session's optional traffic under.
  static let trafficHoldOwner = "regionDiscovery"

  /// Firmware error code for "contact table full" responses (`ERR_CODE_TABLE_FULL`).
  private static let tableFullErrorCode: UInt8 = 3

  public enum Outcome: Sendable {
    /// The DISCOVER_REQ itself failed to send.
    case sendFailed
    /// The shared `DiscoverRequestGate` refused the probe, so nothing was sent; it is allowed
    /// again at `until`.
    case coolingDown(until: Date, reason: DiscoverRequestGate.Reason)
    /// The radio's firmware has no discover command (official companion firmware before v1.10,
    /// or a radio that answered it with `ERR_CODE_UNSUPPORTED_CMD`), so nothing went on air and
    /// the gate was not spent. The caller can fall back to `queryRegions` with the repeaters it
    /// already knows are nearby.
    case discoverUnsupported
    /// No repeaters responded to the probe, or no query targets could be built.
    case noRepeatersResponded
    /// Could not load the contact pool used to route region queries.
    case errorLoadingRepeaters
    /// Discovery completed. `newRegions` is filtered against the caller's
    /// `knownRegions` and sorted. `allRepeatersTableFull` is `true` when every
    /// successful query returned `ERR_CODE_TABLE_FULL` from the repeater.
    case completed(newRegions: [String], allRepeatersTableFull: Bool)
  }

  /// Runs the discovery probe and aggregates regions from all responders.
  ///
  /// - Parameters:
  ///   - session: Active mesh session for the connected device.
  ///   - contactService: Source of the caller's existing contacts; used to find
  ///     routing data for repeaters the user has already added.
  ///   - dataStore: Optional offline data store; when provided, responders that
  ///     aren't contacts are matched against the discovered-nodes table.
  ///   - radioID: Radio identifier used to scope contact and discovered-node lookups.
  ///   - knownRegions: Regions the caller already knows about; subtracted from the result.
  ///   - supportsAdHocRequest: Whether the radio can query a repeater that isn't a
  ///     contact (firmware v1.16+, `DeviceDTO.supportsAdHocRepeaterRequest`). When
  ///     `false`, only responders the user has already added as contacts are queried;
  ///     anonymous requests to non-contact keys would be rejected by the local radio.
  ///   - supportsDiscoverRequest: Whether the radio's firmware has the discover command
  ///     (companion v1.10+, `DeviceDTO.supportsNodeDiscover`). When `false`, nothing is sent,
  ///     the gate is not asked and the outcome is `.discoverUnsupported`.
  ///   - gate: The process-wide discover gate. When it refuses, nothing is sent and the
  ///     outcome is `.coolingDown`; the caller can fall back to `queryRegions` with the
  ///     repeaters it already knows are nearby.
  ///   - noteProbe: Called with the probe's tag, filter and time before it is sent: the
  ///     neighbour table counts replies carrying the tag as answers to our own scan (and their
  ///     uplink SNR as ours) instead of as answers to someone else's.
  ///   - recorded: Called once the gate has recorded the request, so open scan screens show the
  ///     cooldown it started at once.
  public static func discover(
    session: MeshCoreSession,
    contactService: ContactService,
    dataStore: PersistenceStore?,
    radioID: UUID,
    knownRegions: [String],
    supportsAdHocRequest: Bool,
    supportsDiscoverRequest: Bool,
    gate: DiscoverRequestGate,
    noteProbe: @escaping @Sendable (_ tag: UInt32, _ filter: UInt8, _ at: Date) async -> Void = { _, _, _ in },
    recorded: @escaping @Sendable () async -> Void = {}
  ) async -> Outcome {
    guard supportsDiscoverRequest else { return .discoverUnsupported }

    let probe = DiscoverProbe(
      subscribe: {
        await session.events(filter: .eventType { event in
          switch event {
          case .discoverResponse:
            true
          case let .rxLogData(packet):
            // Only the shape a discover reply's own copy can have, so RX bursts don't fill the
            // buffer
            isZeroHopDirectControl(packet)
          default:
            false
          }
        })
      },
      send: { tag in
        _ = try await session.sendNodeDiscoverRequest(
          filter: repeatersFilter,
          prefixOnly: false,
          tag: tag
        )
      },
      hold: { duration in await session.holdBackgroundTraffic(for: duration, owner: trafficHoldOwner) },
      release: { await session.releaseBackgroundTraffic(owner: trafficHoldOwner) },
      noteProbe: { tag, date in await noteProbe(tag, repeatersFilter, date) },
      recorded: recorded
    )

    let discoveredPubkeys: Set<Data>
    switch await respondingRepeaters(probe: probe, gate: gate, listenFor: listenDuration) {
    case let .coolingDown(until, reason):
      return .coolingDown(until: until, reason: reason)
    case .sendFailed:
      return .sendFailed
    case .unsupported:
      return .discoverUnsupported
    case let .responders(keys):
      discoveredPubkeys = keys
    }

    guard !Task.isCancelled else { return .sendFailed }

    return await queryRegions(
      responders: discoveredPubkeys,
      session: session,
      contactService: contactService,
      dataStore: dataStore,
      radioID: radioID,
      knownRegions: knownRegions,
      supportsAdHocRequest: supportsAdHocRequest
    )
  }

  /// Asks each of `responders` (full public keys) for its regions and aggregates them, without
  /// sending a discover request. `discover` runs it on the repeaters that answered its probe;
  /// while the gate is cooling down, callers run it on the repeaters already heard nearby.
  /// Parameters as for `discover`.
  public static func queryRegions(
    responders: Set<Data>,
    session: MeshCoreSession,
    contactService: ContactService,
    dataStore: PersistenceStore?,
    radioID: UUID,
    knownRegions: [String],
    supportsAdHocRequest: Bool
  ) async -> Outcome {
    if responders.isEmpty {
      return .noRepeatersResponded
    }

    let queryTargets: [MeshContact]
    do {
      let contacts = try await contactService.getContacts(radioID: radioID)
      let discoveredNodes = await (try? dataStore?.fetchDiscoveredNodes(radioID: radioID)) ?? []
      queryTargets = buildRegionQueryTargets(
        responders: responders,
        contacts: contacts,
        discoveredNodes: discoveredNodes,
        supportsAdHocRequest: supportsAdHocRequest
      )
    } catch {
      return .errorLoadingRepeaters
    }

    if queryTargets.isEmpty {
      return .noRepeatersResponded
    }

    var allRegions = Set<String>()
    var anyTableFull = false

    await withTaskGroup(of: RegionQueryOutcome.self) { group in
      for meshContact in queryTargets {
        guard !Task.isCancelled else { break }
        group.addTask {
          do {
            let regions = try await session.requestRegions(from: meshContact)
            return .regions(regions)
          } catch let MeshCoreError.deviceError(code) where code == tableFullErrorCode {
            return .tableFull
          } catch {
            return .otherFailure
          }
        }
      }
      for await outcome in group {
        switch outcome {
        case let .regions(regions):
          allRegions.formUnion(regions)
        case .tableFull:
          anyTableFull = true
        case .otherFailure:
          break
        }
      }
    }

    let knownSet = Set(knownRegions)
    let newRegions = allRegions.subtracting(knownSet).sorted()
    return .completed(newRegions: newRegions, allRepeatersTableFull: anyTableFull)
  }

  // MARK: - Probe

  /// The session calls a probe makes, separated so the order can be tested without a radio,
  /// and who hears about it.
  struct DiscoverProbe: Sendable {
    /// Opens a subscription that receives every `.discoverResponse` (0x8E) and the RX log copy
    /// (0x88) of every zero-hop direct CONTROL packet, the shape of a discover reply.
    let subscribe: @Sendable () async -> AsyncStream<MeshEvent>
    /// Sends one repeaters-only, full-key `NODE_DISCOVER_REQ` carrying `tag`.
    let send: @Sendable (_ tag: UInt32) async throws -> Void
    /// Holds the session's optional traffic (message fetches) for the listen window, so the
    /// replies' frames are not crowded out of a stock radio's small send queue.
    var hold: @Sendable (_ duration: Duration) async -> Void = { _ in }
    /// Ends the hold: the send failed or the listen ended (or was cancelled), so no replies
    /// are coming.
    var release: @Sendable () async -> Void = {}
    /// Hands the tag to the neighbour table before the send, as Scan for Nodes does.
    var noteProbe: @Sendable (_ tag: UInt32, _ at: Date) async -> Void = { _, _ in }
    /// The gate recorded the request (sent, or failed after it may have gone on air).
    var recorded: @Sendable () async -> Void = {}
  }

  enum ProbeResult: Sendable, Equatable {
    case coolingDown(until: Date, reason: DiscoverRequestGate.Reason)
    case sendFailed
    /// The radio answered the send with `ERR_CODE_UNSUPPORTED_CMD`: nothing went on air, and
    /// the gate's reservation was given back.
    case unsupported
    case responders(Set<Data>)
  }

  /// Whether `packet` has the shape of a discover reply: a zero-hop direct CONTROL packet.
  static func isZeroHopDirectControl(_ packet: ParsedRxLogData) -> Bool {
    packet.payloadType == .control && !packet.routeType.isFlood
      && decodePathLen(packet.pathLength)?.hopCount == 0
  }

  /// The full key of the repeater whose discover reply to `tag` this received packet is, if it
  /// is one. Official firmware pushes every reply twice: its RX log copy (0x88) first, then the
  /// CONTROL_DATA push (0x8E), through the same queue that drops a frame when it is full, so
  /// the later 0x8E is the one a burst of replies loses (companion-v1.18.0 src/Dispatcher.cpp
  /// checkRecv, examples/companion_radio/MyMesh.cpp onControlDataRecv). A prefix-only reply
  /// names no key that regions can be asked of.
  static func discoverReplyKey(in packet: ParsedRxLogData, tag: UInt32) -> Data? {
    NeighbourEvidence.extract(RxPacketFields(packet), selfHash: nil)
      .first { $0.source == .discoverReply && $0.tag == tag && $0.identity.isFullKey }?
      .identity.bytes
  }

  /// Asks the gate, then subscribes BEFORE sending, so a reply that lands while the send is still
  /// being acknowledged is already buffered for the listener (subscribing after the send lost the
  /// fastest replies). The tag is chosen here so the listener can match replies before the send
  /// returns. Collects the full keys of the repeaters that answered this tag within `listenFor`,
  /// from either copy of each reply, so a reply whose 0x8E push the radio dropped still counts.
  static func respondingRepeaters(
    probe: DiscoverProbe,
    gate: DiscoverRequestGate,
    listenFor: Duration,
    tag: UInt32 = UInt32.random(in: 1...UInt32.max)
  ) async -> ProbeResult {
    if case let .coolingDown(until, reason) = await gate.request() {
      return .coolingDown(until: until, reason: reason)
    }

    let tagData = withUnsafeBytes(of: tag.littleEndian) { Data($0) }
    let events = await probe.subscribe()
    // Ends when cancelled below; replies already buffered are still drained first.
    let listenTask = Task { () -> Set<Data> in
      var keys = Set<Data>()
      for await event in events {
        switch event {
        case let .discoverResponse(response)
          where response.tag == tagData && response.publicKey.count == ProtocolLimits.publicKeySize:
          keys.insert(response.publicKey)
        case let .rxLogData(packet):
          if let key = discoverReplyKey(in: packet, tag: tag) {
            keys.insert(key)
          }
        default:
          break
        }
      }
      return keys
    }

    // The tag is noted first: a close repeater can answer before the send returns
    await probe.noteProbe(tag, Date())
    await probe.hold(listenFor)
    do {
      try await probe.send(tag)
    } catch let MeshCoreError.deviceError(code) where code == FirmwareDeviceErrorCode.unsupportedCommand {
      // Refused before air (companion firmware before v1.10): no repeater spent a token on it
      await probe.release()
      await gate.releaseReservation()
      listenTask.cancel()
      return .unsupported
    } catch {
      await probe.release()
      // A send that timed out may still have gone on air, so it counts against the limiter;
      // recording it also settles the reservation instead of leaving it for the next send.
      await gate.recordOwn()
      await probe.recorded()
      listenTask.cancel()
      return .sendFailed
    }
    await gate.recordOwn()
    await probe.recorded()

    try? await Task.sleep(for: listenFor)
    // Ended or cancelled: either way message fetches go on now
    await probe.release()
    listenTask.cancel()
    return await .responders(listenTask.value)
  }

  /// Builds the `MeshContact` query pool used to fetch regions from each responder.
  /// Prefers contact records (they carry direct routing data when available) and fills
  /// in from the discovered-nodes table for responders the user has not added as contacts.
  ///
  /// Non-contact responders are only included when `supportsAdHocRequest` is `true`:
  /// older firmware rejects an anonymous request to a key it doesn't hold as a contact,
  /// so querying them would only produce spurious failures.
  static func buildRegionQueryTargets(
    responders: Set<Data>,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    supportsAdHocRequest: Bool
  ) -> [MeshContact] {
    var byKey: [Data: MeshContact] = [:]
    for contact in contacts where contact.type == .repeater && responders.contains(contact.publicKey) {
      byKey[contact.publicKey] = contact.toContactFrame().toMeshContact()
    }
    guard supportsAdHocRequest else { return Array(byKey.values) }
    for node in discoveredNodes where node.nodeType == .repeater
      && responders.contains(node.publicKey)
      && byKey[node.publicKey] == nil {
      let frame = ContactFrame(
        publicKey: node.publicKey,
        type: node.nodeType,
        flags: 0,
        outPathLength: node.outPathLength,
        outPath: node.outPath,
        name: node.name,
        lastAdvertTimestamp: node.lastAdvertTimestamp,
        latitude: node.latitude,
        longitude: node.longitude,
        lastModified: 0
      )
      byKey[node.publicKey] = frame.toMeshContact()
    }
    return Array(byKey.values)
  }

  private enum RegionQueryOutcome {
    case regions([String])
    case tableFull
    case otherFailure
  }
}
