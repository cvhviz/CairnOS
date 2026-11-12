import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// The board's chat history pulled through the real handlers (firmware's HIST_SYNC.md).
@Suite("Radio chat history import", .serialized)
@MainActor
struct RadioHistoryImportTests {
  private let bobKey = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6] + Array(repeating: 0x42, count: 26))
  private let storeID: UInt32 = 0xC0FFEE
  private let day = UInt32(Date().timeIntervalSince1970) - 86400

  private struct Fixture {
    let radioID: UUID
    let store: PersistenceStore
    let polling: MessagePollingService
    let session: MockMeshCoreSession
    let coordinator: SyncCoordinator
    let bob: ContactDTO
  }

  private func makeFixture() async throws -> Fixture {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let bob = ContactDTO.testContact(radioID: radioID, publicKey: bobKey, name: "Bob")
    try await store.saveContact(bob)
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 1, name: "Hike"))
    let polling = MessagePollingService(session: session, dataStore: store)
    let dependencies = services.syncDependencies.with(dataStore: store, messagePollingService: polling)
    let coordinator = SyncCoordinator()
    await coordinator.wireMessageHandlers(dependencies: dependencies, radioID: radioID)
    await polling.startMessageEventMonitoring(radioID: radioID)
    HistoryWatermark(radioID: radioID).reset()
    return Fixture(radioID: radioID, store: store, polling: polling, session: session, coordinator: coordinator, bob: bob)
  }

  private func record(
    _ seq: UInt32, _ text: String, flags: CairnHistoryRecord.Flags = [], channel: UInt8? = nil, sent: UInt32? = nil,
    stored: UInt32? = nil
  ) -> CairnHistoryRecord {
    var f = flags
    if sent != nil { f.insert(.hasSentTimestamp) }
    if channel != nil { f.insert(.channel) }
    return CairnHistoryRecord(
      flags: f, seq: seq, key: channel == nil ? bobKey.prefix(6) : Data(repeating: 7, count: 6),
      channelIndex: channel, pathLength: 1, storedAt: stored ?? (day + seq), sentAt: sent ?? 0, snrX4: 20, rssi: -80,
      text: Data(text.utf8)
    )
  }

  private func page(_ records: [CairnHistoryRecord], remaining: UInt16 = 0) -> CairnHistoryPage {
    let last = records.last?.seq ?? 0
    return CairnHistoryPage(
      reply: CairnHistoryPageReply(status: .ok, storeID: storeID, total: UInt16(records.count) + remaining, page: UInt8(records.count)),
      records: records,
      end: CairnHistoryEnd(aborted: false, lastSeq: last, remaining: remaining, storeID: storeID)
    )
  }

  @Test
  func `DMs, channel posts and own sends are stored read, and the watermark moves on`() async throws {
    let fx = try await makeFixture()
    await fx.session.setHistory(
      query: CairnHistoryPageReply(status: .ok, storeID: storeID, total: 3, page: 0),
      pages: [page([
        record(1, "morning", sent: day + 1),
        record(2, "Alice: summit at noon", channel: 1, sent: day + 2),
        record(3, "on my way", flags: .outgoing),
      ])]
    )
    let walked = await fx.polling.importRadioHistory()
    #expect(walked == 3)
    let dms = try await fx.store.fetchMessages(contactID: fx.bob.id)
    #expect(Set(dms.map(\.text)) == ["morning", "on my way"])
    #expect(dms.allSatisfy { $0.isRead })
    let posts = try await fx.store.fetchMessages(radioID: fx.radioID, channelIndex: 1)
    #expect(posts.count == 1)
    #expect(posts.first?.isRead == true)
    let mark = HistoryWatermark(radioID: fx.radioID)
    #expect(mark.storeID == storeID)
    #expect(mark.lastSeq == 3)
  }

  @Test
  func `a DM the drain already stored is not stored twice`() async throws {
    let fx = try await makeFixture()
    let msg = ContactMessage(senderPublicKeyPrefix: bobKey.prefix(6), pathLength: 1, textType: 0,
                             senderTimestamp: Date(timeIntervalSince1970: TimeInterval(day + 5)), signature: nil,
                             text: "drained already", snr: 5)
    await fx.session.setGetMessageResults([.success(.contactMessage(msg)), .success(.noMoreMessages)])
    _ = try await fx.polling.pollAllMessages()
    await fx.session.setHistory(
      query: CairnHistoryPageReply(status: .ok, storeID: storeID, total: 1, page: 0),
      pages: [page([record(5, "drained already", sent: day + 5)])]
    )
    _ = await fx.polling.importRadioHistory()
    let dms = try await fx.store.fetchMessages(contactID: fx.bob.id)
    #expect(dms.filter { $0.text == "drained already" }.count == 1)
  }

  @Test
  func `the next import asks from the watermark, a new store id starts over`() async throws {
    let fx = try await makeFixture()
    await fx.session.setHistory(
      query: CairnHistoryPageReply(status: .ok, storeID: storeID, total: 2, page: 0),
      pages: [page([record(1, "one", sent: day + 1), record(2, "two", sent: day + 2)])]
    )
    _ = await fx.polling.importRadioHistory()
    await fx.session.setHistory(query: CairnHistoryPageReply(status: .ok, storeID: storeID, total: 0, page: 0), pages: [])
    _ = await fx.polling.importRadioHistory()
    let requested = await fx.session.historyPageRequests
    #expect(requested == [0, 2])
    // the board renumbered (its history cleared): from its first record
    await fx.session.setHistory(query: CairnHistoryPageReply(status: .ok, storeID: storeID + 1, total: 0, page: 0), pages: [])
    _ = await fx.polling.importRadioHistory()
    let lastRequest = await fx.session.historyPageRequests.last
    #expect(lastRequest == 0)
  }

  @Test
  func `other firmware is asked once`() async throws {
    let fx = try await makeFixture()
    await fx.session.setHistory(query: nil, pages: [])
    let a = await fx.polling.importRadioHistory()
    let b = await fx.polling.importRadioHistory()
    #expect(a == 0 && b == 0)
    let queries = await fx.session.historyQueryCount
    #expect(queries == 1)
  }

  @Test
  func `room posts without an author are left out`() async throws {
    let fx = try await makeFixture()
    await fx.session.setHistory(
      query: CairnHistoryPageReply(status: .ok, storeID: storeID, total: 1, page: 0),
      pages: [page([record(9, "a room post", flags: .signed, sent: day + 9)])]
    )
    _ = await fx.polling.importRadioHistory()
    let dms = try await fx.store.fetchMessages(contactID: fx.bob.id)
    #expect(dms.isEmpty)
    #expect(HistoryWatermark(radioID: fx.radioID).lastSeq == 9)   // walked past all the same
  }

  @Test
  func `a message this app sent comes back from the board only once`() async throws {
    let fx = try await makeFixture()
    let sentAt = day + 20
    try await fx.store.saveMessage(MessageDTO.testDirectMessage(
      radioID: fx.radioID, contactID: fx.bob.id, text: "sent from the phone", timestamp: sentAt, direction: .outgoing
    ))
    await fx.session.setHistory(
      query: CairnHistoryPageReply(status: .ok, storeID: storeID, total: 1, page: 0),
      pages: [page([record(20, "sent from the phone", flags: .outgoing, stored: sentAt)])]
    )
    _ = await fx.polling.importRadioHistory()
    let dms = try await fx.store.fetchMessages(contactID: fx.bob.id)
    #expect(dms.filter { $0.text == "sent from the phone" }.count == 1)
  }
}
