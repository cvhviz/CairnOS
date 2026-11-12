@testable import CairnServices
import Foundation
@testable import MeshCore
import SwiftData
import Testing

/// NeighbourService keeps, per radio and channel, the ledger of nodes this radio observed, fed
/// from stock frames and pushes only, and publishes it with the neighbour table.
@Suite("NeighbourService ledger")
struct NeighbourServiceLedgerTests {
  // MARK: - Fixtures

  /// A clock the test moves by hand.
  private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
      lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
      lock.withLock { date += seconds }
    }
  }

  private static let repeaterSigner = ClaremontStockFixtures.signer(startingWith: 0x3A)
  private static var repeaterKey: Data { repeaterSigner.publicKey.rawRepresentation }
  private static let konaHillKey = Data([0x7F, 0x3A] + [UInt8](repeating: 0x71, count: 30))

  /// What the radio reports: its key (0xAA x32) and its channel.
  private static func selfInfo(frequency: Double = 910.525) -> SelfInfo {
    SelfInfo(
      advertisementType: 1,
      txPower: 20,
      maxTxPower: 22,
      publicKey: StockCompanionFrames.selfKey,
      latitude: 0,
      longitude: 0,
      multiAcks: 0,
      advertisementLocationPolicy: 0,
      telemetryModeEnvironment: 0,
      telemetryModeLocation: 0,
      telemetryModeBase: 0,
      manualAddContacts: false,
      radioFrequency: frequency,
      radioBandwidth: 250,
      radioSpreadingFactor: 10,
      radioCodingRate: 5,
      name: "Base"
    )
  }

  private static let channel = RadioChannelConfig(selfInfo: selfInfo())!
  private static let otherChannel = RadioChannelConfig(selfInfo: selfInfo(frequency: 927.875))!

  private struct Harness {
    let radioID: UUID
    let store: PersistenceStore
    let session: MockMeshCoreSession
    let clock: FakeClock
    let service: NeighbourService
    let own: OwnTransmissionService
    let entries: AsyncStream<RxLogEntryDTO>.Continuation
  }

  private func makeHarness(container: ModelContainer? = nil) async throws -> Harness {
    let radioID = UUID()
    let store = try PersistenceStore(modelContainer: container ?? PersistenceStore.createContainer(inMemory: true))
    let session = MockMeshCoreSession()
    await session.setCurrentSelfInfo(Self.selfInfo())
    await session.setCurrentChannelConfig(Self.channel)
    let clock = FakeClock()
    let (stream, continuation) = AsyncStream.makeStream(of: RxLogEntryDTO.self)
    let own = OwnTransmissionService(session: session, now: { clock.now })
    let service = NeighbourService(
      session: session,
      dataStore: store,
      entries: { stream },
      ownTransmissions: own,
      now: { clock.now },
      flushInterval: .seconds(3600),
      updateInterval: .milliseconds(20)
    )
    return Harness(radioID: radioID, store: store, session: session, clock: clock, service: service, own: own, entries: continuation)
  }

  private func start(_ harness: Harness) async {
    await harness.own.start(radioID: harness.radioID)
    await harness.service.start(radioID: harness.radioID)
    await harness.service.waitUntilWarm()
  }

  private func snapshot(
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

  /// The repeater's signed advert as "Hilltop" at a position, heard over `path`.
  private static func advert(path: [UInt8] = [], snr: Double = 7.25, channel: RadioChannelConfig? = channel) -> ParsedRxLogData {
    StockCompanionFrames.parsed(
      StockCompanionFrames.signedAdvert(name: "Hilltop", key: repeaterSigner, lat: 34.1, lon: -117.7, path: path),
      snr: snr,
      rssi: -88,
      channel: channel
    )
  }

  /// A flood channel message relayed by `path` (1-byte hashes).
  private static func relayed(path: [UInt8], variant: UInt8 = 0, channel: RadioChannelConfig? = channel) -> ParsedRxLogData {
    StockCompanionFrames.parsed(
      StockCompanionFrames.packet(
        payloadType: 0x05,
        route: StockCompanionFrames.routeFlood,
        path: path,
        payload: [0x11, 0x22, 0x33, variant] + [UInt8](repeating: 0x5C, count: 16)
      ),
      channel: channel
    )
  }

  private static func meshContact(_ key: Data, name: String) -> MeshContact {
    MeshContact(
      id: name,
      publicKey: key,
      type: .repeater,
      flags: ContactFlags(rawValue: 0),
      outPathLength: 0xFF,
      outPath: Data(),
      advertisedName: name,
      lastAdvertisement: Date(timeIntervalSince1970: 1_800_000_000),
      latitude: 19.6,
      longitude: -155.9,
      lastModified: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  // MARK: - Observations

  @Test
  func `a 0-hop signed advert becomes a ledger node with its link and position, persisted on flush`() async throws {
    let harness = try await makeHarness()
    await start(harness)

    await harness.session.yieldEvent(.rxLogData(Self.advert()))
    let snapshot = try await snapshot(harness, "the advert observed") { $0.ledger.node(for: .fullKey(Self.repeaterKey)) != nil }

    let node = try #require(snapshot.ledger.node(for: .fullKey(Self.repeaterKey)))
    #expect(snapshot.ledger.channelKey == Self.channel.key)
    #expect(node.name == "Hilltop")
    #expect(node.lastDirectSNR == 7.25)
    #expect(node.lastDirectRSSI == -88)
    #expect(node.minHops == 0)
    #expect(try abs(#require(node.latitude) - 34.1) < 1e-5)
    #expect(node.kinds[.advertDirect] != nil)
    #expect(snapshot.neighbours.contains { $0.resolution.entry?.publicKey == Self.repeaterKey })

    await harness.service.flush()
    let stored = try await harness.store.fetchObservedNodes(radioID: harness.radioID, channelKey: Self.channel.key)
    #expect(stored.map(\.identity) == [.fullKey(Self.repeaterKey)])
    await harness.service.stop()
  }

  @Test
  func `neither the radio's advert pushes nor its contact table are observations`() async throws {
    let harness = try await makeHarness()
    await start(harness)
    let synced = Data([0x5C] + [UInt8](repeating: 0x42, count: 31))

    await harness.session.yieldEvent(.contactsStart(count: 1))
    await harness.session.yieldEvent(.contact(Self.meshContact(synced, name: "Synced")))
    await harness.session.yieldEvent(.contactsEnd(lastModified: Date(timeIntervalSince1970: 1_800_000_000)))
    // An imported Hawaii card: the firmware loops it back as if heard and pushes 0x8A and 0x80,
    // with no 0x88 frame
    await harness.session.yieldEvent(.newContact(Self.meshContact(Self.konaHillKey, name: "Kona Hill")))
    await harness.session.yieldEvent(.advertisement(publicKey: Self.konaHillKey))
    // Something heard after them, to know they were handled
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x9E])))

    let snapshot = try await snapshot(harness, "the relay after the pushes") { !$0.neighbours.isEmpty }
    #expect(snapshot.ledger.node(for: .fullKey(Self.konaHillKey)) == nil)
    #expect(snapshot.ledger.node(for: .fullKey(synced)) == nil)
    #expect(snapshot.ledger.nodes.isEmpty)
    await harness.service.stop()
  }

  @Test
  func `a stored row observed only by an advert push is dropped on load`() async throws {
    let harness = try await makeHarness()
    let at = harness.clock.now.addingTimeInterval(-600)
    let pushedOnly = ObservedNode(
      identity: .fullKey(Self.konaHillKey),
      name: "Kona Hill",
      latitude: 19.6,
      longitude: -155.9,
      positionAt: at,
      firstObservedAt: at,
      lastObservedAt: at,
      kinds: [.radioVerifiedAdvert: KindStat(count: 1, lastAt: at)]
    )
    let heard = ObservedNode(
      identity: .fullKey(Self.repeaterKey),
      name: "Hilltop",
      firstObservedAt: at,
      lastObservedAt: at,
      kinds: [.radioVerifiedAdvert: KindStat(count: 1, lastAt: at), .advertRelayed: KindStat(count: 1, lastAt: at)]
    )
    try await harness.store.saveObservedNodes(
      radioID: harness.radioID,
      channelKey: Self.channel.key,
      upserting: [pushedOnly, heard],
      removing: []
    )

    await start(harness)
    let snapshot = try #require(await harness.service.snapshot(radioID: harness.radioID))
    #expect(snapshot.ledger.node(for: .fullKey(Self.konaHillKey)) == nil)
    #expect(snapshot.ledger.node(for: .fullKey(Self.repeaterKey)) != nil)
    await harness.service.flush()
    let stored = try await harness.store.fetchObservedNodes(radioID: harness.radioID, channelKey: Self.channel.key)
    #expect(stored.map(\.identity) == [.fullKey(Self.repeaterKey)])
    await harness.service.stop()
  }

  @Test
  func `a new frequency starts an empty ledger and table; switching back restores both`() async throws {
    let harness = try await makeHarness()
    await start(harness)
    await harness.session.yieldEvent(.rxLogData(Self.advert()))
    _ = try await snapshot(harness, "the advert on the first channel") { !$0.neighbours.isEmpty && !$0.ledger.nodes.isEmpty }

    // The radio retunes and reports its new channel
    await harness.session.setCurrentChannelConfig(Self.otherChannel)
    await harness.session.yieldEvent(.selfInfo(Self.selfInfo(frequency: 927.875)))
    _ = try await snapshot(harness, "the new channel, empty") {
      $0.ledger.channelKey == Self.otherChannel.key && $0.ledger.nodes.isEmpty && $0.neighbours.isEmpty
    }
    // A frame still stamped with the old channel is no evidence here; one on the new channel is
    await harness.session.yieldEvent(.rxLogData(Self.advert(snr: 3, channel: Self.channel)))
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x9E], channel: Self.otherChannel)))
    let other = try await snapshot(harness, "the relay on the new channel") { !$0.neighbours.isEmpty }
    #expect(other.neighbours.map(\.identities) == [[.hash(Data([0x9E]))]])
    #expect(other.ledger.nodes.isEmpty)

    // Back on the first channel, its ledger and table return
    await harness.session.setCurrentChannelConfig(Self.channel)
    await harness.session.yieldEvent(.selfInfo(Self.selfInfo()))
    let back = try await snapshot(harness, "the first channel restored") {
      $0.ledger.channelKey == Self.channel.key && $0.ledger.node(for: .fullKey(Self.repeaterKey)) != nil
    }
    #expect(back.neighbours.contains { $0.resolution.entry?.publicKey == Self.repeaterKey })
    #expect(!back.neighbours.contains { $0.identities.contains(.hash(Data([0x9E]))) })
    #expect(back.ledger.version > other.ledger.version)
    #expect(await harness.service.ledgerSnapshot(channelKey: Self.otherChannel.key)?.channelKey == Self.otherChannel.key)
    await harness.service.stop()
  }

  @Test
  func `while a retune waits for the radio the snapshot is cold`() async throws {
    let harness = try await makeHarness()
    await start(harness)
    await harness.session.yieldEvent(.rxLogData(Self.advert()))
    _ = try await snapshot(harness, "the advert") { !$0.ledger.nodes.isEmpty }

    // A radio-parameters write: the session vouches for no channel, frames arrive unstamped
    await harness.session.setCurrentChannelConfig(nil)
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x9E], channel: nil)))
    let cold = try await snapshot(harness, "cold") { $0.ledger.isCold }
    #expect(cold.neighbours.isEmpty)
    await harness.service.stop()
  }

  @Test
  func `a refused retune restores the channel: the next stamped live frame warms the ledger again`() async throws {
    let harness = try await makeHarness()
    await start(harness)
    await harness.session.yieldEvent(.rxLogData(Self.advert()))
    _ = try await snapshot(harness, "the advert") { !$0.ledger.nodes.isEmpty }

    // A radio-parameters write, a live frame left unstamped during it: cold
    await harness.session.setCurrentChannelConfig(nil)
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x9E], channel: nil)))
    _ = try await snapshot(harness, "cold") { $0.ledger.isCold }

    // The radio answers ERR: the session restores its channel, with no SELF_INFO. The next live
    // frame carries the restored stamp, and the service follows it
    await harness.session.setCurrentChannelConfig(Self.channel)
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x5C], variant: 1)))
    let warm = try await snapshot(harness, "warm again") {
      $0.ledger.channelKey == Self.channel.key && $0.neighbours.contains { $0.identities.contains(.hash(Data([0x5C]))) }
    }
    #expect(warm.ledger.node(for: .fullKey(Self.repeaterKey)) != nil, "the channel's stored observations are back")
    await harness.service.stop()
  }

  @Test
  func `a live frame stamped with a new channel switches the ledger when its SELF_INFO was dropped`() async throws {
    let harness = try await makeHarness()
    await start(harness)
    await harness.session.yieldEvent(.rxLogData(Self.advert()))
    _ = try await snapshot(harness, "the advert") { !$0.ledger.nodes.isEmpty }

    // The radio retuned; its SELF_INFO never reached this subscription
    await harness.session.setCurrentChannelConfig(Self.otherChannel)
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x9E], channel: Self.otherChannel)))
    let other = try await snapshot(harness, "the new channel") {
      $0.ledger.channelKey == Self.otherChannel.key && !$0.neighbours.isEmpty
    }
    #expect(other.neighbours.map(\.identities) == [[.hash(Data([0x9E]))]])
    #expect(other.ledger.nodes.isEmpty)
    await harness.service.stop()
  }

  @Test
  func `an old RX_SYNC record stamped with another channel never switches the ledger`() async throws {
    let harness = try await makeHarness()
    await start(harness)
    await harness.session.yieldEvent(.rxLogData(Self.advert()))
    _ = try await snapshot(harness, "the advert") { !$0.ledger.nodes.isEmpty }

    // Held by the radio for ten minutes, heard on the channel it was on then
    let backlog = Self.relayed(path: [0x9E], channel: Self.otherChannel)
      .withRxSync(seq: 1, epoch: 7, radioAge: .seconds(600), isBackfill: false)
    await harness.session.yieldEvent(.rxLogData(backlog))
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x5C], variant: 1)))
    let snapshot = try await snapshot(harness, "the live relay") {
      $0.neighbours.contains { $0.identities.contains(.hash(Data([0x5C]))) }
    }
    #expect(snapshot.ledger.channelKey == Self.channel.key)
    #expect(!snapshot.neighbours.contains { $0.identities.contains(.hash(Data([0x9E]))) })
    await harness.service.stop()
  }

  @Test
  func `a stopped service has no ledger to give for another channel`() async throws {
    let harness = try await makeHarness()
    #expect(await harness.service.ledgerSnapshot(channelKey: Self.otherChannel.key) == nil)
    await start(harness)
    #expect(await harness.service.ledgerSnapshot(channelKey: Self.otherChannel.key) != nil)
    await harness.service.stop()
    #expect(await harness.service.ledgerSnapshot(channelKey: Self.otherChannel.key) == nil)
  }

  @Test
  func `unstamped entries are never evidence, and rows stored before channels were recorded are deleted`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let harness = try await makeHarness(container: container)
    // A neighbour row and an RX log entry as an earlier build stored them: no channel
    let context = ModelContext(container)
    let legacy = NeighbourLink(
      radioID: harness.radioID,
      channelKey: Self.channel.key,
      record: NeighbourRecord(identity: .hash(Data([0x7F])), firstHeard: harness.clock.now, lastHeard: harness.clock.now, heardCount: 3)
    )
    legacy.channelKey = nil
    context.insert(legacy)
    try context.save()
    try await harness.store.saveRxLogEntry(RxLogEntryDTO(
      radioID: harness.radioID,
      receivedAt: harness.clock.now.addingTimeInterval(-600),
      from: Self.advert(channel: nil)
    ))
    try await harness.store.flushPendingRxLogEntries()

    await start(harness)
    // A live frame the session left unstamped is no evidence either
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x9E], channel: nil)))
    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x5C], variant: 1)))
    let snapshot = try await snapshot(harness, "the stamped relay") { !$0.neighbours.isEmpty }

    #expect(snapshot.neighbours.map(\.identities) == [[.hash(Data([0x5C]))]])
    #expect(snapshot.ledger.nodes.isEmpty)
    #expect(try await harness.store.deleteUnstampedNeighbourRecords(radioID: harness.radioID) == 0)
    await harness.service.stop()
  }

  @Test
  func `a hash only a saved Hawaii contact has stays unknown in the snapshot`() async throws {
    let harness = try await makeHarness()
    try await harness.store.saveContact(.testContact(
      radioID: harness.radioID, publicKey: Self.konaHillKey, name: "Kona Hill", typeRawValue: 2, latitude: 19.6, longitude: -155.9
    ))
    await start(harness)

    await harness.session.yieldEvent(.rxLogData(Self.relayed(path: [0x7F])))
    let snapshot = try await snapshot(harness, "the relay row") { !$0.neighbours.isEmpty }
    #expect(snapshot.neighbours.first?.resolution == .unknown(Data([0x7F])))
    await harness.service.stop()
  }

  @Test
  func `stored adverts of the channel are replayed into the ledger on start`() async throws {
    let harness = try await makeHarness()
    try await harness.store.saveRxLogEntry(RxLogEntryDTO(
      radioID: harness.radioID,
      receivedAt: harness.clock.now.addingTimeInterval(-600),
      from: Self.advert(path: [0xB4, 0x9E])
    ))
    try await harness.store.flushPendingRxLogEntries()

    await start(harness)
    let snapshot = try #require(await harness.service.snapshot(radioID: harness.radioID))
    let node = try #require(snapshot.ledger.node(for: .fullKey(Self.repeaterKey)))
    #expect(node.minHops == 2)
    #expect(node.lastDirectAt == nil)
    // Relayed over two hops: an observation, not a neighbour
    #expect(!snapshot.neighbours.contains { $0.identities.contains(.fullKey(Self.repeaterKey)) })
    await harness.service.stop()
  }

  // MARK: - Hears you (R8)

  @Test
  func `an exact echo of our own channel message, passed on by one relay, says the relay hears us`() async throws {
    let harness = try await makeHarness()
    await start(harness)

    await harness.session.emitTransmission(.written(
      id: 1,
      command: PacketBuilder.sendChannelMessage(channel: 1, text: "hello all", timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
      at: harness.clock.now
    ))
    let service = harness.service
    try await waitUntil(timeout: .seconds(5), "the send recorded") { await service.ownSends.count == 1 }

    harness.clock.advance(3)
    let echo = Self.relayed(path: [0x3A])
    await harness.session.yieldEvent(.rxLogData(echo))
    let relayed = try await snapshot(harness, "the relay row") { !$0.neighbours.isEmpty }
    #expect(relayed.neighbours.first?.record.hearsYouAt == nil)

    // RxLogService decrypted the copy: our own text, on our channel, at our timestamp
    harness.entries.yield(RxLogEntryDTO(
      radioID: harness.radioID,
      receivedAt: harness.clock.now,
      from: echo,
      channelIndex: 1,
      decryptStatus: .success,
      senderTimestamp: 1_700_000_000,
      decodedText: "Base: hello all"
    ))
    let heard = try await snapshot(harness, "the relay hears us") { $0.neighbours.first?.record.hearsYouAt != nil }
    #expect(heard.neighbours.first?.identities == [.hash(Data([0x3A]))])
    #expect(heard.neighbours.first?.record.heardCount == 1)
    #expect(await harness.own.recentOwnPacketHashes().contains(echo.packetHash))
    await harness.service.stop()
  }
}
