import Foundation

/// Keeps the car's screen calm: at most one update per interval, a prompt one (within
/// `edgeFloor`) for edge events (the link changing, a scan starting or ending, the result of a
/// tap), and one trailing update so the last change is never lost. Pure over an injected clock reading, so the tests
/// drive it without waiting.
struct CarPlayRefreshGate {
  enum Decision: Equatable {
    /// Apply now, then call `didApply(at:)`.
    case applyNow
    /// Apply once this much time has passed, then call `didApply(at:)`.
    case schedule(after: Duration)
    /// A trailing update is already scheduled and will pick this change up.
    case alreadyScheduled
  }

  /// The pace for data that changes on its own (adverts, battery, unread counts).
  static let dataInterval: Duration = .seconds(10)
  /// The pace while a scan runs: a 15-second scan shows its count two or three times.
  static let scanInterval: Duration = .seconds(5)
  /// The least time between two edge updates, so a flapping link (connecting, connected,
  /// disconnected, again) redraws at most once a second rather than on every step.
  static let edgeFloor: Duration = .seconds(1)

  private(set) var lastApplied: ContinuousClock.Instant?
  private(set) var isTrailingScheduled = false

  mutating func request(
    at now: ContinuousClock.Instant,
    urgent: Bool,
    interval: Duration = Self.dataInterval
  ) -> Decision {
    guard let lastApplied else { return .applyNow }
    let elapsed = now - lastApplied
    if urgent {
      if elapsed >= Self.edgeFloor { return .applyNow }
      // Sooner than any routine trailing update, so the caller replaces whatever is scheduled.
      isTrailingScheduled = true
      return .schedule(after: Self.edgeFloor - elapsed)
    }
    if elapsed >= interval { return .applyNow }
    if isTrailingScheduled { return .alreadyScheduled }
    isTrailingScheduled = true
    return .schedule(after: interval - elapsed)
  }

  /// Records an applied update; any scheduled trailing update it covered is done.
  mutating func didApply(at now: ContinuousClock.Instant) {
    lastApplied = now
    isTrailingScheduled = false
  }
}
