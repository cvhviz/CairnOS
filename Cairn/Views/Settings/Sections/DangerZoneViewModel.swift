import CairnServices
import SwiftUI

@Observable
@MainActor
final class DangerZoneViewModel {
  var showingForgetConfirmation = false
  var showingResetAlert = false
  var isResetting = false
  var errorMessage: String?

  // MARK: - Dependencies

  private var settingsServiceProvider: @MainActor () -> SettingsService? = { nil }
  var settingsService: SettingsService? {
    settingsServiceProvider()
  }

  private var connectedDeviceProvider: @MainActor () -> DeviceDTO? = { nil }
  var connectedDevice: DeviceDTO? {
    connectedDeviceProvider()
  }

  private var connectionManager: ConnectionManager?

  /// Grace period for the radio to reboot after a factory reset before local cleanup.
  private static let resetRebootGracePeriod: Duration = .seconds(1)

  func configure(
    settingsService: @escaping @MainActor () -> SettingsService?,
    connectedDevice: @escaping @MainActor () -> DeviceDTO?,
    connectionManager: ConnectionManager
  ) {
    settingsServiceProvider = settingsService
    connectedDeviceProvider = connectedDevice
    self.connectionManager = connectionManager
  }

  /// Returns true when the device was forgotten and the hosting page should dismiss.
  func forgetDevice(deleteData: Bool) async -> Bool {
    guard let connectionManager else { return false }
    do {
      try await connectionManager.forgetDevice(deleteData: deleteData)
      return true
    } catch DevicePairingError.cancelled {
      return false
    } catch {
      errorMessage = error.userFacingMessage
      return false
    }
  }

  /// Returns true when the reset flow finished and the hosting page should dismiss.
  /// A nil service or device ID mirrors a disconnected state.
  /// - Parameter deleteData: Whether the phone's copy of the radio's messages, contacts and
  ///   channels goes too (as Forget Device offers); with false the record stays as a ghost.
  func factoryReset(deleteData: Bool = true) async -> Bool {
    guard let settingsService,
          let deviceID = connectedDevice?.id,
          let connectionManager else {
      errorMessage = L10n.Settings.DangerZone.Error.servicesUnavailable
      return false
    }

    isResetting = true
    defer { isResetting = false }

    // Send reset command. The device typically reboots before responding,
    // so a timeout/connection error here is expected, not a failure.
    do {
      try await settingsService.factoryReset()
      try await Task.sleep(for: Self.resetRebootGracePeriod)
    } catch {
      // Expected: device reboots before sending OK response
    }

    // Always clean up: remove from ASK, disconnect, then delete or demote the SwiftData record.
    await connectionManager.forgetDevice(id: deviceID, deleteData: deleteData)
    return true
  }
}
