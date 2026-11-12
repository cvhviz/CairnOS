import CoreLocation
import Foundation
import CairnServices
import OSLog

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "Home")

/// The store reads the Home cards make. `PersistenceStore` has them all; the protocol lets a test
/// count which reads a reload makes.
protocol HomeDashboardStore: AnyObject, Sendable {
  func fetchConversations(radioID: UUID) async throws -> [ContactDTO]
  func fetchChannels(radioID: UUID) async throws -> [ChannelDTO]
  func fetchRemoteNodeSessions(radioID: UUID) async throws -> [RemoteNodeSessionDTO]
  func fetchLastMessages(contactIDs: [UUID], limit: Int) async throws -> [UUID: [MessageDTO]]
  func fetchLastChannelMessages(
    channels: [(radioID: UUID, channelIndex: UInt8, id: UUID)],
    limit: Int
  ) async throws -> [UUID: [MessageDTO]]
  func fetchContacts(radioID: UUID) async throws -> [ContactDTO]
  func fetchDiscoveredNodes(radioID: UUID) async throws -> [DiscoveredNodeDTO]
  func fetchLatestRoomMessages(sessionID: UUID, limit: Int) async throws -> [RoomMessageDTO]
}

extension PersistenceStore: HomeDashboardStore {}

/// What the Home Chats and Contacts cards show, read from the local store: the two newest
/// conversations and the unread total, the contact count, nodes newly heard, and the last node
/// heard. Reads only; the Chats and Contacts tabs own every change. Works offline, since the store
/// keeps the last radio's data.
///
/// The chats and the nodes reload apart, each through its own `HomeReloadCoalescer`: an advert
/// burst re-reads only the nodes and a message only the chats, a read under way is never thrown
/// away for a newer one, and each read lands on the cards in one step.
@Observable
@MainActor
final class HomeDashboardModel {
  /// One conversation line on the Chats card.
  struct ConversationLine: Identifiable, Equatable {
    enum Kind: Equatable {
      case direct
      case channel
      case room
    }

    let id: UUID
    let name: String
    let date: Date
    /// The last message's text, on one line as the bubble reads it; always nil when the model was
    /// made with `loadsPreviews: false`.
    let preview: String?
    /// Who wrote the last message, when the line names them: named when shown
    /// (`previewLine(names:)`) so a nickname set since the read still applies.
    var previewAuthor: PreviewAuthor?
    let isUnread: Bool
    var kind: Kind = .direct
    var unreadCount = 0
    var isMuted = false
    var isFavorite = false
    /// For a channel's avatar glyph, as `ChannelAvatar` picks it: the public channel's globe, a
    /// hashtag channel's hash, otherwise a private channel's lock.
    var isPublicChannel = false
    var isHashtagChannel = false
    /// A channel's slot on the radio, so its messages can be read; nil for other kinds.
    var channelIndex: UInt8?
    /// Where tapping the line goes.
    var route: ChatRoute?

    /// Who wrote a line's last message.
    enum PreviewAuthor: Equatable {
      /// Someone else in a channel, by the name they put on air.
      case channelSender(String)
      /// A room post, by its author's key prefix (or the user's own).
      case roomPost(RoomMessageDTO, roomPublicKey: Data, roomName: String)
    }

    /// "Sender: text" for a channel or room line, the text alone otherwise: a channel sender by the
    /// contact's nickname when one contact has that name, a room author as the room shows them.
    func previewLine(names: ContactNameDirectory) -> String? {
      previewParts(names: names).map { parts in
        parts.sender.map { L10n.Localizable.Home.Chats.preview($0, parts.text) } ?? parts.text
      }
    }

    /// The preview's sender (a channel's or room's author) and its text apart, so the card can colour
    /// the name apart from the message (the user, 2026-11-09).
    func previewParts(names: ContactNameDirectory) -> (sender: String?, text: String)? {
      guard let preview else { return nil }
      let sender: String? = switch previewAuthor {
      case let .channelSender(wireName):
        names.channelSenders.shortName(for: wireName)
      case let .roomPost(post, roomPublicKey, roomName):
        names.roomAuthors.resolve(
          post, roomPublicKey: roomPublicKey, roomName: roomName,
          selfName: L10n.Chats.Chats.Path.Receiver.you
        ).displayName
      case nil:
        nil
      }
      return (sender, preview)
    }
  }

  /// The most recently heard node, for the Contacts card's "Last:" lines.
  struct HeardNode: Equatable {
    let name: String
    let lastHeard: Date
    let coordinate: CLLocationCoordinate2D?
    let publicKey: Data
    /// The saved node, so the card's line can open its page; nil for a node heard but not saved,
    /// which the line opens on the Heard list instead.
    let contact: ContactDTO?

    var isSaved: Bool { contact != nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.name == rhs.name && lhs.lastHeard == rhs.lastHeard
        && lhs.publicKey == rhs.publicKey && lhs.isSaved == rhs.isSaved
        && lhs.coordinate?.latitude == rhs.coordinate?.latitude
        && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }
  }

  private(set) var recentConversations: [ConversationLine] = []
  /// Unread messages across conversations that notify, matching the app badge when it is unknown.
  private(set) var unreadTotal = 0
  private(set) var contactCount: Int?
  private(set) var newNodeCount = 0
  /// What `newNodeCount` was counted from, so a card can count again as the clock moves and a
  /// node heard a day ago drops out without waiting for the next reload.
  private var heardNodes: [(publicKey: Data, lastHeard: Date)] = []
  private var contactKeys: Set<Data> = []
  private(set) var lastHeard: HeardNode?

  /// How many conversations to list: two on the Home Chats card, as on Cairn.
  private let conversationLimit: Int
  /// Whether to read each listed conversation's last message. CarPlay passes false: it must never
  /// show message text, so it never fetches any.
  private let loadsPreviews: Bool
  /// Messages fetched per conversation to find a preview past outgoing reactions.
  private static let previewFetchLimit = 10

  /// The store and radio the next reads are for; nil with no radio to read.
  @ObservationIgnored private var source: (store: any HomeDashboardStore, radioID: UUID)?
  @ObservationIgnored private let reloadInterval: Duration
  @ObservationIgnored private lazy var conversationReloads = HomeReloadCoalescer(interval: reloadInterval) { [weak self] in
    await self?.readConversations()
  }

  @ObservationIgnored private lazy var nodeReloads = HomeReloadCoalescer(interval: reloadInterval) { [weak self] in
    await self?.readNodes()
  }

  /// - Parameter reloadInterval: The least time between the starts of two reads of the same card;
  ///   tests pass zero.
  init(conversationLimit: Int = 2, loadsPreviews: Bool = true, reloadInterval: Duration = .seconds(1)) {
    self.conversationLimit = conversationLimit
    self.loadsPreviews = loadsPreviews
    self.reloadInterval = reloadInterval
  }

  /// Reloads everything for `radioID` and returns once both reads are on the cards, or clears the
  /// cards when there is no radio to read: the first load, pull to refresh, and CarPlay.
  func load(dataStore: (any HomeDashboardStore)?, radioID: UUID?) async {
    guard select(dataStore: dataStore, radioID: radioID) else { return }
    async let conversations: Void = conversationReloads.run()
    async let nodes: Void = nodeReloads.run()
    _ = await (conversations, nodes)
  }

  /// Re-reads the Chats card once the conversations changed, paced by its coalescer.
  func requestConversations(dataStore: (any HomeDashboardStore)?, radioID: UUID?) {
    guard select(dataStore: dataStore, radioID: radioID) else { return }
    conversationReloads.request()
  }

  /// Re-reads the Nodes card once the contacts or heard nodes changed, paced by its coalescer.
  func requestNodes(dataStore: (any HomeDashboardStore)?, radioID: UUID?) {
    guard select(dataStore: dataStore, radioID: radioID) else { return }
    nodeReloads.request()
  }

  /// Points the reads at `radioID`. Another radio, or none, clears the cards at once and drops
  /// whatever a read still under way for the old one returns. Returns whether there is a radio to
  /// read.
  private func select(dataStore: (any HomeDashboardStore)?, radioID: UUID?) -> Bool {
    guard let dataStore, let radioID else {
      source = nil
      conversationReloads.reset()
      nodeReloads.reset()
      clear()
      return false
    }
    if source?.radioID != radioID {
      conversationReloads.reset()
      nodeReloads.reset()
      clear()
    }
    source = (dataStore, radioID)
    return true
  }

  private func clear() {
    recentConversations = []
    unreadTotal = 0
    contactCount = nil
    newNodeCount = 0
    heardNodes = []
    contactKeys = []
    lastHeard = nil
  }

  // MARK: - Chats

  /// Reads the Chats card; the returned step sets its lines and unread total together.
  private func readConversations() async -> (@MainActor () -> Void)? {
    guard let source else { return nil }
    let dataStore = source.store
    let radioID = source.radioID
    do {
      let contacts = try await dataStore.fetchConversations(radioID: radioID)
      let channels = try await dataStore.fetchChannels(radioID: radioID)
      let rooms = try await dataStore.fetchRemoteNodeSessions(radioID: radioID).filter(\.isRoom)

      let conversations: [Conversation] = contacts.filter { !$0.isBlocked }.map(Conversation.direct)
        + channels.map(Conversation.channel)
        + rooms.map(Conversation.room)
      let unread = conversations.filter { !$0.isMuted }.reduce(0) { $0 + $1.unreadCount }

      let newest = HomeFormat.newest(conversations, limit: conversationLimit, date: \.lastMessageDate)
      let previews = loadsPreviews ? await previews(for: newest, dataStore: dataStore) : [:]
      let lines = newest.compactMap { conversation in
        conversation.lastMessageDate.map { date in
          ConversationLine(
            id: conversation.id,
            name: conversation.displayName,
            date: date,
            preview: previews[conversation.id]?.text,
            previewAuthor: previews[conversation.id]?.author,
            isUnread: conversation.unreadCount > 0,
            kind: Self.kind(of: conversation),
            unreadCount: conversation.unreadCount,
            isMuted: conversation.isMuted,
            isFavorite: conversation.isFavorite,
            isPublicChannel: Self.channel(of: conversation)?.isPublicChannel ?? false,
            isHashtagChannel: Self.channel(of: conversation)?.name.hasPrefix("#") ?? false,
            channelIndex: Self.channel(of: conversation)?.index,
            route: Self.route(of: conversation)
          )
        }
      }
      return { [weak self] in
        guard let self else { return }
        unreadTotal = unread
        recentConversations = lines
      }
    } catch {
      logger.warning("Home conversations load failed: \(error.localizedDescription)")
      return nil
    }
  }

  private static func channel(of conversation: Conversation) -> ChannelDTO? {
    if case let .channel(channel) = conversation { channel } else { nil }
  }

  private static func route(of conversation: Conversation) -> ChatRoute {
    switch conversation {
    case let .direct(contact): .direct(contact)
    case let .channel(channel): .channel(channel)
    case let .room(session): .room(session)
    }
  }

  private static func kind(of conversation: Conversation) -> ConversationLine.Kind {
    switch conversation {
    case .direct: .direct
    case .channel: .channel
    case .room: .room
    }
  }

  /// The last message's text for the listed conversations, and who wrote it in channels and
  /// rooms. Skips outgoing reactions, as the Chats list does.
  private func previews(
    for conversations: [Conversation],
    dataStore: any HomeDashboardStore
  ) async -> [UUID: (text: String, author: ConversationLine.PreviewAuthor?)] {
    var contactIDs: [UUID] = []
    var channels: [(radioID: UUID, channelIndex: UInt8, id: UUID)] = []
    var rooms: [RemoteNodeSessionDTO] = []
    for conversation in conversations {
      switch conversation {
      case let .direct(contact): contactIDs.append(contact.id)
      case let .channel(channel): channels.append((channel.radioID, channel.index, channel.id))
      case let .room(session): rooms.append(session)
      }
    }

    var result: [UUID: (text: String, author: ConversationLine.PreviewAuthor?)] = [:]
    if !contactIDs.isEmpty,
       let messages = try? await dataStore.fetchLastMessages(contactIDs: contactIDs, limit: Self.previewFetchLimit) {
      for (id, list) in messages {
        let last = list.last { !($0.direction == .outgoing && ReactionParser.parseDM($0.text) != nil && $0.status != .failed) }
        if let last { result[id] = (MessagePreviewFormatter.preview(last.text), nil) }
      }
    }
    if !channels.isEmpty,
       let messages = try? await dataStore.fetchLastChannelMessages(channels: channels, limit: Self.previewFetchLimit) {
      for (id, list) in messages {
        let last = list.last { !($0.direction == .outgoing && ReactionParser.parse($0.text) != nil && $0.status != .failed) }
        guard let last else { continue }
        let author: ConversationLine.PreviewAuthor? = if last.direction == .incoming,
                                                         let sender = last.senderNodeName, !sender.isEmpty {
          .channelSender(sender)
        } else {
          nil
        }
        result[id] = (MessagePreviewFormatter.preview(last.text), author)
      }
    }
    for room in rooms {
      guard let post = try? await dataStore.fetchLatestRoomMessages(sessionID: room.id, limit: 1).last else { continue }
      result[room.id] = (
        MessagePreviewFormatter.preview(post.text),
        post.isFromSelf ? nil : .roomPost(post, roomPublicKey: room.publicKey, roomName: room.name)
      )
    }
    return result
  }

  // MARK: - Nodes

  /// Nodes heard in the last day that aren't saved, as of `now`.
  func newNodeCount(now: Date) -> Int {
    HomeFormat.newNodeCount(heard: heardNodes, contactKeys: contactKeys, now: now)
  }

  /// Reads the Nodes card; the returned step sets the count, the new nodes and the last heard
  /// together.
  private func readNodes() async -> (@MainActor () -> Void)? {
    guard let source else { return nil }
    let dataStore = source.store
    let radioID = source.radioID
    do {
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      let heard = try await dataStore.fetchDiscoveredNodes(radioID: radioID)

      let count = contacts.count { !$0.isBlocked }
      let keys = Set(contacts.map(\.publicKey))
      let heardTimes = heard.map { (publicKey: $0.publicKey, lastHeard: $0.lastHeard) }
      let last = Self.lastHeard(contacts: contacts, heard: heard)
      return { [weak self] in
        guard let self else { return }
        contactCount = count
        contactKeys = keys
        heardNodes = heardTimes
        newNodeCount = newNodeCount(now: .now)
        lastHeard = last
      }
    } catch {
      logger.warning("Home nodes load failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// The node heard last, as the Nodes tab orders its lists: a saved node by its recency (the
  /// newer of the radio's last change and the phone's last hearing), named as the Nodes tab names
  /// it (the nickname first), and an unsaved one by when the phone last heard its advert, named as
  /// the Heard list names it. Blocked nodes are left out, as the contact count and CarPlay's Nodes
  /// list leave them out. Nil when nothing qualifies.
  static func lastHeard(contacts: [ContactDTO], heard: [DiscoveredNodeDTO]) -> HeardNode? {
    let saved = contacts.compactMap { contact -> HeardNode? in
      guard !contact.isBlocked, contact.recencyTimestamp > 0 else { return nil }
      return HeardNode(
        name: contact.displayName,
        lastHeard: contact.recencyDate,
        coordinate: contact.hasLocation ? CLLocationCoordinate2D(latitude: contact.latitude, longitude: contact.longitude) : nil,
        publicKey: contact.publicKey,
        contact: contact
      )
    }
    let savedKeys = Set(contacts.map(\.publicKey))
    let unsaved = heard.compactMap { node -> HeardNode? in
      guard !savedKeys.contains(node.publicKey) else { return nil }
      return HeardNode(
        name: node.name,
        lastHeard: node.lastHeard,
        coordinate: node.hasLocation ? CLLocationCoordinate2D(latitude: node.latitude, longitude: node.longitude) : nil,
        publicKey: node.publicKey,
        contact: nil
      )
    }
    return (saved + unsaved).max { $0.lastHeard < $1.lastHeard }
  }
}
