import CairnServices
import SwiftUI

/// Settings → Notifications → Quiet Hours: a daily window in which notifications arrive silently
/// (no sound, no banner; they still land in Notification Center and the badge still counts), with
/// direct messages optionally let through. The window is stored as minutes past midnight in
/// `NotificationPreferencesStore`; `NotificationService` checks it as it posts.
struct QuietHoursSection: View {
  @State private var preferences = NotificationPreferencesStore()

  var body: some View {
    @Bindable var preferences = preferences
    CardFormSection(L10n.Settings.Notifications.QuietHours.header, footer: L10n.Settings.Notifications.QuietHours.footer) {
      ToggleCard(
        L10n.Settings.Notifications.QuietHours.enable,
        systemImage: "moon.fill",
        color: .indigo,
        isOn: $preferences.quietHoursEnabled.animation(.snappy)
      )
      .accessibilityIdentifier("notifications.quietHours")

      if preferences.quietHoursEnabled {
        timeCard(
          L10n.Settings.Notifications.QuietHours.start,
          systemImage: "moon.zzz",
          minute: $preferences.quietHoursStartMinute
        )
        timeCard(
          L10n.Settings.Notifications.QuietHours.end,
          systemImage: "sun.horizon",
          minute: $preferences.quietHoursEndMinute
        )
        ToggleCard(
          L10n.Settings.Notifications.QuietHours.allowDirect,
          systemImage: "message.fill",
          color: .blue,
          isOn: $preferences.quietHoursAllowDirectMessages
        )
      }
    }
  }

  /// A time-only picker on a card, bound to a minute past midnight.
  private func timeCard(_ title: String, systemImage: String, minute: Binding<Int>) -> some View {
    let date = Binding<Date>(
      get: { QuietHoursWindow.date(forMinute: minute.wrappedValue) },
      set: { minute.wrappedValue = QuietHoursWindow.minute(of: $0) }
    )
    return HStack(spacing: 8) {
      SettingCardLabel(title, systemImage: systemImage, color: .indigo)
      Spacer(minLength: 8)
      DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
        .labelsHidden()
    }
    .cardSurface(padding: 12)
  }
}

#Preview {
  CardForm {
    QuietHoursSection()
  }
}
