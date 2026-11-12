import SwiftUI

/// One action of a message's long-press sheet: a tile in `MessageActionGrid`.
struct MessageActionItem: Identifiable {
  /// Stable per action, for the tile's accessibility identifier ("message.action.<id>").
  let id: String
  let title: String
  let icon: String
  var isDestructive = false
  let action: () -> Void
}

/// A message sheet's actions as a grid of compact tiles (a glyph over a short title, as a node
/// page's action row has them), so the actions take two short rows and the message's details sit
/// right under them instead of below eight full-width rows (the user, 2026-11-07). Up to five
/// tiles share one row; more wrap into two even rows; accessibility sizes use two columns.
struct MessageActionGrid: View {
  let items: [MessageActionItem]

  var body: some View {
    if !items.isEmpty {
      NodeActionTileRow(count: items.count) {
        ForEach(items) { item in
          Button(role: item.isDestructive ? .destructive : nil, action: item.action) {
            NodeActionTile(item.title, systemImage: item.icon)
          }
          .buttonStyle(.plain)
          .tint(item.isDestructive ? Color.red : Color.accentColor)
          .accessibilityIdentifier("message.action.\(item.id)")
        }
      }
      .padding(.horizontal)
      // The sheet sits on the plain system background, where the default card fill is the same
      // white in light mode (as the details tiles below).
      .cardFill(Color(.secondarySystemBackground))
    }
  }
}
