import SwiftUI

/// Animated linear-gradient sweep. One repeating animation on a geometry effect moves the
/// highlight, so the sweep runs without re-evaluating any view body per frame (a per-frame
/// `TimelineView` did) and needs no `GeometryReader` to know how far to travel. Callers pass
/// `isActive: false` under Reduce Motion for a static placeholder.
struct Shimmer: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    if isActive {
      content
        .overlay { ShimmerSweep() }
        .clipped()
    } else {
      content
    }
  }
}

/// The highlight itself. Its own view, so each appearance starts a fresh sweep.
private struct ShimmerSweep: View {
  private static let duration: Double = 1.5
  private static let highlightOpacity: Double = 0.35

  @State private var isSweeping = false

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .white.opacity(Self.highlightOpacity), location: 0.5),
        .init(color: .clear, location: 1)
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
    .modifier(ShimmerOffset(phase: isSweeping ? 1 : -1))
    // Scoped to the sweep, so the repeating animation never leaks into the host's layout.
    .animation(.linear(duration: Self.duration).repeatForever(autoreverses: false), value: isSweeping)
    .onAppear { isSweeping = true }
    .allowsHitTesting(false)
  }
}

/// Moves the highlight by `phase` of its own width: -1 fully off the leading edge, 1 fully
/// off the trailing edge.
private struct ShimmerOffset: GeometryEffect {
  var phase: CGFloat

  var animatableData: CGFloat {
    get { phase }
    set { phase = newValue }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: phase * size.width, y: 0))
  }
}
