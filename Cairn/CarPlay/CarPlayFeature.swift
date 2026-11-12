import CairnServices
import SwiftUI
import UIKit

/// The app's features as CarPlay draws them: the same SF Symbol and the same tint as the
/// matching Home card or Tools tile, read from the app's own sources wherever one exists, so the
/// car's colours can't drift from the phone's.
enum CarPlayFeature: CaseIterable, Hashable {
  case battery
  case network
  case radio
  /// The Radio card while the radio repeats (`clientRepeat`).
  case radioRepeat
  case gps
  case nodes
  case comm
  case advert
  case scan
  case health
  case spectrum

  /// The card's or tile's glyph. Battery, Network and GPS cards pick a state-specific glyph at
  /// build time; this is their default.
  var symbol: String {
    switch self {
    case .battery: BatteryLevel.symbol(for: 100)
    case .network: "antenna.radiowaves.left.and.right"
    case .radio, .radioRepeat: "waveform"
    case .gps: "location.fill"
    case .nodes: AppTab.contacts.symbolName
    case .comm: "bubble.left.and.bubble.right.fill"
    case .advert: "megaphone.fill"
    case .scan: ToolSelection.nodeDiscovery.systemImage
    case .health: ToolSelection.networkHealth.systemImage
    case .spectrum: ToolSelection.spectrum.systemImage
    }
  }

  /// The SwiftUI colour the app uses for the same card or tile (HomeStatusCards, HomeToolsSheet,
  /// ToolSelection.tileColor).
  var color: Color {
    switch self {
    case .battery: BatteryLevel.good.tint
    case .network: HomeStatusCards.cairnTeal
    case .radio: .orange
    case .radioRepeat: AppColors.Radio.repeatMode
    case .gps: .green
    case .nodes: AppTab.contacts.accentColor
    case .comm: .blue
    // Send Advert and Scan share one colour, as on Home's Tools.
    case .advert: ToolSelection.nodeDiscovery.tileColor
    case .scan: ToolSelection.nodeDiscovery.tileColor
    case .health: ToolSelection.networkHealth.tileColor
    case .spectrum: ToolSelection.spectrum.tileColor
    }
  }

  /// The colour resolved for a light or a dark car screen.
  func uiColor(_ style: UIUserInterfaceStyle) -> UIColor {
    CarPlayTint.resolve(color, style: style)
  }
}

/// How a CarPlay glyph or tile is coloured. Pure values, so a snapshot can carry them and the
/// image cache can key on them.
enum CarPlayTint: Hashable {
  /// Cairn's teal, for glyphs with no feature of their own.
  case brand
  case label
  case secondaryLabel
  case white
  case success
  case warning
  case critical
  case feature(CarPlayFeature)
  /// A colour the app computes for a state (`SNRQuality.color`, `GNSSStatus.tint`).
  case color(Color)
  /// A category's avatar colour in Cairn's palette (`CarPlayAvatar`).
  case avatar(AvatarCategory)
  /// A colour picked for a node on the phone (`NodeAvatarColor`).
  case swatch(NodeAvatarColor)

  @MainActor
  func color(for style: UIUserInterfaceStyle) -> UIColor {
    let traits = UITraitCollection(userInterfaceStyle: style)
    switch self {
    // Cairn's teal (#3BA89D): deeper on a light screen and lighter on a dark one, so it keeps its
    // contrast in sunlight and at night.
    case .brand:
      return style == .dark
        ? UIColor(red: 0.36, green: 0.80, blue: 0.75, alpha: 1)
        : UIColor(red: 0.12, green: 0.50, blue: 0.46, alpha: 1)
    case .label:
      return UIColor.label.resolvedColor(with: traits)
    case .secondaryLabel:
      return UIColor.secondaryLabel.resolvedColor(with: traits)
    case .white:
      return .white
    case .success:
      return Self.resolve(.green, style: style)
    case .warning:
      return Self.resolve(.orange, style: style)
    case .critical:
      return Self.resolve(.red, style: style)
    case let .feature(feature):
      return feature.uiColor(style)
    case let .color(color):
      return Self.resolve(color, style: style)
    case let .avatar(category):
      return CarPlayAvatar.categoryColor(category)
    case let .swatch(swatch):
      return CarPlayAvatar.swatchColor(swatch, style: style)
    }
  }

  /// A SwiftUI colour as UIKit draws it on a light or dark screen. System colours (.green,
  /// .purple…) are dynamic, so the dark variant is the brighter one the phone uses at night.
  static func resolve(_ color: Color, style: UIUserInterfaceStyle) -> UIColor {
    UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
  }

  /// A state colour from the app, with the app's "secondary" (no state to show) mapped to the
  /// secondary label colour UIKit can draw.
  static func state(_ color: Color) -> CarPlayTint {
    color == .secondary ? .secondaryLabel : .color(color)
  }
}
