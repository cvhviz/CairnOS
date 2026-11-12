import CoreLocation
import Foundation

/// Pure wording for the Home cards, in Cairn's terse style ("2m", "up 3h 12m", "3.4 mi NE").
/// Kept free of view state so the tests can pin the output for a fixed locale.
enum HomeFormat {
  /// How long ago something happened, in one narrow unit: "now", "2m", "3h", "2d".
  static func age(_ interval: TimeInterval, locale: Locale = .current) -> String {
    guard interval >= 60 else { return L10n.Chats.Chats.Timestamp.now }
    let unit: Duration.UnitsFormatStyle.Unit = switch interval {
    case ..<3600: .minutes
    case ..<86400: .hours
    default: .days
    }
    return Duration.seconds(Int64(interval)).formatted(
      .units(allowed: [unit], width: .narrow, fractionalPart: .hide(rounded: .down)).locale(locale)
    )
  }

  /// Time since the radio's last reboot, in its two largest units: "3h 12m", "3d 4h", "12m".
  static func uptime(seconds: TimeInterval, locale: Locale = .current) -> String {
    let wholeMinutes = Int64(max(0, seconds) / 60) * 60
    return Duration.seconds(wholeMinutes).formatted(
      .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2).locale(locale)
    )
  }

  /// "41.8823, -87.6232": four decimals (about 10 m), signed, in the reader's number format.
  static func coordinate(latitude: Double, longitude: Double, locale: Locale = .current) -> String {
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(4)).locale(locale)
    return "\(latitude.formatted(style)), \(longitude.formatted(style))"
  }

  /// Initial great-circle bearing from one point to another, in degrees clockwise from north.
  static func bearing(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
    let lat1 = origin.latitude * .pi / 180
    let lat2 = destination.latitude * .pi / 180
    let deltaLongitude = (destination.longitude - origin.longitude) * .pi / 180
    let y = sin(deltaLongitude) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
    let degrees = atan2(y, x) * 180 / .pi
    return (degrees + 360).truncatingRemainder(dividingBy: 360)
  }

  /// The nearest of the eight compass points to a bearing: 0 is north, 1 northeast, … 7 northwest.
  static func compassPointIndex(bearing: Double) -> Int {
    let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    return Int((normalized / 45).rounded()) % 8
  }

  /// "NE" in the reader's language.
  static func compassPoint(bearing: Double) -> String {
    switch compassPointIndex(bearing: bearing) {
    case 0: L10n.Localizable.Home.Compass.n
    case 1: L10n.Localizable.Home.Compass.ne
    case 2: L10n.Localizable.Home.Compass.e
    case 3: L10n.Localizable.Home.Compass.se
    case 4: L10n.Localizable.Home.Compass.s
    case 5: L10n.Localizable.Home.Compass.sw
    case 6: L10n.Localizable.Home.Compass.w
    default: L10n.Localizable.Home.Compass.nw
    }
  }

  /// Nodes heard within `window` of `now` that are not saved contacts: Cairn's "+4" beside the
  /// contact count, the nodes worth a look on the Contacts tab's Discover list.
  static func newNodeCount(
    heard: [(publicKey: Data, lastHeard: Date)],
    contactKeys: Set<Data>,
    now: Date,
    window: TimeInterval = 86400
  ) -> Int {
    heard.count { node in
      !contactKeys.contains(node.publicKey) && now.timeIntervalSince(node.lastHeard) <= window
    }
  }

  /// The newest conversations first, without the ones that never had a message.
  static func newest<Item>(_ items: [Item], limit: Int, date: (Item) -> Date?) -> [Item] {
    let dated = items.compactMap { item in date(item).map { (item, $0) } }
    return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
  }
}
