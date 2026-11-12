import CairnServices
import SwiftUI

/// Renders a `SettingsDetail` page. Single source of truth for every Settings page, pushed inside
/// Settings' own stack (`SettingsStack`).
struct SettingsDetailView: View {
  let detail: SettingsDetail

  var body: some View {
    switch detail {
    case .radio:
      RadioSettingsView()
    case .location:
      LocationSettingsView()
    case .battery:
      BatteryView()
    case .nodes:
      NodesSettingsView()
    case .connection:
      ConnectionSettingsView()
    case .deviceInfo:
      DeviceInfoView()
    case .firmwareUpdate:
      FirmwareUpdateView()
    case .clock:
      SettingsFormPage(detail) { DeviceClockSection() }
    case .connections:
      ConnectionsView()
    case .notifications:
      NotificationsSettingsPage()
    case .chats:
      ChatSettingsView()
    case .gps:
      GPSSettingsView()
    case .spectrum:
      SpectrumTabSettingsSheet()
    case .appearance:
      SettingsFormPage(detail) { AppearanceSettingsSection() }
    case .carPlaySiri:
      SettingsFormPage(detail) { CarPlaySiriSettingsSection() }
    case .privacy:
      BlockedItemsView()
    case .backup:
      BackupSettingsPage()
    case .about:
      SettingsFormPage(detail) { AboutSettingsSection(showsDiagnostics: false) }
    case .advanced:
      AdvancedSettingsPage()
    }
  }
}

/// A page that is one or more existing sections on the card form, titled after its `SettingsDetail`.
struct SettingsFormPage<Content: View>: View {
  let detail: SettingsDetail
  @ViewBuilder let content: () -> Content

  init(_ detail: SettingsDetail, @ViewBuilder content: @escaping () -> Content) {
    self.detail = detail
    self.content = content
  }

  var body: some View {
    CardForm {
      content()
    }
    .flashingNavigationTitle(detail.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Settings › Notifications: every alert the app can raise, in one place — messages (by kind), the
/// level new channels start with, new nodes heard, and the radio's low battery.
struct NotificationsSettingsPage: View {
  var body: some View {
    SettingsFormPage(.notifications) {
      NotificationSettingsSection()
      QuietHoursSection()
      ChannelNotificationDefaultsSection()
      NewNodeAlertsSection()
      LowBatteryAlertSection()
    }
  }
}

/// Settings › Backup & Data: the app's file backup, the radio's configuration, and the data export.
struct BackupSettingsPage: View {
  @Environment(\.appState) private var appState

  var body: some View {
    SettingsFormPage(.backup) {
      BackupSettingsSection(
        connectionManager: appState.connectionManager,
        onImportRestoredData: { [appState] in appState.notifyDataRestored() },
        onChannelDraftSlotsAffected: { [appState] slotsByRadio in
          appState.draftStore.clearChannelDrafts(slotsByRadio: slotsByRadio)
        }
      )
    }
  }
}

/// Settings › Advanced: the debug logs and, once unlocked from onboarding (for App Review), Demo Mode.
struct AdvancedSettingsPage: View {
  @State private var demoModeManager = DemoModeManager.shared

  var body: some View {
    SettingsFormPage(.advanced) {
      AboutSettingsSection(showsAbout: false)

      if demoModeManager.isUnlocked {
        CardFormSection(L10n.Settings.DemoMode.header, info: L10n.Settings.DemoMode.footer) {
          ToggleCard(
            L10n.Settings.DemoMode.enabled,
            systemImage: "theatermasks.fill",
            color: .purple,
            isOn: $demoModeManager.isEnabled
          )
        }
      }
    }
  }
}
