import Foundation
@testable import Cairn
@testable import CairnServices
import Testing
import UIKit

/// Background App Refresh runs: registered once (never on a Mac), scheduled only while a
/// connection is wanted, rescheduled as each run starts, and every run's task completed exactly
/// once, whichever way it ends: its work finishing, its own 25 s budget, iOS's expiration, or
/// the app coming to the front.
@Suite("Background refresh controller")
@MainActor
struct BackgroundRefreshControllerTests {
  private struct Harness {
    let controller: BackgroundRefreshController
    let scheduler: FakeScheduler
    let host: FakeHost
    let clock: TestClock
  }

  private func makeHarness(isMac: Bool = false, register: Bool = true) -> Harness {
    let scheduler = FakeScheduler()
    let clock = TestClock()
    let controller = BackgroundRefreshController(scheduler: scheduler, clock: clock, isMac: isMac)
    let host = FakeHost()
    if register {
      controller.register(host: host)
    }
    return Harness(controller: controller, scheduler: scheduler, host: host, clock: clock)
  }

  private func waitForCompletion(_ task: FakeTask) async throws {
    try await waitUntil("the run's task should complete") { !task.completions.isEmpty }
  }

  // MARK: Registration and scheduling

  @Test
  func `registers once`() {
    let harness = makeHarness()
    harness.controller.register(host: harness.host)

    #expect(harness.scheduler.registeredIDs == [BackgroundRefreshController.taskIdentifier])
  }

  @Test
  func `nothing is registered or scheduled on a Mac`() {
    let harness = makeHarness(isMac: true)
    harness.controller.schedule(reason: "test")

    #expect(harness.scheduler.registeredIDs.isEmpty)
    #expect(harness.scheduler.submits.isEmpty)
    #expect(harness.scheduler.cancelCount == 0)
  }

  @Test
  func `schedules while a connection is wanted and withdraws the request otherwise`() {
    let harness = makeHarness()

    harness.controller.schedule(reason: "test")
    #expect(harness.scheduler.submits.count == 1)
    let earliest = harness.scheduler.submits.first ?? .distantPast
    #expect(earliest.timeIntervalSinceNow > BackgroundRefreshController.interval - 60)

    harness.host.wantsBackgroundRefresh = false
    harness.controller.schedule(reason: "test")
    #expect(harness.scheduler.submits.count == 1)
    #expect(harness.scheduler.cancelCount == 1)
  }

  @Test
  func `before launch finishes the request is kept, whatever the unready state says`() {
    let harness = makeHarness()
    // Before the first unlock (or early in a slow launch) the state reads as "nothing wanted".
    harness.host.hasLaunched = false
    harness.host.wantsBackgroundRefresh = false

    harness.controller.schedule(reason: "entered background")

    #expect(harness.scheduler.cancelCount == 0)
    #expect(harness.scheduler.submits.isEmpty)
  }

  @Test
  func `a submit refused by iOS does not throw out of scheduling`() {
    let harness = makeHarness()
    harness.scheduler.submitError = BGTaskSchedulerErrorStub.notPermitted

    harness.controller.schedule(reason: "test")
    harness.controller.schedule(reason: "test")

    #expect(harness.scheduler.submitAttempts == 2)
  }

  // MARK: Runs

  @Test
  func `a run reschedules as it starts and completes once when its work ends`() async throws {
    let harness = makeHarness()
    harness.host.outcome = .drained(count: 2)
    let task = FakeTask()

    harness.scheduler.launch(task)
    #expect(harness.scheduler.submits.count == 1, "the next request goes in before any work")

    try await waitForCompletion(task)
    #expect(task.completions == [true])
    #expect(harness.host.performCalls == 1)
    #expect(harness.host.flushCalls == 1)
    #expect(harness.scheduler.submits.count == 2, "rescheduled at the end while still wanted")
    #expect(task.expirationHandler == nil)
    #expect(harness.controller.currentRun == nil)
  }

  @Test
  func `the deadline handed to the connection manager leaves the finish reserve`() async throws {
    let harness = makeHarness()
    let task = FakeTask()
    let before = ContinuousClock.now

    harness.scheduler.launch(task)
    try await waitForCompletion(task)

    let deadline = try #require(harness.host.lastDeadline)
    let budget = BackgroundRefreshController.softBudget - BackgroundRefreshController.finishReserve
    // Measured from the run's start, a moment after `before`.
    #expect(deadline - before >= budget)
    #expect(deadline - before < budget + .seconds(1))
  }

  @Test
  func `a run that ends without a wanted connection withdraws the next request`() async throws {
    let harness = makeHarness()
    harness.host.outcome = .skipped(.notWanted)
    harness.host.wantsBackgroundRefresh = false
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitForCompletion(task)

    #expect(task.completions == [true])
    #expect(harness.scheduler.submits.count == 1, "only the request made as the run started")
    #expect(harness.scheduler.cancelCount == 1)
  }

  @Test
  func `the soft deadline completes the run once, as a failure`() async throws {
    let harness = makeHarness()
    harness.host.hangsUntilCancelled = true
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitUntil("the soft timer should park on the clock") { harness.clock.sleeperCount == 1 }
    try await waitUntil("the work should be running") { harness.host.performCalls == 1 }
    harness.clock.advance(by: BackgroundRefreshController.softBudget)

    try await waitForCompletion(task)
    try await waitUntil("the cancelled work should return") { harness.host.performReturned }
    #expect(task.completions == [false])
    #expect(harness.scheduler.submits.count == 1, "the request made at the start stands")
  }

  @Test
  func `expiration completes the run once and cancels its work`() async throws {
    let harness = makeHarness()
    harness.host.hangsUntilCancelled = true
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitUntil("the work should be running") { harness.host.performCalls == 1 }
    let expire = try #require(task.expirationHandler)
    expire()
    expire()

    #expect(task.completions == [false])
    try await waitUntil("the cancelled work should return") { harness.host.performReturned }
    harness.controller.appDidBecomeForeground()
    #expect(task.completions == [false])
  }

  @Test
  func `coming to the front mid-run completes it once`() async throws {
    let harness = makeHarness()
    harness.host.hangsUntilCancelled = true
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitUntil("the work should be running") { harness.host.performCalls == 1 }
    harness.controller.appDidBecomeForeground()

    #expect(task.completions == [true])
    try await waitUntil("the cancelled work should return") { harness.host.performReturned }
    harness.clock.advance(by: BackgroundRefreshController.softBudget)
    try await Task.sleep(for: .milliseconds(50))
    #expect(task.completions == [true])
  }

  @Test(arguments: [BackgroundRefreshSkipReason.inForeground, .demoMode, .screenshotMode])
  func `the app in front, demo mode, and screenshot mode skip the run`(reason: BackgroundRefreshSkipReason) async throws {
    let harness = makeHarness()
    harness.host.skipReason = reason
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitForCompletion(task)

    #expect(task.completions == [true])
    #expect(harness.host.performCalls == 0, "the link is never touched")
  }

  @Test
  func `a cold run waits for launch first`() async throws {
    let harness = makeHarness()
    harness.host.hasLaunched = false
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitUntil("the run should wait on launch") { harness.host.launchCalls == 1 }
    #expect(harness.host.performCalls == 0)
    harness.host.finishLaunch()

    try await waitForCompletion(task)
    #expect(task.completions == [true])
    #expect(harness.host.performCalls == 1)
  }

  @Test
  func `a launch that does not finish in time fails the run`() async throws {
    let harness = makeHarness()
    harness.host.hasLaunched = false
    let task = FakeTask()

    harness.scheduler.launch(task)
    // The soft timer and the launch wait's own timer.
    try await waitUntil("both timers should park on the clock") { harness.clock.sleeperCount == 2 }
    harness.clock.advance(by: BackgroundRefreshController.softBudget - BackgroundRefreshController.launchReserve)

    try await waitForCompletion(task)
    #expect(task.completions == [false])
    #expect(harness.host.performCalls == 0)
  }

  @Test
  func `a launch that does not finish in time leaves the next request in place`() async throws {
    let harness = makeHarness()
    // Before the first unlock: the throwaway state has no last radio, so it wants nothing.
    harness.host.hasLaunched = false
    harness.host.wantsBackgroundRefresh = false
    let task = FakeTask()

    harness.scheduler.launch(task)
    try await waitUntil("both timers should park on the clock") { harness.clock.sleeperCount == 2 }
    harness.clock.advance(by: BackgroundRefreshController.softBudget - BackgroundRefreshController.launchReserve)

    try await waitForCompletion(task)
    #expect(task.completions == [false])
    #expect(harness.scheduler.submits.count == 1, "the request made as the run started")
    #expect(harness.scheduler.cancelCount == 0, "an unfinished launch never withdraws it")
  }
}

// MARK: - Notice

@Suite("Background refresh notice")
struct BackgroundRefreshNoticeTests {
  private func notice(_ status: UIBackgroundRefreshStatus, lowPower: Bool = false, isMac: Bool = false) -> BackgroundRefreshNotice.Kind? {
    BackgroundRefreshNotice.notice(for: status, isLowPowerMode: lowPower, isMac: isMac)
  }

  @Test
  func `shown only when Background App Refresh is off or restricted, never on a Mac`() {
    #expect(notice(.available) == nil)
    #expect(notice(.denied) == .off)
    #expect(notice(.restricted) == .restricted)
    #expect(notice(.denied, isMac: true) == nil)
    #expect(notice(.restricted, isMac: true) == nil)
  }

  @Test
  func `Low Power Mode is said as such, never as Off, and a restriction outranks it`() {
    #expect(notice(.available, lowPower: true) == .lowPowerMode)
    #expect(notice(.denied, lowPower: true) == .lowPowerMode, "the per-app switch may well be on")
    #expect(notice(.restricted, lowPower: true) == .restricted)
    #expect(notice(.denied, lowPower: true, isMac: true) == nil)
  }

  @Test
  func `the notice's strings resolve`() {
    for string in [
      L10n.Settings.Notifications.BackgroundRefresh.Off.title,
      L10n.Settings.Notifications.BackgroundRefresh.Off.detail,
      L10n.Settings.Notifications.BackgroundRefresh.Restricted.title,
      L10n.Settings.Notifications.BackgroundRefresh.Restricted.detail,
      L10n.Settings.Notifications.BackgroundRefresh.LowPower.title,
      L10n.Settings.Notifications.BackgroundRefresh.LowPower.detail,
      L10n.Settings.Connections.WifiBackground.footer,
    ] {
      #expect(!string.isEmpty)
      #expect(!string.hasPrefix("notifications."), "the key resolves to a string")
      #expect(!string.hasPrefix("connections."), "the key resolves to a string")
    }
  }
}

// MARK: - Test doubles

private enum BGTaskSchedulerErrorStub: Error {
  case notPermitted
}

@MainActor
private final class FakeScheduler: BackgroundTaskScheduling {
  private(set) var registeredIDs: [String] = []
  private var handler: (@MainActor (any BackgroundRefreshTaskHandle) -> Void)?
  private(set) var submits: [Date] = []
  private(set) var submitAttempts = 0
  private(set) var cancelCount = 0
  var submitError: Error?

  func register(id: String, handler: @escaping @MainActor (any BackgroundRefreshTaskHandle) -> Void) -> Bool {
    registeredIDs.append(id)
    self.handler = handler
    return true
  }

  func submit(id: String, earliestBegin: Date) throws {
    submitAttempts += 1
    if let submitError { throw submitError }
    submits.append(earliestBegin)
  }

  func cancel(id: String) {
    cancelCount += 1
  }

  /// iOS starting a run.
  func launch(_ task: FakeTask) {
    handler?(task)
  }
}

@MainActor
private final class FakeTask: BackgroundRefreshTaskHandle {
  var expirationHandler: (@MainActor () -> Void)?
  private(set) var completions: [Bool] = []

  func setTaskCompleted(success: Bool) {
    completions.append(success)
  }
}

@MainActor
private final class FakeHost: BackgroundRefreshHost {
  var hasLaunched = true
  var skipReason: BackgroundRefreshSkipReason?
  var wantsBackgroundRefresh = true
  var backgroundRefreshStatusDescription = "available"
  var outcome: BackgroundRefreshOutcome = .drained(count: 0)
  var hangsUntilCancelled = false
  private(set) var performCalls = 0
  private(set) var performReturned = false
  private(set) var flushCalls = 0
  private(set) var launchCalls = 0
  private(set) var lastDeadline: ContinuousClock.Instant?
  private var launchWaiters: [CheckedContinuation<Void, Never>] = []

  func launchOnce() async {
    launchCalls += 1
    if hasLaunched { return }
    await withCheckedContinuation { launchWaiters.append($0) }
  }

  func finishLaunch() {
    hasLaunched = true
    let waiters = launchWaiters
    launchWaiters = []
    waiters.forEach { $0.resume() }
  }

  func performBackgroundRefresh(deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome {
    performCalls += 1
    lastDeadline = deadline
    defer { performReturned = true }
    if hangsUntilCancelled {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(5))
      }
      return .timedOut
    }
    return outcome
  }

  func flushLogsNow() async {
    flushCalls += 1
  }
}
