@testable import CairnServices
import Foundation
@testable import MeshCore
import Testing

@Suite("NeighbourService")
struct NeighbourServiceTests {
  // MARK: - Fixtures

  /// A clock the test moves by hand.
  private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date()) {
      self.date = date
    }

    var now: Date {
      lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
      lock.withLock { date += seconds }
    }
  }

  /// A repeater whose key starts with 0x3A, so a 1-byte path hash names it, and whose adverts
  /// verify. The radio's own key is all 0x01.
  private static let repeaterSigner = ClaremontStockFixtures.signer(startingWith: 0x3A)
  private static var repeaterKey: Data { repeaterSigner.publicKey.rawRepresentation }
  private static let otherKey = Data([0x5C] + [UInt8](repeating: 0x42, count: 31))
  /// What the radio reports: its key and its channel (915 MHz, 250 kHz, SF10).
  private static let selfInfo = SelfInfo.testSelfInfo(publicKey: Data(repeating: 0x01, count: 32))
  private static let channel = RadioChannelConfig(selfInfo: selfInfo)!

  private struct Harness {
    let radioID: UUID
    let store: PersistenceStore
    let session: MeshCoreSession
    let clock: FakeClock
    let service: NeighbourService
  }

  private func makeHarness(
    radioID: UUID = UUID(),
    store: PersistenceStore? = nil,
    clock: FakeClock = FakeClock(),
    ownTraceTags: Set<UInt32> = []
  ) async throws -> Harness {
    let dataStore = if let store { store } else { try await PersistenceStore.createTestDataStore(radioID: radioID) }
    let session = MeshCoreSession(transport: MockTransport())
    // The radio has reported its channel, so every frame is stamped with it
    await session.installSelfInfoForTest(Self.selfInfo)
    await session.noteChannelConfig(from: Self.selfInfo)
    let service = NeighbourService(
      session: session,
      dataStore: dataStore,
      isOwnTrace: { ownTraceTags.contains($0) },
      now: { clock.now },
      flushInterval: .seconds(3600),
      updateInterval: .milliseconds(20)
    )
    return Harness(radioID: radioID, store: dataStore, session: session, clock: clock, service: service)
  }

  /// A flood text message whose path is `path`, `hashSize` bytes per hop, stamped with the
  /// radio's channel.
  private static func flood(path: [UInt8], hashSize: Int = 1, snr: Double, packet: Int) -> ParsedRxLogData {
    let payload = Data([0x10, 0x20]) + withUnsafeBytes(of: UInt32(packet).littleEndian) { Data($0) }
    var parsed = ParsedRxLogData(
      snr: snr,
      rssi: -100,
      rawPayload: payload,
      routeType: .flood,
      payloadType: .textMessage,
      payloadVersion: 0,
      payloadTypeBits: PayloadType.textMessage.rawValue,
      transportCode: nil,
      pathLength: UInt8((hashSize - 1) << 6) | UInt8(path.count / hashSize),
      pathNodes: path,
      packetPayload: payload
    )
    parsed.channel = channel
    return parsed
  }

  /// The repeater's signed flood advert as "Hilltop", heard over `path` (0-hop when empty).
  private static func advert(snr: Double, path: [UInt8] = []) -> ParsedRxLogData {
    StockCompanionFrames.parsed(
      StockCompanionFrames.signedAdvert(name: "Hilltop", key: repeaterSigner, path: path),
      snr: snr,
      channel: channel
    )
  }

  /// A 1-hop trace to 0x3A7F that came back: heard there at 4.25 dB, back here at -2.5 dB.
  private static func trace(tag: UInt32) -> TraceInfo {
    TraceInfo(tag: tag, authCode: 0, flags: 1, pathLength: 2, path: [
      TraceNode(hashBytes: Data([0x3A, 0x7F]), snr: 4.25),
      TraceNode(hashBytes: nil, snr: -2.5),
    ])
  }

  private static func reply(key: Data, tag: UInt32, snr: Double = 6) -> DiscoverResponse {
    DiscoverResponse(
      nodeType: 2,
      snrIn: -2.5,
      snr: snr,
      rssi: -95,
      pathLength: 0,
      tag: withUnsafeBytes(of: tag.littleEndian) { Data($0) },
      publicKey: key
    )
  }

  private func waitForSnapshot(
    _ harness: Harness,
    _ message: String,
    until condition: @escaping @Sendable (NeighbourSnapshot) -> Bool
  ) async throws -> NeighbourSnapshot {
    let service = harness.service
    let radioID = harness.radioID
    try await waitUntil(timeout: .seconds(5), message) {
      guard let snapshot = await service.snapshot(radioID: radioID) else { return false }
      return condition(snapshot)
    }
    return try #require(await service.snapshot(radioID: radioID))
  }

  // MARK: - Live Evidence

  @Test
  func `injected flood frames build the expected neighbours and SNR`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()

    // 0xBB relays twice; a 2-byte hop names the repeater whose advert arrives next
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xAA, 0xBB], snr: 5, packet: 1)))
    // Evidence is stamped when it is handled, so let the first relay land before time moves on
    _ = try await waitForSnapshot(harness, "the first relay") { !$0.neighbours.isEmpty }
    harness.clock.advance(6)
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xAA, 0xBB], snr: 7, packet: 2)))
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0x3A], snr: 3, packet: 3)))
    await harness.session.dispatchForTesting(.rxLogData(Self.advert(snr: 4)))

    let snapshot = try await waitForSnapshot(harness, "rows from the frames") { snapshot in
      snapshot.neighbours.count == 2 && snapshot.neighbours.map(\.record.heardCount).reduce(0, +) == 4
    }

    let relay = try #require(snapshot.neighbours.first { $0.identities == [.hash(Data([0xBB]))] })
    #expect(relay.resolution == .unknown(Data([0xBB])))
    #expect(relay.record.heardCount == 2)
    #expect(relay.record.lastSNR == 7)
    #expect(relay.record.bestSNR == 7)
    #expect(relay.record.snrEWMA == 5.5)
    #expect(relay.record.isConfirmed)

    let repeater = try #require(snapshot.neighbours.first { $0.resolution.entry?.publicKey == Self.repeaterKey })
    #expect(Set(repeater.identities) == [.fullKey(Self.repeaterKey), .hash(Data([0x3A]))])
    #expect(repeater.record.name == "Hilltop")
    #expect(repeater.record.sources[.advert]?.count == 1)
    #expect(repeater.record.sources[.relay]?.count == 1)
    #expect(snapshot.isWarm)
    await harness.service.stop()
  }

  @Test
  func `updates deliver a snapshot after evidence arrives`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()
    let updates = await harness.service.updates()

    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xBB], snr: 5, packet: 1)))

    var received: NeighbourSnapshot?
    for await snapshot in updates where !snapshot.neighbours.isEmpty {
      received = snapshot
      break
    }
    #expect(received?.neighbours.first?.identities == [.hash(Data([0xBB]))])
    await harness.service.stop()
  }

  @Test
  func `a 2000-event burst is delivered without a drop`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)

    // Sent while the bootstrap may still be running: the subscription holds them
    for packet in 0..<2000 {
      let hop = UInt8(0x10 + packet % 16)
      await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [hop], snr: 4, packet: packet)))
    }

    let snapshot = try await waitForSnapshot(harness, "all 2000 receptions counted") { snapshot in
      snapshot.neighbours.map(\.record.heardCount).reduce(0, +) == 2000
    }
    #expect(snapshot.neighbours.count == 16)
    #expect(await harness.service.deliveryDrops() == 0)
    #expect(await harness.session.eventDropCount(label: NeighbourService.subscriptionLabel) == 0)
    await harness.service.stop()
  }

  // MARK: - Probes

  @Test
  func `a reply to our probe is marked as answering our scan`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()

    let tag: UInt32 = 0x0102_0304
    let probeAt = harness.clock.now
    await harness.service.noteProbe(tag: tag, filter: 0x04, at: probeAt)
    harness.clock.advance(1)
    await harness.session.dispatchForTesting(.discoverResponse(Self.reply(key: Self.repeaterKey, tag: tag)))
    await harness.session.dispatchForTesting(.discoverResponse(Self.reply(key: Self.otherKey, tag: 0xDEAD_BEEF)))

    let snapshot = try await waitForSnapshot(harness, "both replies") { $0.neighbours.count == 2 }
    #expect(snapshot.lastProbe == NeighbourProbe(tag: tag, filter: 0x04, sentAt: probeAt))

    let ours = try #require(snapshot.neighbours.first { $0.resolution.entry?.publicKey == Self.repeaterKey })
    #expect(snapshot.answeredLastProbe(ours))
    #expect(ours.record.sources[.replyToUs]?.count == 1)
    #expect(ours.record.uplinkSNR == -2.5)
    #expect(ours.record.hearsYouAt != nil)

    let theirs = try #require(snapshot.neighbours.first { $0.resolution.entry?.publicKey == Self.otherKey })
    #expect(!snapshot.answeredLastProbe(theirs))
    #expect(theirs.record.sources[.replyToOthers]?.count == 1)
    #expect(theirs.record.uplinkSNR == nil)
    #expect(snapshot.answeredLastProbeCount == 1)
    await harness.service.stop()
  }

  @Test
  func `only our own trace says a neighbour hears us; another's is a relay reception`() async throws {
    let harness = try await makeHarness(ownTraceTags: [77])
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()

    // someone else's 1-hop trace to the same repeater, whose last retransmission we heard
    await harness.session.dispatchForTesting(.traceData(Self.trace(tag: 5)))
    var snapshot = try await waitForSnapshot(harness, "the relay reception") { !$0.neighbours.isEmpty }
    var row = try #require(snapshot.neighbours.first)
    #expect(row.record.sources[.relay]?.count == 1)
    #expect(row.record.sources[.trace] == nil)
    #expect(row.record.uplinkSNR == nil)
    #expect(row.record.hearsYouAt == nil)
    #expect(row.record.lastSNR == -2.5)

    harness.clock.advance(10)
    await harness.session.dispatchForTesting(.traceData(Self.trace(tag: 77)))
    snapshot = try await waitForSnapshot(harness, "our trace") { $0.neighbours.first?.record.sources[.trace] != nil }
    row = try #require(snapshot.neighbours.first)
    #expect(row.record.uplinkSNR == 4.25)
    #expect(row.record.hearsYouAt != nil)
    await harness.service.stop()
  }

  @Test
  func `a record the radio held is not placed where the phone is now`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()
    await harness.service.updateLocationFix(NeighbourFix(
      latitude: 45, longitude: -122, horizontalAccuracy: 10, timestamp: harness.clock.now
    ))

    // a resume's backlog, heard ten minutes ago somewhere else on the drive
    let held = Self.flood(path: [0xBB], snr: 5, packet: 1)
      .withRxSync(seq: 4, epoch: 7, radioAge: .seconds(600), isBackfill: true)
    await harness.session.dispatchForTesting(.rxLogData(held))
    // a record that waited only moments behind a busy link is heard here
    let fresh = Self.flood(path: [0xCC], snr: 5, packet: 2)
      .withRxSync(seq: 5, epoch: 7, radioAge: .seconds(1), isBackfill: false)
    await harness.session.dispatchForTesting(.rxLogData(fresh))

    let snapshot = try await waitForSnapshot(harness, "both rows") { $0.neighbours.count == 2 }
    let heldRow = try #require(snapshot.neighbours.first { $0.identities == [.hash(Data([0xBB]))] })
    let freshRow = try #require(snapshot.neighbours.first { $0.identities == [.hash(Data([0xCC]))] })
    #expect(heldRow.record.heardFrom == nil)
    #expect(freshRow.record.heardFrom != nil)
    await harness.service.stop()
  }

  @Test
  func `an advert that came over hops names the key its hash resolves to`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()

    // a hop no observed node starts with
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0x3A], snr: 4, packet: 1)))
    _ = try await waitForSnapshot(harness, "the unresolved relay") {
      $0.neighbours.first?.resolution == .unknown(Data([0x3A]))
    }
    // the repeater's signed advert, relayed twice before it reached us: not a neighbour, but an
    // observation of its key
    await harness.session.dispatchForTesting(.rxLogData(Self.advert(snr: 2, path: [0xAA, 0xBB])))

    let snapshot = try await waitForSnapshot(harness, "the hash resolved, with no store read") { snapshot in
      snapshot.neighbours.contains { $0.resolution.entry?.publicKey == Self.repeaterKey }
    }
    #expect(!snapshot.neighbours.contains { $0.identities.contains(.fullKey(Self.repeaterKey)) },
            "an advert over hops is no neighbour evidence for its sender")
    await harness.service.stop()
  }

  @Test
  func `a stored RX_SYNC record sent again by a resume counts once`() async throws {
    let harness = try await makeHarness()
    let parsed = Self.flood(path: [0xBB], snr: 5, packet: 9).withRxSync(seq: 41, epoch: 7, radioAge: nil, isBackfill: false)
    try await harness.store.saveRxLogEntry(
      RxLogEntryDTO(radioID: harness.radioID, receivedAt: harness.clock.now.addingTimeInterval(-60), from: parsed)
    )
    try await harness.store.flushPendingRxLogEntries()

    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()
    // the resume sends 41 again, then 42 is new
    await harness.session.dispatchForTesting(.rxLogData(parsed.withRxSync(seq: 41, epoch: 7, radioAge: .seconds(60), isBackfill: true)))
    harness.clock.advance(5)
    let next = Self.flood(path: [0xBB], snr: 6, packet: 10).withRxSync(seq: 42, epoch: 7, radioAge: nil, isBackfill: false)
    await harness.session.dispatchForTesting(.rxLogData(next))

    let snapshot = try await waitForSnapshot(harness, "the new record") { $0.neighbours.first?.record.lastSNR == 6 }
    #expect(snapshot.neighbours.first?.record.heardCount == 2)
    await harness.service.stop()
  }

  /// Epoch 0 names no journal: records the session delivered without a SUBSCRIBE reply. The radio
  /// numbers from 1 every boot, so a stored epoch-0 seq is no position; a new boot's record with
  /// the same seq is a new reception, not a resume repeat.
  @Test
  func `an epoch-0 record from a new radio boot is not taken for a stored one`() async throws {
    let harness = try await makeHarness()
    let old = Self.flood(path: [0xBB], snr: 5, packet: 9).withRxSync(seq: 1, epoch: 0, radioAge: nil, isBackfill: false)
    try await harness.store.saveRxLogEntry(
      RxLogEntryDTO(radioID: harness.radioID, receivedAt: harness.clock.now.addingTimeInterval(-60), from: old)
    )
    try await harness.store.flushPendingRxLogEntries()

    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()
    harness.clock.advance(5)
    let fresh = Self.flood(path: [0xBB], snr: 6, packet: 10).withRxSync(seq: 1, epoch: 0, radioAge: nil, isBackfill: false)
    await harness.session.dispatchForTesting(.rxLogData(fresh))

    let snapshot = try await waitForSnapshot(harness, "the new boot's record") { $0.neighbours.first?.record.lastSNR == 6 }
    #expect(snapshot.neighbours.first?.record.heardCount == 2)
    await harness.service.stop()
  }

  // MARK: - Bootstrap

  @Test
  func `bootstrap from 1000 stored entries finishes in under 200 ms`() async throws {
    let harness = try await makeHarness()
    let base = harness.clock.now.addingTimeInterval(-3600)
    for packet in 0..<1000 {
      let hop = UInt8(0x40 + packet % 50)
      let entry = RxLogEntryDTO(
        radioID: harness.radioID,
        receivedAt: base.addingTimeInterval(TimeInterval(packet)),
        from: Self.flood(path: [hop], snr: 2, packet: packet)
      )
      try await harness.store.saveRxLogEntry(entry)
    }
    try await harness.store.flushPendingRxLogEntries()

    let started = ContinuousClock.now
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()
    let elapsed = ContinuousClock.now - started

    let snapshot = try #require(await harness.service.snapshot(radioID: harness.radioID))
    #expect(snapshot.neighbours.count == 50)
    #expect(snapshot.neighbours.map(\.record.heardCount).reduce(0, +) == 1000)
    #expect(elapsed < .milliseconds(200), "bootstrap took \(elapsed)")
    await harness.service.stop()
  }

  @Test
  func `a replayed packet still waiting in the subscription counts once`() async throws {
    let harness = try await makeHarness()
    let parsed = Self.flood(path: [0xBB], snr: 5, packet: 9)
    try await harness.store.saveRxLogEntry(RxLogEntryDTO(radioID: harness.radioID, receivedAt: harness.clock.now, from: parsed))
    try await harness.store.flushPendingRxLogEntries()

    await harness.service.start(radioID: harness.radioID)
    // The same reception reaches the subscription as the RX log saved it, drained later than the
    // table's own 3 s dedup window
    harness.clock.advance(5)
    await harness.session.dispatchForTesting(.rxLogData(parsed))
    harness.clock.advance(5)
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xBB], snr: 5, packet: 10)))

    let snapshot = try await waitForSnapshot(harness, "the later packet") { snapshot in
      snapshot.neighbours.first?.record.lastHeard == harness.clock.now
    }
    #expect(snapshot.neighbours.first?.record.heardCount == 2)
    await harness.service.stop()
  }

  @Test
  func `an overheard discover request is replayed to a late subscriber`() async throws {
    let harness = try await makeHarness()
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()

    let request = Data([0x80, 0x04, 0x01, 0x02, 0x03, 0x04])
    var parsed = ParsedRxLogData(
      snr: 3, rssi: -100, rawPayload: request, routeType: .direct, payloadType: .control,
      payloadVersion: 0, payloadTypeBits: PayloadType.control.rawValue, transportCode: nil,
      pathLength: 0, pathNodes: [], packetPayload: request
    )
    parsed.channel = Self.channel
    let heardAt = harness.clock.now
    await harness.session.dispatchForTesting(.rxLogData(parsed))
    await harness.session.dispatchForTesting(.rxLogData(parsed))
    // Events are handled in order: once this relay is counted, both copies of the request were
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xBB], snr: 5, packet: 1)))
    _ = try await waitForSnapshot(harness, "the relay after the request") { !$0.neighbours.isEmpty }

    harness.clock.advance(30)
    let requests = await harness.service.overheardRequests()
    var iterator = requests.makeAsyncIterator()
    #expect(await iterator.next() == heardAt)
    await harness.service.finishStreams()
    #expect(await iterator.next() == nil)
    await harness.service.stop()
  }

  // MARK: - Persistence

  @Test
  func `state survives stop, a new instance and reload`() async throws {
    let first = try await makeHarness()
    await first.service.start(radioID: first.radioID)
    await first.service.waitUntilWarm()
    await first.session.dispatchForTesting(.rxLogData(Self.advert(snr: 4)))
    await first.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xBB], snr: 5, packet: 1)))
    let before = try await waitForSnapshot(first, "two rows") { $0.neighbours.count == 2 }
    await first.service.stop()
    #expect(await first.service.snapshot(radioID: first.radioID) == nil)

    let second = try await makeHarness(radioID: first.radioID, store: first.store, clock: first.clock)
    await second.service.start(radioID: second.radioID)
    await second.service.waitUntilWarm()
    let after = try #require(await second.service.snapshot(radioID: second.radioID))

    let byIdentity: (NeighbourSnapshot) -> [Data: NeighbourRecord] = { snapshot in
      Dictionary(uniqueKeysWithValues: snapshot.neighbours.map { ($0.record.identity.bytes, $0.record) })
    }
    #expect(byIdentity(after) == byIdentity(before))
    #expect(after.neighbours.first { $0.resolution.entry?.publicKey == Self.repeaterKey }?.record.name == "Hilltop")
    await second.service.stop()
  }

  @Test
  func `a restart doesn't count the replayed log twice`() async throws {
    let harness = try await makeHarness()
    let base = harness.clock.now.addingTimeInterval(-600)
    for packet in 0..<10 {
      let entry = RxLogEntryDTO(
        radioID: harness.radioID,
        receivedAt: base.addingTimeInterval(TimeInterval(packet * 10)),
        from: Self.flood(path: [0xBB], snr: 5, packet: packet)
      )
      try await harness.store.saveRxLogEntry(entry)
    }
    try await harness.store.flushPendingRxLogEntries()

    for _ in 0..<2 {
      await harness.service.start(radioID: harness.radioID)
      await harness.service.waitUntilWarm()
      let snapshot = try #require(await harness.service.snapshot(radioID: harness.radioID))
      #expect(snapshot.neighbours.first?.record.heardCount == 10)
      await harness.service.stop()
    }
  }

  @Test
  func `radios stay isolated`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let harness = try await makeHarness(radioID: radioA)
    try await harness.store.saveRxLogEntry(RxLogEntryDTO(
      radioID: radioA,
      receivedAt: harness.clock.now.addingTimeInterval(-60),
      from: Self.flood(path: [0xCC], snr: 5, packet: 1)
    ))
    try await harness.store.flushPendingRxLogEntries()

    await harness.service.start(radioID: radioA)
    await harness.service.waitUntilWarm()
    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xBB], snr: 5, packet: 2)))
    _ = try await waitForSnapshot(harness, "radio A's rows") { $0.neighbours.count == 2 }

    // Switching radios flushes A and starts B empty
    await harness.service.start(radioID: radioB)
    await harness.service.waitUntilWarm()
    #expect(await harness.service.snapshot(radioID: radioA) == nil)
    #expect(try #require(await harness.service.snapshot(radioID: radioB)).neighbours.isEmpty)
    #expect(try await harness.store.fetchNeighbourRecords(radioID: radioB, channelKey: Self.channel.key).isEmpty)
    #expect(try await harness.store.fetchNeighbourRecords(radioID: radioA, channelKey: Self.channel.key).count == 2)

    await harness.session.dispatchForTesting(.rxLogData(Self.flood(path: [0xDD], snr: 5, packet: 3)))
    let snapshotB = try await waitForSnapshot(
      Harness(radioID: radioB, store: harness.store, session: harness.session, clock: harness.clock, service: harness.service),
      "radio B's row"
    ) { !$0.neighbours.isEmpty }
    #expect(snapshotB.neighbours.map(\.identities) == [[.hash(Data([0xDD]))]])
    await harness.service.stop()
    #expect(try await harness.store.fetchNeighbourRecords(radioID: radioA, channelKey: Self.channel.key).count == 2)
    #expect(try await harness.store.fetchNeighbourRecords(radioID: radioB, channelKey: Self.channel.key).map(\.identity) == [.hash(Data([0xDD]))])
  }

  // MARK: - Batches

  @Test
  func `a newer batch wins where two batches touch the same row`() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let a = NeighbourRecord(identity: .hash(Data([0x01])), firstHeard: t0, lastHeard: t0, heardCount: 1)
    var aNewer = a
    aNewer.heardCount = 2
    let b = NeighbourRecord(identity: .hash(Data([0x02])), firstHeard: t0, lastHeard: t0, heardCount: 1)
    let older = NeighbourTable.Changes(upserted: [a, b], removed: [.hash(Data([0x03]))])
    let newer = NeighbourTable.Changes(upserted: [aNewer, NeighbourRecord(identity: .hash(Data([0x03])), firstHeard: t0, lastHeard: t0)],
                                       removed: [.hash(Data([0x02]))])

    let combined = NeighbourService.combine(older: older, newer: newer)
    #expect(Set(combined.upserted.map(\.identity)) == [.hash(Data([0x01])), .hash(Data([0x03]))])
    #expect(combined.upserted.first { $0.identity == .hash(Data([0x01])) }?.heardCount == 2)
    #expect(combined.removed == [.hash(Data([0x02]))])
  }
}
