import CairnServices
import SwiftUI
import UIKit

extension ContactGroup {
  /// The group's accent color; unknown stored names fall back to blue.
  var tint: Color {
    (Palette(rawValue: color) ?? .blue).swatch
  }

  /// Spoken name for an editor symbol choice. A symbol outside `symbolChoices` falls back
  /// to the generic "Icon" rather than reading out its SF Symbol name.
  static func localizedSymbolName(_ symbol: String) -> String {
    typealias Names = L10n.Contacts.Contacts.Groups.SymbolName
    return switch symbol {
    case "person.3.fill": Names.people
    case "person.2.fill": Names.twoPeople
    case "house.fill": Names.house
    case "briefcase.fill": Names.briefcase
    case "heart.fill": Names.heart
    case "star.fill": Names.star
    case "flag.fill": Names.flag
    case "cross.case.fill": Names.firstAidKit
    case "car.fill": Names.car
    case "mountain.2.fill": Names.mountains
    case "antenna.radiowaves.left.and.right": Names.antenna
    case "bolt.fill": Names.lightningBolt
    case "leaf.fill": Names.leaf
    case "tent.fill": Names.tent
    case "shield.fill": Names.shield
    case "tag.fill": Names.tag
    default: L10n.Contacts.Contacts.Groups.icon
    }
  }

  /// Nodes from `contacts` that belong to this group, in the given order.
  func members(in contacts: [ContactDTO]) -> [ContactDTO] {
    let keys = Set(memberKeys)
    return contacts.filter { keys.contains(ContactGroup.memberKey(for: $0.publicKey)) }
  }
}

extension ContactGroup.Palette {
  var swatch: Color {
    switch self {
    case .blue: .blue
    case .green: .green
    case .orange: .orange
    case .red: .red
    case .purple: .purple
    case .pink: .pink
    case .teal: .teal
    case .yellow: .yellow
    case .gray: .gray
    }
  }

  var localizedName: String {
    typealias Names = L10n.Contacts.Contacts.Groups.ColorName
    return switch self {
    case .blue: Names.blue
    case .green: Names.green
    case .orange: Names.orange
    case .red: Names.red
    case .purple: Names.purple
    case .pink: Names.pink
    case .teal: Names.teal
    case .yellow: Names.yellow
    case .gray: Names.gray
    }
  }
}

@MainActor
extension ContactGroup {
  /// WCAG floor for graphical objects, the bar a white symbol has to clear to stay white.
  private static let glyphContrastFloor = 3.0
  private static let whiteLuminance = 1.0

  /// Symbol color for a group fill: white where it clears the graphical-object floor,
  /// otherwise the dark avatar glyph, so light swatches such as yellow stay readable.
  static func glyphColor(onFill fill: Color, colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
    let traits = Theme.traitCollection(colorScheme: colorScheme, contrast: contrast)
    let luminance = WCAGContrast.relativeLuminance(of: UIColor(fill).resolvedColor(with: traits))
    guard WCAGContrast.contrastRatio(whiteLuminance, luminance) < glyphContrastFloor else { return .white }
    return IdentityGamut.glyphColor(forFillLuminance: luminance)
  }
}

/// Rounded-square badge showing a group's symbol on its color.
struct ContactGroupIcon: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  let symbol: String
  let tint: Color
  var size: CGFloat = 28

  init(group: ContactGroup, size: CGFloat = 28) {
    symbol = group.symbol
    tint = group.tint
    self.size = size
  }

  init(symbol: String, tint: Color, size: CGFloat = 28) {
    self.symbol = symbol
    self.tint = tint
    self.size = size
  }

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(ContactGroup.glyphColor(onFill: tint, colorScheme: colorScheme, contrast: colorSchemeContrast))
      .frame(width: size, height: size)
      .background(tint.gradient, in: .rect(cornerRadius: size * 0.25))
      .accessibilityHidden(true)
  }
}
