import CoreLocation
import Foundation
import os
import CairnServices

/// One of the eight compass points, for headings ("47° NE"), coordinate hemispheres and the
/// rose's own N/E/S/W letters.
enum CompassPoint: Int, CaseIterable {
  case north, northeast, east, southeast, south, southwest, west, northwest

  /// The point nearest `degrees`, each one owning the 45° wedge centred on it, so 22.4° is still
  /// north and 22.5° is northeast. Any angle works, negative or past 360.
  init(degrees: Double) {
    let normalized = GPSFormat.normalizedDegrees(degrees)
    self = CompassPoint(rawValue: Int((normalized / 45).rounded()) % 8) ?? .north
  }

  /// "NE": the short form shown on screen.
  var abbreviation: String {
    switch self {
    case .north: L10n.Map.Map.Gps.Cardinal.n
    case .northeast: L10n.Map.Map.Gps.Cardinal.ne
    case .east: L10n.Map.Map.Gps.Cardinal.e
    case .southeast: L10n.Map.Map.Gps.Cardinal.se
    case .south: L10n.Map.Map.Gps.Cardinal.s
    case .southwest: L10n.Map.Map.Gps.Cardinal.sw
    case .west: L10n.Map.Map.Gps.Cardinal.w
    case .northwest: L10n.Map.Map.Gps.Cardinal.nw
    }
  }

  /// "northeast": the spoken form, so VoiceOver doesn't spell out "N E".
  var name: String {
    switch self {
    case .north: L10n.Map.Map.Gps.CardinalName.n
    case .northeast: L10n.Map.Map.Gps.CardinalName.ne
    case .east: L10n.Map.Map.Gps.CardinalName.e
    case .southeast: L10n.Map.Map.Gps.CardinalName.se
    case .south: L10n.Map.Map.Gps.CardinalName.s
    case .southwest: L10n.Map.Map.Gps.CardinalName.sw
    case .west: L10n.Map.Map.Gps.CardinalName.w
    case .northwest: L10n.Map.Map.Gps.CardinalName.nw
    }
  }
}

/// The GPS tab's wording, kept pure so it can be unit tested: Cairn's terse style ("47° NE",
/// "3m ago", "41.88230° N") in the user's language and units.
enum GPSFormat {
  /// Decimal places for a coordinate: five (about 1 m), as the rest of the app shows positions.
  private static let coordinateDecimals = 5

  /// `degrees` folded into 0..<360.
  static func normalizedDegrees(_ degrees: Double) -> Double {
    let folded = degrees.truncatingRemainder(dividingBy: 360)
    return folded < 0 ? folded + 360 : folded
  }

  /// Whole degrees 0...359 for display; 359.6 rounds to 0, not 360.
  static func wholeDegrees(_ degrees: Double) -> Int {
    Int(normalizedDegrees(degrees).rounded()) % 360
  }

  /// "47° NE".
  static func bearingText(_ degrees: Double) -> String {
    "\(wholeDegrees(degrees))° \(CompassPoint(degrees: degrees).abbreviation)"
  }

  /// "47 degrees, northeast", for VoiceOver.
  static func bearingAccessibilityText(_ degrees: Double) -> String {
    L10n.Map.Map.Gps.Heading.accessibilityValue(wholeDegrees(degrees), CompassPoint(degrees: degrees).name)
  }

  /// "41.88230° N" / "87.62320° W": unsigned with the hemisphere letter, like Cairn's rows. The
  /// decimal point is always '.', so a coordinate reads the same in every locale.
  static func latitudeText(_ latitude: Double) -> String {
    let hemisphere = latitude < 0 ? CompassPoint.south : .north
    return "\(String(format: "%.\(coordinateDecimals)f", abs(latitude)))° \(hemisphere.abbreviation)"
  }

  static func longitudeText(_ longitude: Double) -> String {
    let hemisphere = longitude < 0 ? CompassPoint.west : .east
    return "\(String(format: "%.\(coordinateDecimals)f", abs(longitude)))° \(hemisphere.abbreviation)"
  }

  /// "41.88230, -87.62320": the signed pair a Copy puts on the pasteboard, which maps apps and
  /// the chat coordinate detector both understand.
  static func coordinatePairText(_ coordinate: CLLocationCoordinate2D) -> String {
    String(format: "%.\(coordinateDecimals)f, %.\(coordinateDecimals)f", coordinate.latitude, coordinate.longitude)
  }

  /// 41°52'56.3" N, 87°37'23.5" W: degrees, minutes and seconds, the decimal point always '.'.
  static func dmsText(_ coordinate: CLLocationCoordinate2D) -> String {
    func part(_ value: Double, _ hemisphere: CompassPoint) -> String {
      let tenths = Int((abs(value) * 36000).rounded())
      let seconds = String(format: "%.1f", Double(tenths % 600) / 10)
      return "\(tenths / 36000)°\(tenths / 600 % 60)'\(seconds)\" \(hemisphere.abbreviation)"
    }
    let latitude = part(coordinate.latitude, coordinate.latitude < 0 ? .south : .north)
    let longitude = part(coordinate.longitude, coordinate.longitude < 0 ? .west : .east)
    return "\(latitude), \(longitude)"
  }

  /// "EN61fv": the six-character Maidenhead grid square radio operators use.
  static func gridSquare(_ coordinate: CLLocationCoordinate2D) -> String {
    let longitude = min(max(coordinate.longitude + 180, 0), 359.999999)
    let latitude = min(max(coordinate.latitude + 90, 0), 179.999999)
    func letter(_ index: Int, base: Character) -> String {
      String(UnicodeScalar(base.unicodeScalars.first!.value + UInt32(index))!)
    }
    return letter(Int(longitude / 20), base: "A") + letter(Int(latitude / 10), base: "A")
      + String(Int(longitude.truncatingRemainder(dividingBy: 20) / 2))
      + String(Int(latitude.truncatingRemainder(dividingBy: 10)))
      + letter(Int(longitude.truncatingRemainder(dividingBy: 2) * 12), base: "a")
      + letter(Int(latitude.truncatingRemainder(dividingBy: 1) * 24), base: "a")
  }

  /// "3m" / "2h" / "4d": the single largest unit of an age, as Cairn writes it.
  static func shortDuration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
    let formatter: DateComponentsFormatter = formatters.formatter(key: "duration|\(locale.identifier)") {
      var calendar = Calendar(identifier: .gregorian)
      calendar.locale = locale
      let formatter = DateComponentsFormatter()
      formatter.calendar = calendar
      formatter.unitsStyle = .abbreviated
      formatter.maximumUnitCount = 1
      formatter.allowedUnits = [.day, .hour, .minute]
      return formatter
    }
    return formatter.string(from: max(seconds, 60)) ?? ""
  }

  /// "now" under a minute, otherwise "3m ago". The caption beside the fix time.
  static func fixAgeText(_ seconds: TimeInterval, locale: Locale = .current) -> String {
    guard seconds >= 60 else { return L10n.Map.Map.Gps.FixAge.now }
    return L10n.Map.Map.Gps.FixAge.ago(shortDuration(seconds, locale: locale))
  }

  /// "594 ft" / "181 m": a whole-unit length in the user's measurement preference, for altitude,
  /// accuracy and the radio's distance from the phone. Kilometres or miles once it is long.
  static func lengthText(_ meters: Double, locale: Locale = measurementLocale()) -> String {
    let fractionDigits = meters >= 1000 ? 1 : 0
    let formatter: MeasurementFormatter = formatters.formatter(key: "length|\(fractionDigits)|\(locale.identifier)|\(locale.measurementSystem.identifier)") {
      let formatter = MeasurementFormatter()
      formatter.locale = locale
      formatter.unitOptions = .naturalScale
      formatter.numberFormatter.maximumFractionDigits = fractionDigits
      return formatter
    }
    return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
  }

  /// "3.2 mph" / "5.1 km/h": ground speed from metres per second, in the user's preference.
  static func speedText(
    _ metersPerSecond: Double,
    imperial: Bool = measurementLocale().measurementSystem != .metric,
    locale: Locale = .current
  ) -> String {
    let formatter: MeasurementFormatter = formatters.formatter(key: "speed|\(locale.identifier)") {
      let formatter = MeasurementFormatter()
      formatter.locale = locale
      formatter.unitOptions = .providedUnit
      formatter.numberFormatter.maximumFractionDigits = 1
      formatter.numberFormatter.minimumFractionDigits = 1
      return formatter
    }
    let speed = Measurement(value: max(metersPerSecond, 0), unit: UnitSpeed.metersPerSecond)
    return formatter.string(from: speed.converted(to: imperial ? .milesPerHour : .kilometersPerHour))
  }

  /// Whether two fixes are far enough apart to be worth showing separately: further than the
  /// phone's own uncertainty, and never closer than `floor` (the radio stores whole microdegrees
  /// and a manual pin is rarely placed to the metre).
  static func positionsDiffer(
    _ first: CLLocation,
    _ second: CLLocation,
    floor: CLLocationDistance = 25
  ) -> Bool {
    let tolerance = max(floor, first.horizontalAccuracy, second.horizontalAccuracy)
    return first.distance(from: second) > tolerance
  }

  // MARK: - Caches

  /// The user's measurement locale (`MeasurementPreference.locale()`), rebuilt only when the
  /// preference or the system locale changes rather than on every reading of every render.
  static func measurementLocale() -> Locale {
    let preference = MeasurementPreference.current()
    let base = Locale.current
    // The identifier alone may leave out a system-wide measurement override.
    let baseKey = "\(base.identifier)|\(base.measurementSystem.identifier)"
    return measurementLocaleCache.withLock { cache in
      if let cached = cache, cached.preference == preference, cached.baseIdentifier == baseKey {
        return cached.locale
      }
      let locale = MeasurementPreference.locale(base: base, preference: preference)
      cache = (preference, baseKey, locale)
      return locale
    }
  }

  private static let measurementLocaleCache = OSAllocatedUnfairLock<
    (preference: MeasurementSystemPreference, baseIdentifier: String, locale: Locale)?
  >(initialState: nil)

  /// Configured formatters by use and locale. Formatters are costly to build and safe to share
  /// for formatting once configured, which every one here is before it is cached.
  private static let formatters = FormatterCache()

  /// Initial great-circle bearing from `origin` to `destination`, in degrees from north.
  static func bearing(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
    let lat1 = origin.latitude * .pi / 180
    let lat2 = destination.latitude * .pi / 180
    let deltaLon = (destination.longitude - origin.longitude) * .pi / 180
    let y = sin(deltaLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
    return normalizedDegrees(atan2(y, x) * 180 / .pi)
  }
}

/// A locked dictionary of configured formatters. `@unchecked Sendable`: every access goes
/// through the lock, and a cached formatter is only ever read (formatted with), never
/// reconfigured, which Foundation's formatters allow from any thread.
private final class FormatterCache: @unchecked Sendable {
  private let lock = NSLock()
  private var formatters: [String: Formatter] = [:]

  func formatter<F: Formatter>(key: String, make: () -> F) -> F {
    lock.lock()
    defer { lock.unlock() }
    if let cached = formatters[key] as? F { return cached }
    let formatter = make()
    formatters[key] = formatter
    return formatter
  }
}
