import Intents
import CairnServices
import SwiftUI
import TipKit

/// Settings → CarPlay & Siri: the Live Activity switch and Siri permission,
/// the two things that carry the radio beyond the app. CarPlay reads and sends messages through
/// Siri, and the permission prompt only shows on the phone, so this is where it is asked before
/// driving (onboarding asks once too). The Siri card shows the current answer: a button to ask
/// while unanswered, the way to iOS Settings once declined.
struct CarPlaySiriSettingsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var siriStatus = SiriAuthorization.status
  private let liveActivityTip = LiveActivityTip()

  var body: some View {
    // Untitled: the page title names it; the "i" carries the explanation.
    CardFormSection(info: L10n.Settings.CarPlaySiri.info) {
      ToggleCard(
        L10n.Settings.LiveActivity.title,
        systemImage: "platter.filled.bottom.and.arrow.down.iphone",
        color: .orange,
        isOn: liveActivityBinding
      )

      siriCard

      // Inline below the controls rather than over them, so it never covers the switch it explains.
      TipView(liveActivityTip)
    }
    // The answer can change in iOS Settings while the app is in the background.
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        siriStatus = SiriAuthorization.status
      }
    }
  }

  @ViewBuilder
  private var siriCard: some View {
    switch siriStatus {
    case .notDetermined:
      ActionCard(
        L10n.Settings.Siri.allow,
        systemImage: "mic.fill",
        color: .pink,
        subtitle: L10n.Settings.Siri.allowSubtitle
      ) {
        Task { siriStatus = await SiriAuthorization.request() }
      }
    case .denied:
      ActionCard(
        L10n.Settings.Notifications.openSettings,
        systemImage: "mic.slash.fill",
        color: .gray,
        subtitle: L10n.Settings.Siri.deniedSubtitle
      ) {
        // iOS has no deep link to one app's Siri switch; the app's own page lists it.
        if let url = URL(string: UIApplication.openSettingsURLString) {
          openURL(url)
        }
      }
    case .restricted:
      ValueCard(L10n.Settings.Siri.title, systemImage: "mic.slash.fill", color: .gray, value: L10n.Settings.Siri.restricted)
    case .authorized:
      ValueCard(L10n.Settings.Siri.title, systemImage: "mic.fill", color: .pink, value: L10n.Settings.Siri.allowed)
    @unknown default:
      EmptyView()
    }
  }

  /// Turning the Live Activity off ends the one showing; turning it on starts one straight away
  /// when a radio is connected.
  private var liveActivityBinding: Binding<Bool> {
    Binding(
      get: { appState.liveActivityManager.isEnabled },
      set: { newValue in
        appState.liveActivityManager.isEnabled = newValue
        Task {
          if !newValue {
            await appState.liveActivityManager.endActivity()
          } else if appState.connectionState.isConnected {
            await appState.wireServicesIfConnected()
          }
        }
      }
    )
  }
}
