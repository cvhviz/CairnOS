import Foundation

/// Keeps background WiFi attempts from asking a radio the same question over and over.
///
/// A radio that has not seen this phone before (an L2 after a reboot, with no "Always allow" for
/// its MAC) holds a new app connection in quarantine: TCP is accepted, the app gets no frames,
/// and the radio lights its screen to ask whether to allow it. Nobody is there to answer while
/// the app runs in the background, and every reconnect attempt (the reconnect loop, launch, a
/// Background App Refresh run) would light the screen again. The app gets no explicit "awaiting
/// approval" or "refused" signal, only a handshake that times out or a socket the radio closes
/// (`ConnectionManager.isRadioApprovalSignature(transportConnected:error:)`).
///
/// So one unanswered background attempt blocks that endpoint for background attempts until the
/// user is back: a return to the foreground (where an attempt may ask and be answered) or any
/// successful handshake clears it. The same signature also fits a trusted radio that was briefly
/// busy or rebooting, so the block lapses after ``retryInterval``: one background attempt goes
/// through then, and a radio still asking blocks it again. One question every few hours is not a
/// storm, and a phone the radio already trusts gets its background delivery back without the
/// user. The block persists so a background relaunch respects it too.
struct BackgroundWiFiApprovalGate {
  /// How long a recorded endpoint stays blocked for background attempts.
  static let retryInterval: TimeInterval = 3 * 60 * 60

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// The endpoint as stored: `host:port`.
  static func key(host: String, port: UInt16) -> String {
    "\(host):\(port)"
  }

  /// Each recorded endpoint and when it was recorded (seconds since 1970).
  private var recorded: [String: Double] {
    defaults.dictionary(forKey: PersistenceKeys.backgroundWiFiAwaitingApproval) as? [String: Double] ?? [:]
  }

  /// Whether a background attempt to `endpoint` should wait for the user.
  func isBlocked(endpoint: String, now: Date = Date()) -> Bool {
    guard let recordedAt = recorded[endpoint] else { return false }
    return now.timeIntervalSince1970 - recordedAt < Self.retryInterval
  }

  /// Whether anything is recorded, lapsed or not; lets the clear paths skip the defaults write.
  var hasBlockedEndpoints: Bool {
    !recorded.isEmpty
  }

  /// Records a background attempt to `endpoint` the radio did not answer, restarting its block.
  func recordUnanswered(endpoint: String, now: Date = Date()) {
    var endpoints = recorded
    endpoints[endpoint] = now.timeIntervalSince1970
    defaults.set(endpoints, forKey: PersistenceKeys.backgroundWiFiAwaitingApproval)
  }

  /// Lifts every block: the user is present, or a radio answered.
  func clear() {
    guard hasBlockedEndpoints else { return }
    defaults.removeObject(forKey: PersistenceKeys.backgroundWiFiAwaitingApproval)
  }
}
