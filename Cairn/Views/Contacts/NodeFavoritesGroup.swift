import CairnServices
import SwiftUI

// MARK: - Grouping

/// The Saved list split for its Favorites group: the favorites among the nodes shown, then
/// everything else, each in the list's own order. Built from the already filtered and sorted
/// list, so the segment, the group filter, search and the sort apply to the group as they do to
/// the rest, and a node is listed in one place only.
struct NodeFavoritesGrouping: Equatable {
  /// Where the list keeps whether the Favorites group is folded; the list's `@AppStorage` reads it.
  static var collapsedKey: AppStorageKey { .nodesFavoritesCollapsed }
  /// Where the list keeps whether the group under it, the other saved nodes, is folded.
  static var othersCollapsedKey: AppStorageKey { .nodesOthersCollapsed }

  /// The favorites, shown in the group at the top; empty when there's no group to show.
  let favorites: [ContactDTO]
  /// The nodes listed under the group, or the whole list when there's no group.
  let others: [ContactDTO]

  /// With the favorites-only filter in effect every node listed is a favorite, so a group would
  /// only add a header over the same list: the list stays flat then. Search and the group filter
  /// set favorites-only aside (see `ContactsViewModel.filteredContacts`), and a mixed result
  /// still gets its group.
  init(_ contacts: [ContactDTO], favoritesOnly: Bool) {
    let favorites = contacts.filter(\.isFavorite)
    if favorites.isEmpty || (favoritesOnly && favorites.count == contacts.count) {
      self.favorites = []
      others = contacts
    } else {
      self.favorites = favorites
      others = contacts.filter { !$0.isFavorite }
    }
  }

  /// Whether the list opens with the Favorites group.
  var showsFavoritesGroup: Bool {
    !favorites.isEmpty
  }

  /// Which of `contacts` are favorites. Unlike the group's own rows it doesn't change with the
  /// search, segment, filters or sort, only when a node is favorited or unfavorited, so the list
  /// animates on that alone.
  static func favoriteMembership(_ contacts: [ContactDTO]) -> Set<UUID> {
    Set(contacts.lazy.filter(\.isFavorite).map(\.id))
  }
}

// MARK: - Header

/// The title row of one of the Saved list's two groups, Favorites and the other saved nodes under
/// it: the group's glyph and title, how many nodes it holds in a pill, and a chevron in a disc
/// that turns as the group folds. The whole row folds the group away and back; the two read
/// alike, so the list under Favorites is plainly a group of its own and not the tail of the
/// favorites.
struct NodeGroupHeader: View {
  enum Kind {
    case favorites
    case others

    var title: String {
      switch self {
      case .favorites: L10n.Contacts.Contacts.Segment.favorites
      case .others: L10n.Contacts.Contacts.List.Group.others
      }
    }

    var symbol: String {
      switch self {
      case .favorites: "star.fill"
      case .others: "person.2.fill"
      }
    }

    var tint: Color {
      switch self {
      case .favorites: .yellow
      case .others: .secondary
      }
    }

    var accessibilityIdentifier: String {
      switch self {
      case .favorites: "nodes.favoritesGroup"
      case .others: "nodes.othersGroup"
      }
    }
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let kind: Kind
  let count: Int
  @Binding var isCollapsed: Bool

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 8) {
        Image(systemName: kind.symbol)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(kind.tint)
          .frame(width: 20)
          .accessibilityHidden(true)
        Text(kind.title)
          .font(.headline)
          .foregroundStyle(.primary)
        Text(count.formatted())
          .font(.caption.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.fill.tertiary, in: .capsule)
        Spacer(minLength: 0)
        Image(systemName: "chevron.down")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .background(.fill.tertiary, in: .circle)
          .rotationEffect(.degrees(isCollapsed ? -90 : 0))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, CardStyle.pageInset + 2)
      // A full-size tap target: in the stack nothing gives it a row's minimum height.
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // Read as "Favorites, 3, Expanded, Button, Heading".
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits([.isHeader, .isButton])
    .accessibilityValue(
      isCollapsed ? L10n.Chats.Chats.Message.Action.collapsed : L10n.Chats.Chats.Message.Action.expanded
    )
    .accessibilityIdentifier(kind.accessibilityIdentifier)
  }

  private func toggle() {
    withAnimation(reduceMotion ? nil : .snappy) { isCollapsed.toggle() }
  }
}
