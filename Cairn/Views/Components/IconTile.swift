import SwiftUI

/// The small filled rounded square that carries a white glyph, the system Settings icon style.
/// The glyph is white on the tile color, so the tile reads the same in light and dark mode.
struct IconTile: View {
  let systemImage: String
  let color: Color
  @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 28

  init(systemImage: String, color: Color) {
    self.systemImage = systemImage
    self.color = color
  }

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: tileSize * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: tileSize, height: tileSize)
      .background(color.gradient, in: .rect(cornerRadius: tileSize * 0.25, style: .continuous))
  }
}
