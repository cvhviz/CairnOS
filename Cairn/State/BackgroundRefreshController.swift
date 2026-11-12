import BackgroundTasks
import CairnServices
import UIKit

private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "BackgroundRefresh")

/// Background App Refresh: what puts Cairn in Settings › General › Background App Refresh, and
/// the short runs iOS grants it there.
///
/// Bluetooth keeps delivering in the background on its own (a GATT notification or a pending
/// connect wakes the app). A WiFi socket wakes nothing: once iOS suspends the app, the radio
/// queues messages until the user opens it. With the `fetch` background mode and a
/// `BGAppRefreshTask`, iOS wakes the app now and then (minutes to hours apart, at its own
/// discretion, never after a force-quit or in Low Power Mode) for about 30 seconds. Each run
/// checks in on the radio once (`ConnectionManager.performBackgroundRefresh(deadline:)`): drains
/// a live link, reconnects one that is down, then leaves the link as backgrounding leaves it. It
/// never keeps a socket open and never asks for more time.
///
/// Every run completes its task exactly once: when its work ends, at its own 25 s budget, when
/// iOS's expiration handler fires, or when the app comes to the front. A task left uncompleted
/// gets the app killed and its future refresh budget cut.
@MainActor
final class BackgroundRefreshController {
  /// In both Info.plists' `BGTaskSchedulerPermittedIdentifiers`; registering an identifier
  /// missing there crashes at launch. One identifier for both bundle IDs (Debug's `.dev` too).
  static let taskIdentifier = "cvhvisuals.Cairn.refresh"
  /// The earliest the next run may start. iOS decides the real cadence.
  static let interval: TimeInterval = 15 * 60
  /// The run's own budget, inside the roughly 30 s iOS grants.
  static let softBudget: Duration = .seconds(25)
  /// Kept back from the budget for the log flush and the completion.
  static let finishReserve: Duration = .seconds(2)
  /// Kept back from the budget after waiting for launch: a reconnect needs the rest.
  static let launchReserve: Duration = .seconds(8)

  private let scheduler: any BackgroundTaskScheduling
  private let clock: any Clock<Duration>
  private let isMac: Bool
  private weak var host: (any BackgroundRefreshHost)?
  private var isRegistered = false
  private var hasLoggedNotPermitted = false
  /// The run in flight, nil between runs.
  private(set) var currentRun: Run?

  init(
    scheduler: (any BackgroundTaskScheduling)? = nil,
    clock: (any Clock<Duration>)? = nil,
    isMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac
  ) {
    self.scheduler = scheduler ?? SystemBackgroundTaskScheduler()
    self.clock = clock ?? ContinuousClock()
    self.isMac = isMac
  }

  // MARK: - Registration and scheduling

  /// Registers the launch handler; must run before launch finishes, so the app delegate calls it
  /// from `didFinishLaunching`. Once per process. Skipped on a Mac, where the app is not
  /// suspended and the link carries on as in front.
  func register(host: any BackgroundRefreshHost) {
    guard !isRegistered else { return }
    guard !isMac else {
      logger.info("Not registered: running on a Mac")
      return
    }
    self.host = host
    isRegistered = scheduler.register(id: Self.taskIdentifier) { [weak self] task in
      self?.handle(task: task)
    }
    logger.info(isRegistered ? "Registered" : "Registration refused for \(Self.taskIdentifier)")
  }

  /// Asks for the next run while a refresh could do anything, and withdraws the request
  /// otherwise (a user disconnect, Connect on Launch off with nothing connected, the demo radio).
  /// Called on every entry to the background and after each run.
  ///
  /// Only a launched process decides. Before launch finishes the state it would read is not the
  /// user's: before the first unlock it is the throwaway one (UserDefaults unreadable, so no last
  /// radio), and in a slow launch `activate()` has not set the intent yet. Either reads as "no
  /// connection wanted", and withdrawing then would leave Background App Refresh silently off
  /// until the next foreground. The request already in place (a run submits one as it starts)
  /// stays.
  func schedule(reason: String) {
    guard isRegistered, let host else { return }
    guard host.hasLaunched else {
      logger.info("Kept the request (\(reason)): launch has not finished, so the connection intent is unknown")
      return
    }
    if host.wantsBackgroundRefresh {
      submit(reason: reason)
    } else {
      scheduler.cancel(id: Self.taskIdentifier)
      logger.info("Cancelled (\(reason)): nothing to refresh (no connection wanted, or the demo radio)")
    }
  }

  private func submit(reason: String) {
    let earliest = Date(timeIntervalSinceNow: Self.interval)
    do {
      try scheduler.submit(id: Self.taskIdentifier, earliestBegin: earliest)
      logger.info("Scheduled (\(reason)): earliest in \(Int(Self.interval / 60)) min")
    } catch let error as BGTaskScheduler.Error where error.code == .notPermitted {
      // Background App Refresh is off for Cairn or system-wide; Settings shows why.
      guard !hasLoggedNotPermitted else { return }
      hasLoggedNotPermitted = true
      logger.info("Not scheduled (\(reason)): Background App Refresh is off")
    } catch let error as BGTaskScheduler.Error where error.code == .unavailable {
      logger.debug("Not scheduled (\(reason)): unavailable here (simulator)")
    } catch {
      logger.warning("Not scheduled (\(reason)): \(error.localizedDescription)")
    }
  }

  // MARK: - Runs

  /// A run iOS started. Its task completes exactly once, whichever way the run ends.
  func handle(task: any BackgroundRefreshTaskHandle) {
    currentRun?.finish(outcome: .timedOut, success: false, ending: "superseded")
    let run = Run(task: task, startedAt: ContinuousClock.now) { [weak self] run in
      if self?.currentRun === run {
        self?.currentRun = nil
      }
    }
    currentRun = run

    task.expirationHandler = { [weak run] in
      run?.finish(outcome: .timedOut, success: false, ending: "expired")
    }
    // The next request goes in at once: a run cut short must not leave none behind. The end of
    // the run withdraws it if no connection is wanted by then (launch decides that on a cold
    // start; a launch that did not finish leaves it in place).
    if isRegistered {
      submit(reason: "run started")
    }

    let clock = clock
    run.softTimer = Task { [weak run] in
      try? await clock.sleep(for: Self.softBudget)
      guard !Task.isCancelled else { return }
      run?.finish(outcome: .timedOut, success: false, ending: "soft deadline")
    }
    run.work = Task { [weak self, weak run] in
      guard let self, let run else { return }
      let outcome = await perform(run)
      guard !Task.isCancelled else { return }
      schedule(reason: "run ended")
      run.finish(outcome: outcome, success: outcome.isSuccess, ending: "finished")
    }
  }

  /// The app came to the front (a window or a car's screen): the foreground owns the link from
  /// here. The run stops waiting and completes; a connect it started carries on as any connect.
  func appDidBecomeForeground() {
    currentRun?.finish(outcome: .skipped(.inForeground), success: true, ending: "foreground")
  }

  private func perform(_ run: Run) async -> BackgroundRefreshOutcome {
    guard let host else { return .failed("no host") }
    let warm = host.hasLaunched
    logger.info("Run started: \(warm ? "warm" : "cold") launch, refresh status \(host.backgroundRefreshStatusDescription)")

    if let reason = host.skipReason {
      return .skipped(reason)
    }
    guard await waitForLaunch(host: host, timeout: Self.softBudget - Self.launchReserve) else {
      // Before the first unlock launch waits for protected data and never returns in time.
      return .failed("launch did not finish (protected data unavailable?)")
    }
    guard !Task.isCancelled else { return .timedOut }
    // Launch may have taken a while; the user may have opened the app meanwhile.
    if let reason = host.skipReason {
      return .skipped(reason)
    }

    let deadline = run.startedAt + Self.softBudget - Self.finishReserve
    let outcome = await host.performBackgroundRefresh(deadline: deadline)
    await host.flushLogsNow()
    return outcome
  }

  /// Waits for the launch sequence, at most `timeout`. Launch runs on in its own task either
  /// way: it is the process's, not the run's.
  private func waitForLaunch(host: any BackgroundRefreshHost, timeout: Duration) async -> Bool {
    if host.hasLaunched { return true }
    let first = FirstResult()
    Task {
      await host.launchOnce()
      // launch can return without finishing: the store would not open (its recovery screen is up)
      first.resolve(host.hasLaunched)
    }
    let clock = clock
    let timer = Task {
      try? await clock.sleep(for: timeout)
      first.resolve(false)
    }
    let launched = await withTaskCancellationHandler {
      await first.value()
    } onCancel: {
      Task { @MainActor in first.resolve(false) }
    }
    timer.cancel()
    return launched
  }

  /// One run: its task, the timers and work that end it, and the once-only completion.
  @MainActor
  final class Run {
    private let task: any BackgroundRefreshTaskHandle
    let startedAt: ContinuousClock.Instant
    private let onFinish: (Run) -> Void
    var softTimer: Task<Void, Never>?
    var work: Task<Void, Never>?
    private(set) var isFinished = false

    init(
      task: any BackgroundRefreshTaskHandle,
      startedAt: ContinuousClock.Instant,
      onFinish: @escaping (Run) -> Void
    ) {
      self.task = task
      self.startedAt = startedAt
      self.onFinish = onFinish
    }

    /// Cancels what is still running and completes the task, the first time only.
    func finish(outcome: BackgroundRefreshOutcome, success: Bool, ending: String) {
      guard !isFinished else { return }
      isFinished = true
      softTimer?.cancel()
      work?.cancel()
      task.expirationHandler = nil
      task.setTaskCompleted(success: success)
      let elapsed = ContinuousClock.now - startedAt
      logger.info(
        "Run ended (\(ending)): \(outcome.summary), success \(success), " +
          "\(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))"
      )
      onFinish(self)
    }
  }
}

/// The first of several racing results, delivered once.
@MainActor
private final class FirstResult {
  private var result: Bool?
  private var continuation: CheckedContinuation<Bool, Never>?

  func resolve(_ value: Bool) {
    guard result == nil else { return }
    result = value
    continuation?.resume(returning: value)
    continuation = nil
  }

  func value() async -> Bool {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }
}

// MARK: - Seams

/// What a run needs from the app. `AppLaunchController` in the app; a fake in tests.
@MainActor
protocol BackgroundRefreshHost: AnyObject {
  /// Whether the launch sequence has finished.
  var hasLaunched: Bool { get }
  /// Runs (or joins) the launch sequence.
  func launchOnce() async
  /// Why a run should not touch the link right now, nil when it may.
  var skipReason: BackgroundRefreshSkipReason? { get }
  /// The connection manager's ``ConnectionManager/wantsBackgroundRefresh``.
  var wantsBackgroundRefresh: Bool { get }
  /// `UIApplication.backgroundRefreshStatus` and Low Power Mode, for the log.
  var backgroundRefreshStatusDescription: String { get }
  func performBackgroundRefresh(deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome
  /// Writes the buffered logs, awaited.
  func flushLogsNow() async
}

/// `BGTaskScheduler`, behind a seam for tests.
@MainActor
protocol BackgroundTaskScheduling: AnyObject {
  /// Registers the launch handler, delivered on the main actor. Returns whether iOS accepted it.
  func register(id: String, handler: @escaping @MainActor (any BackgroundRefreshTaskHandle) -> Void) -> Bool
  func submit(id: String, earliestBegin: Date) throws
  func cancel(id: String)
}

/// A `BGAppRefreshTask`, behind a seam for tests.
@MainActor
protocol BackgroundRefreshTaskHandle: AnyObject {
  /// Called on the main actor when iOS reclaims the run's time.
  var expirationHandler: (@MainActor () -> Void)? { get set }
  func setTaskCompleted(success: Bool)
}

@MainActor
private final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
  func register(id: String, handler: @escaping @MainActor (any BackgroundRefreshTaskHandle) -> Void) -> Bool {
    // `using: .main`: the launch handler runs on the main queue, so on the main actor.
    BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
      MainActor.assumeIsolated {
        handler(SystemRefreshTask(task: task))
      }
    }
  }

  func submit(id: String, earliestBegin: Date) throws {
    let request = BGAppRefreshTaskRequest(identifier: id)
    request.earliestBeginDate = earliestBegin
    try BGTaskScheduler.shared.submit(request)
  }

  func cancel(id: String) {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
  }
}

@MainActor
private final class SystemRefreshTask: BackgroundRefreshTaskHandle {
  private let task: BGTask

  init(task: BGTask) {
    self.task = task
  }

  var expirationHandler: (@MainActor () -> Void)? {
    didSet {
      guard let handler = expirationHandler else {
        task.expirationHandler = nil
        return
      }
      // iOS may call the expiration handler off the main queue.
      task.expirationHandler = {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { handler() }
        }
      }
    }
  }

  func setTaskCompleted(success: Bool) {
    task.setTaskCompleted(success: success)
  }
}

// MARK: - App host

extension AppLaunchController: BackgroundRefreshHost {
  var skipReason: BackgroundRefreshSkipReason? {
    if ProcessInfo.processInfo.isiOSAppOnMac { return .onMac }
    // In front (a window, or a car's screen while the phone is locked): the foreground owns the link.
    if UIApplication.shared.applicationState != .background || isCarPlayConnected { return .inForeground }
    if DemoModeManager.shared.isEnabled { return .demoMode }
    #if DEBUG
      if ProcessInfo.processInfo.isScreenshotMode { return .screenshotMode }
    #endif
    return nil
  }

  var wantsBackgroundRefresh: Bool {
    appState.connectionManager.wantsBackgroundRefresh
  }

  var backgroundRefreshStatusDescription: String {
    let status = switch UIApplication.shared.backgroundRefreshStatus {
    case .available: "available"
    case .denied: "denied"
    case .restricted: "restricted"
    @unknown default: "unknown"
    }
    return ProcessInfo.processInfo.isLowPowerModeEnabled ? "\(status), Low Power Mode" : status
  }

  func performBackgroundRefresh(deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome {
    // Read fresh: launch replaces the state once on the before-first-unlock path.
    // Only the link to this phone's own radio: nothing goes out over the mesh from the background
    // (a background check on repeaters, logging in and asking each for its status, cost airtime
    // on every run and was removed 2026-11-09).
    return await appState.connectionManager.performBackgroundRefresh(deadline: deadline)
  }
}
