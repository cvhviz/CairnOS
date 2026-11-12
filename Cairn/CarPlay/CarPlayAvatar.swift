import CairnServices
import MeshCore
import SwiftUI
import Synchronization
import UIKit

/// The phone's avatars for the car: the same glyph on the same pebble colour as `ContactAvatar`,
/// `NodeAvatar` and `ChannelAvatar`, in Cairn's own palette (`Theme.default`). A companion is
/// Cairn's walkie-talkie (or the emoji its name leads with) on moss, a repeater the lattice mast
/// on the brand teal, a room server a door on sandstone, a channel a globe, hash or lock on slate. Pure values, so the snapshot can carry them;
/// `CarPlayTemplates.avatar` draws them. Contact photos stay on the phone.
enum CarPlayAvatar {
  /// Cairn's walkie-talkie, a MeshCore radio (`ContactAvatar` without a photo).
  static let companionSymbol = AppTab.home.symbolName
  /// Cairn's lattice mast (`NodeAvatar`); SF Symbols has no radio mast.
  static let repeaterSymbol = "cairn.repeater.fill"
  /// A room server's door (`NodeAvatar`).
  static let roomSymbol = "door.left.hand.closed"
  /// A channel's hash (`ChannelAvatar` for a hashtag channel).
  static let channelSymbol = "number"
  /// The public channel's globe and a private channel's lock (`ChannelAvatar`).
  static let publicChannelSymbol = "globe"
  static let privateChannelSymbol = "lock"
  /// Marks an avatar "symbol" that is an emoji to draw as text: "emoji:🚒".
  static let emojiPrefix = "emoji:"
  static let favoriteSymbol = "star.fill"
  /// The nodes heard in the last hour.
  static let recentSymbol = "dot.radiowaves.left.and.right"
  /// The nodes heard by advert and not saved (the phone's Heard list and its empty state).
  static let heardSymbol = "antenna.radiowaves.left.and.right"

  /// A node's avatar glyph by kind; a companion whose name leads with an emoji shows that emoji,
  /// which its owner chose, as `ContactAvatar` does.
  static func symbol(_ type: ContactType, name: String) -> String {
    switch type {
    case .chat: companion(name)
    case .repeater: repeaterSymbol
    case .room: roomSymbol
    }
  }

  /// The walkie-talkie, or the first emoji in the name (`emojiPrefix`).
  static func companion(_ name: String) -> String {
    name.first(where: \.isEmoji).map { emojiPrefix + String($0) } ?? companionSymbol
  }

  /// The emoji an avatar symbol stands for, or nil for a glyph.
  static func emoji(_ symbol: String) -> String? {
    symbol.hasPrefix(emojiPrefix) ? String(symbol.dropFirst(emojiPrefix.count)) : nil
  }

  /// Lowered node name → the colour picked for it on the phone (`NodeAppearanceIndex`), set by the
  /// controller with each snapshot's inputs so every builder sees the same colours.
  static let pickedColors = Mutex<[String: NodeAvatarColor]>([:])

  static func pickedColor(forName name: String) -> NodeAvatarColor? {
    pickedColors.withLock { $0[name.lowercased()] }
  }

  /// A node's avatar colour: the one picked for it on the phone, else its kind's.
  static func tint(_ type: ContactType, name: String) -> CarPlayTint {
    if let picked = pickedColor(forName: name) { return .swatch(picked) }
    return switch type {
    case .chat: .avatar(.companion)
    case .repeater: .avatar(.repeater)
    case .room: .avatar(.room)
    }
  }

  /// A companion's colour by name: the one picked for it, else the companions'.
  static func companionTint(_ name: String) -> CarPlayTint {
    pickedColor(forName: name).map(CarPlayTint.swatch) ?? .avatar(.companion)
  }

  /// The connected radio's colour: the one picked for it, else the radio colour.
  static func radioTint(_ name: String) -> CarPlayTint {
    pickedColor(forName: name).map(CarPlayTint.swatch) ?? .avatar(.radio)
  }

  /// A conversation's avatar glyph, as the Chats list draws it: a direct chat as its companion,
  /// the public channel a globe, a hashtag channel a hash, a private one a lock.
  static func symbol(_ line: HomeDashboardModel.ConversationLine) -> String {
    switch line.kind {
    case .direct: companion(line.name)
    case .channel: line.isPublicChannel ? publicChannelSymbol : (line.isHashtagChannel ? channelSymbol : privateChannelSymbol)
    case .room: roomSymbol
    }
  }

  /// A conversation's avatar colour: a direct chat's or room's picked colour, else its kind's.
  static func tint(_ kind: HomeDashboardModel.ConversationLine.Kind, name: String) -> CarPlayTint {
    if kind != .channel, let picked = pickedColor(forName: name) { return .swatch(picked) }
    return switch kind {
    case .direct: .avatar(.companion)
    case .channel: .avatar(.channel)
    case .room: .avatar(.room)
    }
  }

  /// A Nodes group's tile: the glyph and colour of the nodes it holds; a star for Favorites.
  static func symbol(_ category: CarPlaySnapshot.NodeCategory) -> String {
    switch category {
    case .recentlyHeard: recentSymbol
    case .favorites: favoriteSymbol
    case .contacts: companionSymbol
    case .repeaters: repeaterSymbol
    case .rooms: roomSymbol
    case .heard: heardSymbol
    case .nearby: nearbySymbol
    }
  }

  /// The Nearby group's glyph: the app's location arrow.
  static let nearbySymbol = "location.fill"

  static func tint(_ category: CarPlaySnapshot.NodeCategory) -> CarPlayTint {
    switch category {
    case .recentlyHeard: .feature(.nodes)
    // The favourite star's yellow, as on the node rows' badge.
    case .favorites: .color(.yellow)
    case .contacts: .avatar(.companion)
    case .repeaters: .avatar(.repeater)
    case .rooms: .avatar(.room)
    // Heard by a scan or an advert: the scan tool's colour.
    case .heard: .feature(.scan)
    // Where things are: the GPS tab's colour.
    case .nearby: .feature(.gps)
    }
  }

  /// The glyph's colour on an avatar of this fill: white on Cairn's fixed category colours, picked
  /// or not, otherwise white or near-black, whichever reads on the fill, as the phone picks.
  static func glyphColor(on tint: CarPlayTint, fill: UIColor) -> UIColor {
    switch tint {
    case .avatar, .feature, .brand, .success, .warning, .critical, .white, .label, .secondaryLabel, .swatch(.category):
      return .white
    case .color, .swatch:
      return UIColor(IdentityGamut.glyphColor(forFillLuminance: WCAGContrast.relativeLuminance(of: fill)))
    }
  }

  /// A picked swatch's avatar fill as the phone draws it in a light or dark appearance
  /// (`Theme.swatchFill`).
  @MainActor
  static func swatchColor(_ swatch: NodeAvatarColor, style: UIUserInterfaceStyle) -> UIColor {
    let scheme: ColorScheme = style == .dark ? .dark : .light
    let color = Theme.default.swatchFill(swatch, colorScheme: scheme, contrast: .standard)
    return UIColor(color).resolvedColor(with: Theme.traitCollection(colorScheme: scheme, contrast: .standard))
  }

  /// A category's fixed colour in Cairn's palette.
  static func categoryColor(_ category: AvatarCategory) -> UIColor {
    UIColor(category.color)
  }
}
