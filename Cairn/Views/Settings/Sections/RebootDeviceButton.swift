import CairnServices
import SwiftUI

/// Reboots the connected radio after a confirmation. A card in the Connection page's device actions.
struct RebootDeviceButton: View {
  @Environment(\.appState) private var appState
  @State private var showingRebootAlert = false
  @State private var isRebooting = false
  @State private var errorMessage: String?

  var body: some View {
    ActionCard(
      isRebooting ? L10n.Settings.DeviceActions.rebooting : L10n.Settings.DeviceActions.rebootDevice,
      systemImage: "arrow.clockwise",
      color: .orange
    ) {
      showingRebootAlert = true
    }
    .overlay(alignment: .trailing) {
      if isRebooting {
        ProgressView()
          .padding(.trailing, 12)
      }
    }
    .dimmedWhenDisabled()
    .radioDisabled(for: appState.connectionState, or: isRebooting)
    .alert(L10n.Settings.DeviceActions.Alert.Reboot.title, isPresented: $showingRebootAlert) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.DeviceActions.Alert.Reboot.confirm) {
        rebootDevice()
      }
    } message: {
      Text(L10n.Settings.DeviceActions.Alert.Reboot.message)
    }
    .errorAlert($errorMessage)
  }

  private func rebootDevice() {
    guard let settingsService = appState.services?.settingsService else { return }

    isRebooting = true
    Task {
      defer { isRebooting = false }
      do {
        try await settingsService.reboot()
      } catch BLEError.operationTimeout {
        // Expected - device reboots before BLE write callback arrives
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}
