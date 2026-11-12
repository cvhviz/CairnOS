import Foundation
@testable import CairnServices
import MeshCoreTestSupport
import Testing

/// Messages sent from the radio's own UI (Cairn sent-message echo, SENT_SYNC.md).
@Suite("Radio-sent message sync")
@MainActor
struct RadioSentMessageTests {
  private let publicKey = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66] + Array(repeating: 0xAB, count: 26))
  private let sentAt: UInt32 = 1_760_000_000

  private final class StatusEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MessageStatusEvent] = []
    func append(_ event: MessageStatusEvent) {
      lock.lock(); defer { lock.unlock() }
      events.append(event)
    }

    var all: [MessageStatusEvent] {
      lock.lock(); defer { lock.unlock() }
      return events
    }
  }

  private struct Fixture {
    let radioID: UUID
    let dataStore: PersistenceStore
    let dependencies: SyncDependencies
    let coordinator: SyncCoordinator
    let contact: ContactDTO
    let statusEvents: StatusEvents
  }

  private func makeFixture() async throws -> Fixture {
    let radioID = UUID()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    try await store.saveDevice(DeviceDTO.testDevice(id: radioID, nodeName: "Me"))
    let contact = ContactDTO.testContact(radioID: radioID, publicKey: publicKey, name: "Peer")
    try await store.saveContact(contact)
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 2, name: "Hike"))

    let transport = SimulatorMockTransport()
    let session = MeshCoreSession(transport: transport)
    let services = try await ServiceContainer.forTesting(session: session)
    let statusEvents = StatusEvents()
    let dependencies = services.syncDependencies.with(
      dataStore: store,
      messagePollingService: MockMessagePollingService(),
      publishMessageStatus: { statusEvents.append($0) }
    )
    return Fixture(
      radioID: radioID,
      dataStore: store,
      dependencies: dependencies,
      coordinator: SyncCoordinator(),
      contact: contact,
      statusEvents: statusEvents
    )
  }

  private func dmEcho(
    text: String = "on my way",
    timestamp: UInt32? = nil,
    ack: UInt32 = 0xCAFE_F00D,
    delivered: Bool = false,
    live: Bool = true
  ) -> RadioSentMessage {
    RadioSentMessage(
      isLive: live,
      kind: .direct,
      destination: Data(publicKey.prefix(6)),
      timestamp: timestamp ?? sentAt,
      ackCode: ack,
      isDelivered: delivered,
      text: text
    )
  }

  private func handle(
    _ message: RadioSentMessage,
    _ fixture: Fixture,
    context: DeliveryContext = .live
  ) async {
    await fixture.coordinator.handleRadioSentMessage(
      message,
      context: context,
      dependencies: fixture.dependencies,
      radioID: fixture.radioID
    )
  }

  private func dmRows(_ fixture: Fixture) async throws -> [MessageDTO] {
    try await fixture.dataStore.fetchMessages(contactID: fixture.contact.id, limit: 50, offset: 0)
  }

  // MARK: - Storing

  @Test
  func `DM echo is stored as an outgoing radio-sent row`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(), fixture)

    let rows = try await dmRows(fixture)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.direction == .outgoing)
    #expect(row.sentFromRadio)
    #expect(row.status == .sent)
    #expect(row.isRead)
    #expect(row.timestamp == sentAt)
    #expect(row.ackCode == 0xCAFE_F00D)
    #expect(row.text == "on my way")
    #expect(row.textType == .plain)
    #expect(!row.timestampCorrected)
    #expect(row.createdAt == Date(timeIntervalSince1970: TimeInterval(sentAt)))

    // Outgoing: no unread change.
    let contact = try #require(await fixture.dataStore.fetchContact(id: fixture.contact.id))
    #expect(contact.unreadCount == 0)
  }

  @Test
  func `a live echo is announced as it arrives, a fetched one is not`() async throws {
    let fixture = try await makeFixture()
    let events = fixture.coordinator.dataEvents()
    await handle(dmEcho(text: "queued", live: false), fixture, context: .initialSync(anchor: .now))
    await handle(dmEcho(), fixture)
    fixture.coordinator.finishDataEvents()

    var announced: [RadioSentMessage] = []
    for await event in events {
      if case let .radioSentMessage(message) = event { announced.append(message) }
    }
    #expect(announced.map(\.text) == ["on my way"])
    #expect(announced.first?.ackCode == 0xCAFE_F00D)
  }

  @Test
  func `channel echo is stored under its slot without an ack`() async throws {
    let fixture = try await makeFixture()
    let echo = RadioSentMessage(
      isLive: false,
      kind: .channel,
      destination: Data([2, 0, 0, 0, 0, 0]),
      timestamp: sentAt,
      ackCode: 0,
      isDelivered: false,
      text: "summit!"
    )
    await handle(echo, fixture)

    let rows = try await fixture.dataStore.fetchMessages(radioID: fixture.radioID, channelIndex: 2, limit: 50, offset: 0)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.direction == .outgoing)
    #expect(row.sentFromRadio)
    #expect(row.status == .sent)
    #expect(row.ackCode == nil)
    #expect(row.senderNodeName == nil)
    let channel = try #require(await fixture.dataStore.fetchChannel(radioID: fixture.radioID, index: 2))
    #expect(channel.unreadCount == 0)
  }

  @Test
  func `a second copy merges and only upgrades to delivered`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(live: true), fixture)
    await handle(dmEcho(delivered: true, live: false), fixture)
    await handle(dmEcho(delivered: false, live: false), fixture)

    let rows = try await dmRows(fixture)
    #expect(rows.count == 1)
    #expect(rows.first?.status == .delivered)
    #expect(fixture.statusEvents.all.count == 1)
  }

  @Test
  func `the same text at another timestamp is another message`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(timestamp: sentAt), fixture)
    await handle(dmEcho(timestamp: sentAt + 1), fixture)
    #expect(try await dmRows(fixture).count == 2)
  }

  @Test
  func `echo for an unknown contact is dropped`() async throws {
    let fixture = try await makeFixture()
    let echo = RadioSentMessage(
      isLive: true,
      kind: .direct,
      destination: Data([9, 9, 9, 9, 9, 9]),
      timestamp: sentAt,
      ackCode: 1,
      isDelivered: false,
      text: "who?"
    )
    await handle(echo, fixture)
    #expect(try await dmRows(fixture).isEmpty)
  }

  @Test
  func `unset radio clock sorts by arrival and keeps the raw timestamp`() async throws {
    let fixture = try await makeFixture()
    let before = Date()
    await handle(dmEcho(timestamp: 120), fixture)

    let row = try #require(try await dmRows(fixture).first)
    #expect(row.timestamp == 120)
    #expect(row.timestampCorrected)
    #expect(row.createdAt >= before.addingTimeInterval(-1))
    #expect(row.senderDate == row.createdAt)
  }

  // MARK: - ACKs and status

  @Test
  func `SEND_CONFIRMED with the echo ack marks it delivered`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(ack: 0x0102_0304), fixture)

    let reconciled = try await fixture.dataStore.markOutgoingSentDMDelivered(ackCode: 0x0102_0304, roundTripTime: 850)
    #expect(reconciled != nil)
    let row = try #require(try await dmRows(fixture).first)
    #expect(row.status == .delivered)
    #expect(row.roundTripTime == 850)
  }

  @Test
  func `status update delivered then failed never downgrades`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(), fixture)

    let delivered = RadioSentMessage(
      isLive: true, kind: .statusUpdate, destination: Data(publicKey.prefix(6)), timestamp: sentAt,
      ackCode: 0xCAFE_F00D, isDelivered: true, text: "", deliveryStatus: .delivered, roundTripTime: 1200
    )
    await handle(delivered, fixture)
    var row = try #require(try await dmRows(fixture).first)
    #expect(row.status == .delivered)
    #expect(row.roundTripTime == 1200)

    let failed = RadioSentMessage(
      isLive: false, kind: .statusUpdate, destination: Data(publicKey.prefix(6)), timestamp: sentAt,
      ackCode: 0xCAFE_F00D, isDelivered: false, text: "", deliveryStatus: .failed
    )
    await handle(failed, fixture)
    row = try #require(try await dmRows(fixture).first)
    #expect(row.status == .delivered)

    let events = fixture.statusEvents.all
    #expect(events.count == 1)
    if case let .statusResolved(_, status, rtt)? = events.first {
      #expect(status == .delivered)
      #expect(rtt == 1200)
    } else {
      Issue.record("Expected statusResolved")
    }
  }

  @Test
  func `failed status update fails a still-sent row`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(), fixture)
    let failed = RadioSentMessage(
      isLive: true, kind: .statusUpdate, destination: Data(publicKey.prefix(6)), timestamp: sentAt,
      ackCode: 0xCAFE_F00D, isDelivered: false, text: "", deliveryStatus: .failed
    )
    await handle(failed, fixture)
    let row = try #require(try await dmRows(fixture).first)
    #expect(row.status == .failed)
    if case .failed? = fixture.statusEvents.all.first {} else {
      Issue.record("Expected a failed event")
    }
  }

  @Test
  func `status update with no stored row is ignored`() async throws {
    let fixture = try await makeFixture()
    let delivered = RadioSentMessage(
      isLive: true, kind: .statusUpdate, destination: Data(publicKey.prefix(6)), timestamp: sentAt,
      ackCode: 5, isDelivered: true, text: "", deliveryStatus: .delivered, roundTripTime: 1
    )
    await handle(delivered, fixture)
    #expect(try await dmRows(fixture).isEmpty)
    #expect(fixture.statusEvents.all.isEmpty)
  }

  @Test
  func `stale-sent sweep leaves radio-sent rows alone`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(timestamp: sentAt), fixture)
    let failed = try await fixture.dataStore.failStaleSentDMs(sentBefore: Date(), excluding: [])
    #expect(failed.isEmpty)
    #expect(try await dmRows(fixture).first?.status == .sent)
  }

  @Test
  func `drained echo sorts at the drain anchor like received backlog`() async throws {
    let fixture = try await makeFixture()
    let anchor = Date(timeIntervalSince1970: TimeInterval(sentAt) + 1800)
    await handle(dmEcho(live: false), fixture, context: .initialSync(anchor: anchor))

    let row = try #require(try await dmRows(fixture).first)
    #expect(row.sortDate == anchor)
    #expect(row.createdAt == Date(timeIntervalSince1970: TimeInterval(sentAt)))
  }

  @Test
  func `live echo sorts at receive time, not the radio's send time`() async throws {
    let fixture = try await makeFixture()
    let before = Date()
    await handle(dmEcho(live: true), fixture, context: .live)

    let row = try #require(try await dmRows(fixture).first)
    #expect(row.sortDate >= before.addingTimeInterval(-1))
    #expect(row.timestamp == sentAt)
  }

  @Test
  func `app resend turns a radio-sent row into an ordinary app send`() async throws {
    let fixture = try await makeFixture()
    await handle(dmEcho(timestamp: 120), fixture)
    let row = try #require(try await dmRows(fixture).first)
    #expect(row.sentFromRadio)

    try await fixture.dataStore.updateMessageTimestamp(id: row.id, timestamp: sentAt + 60)

    let resent = try #require(try await fixture.dataStore.fetchMessage(id: row.id))
    #expect(!resent.sentFromRadio)
    #expect(!resent.timestampCorrected)
    #expect(resent.senderTimestamp == nil)
    #expect(resent.timestamp == sentAt + 60)
    // Now swept like any app DM stranded by a teardown.
    let failed = try await fixture.dataStore.failStaleSentDMs(
      sentBefore: Date(timeIntervalSince1970: TimeInterval(sentAt) + 3600), excluding: []
    )
    #expect(failed == [row.id])
  }

  // MARK: - Model

  @Test
  func `backups without the field decode as not sent from radio`() throws {
    let dto = MessageDTO.testDirectMessage(text: "old")
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
    json.removeValue(forKey: "sentFromRadio")
    let decoded = try JSONDecoder().decode(MessageDTO.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(!decoded.sentFromRadio)

    let radioSent = dto.copy { $0.sentFromRadio = true }
    let roundTrip = try JSONDecoder().decode(MessageDTO.self, from: JSONEncoder().encode(radioSent))
    #expect(roundTrip.sentFromRadio)
  }

  @Test
  func `dedupe key names the conversation, timestamp and text`() {
    let dm = DeduplicationKey.radioSent(destination: Data([1, 2, 3, 4, 5, 6]), channelIndex: nil, timestamp: 9, content: "a")
    let ch = DeduplicationKey.radioSent(destination: Data([1, 0, 0, 0, 0, 0]), channelIndex: 1, timestamp: 9, content: "a")
    #expect(dm.hasPrefix("radio-sent|dm:010203040506|9|"))
    #expect(ch.hasPrefix("radio-sent|ch:1|9|"))
    #expect(dm != DeduplicationKey.radioSent(destination: Data([1, 2, 3, 4, 5, 6]), channelIndex: nil, timestamp: 9, content: "b"))
  }
}
