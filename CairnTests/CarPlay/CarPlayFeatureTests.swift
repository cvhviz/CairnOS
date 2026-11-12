import SwiftUI
@testable import Cairn
import Testing
import UIKit

@Suite("CarPlayFeature")
struct CarPlayFeatureTests {
  private func rgba(_ color: UIColor) -> [CGFloat] {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue, alpha].map { ($0 * 1000).rounded() / 1000 }
  }

  /// The colour the app draws, resolved for a light or dark screen.
  private func app(_ color: Color, _ style: UIUserInterfaceStyle) -> [CGFloat] {
    rgba(UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
  }

  @Test
  func `Tints match the app's colours in light and dark`() {
    let expected: [(CarPlayFeature, Color)] = [
      (.scan, ToolSelection.nodeDiscovery.tileColor),
      (.health, ToolSelection.networkHealth.tileColor),
      (.spectrum, ToolSelection.spectrum.tileColor),
      (.nodes, AppTab.contacts.accentColor),
      (.comm, .blue),
      (.gps, .green),
      (.battery, .green),
      (.radio, .orange),
      (.radioRepeat, AppColors.Radio.repeatMode),
      (.network, HomeStatusCards.cairnTeal),
      // Send Advert and Scan share one colour, as on Home's Tools.
      (.advert, ToolSelection.nodeDiscovery.tileColor),
    ]
    #expect(expected.count == CarPlayFeature.allCases.count)
    for (feature, color) in expected {
      for style in [UIUserInterfaceStyle.light, .dark] {
        #expect(rgba(feature.uiColor(style)) == app(color, style), "\(feature) \(style.rawValue)")
      }
    }
    // System colours are brighter at night, as on the phone.
    #expect(rgba(CarPlayFeature.nodes.uiColor(.light)) != rgba(CarPlayFeature.nodes.uiColor(.dark)))
  }

  @Test
  func `Symbols are the app's`() {
    #expect(CarPlayFeature.scan.symbol == ToolSelection.nodeDiscovery.systemImage)
    #expect(CarPlayFeature.health.symbol == ToolSelection.networkHealth.systemImage)
    #expect(CarPlayFeature.spectrum.symbol == ToolSelection.spectrum.systemImage)
    #expect(CarPlayFeature.nodes.symbol == AppTab.contacts.symbolName)
    #expect(CarPlayFeature.advert.symbol == "megaphone.fill")
  }

  @Test
  func `A secondary state colour draws as the secondary label`() {
    #expect(CarPlayTint.state(.secondary) == .secondaryLabel)
    #expect(CarPlayTint.state(.green) == .color(.green))
  }
}
