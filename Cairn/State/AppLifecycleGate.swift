import SwiftUI

/// Collapses the lifecycle hooks `CairnApp` attaches to every window into one
/// run per process. Each open window starts its own launch task and observes
/// the same app-level scene phase, so without this the launch sequence would
/// repeat for every additional window and each phase transition would be
/// handled once per open window.
///
/// Mirrors `PendingExternalURL`: a reference type stored as a `let` on `CairnApp`
/// so it outlives the before-first-unlock `AppState` swap.
@MainActor
final class AppLifecycleGate {
  /// How long after a handled transition another window's report of the same
  /// phase counts as the same transition. Reports from one SwiftUI update land
  /// milliseconds apart; the bound keeps a stale record (every window closed,
  /// then one reopened) from swallowing a later, real transition.
  static let duplicateReportWindow: Duration = .seconds(1)

  private var launchTask: Task<Void, Never>?
  private var lastHandled: (phase: ScenePhase, at: ContinuousClock.Instant)?

  /// Runs `launch` for the first caller. Later callers wait for that same run,
  /// so a window opened mid-launch still resumes only once launch has settled.
  /// The run is not tied to the calling window's task, so closing that window
  /// cannot cancel launch for the others.
  func runLaunchOnce(_ launch: @escaping @MainActor () async -> Void) async {
    if let launchTask {
      await launchTask.value
      return
    }
    let task = Task { @MainActor in
      await launch()
    }
    launchTask = task
    await task.value
  }

  /// Whether the caller is the first window to report this transition into
  /// `phase`. Every window reports the same app-level transition; only the
  /// first report may act on it.
  func shouldHandle(_ phase: ScenePhase, at now: ContinuousClock.Instant = .now) -> Bool {
    if let lastHandled, lastHandled.phase == phase,
       now - lastHandled.at < Self.duplicateReportWindow {
      return false
    }
    lastHandled = (phase, now)
    return true
  }
}
