import CairnServices
import SwiftUI

/// The Connection page's last card: Forget Device and Factory Reset, the two ways to be done with
/// a radio, side by side. Same confirmations and flows they had before, through the same view
/// model; node removal lives on Settings → Nodes (`NodeRemovalSection`). The page's Device section
/// already names the connected radio, so it isn't repeated here.
struct DeviceResetSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel = DangerZoneViewModel()

  var body: some View {
    CardFormSection(L10n.Settings.DangerZone.header, footer: L10n.Settings.DangerZone.footer) {
      ActionCard(L10n.Settings.DangerZone.forgetDevice, systemImage: "trash", role: .destructive) {
        viewModel.showingForgetConfirmation = true
      }
      // Not while a factory reset is running: the two flows would race over the same radio.
      .dimmedWhenDisabled()
      .disabled(viewModel.isResetting)

      ActionCard(
        viewModel.isResetting ? L10n.Settings.DangerZone.resetting : L10n.Settings.DangerZone.factoryReset,
        systemImage: "exclamationmark.triangle",
        role: .destructive
      ) {
        viewModel.showingResetAlert = true
      }
      .overlay(alignment: .trailing) {
        if viewModel.isResetting {
          ProgressView()
            .padding(.trailing, 12)
        }
      }
      .dimmedWhenDisabled()
      .radioDisabled(for: appState.connectionState, or: viewModel.isResetting)
    }
    .task {
      viewModel.configure(
        settingsService: { appState.services?.settingsService },
        connectedDevice: { appState.connectedDevice },
        connectionManager: appState.connectionManager
      )
    }
    .confirmationDialog(
      L10n.Settings.DangerZone.Dialog.Forget.title,
      isPresented: $viewModel.showingForgetConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Settings.DangerZone.Dialog.Forget.keepData, role: .destructive) {
        forgetDevice(deleteData: false)
      }
      Button(L10n.Settings.DangerZone.Dialog.Forget.deleteAll, role: .destructive) {
        forgetDevice(deleteData: true)
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Settings.DangerZone.Dialog.Forget.message)
    }
    // The same keep/delete choice as Forget: the radio is wiped either way, the phone's copy of
    // its messages, contacts and channels only on Delete.
    .confirmationDialog(
      L10n.Settings.DangerZone.Dialog.Reset.title,
      isPresented: $viewModel.showingResetAlert,
      titleVisibility: .visible
    ) {
      Button(L10n.Settings.DangerZone.Dialog.Reset.keepData, role: .destructive) {
        factoryReset(deleteData: false)
      }
      Button(L10n.Settings.DangerZone.Dialog.Reset.deleteAll, role: .destructive) {
        factoryReset(deleteData: true)
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Settings.DangerZone.Dialog.Reset.message)
    }
    .errorAlert($viewModel.errorMessage)
  }

  private func factoryReset(deleteData: Bool) {
    Task {
      if await viewModel.factoryReset(deleteData: deleteData) {
        if deleteData { appState.radioAvatars.reload() }
        dismiss()
      }
    }
  }

  private func forgetDevice(deleteData: Bool) {
    Task {
      if await viewModel.forgetDevice(deleteData: deleteData) {
        if deleteData { appState.radioAvatars.reload() }
        dismiss()
      }
    }
  }
}
