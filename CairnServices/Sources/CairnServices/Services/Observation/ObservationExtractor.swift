import Foundation
import MeshCore
import os

// MARK: - Verified Advert

/// An advert whose Ed25519 signature this app checked: the node itself announced this key, type,
/// name and position.
public struct VerifiedAdvert: Sendable, Equatable {
  public let publicKey: Data
  /// The advertiser's clock when it sent the advert.
  public let timestamp: UInt32
  /// 1 chat, 2 repeater, 3 room, 4 sensor; nil when not said.
  public let nodeTypeRaw: UInt8?
  public let name: String?
  /// The advertised position in degrees; nil when it carries none (0,0 means none).
  public let latitude: Double?
  public let longitude: Double?
}

/// What an advert packet's signature shows.
public enum AdvertCheck: Sendable, Equatable {
  /// The signature holds for the key the advert carries.
  case verified(VerifiedAdvert)
  /// The signature fails: the key is only a claim, never an identity.
  case unverified(publicKey: Data)
}

// MARK: - Extractor

/// Reads ``NodeObservation``s out of what this radio received: a stamped 0x88 frame, a stored RX
/// log entry, or one of the radio's own live pushes. Pure, apart from the shared signature cache.
///
/// Only proof counts (see ``ObservationKind``): a signed advert (signature checked here), a 0-hop
/// discover reply, a direct message this app decrypted that its peer sent, the radio's own live
/// decrypt pushes, and the 8-byte hashes of a trace this session sent. The radio's advert pushes
/// are not counted: it sends them for an imported contact too. A 1-3 byte relay
/// hash, an anonymous request's key, a channel message, a queued message, the radio's contact
/// table, a forged or unreadable advert, and anything received on an unknown channel give nothing,
/// and neither does this radio's own key.
public enum ObservationExtractor {
  // MARK: Raw frames

  /// The observations in one received packet.
  ///
  /// - Parameters:
  ///   - fields: The packet.
  ///   - channel: The channel the session stamped on the frame; nil gives nothing.
  ///   - receivedAt: When the radio received it.
  ///   - selfKey: This radio's public key.
  ///   - entryID: The RX log entry it was stored as, if any.
  public static func observations(
    from fields: RxPacketFields,
    channel: RadioChannelConfig?,
    receivedAt: Date,
    selfKey: Data?,
    entryID: UUID? = nil
  ) -> [NodeObservation] {
    guard let channel else { return [] }
    return observations(from: fields, channelKey: channel.key, receivedAt: receivedAt, selfKey: selfKey, entryID: entryID)
  }

  /// The observations in one stored RX log entry: its packet's, and the peer of a direct message
  /// this app decrypted. An entry with no channel stamp gives nothing. Ingesting an entry whose
  /// live frame was already ingested changes nothing.
  public static func observations(from entry: RxLogEntryDTO, selfKey: Data?) -> [NodeObservation] {
    guard let channelKey = entry.channelKey else { return [] }
    var result = observations(
      from: RxPacketFields(entry),
      channelKey: channelKey,
      receivedAt: entry.receivedAt,
      selfKey: selfKey,
      entryID: entry.id
    )
    if let message = decryptedMessageObservation(entry, channelKey: channelKey, selfKey: selfKey) {
      result.append(message)
    }
    return result
  }

  /// Whether an advert packet's signature holds, and what it announces; nil when the packet is
  /// not an advert or is shorter than the radio accepts. Checks are cached by packet hash.
  public static func advertCheck(in fields: RxPacketFields) -> AdvertCheck? {
    guard fields.payloadType == .advert,
          let signed = AdvertPushRecovery.SignedAdvert(payload: fields.packetPayload) else { return nil }
    guard AdvertSignatureCache.shared.isValid(signed, payload: fields.packetPayload, packetHash: fields.packetHash) else {
      return .unverified(publicKey: signed.publicKey)
    }
    let announced = NeighbourEvidence.advertiser(in: fields, selfHash: nil)
    return .verified(VerifiedAdvert(
      publicKey: signed.publicKey,
      timestamp: signed.timestamp,
      nodeTypeRaw: announced?.nodeTypeRaw.flatMap { $0 == 0 ? nil : $0 },
      name: announced?.name,
      latitude: announced?.latitude,
      longitude: announced?.longitude
    ))
  }

  // MARK: Pushes

  /// The observations in one session event.
  ///
  /// A `.rxLogData` frame is read with its own channel stamp. Every other push is a live reply,
  /// so it counts on `channel`, the session's current channel when it is handled; nil (no
  /// channel yet, or a retune not yet confirmed) gives nothing.
  ///
  /// - Parameters:
  ///   - event: The event.
  ///   - channel: The session's current channel.
  ///   - at: When it was handled.
  ///   - selfKey: This radio's public key.
  ///   - isOwnTrace: Whether a trace tag is one this session sent.
  public static func observations(
    from event: MeshEvent,
    channel: RadioChannelConfig?,
    at: Date,
    selfKey: Data?,
    isOwnTrace: (UInt32) -> Bool = { _ in false }
  ) -> [NodeObservation] {
    if case let .rxLogData(parsed) = event {
      return observations(
        from: RxPacketFields(parsed),
        channel: parsed.channel,
        receivedAt: RxLogService.receivedAt(radioAge: parsed.radioAge, now: at),
        selfKey: selfKey
      )
    }
    guard let channelKey = channel?.key else { return [] }

    func observed(
      _ bytes: Data,
      _ kind: ObservationKind,
      hops: Int? = nil,
      snr: Double? = nil,
      rssi: Int? = nil,
      name: String? = nil,
      nodeTypeRaw: UInt8? = nil,
      latitude: Double? = nil,
      longitude: Double? = nil
    ) -> [NodeObservation] {
      guard let identity = ObservedIdentity(bytes: bytes), !identity.isSelf(selfKey) else { return [] }
      return [NodeObservation(
        identity: identity,
        kind: kind,
        channelKey: channelKey,
        at: at,
        hops: hops,
        snr: snr,
        rssi: rssi,
        name: name,
        nodeTypeRaw: nodeTypeRaw.flatMap { $0 == 0 ? nil : $0 },
        latitude: latitude,
        longitude: longitude
      )]
    }

    switch event {
    // The advert pushes (0x80, 0x8A) are not proof of reception: the firmware's
    // CMD_IMPORT_CONTACT loops an imported advert back "as if received over radio", with no
    // 0x88, and pushes it the same way. A real advert always comes with its own 0x88 frame,
    // whose signature this app checks itself.
    case let .pathUpdate(publicKey):
      return observed(publicKey, .radioDecryptedReply)
    case let .loginSuccess(info):
      return observed(info.publicKeyPrefix, .radioDecryptedReply)
    case let .statusResponse(response):
      return observed(response.publicKeyPrefix, .radioDecryptedReply)
    case let .telemetryResponse(response):
      return observed(response.publicKeyPrefix, .radioDecryptedReply)
    case let .pathResponse(info):
      return observed(info.publicKeyPrefix, .radioDecryptedReply)
    case let .discoverResponse(response):
      // A discover reply is sent zero-hop; one that says otherwise names no transmitter
      guard decodePathLen(response.pathLength)?.hopCount == 0 else { return [] }
      return NeighbourEvidence.extract(response, selfHash: selfKey).flatMap { evidence in
        observed(
          evidence.identity.bytes,
          .discoverReply,
          hops: 0,
          snr: evidence.snr,
          rssi: evidence.rssi,
          nodeTypeRaw: evidence.nodeTypeRaw
        )
      }
    case let .traceData(trace):
      return ownTraceObservations(trace, channelKey: channelKey, at: at, selfKey: selfKey, isOwnTrace: isOwnTrace)
    default:
      return []
    }
  }

  // MARK: Rules

  /// A signed advert, or a 0-hop discover reply.
  static func observations(
    from fields: RxPacketFields,
    channelKey: ChannelKey,
    receivedAt: Date,
    selfKey: Data?,
    entryID: UUID?
  ) -> [NodeObservation] {
    guard let hops = PathHops.split(pathNodes: fields.pathNodes, pathLength: fields.pathLength) else { return [] }
    switch fields.payloadType {
    case .advert:
      guard case let .verified(advert)? = advertCheck(in: fields),
            let identity = ObservedIdentity(bytes: advert.publicKey),
            !identity.isSelf(selfKey) else { return [] }
      // A flood's path lists the relays it crossed. A direct packet's path is the route still
      // ahead, so only an empty one (a zero-hop advert) shows the advertiser sent this frame.
      let hopCount: Int? = fields.routeType.isFlood ? hops.count : (hops.isEmpty ? 0 : nil)
      return [NodeObservation(
        identity: identity,
        kind: hopCount == 0 ? .advertDirect : .advertRelayed,
        channelKey: channelKey,
        at: receivedAt,
        hops: hopCount,
        snr: fields.snr,
        rssi: fields.rssi,
        name: advert.name,
        nodeTypeRaw: advert.nodeTypeRaw,
        latitude: advert.latitude,
        longitude: advert.longitude,
        entryID: entryID
      )]
    case .control:
      guard !fields.routeType.isFlood, hops.isEmpty else { return [] }
      return NeighbourEvidence.extract(fields, selfHash: selfKey).compactMap { evidence in
        guard evidence.source == .discoverReply,
              let identity = ObservedIdentity(bytes: evidence.identity.bytes),
              !identity.isSelf(selfKey) else { return nil }
        return NodeObservation(
          identity: identity,
          kind: .discoverReply,
          channelKey: channelKey,
          at: receivedAt,
          hops: 0,
          snr: evidence.snr,
          rssi: evidence.rssi,
          nodeTypeRaw: evidence.nodeTypeRaw.flatMap { $0 == 0 ? nil : $0 },
          entryID: entryID
        )
      }
    default:
      return []
    }
  }

  /// A direct message this app decrypted with a contact's shared secret proves that contact sent
  /// it only when it was addressed from the contact to this radio: `src == peer[0]`,
  /// `dest == self[0]`, and the two bytes differ. An echo of our own message to the contact
  /// decrypts with the same secret, but its sender is us.
  static func decryptedMessageObservation(
    _ entry: RxLogEntryDTO,
    channelKey: ChannelKey,
    selfKey: Data?
  ) -> NodeObservation? {
    let payload = [UInt8](entry.packetPayload)
    guard entry.payloadType == .textMessage, entry.decryptStatus == .success,
          let peer = entry.peerPublicKey, let peerByte = peer.first,
          let selfByte = selfKey?.first, payload.count >= 2,
          let identity = ObservedIdentity(bytes: peer), !identity.isSelf(selfKey),
          payload[1] == peerByte, payload[0] == selfByte, peerByte != selfByte,
          let hops = PathHops.split(pathNodes: entry.pathNodes, pathLength: entry.pathLength) else { return nil }
    return NodeObservation(
      identity: identity,
      kind: .decryptedMessage,
      channelKey: channelKey,
      at: entry.receivedAt,
      // A direct message's path is the route still ahead, which says nothing of the hops taken
      hops: entry.isFlood ? hops.count : nil,
      snr: entry.snr,
      rssi: entry.rssi,
      entryID: entry.id
    )
  }

  /// The 8-byte hashes that answered in a trace this session sent. A shorter hash names no node:
  /// we chose it from a path, so it proves nothing about which key holds it. Only the last hop
  /// sent the frame this radio received (the final entry's SNR), so only it is 0 hops away. The
  /// first hop heard this radio, the reverse direction, which says nothing of whether this radio
  /// hears it; it and the hops between are not counted.
  static func ownTraceObservations(
    _ trace: TraceInfo,
    channelKey: ChannelKey,
    at: Date,
    selfKey: Data?,
    isOwnTrace: (UInt32) -> Bool
  ) -> [NodeObservation] {
    guard isOwnTrace(trace.tag) else { return [] }
    let hashed = trace.path.enumerated().compactMap { index, node in node.hashBytes.map { (index, $0) } }
    guard let lastHashed = hashed.last?.0 else { return [] }
    let receivedSNR: Double? = trace.path.last.flatMap { $0.hashBytes == nil ? $0.snr : nil }
    return hashed.compactMap { index, hash in
      guard hash.count == 8, let identity = ObservedIdentity(bytes: hash), !identity.isSelf(selfKey) else { return nil }
      let isLast = index == lastHashed
      return NodeObservation(
        identity: identity,
        kind: .ownTraceHop,
        channelKey: channelKey,
        at: at,
        hops: isLast ? 0 : nil,
        snr: isLast ? receivedSNR : nil
      )
    }
  }
}

// MARK: - Signature Cache

/// Remembers which advert payloads' signatures held, by packet hash, so resolving the same packet
/// again (a list rebuild, a replay) never verifies it twice. The payload is kept and compared, so
/// a hash that matched another payload is checked afresh. Holds at most ``capacity`` entries,
/// evicting the least recently used.
final class AdvertSignatureCache: Sendable {
  static let shared = AdvertSignatureCache(capacity: 2048)

  private struct Entry {
    let payload: Data
    let isValid: Bool
    var lastUsed: UInt64
  }

  private struct State {
    var entries: [String: Entry] = [:]
    var tick: UInt64 = 0
  }

  let capacity: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  /// How many checks are remembered.
  var count: Int {
    state.withLock { $0.entries.count }
  }

  /// Whether `advert`'s signature holds, from the cache when this payload was checked before.
  func isValid(_ advert: AdvertPushRecovery.SignedAdvert, payload: Data, packetHash: String) -> Bool {
    let cached: Bool? = state.withLock { state in
      state.tick += 1
      guard var entry = state.entries[packetHash], entry.payload == payload else { return nil }
      entry.lastUsed = state.tick
      state.entries[packetHash] = entry
      return entry.isValid
    }
    if let cached {
      return cached
    }
    // Verified outside the lock: it is the slow part, and a race only verifies twice
    let isValid = advert.isSignatureValid
    let capacity = capacity
    state.withLock { state in
      state.tick += 1
      state.entries[packetHash] = Entry(payload: payload, isValid: isValid, lastUsed: state.tick)
      guard state.entries.count > capacity else { return }
      // Evict down to three quarters at once, so a full cache doesn't sort on every insert
      let keep = capacity - capacity / 4
      let oldest = state.entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(state.entries.count - keep)
      for (key, _) in oldest {
        state.entries.removeValue(forKey: key)
      }
    }
    return isValid
  }
}
