import SwiftUI

/// Card rows for collection lists (log entries, conversations, nodes, neighbours, saved paths):
/// each `List` row draws as its own rounded card with a gap to the next, on the card canvas.
/// The card is the row's background rather than a `cardSurface()` around its content, so the
/// list keeps its swipe actions, selection and disclosure behaviour.
extension View {
  /// Paints this row as a card. Apply to every row of a `.plain` list wrapped in
  /// `cardListCanvas(_:)`.
  func cardListRow(_ theme: Theme, isSelected: Bool = false) -> some View {
    modifier(CardListRowModifier(theme: theme, isSelected: isSelected))
  }

  /// The list around card rows: plain style, no system background, the card canvas behind.
  func cardListCanvas(_ theme: Theme) -> some View {
    listStyle(.plain)
      .scrollContentBackground(.hidden)
      .cardCanvas(theme)
  }
}

private struct CardListRowModifier: ViewModifier {
  let theme: Theme
  let isSelected: Bool

  /// Half the gap between cards: each row gives this much above and below its card.
  private static let halfGap: CGFloat = CardStyle.spacing / 2
  /// Content inset inside the card, matching `cardSurface()`'s default padding.
  private static let contentPadding: CGFloat = 12

  func body(content: Content) -> some View {
    content
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(
        top: Self.halfGap + Self.contentPadding,
        leading: CardStyle.pageInset + Self.contentPadding,
        bottom: Self.halfGap + Self.contentPadding,
        trailing: CardStyle.pageInset + Self.contentPadding
      ))
      .listRowBackground(card)
  }

  private var card: some View {
    CardBackground(isSelected: isSelected)
      .padding(.vertical, Self.halfGap)
      .padding(.horizontal, CardStyle.pageInset)
  }
}
