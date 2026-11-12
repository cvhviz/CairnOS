import SwiftUI

extension View {
  /// Enables row `.swipeActions` inside this `ScrollView` on iOS 27.
  /// Earlier OSes have no container API, so the row modifiers stay inert outside `List`.
  @ViewBuilder
  func swipeActionsContainerIfAvailable() -> some View {
    if #available(iOS 27, *) {
      swipeActionsContainer()
    } else {
      self
    }
  }

  /// A node list row in either container. In the `List` used before iOS 27 it is a bare row: no
  /// separator, inset or background of its own, so it draws exactly as it does in the iOS 27
  /// `LazyVStack`, where these modifiers do nothing.
  func nodeListRow() -> some View {
    listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  /// Dresses the `List` the node lists use before iOS 27 as the `ScrollView` they use after: plain
  /// style on the page's own canvas, the cards' gap between rows, and no minimum row height, so
  /// the zero-height scroll anchors stay out of the way.
  func nodeListStyle(spacing: CGFloat) -> some View {
    listStyle(.plain)
      .scrollContentBackground(.hidden)
      .listRowSpacing(spacing)
      .environment(\.defaultMinListRowHeight, 1)
  }
}

/// Where the node lists put their rows.
enum NodeListHosting {
  /// Whether the rows go in a `List`: before iOS 27, where row swipe actions work nowhere else.
  /// From iOS 27 on they stay in a `ScrollView` + `LazyVStack` with `swipeActionsContainer()`,
  /// which has no collection view and so none of its selection-delete assertions. The `List` is
  /// never given a selection binding, which is what tripped that assertion.
  nonisolated static var usesList: Bool {
    if #available(iOS 27, *) { false } else { true }
  }
}
