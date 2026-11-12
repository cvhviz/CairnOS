import CairnServices
import SwiftUI

struct ChannelAvatar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  let channel: ChannelDTO
  let size: CGFloat

  var body: some View {
    ZStack {
      AvatarDisc(color: fill)

      Image(systemName: channel.isPublicChannel ? "globe" : (channel.name.hasPrefix("#") ? "number" : "lock"))
        .font(.system(size: size * 0.4, weight: .bold))
        .foregroundStyle(glyph)
        // Decorative: the symbol name would otherwise be read ahead of the channel name.
        .accessibilityHidden(true)
    }
    .frame(width: size, height: size)
  }

  private var fill: Color {
    AvatarCategory.channel.color
  }

  private var glyph: Color {
    theme.avatarGlyphColor(
      forFill: fill,
      swatch: nil,
      colorScheme: colorScheme,
      contrast: colorSchemeContrast
    )
  }
}
