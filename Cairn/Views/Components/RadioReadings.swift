import Foundation
import CairnServices

/// The connected radio's headline readings, shared by the title bar's status line and the
/// Settings dashboard so both always show the same numbers.
extension AppState {
  /// The session is fully up. During auto-reconnect `connectedDevice` is kept while the
  /// session is torn down, so it alone would present the last readings as live.
  var isRadioReady: Bool {
    connectionState == .ready && connectedDevice != nil
  }

  /// Battery charge from the radio's voltage and its discharge curve; nil until a reading arrives.
  var radioBatteryPercent: Int? {
    #if DEBUG && targetEnvironment(simulator)
      // The simulator's mock radio never answers a battery request, so UI tests
      // pass `-uiTestBatteryPercent 87` to exercise the layouts that show one.
      let override = Int(ProcessInfo.processInfo.launchArgument("uiTestBatteryPercent") ?? "") ?? 0
      if override > 0 { return min(override, 100) }
    #endif
    guard isRadioReady, let battery = batteryMonitor.deviceBattery, battery.isBatteryPresent else {
      return nil
    }
    return min(max(battery.percentage(using: batteryMonitor.activeBatteryOCVArray(for: connectedDevice)), 0), 100)
  }

  /// Battery voltage in volts, when the radio has reported one.
  var radioBatteryVoltage: Double? {
    guard isRadioReady, let battery = batteryMonitor.deviceBattery, battery.isBatteryPresent else {
      return nil
    }
    return battery.voltage
  }

  /// TX power in dBm at the antenna: the radio chip's setting the radio reports, through the
  /// amplifier curve of boards known to have one (a Heltec T096 at setting 9 shows 23; 15-16 show 28).
  var radioTxPower: Int? {
    connectedDevice.map { RadioAmplifier.effectiveTxPower(reported: Int($0.txPower), model: $0.manufacturerName) }
  }

  /// The most the radio radiates: its maximum setting through the same curve (a T096 capped at 16: 28).
  var radioMaxTxPower: Int? {
    connectedDevice.map { RadioAmplifier.antennaMaxTxPower(reportedMax: Int($0.maxTxPower), model: $0.manufacturerName) }
  }
}

/// TX power texts, one convention everywhere: the number a radio reports and the app sends is the
/// radio chip's setting; on a board with a PA after the chip (`RadioAmplifier`, or a remote node's
/// `txa=` figure) the power at the antenna leads and the setting follows, and where the two are the
/// same the setting shows alone as plain dBm.
enum TxPowerText {
  static func dBm(_ value: Int) -> String {
    L10n.Settings.DeviceInfo.txPowerFormat(value.formatted())
  }

  /// The connected radio's: "23 dBm at antenna (setting 9 dBm)" on a known amplified board, else "22 dBm".
  static func reading(setting: Int, model: String) -> String {
    guard RadioAmplifier.hasAmplifier(model: model) else { return dBm(setting) }
    return withAntenna(RadioAmplifier.effectiveTxPower(reported: setting, model: model), setting: setting)
  }

  /// "23 dBm at antenna (setting 9 dBm)", or plain dBm when the two are the same.
  static func withAntenna(_ antenna: Int, setting: Int) -> String {
    antenna == setting ? dBm(setting) : L10n.Settings.Radio.TxPower.atAntennaWithSetting(dBm(antenna), dBm(setting))
  }

  /// A remote node's card line. `antenna` is its `txa=` figure for this setting (newer Cairn
  /// firmware), nil when unknown (stock or older firmware): the value is then labelled as the radio
  /// setting it is, since a board with a PA radiates more.
  static func remoteDetail(setting: Int, antenna: Int?) -> String {
    guard let antenna else { return L10n.Settings.Radio.TxPower.detailSetting(dBm(setting)) }
    return "\(L10n.Settings.Dashboard.txPower) \(withAntenna(antenna, setting: setting))"
  }
}
