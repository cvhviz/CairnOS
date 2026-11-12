import SwiftUI
import UIKit

/// A card shown where Cairn explains background delivery (Settings › Notifications, and
/// Connections while the radio is on WiFi) when Background App Refresh cannot run for Cairn. Over
/// WiFi that is the only way Cairn hears from the radio while it is closed; Bluetooth delivers
/// without it.
///
/// - Off (for Cairn or system-wide): a tap opens Cairn's page in the Settings app, where the
///   switch sits.
/// - Restricted (Screen Time or device management): says so, with no tap, since the user cannot
///   change it there.
/// - Low Power Mode: pauses Background App Refresh for every app whatever the switch says, so it
///   is checked before the status and never shown as Off; no tap, since the switch is not what
///   stops it.
///
/// Hidden on a Mac, where the app is not suspended and the setting does not apply.
struct BackgroundRefreshNotice: View {
  enum Kind: Equatable {
    case off
    case restricted
    case lowPowerMode
  }

  /// What to show, nil for nothing. A restriction outranks Low Power Mode: it outlasts it.
  nonisolated static func notice(
    for status: UIBackgroundRefreshStatus,
    isLowPowerMode: Bool,
    isMac: Bool
  ) -> Kind? {
    guard !isMac else { return nil }
    if status == .restricted { return .restricted }
    if isLowPowerMode { return .lowPowerMode }
    switch status {
    case .denied: return .off
    case .available, .restricted: return nil
    @unknown default: return nil
    }
  }

  /// What the shared monitor shows now.
  @MainActor
  static var current: Kind? {
    let monitor = BackgroundRefreshStatusMonitor.shared
    return notice(
      for: monitor.status,
      isLowPowerMode: monitor.isLowPowerMode,
      isMac: ProcessInfo.processInfo.isiOSAppOnMac
    )
  }

  /// Whether the card shows anything now, for a parent that adds it as a list row.
  @MainActor
  static var isShowing: Bool {
    current != nil
  }

  @Environment(\.openURL) private var openURL

  var body: some View {
    switch Self.current {
    case .off:
      ActionCard(
        L10n.Settings.Notifications.BackgroundRefresh.Off.title,
        systemImage: "arrow.clockwise.circle.fill",
        color: .orange,
        subtitle: L10n.Settings.Notifications.BackgroundRefresh.Off.detail
      ) {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          openURL(url)
        }
      }
      .accessibilityHint(L10n.Settings.Notifications.openSettings)
    case .restricted:
      infoCard(
        L10n.Settings.Notifications.BackgroundRefresh.Restricted.title,
        systemImage: "arrow.clockwise.circle.fill",
        color: .orange,
        subtitle: L10n.Settings.Notifications.BackgroundRefresh.Restricted.detail
      )
    case .lowPowerMode:
      infoCard(
        L10n.Settings.Notifications.BackgroundRefresh.LowPower.title,
        systemImage: "battery.25percent",
        color: .yellow,
        subtitle: L10n.Settings.Notifications.BackgroundRefresh.LowPower.detail
      )
    case nil:
      EmptyView()
    }
  }

  /// A card that only informs: nothing the user can tap changes it.
  private func infoCard(_ title: String, systemImage: String, color: Color, subtitle: String) -> some View {
    SettingCardLabel(title, systemImage: systemImage, color: color, subtitle: subtitle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)
      .accessibilityElement(children: .combine)
  }
}

/// `UIApplication.backgroundRefreshStatus` and Low Power Mode, kept current: read at start, again
/// whenever the app becomes active (the user may have changed either in Settings), and on the
/// system's change notifications. One instance for the app, so the notice needs no lifecycle hooks
/// of its own (it may render nothing, and an empty view runs none).
@Observable
@MainActor
final class BackgroundRefreshStatusMonitor {
  static let shared = BackgroundRefreshStatusMonitor()

  private(set) var status: UIBackgroundRefreshStatus
  private(set) var isLowPowerMode: Bool
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  private init() {
    status = UIApplication.shared.backgroundRefreshStatus
    isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let names: [Notification.Name] = [
      UIApplication.backgroundRefreshStatusDidChangeNotification,
      UIApplication.didBecomeActiveNotification,
      // Posted on an arbitrary queue; the observer hops to main.
      .NSProcessInfoPowerStateDidChange,
    ]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refresh()
        }
      })
    }
  }

  func refresh() {
    let current = UIApplication.shared.backgroundRefreshStatus
    if current != status {
      status = current
    }
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    if lowPower != isLowPowerMode {
      isLowPowerMode = lowPower
    }
  }
}
