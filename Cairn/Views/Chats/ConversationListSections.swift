import CairnServices
import Foundation

/// What the conversation list draws from the favorite/other split it's handed, already filtered
/// and searched: a Favorites group above the rest, or one run by recency when Favorites on Top
/// (`pinFavoriteChats`) is off. Worked out apart from the view so the grouping can be tested.
struct ConversationListSections: Equatable {
  /// Where the list keeps whether the group is folded; the list's `@AppStorage` reads it.
  static var collapsedKey: AppStorageKey { .chatsFavoritesCollapsed }

  /// The Favorites group's conversations, most recent first; empty when there's no group.
  let favorites: [Conversation]
  /// Everything under the group. Never repeats a conversation the group holds.
  let others: [Conversation]
  /// The group is folded: its header stays, its rows don't.
  let isFavoritesCollapsed: Bool

  init(
    favorites: [Conversation],
    others: [Conversation],
    pinFavorites: Bool,
    isFavoritesCollapsed: Bool,
    sort: ([Conversation]) -> [Conversation]
  ) {
    let favoriteIDs = Set(favorites.map(\.id))
    let rest = others.filter { !favoriteIDs.contains($0.id) }
    if pinFavorites {
      self.favorites = favorites
      self.others = rest
    } else {
      // No group: favorites take their place among the rest by recency.
      self.favorites = []
      self.others = sort(favorites + rest)
    }
    self.isFavoritesCollapsed = isFavoritesCollapsed
  }

  /// The group shows only while a favorite is in the results, so a filter or search that
  /// matches none hides its header too.
  var showsFavoritesGroup: Bool {
    !favorites.isEmpty
  }

  /// The group's rows on screen: none while it's folded.
  var visibleFavorites: [Conversation] {
    isFavoritesCollapsed ? [] : favorites
  }

  /// The rows on screen, top to bottom: what ↑/↓ steps through.
  var visibleRows: [Conversation] {
    visibleFavorites + others
  }

  /// Favorites folded out of sight: the rows ↑/↓ can't land on, which sit above the visible ones.
  var hiddenFavorites: [Conversation] {
    isFavoritesCollapsed ? favorites : []
  }

  /// Unread messages in the folded group, which its header shows in place of the rows' badges.
  /// Counted as the Unread filter counts: muted conversations don't add to it. Zero while the
  /// group is open, since its rows show their own.
  var foldedUnreadCount: Int {
    guard isFavoritesCollapsed else { return 0 }
    return favorites.reduce(0) { $1.isMuted ? $0 : $0 + $1.unreadCount }
  }

  /// Every row the list holds, favorites first, folded ones included.
  var allRows: [Conversation] {
    favorites + others
  }

  var isEmpty: Bool {
    favorites.isEmpty && others.isEmpty
  }
}
