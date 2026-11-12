import Foundation
import Intents
@testable import Cairn
import CairnServices
import Testing

@Suite("CarPlayChatsSource")
struct CarPlayChatsSourceTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  /// Message text no CarPlay screen may ever show.
  private static let secret = "SECRET-MESSAGE-TEXT-9c1d"

  private func dto(
    outgoing: Bool = false,
    channel: Bool = true,
    text: String = secret,
    status: MessageStatus = .delivered,
    heardRepeats: Int = 0,
    pathLength: UInt8 = 2,
    snr: Double? = 6.5,
    sender: String? = "Bob",
    secondsAgo: Double = 120
  ) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: channel ? nil : UUID(),
      channelIndex: channel ? 0 : nil,
      text: text,
      timestamp: 0,
      createdAt: now.addingTimeInterval(-secondsAgo),
      direction: outgoing ? .outgoing : .incoming,
      status: status,
      textType: .plain,
      ackCode: nil,
      pathLength: pathLength,
      snr: snr,
      senderKeyPrefix: nil,
      senderNodeName: sender,
      isRead: false,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: heardRepeats,
      retryAttempt: 0,
      maxRetryAttempts: 0
    )
  }

  private func line(
    _ kind: HomeDashboardModel.ConversationLine.Kind = .channel,
    name: String = "Public",
    unread: Int = 0,
    muted: Bool = false
  ) -> HomeDashboardModel.ConversationLine {
    HomeDashboardModel.ConversationLine(
      id: UUID(),
      name: name,
      date: now.addingTimeInterval(-60),
      preview: Self.secret,
      isUnread: unread > 0,
      kind: kind,
      unreadCount: unread,
      isMuted: muted,
      isPublicChannel: name == "Public"
    )
  }

  private func message(
    outgoing: Bool = false,
    sender: String? = "Bob",
    secondsAgo: Double = 120,
    delivery: CarPlayChatsSource.Delivery? = nil
  ) -> CarPlayChatsSource.Message {
    CarPlayChatsSource.Message(
      id: UUID(),
      isOutgoing: outgoing,
      sender: outgoing ? nil : sender,
      date: now.addingTimeInterval(-secondsAgo),
      hops: outgoing ? nil : 2,
      snr: outgoing ? nil : 6.5,
      delivery: outgoing ? (delivery ?? .delivered) : nil
    )
  }

  // MARK: - Delivery

  @Test
  func `Delivery reads as the phone's bubble shows it`() {
    #expect(CarPlayChatsSource.delivery(status: .pending, heardRepeats: 0, isChannel: true) == .sending)
    #expect(CarPlayChatsSource.delivery(status: .retrying, heardRepeats: 0, isChannel: false) == .retrying)
    // A direct message only queued may still fail; a channel's send is final.
    #expect(CarPlayChatsSource.delivery(status: .sent, heardRepeats: 0, isChannel: false) == .sending)
    #expect(CarPlayChatsSource.delivery(status: .sent, heardRepeats: 0, isChannel: true) == .sent)
    #expect(CarPlayChatsSource.delivery(status: .sent, heardRepeats: 3, isChannel: true) == .heard(3))
    #expect(CarPlayChatsSource.delivery(status: .delivered, heardRepeats: 1, isChannel: false) == .delivered)
    #expect(CarPlayChatsSource.delivery(status: .failed, heardRepeats: 0, isChannel: true) == .failed)
    #expect(CarPlayChatsSource.Delivery.heard(1).isConfirmed)
    #expect(CarPlayChatsSource.Delivery.delivered.isConfirmed)
    #expect(!CarPlayChatsSource.Delivery.sent.isConfirmed)
    #expect(!CarPlayChatsSource.Delivery.failed.isConfirmed)
  }

  @Test
  func `Delivery text uses the bubble's words, with a check once confirmed`() {
    #expect(CarPlayChatsSource.deliveryText(.delivered) == "\u{2713} " + L10n.Chats.Chats.Message.Status.delivered)
    #expect(CarPlayChatsSource.deliveryText(.heard(2)) == "\u{2713} 2 " + L10n.Chats.Chats.Message.Repeat.plural)
    #expect(CarPlayChatsSource.deliveryText(.heard(1)) == "\u{2713} 1 " + L10n.Chats.Chats.Message.Repeat.singular)
    #expect(CarPlayChatsSource.deliveryText(.failed) == L10n.Chats.Chats.Message.Status.failed)
  }

  // MARK: - Messages

  @Test
  func `Messages keep who, when and how, never the text`() {
    let incoming = CarPlayChatsSource.message(dto(), isDM: false)
    #expect(incoming?.sender == "Bob")
    #expect(incoming?.hops == 2)
    #expect(incoming?.snr == 6.5)
    #expect(incoming?.delivery == nil)
    #expect(!String(describing: incoming as Any).contains(Self.secret))

    let direct = CarPlayChatsSource.message(dto(channel: false), isDM: true)
    // The conversation's name says who wrote a direct message.
    #expect(direct?.sender == nil)

    let sent = CarPlayChatsSource.message(dto(outgoing: true, status: .sent, heardRepeats: 2), isDM: false)
    #expect(sent?.isOutgoing == true)
    #expect(sent?.delivery == .heard(2))
    #expect(sent?.hops == nil)
  }

  @Test
  func `Sent reactions are hidden as in the chat view`() {
    let reaction = dto(outgoing: true, channel: false, text: "👍\n0123ABCD", status: .sent)
    #expect(CarPlayChatsSource.message(reaction, isDM: true) == nil)
    let failed = dto(outgoing: true, channel: false, text: "👍\n0123ABCD", status: .failed)
    #expect(CarPlayChatsSource.message(failed, isDM: true) != nil)
  }

  @Test
  func `Room messages carry their author or the user's delivery`() {
    let session = UUID()
    let theirs = RoomMessageDTO(sessionID: session, authorKeyPrefix: Data([0xAB]), authorName: "Ann", text: Self.secret, timestamp: 0)
    let mine = RoomMessageDTO(sessionID: session, authorKeyPrefix: Data([0x01]), text: Self.secret, timestamp: 0, isFromSelf: true, status: .failed)
    #expect(CarPlayChatsSource.message(theirs).sender == "Ann")
    #expect(CarPlayChatsSource.message(mine).delivery == .failed)
    #expect(CarPlayChatsSource.message(mine).sender == nil)
    let sent = RoomMessageDTO(sessionID: session, authorKeyPrefix: Data([0x01]), text: Self.secret, timestamp: 0, isFromSelf: true, status: .sent)
    #expect(CarPlayChatsSource.message(sent).delivery == .sent)
  }

  @Test
  func `Activity is the newest message and the user's newest sent one`() {
    let last = message(secondsAgo: 30)
    let sent = message(outgoing: true, secondsAgo: 90, delivery: .heard(2))
    let activity = CarPlayChatsSource.activity([last, sent, message(outgoing: true, secondsAgo: 200, delivery: .failed)])
    #expect(activity.last == last)
    #expect(activity.lastSent == .heard(2))
    #expect(CarPlayChatsSource.activity([]).last == nil)
  }

  // MARK: - Conversation rows

  @Test
  func `A channel row says unread, who wrote last and when, then the delivery mark`() {
    let channel = line(unread: 3)
    let activity = CarPlayChatsSource.Activity(last: message(sender: "Bob", secondsAgo: 120), lastSent: .heard(2))
    let detail = CarPlayChatsSource.chatDetail(channel, activity: activity, now: now)
    #expect(detail == NodeRouteFormat.joined([
      L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(3),
      "Bob",
      HomeFormat.age(120),
      CarPlayChatsSource.deliveryText(.heard(2)),
    ]))
  }

  @Test
  func `The user's own last message reads as You, and only a confirmed one gets a mark`() {
    let mine = CarPlayChatsSource.Activity(last: message(outgoing: true, secondsAgo: 60, delivery: .sending), lastSent: .sending)
    #expect(CarPlayChatsSource.chatDetail(line(), activity: mine, now: now)
      == NodeRouteFormat.joined([L10n.Localizable.CarPlay.Chats.you, HomeFormat.age(60)]))
  }

  @Test
  func `A direct chat's row needs no sender, and a muted one no unread`() {
    let direct = line(.direct, name: "Alice", unread: 2, muted: true)
    let activity = CarPlayChatsSource.Activity(last: message(sender: nil, secondsAgo: 300), lastSent: .delivered)
    #expect(CarPlayChatsSource.chatDetail(direct, activity: activity, now: now)
      == NodeRouteFormat.joined([HomeFormat.age(300), CarPlayChatsSource.deliveryText(.delivered)]))
  }

  @Test
  func `Long sender names are shortened for the row`() {
    let activity = CarPlayChatsSource.Activity(last: message(sender: "A very long mesh node name indeed"), lastSent: nil)
    let detail = CarPlayChatsSource.chatDetail(line(), activity: activity, now: now)
    #expect(detail.contains(CarPlaySnapshotBuilder.glanceName("A very long mesh node name indeed")))
  }

  // MARK: - Conversation screen

  private func inputs(siri: Bool = true, limit: Int = CarPlaySnapshotBuilder.maxListItems) -> CarPlayInputs {
    var inputs = CarPlayInputs()
    inputs.isSiriAvailable = siri
    inputs.listLimit = limit
    return inputs
  }

  @Test
  func `A conversation screen lists its newest messages within the car's limit`() {
    let open = CarPlayInputs.OpenConversation(line: line(), messages: (0 ..< 20).map { message(secondsAgo: Double($0 * 60)) })
    let page = CarPlayChatsSource.page(open, inputs: inputs(), now: now)
    #expect(page.hasSiri)
    #expect(page.canReply)
    // Read with Siri and Reply take two of the twelve rows.
    #expect(page.rows.count == CarPlaySnapshotBuilder.maxListItems - 2)
    #expect(page.rows.first?.age == HomeFormat.age(0))
    #expect(page.note == L10n.Localizable.CarPlay.Chats.recent)

    let narrow = CarPlayChatsSource.page(open, inputs: inputs(limit: 6), now: now)
    #expect(narrow.rows.count == 4)
  }

  @Test
  func `A room's screen has no reply and one more message`() {
    let open = CarPlayInputs.OpenConversation(line: line(.room, name: "Ops"), messages: (0 ..< 20).map { message(secondsAgo: Double($0)) })
    let page = CarPlayChatsSource.page(open, inputs: inputs(), now: now)
    #expect(!page.canReply)
    #expect(page.rows.count == CarPlaySnapshotBuilder.maxListItems - 1)
  }

  @Test
  func `Message rows say who, how and when, and Siri reads each by its own identifier`() {
    let conversation = line(unread: 1)
    let incoming = message(sender: "Bob", secondsAgo: 60)
    let earlier = message(sender: "Cy", secondsAgo: 90)
    let mine = message(outgoing: true, secondsAgo: 120, delivery: .delivered)
    let open = CarPlayInputs.OpenConversation(line: conversation, messages: [incoming, earlier, mine])
    let page = CarPlayChatsSource.page(open, inputs: inputs(), now: now)
    #expect(page.readDetail == L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(1))
    #expect(page.rows.map(\.sender) == ["Bob", "Cy", L10n.Localizable.CarPlay.Chats.you])
    // Only as many of the newest incoming messages as the conversation counts unread.
    #expect(page.rows.map(\.isUnread) == [true, false, false])
    #expect(page.rows[0].detail == CarPlayChatsSource.signalText(incoming))
    #expect(page.rows[0].detail.contains(NodeRouteFormat.hopCount(2)))
    #expect(page.rows[2].detail == CarPlayChatsSource.deliveryText(.delivered))
    #expect(page.rows[0].siriIdentifier == SiriMessage.identifier(conversationID: conversation.id, messageID: incoming.id))
    #expect(page.rows[0].age == HomeFormat.age(60))
  }

  @Test
  func `Zero hops reads as Direct, and nothing known reads as nothing`() {
    var direct = message()
    direct.hops = 0
    direct.snr = nil
    #expect(CarPlayChatsSource.signalText(direct) == L10n.Chats.Chats.Message.Hops.direct)
    direct.hops = nil
    #expect(CarPlayChatsSource.signalText(direct).isEmpty)
  }

  @Test
  func `Without Siri the screen says why instead of rows that can't work`() {
    let open = CarPlayInputs.OpenConversation(line: line(), messages: [message()])
    let page = CarPlayChatsSource.page(open, inputs: inputs(siri: false), now: now)
    #expect(!page.hasSiri)
    #expect(page.rows.isEmpty)
    #expect(page.empty.title == L10n.Localizable.CarPlay.Chats.siriOff)
  }

  @Test
  func `The open conversation reaches the snapshot without any message text`() {
    var inputs = inputs()
    inputs.connectionState = .ready
    inputs.isRadioReady = true
    inputs.lastRadioName = "Heltec"
    let conversation = line(unread: 2)
    inputs.conversations = [conversation]
    inputs.chatActivity = [conversation.id: CarPlayChatsSource.activity([message()])]
    let messages = [dto(), dto(outgoing: true, status: .sent, heardRepeats: 1)].compactMap { CarPlayChatsSource.message($0, isDM: false) }
    inputs.openConversation = .init(line: conversation, messages: messages)
    let snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    #expect(snapshot.chats.page?.rows.count == 2)
    #expect(snapshot.chats.rows.first?.detail.contains("Bob") == true)
    #expect(!String(describing: snapshot).contains(Self.secret))
  }

  // MARK: - Siri

  @Test
  func `A message row's identifier names one message and still leads to its conversation`() {
    let conversationID = UUID()
    let messageID = UUID()
    let identifier = SiriMessage.identifier(conversationID: conversationID, messageID: messageID)
    let pinned = SiriMessage.pinnedMessage(fromIdentifier: identifier)
    #expect(pinned?.conversationID == conversationID)
    #expect(pinned?.messageID == messageID)
    #expect(SiriMessage.pinnedMessage(fromIdentifier: conversationID.uuidString) == nil)
    #expect(MessageIntentHandler.conversationID(identifier) == conversationID)
    #expect(MessageIntentHandler.conversationID(conversationID.uuidString) == conversationID)
    #expect(MessageIntentHandler.conversationID(nil) == nil)
  }

  @Test
  func `The Reply row's recipient handle names its conversation`() {
    let id = UUID()
    let fromHandle = INPerson(
      personHandle: INPersonHandle(value: id.uuidString, type: .unknown),
      nameComponents: nil,
      displayName: "Public",
      image: nil,
      contactIdentifier: nil,
      customIdentifier: nil
    )
    #expect(MessageIntentHandler.conversationID(of: fromHandle) == id)
    let spoken = INPerson(
      personHandle: INPersonHandle(value: "Bob", type: .unknown),
      nameComponents: nil,
      displayName: "Bob",
      image: nil,
      contactIdentifier: nil,
      customIdentifier: nil
    )
    #expect(MessageIntentHandler.conversationID(of: spoken) == nil)
  }
}
