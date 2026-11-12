import CairnServices
import SwiftUI

/// Settings → Chats → Direct Messages: how many acknowledgments the radio sends per direct
/// message. A radio setting, so the Chats page shows it only while one is connected.
struct DirectMessagesSettingsSection: View {
  @Environment(\.appState) private var appState
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var isSaving = false

  private var device: DeviceDTO? {
    appState.connectedDevice
  }

  var body: some View {
    CardFormSection(L10n.Settings.DirectMessages.header, info: L10n.Settings.DirectMessages.footer) {
      PickerCard(
        L10n.Settings.DirectMessages.acknowledgments,
        systemImage: "checkmark.message.fill",
        color: .green,
        selection: acksBinding
      ) {
        Text("1").tag(1)
        Text("2").tag(2)
      }
      .radioDisabled(for: appState.connectionState, or: isSaving)
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  // MARK: - Binding

  private var acksBinding: Binding<Int> {
    Binding(
      get: { Int(device?.multiAcks ?? 0) + 1 },
      set: { saveMultiAcks(UInt8($0 - 1)) }
    )
  }

  // MARK: - Save

  private func saveMultiAcks(_ value: UInt8) {
    guard let device, let settingsService = appState.services?.settingsService else { return }

    isSaving = true
    Task {
      do {
        _ = try await settingsService.setOtherParamsVerified(from: device, multiAcks: value)
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { saveMultiAcks(value) },
          // Stays on Chats: this section shares the page with app preferences, so one failed
          // radio write shouldn't close it. The picker reads the radio, so it shows what stuck.
          onMaxRetriesExceeded: {}
        )
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}

#Preview {
  CardForm {
    DirectMessagesSettingsSection()
  }
}
