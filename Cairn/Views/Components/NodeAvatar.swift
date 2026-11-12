import CairnServices
import SwiftUI

/// Avatar view for remote nodes (room servers and repeaters). All repeaters share one theme color,
/// all room servers share another — distinct per category, fixed per theme — unless a photo or a
/// colour was picked for the node. A photo shows untinted; a picked colour fills the disc. A node
/// whose name carries an emoji wears the first of them in place of the mast or door, as a
/// companion's avatar does: its owner chose it.
struct NodeAvatar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.appState) private var appState
  let publicKey: Data
  let role: RemoteNodeRole
  let size: CGFloat
  /// The node's name, for the emoji it may carry; nil shows the role's glyph.
  let name: String?
  /// The picked photo and colour. Nil looks them up by `publicKey` in `NodeAppearanceIndex`.
  private let appearance: NodeAppearance?

  /// Looks up the node's picked photo and colour by its key.
  init(publicKey: Data, role: RemoteNodeRole, size: CGFloat, name: String? = nil) {
    self.publicKey = publicKey
    self.role = role
    self.size = size
    self.name = name
    appearance = nil
  }

  /// Draws the given photo and colour, for a caller that already holds the contact.
  init(publicKey: Data, role: RemoteNodeRole, size: CGFloat, name: String? = nil, photo: Data?, color: NodeAvatarColor?) {
    self.publicKey = publicKey
    self.role = role
    self.size = size
    self.name = name
    appearance = NodeAppearance(color: color, photo: photo, photoRevision: nil)
  }

  var body: some View {
    if let photo = resolved?.photo, let image = AvatarImageCache.image(for: photo) {
      AvatarPhoto(image: image, size: size)
    } else {
      ZStack {
        AvatarDisc(color: fill)

        Group {
          if let emoji = leadingEmoji {
            Text(emoji)
              .font(.system(size: size * 0.46))
          } else {
            icon
              // The mast is tall and slender, so it takes a larger size to fill the pebble as the door does.
              .font(.system(size: size * (role == .repeater ? 0.56 : 0.45), weight: .semibold))
          }
        }
        .foregroundStyle(glyph)
        // Decorative: the symbol name would otherwise be read ahead of the node name.
        .accessibilityHidden(true)
      }
      .frame(width: size, height: size)
    }
  }

  /// The first emoji in the node's name, as `ContactAvatar` picks a companion's.
  private var leadingEmoji: String? {
    name?.first(where: \.isEmoji).map(String.init)
  }

  private var resolved: NodeAppearance? {
    appearance ?? appState.nodeAppearance.appearance(for: publicKey)
  }

  /// A door for a room server; for a repeater, Cairn's own lattice-mast symbol from the asset
  /// catalog (SF Symbols has no radio mast).
  private var icon: Image {
    switch role {
    case .roomServer:
      Image(systemName: "door.left.hand.closed")
    case .repeater:
      Image("cairn.repeater.fill")
    }
  }

  private var category: AvatarCategory {
    role == .roomServer ? .room : .repeater
  }

  private var fill: Color {
    theme.avatarColor(
      resolved?.color,
      category: category,
      colorScheme: colorScheme,
      contrast: colorSchemeContrast
    )
  }

  private var glyph: Color {
    theme.avatarGlyphColor(
      forFill: fill,
      swatch: resolved?.color,
      colorScheme: colorScheme,
      contrast: colorSchemeContrast
    )
  }
}

#Preview("Room Server") {
  NodeAvatar(
    publicKey: Data(repeating: 0x42, count: 32),
    role: .roomServer,
    size: 60
  )
}

#Preview("Repeater") {
  NodeAvatar(
    publicKey: Data(repeating: 0x55, count: 32),
    role: .repeater,
    size: 60
  )
}
