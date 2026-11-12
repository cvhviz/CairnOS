import CairnServices
import SwiftUI
import UserNotifications

/// Notification toggle settings
struct NotificationSettingsSection: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var preferences = NotificationPreferencesStore()
  @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
  /// Messages a Cairn radio lost that no notification reported (RadioQueueLossLedger).
  @AppStorage(AppStorageKey.radioQueueLossUnseen.rawValue) private var radioQueueLossUnseen = 0
  @AppStorage(AppStorageKey.radioQueueLossDevice.rawValue) private var radioQueueLossDevice = ""

  var body: some View {
    @Bindable var preferences = preferences
    CardFormSection(
      L10n.Settings.Notifications.messagesHeader,
      // These switches are app-wide; per-conversation levels live in each chat's info screen.
      info: authorizationGranted ? L10n.Settings.Notifications.footer : nil
    ) {
      // Shown whatever the permission: it exists because no notification could say it.
      if radioQueueLossUnseen > 0 {
        ActionCard(
          L10n.Settings.Notifications.RadioQueueLoss.title(radioQueueLossUnseen),
          systemImage: "exclamationmark.triangle.fill",
          color: .orange,
          subtitle: L10n.Settings.Notifications.RadioQueueLoss.subtitle(
            radioQueueLossDevice.isEmpty ? "Radio" : radioQueueLossDevice
          )
        ) {
          RadioQueueLossLedger().dismiss()
        }
      }
      // Shown whatever the permission too: over WiFi, Background App Refresh is how messages
      // reach Cairn while it is closed.
      BackgroundRefreshNotice()
      switch authorizationStatus {
      case .notDetermined:
        ActionCard(L10n.Settings.Notifications.enable, systemImage: "bell.badge.fill", color: .red) {
          Task {
            await requestAuthorization()
          }
        }

      case .denied:
        ActionCard(
          L10n.Settings.Notifications.openSettings,
          systemImage: "bell.slash.fill",
          color: .gray,
          subtitle: L10n.Settings.Notifications.disabled
        ) {
          // Straight to this app's notification settings rather than its general page.
          if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
          }
        }

      default:
        ToggleCard(
          L10n.Settings.Notifications.contactMessages,
          systemImage: "message.fill",
          color: .blue,
          isOn: $preferences.contactMessagesEnabled
        )
        ToggleCard(
          L10n.Settings.Notifications.channelMessages,
          // The channel symbol and colour the New Channels picker below uses.
          systemImage: "number",
          color: .teal,
          isOn: $preferences.channelMessagesEnabled
        )
        ToggleCard(
          L10n.Settings.Notifications.roomMessages,
          systemImage: "bubble.left.and.bubble.right.fill",
          color: .purple,
          isOn: $preferences.roomMessagesEnabled
        )
        ToggleCard(
          L10n.Settings.Notifications.reactions,
          systemImage: "face.smiling.fill",
          color: .orange,
          isOn: $preferences.reactionNotificationsEnabled
        )
        // A dead-man's switch for background delivery: told when the app has heard nothing from its
        // radio for a while (it may have been closed) or Bluetooth is off.
        ToggleCard(
          L10n.Settings.Notifications.notReceiving,
          systemImage: "antenna.radiowaves.left.and.right.slash",
          color: .gray,
          isOn: $preferences.notReceivingReminderEnabled
        )
        // How every notification above arrives: with a sound, and counted on the app icon.
        ToggleCard(
          L10n.Settings.Notifications.sound,
          systemImage: "speaker.wave.2.fill",
          color: .pink,
          isOn: $preferences.soundEnabled
        )
        .accessibilityIdentifier("notifications.sound")
        ToggleCard(
          L10n.Settings.Notifications.badge,
          systemImage: "app.badge.fill",
          color: .red,
          isOn: $preferences.badgeEnabled
        )
        .accessibilityIdentifier("notifications.badge")
        // Low-battery warnings live on Settings → Battery and new-node alerts on Settings → Nodes,
        // each beside what it watches.
      }
    }
    .task {
      await refreshAuthorizationStatus()
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        Task {
          await refreshAuthorizationStatus()
        }
      }
    }
  }

  private var authorizationGranted: Bool {
    authorizationStatus != .notDetermined && authorizationStatus != .denied
  }

  private func refreshAuthorizationStatus() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    authorizationStatus = settings.authorizationStatus
  }

  /// Reads the outcome back from the system rather than inferring it from the result, so a thrown
  /// request stays not-determined and a provisional grant shows as what it is.
  private func requestAuthorization() async {
    _ = try? await UNUserNotificationCenter.current()
      .requestAuthorization(options: NotificationService.authorizationOptions)
    await refreshAuthorizationStatus()
  }
}
