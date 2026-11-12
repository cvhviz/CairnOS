import Foundation

/// Keeps App Nap off the Mac app while a radio link is wanted. A napped app has its timers
/// coalesced and its work deprioritised once its window is hidden or covered, which starves the
/// link's keepalives, write timeouts and reconnect watchdog. iPhone and iPad have no App Nap;
/// there this does nothing.
@MainActor
enum MacRadioActivity {
  private static var token: NSObjectProtocol?

  /// Holds the activity while `isWanted`, releasing it once the user disconnects. Safe to call
  /// from every window: it holds at most one.
  static func update(isWanted: Bool) {
    guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
    if isWanted, token == nil {
      token = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Keeping the radio's Bluetooth link alive"
      )
    } else if !isWanted, let held = token {
      ProcessInfo.processInfo.endActivity(held)
      token = nil
    }
  }
}
