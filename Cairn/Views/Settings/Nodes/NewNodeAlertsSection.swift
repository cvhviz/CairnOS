import CairnServices
import SwiftUI
import UserNotifications

/// The "new node discovered" notification switches, on Settings → Nodes beside the auto-add rules
/// that decide what a discovered node becomes. Same preferences as before
/// (`NotificationPreferencesStore`); when iOS has notifications off for the app, says so and links
/// to Settings, since the switches alone would do nothing.
struct NewNodeAlertsSection: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var preferences = NotificationPreferencesStore()
  @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

  var body: some View {
    @Bindable var preferences = preferences
    CardFormSection(L10n.Settings.Nodes.Alerts.header, info: L10n.Settings.Nodes.Alerts.footer) {
      ToggleCard(
        L10n.Settings.Nodes.Alerts.newNodeDiscovered,
        systemImage: "person.badge.plus",
        color: .green,
        isOn: Binding(
          get: { preferences.newContactDiscoveredEnabled },
          set: { newValue in
            withAnimation { preferences.newContactDiscoveredEnabled = newValue }
          }
        )
      )
      .dimmedWhenDisabled()
      .disabled(isDenied)

      // The node types follow the master switch, with the same names and icons as Auto-Add's
      // types above so one kind of node looks the same everywhere on the page.
      if preferences.newContactDiscoveredEnabled {
        Group {
          ToggleCard(
            L10n.Settings.Nodes.autoAddContacts,
            systemImage: "person.fill",
            color: .blue,
            isOn: $preferences.discoveryContactEnabled
          )
          ToggleCard(
            L10n.Settings.Nodes.autoAddRepeaters,
            systemImage: "antenna.radiowaves.left.and.right",
            color: .orange,
            isOn: $preferences.discoveryRepeaterEnabled
          )
          ToggleCard(
            L10n.Settings.Nodes.autoAddRoomServers,
            systemImage: "bubble.left.and.bubble.right.fill",
            color: .purple,
            isOn: $preferences.discoveryRoomEnabled
          )
        }
        .dimmedWhenDisabled()
        .disabled(isDenied)
      }

      if isDenied {
        ActionCard(
          L10n.Settings.Notifications.openSettings,
          systemImage: "bell.slash.fill",
          color: .gray,
          subtitle: L10n.Settings.Notifications.disabled
        ) {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
          }
        }
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

  /// With notifications off in iOS the switches would do nothing, so they're dimmed until the
  /// user turns them back on from the Open Settings card.
  private var isDenied: Bool {
    authorizationStatus == .denied
  }

  private func refreshAuthorizationStatus() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    authorizationStatus = settings.authorizationStatus
  }
}
