import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// What Settings → Radio and onboarding say when the radio refuses a preset or its parameters.
struct RadioWriteErrorMessageTests {
  private static let refused = SettingsServiceError.sessionError(
    .deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  )

  @Test func `a write refused over Wi-Fi says to use Always allow, Bluetooth or the radio`() {
    #expect(
      RadioWriteErrorMessage.message(for: Self.refused, isWiFi: true)
        == L10n.Localizable.Error.Settings.radioSettingsOverWiFi
    )
    let raw: any Error = MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
    #expect(RadioWriteErrorMessage.message(for: raw, isWiFi: true) == L10n.Localizable.Error.Settings.radioSettingsOverWiFi)
    // Cairn firmware takes radio settings over Wi-Fi from a phone marked "Always allow" on the
    // radio, so the message says so rather than that Wi-Fi never works, and how to get the radio's
    // question back for a phone it let in once (its App link setting off and on). The radio's labels
    // are English in every language's text.
    let text = L10n.Localizable.Error.Settings.radioSettingsOverWiFi
    #expect(text.contains("Always allow"))
    #expect(text.contains("App link"))
    #expect(!text.contains("doesn't accept"))
  }

  @Test func `the same refusal over Bluetooth keeps its own message`() {
    #expect(RadioWriteErrorMessage.message(for: Self.refused, isWiFi: false) == Self.refused.userFacingMessage)
  }

  @Test func `other errors over Wi-Fi keep their own message`() {
    let illegal = SettingsServiceError.sessionError(.deviceError(code: ErrorCode.illegalArgument.rawValue))
    #expect(RadioWriteErrorMessage.message(for: illegal, isWiFi: true) == illegal.userFacingMessage)
    let timeout = SettingsServiceError.sessionError(.timeout)
    #expect(RadioWriteErrorMessage.message(for: timeout, isWiFi: true) == timeout.userFacingMessage)
  }

  @Test func `a preset whose path hash size failed names the preset`() {
    let error = SettingsServiceError.presetPathHashNotApplied(presetName: "WCMesh (SoCal)")
    #expect(error.userFacingMessage == L10n.Localizable.Error.Settings.presetPathHashNotApplied("WCMesh (SoCal)"))
    #expect(error.userFacingMessage.contains("WCMesh (SoCal)"))
    #expect(!error.isRetryable)
  }

  @Test func `a dropped link is a readable, retryable settings error`() {
    let error = SettingsServiceError(transportError: .notConnected)
    #expect(error.isRetryable)
    #expect(error.userFacingMessage == L10n.Localizable.Error.Settings.notConnected)
  }

  @Test @MainActor func `a refusal over Wi-Fi is remembered for that radio on that link only`() {
    let appState = AppState()
    let device = MockDataProvider.simulatorDevice
    appState.connectionManager.connectedDevice = device
    appState.connectionManager.currentTransportType = .wifi
    #expect(!appState.radioRefusesSettingsOverWiFi)

    // Any other error over Wi-Fi isn't a refusal of radio settings.
    _ = RadioWriteErrorMessage.message(for: SettingsServiceError.sessionError(.timeout), appState: appState)
    #expect(!appState.radioRefusesSettingsOverWiFi)

    #expect(
      RadioWriteErrorMessage.message(for: Self.refused, appState: appState)
        == L10n.Localizable.Error.Settings.radioSettingsOverWiFi
    )
    #expect(appState.radioRefusesSettingsOverWiFi)

    // Over Bluetooth the same radio takes radio settings, so nothing is held back there.
    appState.connectionManager.currentTransportType = .bluetooth
    #expect(!appState.radioRefusesSettingsOverWiFi)
  }

  /// The radio's trust can change between links (the phone reconnects and is marked "Always
  /// allow"), so a refusal ends with the link: a reconnect offers radio settings again.
  @Test @MainActor func `a refusal over Wi-Fi ends when the link does`() {
    let appState = AppState()
    appState.connectionManager.connectedDevice = MockDataProvider.simulatorDevice
    appState.connectionManager.currentTransportType = .wifi
    _ = RadioWriteErrorMessage.message(for: Self.refused, appState: appState)
    #expect(appState.radioRefusesSettingsOverWiFi)

    appState.tearDownAppStateSessionState(announcesConnectionLoss: false)
    #expect(appState.connectionUI.radioSettingsRefusedOverWiFiDeviceID == nil)
    #expect(!appState.radioRefusesSettingsOverWiFi)
  }

  @Test func `the remembered refusal holds only for the radio that refused, over Wi-Fi`() {
    let refused = UUID()
    #expect(AppState.radioRefusesSettingsOverWiFi(refusedDeviceID: refused, connectedDeviceID: refused, isWiFi: true))
    #expect(!AppState.radioRefusesSettingsOverWiFi(refusedDeviceID: refused, connectedDeviceID: UUID(), isWiFi: true))
    #expect(!AppState.radioRefusesSettingsOverWiFi(refusedDeviceID: refused, connectedDeviceID: refused, isWiFi: false))
    #expect(!AppState.radioRefusesSettingsOverWiFi(refusedDeviceID: nil, connectedDeviceID: refused, isWiFi: true))
  }
}
