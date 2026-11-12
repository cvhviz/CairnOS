import SwiftUI

/// Keeps a floating card off an iPhone Duo's fold. While the device is partly folded like a book,
/// the inner display reports the crease as an active division region; a card centred across it
/// would bend over the fold, so it moves onto one side with room around the hinge. Flat, the
/// region is inactive (and on every other device there is none), so nothing moves.
enum FoldAvoidance {
  /// Room kept between the card and the hinge, as Apple's own apps widen spacing around it.
  nonisolated static let hingeSpacing: CGFloat = 16

  /// The insets that hold a view of `width` on the `edge` side of the first upright fold crossing
  /// it, or none. `dividers` are the active division frames in the view's own coordinates. A fold
  /// across the view (laptop posture) is left alone: a card pinned to an edge already sits in one
  /// region, and padding it vertically would change the height it was measured at.
  nonisolated static func insets(
    dividers: [CGRect],
    width: CGFloat,
    keeping edge: HorizontalEdge,
    spacing: CGFloat = hingeSpacing
  ) -> EdgeInsets {
    guard let fold = dividers.first(where: { $0.height > $0.width && $0.minX > 0 && $0.maxX < width }) else {
      return EdgeInsets()
    }
    switch edge {
    case .leading:
      return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: width - fold.minX + spacing)
    case .trailing:
      return EdgeInsets(top: 0, leading: fold.maxX + spacing, bottom: 0, trailing: 0)
    }
  }
}

private struct FoldAvoidanceModifier: ViewModifier {
  let edge: HorizontalEdge
  @State private var insets = EdgeInsets()

  func body(content: Content) -> some View {
    if #available(iOS 27.1, *) {
      content
        // Folded, the card fills its side and centres there; flat, it keeps its own width.
        .frame(maxWidth: insets == EdgeInsets() ? nil : .infinity)
        .padding(insets)
        // Measured on the full-width frame, which the insets never resize, so they can't feed back.
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: EdgeInsets.self) { proxy in
          FoldAvoidance.insets(
            dividers: proxy.reservedRegions(kind: .division).map(\.frame),
            width: proxy.size.width,
            keeping: edge
          )
        } action: { newInsets in
          withAnimation(.smooth) { insets = newInsets }
        }
    } else {
      content
    }
  }
}

extension View {
  /// Moves this floating card to one side of an iPhone Duo's fold while it is partly folded. The
  /// card takes the full width it is offered, so apply it to a card that is centred in a stack.
  func avoidsFold(keeping edge: HorizontalEdge = .trailing) -> some View {
    modifier(FoldAvoidanceModifier(edge: edge))
  }
}
