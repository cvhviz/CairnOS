import SwiftUI
import UIKit

/// An opaque color as stored in the background settings: gamma-encoded, extended-range sRGB
/// components, so a wide-gamut pick from `ColorPicker` survives the round trip.
struct BackgroundColor: Codable, Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  init(hex: Int) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }

  /// Captures a SwiftUI color (resolved for the light appearance; a background color is a
  /// fixed pick, not an adaptive one). Opacity is dropped: backgrounds are always opaque.
  init(_ color: Color) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
      var white: CGFloat = 0
      resolved.getWhite(&white, alpha: &alpha)
      (red, green, blue) = (white, white, white)
    }
    self.init(red: Double(red), green: Double(green), blue: Double(blue))
  }

  var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue)
  }

  var uiColor: UIColor {
    UIColor(red: red, green: green, blue: blue, alpha: 1)
  }

  /// Linear blend: `fraction` 0 is `self`, 1 is `other`.
  func mixed(with other: BackgroundColor, by fraction: Double) -> BackgroundColor {
    BackgroundColor(
      red: red + (other.red - red) * fraction,
      green: green + (other.green - green) * fraction,
      blue: blue + (other.blue - blue) * fraction
    )
  }

  static func average(of colors: [BackgroundColor]) -> BackgroundColor {
    guard !colors.isEmpty else { return BackgroundColor(red: 0.5, green: 0.5, blue: 0.5) }
    let count = Double(colors.count)
    return BackgroundColor(
      red: colors.map(\.red).reduce(0, +) / count,
      green: colors.map(\.green).reduce(0, +) / count,
      blue: colors.map(\.blue).reduce(0, +) / count
    )
  }

  static let white = BackgroundColor(red: 1, green: 1, blue: 1)
  static let black = BackgroundColor(red: 0, green: 0, blue: 0)
}

/// The user's page background: what paints behind every screen, plus the dim and blur applied
/// over it. Persisted as one JSON string (`AppStorageKey.appBackground`) so a change is atomic
/// and a backup carries it as a single value. The photo itself lives in `BackgroundImageStore`;
/// only its file name is stored here.
struct AppBackground: Codable, Equatable, Sendable {
  enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The untouched system look: grouped backgrounds and opaque cards.
    case system
    case solid
    case gradient
    case image

    var id: String { rawValue }
  }

  enum GradientStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear
    /// A soft 3×3 `MeshGradient` blend of the same colors.
    case mesh

    var id: String { rawValue }
  }

  /// Which way a linear gradient runs, from its first color to its last.
  enum GradientDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case topToBottom
    case topLeadingToBottomTrailing
    case leadingToTrailing
    case bottomLeadingToTopTrailing

    var id: String { rawValue }

    var startPoint: UnitPoint {
      switch self {
      case .topToBottom: .top
      case .topLeadingToBottomTrailing: .topLeading
      case .leadingToTrailing: .leading
      case .bottomLeadingToTopTrailing: .bottomLeading
      }
    }

    var endPoint: UnitPoint {
      switch self {
      case .topToBottom: .bottom
      case .topLeadingToBottomTrailing: .bottomTrailing
      case .leadingToTrailing: .trailing
      case .bottomLeadingToTopTrailing: .topTrailing
      }
    }
  }

  /// Dim stops at 80%: past that the background is effectively a flat black or white page.
  static let dimRange: ClosedRange<Double> = 0...0.8
  /// Blur radius in points, as seen on a phone-sized page.
  static let blurRange: ClosedRange<Double> = 0...40
  static let gradientColorCount: ClosedRange<Int> = 2...3
  static let defaultDim: Double = 0.65

  var kind: Kind = .system
  var solidColor: BackgroundColor = SolidBackgroundPreset.midnight.color
  var gradientColors: [BackgroundColor] = GradientBackgroundPreset.ocean.colors
  var gradientStyle: GradientStyle = .mesh
  var gradientDirection: GradientDirection = .topLeadingToBottomTrailing
  /// Fraction 0...0.8 of the adaptive wash over the background: black in Dark Mode, white in
  /// Light Mode, so it always pushes the background away from the text color.
  var dim: Double = AppBackground.defaultDim
  /// Blur radius in points (photos only).
  var blur: Double = 0
  /// File name inside `BackgroundImageStore`, when a photo has been picked.
  var imageFileName: String?
  /// The photo's average color, measured once when it is saved. Stands in for the photo where
  /// UI needs one flat color (fades, rims) without decoding the image.
  var imageAverageColor: BackgroundColor?

  static let system = AppBackground()

  /// What a fresh install starts on, until the user picks another: the Ocean gradient as a soft
  /// mesh, dimmed 65% so cards and text stay calm over it.
  static let appDefault: AppBackground = {
    var background = AppBackground()
    background.kind = .gradient
    return background
  }()

  init() {}

  /// The same settings with every value inside its supported range. Applied on decode and on
  /// every update, so neither a slider nor a hand-edited backup can push a value out of bounds.
  func normalized() -> AppBackground {
    var copy = self
    copy.dim = Self.clamp(dim, to: Self.dimRange, fallback: Self.defaultDim)
    copy.blur = Self.clamp(blur, to: Self.blurRange, fallback: 0)
    if copy.gradientColors.count > Self.gradientColorCount.upperBound {
      copy.gradientColors = Array(copy.gradientColors.prefix(Self.gradientColorCount.upperBound))
    }
    while copy.gradientColors.count < Self.gradientColorCount.lowerBound {
      copy.gradientColors.append(copy.gradientColors.last ?? solidColor)
    }
    if let name = copy.imageFileName, !BackgroundImageStore.isValidFileName(name) {
      copy.imageFileName = nil
    }
    if copy.kind == .image, copy.imageFileName == nil {
      copy.kind = .system
    }
    return copy
  }

  private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  // MARK: Coding

  private enum CodingKeys: String, CodingKey {
    case kind, solidColor, gradientColors, gradientStyle, gradientDirection, dim, blur
    case imageFileName, imageAverageColor
  }

  /// Tolerant decode: every field is optional and an unknown enum value (from a newer build)
  /// falls back to its default instead of discarding the whole background.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AppBackground()
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }
    kind = value(String.self, .kind).flatMap(Kind.init(rawValue:)) ?? defaults.kind
    solidColor = value(BackgroundColor.self, .solidColor) ?? defaults.solidColor
    gradientColors = value([BackgroundColor].self, .gradientColors) ?? defaults.gradientColors
    gradientStyle = value(String.self, .gradientStyle).flatMap(GradientStyle.init(rawValue:)) ?? defaults.gradientStyle
    gradientDirection = value(String.self, .gradientDirection).flatMap(GradientDirection.init(rawValue:))
      ?? defaults.gradientDirection
    dim = value(Double.self, .dim) ?? defaults.dim
    blur = value(Double.self, .blur) ?? defaults.blur
    imageFileName = value(String.self, .imageFileName)
    imageAverageColor = value(BackgroundColor.self, .imageAverageColor)
    self = normalized()
  }

  /// Decodes the persisted string; a missing or unreadable value is the system background.
  static func decode(from string: String?) -> AppBackground {
    guard let data = string?.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(AppBackground.self, from: data) else {
      return .appDefault
    }
    return decoded
  }

  var encodedString: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(self) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// The flat color closest to this background before dim: the solid color, the gradient's
  /// average, or the photo's measured average.
  var baseApproximateColor: BackgroundColor {
    switch kind {
    case .system: BackgroundColor(red: 0.95, green: 0.95, blue: 0.97)
    case .solid: solidColor
    case .gradient: BackgroundColor.average(of: gradientColors)
    case .image: imageAverageColor ?? BackgroundColor(red: 0.5, green: 0.5, blue: 0.5)
    }
  }
}

// MARK: - Presets

/// Hand-picked solid backgrounds, from deep to light.
enum SolidBackgroundPreset: String, CaseIterable, Identifiable {
  case midnight, ocean, forest, plum, graphite, sand, sage, blush

  var id: String { rawValue }

  var color: BackgroundColor {
    switch self {
    case .midnight: BackgroundColor(hex: 0x14213D)
    case .ocean: BackgroundColor(hex: 0x1F5F8B)
    case .forest: BackgroundColor(hex: 0x2D5A3D)
    case .plum: BackgroundColor(hex: 0x4B2E5C)
    case .graphite: BackgroundColor(hex: 0x3A3A3C)
    case .sand: BackgroundColor(hex: 0xE8DCC4)
    case .sage: BackgroundColor(hex: 0xC9D6C3)
    case .blush: BackgroundColor(hex: 0xF2D4D7)
    }
  }
}

/// Hand-picked gradients. Picking one copies its colors into the custom gradient, so a preset
/// is a starting point the user can keep editing.
enum GradientBackgroundPreset: String, CaseIterable, Identifiable {
  case dusk, ocean, aurora, sunset, forest, graphite

  var id: String { rawValue }

  var colors: [BackgroundColor] {
    switch self {
    case .dusk: [BackgroundColor(hex: 0x2B1E4F), BackgroundColor(hex: 0x7A3E7D), BackgroundColor(hex: 0xE07A5F)]
    case .ocean: [BackgroundColor(hex: 0x0B2545), BackgroundColor(hex: 0x13506B), BackgroundColor(hex: 0x3FA7A3)]
    case .aurora: [BackgroundColor(hex: 0x0F2027), BackgroundColor(hex: 0x1D6B5F), BackgroundColor(hex: 0x7BD389)]
    case .sunset: [BackgroundColor(hex: 0xF6D365), BackgroundColor(hex: 0xFDA085)]
    case .forest: [BackgroundColor(hex: 0x1E3B2F), BackgroundColor(hex: 0x6A8D5A)]
    case .graphite: [BackgroundColor(hex: 0x232526), BackgroundColor(hex: 0x5B5F66)]
    }
  }
}
