import CairnServices
import SwiftUI
import UIKit

/// Resolves a theme's avatar and name colors for the current appearance. Avatars fill with their
/// category's fixed color (`AvatarCategory.color`) or a picked one; names (senders, mentions) take
/// the same color, solved to clear WCAG AA against every surface they render on (list canvas and
/// incoming bubble).
///
/// Main-actor isolated: these resolve adaptive `UIColor`s and build trait collections, which UIKit
/// requires on the main actor. Every caller (the avatar views and the main-actor message bake)
/// already runs there.
@MainActor
extension Theme {
  /// Relative luminances of the surfaces names sit on, resolved for the given appearance. The
  /// system background and the incoming bubble are the two surfaces a name color must stay
  /// legible against.
  func avatarSurfaceLuminances(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> [Double] {
    let traits = Self.traitCollection(colorScheme: colorScheme, contrast: contrast)
    let surfaces = [Color(.systemBackground), incomingBubbleColor]
    return surfaces.map { WCAGContrast.relativeLuminance(of: UIColor($0).resolvedColor(with: traits)) }
  }

  /// Color a picked swatch tints a name with, legible against both surfaces it renders on (list
  /// canvas and incoming bubble). A hue swatch fills the avatar in this same color.
  func swatchColor(_ swatch: NodeAvatarColor, colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
    identityGamut.color(
      for: swatch,
      backgroundLuminances: avatarSurfaceLuminances(colorScheme: colorScheme, contrast: contrast),
      highContrast: contrast == .increased
    )
  }

  /// Fill for an avatar disc in a picked swatch: a category or custom color exactly, a hue swatch
  /// as solved for this appearance.
  func swatchFill(_ swatch: NodeAvatarColor, colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
    if let rgb = swatch.fixedRGB { return Color(hex: rgb) }
    return swatchColor(swatch, colorScheme: colorScheme, contrast: contrast)
  }

  /// Fill for an avatar disc: the picked swatch, else its category's fixed color.
  func avatarColor(
    _ swatch: NodeAvatarColor?,
    category: AvatarCategory,
    colorScheme: ColorScheme,
    contrast: ColorSchemeContrast
  ) -> Color {
    if let swatch { return swatchFill(swatch, colorScheme: colorScheme, contrast: contrast) }
    return category.color
  }

  /// Color for a node's name where names are tinted (sender names, mentions, map badges): the
  /// picked swatch, with or without a photo, else its category's color, as its avatar wears.
  func nameColor(
    _ swatch: NodeAvatarColor?,
    category: AvatarCategory = .companion,
    colorScheme: ColorScheme,
    contrast: ColorSchemeContrast
  ) -> Color {
    swatchColor(swatch ?? .category(category), colorScheme: colorScheme, contrast: contrast)
  }

  /// Glyph (icon / emoji) color for an avatar of the given fill: white on a category's color, picked
  /// or Automatic (nil); on a hue swatch or custom color, white or near-black, whichever reads.
  func avatarGlyphColor(
    forFill fill: Color,
    swatch: NodeAvatarColor?,
    colorScheme: ColorScheme,
    contrast: ColorSchemeContrast
  ) -> Color {
    if swatch == nil { return .white }
    if case .category = swatch { return .white }
    let traits = Self.traitCollection(colorScheme: colorScheme, contrast: contrast)
    let luminance = WCAGContrast.relativeLuminance(of: UIColor(fill).resolvedColor(with: traits))
    return IdentityGamut.glyphColor(forFillLuminance: luminance)
  }

  static func traitCollection(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> UITraitCollection {
    UITraitCollection { traits in
      traits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
      traits.accessibilityContrast = contrast == .increased ? .high : .unspecified
    }
  }
}
