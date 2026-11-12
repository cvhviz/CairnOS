@testable import Cairn
@testable import CairnServices
import SwiftUI
import Testing
import UIKit

/// Guards the legibility of name colors (senders, mentions) against the surfaces they render on,
/// in every appearance/contrast combination: each category's Automatic color and every swatch.
/// These are surfaces a user reads under stress and outdoor glare, so they must clear the WCAG AA
/// 4.5:1 floor.
@Suite("Theme contrast")
struct ThemeContrastTests {
  private static let traits: [(name: String, style: UIUserInterfaceStyle, collection: UITraitCollection)] = [
    ("light", .light, UITraitCollection(userInterfaceStyle: .light)),
    ("dark", .dark, UITraitCollection(userInterfaceStyle: .dark)),
    ("light+highContrast", .light, UITraitCollection(userInterfaceStyle: .light).modifyingTraits {
      $0.accessibilityContrast = .high
    }),
    ("dark+highContrast", .dark, UITraitCollection(userInterfaceStyle: .dark).modifyingTraits {
      $0.accessibilityContrast = .high
    })
  ]

  private static func floor(forTraitNamed name: String) -> Double {
    name.contains("highContrast") ? WCAGContrast.increasedContrastFloor : WCAGContrast.aaFloor
  }

  private static func luminance(of color: Color, _ collection: UITraitCollection) -> Double {
    WCAGContrast.relativeLuminance(of: UIColor(color).resolvedColor(with: collection))
  }

  /// System background and incoming bubble — the two surfaces identity colors must stay legible
  /// against.
  private static func surfaceLuminances(_ theme: Theme, _ collection: UITraitCollection) -> [Double] {
    [Color(.systemBackground), theme.incomingBubbleColor]
      .map { luminance(of: $0, collection) }
  }

  @Test
  @MainActor
  func `name colors clear AA against their surfaces for every theme and appearance`() {
    let picks = NodeAvatarColor.hues.map(Optional.some) + [nil]
    for theme in [Theme.default] {
      for trait in Self.traits {
        let floor = Self.floor(forTraitNamed: trait.name)
        let scheme: ColorScheme = trait.style == .dark ? .dark : .light
        let contrast: ColorSchemeContrast = trait.name.contains("highContrast") ? .increased : .standard
        let backgrounds = Self.surfaceLuminances(theme, trait.collection)
        for category in AvatarCategory.allCases {
          for pick in picks {
            let color = theme.nameColor(pick, category: category, colorScheme: scheme, contrast: contrast)
            let colorLuminance = Self.luminance(of: color, trait.collection)
            for background in backgrounds {
              let ratio = WCAGContrast.contrastRatio(colorLuminance, background)
              #expect(ratio >= floor, "\(theme.id) \(category) \(String(describing: pick)) vs \(background) in \(trait.name) is \(ratio)")
            }
          }
        }
      }
    }
  }
}
