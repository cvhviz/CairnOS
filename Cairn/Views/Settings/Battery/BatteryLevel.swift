import SwiftUI

/// How the radio's battery charge reads: good, low, or critical, with the glyph, color and word
/// that go with it. Shared by the Settings dashboard's battery card and Settings → Battery so the
/// two always agree.
enum BatteryLevel: Equatable {
  case good
  case low
  case critical

  /// Below this the battery is worth a warning; below `criticalThreshold`, an alarm. The same
  /// thresholds the low-battery notifications and `BatteryInfo.levelColor` use.
  static let lowThreshold = 20
  static let criticalThreshold = 10

  init(percent: Int) {
    if percent < Self.criticalThreshold {
      self = .critical
    } else if percent < Self.lowThreshold {
      self = .low
    } else {
      self = .good
    }
  }

  var tint: Color {
    switch self {
    case .good: .green
    case .low: .orange
    case .critical: .red
    }
  }

  /// Says the level in words, so the state never rests on the meter's color alone.
  var title: String {
    switch self {
    case .good: L10n.Settings.Battery.Level.good
    case .low: L10n.Settings.Battery.Level.low
    case .critical: L10n.Settings.Battery.Level.critical
    }
  }

  /// The battery glyph for a charge, or the empty battery while there is no reading.
  static func symbol(for percent: Int?) -> String {
    switch percent {
    case .none: "battery.0"
    case let .some(value) where value >= 88: "battery.100"
    case let .some(value) where value >= 63: "battery.75"
    case let .some(value) where value >= 38: "battery.50"
    case let .some(value) where value >= 13: "battery.25"
    default: "battery.0"
    }
  }

  /// "87%", or "—" while there is no reading.
  static func formattedPercent(_ percent: Int?) -> String {
    percent.map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "—"
  }

  /// "4.02 V": volts to two decimals, the precision the radio reports in.
  static func formattedVoltage(_ volts: Double) -> String {
    Measurement(value: volts, unit: UnitElectricPotentialDifference.volts)
      .formatted(.measurement(
        width: .abbreviated,
        usage: .asProvided,
        numberFormatStyle: .number.precision(.fractionLength(2))
      ))
  }

  /// "3.10–4.19 V": the voltages a discharge curve calls empty and full, or nil for a curve
  /// without both ends.
  static func formattedRange(ocvArray: [Int]) -> String? {
    guard let full = ocvArray.first, let empty = ocvArray.last, ocvArray.count > 1 else { return nil }
    let low = (Double(empty) / 1000).formatted(.number.precision(.fractionLength(2)))
    return "\(low)–\(formattedVoltage(Double(full) / 1000))"
  }
}
