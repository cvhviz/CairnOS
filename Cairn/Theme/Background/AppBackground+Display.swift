import Foundation

extension AppBackground.Kind {
  var localizedName: String {
    switch self {
    case .system: L10n.Settings.Appearance.Scheme.system
    case .solid: L10n.Settings.Appearance.Background.Kind.color
    case .gradient: L10n.Settings.Appearance.Background.Kind.gradient
    case .image: L10n.Settings.Appearance.Background.Kind.photo
    }
  }

  var systemImage: String {
    switch self {
    case .system: "iphone"
    case .solid: "paintbrush.fill"
    case .gradient: "circle.lefthalf.striped.horizontal"
    case .image: "photo.fill"
    }
  }
}

extension AppBackground.GradientStyle {
  var localizedName: String {
    switch self {
    case .linear: L10n.Settings.Appearance.Background.Style.linear
    case .mesh: L10n.Settings.Appearance.Background.Style.mesh
    }
  }
}

extension AppBackground.GradientDirection {
  var localizedName: String {
    switch self {
    case .topToBottom: L10n.Settings.Appearance.Background.Direction.topToBottom
    case .topLeadingToBottomTrailing: L10n.Settings.Appearance.Background.Direction.diagonal
    case .leadingToTrailing: L10n.Settings.Appearance.Background.Direction.sideToSide
    case .bottomLeadingToTopTrailing: L10n.Settings.Appearance.Background.Direction.rising
    }
  }
}

extension SolidBackgroundPreset {
  var localizedName: String {
    switch self {
    case .midnight: L10n.Settings.Appearance.Background.Preset.midnight
    case .ocean: L10n.Settings.Appearance.Background.Preset.ocean
    case .forest: L10n.Settings.Appearance.Background.Preset.forest
    case .plum: L10n.Settings.Appearance.Background.Preset.plum
    case .graphite: L10n.Settings.Appearance.Background.Preset.graphite
    case .sand: L10n.Settings.Appearance.Background.Preset.sand
    case .sage: L10n.Settings.Appearance.Background.Preset.sage
    case .blush: L10n.Settings.Appearance.Background.Preset.blush
    }
  }
}

extension GradientBackgroundPreset {
  var localizedName: String {
    switch self {
    case .dusk: L10n.Settings.Appearance.Background.Preset.dusk
    case .ocean: L10n.Settings.Appearance.Background.Preset.ocean
    case .aurora: L10n.Settings.Appearance.Background.Preset.aurora
    case .sunset: L10n.Settings.Appearance.Background.Preset.sunset
    case .forest: L10n.Settings.Appearance.Background.Preset.forest
    case .graphite: L10n.Settings.Appearance.Background.Preset.graphite
    }
  }
}
