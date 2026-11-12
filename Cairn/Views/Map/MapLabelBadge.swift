import Foundation
import UIKit

/// A pin's name drawn as a small badge card under the pin: a dot in the pin's avatar colour (or a
/// type tint), the name, and optional short info ("5m", "+7.5 dB"), on a capsule that reads over
/// any basemap.
///
/// MapLibre places badges with collision on, so overlapping names give way instead of stacking;
/// `sortKey` decides who wins. The badge is a pre-rendered sprite (system font, so Dynamic Type
/// and the app's typography apply), and everything needed to redraw it is encoded in its sprite
/// name so MapLibre's `didFailToLoadImage` can rebuild it after an atlas eviction.
struct MapLabelBadge: Equatable {
  enum Tint: String, CaseIterable {
    case chat
    case repeater
    case room
    case neutral
    /// No leading dot (tool anchors that already carry a letter or symbol).
    case none

    var color: UIColor? {
      switch self {
      case .chat: UIColor(red: 204 / 255, green: 122 / 255, blue: 92 / 255, alpha: 1)
      case .repeater: .systemCyan
      case .room: UIColor(red: 1, green: 136 / 255, blue: 0, alpha: 1)
      case .neutral: .systemGray
      case .none: nil
      }
    }
  }

  var title: String
  var detail: String?
  var tint: Tint
  /// The pin's own avatar colour as 0xRRGGBB, drawn as the dot in place of the type tint so the
  /// badge matches the avatar pin above it. Nil uses the tint.
  var dotRGB: UInt32?
  var isDark: Bool
  /// Title point size, already scaled for Dynamic Type and rounded to whole points.
  var fontSize: Int

  /// Longest title drawn before it is cut with an ellipsis; long names would make wide badges
  /// that win collisions against several neighbours.
  static let maxTitleLength = 24

  /// Sprite-name format version, so a format change never decodes an old cached name.
  private static let version = "b2"
  private static let fieldSeparator: Character = "|"
  private static let detailSeparator: Character = "\u{1F}"
  private static let colorSeparator: Character = "#"

  // MARK: - Composition

  init(title: String, detail: String?, tint: Tint, isDark: Bool, fontSize: Int, dotRGB: UInt32? = nil) {
    self.title = Self.truncated(title)
    let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.detail = (trimmedDetail?.isEmpty ?? true) ? nil : trimmedDetail
    self.tint = tint
    self.dotRGB = tint == .none ? nil : dotRGB
    self.isDark = isDark
    self.fontSize = fontSize
  }

  /// The badge a pin shows, or nil when it has no name to show. `dotColor` is the pin's avatar
  /// colour, when it is a node pin.
  init?(point: MapPoint, isDark: Bool, fontSize: Int, dotColor: UIColor? = nil) {
    guard let label = point.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
      return nil
    }
    self.init(
      title: label,
      detail: point.detail,
      tint: Self.tint(for: point.pinStyle),
      isDark: isDark,
      fontSize: fontSize,
      dotRGB: dotColor.flatMap(Self.rgb)
    )
  }

  /// The dot's colour: the avatar colour when known, else the type tint.
  var dotColor: UIColor? {
    guard let dotRGB else { return tint.color }
    return UIColor(
      red: CGFloat((dotRGB >> 16) & 0xFF) / 255,
      green: CGFloat((dotRGB >> 8) & 0xFF) / 255,
      blue: CGFloat(dotRGB & 0xFF) / 255,
      alpha: 1
    )
  }

  private static func rgb(_ color: UIColor) -> UInt32? {
    var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
    return byte(red) << 16 | byte(green) << 8 | byte(blue)
  }

  static func truncated(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxTitleLength else { return trimmed }
    return String(trimmed.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  static func tint(for style: MapPoint.PinStyle) -> Tint {
    switch style {
    case .contactChat, .discoveredChat: .chat
    case .contactRoom, .discoveredRoom: .room
    case .contactRepeater, .repeater, .repeaterRingBlue, .repeaterRingGreen, .repeaterRingWhite,
         .repeaterHop, .discoveredRepeater: .repeater
    case .locationFix, .locationFixLatest, .droppedPin: .neutral
    case .pointA, .pointB, .crosshair, .obstruction, .badge: .none
    }
  }

  // MARK: - Sprite name

  var spriteName: String {
    let body = detail.map { title + String(Self.detailSeparator) + $0 } ?? title
    let tintField = dotRGB.map { tint.rawValue + String(Self.colorSeparator) + String($0, radix: 16) } ?? tint.rawValue
    let fields = [Self.version, isDark ? "d" : "l", tintField, String(fontSize), body]
    return PinSpriteRenderer.labelSpritePrefix + fields.joined(separator: String(Self.fieldSeparator))
  }

  /// Rebuilds a badge from its sprite name, or nil when the name isn't one of ours.
  init?(spriteName: String) {
    guard spriteName.hasPrefix(PinSpriteRenderer.labelSpritePrefix) else { return nil }
    let encoded = spriteName.dropFirst(PinSpriteRenderer.labelSpritePrefix.count)
    let fields = encoded.split(separator: Self.fieldSeparator, maxSplits: 4, omittingEmptySubsequences: false)
    let tintParts = fields.count == 5
      ? fields[2].split(separator: Self.colorSeparator, maxSplits: 1, omittingEmptySubsequences: false)
      : []
    guard fields.count == 5, fields[0] == Self.version,
          let tintName = tintParts.first, let tint = Tint(rawValue: String(tintName)),
          let size = Int(fields[3]) else { return nil }
    var dotRGB: UInt32?
    if tintParts.count > 1 {
      guard let rgb = UInt32(tintParts[1], radix: 16) else { return nil }
      dotRGB = rgb
    }
    let parts = fields[4].split(separator: Self.detailSeparator, maxSplits: 1, omittingEmptySubsequences: false)
    guard let title = parts.first, !title.isEmpty else { return nil }
    self.init(
      title: String(title),
      detail: parts.count > 1 ? String(parts[1]) : nil,
      tint: tint,
      isDark: fields[1] == "d",
      fontSize: size,
      dotRGB: dotRGB
    )
  }

  // MARK: - Dynamic Type

  static let baseFontSize = 12
  /// Badges grow with the reader's text size up to this, past which they would cover the map.
  static let maxFontSize = 17

  static func fontSize(for category: UIContentSizeCategory) -> Int {
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let scaled = UIFontMetrics(forTextStyle: .caption1)
      .scaledValue(for: CGFloat(baseFontSize), compatibleWith: traits)
    return min(maxFontSize, max(baseFontSize - 1, Int(scaled.rounded())))
  }

  // MARK: - Priority

  /// MapLibre places lower sort keys first, so they win a collision: the selected pin, then
  /// tool anchors, this radio, favorites, nodes that just answered a scan, path hops in order,
  /// stored contacts, and discovered nodes last. Faded (long-unheard) pins drop back a little.
  ///
  /// The key must not move while nothing on screen does: the map re-places every badge each time
  /// its data reloads (an advert heard, a minute's age text ticking over), and two badges whose
  /// keys swap order swap which one shows. So the fade counts in whole steps, not continuously,
  /// and equal keys are split by `tieBreak` (from the pin's id), never by the order the points
  /// happen to come in, which changes with every node heard.
  static func sortKey(
    pinStyle: MapPoint.PinStyle,
    isFavorite: Bool,
    hopIndex: Int?,
    opacity: Double,
    isSelected: Bool,
    isThisRadio: Bool = false,
    tieBreak: Double = 0
  ) -> Double {
    if isSelected { return 0 }
    // This radio's own name, the map's "you are here": only the selected pin and the tools'
    // anchors beat it, so a favorite at the same spot can't hide it.
    if isThisRadio { return 8 }
    let base: Double = switch pinStyle {
    case .pointA, .pointB, .crosshair, .droppedPin, .locationFixLatest: 5
    case .repeaterRingGreen: 20
    case .repeaterHop, .repeaterRingWhite, .repeaterRingBlue: 30 + Double(min(hopIndex ?? 0, 99)) / 100
    case .contactChat, .contactRepeater, .contactRoom, .repeater: 40
    case .discoveredChat, .discoveredRepeater, .discoveredRoom: 50
    case .locationFix, .obstruction, .badge: 60
    }
    let favored = isFavorite ? min(base, 10) : base
    let fade = ((1 - min(max(opacity, 0), 1)) * 5).rounded(.down)   // 0...5, whole steps
    return favored + fade + min(max(tieBreak, 0), 1) * 0.009
  }

  /// A fixed fraction in 0..<1 for a pin, from its id: the same pin always ranks the same among
  /// equals (`sortKey`), whatever order the map's points arrive in.
  static func tieBreak(for id: UUID) -> Double {
    let b = id.uuid
    let n = UInt32(b.12) << 24 | UInt32(b.13) << 16 | UInt32(b.14) << 8 | UInt32(b.15)
    return Double(n) / 4_294_967_296
  }

  /// Sort key for the distance/SNR stats badges drawn at line midpoints, which collide with one
  /// another when traces run close together. Lower wins, as with `sortKey`: an undimmed badge
  /// (the selected trace, or every trace when nothing is selected) beats a dimmed one, and among
  /// equals the stronger link wins. A badge without an SNR ranks below any that has one.
  static func statsSortKey(opacity: Double, snr: Double?) -> Double {
    let fade = (1 - min(max(opacity, 0), 1)) * 1000
    guard let snr, snr.isFinite else { return fade + 100 }
    // SNR spans roughly -30...+30 dB on LoRa; clamping keeps the ranks inside one fade band.
    return fade + (statsSNRCeiling - min(max(snr, -statsSNRCeiling), statsSNRCeiling))
  }

  private static let statsSNRCeiling: Double = 40

  // MARK: - Detail text

  /// "3m" / "2h" / "4d": the largest unit of how long ago a node was heard. Nil when unknown.
  static func ageDetail(lastHeard: Date?, now: Date, locale: Locale = .current) -> String? {
    guard let lastHeard else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    let formatter = DateComponentsFormatter()
    formatter.calendar = calendar
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    formatter.allowedUnits = [.day, .hour, .minute]
    return formatter.string(from: max(now.timeIntervalSince(lastHeard), 60))
  }

  /// "+7.5 dB": the SNR a node heard this radio at.
  static func snrDetail(_ snr: Double, locale: Locale = .current) -> String {
    let value = snr.formatted(
      .number.precision(.fractionLength(1)).sign(strategy: .always()).locale(locale)
    )
    return "\(value) dB"
  }
}
