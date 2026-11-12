import CairnServices
import SwiftUI

/// Units and words the Trips page uses: distance by road (mi or km, ft or m under one of them),
/// altitude in the app's units (`LocationReportFormat`), moving time as "1h 12m".
enum TripFormat {
  static var isImperial: Bool { MeasurementPreference.locale().measurementSystem == .us }

  /// "4.4 mi" / "7.1 km", feet or metres under a tenth of a mile or a kilometre: a tenth always shown
  /// under 100, so a walk's progress reads.
  static func distance(_ meters: Double) -> String {
    let imperial = isImperial
    let long: UnitLength = imperial ? .miles : .kilometers
    let short: UnitLength = imperial ? .feet : .meters
    let inLong = Measurement(value: meters, unit: UnitLength.meters).converted(to: long)
    let useShort = inLong.value < (imperial ? 0.1 : 1)
    let shown = useShort ? Measurement(value: meters, unit: UnitLength.meters).converted(to: short) : inLong
    let digits = useShort || shown.value >= 100 ? 0 : 1
    return shown.formatted(.measurement(
      width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits))
    ).locale(MeasurementPreference.locale()))
  }

  static func altitude(_ meters: Double) -> String { LocationReportFormat.altitude(meters) }

  static func duration(_ seconds: TimeInterval) -> String {
    Duration.seconds(Int(seconds)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
  }

  static func speed(_ metersPerSecond: Double) -> String {
    let unit: UnitSpeed = isImperial ? .milesPerHour : .kilometersPerHour
    return Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: unit).formatted(.measurement(
      width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))
    ).locale(MeasurementPreference.locale()))
  }

  /// The climb and descent, "▲ 975 ft  ▼ 907 ft", as the device's Trip card has them.
  static func climb(_ summary: TripSummary) -> Text {
    Text("▲ \(altitude(summary.climb))").foregroundStyle(.green)
      + Text("  ")
      + Text("▼ \(altitude(summary.descent))").foregroundStyle(.orange)
  }

  static func steps(_ count: Int) -> String { count.formatted() }
}
