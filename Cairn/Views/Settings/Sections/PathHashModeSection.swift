import CairnServices
import SwiftUI

/// The path hash size on firmware v10+ devices, as a tile on Settings → Radio. Unlike the radio
/// parameters it applies as soon as it's picked.
struct PathHashModeSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  /// Runs when the retry alert gives up, in place of dismissing this view.
  var onGiveUp: (() -> Void)?
  /// Reports a write in flight or its alert showing, so a hosting sheet can hold itself open
  /// until the outcome has been seen.
  var onBusyChange: ((Bool) -> Void)?
  @State private var selectedMode: UInt8?
  @State private var isApplying = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()

  private var currentMode: UInt8 {
    selectedMode ?? appState.connectedDevice?.pathHashMode ?? 0
  }

  /// The size's name, for the tile and for the Radio page's card.
  static func title(for mode: UInt8) -> String {
    switch mode {
    case 1: L10n.Settings.PathHashMode.twoBytes
    case 2: L10n.Settings.PathHashMode.threeBytes
    default: L10n.Settings.PathHashMode.oneByte
    }
  }

  var body: some View {
    CardFormSection(L10n.Settings.PathHashMode.header, info: L10n.Settings.PathHashMode.footer) {
      MetricTileGrid {
        Menu {
          Picker(L10n.Settings.PathHashMode.label, selection: Binding(
            get: { currentMode },
            set: { newMode in
              guard newMode != selectedMode else { return }
              selectedMode = newMode
              applyMode(newMode)
            }
          )) {
            Text(L10n.Settings.PathHashMode.oneByte).tag(UInt8(0))
            Text(L10n.Settings.PathHashMode.twoBytes).tag(UInt8(1))
            Text(L10n.Settings.PathHashMode.threeBytes).tag(UInt8(2))
          }
        } label: {
          RadioSettingTile(
            L10n.Settings.PathHashMode.label,
            systemImage: "number",
            value: Self.title(for: currentMode),
            editStyle: .menu
          )
        }
        .buttonStyle(.plain)
        .radioDisabled(for: appState.connectionState, or: isApplying)
      }
    }
    .onAppear {
      selectedMode = appState.connectedDevice?.pathHashMode ?? 0
    }
    .onChange(of: appState.connectedDevice?.pathHashMode) { _, newValue in
      if let newValue {
        selectedMode = newValue
      }
    }
    .onChange(of: isBusy) { _, busy in
      onBusyChange?(busy)
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  private var isBusy: Bool {
    isApplying || errorMessage != nil || retryAlert.isPresented
  }

  private func applyMode(_ mode: UInt8) {
    isApplying = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }
        _ = try await settingsService.setPathHashModeVerified(mode)
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        selectedMode = appState.connectedDevice?.pathHashMode ?? 0
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { applyMode(mode) },
          onMaxRetriesExceeded: { onGiveUp?() ?? dismiss() }
        )
      } catch {
        errorMessage = error.userFacingMessage
        selectedMode = appState.connectedDevice?.pathHashMode ?? 0
      }
      isApplying = false
    }
  }
}
