import Foundation
@testable import Cairn
@testable import CairnServices
import SwiftData
import Testing

// MARK: - Helpers

private func makeContact(radioID: UUID, name: String, unreadCount: Int = 0) -> ContactDTO {
  ContactDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: Data((0..<ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: 0...255) }),
    name: name,
    typeRawValue: ContactType.chat.rawValue,
    flags: 0,
    outPathLength: 2,
    outPath: Data([0x01, 0x02]),
    lastAdvertTimestamp: 1_000,
    latitude: 0,
    longitude: 0,
    lastModified: 1_000,
    lastHeardTimestamp: nil,
    nickname: nil,
    isBlocked: false,
    isMuted: false,
    isFavorite: false,
    lastMessageDate: Date(timeIntervalSince1970: 1_000),
    unreadCount: unreadCount
  )
}

private func makeChannel(radioID: UUID, index: UInt8, name: String, unreadCount: Int = 0) -> ChannelDTO {
  ChannelDTO(
    id: UUID(),
    radioID: radioID,
    index: index,
    name: name,
    secret: Data(repeating: 0xA1, count: 16),
    isEnabled: true,
    lastMessageDate: Date(timeIntervalSince1970: 1_000),
    unreadCount: unreadCount,
    unreadMentionCount: 0,
    notificationLevel: .all,
    isFavorite: false
  )
}

private func makeMessage(
  radioID: UUID,
  contactID: UUID? = nil,
  channelIndex: UInt8? = nil,
  text: String,
  at seconds: TimeInterval,
  direction: MessageDirection = .incoming,
  replyToID: UUID? = nil
) -> MessageDTO {
  MessageDTO(
    id: UUID(),
    radioID: radioID,
    contactID: contactID,
    channelIndex: channelIndex,
    text: text,
    timestamp: UInt32(seconds),
    createdAt: Date(timeIntervalSince1970: seconds),
    direction: direction,
    status: .delivered,
    textType: .plain,
    ackCode: nil,
    pathLength: 0,
    snr: nil,
    senderKeyPrefix: nil,
    senderNodeName: nil,
    isRead: false,
    replyToID: replyToID,
    roundTripTime: nil,
    heardRepeats: 0,
    retryAttempt: 0,
    maxRetryAttempts: 0
  )
}

private func makeStore() throws -> PersistenceStore {
  PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
}

// MARK: - Search hits

@Suite("Chats list message search")
@MainActor
struct ChatListMessageSearchTests {
  @Test
  func `hits pair with their listed conversation and drop the rest`() {
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    let channel = makeChannel(radioID: radioID, index: 3, name: "Trail")
    let conversations: [Conversation] = [.direct(contact), .channel(channel)]

    let dm = makeMessage(radioID: radioID, contactID: contact.id, text: "meet at the trailhead", at: 30)
    let inChannel = makeMessage(radioID: radioID, channelIndex: 3, text: "trailhead closed", at: 20)
    let otherSlot = makeMessage(radioID: radioID, channelIndex: 7, text: "trailhead open", at: 10)
    let otherRadio = makeMessage(radioID: UUID(), channelIndex: 3, text: "trailhead", at: 5)

    let hits = MessageSearchHit.resolve(messages: [dm, inChannel, otherSlot, otherRadio], conversations: conversations)

    #expect(hits.map(\.message.id) == [dm.id, inChannel.id])
    #expect(hits[0].conversation == .direct(contact))
    #expect(hits[1].conversation == .channel(channel))
    #expect(hits[1].route == .channel(channel))
  }

  @Test
  func `the store searches every conversation of one radio`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let contactID = UUID()
    try await store.saveMessage(makeMessage(radioID: radioID, contactID: contactID, text: "Water at the Trailhead", at: 10))
    try await store.saveMessage(makeMessage(radioID: radioID, channelIndex: 2, text: "trailhead is closed", at: 20))
    try await store.saveMessage(makeMessage(radioID: radioID, channelIndex: 2, text: "nothing here", at: 30))
    try await store.saveMessage(makeMessage(radioID: UUID(), channelIndex: 2, text: "trailhead on another radio", at: 40))

    let hits = try await store.searchMessages(radioID: radioID, query: "TRAILHEAD", limit: 50)

    #expect(hits.map(\.text) == ["trailhead is closed", "Water at the Trailhead"])
    #expect(try await store.searchMessages(radioID: radioID, query: "   ", limit: 50).isEmpty)
  }

  @Test
  func `an empty query clears the hits without touching the store`() {
    let viewModel = ChatViewModel()
    viewModel.messageSearchHits = [
      MessageSearchHit(
        message: makeMessage(radioID: UUID(), channelIndex: 1, text: "x", at: 1),
        conversation: .channel(makeChannel(radioID: UUID(), index: 1, name: "X"))
      )
    ]
    viewModel.messageSearchQuery = "x"

    viewModel.searchMessages(query: "  ", radioID: UUID())

    #expect(viewModel.messageSearchHits.isEmpty)
    #expect(viewModel.messageSearchQuery.isEmpty)
  }

  @Test
  func `name search ignores the filter and matches case-insensitively`() {
    let radioID = UUID()
    let alice = Conversation.direct(makeContact(radioID: radioID, name: "Alice", unreadCount: 2))
    let trail = Conversation.channel(makeChannel(radioID: radioID, index: 1, name: "Trail"))

    #expect([alice, trail].filtered(by: .channels, searchText: "ali").map(\.displayName) == ["Alice"])
    #expect([alice, trail].filtered(by: .unread, searchText: "").map(\.displayName) == ["Alice"])
    #expect([alice, trail].filtered(by: .channels, searchText: "").map(\.displayName) == ["Trail"])
  }
}

// MARK: - Drafts

@Suite("Chats list draft previews")
@MainActor
struct ChatListDraftPreviewTests {
  private func scratchDefaults() throws -> UserDefaults {
    let suite = "ChatListDraftPreviewTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test
  func `rows preview the non-empty drafts of direct and channel conversations`() throws {
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    let channel = makeChannel(radioID: radioID, index: 4, name: "Trail")
    let silent = makeChannel(radioID: radioID, index: 5, name: "Quiet")
    let store = DraftStore(defaults: try scratchDefaults())
    store.setDraft("on my way\nback soon", for: .dm(radioID: radioID, contactID: contact.id))
    store.setDraft("  @[Bob] hello ", for: .channel(radioID: radioID, channelIndex: 4))
    store.setDraft("   ", for: .channel(radioID: radioID, channelIndex: 5))

    let previews = ChatViewModel.draftPreviews(
      for: [.direct(contact), .channel(channel), .channel(silent)],
      in: store
    )

    #expect(previews[contact.id] == "on my way back soon")
    #expect(previews[channel.id] == "@Bob hello")
    #expect(previews[silent.id] == nil)
  }

  @Test
  func `refreshing publishes the drafts for the listed conversations`() throws {
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    let store = DraftStore(defaults: try scratchDefaults())
    store.setDraft("draft", for: .dm(radioID: radioID, contactID: contact.id))

    let viewModel = ChatViewModel()
    viewModel.conversations = [contact]
    viewModel.recomputeSnapshot()
    viewModel.refreshDraftPreviews(from: store)
    #expect(viewModel.draftPreview(id: contact.id) == "draft")

    store.clearDraft(for: .dm(radioID: radioID, contactID: contact.id))
    viewModel.refreshDraftPreviews(from: store)
    #expect(viewModel.draftPreview(id: contact.id) == nil)
  }
}

// MARK: - Unread

@Suite("Chats list unread actions")
@MainActor
struct ChatListUnreadActionTests {
  @Test
  func `mark as unread flags a read conversation with one unread`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    try await store.saveContact(contact)
    let channel = makeChannel(radioID: radioID, index: 1, name: "Trail")
    try await store.saveChannel(channel)

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { store }))
    viewModel.conversations = [contact]
    viewModel.channels = [channel]
    viewModel.recomputeSnapshot()
    #expect(viewModel.unreadConversations.isEmpty)

    await viewModel.markAsUnread(.direct(contact))
    // The trailing reload has no radio to read, so it empties the buffers: seed again.
    viewModel.channels = [channel]
    viewModel.recomputeSnapshot()
    await viewModel.markAsUnread(.channel(channel))

    #expect(try await store.fetchContact(id: contact.id)?.unreadCount == 1)
    #expect(try await store.fetchChannel(id: channel.id)?.unreadCount == 1)
  }

  @Test
  func `mark as unread leaves an unread conversation alone`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice", unreadCount: 3)
    try await store.saveContact(contact)

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { store }))
    viewModel.conversations = [contact]
    viewModel.recomputeSnapshot()

    await viewModel.markAsUnread(.direct(contact))

    #expect(try await store.fetchContact(id: contact.id)?.unreadCount == 3)
  }

  @Test
  func `mark all as read clears every unread conversation`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = makeContact(radioID: radioID, name: "Alice", unreadCount: 2)
    let bob = makeContact(radioID: radioID, name: "Bob")
    let channel = makeChannel(radioID: radioID, index: 1, name: "Trail", unreadCount: 5)
    try await store.saveContact(alice)
    try await store.saveContact(bob)
    try await store.saveChannel(channel)

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { store }))
    viewModel.conversations = [alice, bob]
    viewModel.channels = [channel]
    viewModel.recomputeSnapshot()
    #expect(Set(viewModel.unreadConversations.map(\.id)) == [alice.id, channel.id])

    await viewModel.markAllAsRead()

    #expect(try await store.fetchContact(id: alice.id)?.unreadCount == 0)
    #expect(try await store.fetchChannel(id: channel.id)?.unreadCount == 0)
  }
}

// MARK: - Offline sends

@Suite("Offline send queue")
@MainActor
struct ChatOfflineSendQueueTests {
  @Test
  func `a direct message written offline is stored pending and queued for the radio`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    try await store.saveContact(contact)

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { store }))
    viewModel.currentContact = contact
    let coordinator = ChatCoordinator.makeForTesting()
    viewModel.bindCoordinatorForTesting(coordinator)

    await viewModel.sendMessage(text: "see you at camp")

    let stored = try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0)
    #expect(stored.map(\.text) == ["see you at camp"])
    #expect(stored.first?.status == .pending)
    #expect(stored.first?.isOutgoing == true)
    let queued = try await store.fetchPendingSends(radioID: radioID)
    #expect(queued.map(\.messageID) == stored.map(\.id))
    #expect(queued.first?.kind == .dm)
    #expect(viewModel.hasQueuedSends)
    #expect(viewModel.sendErrorMessage == nil)
  }

  @Test
  func `a channel message written offline keeps its slot and queues as a channel send`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let channel = makeChannel(radioID: radioID, index: 2, name: "Trail")
    try await store.saveChannel(channel)

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { store }))
    viewModel.currentChannel = channel
    viewModel.bindCoordinatorForTesting(ChatCoordinator.makeForTesting())

    await viewModel.sendChannelMessage(text: "trail is clear")

    let stored = try await store.fetchMessages(radioID: radioID, channelIndex: 2, limit: 10, offset: 0)
    #expect(stored.map(\.text) == ["trail is clear"])
    #expect(stored.first?.status == .pending)
    let queued = try await store.fetchPendingSends(radioID: radioID)
    #expect(queued.count == 1)
    #expect(queued.first?.kind == .channel)
    #expect(queued.first?.channelIndex == 2)
  }

  @Test
  func `deleting a queued message drops its queue row`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    try await store.saveContact(contact)
    let message = try await store.queueOfflineDirectMessage(text: "hold this", to: contact)

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { store }))
    viewModel.currentContact = contact
    viewModel.bindCoordinatorForTesting(ChatCoordinator.makeForTesting())

    await viewModel.deleteMessage(message)

    #expect(try await store.fetchMessage(id: message.id) == nil)
    #expect(try await store.fetchPendingSends(radioID: radioID).isEmpty)
    #expect(viewModel.errorMessage == nil)
  }
}

// MARK: - Reply quotes

@Suite("Reply quote target")
@MainActor
struct ReplyQuoteTargetTests {
  @Test
  func `a reply with a stored id jumps to it`() async {
    let original = UUID()
    let reply = makeMessage(radioID: UUID(), contactID: UUID(), text: "@[Bob]\n>hi\nhello", at: 10, replyToID: original)

    #expect(await ChatViewModel().quotedMessageID(for: reply) == original)
  }

  @Test
  func `without an id the newest earlier message opening with the quote wins`() throws {
    let radioID = UUID()
    let contactID = UUID()
    let older = makeMessage(radioID: radioID, contactID: contactID, text: "on the ridge now", at: 10)
    let newer = makeMessage(radioID: radioID, contactID: contactID, text: "on the ridge again", at: 20)
    let later = makeMessage(radioID: radioID, contactID: contactID, text: "on the ridge later", at: 40)
    let reply = makeMessage(radioID: radioID, contactID: contactID, text: "@[Bob]\n>on the ridge\nsame", at: 30, direction: .outgoing)
    let quote = try #require(ReplyQuote.parse(reply.text))

    let match = ChatViewModel.quotedMessage(matching: quote, reply: reply, in: [older, reply, newer, later])

    #expect(match?.id == newer.id)
  }

  @Test
  func `the store search uses the quote's first line`() {
    #expect(ChatViewModel.quoteSearchText("first line\nsecond") == "first line")
    #expect(ChatViewModel.quoteSearchText("only") == "only")
  }
}

// MARK: - Route persistence and selection

@Suite("Chat route persistence")
@MainActor
struct ChatRoutePersistenceTests {
  @Test
  func `routes round-trip as kind and id only`() throws {
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    let channel = makeChannel(radioID: radioID, index: 1, name: "Trail")

    let direct = ChatRoutePersistence.encode(.direct(contact))
    #expect(direct == "direct:\(contact.id.uuidString)")
    #expect(!direct.contains(contact.publicKey.map { String(format: "%02X", $0) }.joined()))
    let decoded = try #require(ChatRoutePersistence.decode(direct))
    #expect(decoded.kind == .direct && decoded.id == contact.id)

    let decodedChannel = try #require(ChatRoutePersistence.decode(ChatRoutePersistence.encode(.channel(channel))))
    #expect(decodedChannel.kind == .channel && decodedChannel.id == channel.id)

    #expect(ChatRoutePersistence.encode(nil) == "")
    #expect(ChatRoutePersistence.decode("") == nil)
    #expect(ChatRoutePersistence.decode("direct:not-a-uuid") == nil)
    #expect(ChatRoutePersistence.decode("tool:\(UUID().uuidString)") == nil)
  }

  @Test
  func `a persisted route resolves from the store for the current radio only`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, name: "Alice")
    try await store.saveContact(contact)
    let key = ChatRoutePersistence.encode(.direct(contact))

    #expect(await ChatRoutePersistence.resolve(key, radioID: radioID, store: store) == .direct(contact))
    #expect(await ChatRoutePersistence.resolve(key, radioID: UUID(), store: store) == nil)
    #expect(await ChatRoutePersistence.resolve("direct:\(UUID().uuidString)", radioID: radioID, store: store) == nil)
  }

  @Test
  func `select all keeps selection mode and takes every id`() {
    let selection = MessageSelectionModel()
    let first = UUID()
    let second = UUID()
    selection.selectAll([first, second])
    #expect(selection.count == 0, "Select All is a no-op outside selection mode")

    selection.begin(with: first)
    selection.selectAll([first, second])
    #expect(selection.isSelecting)
    #expect(selection.selectedIDs == [first, second])
  }
}
