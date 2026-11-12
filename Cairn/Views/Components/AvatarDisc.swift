import SwiftUI

/// Cairn's avatar outline: a smooth stone, a squircle with deep continuous corners. Rounder than
/// an app icon so it never reads as one, squarer than a circle. Every avatar, photo or generated,
/// draws and clips to it; the photo cropper frames to it too.
struct AvatarPebble: InsettableShape {
  /// Corner radius as a share of the shorter side.
  static let cornerFraction: CGFloat = 0.36

  /// How far `strokeBorder` has drawn the outline in from the edge.
  var insetAmount: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let inner = rect.insetBy(dx: insetAmount, dy: insetAmount)
    return RoundedRectangle(cornerRadius: min(inner.width, inner.height) * Self.cornerFraction, style: .continuous)
      .path(in: inner)
  }

  func inset(by amount: CGFloat) -> AvatarPebble {
    var copy = self
    copy.insetAmount += amount
    return copy
  }
}

/// Pebble fill shared by the generated avatars (contacts, channels, nodes): a soft top-lit
/// gradient over the avatar color plus a hairline rim, so pale fills keep an edge on light
/// canvases. Increase Contrast falls back to the flat fill the glyph color was computed against.
struct AvatarDisc: View {
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  let color: Color

  var body: some View {
    AvatarPebble()
      .fill(colorSchemeContrast == .increased ? AnyShapeStyle(color) : AnyShapeStyle(color.gradient))
      .overlay {
        AvatarPebble().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
      }
  }
}
