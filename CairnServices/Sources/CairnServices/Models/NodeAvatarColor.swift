import Foundation

/// A colour the user picked for a node's avatar and name: one of the hue swatches, whose
/// brightness the app solves per theme, appearance and contrast; a
/// category's fixed colour; or any colour from the system picker. The raw values are stored, so
/// their spelling must never change.
public enum NodeAvatarColor: Hashable, Sendable {
  case red
  case orange
  case amber
  case lime
  case teal
  case sky
  case purple
  /// The fixed colour of a category, so a node can wear, say, the repeaters' colour.
  case category(AvatarCategory)
  /// A colour from the system picker, as 0xRRGGBB.
  case custom(rgb: Int)

  /// The hue swatches, by hue. The category colours fill the hues between them.
  public static let hues: [NodeAvatarColor] = [.red, .orange, .amber, .lime, .teal, .sky, .purple]

  /// A hue swatch's hue in degrees (0..<360); nil for a fixed colour.
  public var hueDegrees: Double? {
    switch self {
    case .red: 355
    case .orange: 25
    case .amber: 45
    case .lime: 90
    case .teal: 170
    case .sky: 205
    case .purple: 280
    case .category, .custom: nil
    }
  }
}

extension NodeAvatarColor: RawRepresentable {
  private static let categoryPrefix = "type."
  private static let customPrefix = "rgb."

  /// Hue swatches retired when the category colours took their place, read back as the category
  /// colour that replaced each.
  private static let retiredHues: [String: AvatarCategory] = [
    "green": .companion, "cyan": .channel, "blue": .radio, "indigo": .repeater, "pink": .room,
  ]

  /// A hue swatch's name ("teal"), "type.<category>" or "rgb.<RRGGBB>".
  public init?(rawValue: String) {
    if let hue = Self.hues.first(where: { $0.rawValue == rawValue }) {
      self = hue
    } else if let category = Self.retiredHues[rawValue] {
      self = .category(category)
    } else if rawValue.hasPrefix(Self.categoryPrefix) {
      guard let category = AvatarCategory(rawValue: String(rawValue.dropFirst(Self.categoryPrefix.count))) else { return nil }
      self = .category(category)
    } else if rawValue.hasPrefix(Self.customPrefix) {
      let hex = rawValue.dropFirst(Self.customPrefix.count)
      guard hex.count == 6, let rgb = Int(hex, radix: 16) else { return nil }
      self = .custom(rgb: rgb)
    } else {
      return nil
    }
  }

  public var rawValue: String {
    switch self {
    case .red: "red"
    case .orange: "orange"
    case .amber: "amber"
    case .lime: "lime"
    case .teal: "teal"
    case .sky: "sky"
    case .purple: "purple"
    case let .category(category): Self.categoryPrefix + category.rawValue
    case let .custom(rgb): Self.customPrefix + String(format: "%06X", rgb & 0xFFFFFF)
    }
  }
}

extension NodeAvatarColor: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let color = NodeAvatarColor(rawValue: raw) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown avatar colour \(raw)")
    }
    self = color
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
