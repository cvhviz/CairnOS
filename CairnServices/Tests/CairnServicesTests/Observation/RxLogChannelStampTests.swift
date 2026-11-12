import CryptoKit
import Foundation
@testable import CairnServices
@testable import MeshCore
import SwiftData
import Testing

@Suite("RX log channel stamp")
struct RxLogChannelStampTests {
  private typealias Frames = StockCompanionFrames

  private static let advertiser = Frames.signingKey(seed: 0x11)

  private struct Harness {
    let radioID: UUID
    let container: ModelContainer
    let store: PersistenceStore
    let session: MeshCoreSession
    let service: RxLogService
  }

  private static func harness() async throws -> Harness {
    let radioID = UUID()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let session = MeshCoreSession(transport: MockTransport())
    let service = RxLogService(session: session, dataStore: store, heardRepeatsService: nil)
    await service.startEventMonitoring(radioID: radioID)
    return Harness(radioID: radioID, container: container, store: store, session: session, service: service)
  }

  /// Processes `parsed`, returning the entry the stream yielded and the one stored.
  private static func process(
    _ parsed: ParsedRxLogData,
    in harness: Harness
  ) async throws -> (yielded: RxLogEntryDTO, stored: RxLogEntryDTO) {
    var stream = harness.service.entryStream().makeAsyncIterator()
    await harness.service.process(parsed)
    let yielded = try #require(await stream.next())
    await harness.service.flushPendingEntries()
    let stored = try #require(try await harness.store.fetchRxLogEntries(radioID: harness.radioID).first { $0.id == yielded.id })
    return (yielded, stored)
  }

  @Test
  func `a stamped packet gives a stamped entry, yielded and stored`() async throws {
    let harness = try await Self.harness()
    defer { Task { await harness.service.stopEventMonitoring() } }
    let parsed = Frames.parsed(Frames.groupTextPacket(index: 1), channel: Frames.channel)

    let (yielded, stored) = try await Self.process(parsed, in: harness)
    #expect(yielded.channel == Frames.channel)
    #expect(yielded.channelKey == Frames.channel.key)
    #expect(stored.channelKey == Frames.channel.key)
    #expect(stored.channel == Frames.channel, "the coding rate is stored beside the key")
  }

  @Test
  func `an unstamped packet stays unstamped, whatever the session reports now`() async throws {
    let harness = try await Self.harness()
    defer { Task { await harness.service.stopEventMonitoring() } }
    guard case let .selfInfo(info) = PacketParser.parse(Frames.selfInfo) else {
      Issue.record("SELF_INFO did not parse")
      return
    }
    // The session knows its channel, but the frame was not stamped (a retune not yet confirmed,
    // an old RX_SYNC record): the RX log never stamps it a second time
    await harness.session.installSelfInfoForTest(info)
    let parsed = Frames.parsed(Frames.groupTextPacket(index: 2), channel: nil)

    let (yielded, stored) = try await Self.process(parsed, in: harness)
    #expect(yielded.channel == nil)
    #expect(yielded.channelKey == nil)
    #expect(stored.channel == nil)
    #expect(stored.channelKey == nil)
  }

  @Test
  func `an entry stored before channels were recorded reads with no channel`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let radioID = UUID()
    let context = ModelContext(container)
    context.insert(RxLogEntry(
      radioID: radioID,
      routeType: Int(RouteType.flood.rawValue),
      payloadType: Int(PayloadType.groupText.rawValue),
      payloadVersion: 0,
      pathLength: 0,
      pathNodes: Data(),
      packetPayload: Data([0x01, 0x02]),
      rawPayload: Data([0x15, 0x00, 0x01, 0x02]),
      packetHash: "legacy"
    ))
    try context.save()

    let entry = try #require(try await store.fetchRxLogEntries(radioID: radioID).first)
    #expect(entry.channel == nil)
    #expect(entry.channelKey == nil)
  }

  @Test
  func `an advert writes nothing about channels to the advertiser's contact`() async throws {
    let harness = try await Self.harness()
    defer { Task { await harness.service.stopEventMonitoring() } }
    let key = Self.advertiser.publicKey.rawRepresentation
    try await harness.store.saveContact(ContactDTO.testContact(radioID: harness.radioID, publicKey: key, name: "Claremont"))
    let before = try #require(try await harness.store.fetchContact(radioID: harness.radioID, publicKey: key))

    let advert = Frames.signedAdvert(name: "Claremont", key: Self.advertiser, lat: 34.1, lon: -117.7, path: [0x3A])
    _ = try await Self.process(Frames.parsed(advert, channel: Frames.channel), in: harness)

    #expect(try await harness.store.fetchContact(radioID: harness.radioID, publicKey: key) == before)
  }
}
