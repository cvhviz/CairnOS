import SwiftUI

/// How a node list lays out its nodes: one row each, or a grid of cards. Stored by raw value
/// under `AppStorageKey.nodesDisplayMode` and `.discoveryDisplayMode`, so keep the raw values.
enum NodeDisplayMode: String, CaseIterable {
  case list
  case cards

  /// The mode's name in the Nodes tab's Layout picker.
  var title: String {
    switch self {
    case .list: L10n.Contacts.Contacts.TabSettings.Layout.list
    case .cards: L10n.Contacts.Contacts.TabSettings.Layout.cards
    }
  }

  /// What the toggle does when it shows this mode as its target.
  var switchTitle: String {
    switch self {
    case .list: L10n.Contacts.Contacts.List.DisplayMode.showList
    case .cards: L10n.Contacts.Contacts.List.DisplayMode.showCards
    }
  }

  var systemImage: String {
    switch self {
    case .list: "list.bullet"
    case .cards: "square.grid.2x2"
    }
  }
}

extension View {
  /// The pinned segment header's backing on the node lists. iOS 26 glass pills carry their own
  /// material; the iOS 18 segmented fallback is transparent, so it gets the page's own canvas —
  /// the grouped background the node cards sit on, not the plain one `pinnedFilterHeaderBackground`
  /// assumes.
  @ViewBuilder
  func nodeListHeaderBackground(_ theme: Theme) -> some View {
    if #available(iOS 26.0, *) {
      self
    } else {
      background(theme.canvasColor ?? Color(.systemGroupedBackground))
    }
  }
}
