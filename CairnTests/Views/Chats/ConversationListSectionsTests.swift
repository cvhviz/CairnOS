import Foundation
@testable import Cairn
@testable import CairnServices
import SwiftUI
import Testing

@Suite("Conversation list Favorites group")
@MainActor
struct ConversationListSectionsTests {
  // MARK: - Test Helpers

  private func contact(
    _ name: String,
    isFavorite: Bool = false,
    unreadCount: Int = 0,
    isMuted: Bool = false,
    at seconds: TimeInterval = 0
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(),
      name: name,
      typeRawValue: 0,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: isMuted,
      isFavorite: isFavorite,
      lastMessageDate: Date(timeIntervalSince1970: seconds),
      unreadCount: unreadCount,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }

  private func channel(_ name: String, isFavorite: Bool = false, at seconds: TimeInterval = 0) -> Conversation {
    .channel(ChannelDTO(
      id: UUID(),
      radioID: UUID(),
      index: 1,
      name: name,
      secret: Data(repeating: 0xA1, count: 16),
      isEnabled: true,
      lastMessageDate: Date(timeIntervalSince1970: seconds),
      unreadCount: 0,
      isFavorite: isFavorite
    ))
  }

  private func names(_ conversations: [Conversation]) -> [String] {
    conversations.map(\.displayName)
  }

  /// The grouping as the list builds it: the snapshot filtered and searched the way the Comm tab
  /// does (`ChatsView`, `ChatsContentColumn`), then split with Favorites on Top on.
  private func sections(
    _ snapshot: ConversationSnapshot,
    filter: ChatFilter = .all,
    searchText: String = "",
    isFavoritesCollapsed: Bool = false
  ) -> ConversationListSections {
    ConversationListSections(
      favorites: snapshot.favorites.filtered(by: filter, searchText: searchText),
      others: snapshot.others.filtered(by: filter, searchText: searchText),
      pinFavorites: true,
      isFavoritesCollapsed: isFavoritesCollapsed,
      sort: ChatViewModel().sortedByLastMessage
    )
  }

  // MARK: - Grouping

  @Test
  func `favorites go in the group and the rest below it`() {
    let snapshot = ConversationSnapshot(
      favorites: [channel("Fav A", isFavorite: true), .direct(contact("Fav B", isFavorite: true))],
      others: [channel("Plain"), .direct(contact("Other"))]
    )

    let result = sections(snapshot)

    #expect(result.showsFavoritesGroup)
    #expect(names(result.favorites) == ["Fav A", "Fav B"])
    #expect(names(result.others) == ["Plain", "Other"])
    #expect(names(result.visibleRows) == ["Fav A", "Fav B", "Plain", "Other"])
  }

  @Test
  func `a favorite is never listed again below the group`() {
    let favorite = channel("Fav", isFavorite: true)
    let snapshot = ConversationSnapshot(favorites: [favorite], others: [favorite, channel("Plain")])

    let result = sections(snapshot)

    #expect(names(result.favorites) == ["Fav"])
    #expect(names(result.others) == ["Plain"])
    #expect(result.visibleRows.count(where: { $0.id == favorite.id }) == 1)
  }

  @Test
  func `with pinning off there is no group and favorites appear once by recency`() {
    let favorite = channel("Fav", isFavorite: true, at: 500)
    let result = ConversationListSections(
      favorites: [favorite],
      others: [channel("Recent", at: 900), favorite, channel("Old", at: 100)],
      pinFavorites: false,
      isFavoritesCollapsed: false,
      sort: ChatViewModel().sortedByLastMessage
    )

    #expect(!result.showsFavoritesGroup)
    #expect(names(result.visibleRows) == ["Recent", "Fav", "Old"])
  }

  // MARK: - Filters and Search

  @Test
  func `the segment filter applies to the group too`() {
    let snapshot = ConversationSnapshot(
      favorites: [channel("Fav Channel", isFavorite: true), .direct(contact("Fav DM", isFavorite: true))],
      others: [channel("Plain Channel"), .direct(contact("Plain DM"))]
    )

    let result = sections(snapshot, filter: .directMessages)

    #expect(names(result.favorites) == ["Fav DM"])
    #expect(names(result.others) == ["Plain DM"])
  }

  @Test
  func `the unread filter applies to the group too`() {
    let snapshot = ConversationSnapshot(
      favorites: [
        .direct(contact("Fav Unread", isFavorite: true, unreadCount: 2)),
        .direct(contact("Fav Read", isFavorite: true))
      ],
      others: [.direct(contact("Plain Unread", unreadCount: 1))]
    )

    let result = sections(snapshot, filter: .unread)

    #expect(names(result.favorites) == ["Fav Unread"])
    #expect(names(result.others) == ["Plain Unread"])
  }

  @Test
  func `search applies to the group too`() {
    let snapshot = ConversationSnapshot(
      favorites: [channel("Base Camp", isFavorite: true), channel("Summit", isFavorite: true)],
      others: [channel("Base Ops"), channel("Valley")]
    )

    let result = sections(snapshot, searchText: "base")

    #expect(names(result.favorites) == ["Base Camp"])
    #expect(names(result.others) == ["Base Ops"])
  }

  // MARK: - Empty Group

  @Test
  func `the group hides when no favorite is in the results`() {
    let snapshot = ConversationSnapshot(
      favorites: [channel("Summit", isFavorite: true)],
      others: [channel("Base Ops")]
    )

    let searched = sections(snapshot, searchText: "base")
    #expect(!searched.showsFavoritesGroup)
    #expect(names(searched.visibleRows) == ["Base Ops"])

    let filtered = sections(snapshot, filter: .directMessages)
    #expect(!filtered.showsFavoritesGroup)
    #expect(filtered.isEmpty)

    let noFavorites = sections(ConversationSnapshot(favorites: [], others: [channel("Plain")]))
    #expect(!noFavorites.showsFavoritesGroup)
  }

  // MARK: - Collapse

  @Test
  func `a folded group keeps its header and drops its rows`() {
    let snapshot = ConversationSnapshot(
      favorites: [channel("Fav", isFavorite: true)],
      others: [channel("Plain")]
    )

    let result = sections(snapshot, isFavoritesCollapsed: true)

    #expect(result.showsFavoritesGroup)
    #expect(result.favorites.count == 1)
    #expect(result.visibleFavorites.isEmpty)
    #expect(names(result.visibleRows) == ["Plain"])
    #expect(names(result.allRows) == ["Fav", "Plain"])
  }

  @Test
  func `a folded group of only favorites is not an empty list`() {
    let snapshot = ConversationSnapshot(favorites: [channel("Fav", isFavorite: true)], others: [])

    let result = sections(snapshot, isFavoritesCollapsed: true)

    #expect(!result.isEmpty)
    #expect(result.visibleRows.isEmpty)
  }

  @Test
  func `the folded group's header counts its unread messages, muted ones aside`() {
    let snapshot = ConversationSnapshot(
      favorites: [
        .direct(contact("Fav A", isFavorite: true, unreadCount: 2)),
        .direct(contact("Fav B", isFavorite: true, unreadCount: 3)),
        .direct(contact("Fav Muted", isFavorite: true, unreadCount: 7, isMuted: true)),
      ],
      others: [.direct(contact("Other", unreadCount: 4))]
    )

    #expect(sections(snapshot, isFavoritesCollapsed: true).foldedUnreadCount == 5)
    // Open, the rows show their own badges.
    #expect(sections(snapshot).foldedUnreadCount == 0)
  }

  /// With the Unread filter on and only favorites unread, the folded header still says so.
  @Test
  func `the unread filter's folded group keeps its unread count`() {
    let snapshot = ConversationSnapshot(
      favorites: [
        .direct(contact("Fav A", isFavorite: true, unreadCount: 1)),
        .direct(contact("Fav Read", isFavorite: true)),
      ],
      others: [.direct(contact("Other"))]
    )

    let result = sections(snapshot, filter: .unread, isFavoritesCollapsed: true)

    #expect(names(result.favorites) == ["Fav A"])
    #expect(result.visibleRows.isEmpty)
    #expect(result.foldedUnreadCount == 1)
  }

  // MARK: - Keyboard Stepping

  @Test
  func `stepping from a folded favorite goes down into the list and never wraps to the end`() {
    let favorite = channel("Fav", isFavorite: true)
    let snapshot = ConversationSnapshot(favorites: [favorite], others: [channel("A"), channel("B")])
    let result = sections(snapshot, isFavoritesCollapsed: true)
    let routes = result.visibleRows.map(ChatRoute.init(conversation:))
    let hidden = result.hiddenFavorites.map(ChatRoute.init(conversation:))
    let selected = ChatRoute(conversation: favorite)

    #expect(hidden == [selected])
    #expect(ConversationListContent.stepped(from: selected, in: routes, hiddenAbove: hidden, by: .next) == routes[0])
    #expect(ConversationListContent.stepped(from: selected, in: routes, hiddenAbove: hidden, by: .previous) == nil)
    // Open, nothing is hidden and the favorite steps as any row does.
    #expect(sections(snapshot).hiddenFavorites.isEmpty)
  }

  // MARK: - Folded State

  @Test
  func `the fold persists under the sections' key and starts open`() throws {
    let suiteName = "ChatsFavoritesCollapsed-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    // `ConversationListContent` declares its `@AppStorage` with this key.
    #expect(ConversationListSections.collapsedKey == .chatsFavoritesCollapsed)
    let key = ConversationListSections.collapsedKey.rawValue
    #expect(key == "chatsFavoritesCollapsed")

    // The same declaration `ConversationListContent` makes, against a test store.
    let firstLaunch = AppStorage(wrappedValue: false, key, store: defaults)
    #expect(firstLaunch.wrappedValue == false)
    firstLaunch.wrappedValue = true

    let nextLaunch = AppStorage(wrappedValue: false, key, store: defaults)
    #expect(nextLaunch.wrappedValue == true)
    #expect(defaults.bool(forKey: key))
  }

  // MARK: - Live Favorite Toggle

  @Test
  func `favoriting a conversation moves it from the list into the group`() {
    let viewModel = ChatViewModel()
    let alice = contact("Alice", at: 200)
    viewModel.conversations = [alice, contact("Bob", at: 100)]
    viewModel.recomputeSnapshot()
    #expect(!sections(viewModel.conversationSnapshot).showsFavoritesGroup)

    viewModel.conversations[0] = alice.with(isFavorite: true)
    viewModel.recomputeSnapshot()
    let favorited = sections(viewModel.conversationSnapshot)
    #expect(names(favorited.favorites) == ["Alice"])
    #expect(names(favorited.others) == ["Bob"])

    viewModel.conversations[0] = alice.with(isFavorite: false)
    viewModel.recomputeSnapshot()
    let unfavorited = sections(viewModel.conversationSnapshot)
    #expect(!unfavorited.showsFavoritesGroup)
    #expect(names(unfavorited.others) == ["Alice", "Bob"])
  }
}
