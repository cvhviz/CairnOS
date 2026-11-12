import SwiftUI
import UIKit

/// The user's background ready to paint: the settings plus, for a photo, the decoded (and, when
/// blurred, pre-rendered) image. Built by `ThemeService`; carried on `Theme.backdrop`.
///
/// `@unchecked Sendable`: `UIImage` is immutable once made, and nothing here mutates.
struct ResolvedBackdrop: Equatable, @unchecked Sendable {
  let settings: AppBackground
  /// The photo to draw, already blurred to `settings.blur`. `nil` for colors and gradients.
  let image: UIImage?

  static func == (lhs: ResolvedBackdrop, rhs: ResolvedBackdrop) -> Bool {
    lhs.settings == rhs.settings && lhs.image === rhs.image
  }

  /// One flat color close to what the page shows, dim included. Adapts with the appearance
  /// because the dim wash does (white in Light Mode, black in Dark Mode).
  var approximateColor: Color {
    let base = settings.baseApproximateColor
    let dim = settings.dim
    return Color(uiColor: UIColor { traits in
      let wash: BackgroundColor = traits.userInterfaceStyle == .dark ? .black : .white
      return base.mixed(with: wash, by: dim).uiColor
    })
  }
}

/// Paints a background edge to edge: the color, gradient or photo, then the dim wash.
///
/// Decorative: hidden from accessibility and never hit-tested.
struct AppBackdropView: View {
  let backdrop: ResolvedBackdrop

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      base
      // Dim washes toward the system background (black in Dark Mode, white in Light Mode),
      // pushing the background away from the label color so text on glass stays legible.
      (colorScheme == .dark ? Color.black : Color.white)
        .opacity(backdrop.settings.dim)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var base: some View {
    let settings = backdrop.settings
    switch settings.kind {
    case .system:
      Color(.systemGroupedBackground)
    case .solid:
      settings.solidColor.color
    case .gradient:
      BackgroundGradientView(
        colors: settings.gradientColors,
        style: settings.gradientStyle,
        direction: settings.gradientDirection
      )
    case .image:
      if let image = backdrop.image {
        // An aspect-filled photo sized by the page, not by its own pixels: the clear color takes
        // the proposed size and the overlay fills it.
        Color.clear
          .overlay {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
          }
          .clipped()
      } else {
        Color(.systemGroupedBackground)
      }
    }
  }
}

/// A gradient background: linear along the chosen direction, or a soft mesh of the same colors.
struct BackgroundGradientView: View {
  let colors: [BackgroundColor]
  let style: AppBackground.GradientStyle
  let direction: AppBackground.GradientDirection

  var body: some View {
    switch style {
    case .linear:
      LinearGradient(
        colors: colors.map(\.color),
        startPoint: direction.startPoint,
        endPoint: direction.endPoint
      )
    case .mesh:
      MeshGradient(
        width: 3,
        height: 3,
        points: Self.meshPoints,
        colors: Self.meshColors(colors).map(\.color),
        smoothsColors: true
      )
    }
  }

  /// A 3×3 grid with the centre nudged off-axis, so the blend reads organic rather than as a
  /// plain diagonal.
  private static let meshPoints: [SIMD2<Float>] = [
    [0, 0], [0.5, 0], [1, 0],
    [0, 0.5], [0.62, 0.42], [1, 0.5],
    [0, 1], [0.5, 1], [1, 1],
  ]

  /// Spreads two or three colors over the 3×3 grid: the first in the top-leading corner, the
  /// last in the bottom-trailing one, the middle color (or the blend of two) through the centre.
  static func meshColors(_ colors: [BackgroundColor]) -> [BackgroundColor] {
    let first = colors.first ?? .black
    let last = colors.last ?? first
    let middle = colors.count >= 3 ? colors[1] : first.mixed(with: last, by: 0.5)
    return [
      first, first, middle,
      first, middle, last,
      middle, last, last,
    ]
  }
}
