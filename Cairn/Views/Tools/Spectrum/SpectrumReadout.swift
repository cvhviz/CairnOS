import Foundation

/// The Channel cursor's readout, a port of the firmware's `spec::chanReadout` and `spec::ageLabel`
/// (FRAMEWORK §17.3): "-42 s · min -112 avg -109 max -96 · NF -118 · SNR 6.25 · busy 8%". Level 0
/// is the whole line; each level after drops one part in the radio's order (min, busy, SNR, NF), so
/// the card shows the first that fits and never cuts one. The words come from the app's strings;
/// in English they read exactly as the radio's.
enum SpectrumReadout {
  struct Input: Equatable {
    /// The column's age (``age(milliseconds:)``).
    var when: String
    /// Readings fell in the column; otherwise it is a gap, or a transmit alone.
    var hasData: Bool
    var isTX: Bool
    var min = 0
    var avg = 0
    var max = 0
    /// The column's floor; nil = none.
    var nf: Int?
    /// The SNR of a packet heard over the column, in quarter dB.
    var snrX4: Int?
    /// The column's busy share, %; nil = no calibrated readings.
    var busy: Int?
  }

  static let levels = 5
  private static let separator = " · "

  static func line(_ input: Input, level: Int) -> String {
    guard input.hasData else {
      let state = input.isTX ? L10n.Tools.Tools.Spectrum.Device.Readout.transmitting : L10n.Tools.Tools.Spectrum.Device.Readout.noData
      return input.when + separator + state
    }
    var parts = [
      level >= 1
        ? L10n.Tools.Tools.Spectrum.Device.Readout.avgMax(String(input.avg), String(input.max))
        : L10n.Tools.Tools.Spectrum.Device.Readout.minAvgMax(String(input.min), String(input.avg), String(input.max)),
    ]
    if let nf = input.nf, level < 4 {
      parts.append(L10n.Tools.Tools.Spectrum.Device.Readout.nf(String(nf)))
    }
    if let snrX4 = input.snrX4, level < 3 {
      parts.append(L10n.Tools.Tools.Spectrum.Device.Readout.snr(snr(x4: snrX4)))
    }
    if let busy = input.busy, level < 2 {
      parts.append(L10n.Tools.Tools.Spectrum.Device.Readout.busy(String(busy) + "%"))
    }
    return input.when + separator + parts.joined(separator: separator)
  }

  /// Every level, the whole line first.
  static func lines(_ input: Input) -> [String] {
    (0..<levels).map { line(input, level: $0) }
  }

  /// The radio's quarter-dB SNR with two decimals: "6.25", "-4.50", "7.00".
  static func snr(x4: Int) -> String {
    let magnitude = abs(x4)
    return (x4 < 0 ? "-" : "") + String(magnitude / 4) + "." + String(format: "%02d", (magnitude % 4) * 25)
  }

  /// A column's age: "now" under half a second, "-12 s", "-2.5 m" (tenths, cut not rounded) under
  /// ten minutes, then "-14 m".
  static func age(milliseconds: UInt32) -> String {
    let seconds = (UInt64(milliseconds) + 500) / 1000
    if seconds == 0 {
      return L10n.Tools.Tools.Spectrum.Device.Readout.now
    }
    if seconds < 100 {
      return L10n.Tools.Tools.Spectrum.Device.Age.seconds(String(seconds))
    }
    if seconds < 600 {
      return L10n.Tools.Tools.Spectrum.Device.Age.minutes(String(seconds / 60) + "." + String((seconds % 60) / 6))
    }
    return L10n.Tools.Tools.Spectrum.Device.Age.minutes(String((seconds + 30) / 60))
  }
}
