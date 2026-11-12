import CairnServices
import MeshCore
import SwiftUI

extension AvatarCategory {
  /// A saved node's category by its type.
  init(_ type: ContactType) {
    switch type {
    case .chat: self = .companion
    case .repeater: self = .repeater
    case .room: self = .room
    }
  }

  /// The category's fixed avatar colour, as 0xRRGGBB. One hue per type so each tells apart at a
  /// glance on the map and in lists, every one dark enough to carry a white glyph. Repeaters take
  /// the indigo of Send Advert and Scan (`ToolSelection.nodeDiscovery.tileColor`), the tools that
  /// reach them; the user's own radio takes the app's accent blue: it stands for you.
  var rgb: Int {
    switch self {
    case .companion: 0x16A34A
    case .repeater: 0x5856D6
    case .room: 0xDB2777
    case .channel: 0x0891B2
    case .radio: 0x2463EB
    }
  }

  var color: Color {
    Color(hex: rgb)
  }
}

extension NodeAvatarColor {
  /// The exact colour a category or custom pick fills an avatar with; nil for a hue swatch, which
  /// the theme solves per appearance.
  var fixedRGB: Int? {
    switch self {
    case let .category(category): category.rgb
    case let .custom(rgb): rgb
    default: nil
    }
  }
}
