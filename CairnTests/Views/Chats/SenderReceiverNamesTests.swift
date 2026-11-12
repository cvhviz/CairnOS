import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// Sender and receiver names on every surface outside the bubble: list rows, Home, CarPlay, Siri,
/// search, reactions, room posts and their actions, replies and forwards. Seeds the mock data's
/// "Frank Wilson" with nickname "Dad", as screenshot mode does.
@MainActor
@Suite("Sender and receiver names")
struct SenderReceiverNamesTests {
  private let radioID = UUID()
  private let frankKey = Data([0x60, 0x61, 0x62, 0x63] + Array(repeating: 0x60, count: 28))
  private let hannahKey = Data([0x50, 0x51, 0x52, 0x53] + Array(repeating: 0x50, count: 28))
  private let roomKey = Data([0x9A, 0x9B, 0x9C, 0x9D] + Array(repeating: 0x9A, count: 28))

  private func contact(_ name: String, key: Data, nickname: String? = nil, id: UUID = UUID()) -> ContactDTO {
    ContactDTO(
      id: id, radioID: radioID, publicKey: key, name: name, typeRawValue: ContactType.chat.rawValue,
      flags: 0, outPathLength: 0, outPath: Data(), lastAdvertTimestamp: 0, latitude: 0, longitude: 0,
      lastModified: 0, lastHeardTimestamp: nil, nickname: nickname, isBlocked: false, isMuted: false,
      isFavorite: false, lastMessageDate: nil, unreadCount: 0
    )
  }

  private var names: ContactNameDirectory {
    ContactNameDirectory(contacts: [
      contact("Frank Wilson", key: frankKey, nickname: "Dad"),
      contact("Hannah Lee", key: hannahKey)
    ])
  }

  private func channelMessage(sender: String?, text: String = "Heading up the ridge", outgoing: Bool = false) -> MessageDTO {
    MessageDTO(
      id: UUID(), radioID: radioID, contactID: nil, channelIndex: 1, text: text, timestamp: 1_760_000_000,
      createdAt: Date(), direction: outgoing ? .outgoing : .incoming, status: .delivered, textType: .plain,
      ackCode: nil, pathLength: 0, snr: nil, senderKeyPrefix: nil, senderNodeName: sender, isRead: true,
      replyToID: nil, roundTripTime: nil, heardRepeats: 0, retryAttempt: 0, maxRetryAttempts: 0
    )
  }

  private func roomPost(prefix: Data, storedName: String? = nil, isFromSelf: Bool = false, text: String = "Trail is clear") -> RoomMessageDTO {
    RoomMessageDTO(
      sessionID: UUID(), authorKeyPrefix: prefix.prefix(4), authorName: storedName, text: text,
      timestamp: 1_760_000_000, isFromSelf: isFromSelf
    )
  }

  private var room: RemoteNodeSessionDTO {
    RemoteNodeSessionDTO(radioID: radioID, publicKey: roomKey, name: "Diana's Room", role: .roomServer, isConnected: true, permissionLevel: .readWrite)
  }

  // MARK: - Chats list rows

  @Test
  func `a channel row names its last sender by nickname and reads mentions as the bubble does`() {
    let viewModel = ChatViewModel()
    let channelID = UUID()
    viewModel.listSenderNames = names
    viewModel.lastMessageCache[channelID] = channelMessage(sender: "Frank Wilson", text: "@[Basecamp] heading up")

    #expect(viewModel.lastMessageSender(id: channelID) == "Dad")
    #expect(viewModel.lastMessagePreview(id: channelID) == "@Basecamp heading up")

    viewModel.lastMessageCache[channelID] = channelMessage(sender: "Frank Wilson", outgoing: true)
    #expect(viewModel.lastMessageSender(id: channelID) == L10n.Chats.Chats.Path.Receiver.you)
  }

  @Test
  func `a room row previews its last post as Author: text`() {
    let viewModel = ChatViewModel()
    let session = room
    viewModel.roomSessions = [session]
    viewModel.listSenderNames = names
    viewModel.lastRoomPostCache[session.id] = roomPost(prefix: hannahKey)
    #expect(viewModel.lastMessageSender(id: session.id) == "Hannah Lee")
    #expect(viewModel.lastMessagePreview(id: session.id) == "Trail is clear")

    viewModel.lastRoomPostCache[session.id] = roomPost(prefix: Data(repeating: 0, count: 4), storedName: "Me", isFromSelf: true)
    #expect(viewModel.lastMessageSender(id: session.id) == L10n.Chats.Chats.Path.Receiver.you)
  }

  // MARK: - Home

  @Test
  func `the Home card names a channel sender by nickname and a room author by key`() {
    var line = HomeDashboardModel.ConversationLine(id: UUID(), name: "Trail Crew", date: Date(), preview: "Heading up", isUnread: false, kind: .channel)
    line.previewAuthor = .channelSender("Frank Wilson")
    #expect(line.previewLine(names: names) == L10n.Localizable.Home.Chats.preview("Dad", "Heading up"))

    var roomLine = HomeDashboardModel.ConversationLine(id: room.id, name: room.name, date: Date(), preview: "Trail is clear", isUnread: false, kind: .room)
    roomLine.previewAuthor = .roomPost(roomPost(prefix: hannahKey), roomPublicKey: roomKey, roomName: room.name)
    #expect(roomLine.previewLine(names: names) == L10n.Localizable.Home.Chats.preview("Hannah Lee", "Trail is clear"))

    let direct = HomeDashboardModel.ConversationLine(id: UUID(), name: "Alice", date: Date(), preview: "hi", isUnread: false)
    #expect(direct.previewLine(names: names) == "hi")
  }

  // MARK: - CarPlay

  @Test
  func `CarPlay names a channel sender by nickname`() {
    let message = CarPlayChatsSource.message(channelMessage(sender: "Frank Wilson"), isDM: false, names: names)
    #expect(message?.sender == "Dad")
  }

  @Test
  func `CarPlay never names the channel as the author of a nameless message`() {
    for sender in [nil, ""] as [String?] {
      let message = CarPlayChatsSource.message(channelMessage(sender: sender), isDM: false)
      #expect(message?.sender == L10n.Chats.Chats.Message.Sender.unknown)
      let line = HomeDashboardModel.ConversationLine(id: UUID(), name: "Public", date: Date(), preview: nil, isUnread: false, kind: .channel)
      let row = CarPlayChatsSource.row(try! #require(message), in: line, isUnread: false, now: Date())
      #expect(row.sender != "Public")
      #expect(row.sender == L10n.Chats.Chats.Message.Sender.unknown)
    }
    let dmLine = HomeDashboardModel.ConversationLine(id: UUID(), name: "Alice", date: Date(), preview: nil, isUnread: false, kind: .direct)
    let dm = CarPlayChatsSource.Message(id: UUID(), isOutgoing: false, sender: nil, date: Date())
    #expect(CarPlayChatsSource.row(dm, in: dmLine, isUnread: false, now: Date()).sender == "Alice")
  }

  @Test
  func `CarPlay names a room author from the key and dates the post by its own clock`() {
    let known = CarPlayChatsSource.message(roomPost(prefix: frankKey, storedName: "Frank Wilson"), room: room, names: names)
    #expect(known.sender == "Dad")
    #expect(known.date == Date(timeIntervalSince1970: 1_760_000_000))
    let unknown = CarPlayChatsSource.message(roomPost(prefix: Data([0xDE, 0xAD, 0xBE, 0xEF])), room: room, names: names)
    #expect(unknown.sender == L10n.Chats.Chats.Message.Sender.unknownAuthor("DEADBEEF"))
  }

  // MARK: - Siri

  @Test
  func `Siri reads a channel sender with the nickname and never leaves a sender out`() {
    let channel = ChannelDTO(id: UUID(), radioID: radioID, index: 1, name: "Trail Crew", secret: Data(repeating: 1, count: 16),
                             isEnabled: true, lastMessageDate: nil, unreadCount: 0)
    let named = SiriMessageDirectory.siriMessage(channelMessage(sender: "Frank Wilson"), channel: channel, names: names)
    #expect(named.senderName == L10n.Chats.Chats.Message.Sender.unverifiedLabel("Dad", "Frank Wilson"))
    let nameless = SiriMessageDirectory.siriMessage(channelMessage(sender: nil), channel: channel, names: names)
    #expect(nameless.senderName == L10n.Chats.Chats.Message.Sender.unknown)
    let mine = SiriMessageDirectory.siriMessage(channelMessage(sender: nil, outgoing: true), channel: channel, names: names)
    #expect(mine.senderName == nil)
  }

  @Test
  func `Siri names an unknown room author by key, not as the user`() {
    let post = SiriMessageDirectory.siriMessage(roomPost(prefix: Data([0xDE, 0xAD, 0xBE, 0xEF])), session: room, names: names)
    #expect(post.senderName == L10n.Chats.Chats.Message.Sender.unknownAuthor("DEADBEEF"))
    let mine = SiriMessageDirectory.siriMessage(roomPost(prefix: Data(repeating: 0, count: 4), storedName: "Me", isFromSelf: true), session: room, names: names)
    #expect(mine.senderName == nil)
  }

  // MARK: - Reactions

  @Test
  func `the reactions list names each reactor as they are now`() {
    let frankID = UUID()
    let directory = ContactNameDirectory(contacts: [contact("Frank Wilson", key: frankKey, nickname: "Dad", id: frankID)])
    let mine = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Basecamp", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID, isFromSelf: true)
    let dm = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Frank Wilson", messageHash: "h", rawText: "r", contactID: frankID, radioID: radioID)
    let channel = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Frank Wilson", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID)
    let nameless = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID)

    #expect(ReactionDetailsSheet.reactorName(mine, names: directory) == L10n.Chats.Chats.Path.Receiver.you)
    #expect(ReactionDetailsSheet.reactorName(dm, names: directory) == "Dad")
    #expect(ReactionDetailsSheet.reactorName(channel, names: directory) == L10n.Chats.Chats.Message.Sender.unverifiedLabel("Dad", "Frank Wilson"))
    #expect(ReactionDetailsSheet.reactorName(nameless, names: directory) == L10n.Chats.Chats.Message.Sender.unknown)
  }

  // MARK: - Replies

  @Test
  func `a channel message with no sender name offers no Reply`() {
    #expect(!MessageActionAvailability(message: channelMessage(sender: nil)).canReply)
    #expect(!MessageActionAvailability(message: channelMessage(sender: " ")).canReply)
    #expect(MessageActionAvailability(message: channelMessage(sender: "Frank Wilson")).canReply)
  }

  // MARK: - Forwarding

  @Test
  func `a forward names the original author in plain text, not as a mention`() {
    let format: (String, String) -> String = { L10n.Chats.Chats.Forward.attribution($0, $1) }
    let forwarded = ForwardedDraft.attributed(text: "on the ridge", sender: "Frank Wilson", format: format)
    #expect(forwarded == L10n.Chats.Chats.Forward.attribution("Frank Wilson", "on the ridge"))
    #expect(!forwarded.contains("@["))

    let reply = MentionUtilities.buildReplyText(mentionName: "Carol", messageText: "where are you") + "at the hut"
    #expect(ForwardedDraft.attributed(text: reply, sender: "Frank Wilson", format: format)
      == L10n.Chats.Chats.Forward.attribution("Frank Wilson", "at the hut"))
    #expect(ForwardedDraft.attributed(text: "my own words", sender: nil, format: format) == "my own words")
  }

  // MARK: - Rooms

  @Test
  func `room actions follow the author's key, not the name saved at receipt`() {
    let resolver = names.roomAuthors
    // Saved before the author was a contact: no name then, a contact now.
    let later = roomPost(prefix: hannahKey)
    let laterAuthor = resolver.resolve(later, roomPublicKey: roomKey, roomName: room.name, selfName: "You")
    let available = RoomMessageActionAvailability(message: later, session: room, author: laterAuthor)
    #expect(available.canSendDM)
    #expect(available.canReply)
    #expect(laterAuthor.advertisedName == "Hannah Lee")

    // A nicknamed author is mentioned by the name they advertise, never the nickname.
    let frank = resolver.resolve(roomPost(prefix: frankKey, storedName: "Dad"), roomPublicKey: roomKey, roomName: room.name, selfName: "You")
    #expect(frank.displayName == "Dad")
    #expect(frank.advertisedName == "Frank Wilson")

    // An unknown author can't be mentioned or messaged.
    let stranger = roomPost(prefix: Data([0xDE, 0xAD, 0xBE, 0xEF]))
    let strangerAuthor = resolver.resolve(stranger, roomPublicKey: roomKey, roomName: room.name, selfName: "You")
    let none = RoomMessageActionAvailability(message: stranger, session: room, author: strangerAuthor)
    #expect(!none.canReply)
    #expect(!none.canSendDM)
  }

  @Test
  func `an unknown room author is announced as unknown, not read out as a name`() {
    let post = roomPost(prefix: Data([0xDE, 0xAD, 0xBE, 0xEF]))
    let author = RoomAuthorResolver.empty.resolve(post, roomPublicKey: roomKey, roomName: room.name, selfName: "You")
    let bubble = RoomMessageBubble(message: post, showTimestamp: false, showSenderName: true, showAvatar: true, author: author)
    #expect(bubble.accessibilityMessageLabel == "\(L10n.Chats.Chats.Message.Sender.unknownAuthorAccessibility("DEADBEEF")): Trail is clear")
  }

  @Test
  func `my own room post reads as me even when stored as Me`() {
    let post = roomPost(prefix: Data(repeating: 0, count: 4), storedName: "Me", isFromSelf: true)
    let author = names.roomAuthors.resolve(post, roomPublicKey: roomKey, roomName: room.name, selfName: L10n.Chats.Chats.Path.Receiver.you)
    #expect(author.displayName == L10n.Chats.Chats.Path.Receiver.you)
  }

  @Test
  func `a room author link carries the key prefix`() throws {
    let url = try #require(MentionDeeplinkSupport.url(forKeyPrefix: Data([0x50, 0x51, 0x52, 0x53])))
    #expect(url.absoluteString == "cairn://node/50515253")
    #expect(MentionDeeplinkSupport.keyPrefix(from: url) == Data([0x50, 0x51, 0x52, 0x53]))
    #expect(MentionDeeplinkSupport.name(from: url) == nil)
    #expect(MentionDeeplinkSupport.keyPrefix(from: try #require(MentionDeeplinkSupport.url(forName: "Frank"))) == nil)
  }
}
