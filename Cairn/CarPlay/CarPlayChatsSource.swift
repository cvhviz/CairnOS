import Foundation
import CairnServices

/// The Comm tab's message facts, read from the store the way the phone's chat view reads them
/// (newest messages, the user's sent reactions hidden), kept as plain values with no text: who
/// wrote, when, how a message arrived and how the user's own message went. Message text is only
/// looked at here to hide reactions, and never leaves this file. The builders are pure, so the
/// tests pin every row; the loaders are the only part that touches the store.
enum CarPlayChatsSource {
  /// How the user's own message went, as the phone's bubble footer shows it.
  enum Delivery: Equatable {
    case sending
    case retrying
    /// A channel message the radio sent, with no repeat heard yet.
    case sent
    /// Heard repeated by this many repeaters.
    case heard(Int)
    /// Acknowledged by the recipient or the room server.
    case delivered
    case failed

    /// Heard by a repeater or acknowledged: the mark a conversation row carries.
    var isConfirmed: Bool {
      switch self {
      case .heard, .delivered: true
      case .sending, .retrying, .sent, .failed: false
      }
    }
  }

  /// One message as the car may describe it. There is no field for its text.
  struct Message: Equatable, Identifiable {
    let id: UUID
    let isOutgoing: Bool
    /// Who wrote an incoming channel or room message, named as the phone names them (a channel
    /// sender by nickname when one contact has that name; "Unknown" when the message carried no
    /// name); nil for a direct chat (the conversation's name says who) and for the user's own.
    let sender: String?
    let date: Date
    /// The hops an incoming flood message came over; nil when it was routed direct, or for the
    /// user's own.
    var hops: Int?
    var snr: Double?
    /// How the user's own message went; nil for an incoming one.
    var delivery: Delivery?
  }

  /// What a conversation's row says about its latest messages.
  struct Activity: Equatable {
    /// The newest message the phone's chat view shows.
    var last: Message?
    /// How the user's newest sent message went, within the messages read.
    var lastSent: Delivery?
  }

  /// Messages read per conversation for its row: enough to find the user's last sent message
  /// past a few replies, few enough to read twelve conversations at once.
  static let activityFetchLimit = 8
  /// Extra messages read for a conversation's screen, so hidden reactions don't shorten it.
  static let reactionSlack = 10

  // MARK: - Pure

  /// The bubble's delivery state. A direct message the radio only queued (`.sent`) may still
  /// fail for want of an ACK, so it reads as sending, as the phone's bubble shows it; a channel's
  /// `.sent` is final.
  static func delivery(status: MessageStatus, heardRepeats: Int, isChannel: Bool) -> Delivery {
    switch status {
    case .pending, .sending: .sending
    case .retrying: .retrying
    case .sent: heardRepeats > 0 ? .heard(heardRepeats) : (isChannel ? .sent : .sending)
    case .delivered: .delivered
    case .failed: .failed
    }
  }

  /// A direct or channel message, or nil for one the phone's chat view hides (a sent reaction).
  static func message(_ dto: MessageDTO, isDM: Bool, names: ContactNameDirectory = .empty) -> Message? {
    guard !dto.isHiddenOutgoingReaction(isDM: isDM) else { return nil }
    guard !dto.isOutgoing else {
      return Message(
        id: dto.id,
        isOutgoing: true,
        sender: nil,
        date: dto.sortDate,
        delivery: delivery(status: dto.status, heardRepeats: dto.heardRepeats, isChannel: !isDM)
      )
    }
    // A channel message with no "name: " prefix (another client, a raw packet) has no known
    // author: never the channel's own name.
    let sender = isDM ? nil : names.channelSenders.shortName(for: dto.senderNodeName) ?? L10n.Chats.Chats.Message.Sender.unknown
    return Message(
      id: dto.id,
      isOutgoing: false,
      sender: sender,
      date: dto.sortDate,
      hops: dto.isFloodRouted ? dto.hopCount : nil,
      snr: dto.snr
    )
  }

  /// A room message: its author, or how the room server took the user's own. A room's `.sent`
  /// is final (every retry spent, likely reached the server), as the phone's room view shows it.
  /// The author is resolved from the post's key prefix against the radio's contacts now (an
  /// unknown one reads "Unknown (50515253)"), and the date is the post's own time on the room's
  /// clock, so a backlog pushed at login doesn't all read "now".
  static func message(
    _ dto: RoomMessageDTO,
    room: RemoteNodeSessionDTO? = nil,
    names: ContactNameDirectory = .empty
  ) -> Message {
    let identity = names.roomAuthors.resolve(
      dto, roomPublicKey: room?.publicKey, roomName: room?.name, selfName: L10n.Localizable.CarPlay.Chats.you
    )
    let sender = identity.isKeyOnly ? L10n.Chats.Chats.Message.Sender.unknownAuthor(identity.keyPrefixHex) : identity.displayName
    return Message(
      id: dto.id,
      isOutgoing: dto.isFromSelf,
      sender: dto.isFromSelf ? nil : sender,
      date: dto.postDate,
      delivery: dto.isFromSelf ? delivery(status: dto.status, heardRepeats: 0, isChannel: true) : nil
    )
  }

  /// The row's facts from a conversation's messages, newest first.
  static func activity(_ newestFirst: [Message]) -> Activity {
    Activity(
      last: newestFirst.first,
      lastSent: newestFirst.first(where: \.isOutgoing)?.delivery
    )
  }

  /// "2 repeats", in the bubble footer's words.
  static func repeats(_ count: Int) -> String {
    let word = count == 1 ? L10n.Chats.Chats.Message.Repeat.singular : L10n.Chats.Chats.Message.Repeat.plural
    return "\(count.formatted()) \(word)"
  }

  /// The delivery state in the bubble's words; a confirmed one leads with a check mark.
  static func deliveryText(_ delivery: Delivery) -> String {
    switch delivery {
    case .sending: L10n.Chats.Chats.Message.Status.sending
    case .retrying: L10n.Chats.Chats.Message.Status.retrying
    case .sent: L10n.Chats.Chats.Message.Status.sent
    case let .heard(count): "\u{2713} " + repeats(count)
    case .delivered: "\u{2713} " + L10n.Chats.Chats.Message.Status.delivered
    case .failed: L10n.Chats.Chats.Message.Status.failed
    }
  }

  /// "Direct" or "3 hops", then "SNR 6.5 dB", for an incoming message; whatever is known.
  static func signalText(_ message: Message) -> String {
    let hops: String? = message.hops.map { $0 == 0 ? L10n.Chats.Chats.Message.Hops.direct : NodeRouteFormat.hopCount($0) }
    let snr = message.snr.map { L10n.Localizable.CarPlay.Scan.signal($0.formatted(.number.precision(.fractionLength(1)))) }
    return NodeRouteFormat.joined([hops, snr])
  }

  /// A conversation row's line: "3 unread · Bob · 2m · ✓ 2 repeats". The unread count first, so
  /// truncation never cuts it; then who wrote last (a channel's or room's sender, or "You") and
  /// when; then the mark for the user's last message once a repeater heard it or it was
  /// acknowledged. Before the messages are read, the conversation's kind stands in for the sender.
  static func chatDetail(_ line: HomeDashboardModel.ConversationLine, activity: Activity?, now: Date) -> String {
    let showsUnread = line.unreadCount > 0 && !line.isMuted
    var parts: [String?] = [showsUnread ? L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(line.unreadCount) : nil]
    if let last = activity?.last {
      let sender: String? = if last.isOutgoing {
        L10n.Localizable.CarPlay.Chats.you
      } else if line.kind == .direct {
        nil
      } else {
        last.sender.map(CarPlaySnapshotBuilder.glanceName)
      }
      parts += [sender, HomeFormat.age(now.timeIntervalSince(last.date))]
    } else {
      parts += [showsUnread ? nil : CarPlaySnapshotBuilder.kindName(line.kind), HomeFormat.age(now.timeIntervalSince(line.date))]
    }
    if let sent = activity?.lastSent, sent.isConfirmed {
      parts.append(deliveryText(sent))
    }
    return NodeRouteFormat.joined(parts)
  }

  /// A conversation's screen: Read with Siri and Reply (none for a room, which Siri can only
  /// read), then its newest messages in the room left, newest first. A message row says who wrote
  /// it, how it came (hops, SNR) or how the user's went, and when; never what it says. The newest
  /// incoming messages, as many as the conversation counts unread, show the unread dot. Without
  /// Siri every row would do nothing, so the screen says why instead.
  static func page(_ open: CarPlayInputs.OpenConversation, inputs: CarPlayInputs, now: Date) -> CarPlaySnapshot.ConversationPage {
    let line = open.line
    let showsUnread = line.unreadCount > 0 && !line.isMuted
    let canReply = line.kind != .room
    let symbol = CarPlayAvatar.symbol(line)
    let tint = CarPlayAvatar.tint(line.kind, name: line.name)
    guard inputs.isSiriAvailable else {
      return .init(
        id: line.id, title: line.name, symbol: symbol, tint: tint, hasSiri: false, showsUnread: showsUnread,
        readDetail: "", canReply: false, rows: [],
        empty: .init(title: L10n.Localizable.CarPlay.Chats.siriOff, subtitle: nil)
      )
    }
    let room = max(0, min(inputs.listLimit, CarPlaySnapshotBuilder.maxListItems) - (canReply ? 2 : 1))
    var unreadLeft = showsUnread ? line.unreadCount : 0
    var rows: [CarPlaySnapshot.MessageRow] = []
    for message in open.messages.prefix(room) {
      let isUnread = !message.isOutgoing && unreadLeft > 0
      if isUnread { unreadLeft -= 1 }
      rows.append(row(message, in: line, isUnread: isUnread, now: now))
    }
    return .init(
      id: line.id,
      title: line.name,
      symbol: symbol,
      tint: tint,
      hasSiri: true,
      showsUnread: showsUnread,
      readDetail: showsUnread
        ? L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(line.unreadCount)
        : L10n.Localizable.CarPlay.Chats.readHint,
      canReply: canReply,
      rows: rows,
      note: rows.isEmpty ? nil : L10n.Localizable.CarPlay.Chats.recent,
      empty: .init(title: L10n.Localizable.CarPlay.Cards.noMessages, subtitle: nil)
    )
  }

  static func row(
    _ message: Message,
    in line: HomeDashboardModel.ConversationLine,
    isUnread: Bool,
    now: Date
  ) -> CarPlaySnapshot.MessageRow {
    // Only a direct chat's messages have no sender of their own: the conversation is who wrote.
    let sender = message.isOutgoing
      ? L10n.Localizable.CarPlay.Chats.you
      : (message.sender ?? (line.kind == .direct ? line.name : L10n.Chats.Chats.Message.Sender.unknown))
    let detail = message.delivery.map(deliveryText) ?? signalText(message)
    return .init(
      id: message.id,
      siriIdentifier: SiriMessage.identifier(conversationID: line.id, messageID: message.id),
      sender: sender,
      detail: detail,
      age: HomeFormat.age(now.timeIntervalSince(message.date)),
      symbol: message.isOutgoing ? CarPlayAvatar.companionSymbol : CarPlayAvatar.companion(sender),
      tint: message.isOutgoing ? .brand : CarPlayAvatar.companionTint(sender),
      isUnread: isUnread
    )
  }

  // MARK: - Store

  /// The row facts for the listed conversations: direct chats and channels in one read each,
  /// rooms one by one, each at most `activityFetchLimit` messages.
  @MainActor
  static func activities(
    for lines: [HomeDashboardModel.ConversationLine],
    radioID: UUID,
    store: PersistenceStore
  ) async -> [UUID: Activity] {
    var result: [UUID: Activity] = [:]
    let names = await nameDirectory(radioID: radioID, store: store, needed: lines.contains { $0.kind != .direct })
    let directIDs = lines.filter { $0.kind == .direct }.map(\.id)
    if !directIDs.isEmpty, let lists = try? await store.fetchLastMessages(contactIDs: directIDs, limit: activityFetchLimit) {
      for (id, list) in lists {
        result[id] = activity(list.reversed().compactMap { message($0, isDM: true) })
      }
    }
    let channels = lines.compactMap { line -> (radioID: UUID, channelIndex: UInt8, id: UUID)? in
      guard line.kind == .channel, let index = line.channelIndex else { return nil }
      return (radioID, index, line.id)
    }
    if !channels.isEmpty, let lists = try? await store.fetchLastChannelMessages(channels: channels, limit: activityFetchLimit) {
      for (id, list) in lists {
        result[id] = activity(list.reversed().compactMap { message($0, isDM: false, names: names) })
      }
    }
    for line in lines where line.kind == .room {
      guard !Task.isCancelled else { break }
      if let list = try? await store.fetchLatestRoomMessages(sessionID: line.id, limit: activityFetchLimit) {
        let room = try? await store.fetchRemoteNodeSession(id: line.id)
        result[line.id] = activity(list.reversed().map { message($0, room: room, names: names) })
      }
    }
    return result
  }

  /// The radio's contacts indexed for naming senders; empty when nothing listed needs names.
  @MainActor
  private static func nameDirectory(radioID: UUID, store: PersistenceStore, needed: Bool) async -> ContactNameDirectory {
    guard needed, let contacts = try? await store.fetchContacts(radioID: radioID) else { return .empty }
    return ContactNameDirectory(contacts: contacts)
  }

  /// A conversation's newest messages, newest first, at most `limit`.
  @MainActor
  static func messages(
    for line: HomeDashboardModel.ConversationLine,
    radioID: UUID,
    store: PersistenceStore,
    limit: Int
  ) async -> [Message] {
    guard limit > 0 else { return [] }
    switch line.kind {
    case .direct:
      let list = (try? await store.fetchMessages(contactID: line.id, limit: limit + reactionSlack, offset: 0)) ?? []
      return Array(list.reversed().compactMap { message($0, isDM: true) }.prefix(limit))
    case .channel:
      guard let index = line.channelIndex else { return [] }
      let names = await nameDirectory(radioID: radioID, store: store, needed: true)
      let list = (try? await store.fetchMessages(radioID: radioID, channelIndex: index, limit: limit + reactionSlack, offset: 0)) ?? []
      return Array(list.reversed().compactMap { message($0, isDM: false, names: names) }.prefix(limit))
    case .room:
      let names = await nameDirectory(radioID: radioID, store: store, needed: true)
      let room = try? await store.fetchRemoteNodeSession(id: line.id)
      let list = (try? await store.fetchLatestRoomMessages(sessionID: line.id, limit: limit)) ?? []
      return list.reversed().map { message($0, room: room, names: names) }
    }
  }
}
