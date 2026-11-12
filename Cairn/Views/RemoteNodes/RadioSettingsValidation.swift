import CairnServices
import Foundation

/// What `set radio f,bw,sf,cr` may carry before it goes to a node. The frequency is held to the
/// companion's range (`PacketBuilder.frequencyRangeKHz`, as Settings › Radio does), and the
/// bandwidth, spreading factor and coding rate to the sets the local radio page offers
/// (`RadioOptions`). A wrong value here strands the node: it stops hearing the mesh and can only be
/// fixed at the board.
enum RadioSettingsValidator {
  struct Errors: Equatable {
    var frequency: String?
    var bandwidth: String?
    var spreadingFactor: String?
    var codingRate: String?

    var hasErrors: Bool {
      frequency != nil || bandwidth != nil || spreadingFactor != nil || codingRate != nil
    }
  }

  /// The companion's frequency range in MHz, inclusive.
  static var frequencyRangeMHz: ClosedRange<Double> {
    Double(PacketBuilder.frequencyRangeKHz.lowerBound) / 1000 ... Double(PacketBuilder.frequencyRangeKHz.upperBound) / 1000
  }

  /// Bandwidth values that are close enough to a listed one (firmware reports 7.8 as 7.8 or 7.799).
  private static let bandwidthTolerance = 0.05

  static func isFrequencyAllowed(_ mhz: Double) -> Bool {
    guard mhz.isFinite else { return false }
    let kHz = (mhz * 1000).rounded()
    return kHz >= Double(PacketBuilder.frequencyRangeKHz.lowerBound)
      && kHz <= Double(PacketBuilder.frequencyRangeKHz.upperBound)
  }

  static func isBandwidthAllowed(_ kHz: Double) -> Bool {
    guard kHz.isFinite else { return false }
    return RadioOptions.bandwidthsKHz.contains { abs($0 - kHz) <= bandwidthTolerance }
  }

  static func isSpreadingFactorAllowed(_ sf: Int) -> Bool {
    RadioOptions.spreadingFactors.contains(sf)
  }

  static func isCodingRateAllowed(_ cr: Int) -> Bool {
    RadioOptions.codingRates.contains(cr)
  }

  /// Nil fields are unloaded, not wrong: the apply path refuses to send without them anyway.
  static func validate(frequency: Double?, bandwidth: Double?, spreadingFactor: Int?, codingRate: Int?) -> Errors {
    var errors = Errors()
    if let frequency, !isFrequencyAllowed(frequency) {
      let range = frequencyRangeMHz
      errors.frequency = L10n.RemoteNodes.RemoteNodes.Settings.Radio.frequencyValidation(
        range.lowerBound.formatted(.number.precision(.fractionLength(3))),
        range.upperBound.formatted(.number.precision(.fractionLength(3)))
      )
    }
    if let bandwidth, !isBandwidthAllowed(bandwidth) {
      errors.bandwidth = L10n.RemoteNodes.RemoteNodes.Settings.Radio.bandwidthValidation
    }
    if let spreadingFactor, !isSpreadingFactorAllowed(spreadingFactor) {
      errors.spreadingFactor = L10n.RemoteNodes.RemoteNodes.Settings.Radio.spreadingFactorValidation(
        RadioOptions.spreadingFactors.lowerBound, RadioOptions.spreadingFactors.upperBound
      )
    }
    if let codingRate, !isCodingRateAllowed(codingRate) {
      errors.codingRate = L10n.RemoteNodes.RemoteNodes.Settings.Radio.codingRateValidation(
        RadioOptions.codingRates.lowerBound, RadioOptions.codingRates.upperBound
      )
    }
    return errors
  }
}

/// The radio settings as one value, for the "old → new" lines of the confirmation before they're sent.
struct RadioSettingsValues: Equatable {
  var frequency: Double?
  var bandwidth: Double?
  var spreadingFactor: Int?
  var codingRate: Int?
  var txPower: Int?

  /// One line per setting that changes: "Frequency: 869.525 MHz → 868.000 MHz".
  func changeLines(to new: RadioSettingsValues) -> [String] {
    var lines: [String] = []
    func line(_ title: String, _ old: String?, _ now: String?) {
      guard let old, let now, old != now else { return }
      lines.append(L10n.RemoteNodes.RemoteNodes.Settings.Radio.changeLine(title, old, now))
    }
    let mhz = { (value: Double?) in value.map { "\($0.formatted(.number.precision(.fractionLength(3)))) MHz" } }
    let khz = { (value: Double?) in value.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kHz" } }
    line(L10n.RemoteNodes.RemoteNodes.Settings.frequencyMHz, mhz(frequency), mhz(new.frequency))
    line(L10n.RemoteNodes.RemoteNodes.Settings.bandwidthKHz, khz(bandwidth), khz(new.bandwidth))
    line(L10n.RemoteNodes.RemoteNodes.Settings.spreadingFactor, spreadingFactor.map { "SF\($0)" }, new.spreadingFactor.map { "SF\($0)" })
    line(L10n.RemoteNodes.RemoteNodes.Settings.codingRate, codingRate.map { "4/\($0)" }, new.codingRate.map { "4/\($0)" })
    line(L10n.Settings.Dashboard.txPower, txPower.map { "\($0) dBm" }, new.txPower.map { "\($0) dBm" })
    return lines
  }
}

/// How one field fared in a multi-field Apply, so a failure names the setting rather than
/// collapsing into "some settings failed".
enum NodeFieldResult: Equatable {
  case applied
  case failed(String)
}
