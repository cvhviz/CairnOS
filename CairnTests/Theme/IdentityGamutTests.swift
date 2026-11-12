@testable import Cairn
@testable import CairnServices
import SwiftUI
import Testing
import UIKit

/// Validates the name-colour solver in isolation: every pick (hue swatch, category colour, and a
/// sweep of custom colours) must resolve to a colour that clears WCAG AA against the surfaces it
/// renders on, in both appearances and both contrast settings.
@Suite("IdentityGamut contrast")
struct IdentityGamutTests {
  private let gamut = IdentityGamut(saturation: 0.45...0.75)

  /// The hue swatches, the category colours, and custom colours across the RGB cube (the 216
  /// web-safe colours), from black through mid-tones to white.
  private static let picks: [NodeAvatarColor] = {
    let steps = [0x00, 0x33, 0x66, 0x99, 0xCC, 0xFF]
    var customs: [NodeAvatarColor] = []
    for red in steps {
      for green in steps {
        for blue in steps {
          customs.append(.custom(rgb: red << 16 | green << 8 | blue))
        }
      }
    }
    return NodeAvatarColor.hues + AvatarCategory.allCases.map(NodeAvatarColor.category) + customs
  }()

  private static let light = UITraitCollection(userInterfaceStyle: .light)
  private static let dark = UITraitCollection(userInterfaceStyle: .dark)

  private func luminance(of color: Color, _ trait: UITraitCollection) -> Double {
    WCAGContrast.relativeLuminance(of: UIColor(color).resolvedColor(with: trait))
  }

  private func surfaceLuminances(_ trait: UITraitCollection) -> [Double] {
    [
      luminance(of: Color(.systemBackground), trait),
      luminance(of: Color(.secondarySystemBackground), trait),
      luminance(of: Color(UIColor.systemGray5), trait)
    ]
  }

  @Test
  func `every pick clears AA against its surfaces in both appearances and contrasts`() {
    for trait in [Self.light, Self.dark] {
      for highContrast in [false, true] {
        let backgrounds = surfaceLuminances(trait)
        let floor = highContrast ? WCAGContrast.increasedContrastFloor : WCAGContrast.aaFloor
        for pick in Self.picks {
          let color = gamut.color(for: pick, backgroundLuminances: backgrounds, highContrast: highContrast)
          let colorLuminance = luminance(of: color, trait)
          for background in backgrounds {
            let ratio = WCAGContrast.contrastRatio(colorLuminance, background)
            #expect(ratio >= floor, "\(pick) luminance \(colorLuminance) vs surface \(background) is \(ratio), below \(floor)")
          }
        }
      }
    }
  }

  @Test
  func `a pick keeps its hue across appearance`() {
    let lightBackgrounds = surfaceLuminances(Self.light)
    let darkBackgrounds = surfaceLuminances(Self.dark)
    let saturated = NodeAvatarColor.hues + AvatarCategory.allCases.map(NodeAvatarColor.category)
    for pick in saturated {
      let lightHue = gamut.resolve(swatch: pick, backgroundLuminances: lightBackgrounds, highContrast: false).hue
      let darkHue = gamut.resolve(swatch: pick, backgroundLuminances: darkBackgrounds, highContrast: false).hue
      #expect(abs(lightHue - darkHue) < 0.001, "\(pick) hue drifted across appearance: \(lightHue) vs \(darkHue)")
    }
  }
}
