import CairnServices
import Foundation

/// What a radio config profile holds, in the words and figures Radio Settings uses for the
/// connected radio (`HomeStatusLines`, the Parameters card), so a profile reads like the page it
/// would change.
enum RadioProfileSummary {
  /// The preset the radio settings match, or "Custom" when they match none or several.
  static func presetName(_ radio: MeshCoreNodeConfig.RadioSettings) -> String {
    RadioPresets.matchingPreset(
      frequencyKHz: radio.frequency,
      bandwidthKHz: radio.bandwidth,
      spreadingFactor: radio.spreadingFactor,
      codingRate: radio.codingRate
    )?.name ?? L10n.Settings.BatteryCurve.custom
  }

  /// "910.525 MHz".
  static func frequency(_ radio: MeshCoreNodeConfig.RadioSettings) -> String {
    L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz(radio.frequency))
  }

  /// "SF7 · 62.5 kHz · CR5", as the Parameters card on Radio Settings.
  static func modulation(_ radio: MeshCoreNodeConfig.RadioSettings) -> String {
    let bandwidth = RadioOptions.formatBandwidth(RadioOptions.nearestBandwidth(to: radio.bandwidth))
    return NodeRouteFormat.joined([
      L10n.Settings.Dashboard.modulation(Int(radio.spreadingFactor), bandwidth),
      "CR\(radio.codingRate)",
    ])
  }

  /// "Radio setting 22 dBm": the radio chip's setting the profile holds. A profile doesn't record
  /// the board it came from, and the same setting radiates more on a board with an amplifier (a
  /// T096 at 9 gives about 23 dBm at the antenna), so it is never shown as plain antenna dBm.
  static func txPower(_ radio: MeshCoreNodeConfig.RadioSettings) -> String {
    L10n.Settings.Radio.TxPower.radioSetting(L10n.Settings.DeviceInfo.txPowerFormat(Int(radio.txPower).formatted()))
  }

  /// The channel names in slot order, blank names left out.
  static func channelNames(_ config: MeshCoreNodeConfig) -> [String] {
    (config.channels ?? []).map(\.name).filter { !$0.isEmpty }
  }

  /// The profile's card line: "MeshCore US · 910.525 MHz · 22 dBm · Channels: 3", each part only
  /// when the profile holds it.
  static func line(_ config: MeshCoreNodeConfig) -> String {
    NodeRouteFormat.joined([
      config.radioSettings.map(presetName),
      config.radioSettings.map(frequency),
      config.radioSettings.map(txPower),
      config.channels.map { L10n.Settings.Connections.Profiles.channelCount($0.count) },
    ])
  }
}
