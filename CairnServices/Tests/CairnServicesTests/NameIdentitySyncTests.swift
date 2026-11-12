import Foundation
@testable import CairnServices
import MeshCoreTestSupport
import Testing

/// Names stored with messages, reactions, room posts and sessions stay right through renames,
/// nickname changes, and posts written on a Cairn radio's own screen.
@Suite("Name identity in sync and storage")
@MainActor
struct NameIdentitySyncTests {
  private let selfKey = Data([0xC0, 0xFF, 0xEE, 0x01] + Array(repeating: 0x11, count: 28))
  private let roomKey = Data([0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F] + Array(repeating: 0x22, count: 26))
  private let sentAt: UInt32 = 1_760_000_000

  private struct Fixture {
    let radioID: UUID
    let store: PersistenceStore
    let services: ServiceContainer
    let dependencies: SyncDependencies
    let coordinator: SyncCoordinator
    let roomContact: ContactDTO
    let roomSession: RemoteNodeSessionDTO
  }

  private func makeFixture(nodeName: String = "Basecamp") async throws -> Fixture {
    let radioID = UUID()
    let session = MeshCoreSession(transport: SimulatorMockTransport())
    let services = try await ServiceContainer.forTesting(session: session, radioID: radioID)
    let store = services.dataStore
    try await store.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID, publicKey: selfKey, nodeName: nodeName))
    let roomContact = ContactDTO.testContact(
      radioID: radioID, publicKey: roomKey, name: "Diana's Room", typeRawValue: ContactType.room.rawValue
    )
    try await store.saveContact(roomContact)
    let roomSession = RemoteNodeSessionDTO(
      radioID: radioID, publicKey: roomKey, name: "Diana's Room", role: .roomServer,
      isConnected: true, permissionLevel: .readWrite
    )
    try await store.saveRemoteNodeSessionDTO(roomSession)
    let dependencies = services.syncDependencies.with(
      dataStore: store,
      messagePollingService: MockMessagePollingService()
    )
    return Fixture(
      radioID: radioID, store: store, services: services, dependencies: dependencies,
      coordinator: SyncCoordinator(), roomContact: roomContact, roomSession: roomSession
    )
  }

  // MARK: - Own room posts

  @Test
  func `a room post I make is saved under my key with no stored name`() async throws {
    let fixture = try await makeFixture()
    let post = try await fixture.services.roomServerService.postMessage(sessionID: fixture.roomSession.id, text: "hi room")
    #expect(post.isFromSelf)
    #expect(post.authorKeyPrefix == selfKey.prefix(4))
    #expect(post.authorName == nil)
  }

  @Test
  func `a room post written on the radio is my post in the room, not a DM to the room`() async throws {
    let fixture = try await makeFixture()
    let echo = RadioSentMessage(
      isLive: true, kind: .direct, destination: Data(roomKey.prefix(6)), timestamp: sentAt,
      ackCode: 0x1234, isDelivered: true, text: "from the trail"
    )
    await fixture.coordinator.handleRadioSentMessage(echo, dependencies: fixture.dependencies, radioID: fixture.radioID)

    let dms = try await fixture.store.fetchMessages(contactID: fixture.roomContact.id, limit: 10, offset: 0)
    #expect(dms.isEmpty)
    let posts = try await fixture.store.fetchRoomMessages(sessionID: fixture.roomSession.id, limit: nil, offset: nil)
    let post = try #require(posts.first)
    #expect(posts.count == 1)
    #expect(post.isFromSelf)
    #expect(post.authorKeyPrefix == selfKey.prefix(4))
    #expect(post.text == "from the trail")
    #expect(post.status == .delivered)
    let contact = try #require(try await fixture.store.fetchContact(id: fixture.roomContact.id))
    #expect(contact.lastMessageDate == nil)
  }

  @Test
  func `history of a room post this app sent is not stored twice`() async throws {
    let fixture = try await makeFixture()
    let sent = try await fixture.services.roomServerService.postMessage(sessionID: fixture.roomSession.id, text: "app post")
    let record = RadioSentMessage(
      isLive: false, kind: .direct, destination: Data(roomKey.prefix(6)), timestamp: sent.timestamp,
      ackCode: 0, isDelivered: false, text: "app post"
    )
    await fixture.coordinator.handleRadioSentMessage(
      record, context: .history(storedAt: Date()), dependencies: fixture.dependencies, radioID: fixture.radioID
    )
    let posts = try await fixture.store.fetchRoomMessages(sessionID: fixture.roomSession.id, limit: nil, offset: nil)
    #expect(posts.count == 1)
    let dms = try await fixture.store.fetchMessages(contactID: fixture.roomContact.id, limit: 10, offset: 0)
    #expect(dms.isEmpty)
  }

  @Test
  func `a room post echoed with no room session is not filed as a DM`() async throws {
    let fixture = try await makeFixture()
    try await fixture.store.deleteRemoteNodeSession(id: fixture.roomSession.id)
    let echo = RadioSentMessage(
      isLive: true, kind: .direct, destination: Data(roomKey.prefix(6)), timestamp: sentAt,
      ackCode: 0x1234, isDelivered: false, text: "nobody home"
    )
    await fixture.coordinator.handleRadioSentMessage(echo, dependencies: fixture.dependencies, radioID: fixture.radioID)
    let dms = try await fixture.store.fetchMessages(contactID: fixture.roomContact.id, limit: 10, offset: 0)
    #expect(dms.isEmpty)
  }

  @Test
  func `room posts older builds filed as DMs move into the room`() async throws {
    let fixture = try await makeFixture()
    let stray = MessageDTO(
      id: UUID(), radioID: fixture.radioID, contactID: fixture.roomContact.id, channelIndex: nil,
      text: "old echo", timestamp: sentAt, createdAt: Date(), direction: .outgoing, status: .sent,
      textType: .plain, ackCode: nil, pathLength: 0, snr: nil, senderKeyPrefix: nil, senderNodeName: nil,
      isRead: true, replyToID: nil, roundTripTime: nil, heardRepeats: 0, retryAttempt: 0,
      maxRetryAttempts: 0, sentFromRadio: true
    )
    try await fixture.store.saveMessage(stray)
    try await fixture.store.updateContactLastMessage(contactID: fixture.roomContact.id, date: Date())

    await fixture.coordinator.repairStoredNames(
      dependencies: fixture.dependencies, radioID: fixture.radioID, defaultsSuiteName: UUID().uuidString
    )

    let dms = try await fixture.store.fetchMessages(contactID: fixture.roomContact.id, limit: 10, offset: 0)
    #expect(dms.isEmpty)
    let contact = try #require(try await fixture.store.fetchContact(id: fixture.roomContact.id))
    #expect(contact.lastMessageDate == nil)
    let posts = try await fixture.store.fetchRoomMessages(sessionID: fixture.roomSession.id, limit: nil, offset: nil)
    #expect(posts.map(\.text) == ["old echo"])
    #expect(posts.first?.isFromSelf == true)
  }

  // MARK: - Own channel messages and renames

  @Test
  func `a channel message I send records the name it went out under`() async throws {
    let fixture = try await makeFixture(nodeName: "OldName")
    let pending = try await fixture.services.messageService.createPendingChannelMessage(
      text: "hello", channelIndex: 0, radioID: fixture.radioID
    )
    #expect(pending.sentAsNodeName == "OldName")
    try await fixture.store.updateMessageSentAsNodeName(id: pending.id, name: "NewName")
    let stored = try #require(try await fixture.store.fetchMessage(id: pending.id))
    #expect(stored.sentAsNodeName == "NewName")
  }

  @Test
  func `a reaction naming my old name still finds my message after a rename`() async throws {
    let fixture = try await makeFixture(nodeName: "NewName")
    let mine = MessageDTO(
      id: UUID(), radioID: fixture.radioID, contactID: nil, channelIndex: 3, text: "summit at noon",
      timestamp: sentAt, createdAt: Date(timeIntervalSince1970: TimeInterval(sentAt)), direction: .outgoing,
      status: .sent, textType: .plain, ackCode: nil, pathLength: 0, snr: nil, senderKeyPrefix: nil,
      senderNodeName: nil, isRead: true, replyToID: nil, roundTripTime: nil, heardRepeats: 0,
      retryAttempt: 0, maxRetryAttempts: 0, sentAsNodeName: "OldName"
    )
    try await fixture.store.saveMessage(mine)
    let hash = ReactionParser.generateMessageHash(text: mine.text, timestamp: mine.reactionTimestamp)
    let parsed = ParsedReaction(emoji: "👍", targetSender: "OldName", messageHash: hash)
    let found = try await fixture.store.findChannelMessageForReaction(
      radioID: fixture.radioID, channelIndex: 3, parsedReaction: parsed, localNodeName: "NewName",
      timestampWindow: (sentAt - 60)...(sentAt + 60), limit: 50
    )
    #expect(found?.id == mine.id)
    let wrong = ParsedReaction(emoji: "👍", targetSender: "NewName", messageHash: hash)
    let notFound = try await fixture.store.findChannelMessageForReaction(
      radioID: fixture.radioID, channelIndex: 3, parsedReaction: wrong, localNodeName: "NewName",
      timestampWindow: (sentAt - 60)...(sentAt + 60), limit: 50
    )
    #expect(notFound == nil)
  }

  @Test
  func `the node name is read per message, so a rename applies at once`() async throws {
    let fixture = try await makeFixture(nodeName: "OldName")
    #expect(await fixture.coordinator.currentSelfNodeName(radioID: fixture.radioID, dataStore: fixture.store) == "OldName")
    try await fixture.store.saveDevice(DeviceDTO.testDevice(id: fixture.radioID, radioID: fixture.radioID, publicKey: selfKey, nodeName: "NewName"))
    #expect(await fixture.coordinator.currentSelfNodeName(radioID: fixture.radioID, dataStore: fixture.store) == "NewName")
  }

  // MARK: - Reactions

  @Test
  func `my saved reactions are marked as mine once`() async throws {
    let fixture = try await makeFixture()
    let message = MessageDTO.testChannelMessage(radioID: fixture.radioID, channelIndex: 1, direction: .incoming, senderNodeName: "Carol")
    try await fixture.store.saveMessage(message)
    try await fixture.store.saveReaction(ReactionDTO.testReaction(messageID: message.id, radioID: fixture.radioID, senderName: "Basecamp"))
    try await fixture.store.saveReaction(ReactionDTO.testReaction(messageID: message.id, radioID: fixture.radioID, emoji: "🔥", senderName: "Me"))
    try await fixture.store.saveReaction(ReactionDTO.testReaction(messageID: message.id, radioID: fixture.radioID, emoji: "😂", senderName: "Carol"))
    let defaults = UUID().uuidString

    await fixture.coordinator.repairStoredNames(dependencies: fixture.dependencies, radioID: fixture.radioID, defaultsSuiteName: defaults)

    let reactions = try await fixture.store.fetchReactions(for: message.id, limit: 10)
    #expect(Set(reactions.filter(\.isFromSelf).map(\.emoji)) == ["👍", "🔥"])
    #expect(reactions.first { $0.emoji == "😂" }?.isFromSelf == false)

    // A later reaction from someone who shares the node name is not taken for mine.
    try await fixture.store.saveReaction(ReactionDTO.testReaction(messageID: message.id, radioID: fixture.radioID, emoji: "🎉", senderName: "Basecamp"))
    await fixture.coordinator.repairStoredNames(dependencies: fixture.dependencies, radioID: fixture.radioID, defaultsSuiteName: defaults)
    let after = try await fixture.store.fetchReactions(for: message.id, limit: 10)
    #expect(after.first { $0.emoji == "🎉" }?.isFromSelf == false)
  }

  @Test
  func `a DM reaction arriving again after a nickname change is not a duplicate`() async throws {
    let fixture = try await makeFixture()
    let contact = ContactDTO.testContact(radioID: fixture.radioID, publicKey: Data(repeating: 0x44, count: 32), name: "Frank Wilson", nickname: "Dad")
    try await fixture.store.saveContact(contact)
    let message = MessageDTO.testDirectMessage(radioID: fixture.radioID, contactID: contact.id, direction: .outgoing)
    try await fixture.store.saveMessage(message)
    // Saved by an older build under the nickname of the day.
    try await fixture.store.saveReaction(ReactionDTO.testReaction(messageID: message.id, radioID: fixture.radioID, senderName: "Dad", channelIndex: nil, contactID: contact.id))
    let again = ReactionDTO.testReaction(messageID: message.id, radioID: fixture.radioID, senderName: "Frank Wilson", channelIndex: nil, contactID: contact.id)
    #expect(try await fixture.store.hasReaction(matching: again))
  }

  // MARK: - Sessions

  @Test
  func `a room's session name follows its contact's nickname`() async throws {
    let fixture = try await makeFixture()
    try await fixture.store.saveContact(ContactDTO.testContact(
      id: fixture.roomContact.id, radioID: fixture.radioID, publicKey: roomKey, name: "Diana's Room",
      typeRawValue: ContactType.room.rawValue, nickname: "Trail Room"
    ))
    await fixture.coordinator.refreshRemoteNodeSessionNames(dataStore: fixture.store, radioID: fixture.radioID)
    let session = try #require(try await fixture.store.fetchRemoteNodeSession(id: fixture.roomSession.id))
    #expect(session.name == "Trail Room")
    #expect(session.isConnected)
    #expect(session.permissionLevel == .readWrite)
  }

  // MARK: - Notifications

  @Test
  func `a group notification names its sender and reads mentions as the bubble does`() {
    #expect(NotificationService.groupBody(sender: "Dad (Frank Wilson)", text: "@[Basecamp] ok") == "Dad (Frank Wilson): @Basecamp ok")
    #expect(NotificationService.groupBody(sender: nil, text: "plain") == "plain")
  }

  @Test
  func `a blank channel name reads as its slot in a notification`() {
    let service = NotificationService()
    #expect(service.channelDisplayName(name: "", index: 4) == "Channel 4")
    #expect(service.channelDisplayName(name: nil, index: 5) == "Channel 5")
    #expect(service.channelDisplayName(name: "Hike", index: 4) == "Hike")
  }

  @Test
  func `a room notification names an unknown author by key, never leaving it out`() async throws {
    let fixture = try await makeFixture()
    let stranger = RoomMessageDTO(sessionID: fixture.roomSession.id, authorKeyPrefix: Data([0xDE, 0xAD, 0xBE, 0xEF]), text: "hi", timestamp: sentAt)
    let label = await fixture.coordinator.roomAuthorLabel(stranger, session: fixture.roomSession, dependencies: fixture.dependencies)
    #expect(label == "DEADBEEF")

    let frankKey = Data([0x60, 0x61, 0x62, 0x63] + Array(repeating: 0x60, count: 28))
    try await fixture.store.saveContact(ContactDTO.testContact(radioID: fixture.radioID, publicKey: frankKey, name: "Frank Wilson", nickname: "Dad"))
    await fixture.coordinator.contactsDidChange()
    let frank = RoomMessageDTO(sessionID: fixture.roomSession.id, authorKeyPrefix: frankKey.prefix(4), authorName: "Frank Wilson", text: "hi", timestamp: sentAt)
    #expect(await fixture.coordinator.roomAuthorLabel(frank, session: fixture.roomSession, dependencies: fixture.dependencies) == "Dad")
  }
}
