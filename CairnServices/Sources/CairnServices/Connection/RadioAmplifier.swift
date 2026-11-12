import Foundation

/// Boards whose RF front end has a power amplifier after the LoRa chip.
///
/// The companion protocol reports the TX power configured on the LoRa chip (the "radio setting",
/// what the app sends and the firmware caps at `maxTxPower`) and has no field for an amplifier's
/// state or gain, so the figure a radio reports understates what such a board actually radiates.
/// For known boards the app shows the power at the antenna as well. Display only: the value sent
/// to the radio when the user changes TX power is never adjusted.
public enum RadioAmplifier {
  /// A board's transmit chain: a pi attenuator, then the PA. Each curve is Meshtastic's measured
  /// net gain per SX1262 setting 0...21 (`TX_GAIN_LORA` in its `configuration.h`), the same tables
  /// the Cairn firmware uses (`HeltecTxPower.h`).
  public enum Curve: String, Sendable, CaseIterable {
    /// Heltec Mesh Node T096: 21 dB pad + KCT8103L. 14 dB up to a setting of 12, then compressing:
    /// 23 dBm at 9, 28 dBm from 15 on (Heltec rates it 28 ± 1 dBm).
    case t096
    /// Heltec Wireless Tracker V2 (KCT8103L): 14 dB up to 11; 23 dBm at 9, 28 dBm from 16 on.
    case trackerV2
    /// Heltec V4-R8 and V4.3 (KCT8103L behind a 21 dB pad): 13 dB up to 13; 23 dBm at 10, 28 dBm
    /// from 17 on.
    case kct8103l
    /// Heltec V4 / V4.2 (GC1109 behind a 17 dB pad): 11 dB up to 15; 21 dBm at 10, 27 dBm at 18.
    case gc1109

    /// Net gain in dB for SX1262 settings 0...21.
    var gain: [Int] {
      switch self {
      case .t096: [14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 13, 13, 13, 12, 11, 10, 9, 8, 7]
      case .trackerV2: [14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 13, 13, 13, 12, 12, 11, 10, 9, 8, 7]
      case .kct8103l: [13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 12, 12, 11, 11, 10, 9, 8, 7]
      case .gc1109: [11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 10, 10, 9, 9, 8, 7]
      }
    }

    /// The power at the antenna for an SX1262 setting. Below 0 the chain is linear (the first
    /// point's gain); past the table, the last point's output (the PA is saturated there).
    public func antennaDbm(setting: Int) -> Int {
      let table = gain
      if setting < 0 { return setting + table[0] }
      if setting >= table.count { return (table.count - 1) + table[table.count - 1] }
      return setting + table[setting]
    }
  }

  /// The curve for a radio's reported model string, matched by substring like
  /// `DevicePlatform.detect(from:)` (the firmware's model string carries vendor and variant text
  /// around the board name), most specific first: a "Heltec V4.3 …" or "Heltec V4 R8 …" has the
  /// KCT8103L, any other "Heltec V4 …" (the V4.2, its Kit V1) the GC1109. Boards whose curve is not
  /// known (the Meshnology W12's GC1109 sits behind a different pad) return nil and show the setting.
  public static func curve(model: String) -> Curve? {
    if model.localizedStandardContains("T096") { return .t096 }
    if model.localizedStandardContains("Tracker V2") { return .trackerV2 }
    if model.localizedStandardContains("V4 R8") || model.localizedStandardContains("V4.3") { return .kct8103l }
    if model.localizedStandardContains("Heltec V4") { return .gc1109 }
    return nil
  }

  /// Whether `model` (the radio's reported model string) has a known amplifier.
  public static func hasAmplifier(model: String) -> Bool {
    curve(model: model) != nil
  }

  /// TX power to display for a radio: the power at the antenna for a known amplified board,
  /// else the setting it reports.
  public static func effectiveTxPower(reported: Int, model: String) -> Int {
    curve(model: model)?.antennaDbm(setting: reported) ?? reported
  }

  /// The most the radio radiates: its reported maximum setting (`maxTxPower`) through the board's
  /// curve (a T096 capped at 18 radiates 28 dBm), else the maximum itself.
  public static func antennaMaxTxPower(reportedMax: Int, model: String) -> Int {
    effectiveTxPower(reported: reportedMax, model: model)
  }
}
