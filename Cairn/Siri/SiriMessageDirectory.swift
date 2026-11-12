import Foundation
import CairnServices

/// A conversation as Siri needs it, carried across actors as a plain value.
struct SiriConversation: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case direct
    case channel
    case room
  }

  let id: UUID
  let name: String
  let kind: Kind
  let unreadCount: Int
  let isMuted: Bool
}

/// A message for Siri to read aloud. Spoken only: CarPlay never shows message text.
struct SiriMessage: Sendable, Equatable {
  /// `"<conversation>|<message>"`, so marking it read can find its conversation.
  let identifier: String
  let conversationID: UUID
  let content: String
  let date: Date
  /// Nil for the user's own messages.
  let senderName: String?
  /// The channel or room name; nil in a direct conversation.
  let groupName: String?

  static func identifier(conversationID: UUID, messageID: UUID) -> String {
    "\(conversationID.uuidString)|\(messageID.uuidString)"
  }

  static func conversationID(fromIdentifier identifier: String) -> UUID? {
    identifier.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
  }

  /// The one message an identifier names (a CarPlay message row), or nil for a plain
  /// conversation identifier.
  static func pinnedMessage(fromIdentifier identifier: String) -> (conversationID: UUID, messageID: UUID)? {
    let parts = identifier.split(separator: "|")
    guard parts.count == 2, let conversationID = UUID(uuidString: String(parts[0])),
          let messageID = UUID(uuidString: String(parts[1])) else { return nil }
    return (conversationID, messageID)
  }

  /// What marking an identifier read clears. A message Siri read from a CarPlay message row
  /// carries a `|pin` tail (`pinnedReadIdentifier`), so it only names that one message.
  enum ReadMark: Equatable {
    case conversation(UUID)
    case pinned(conversationID: UUID, messageID: UUID)
  }

  /// The identifier Siri gets for a message read from a CarPlay message row.
  static func pinnedReadIdentifier(conversationID: UUID, messageID: UUID) -> String {
    identifier(conversationID: conversationID, messageID: messageID) + "|pin"
  }

  static func readMark(fromIdentifier identifier: String) -> ReadMark? {
    let parts = identifier.split(separator: "|")
    guard let first = parts.first, let conversationID = UUID(uuidString: String(first)) else { return nil }
    if parts.count == 3, parts[2] == "pin", let messageID = UUID(uuidString: String(parts[1])) {
      return .pinned(conversationID: conversationID, messageID: messageID)
    }
    return .conversation(conversationID)
  }
}

/// Name matching for spoken recipients and group names: case, accents and a channel's leading
/// "#" never matter. Exact matches win over partial ones, so "Bob" does not also offer "Bobby".
enum SiriNameMatcher {
  static func normalized(_ name: String) -> String {
    var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasPrefix("#") {
      text.removeFirst()
    }
    return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  static func bestMatches(_ query: String, in candidates: [SiriConversation]) -> [SiriConversation] {
    let wanted = normalized(query)
    guard !wanted.isEmpty else { return [] }
    let exact = candidates.filter { normalized($0.name) == wanted }
    if !exact.isEmpty { return exact }
    return candidates.filter { normalized($0.name).contains(wanted) }
  }
}

/// Whether a Siri send can go ahead now, should wait for the radio, or cannot happen at all.
/// Pure over the send route, so the tests pin it without a radio.
enum SiriSendReadiness: Equatable {
  case ready
  /// The link is coming up, or a known radio should reconnect: worth a short wait.
  case wait
  /// No radio to reconnect to.
  case unavailable

  static func of(_ route: SendRoute, hasRestorableRadio: Bool) -> Self {
    switch route {
    case .headlessQueue, .queueAfterSync: .ready
    case .foregroundEscalate: .wait
    case .notConnected: hasRestorableRadio ? .wait : .unavailable
    }
  }
}

/// The mesh's text limits, checked while Siri is still collecting the message so it can ask
/// again rather than fail after the driver confirmed.
enum SiriMessageLimits {
  static func fits(_ text: String, kind: SiriConversation.Kind, nodeNameByteCount: Int) -> Bool {
    switch kind {
    case .direct: text.utf8.count <= ProtocolLimits.maxDirectMessageLength
    case .channel: text.utf8.count <= ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: nodeNameByteCount)
    // Rooms are read-only for Siri; resolution rejects them for that reason, not length.
    case .room: true
    }
  }
}

/// The app's conversations and messages for the Siri messaging intents, read from the same store
/// the Chats tab uses and sent through the same durable queue as the Send Message shortcut. Works
/// while the phone is locked after its first unlock, which is when CarPlay runs, and when Siri
/// started the app in the background with no screen at all.
@MainActor
enum SiriMessageDirectory {
  /// Messages read per conversation; Siri reads them aloud, so fewer is kinder.
  static let messagesPerConversation = 5
  /// Messages read in one request across conversations.
  static let maxMessages = 20

  /// How long a Siri request waits for the app to launch and the radio to come back. Siri
  /// allows a request roughly ten seconds, and a spoken failure beats a timeout.
  static let readyTimeout: Duration = .seconds(8)
  private static let pollInterval: Duration = .milliseconds(250)

  private static var appState: AppState? {
    AppLaunchController.current?.intentBridge.appState
  }

  // MARK: - Launch

  /// Siri can start the app in the background with no scene at all, and only scenes run the
  /// launch sequence. Without it the store is the only source and the radio never reconnects,
  /// so every request starts it (once per process) and waits for it, up to `deadline`. The
  /// launch keeps going if the wait gives up, so the next request finds it done.
  @discardableResult
  static func ensureLaunched(until deadline: ContinuousClock.Instant = .now + readyTimeout) async -> AppState? {
    guard let launch = AppLaunchController.current else { return nil }
    if !launch.hasLaunched {
      Task { await launch.launchOnce() }
      while !launch.hasLaunched, ContinuousClock.now < deadline {
        try? await Task.sleep(for: pollInterval)
      }
    }
    return appState
  }

  /// The app state once the radio can take a message, waiting a few seconds for a link that is
  /// coming up or a known radio that should reconnect (the phone is likely locked in a bag, so
  /// nobody can open the app to help). Nil when it can't within `readyTimeout`.
  static func readyToSend() async -> AppState? {
    let deadline = ContinuousClock.now + readyTimeout
    guard await ensureLaunched(until: deadline) != nil else { return nil }
    while let appState {
      let readiness = SiriSendReadiness.of(
        SendMessageIntent.route(for: appState.connectionState),
        hasRestorableRadio: appState.connectionManager.lastConnectedRadioID != nil
      )
      switch readiness {
      case .ready: return appState
      case .unavailable: return nil
      case .wait:
        guard ContinuousClock.now < deadline else { return nil }
        try? await Task.sleep(for: pollInterval)
      }
    }
    return nil
  }

  // MARK: - Conversations

  private static func liveConversations() async -> [Conversation] {
    guard let appState, let store = appState.offlineDataStore, let radioID = appState.currentRadioID else { return [] }
    do {
      let contacts = try await store.fetchConversations(radioID: radioID)
      let channels = try await store.fetchChannels(radioID: radioID)
      let rooms = try await store.fetchRemoteNodeSessions(radioID: radioID).filter(\.isRoom)
      return contacts.filter { !$0.isBlocked }.map(Conversation.direct)
        + channels.map(Conversation.channel)
        + rooms.map(Conversation.room)
    } catch {
      return []
    }
  }

  private static func value(_ conversation: Conversation) -> SiriConversation {
    let kind: SiriConversation.Kind = switch conversation {
    case .direct: .direct
    case .channel: .channel
    case .room: .room
    }
    return SiriConversation(
      id: conversation.id,
      name: conversation.displayName,
      kind: kind,
      unreadCount: conversation.unreadCount,
      isMuted: conversation.isMuted
    )
  }

  static func conversations() async -> [SiriConversation] {
    await liveConversations().map(value)
  }

  /// People a message can go to: chat contacts only, never a repeater or a room server.
  static func people() async -> [SiriConversation] {
    await liveConversations().compactMap { conversation in
      guard case let .direct(contact) = conversation, contact.type == .chat else { return nil }
      return value(conversation)
    }
  }

  static func channels() async -> [SiriConversation] {
    await conversations().filter { $0.kind == .channel }
  }

  static func isAvailable() async -> Bool {
    await ensureLaunched() != nil
  }

  static func kind(of id: UUID) async -> SiriConversation.Kind? {
    await conversations().first { $0.id == id }?.kind
  }

  /// Whether `text` fits the conversation's limit on the current radio. Unknown conversations
  /// pass: `send` fails them plainly.
  static func fits(_ text: String, inConversation id: UUID) async -> Bool {
    guard let kind = await kind(of: id) else { return true }
    let nodeNameByteCount = appState?.connectedDevice?.nodeName.utf8.count ?? 0
    return SiriMessageLimits.fits(text, kind: kind, nodeNameByteCount: nodeNameByteCount)
  }

  // MARK: - Send

  enum SendResult: Sendable, Equatable {
    case queued
    /// No radio could take it in time: Siri says the service is unavailable.
    case notConnected
    case failed
  }

  /// Queues `text` to a contact or channel through `SendMessageIntent.performSend`, so Siri,
  /// Shortcuts and the Chats tab share one send path. A radio that is not ready within
  /// `readyTimeout` fails plainly: Siri says so, and nothing asks the driver to open the phone.
  static func send(text: String, toConversation id: UUID) async -> SendResult {
    guard let appState = await readyToSend() else { return .notConnected }
    guard let conversation = await liveConversations().first(where: { $0.id == id }) else { return .failed }
    let recipient: MessageRecipient
    switch conversation {
    case let .direct(contact): recipient = .contact(contact)
    case let .channel(channel): recipient = .channel(channel)
    case .room: return .failed
    }
    do {
      let nodeNameByteCount = appState.connectedDevice?.nodeName.utf8.count ?? 0
      try SendMessageIntent.validate(message: text, for: recipient, nodeNameByteCount: nodeNameByteCount)
      let outcome = try await SendMessageIntent.performSend(message: text, recipient: recipient, in: appState)
      return outcome == .queued ? .queued : .notConnected
    } catch {
      return .failed
    }
  }

  // MARK: - Read

  /// The newest messages in `ids`, or with `unreadOnly` the unread ones in conversations that
  /// notify. Oldest first, as Siri reads them.
  static func messages(inConversations ids: Set<UUID>?, unreadOnly: Bool) async -> [SiriMessage] {
    guard let appState = await ensureLaunched(), let store = appState.offlineDataStore else { return [] }
    var conversations = await liveConversations()
    if let ids {
      conversations = conversations.filter { ids.contains($0.id) }
    }
    if unreadOnly {
      conversations = conversations.filter { $0.unreadCount > 0 && !$0.isMuted }
    }

    var result: [SiriMessage] = []
    let names = await senderNames(store: store)
    for conversation in conversations where result.count < maxMessages {
      let wanted = unreadOnly ? min(conversation.unreadCount, messagesPerConversation) : messagesPerConversation
      let messages = await recentMessages(conversation, limit: wanted, incomingOnly: unreadOnly, store: store, names: names)
      result.append(contentsOf: messages.prefix(maxMessages - result.count))
    }
    return result.sorted { $0.date < $1.date }
  }

  /// One message of a conversation, for a CarPlay message row. Nil when it is gone, belongs to
  /// another conversation, or is a reaction the chat view hides.
  static func message(_ messageID: UUID, inConversation id: UUID) async -> SiriMessage? {
    guard let appState = await ensureLaunched(), let store = appState.offlineDataStore,
          let conversation = await liveConversations().first(where: { $0.id == id }) else { return nil }
    switch conversation {
    case let .direct(contact):
      guard let message = try? await store.fetchMessage(id: messageID), message.contactID == contact.id,
            !message.isHiddenOutgoingReaction(isDM: true) else { return nil }
      return siriMessage(message, contact: contact)
    case let .channel(channel):
      guard let message = try? await store.fetchMessage(id: messageID),
            message.radioID == channel.radioID, message.channelIndex == channel.index,
            !message.isHiddenOutgoingReaction(isDM: false) else { return nil }
      return siriMessage(message, channel: channel, names: await senderNames(store: store))
    case let .room(session):
      guard let message = try? await store.fetchRoomMessage(id: messageID), message.sessionID == session.id else { return nil }
      return siriMessage(message, session: session, names: await senderNames(store: store))
    }
  }

  /// The current radio's contacts indexed for naming senders, read fresh: Siri can run before the
  /// app has built its own tables.
  private static func senderNames(store: PersistenceStore) async -> ContactNameDirectory {
    guard let radioID = appState?.currentRadioID,
          let contacts = try? await store.fetchContacts(radioID: radioID) else { return .empty }
    return ContactNameDirectory(contacts: contacts)
  }

  private static func siriMessage(_ message: MessageDTO, contact: ContactDTO) -> SiriMessage {
    SiriMessage(
      identifier: SiriMessage.identifier(conversationID: contact.id, messageID: message.id),
      conversationID: contact.id,
      content: MessagePreviewFormatter.preview(message.text),
      date: message.sortDate,
      senderName: message.direction == .incoming ? contact.displayName : nil,
      groupName: nil
    )
  }

  /// A channel message: someone else's always names a sender (nil reads as the user's own), as
  /// notifications name it ("Dad (Frank Wilson)"), or "Unknown" when it carried no name.
  static func siriMessage(_ message: MessageDTO, channel: ChannelDTO, names: ContactNameDirectory) -> SiriMessage {
    let sender: String? = if message.direction == .incoming {
      names.channelSenders.labeledName(for: message.senderNodeName) { nickname, wireName in
        L10n.Chats.Chats.Message.Sender.unverifiedLabel(nickname, wireName)
      } ?? L10n.Chats.Chats.Message.Sender.unknown
    } else {
      nil
    }
    return SiriMessage(
      identifier: SiriMessage.identifier(conversationID: channel.id, messageID: message.id),
      conversationID: channel.id,
      content: MessagePreviewFormatter.preview(message.text),
      date: message.sortDate,
      senderName: sender,
      groupName: channel.displayName
    )
  }

  /// A room post: its author resolved from the key prefix now (an unknown one by key, never left
  /// out, which would read as the user's own), dated by the post's own time.
  static func siriMessage(_ message: RoomMessageDTO, session: RemoteNodeSessionDTO, names: ContactNameDirectory) -> SiriMessage {
    let identity = names.roomAuthors.resolve(
      message, roomPublicKey: session.publicKey, roomName: session.name, selfName: ""
    )
    let sender = identity.isKeyOnly ? L10n.Chats.Chats.Message.Sender.unknownAuthor(identity.keyPrefixHex) : identity.displayName
    return SiriMessage(
      identifier: SiriMessage.identifier(conversationID: session.id, messageID: message.id),
      conversationID: session.id,
      content: MessagePreviewFormatter.preview(message.text),
      date: message.postDate,
      senderName: message.isFromSelf ? nil : sender,
      groupName: session.name
    )
  }

  private static func recentMessages(
    _ conversation: Conversation,
    limit: Int,
    incomingOnly: Bool,
    store: PersistenceStore,
    names: ContactNameDirectory = .empty
  ) async -> [SiriMessage] {
    guard limit > 0 else { return [] }
    // Read a little past the limit so skipped reactions and own messages don't shorten it.
    let fetchLimit = limit + 10
    switch conversation {
    case let .direct(contact):
      let messages = (try? await store.fetchMessages(contactID: contact.id, limit: fetchLimit, offset: 0)) ?? []
      return messages
        .filter { ReactionParser.parseDM($0.text) == nil && (!incomingOnly || $0.direction == .incoming) }
        .suffix(limit)
        .map { siriMessage($0, contact: contact) }
    case let .channel(channel):
      let messages = (try? await store.fetchMessages(
        radioID: channel.radioID,
        channelIndex: channel.index,
        limit: fetchLimit,
        offset: 0
      )) ?? []
      return messages
        .filter { ReactionParser.parse($0.text) == nil && (!incomingOnly || $0.direction == .incoming) }
        .suffix(limit)
        .map { siriMessage($0, channel: channel, names: names) }
    case let .room(session):
      let messages = (try? await store.fetchRoomMessages(sessionID: session.id, limit: nil, offset: nil)) ?? []
      return messages
        .filter { !incomingOnly || !$0.isFromSelf }
        .suffix(limit)
        .map { siriMessage($0, session: session, names: names) }
    }
  }

  // MARK: - Mark read

  /// Whether `messageID` is the newest incoming message of a conversation, so reading it alone
  /// leaves nothing unread there.
  static func isNewestIncoming(_ messageID: UUID, inConversation id: UUID) async -> Bool {
    guard let appState = await ensureLaunched(), let store = appState.offlineDataStore,
          let conversation = await liveConversations().first(where: { $0.id == id }) else { return false }
    let newest = await recentMessages(conversation, limit: 1, incomingOnly: true, store: store)
    return newest.last?.identifier == SiriMessage.identifier(conversationID: id, messageID: messageID)
  }

  /// Clears unread state the way the Chats list's Mark as Read does: counts, mentions, delivered
  /// notifications, then the badge. Returns false when nothing matched.
  static func markRead(conversations ids: Set<UUID>) async -> Bool {
    guard let appState = await ensureLaunched(), let store = appState.offlineDataStore else { return false }
    let notificationService = appState.services?.notificationService
    let matches = await liveConversations().filter { ids.contains($0.id) }
    guard !matches.isEmpty else { return false }
    do {
      for conversation in matches where conversation.unreadCount > 0 {
        switch conversation {
        case let .direct(contact):
          try await store.clearUnreadCount(contactID: contact.id)
          try await store.clearUnreadMentionCount(contactID: contact.id)
          await notificationService?.removeDeliveredNotifications(forContactID: contact.id)
        case let .channel(channel):
          try await store.clearChannelUnreadCount(channelID: channel.id)
          try await store.clearChannelUnreadMentionCount(channelID: channel.id)
          await notificationService?.removeDeliveredNotifications(forChannelIndex: channel.index, radioID: channel.radioID)
        case let .room(session):
          try await store.resetRoomUnreadCount(session.id)
          await notificationService?.removeDeliveredNotifications(forRoomSessionID: session.id)
        }
      }
    } catch {
      return false
    }
    await notificationService?.updateBadgeCount()
    appState.refreshConversations()
    return true
  }
}
