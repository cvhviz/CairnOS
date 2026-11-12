import CairnServices
import SwiftUI
import UIKit

/// Process-lifetime cache of decoded avatar images, keyed by the raw JPEG data.
/// Avoids re-running `UIImage(data:)` on every cell redraw while scrolling a contact list.
enum AvatarImageCache {
  /// NSCache is internally thread-safe; its lack of Sendable conformance is a
  /// missing annotation in Foundation, not an actual data race risk here.
  nonisolated(unsafe) static let shared = NSCache<NSData, UIImage>()

  /// The decoded photo, from the cache when it has been drawn before.
  static func image(for data: Data) -> UIImage? {
    let key = data as NSData
    if let cached = shared.object(forKey: key) {
      return cached
    }
    guard let decoded = UIImage(data: data) else { return nil }
    shared.setObject(decoded, forKey: key, cost: data.count)
    return decoded
  }
}

/// A picked avatar photo, filling the pebble untinted.
struct AvatarPhoto: View {
  let image: UIImage
  let size: CGFloat

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(AvatarPebble())
  }
}

struct ContactAvatar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  let name: String
  let size: CGFloat
  let imageData: Data?
  /// The picked colour; nil means Automatic (the category's colour).
  let color: NodeAvatarColor?
  /// Companion, or `.radio` for one of the user's own radios.
  let category: AvatarCategory

  init(contact: ContactDTO, size: CGFloat) {
    name = contact.displayName
    self.size = size
    imageData = contact.avatarImageData
    color = contact.avatarColor
    category = .companion
  }

  init(name: String, size: CGFloat) {
    self.init(name: name, size: size, imageData: nil)
  }

  init(
    name: String,
    size: CGFloat,
    imageData: Data?,
    color: NodeAvatarColor? = nil,
    category: AvatarCategory = .companion
  ) {
    self.name = name
    self.size = size
    self.imageData = imageData
    self.color = color
    self.category = category
  }

  var body: some View {
    if let imageData, let uiImage = AvatarImageCache.image(for: imageData) {
      AvatarPhoto(image: uiImage, size: size)
    } else {
      // Without a photo, a companion is a radio: Cairn's walkie-talkie on its category's colour,
      // or the one picked for it. A name that leads with an emoji keeps that emoji, which its
      // owner chose.
      Group {
        if let emoji = leadingEmoji {
          Text(emoji)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
        } else {
          Image(AppTab.home.symbolName)
            .font(.system(size: size * 0.42, weight: .semibold))
        }
      }
      .foregroundStyle(glyphColor)
      .frame(width: size, height: size)
      .background { AvatarDisc(color: avatarColor) }
      // Decorative: the glyph would otherwise be read ahead of the name beside the avatar.
      .accessibilityHidden(true)
    }
  }

  private var leadingEmoji: String? {
    name.first(where: \.isEmoji).map(String.init)
  }

  private var avatarColor: Color {
    theme.avatarColor(color, category: category, colorScheme: colorScheme, contrast: colorSchemeContrast)
  }

  private var glyphColor: Color {
    theme.avatarGlyphColor(
      forFill: avatarColor,
      swatch: color,
      colorScheme: colorScheme,
      contrast: colorSchemeContrast
    )
  }
}

/// A companion known by name and key but not as a `ContactDTO` here (a discovered node, a node
/// being added): the photo and colour picked for the contact with that key, if there is one.
struct CompanionAvatar: View {
  @Environment(\.appState) private var appState
  let name: String
  let publicKey: Data
  let size: CGFloat

  var body: some View {
    let appearance = appState.nodeAppearance.appearance(for: publicKey)
    ContactAvatar(name: name, size: size, imageData: appearance?.photo, color: appearance?.color)
  }
}
