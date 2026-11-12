import CairnServices
import Foundation

/// What to say when the radio refuses a change to its radio settings (a preset, or the frequency,
/// bandwidth, SF and CR).
enum RadioWriteErrorMessage {
  /// The error's own message, except for the one refusal that has a cause the user can act on:
  /// Cairn firmware answers `CMD_SET_RADIO_PARAMS` over Wi-Fi with "unsupported command" unless
  /// the phone is a trusted device on the radio (its Wi-Fi address chosen "Always allow" in the
  /// radio's prompt), which would otherwise read as a firmware without the command. The message
  /// names the ways out: that trust (for a phone the radio let in once, its "App link" setting off
  /// and on makes it ask again), or Bluetooth / the radio itself. Every companion firmware
  /// has the command and official firmware takes it over Wi-Fi from anyone, so neither over
  /// Bluetooth nor from official firmware does this message appear.
  static func message(for error: any Error, isWiFi: Bool) -> String {
    if isWiFi, isUnsupportedCommand(error) {
      return L10n.Localizable.Error.Settings.radioSettingsOverWiFi
    }
    return error.userFacingMessage
  }

  /// The message for `error`, noting a Wi-Fi refusal on `appState` so Settings and onboarding
  /// stop offering a write the radio won't take over this link (until the link ends:
  /// `ConnectionUIState.radioSettingsRefusedOverWiFiDeviceID`).
  @MainActor
  static func message(for error: any Error, appState: AppState) -> String {
    let isWiFi = appState.connectionManager.currentTransportType == .wifi
    if isWiFi, isUnsupportedCommand(error), let deviceID = appState.connectedDevice?.id {
      appState.connectionUI.radioSettingsRefusedOverWiFiDeviceID = deviceID
    }
    return message(for: error, isWiFi: isWiFi)
  }

  static func isUnsupportedCommand(_ error: any Error) -> Bool {
    let unsupported = ErrorCode.unsupportedCommand.rawValue
    switch error {
    case let SettingsServiceError.sessionError(.deviceError(code)):
      return code == unsupported
    case let MeshCoreError.deviceError(code):
      return code == unsupported
    default:
      return false
    }
  }
}

extension AppState {
  /// Whether the connected radio has refused radio settings over the Wi-Fi link it is on now.
  /// Over Bluetooth, or on another radio, it is false again.
  var radioRefusesSettingsOverWiFi: Bool {
    Self.radioRefusesSettingsOverWiFi(
      refusedDeviceID: connectionUI.radioSettingsRefusedOverWiFiDeviceID,
      connectedDeviceID: connectedDevice?.id,
      isWiFi: connectionManager.currentTransportType == .wifi
    )
  }

  nonisolated static func radioRefusesSettingsOverWiFi(
    refusedDeviceID: UUID?,
    connectedDeviceID: UUID?,
    isWiFi: Bool
  ) -> Bool {
    guard isWiFi, let refusedDeviceID else { return false }
    return refusedDeviceID == connectedDeviceID
  }
}
