import CairnServices
import SwiftUI

/// The low-battery notification switch, on Settings › Notifications with every other alert. Same
/// preference as before (`AppStorageKey.notifyLowBattery`). Permission to notify is asked for, or
/// linked to in the system Settings, once for the whole page by the Messages section at its top
/// (`NotificationSettingsSection`), so it isn't repeated here.
struct LowBatteryAlertSection: View {
  @State private var preferences = NotificationPreferencesStore()

  var body: some View {
    @Bindable var preferences = preferences
    CardFormSection(L10n.Settings.DeviceInfo.battery, info: L10n.Settings.Battery.Alerts.footer) {
      ToggleCard(
        L10n.Settings.Notifications.lowBattery,
        systemImage: "battery.25",
        color: .red,
        isOn: $preferences.lowBatteryEnabled
      )
    }
  }
}
