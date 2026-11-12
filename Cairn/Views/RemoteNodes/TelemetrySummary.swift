import Foundation
import CairnServices
import MeshCore

/// Time window for a min/avg/max telemetry summary request.
enum TelemetrySummaryRange: CaseIterable, Identifiable {
  case hour
  case day
  case week

  var id: Self { self }

  var duration: TimeInterval {
    switch self {
    case .hour: 3600
    case .day: 86400
    case .week: 7 * 86400
    }
  }

  var label: String {
    switch self {
    case .hour: L10n.RemoteNodes.RemoteNodes.Summary.Range.hour
    case .day: L10n.RemoteNodes.RemoteNodes.Summary.Range.day
    case .week: L10n.RemoteNodes.RemoteNodes.Summary.Range.week
    }
  }
}

/// One formatted min/avg/max row.
struct TelemetrySummaryRow: Identifiable, Equatable {
  let id: Int
  let label: String
  let min: String
  let avg: String
  let max: String
  /// The sensor behind the row, for its tile's symbol; nil for a type this app doesn't know.
  var sensorType: LPPSensorType?
}

/// Pure formatting for MMA (min/max/average) telemetry entries.
enum TelemetrySummaryFormatter {
  /// Formats MMA entries into display rows. The channel is appended to the label only when
  /// the response spans several channels, matching the live telemetry section.
  static func rows(
    from entries: [MMAEntry],
    locale: Locale = .current,
    convertUnits: Bool = true
  ) -> [TelemetrySummaryRow] {
    let multipleChannels = Set(entries.map(\.channel)).count > 1
    return entries.enumerated().map { index, entry in
      let type = LPPSensorType(name: entry.type)
      let baseName = type?.localizedName ?? entry.type
      let label = multipleChannels
        ? "\(baseName) · \(L10n.RemoteNodes.RemoteNodes.Status.channel(Int(entry.channel)))"
        : baseName
      return TelemetrySummaryRow(
        id: index,
        label: label,
        min: format(entry.min, type: type, locale: locale, convertUnits: convertUnits),
        avg: format(entry.avg, type: type, locale: locale, convertUnits: convertUnits),
        max: format(entry.max, type: type, locale: locale, convertUnits: convertUnits),
        sensorType: type
      )
    }
  }

  /// Formats one value with its unit. Locale-sensitive types (temperature, pressure,
  /// altitude, distance) are converted to the user's preferred unit when `convertUnits`.
  static func format(
    _ value: Double,
    type: LPPSensorType?,
    locale: Locale = .current,
    convertUnits: Bool = true
  ) -> String {
    guard let type else {
      return value.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
    }
    if convertUnits, type.isConverted {
      let converted = type.convertedValue(value)
      let number = converted.formatted(
        .number.locale(locale).precision(.fractionLength(type.convertedFractionLength))
      )
      return "\(number) \(type.localizedUnitSymbol)"
    }
    let number = value.formatted(.number.locale(locale).precision(.fractionLength(fractionDigits(for: type))))
    let unit = type.unit
    guard !unit.isEmpty else { return number }
    return ["%", "\u{00B0}"].contains(unit) ? "\(number)\(unit)" : "\(number) \(unit)"
  }

  static func fractionDigits(for type: LPPSensorType) -> Int {
    switch type {
    case .voltage, .analogInput, .analogOutput: 2
    case .current, .load, .distance, .energy: 3
    case .temperature, .barometer, .humidity: 1
    default: 0
    }
  }
}
