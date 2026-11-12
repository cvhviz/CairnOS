import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "ChannelNotificationDefaults")

/// Picks the notification level new channels start with, and can apply it to
/// every existing channel in one step instead of editing each channel's info sheet.
struct ChannelNotificationDefaultsSection: View {
  @Environment(\.appState) private var appState

  @State private var level = ChannelNotificationDefaults.level()
  @State private var showingApplyConfirmation = false
  @State private var isApplying = false
  @State private var appliedTrigger = 0
  @State private var errorMessage: String?

  var body: some View {
    CardFormSection(
      L10n.Settings.Notifications.ChannelDefault.header,
      info: L10n.Settings.Notifications.ChannelDefault.footer
    ) {
      PickerCard(
        L10n.Settings.Notifications.ChannelDefault.newChannels,
        systemImage: "number",
        color: .teal,
        selection: $level
      ) {
        ForEach(NotificationLevel.allCases, id: \.self) { level in
          Text(level.localizedName).tag(level)
        }
      }
      .onChange(of: level) { _, newValue in
        ChannelNotificationDefaults.setLevel(newValue)
      }

      ActionCard(
        L10n.Settings.Notifications.ChannelDefault.applyToAll,
        systemImage: "checkmark.circle.fill",
        color: .teal
      ) {
        showingApplyConfirmation = true
      }
      .overlay(alignment: .trailing) {
        if isApplying {
          ProgressView()
            .padding(.trailing, 12)
        }
      }
      .disabled(isApplying || appState.currentRadioID == nil)
      // The card's plain style doesn't dim a disabled button; the spinner covers `isApplying`.
      .opacity(appState.currentRadioID == nil ? 0.5 : 1)
    }
    .cairnFeedback(.success, trigger: appliedTrigger)
    .errorAlert($errorMessage)
    .confirmationDialog(
      L10n.Settings.Notifications.ChannelDefault.applyConfirmTitle(level.localizedName),
      isPresented: $showingApplyConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Settings.Notifications.ChannelDefault.applyToAll) {
        Task { await applyToAllChannels() }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    }
  }

  private func applyToAllChannels() async {
    guard let radioID = appState.currentRadioID,
          let dataStore = appState.offlineDataStore else { return }
    isApplying = true
    defer { isApplying = false }
    do {
      try await dataStore.setAllChannelsNotificationLevel(radioID: radioID, level: level)
      await appState.services?.notificationService.updateBadgeCount()
      appState.services?.syncCoordinator.notifyConversationsChanged()
      appliedTrigger += 1
    } catch {
      logger.error("Failed to apply notification level to all channels: \(error)")
      errorMessage = error.userFacingMessage
    }
  }
}
