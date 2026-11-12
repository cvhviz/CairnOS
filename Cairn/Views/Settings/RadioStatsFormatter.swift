import Foundation

/// Pure formatting for companion radio statistics (`CMD_GET_STATS`).
enum RadioStatsFormatter {
  /// Uptime as up to three abbreviated units, e.g. "2d 3h 14m" in English.
  static func duration(seconds: UInt32, locale: Locale = .current) -> String {
    Duration.seconds(Int64(seconds)).formatted(
      .units(
        allowed: [.days, .hours, .minutes, .seconds],
        width: .narrow,
        maximumUnitCount: 3
      )
      .locale(locale)
    )
  }

  /// Share of `uptime` spent on air, as a 0...1 fraction. Nil when uptime is zero.
  static func airtimeFraction(airtimeSeconds: UInt32, uptimeSeconds: UInt32) -> Double? {
    guard uptimeSeconds > 0 else { return nil }
    return min(1, Double(airtimeSeconds) / Double(uptimeSeconds))
  }

  /// Airtime's share of uptime as a percentage, e.g. "0.84%". Nil without an uptime to compare.
  static func airtimeShare(seconds: UInt32, uptimeSeconds: UInt32?, locale: Locale = .current) -> String? {
    guard let uptimeSeconds,
          let fraction = airtimeFraction(airtimeSeconds: seconds, uptimeSeconds: uptimeSeconds) else {
      return nil
    }
    return fraction.formatted(.percent.locale(locale).precision(.fractionLength(2)))
  }

  /// Millivolts as volts with two decimals, e.g. "4.12 V".
  static func voltage(millivolts: UInt16, locale: Locale = .current) -> String {
    let volts = Double(millivolts) / 1000
    return "\(volts.formatted(.number.locale(locale).precision(.fractionLength(2)))) V"
  }

  /// Receive error rate as a percentage of all receive attempts; nil with no traffic.
  static func receiveErrorRate(errors: UInt32, received: UInt32) -> Double? {
    let total = UInt64(errors) + UInt64(received)
    guard total > 0 else { return nil }
    return Double(errors) / Double(total)
  }
}
