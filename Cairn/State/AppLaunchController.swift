import CairnServices
import os
import SwiftData
import TipKit
import UIKit

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "AppLaunchController")

/// Owns the app's `AppState` and the once-per-process launch work, outside the SwiftUI `App`
/// struct so scenes SwiftUI does not create can reach them. The CarPlay scene and the Siri intent
/// handlers are instantiated by UIKit from a class name, and the app can launch with only the
/// CarPlay screen showing: no window, so no window `.task` to run launch from. Both read the one
/// instance through `current`, which `CairnApp.init` sets before any scene connects.
@Observable
@MainActor
final class AppLaunchController {
  /// The process's controller, registered by `CairnApp.init`.
  static var current: AppLaunchController?

  /// The live state. Replaced once on the before-first-unlock path, when the real store opens.
  private(set) var appState: AppState
  /// The real store is not open yet (before first unlock, or it failed to open): `appState` is a
  /// placeholder on an in-memory container until the launch sequence swaps the real one in.
  private(set) var awaitingStore = false
  /// Why the store could not be opened, once the retries are spent. While set, the windows show
  /// `StoreUnavailableView` in place of the app, which would otherwise run on the empty
  /// placeholder and look as if everything had been erased.
  private(set) var storeFailure: String?
  /// A retry under way; later callers join it.
  private var storeRetryTask: Task<Void, Never>?
  var isRetryingStore: Bool { storeRetryTask != nil }
  /// Set when the launch sequence has finished, so a scene arriving later knows it only needs a
  /// foreground reconciliation, not a launch.
  private(set) var hasLaunched = false

  /// Stable holder that App Intents read through `AppDependencyManager`. It
  /// must outlive the before-first-unlock `AppState` swap.
  @ObservationIgnored let intentBridge = IntentBridge()

  /// Stages externally opened URLs across launch; see `PendingExternalURL`.
  @ObservationIgnored let pendingExternalURL = PendingExternalURL()

  /// Runs the per-scene lifecycle hooks once per process; see `AppLifecycleGate`.
  @ObservationIgnored let lifecycleGate = AppLifecycleGate()

  /// App-lifetime notification delegate; see `NotificationResponseRelay`.
  @ObservationIgnored let notificationRelay = NotificationResponseRelay()

  /// Set while a car's screen shows the app. SwiftUI's `scenePhase` only follows the phone's
  /// windows, so without this, locking the phone mid-drive would put the radio link, battery
  /// polling and keepalives into background mode while the car still shows them.
  @ObservationIgnored private(set) var isCarPlayConnected = false

  /// Set when a scene became active before launch finished. Launch reconciles once at its end,
  /// and the application state may read inactive by then.
  @ObservationIgnored private var foregroundRequestedDuringLaunch = false

  /// Held while a WiFi connect or sync carries on after the app left the foreground.
  @ObservationIgnored private var wifiBackgroundTask: BackgroundTaskAssertion?

  /// Background App Refresh: registered by the app delegate, scheduled on every entry to the
  /// background. Reads `appState` fresh for each run, so it outlives the before-first-unlock swap.
  @ObservationIgnored let backgroundRefresh = BackgroundRefreshController()

  init() {
    // The response that launched the app is only delivered to a delegate
    // installed before launch finishes.
    notificationRelay.install()

    do {
      let container = try Self.openStore()
      appState = AppState(modelContainer: container)
      intentBridge.adopt(appState)
      notificationRelay.adopt(appState)
      return
    } catch {
      logger.error("Store did not open at launch: \(Self.describe(error), privacy: .public)")
    }

    // The store did not open. Before first unlock that is expected (the encrypted files cannot be
    // read yet); otherwise it is a failure to recover from, never one to crash on. Either way
    // launch proceeds on a throwaway in-memory container, and the launch sequence opens the real
    // store (waiting for the unlock, retrying) and swaps it in before doing any work. Which of
    // the two it is, is decided there: `UIApplication` is not ready to say this early.
    let throwaway: ModelContainer
    do {
      throwaway = try PersistenceStore.createContainer(inMemory: true)
    } catch {
      fatalError("In-memory ModelContainer creation failed: \(error)")
    }
    // Adoption is deferred to the swap, so an intent that runs meanwhile reads nil, not an
    // empty store.
    appState = AppState(modelContainer: throwaway)
    awaitingStore = true
  }

  /// The real store, in the app's own container; a copy an earlier build left in the App Group
  /// container is moved over first (`StoreRelocation`).
  private static func openStore() throws -> ModelContainer {
    try PersistenceStore.createContainer(legacyAppGroupID: WidgetSnapshotStore.appGroupID)
  }

  private static func describe(_ error: any Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
  }

  /// Runs the launch sequence for the first caller; later callers wait for that same run.
  func launchOnce() async {
    // The gate runs launch once; a run that ended with the store still closed is not repeated by
    // it, so whoever asks for launch afterwards (a window, the car, Siri, a background refresh)
    // tries the store again instead. Read before the gate, so the run that just failed does not
    // retry on its own heels.
    let failedEarlier = awaitingStore && storeFailure != nil
    await lifecycleGate.runLaunchOnce { [self] in
      await runLaunchSequence()
    }
    if failedEarlier { await retryOpeningStore() }
  }

  /// Launch work every scene asks for; `lifecycleGate` runs it once.
  private func runLaunchSequence() async {
    if awaitingStore {
      // Still closed after the retries: `storeFailure` puts the recovery screen up, and its Try
      // Again resumes launch from here (`retryOpeningStore()`).
      guard await openStoreWithRetries() else { return }
    }
    await finishLaunch()
  }

  /// Opens the real store and swaps it in for the placeholder. Waits out the time before first
  /// unlock without counting it; a failure with the data readable is retried a few times, then
  /// reported through `storeFailure`. false = still closed.
  private func openStoreWithRetries() async -> Bool {
    var lastError: (any Error)?
    var failures = 0
    while failures <= Self.storeRetryDelays.count {
      do {
        let container = try Self.openStore()
        let realAppState = AppState(modelContainer: container)
        appState = realAppState
        // First real store on this path; the bridge was left nil in `init()` until now.
        intentBridge.adopt(realAppState)
        notificationRelay.adopt(realAppState)
        awaitingStore = false
        storeFailure = nil
        return true
      } catch {
        lastError = error
        guard UIApplication.shared.isProtectedDataAvailable else {
          logger.warning("Protected data unavailable (before first unlock), waiting to open the store")
          await waitForProtectedData()
          continue
        }
        logger.error("Store did not open (attempt \(failures + 1)): \(Self.describe(error), privacy: .public)")
        if failures < Self.storeRetryDelays.count {
          try? await Task.sleep(for: Self.storeRetryDelays[failures])
        }
        failures += 1
      }
    }
    let description = lastError.map(Self.describe) ?? "unknown"
    logger.fault("Store did not open after retries: \(description, privacy: .public)")
    storeFailure = description
    return false
  }

  /// Waits between attempts to open the store while the data is readable.
  private static let storeRetryDelays: [Duration] = [.milliseconds(300), .seconds(1), .seconds(2)]

  /// The recovery screen's Try Again: opens the store and, once it is open, runs the rest of
  /// launch that the first attempt never reached.
  func retryOpeningStore() async {
    if let storeRetryTask {
      await storeRetryTask.value
      return
    }
    guard awaitingStore, storeFailure != nil else { return }
    let task = Task { [self] in
      guard await openStoreWithRetries() else { return }
      await finishLaunch()
    }
    storeRetryTask = task
    await task.value
    storeRetryTask = nil
  }

  /// Everything after the store is open.
  private func finishLaunch() async {
    try? Tips.configure([
      .displayFrequency(.immediate)
    ])

    #if DEBUG
      if ProcessInfo.processInfo.isScreenshotMode {
        await setupScreenshotMode()
      } else {
        await appState.initialize()
      }
    #else
      await appState.initialize()
    #endif

    // `initialize()` awaits only the wiring (the reconnect to the last radio runs on its own),
    // so taps, links, and CarPlay are released as soon as the store and the UI are ready,
    // not after a connect and initial sync that can take a minute.
    pendingExternalURL.markReady(appState)
    await notificationRelay.markReady()
    hasLaunched = true
    await runInitialForegroundReconciliationIfNeeded()
  }

  #if DEBUG && targetEnvironment(simulator)
    /// Sets up the app for App Store screenshot capture.
    /// Bypasses onboarding and auto-connects to simulator with mock data.
    private func setupScreenshotMode() async {
      // Bypass onboarding
      appState.onboarding.hasCompletedOnboarding = true
      // Screenshots need the mock radio connected, whatever Connect on Launch was left at.
      UserDefaults.standard.removeObject(forKey: AppStorageKey.connectOnLaunch.rawValue)

      // Persist simulator device ID for auto-reconnect
      UserDefaults.standard.set(
        MockDataProvider.simulatorDeviceID.uuidString,
        forKey: PersistenceKeys.lastConnectedDeviceID
      )

      // Initialize app (will auto-connect to simulator device)
      await appState.initialize()
    }

  #elseif DEBUG
    private func setupScreenshotMode() async {
      // Screenshot mode only works in simulator
      await appState.initialize()
    }
  #endif

  /// Waits for the first unlock. Subscribes before checking, so an unlock landing
  /// between the check and the wait can't be missed, then relies on the system
  /// notification instead of polling every second while locked.
  private func waitForProtectedData() async {
    let notifications = NotificationCenter.default.notifications(
      named: UIApplication.protectedDataDidBecomeAvailableNotification
    )
    let iterator = notifications.makeAsyncIterator()
    guard !UIApplication.shared.isProtectedDataAvailable else { return }
    _ = await iterator.next()
  }

  // MARK: - Scenes

  /// Whether one of the phone's own windows is on screen; the CarPlay scene is not a window.
  var hasForegroundWindowScene: Bool {
    UIApplication.shared.connectedScenes.contains { scene in
      scene is UIWindowScene
        && (scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
    }
  }

  /// The app-wide background work: stop foreground-only polling and flush logs. Runs when the
  /// phone's windows go to the background with no car connected, or when the car disconnects
  /// with no window on screen.
  func enterBackground() {
    // On the placeholder there is no radio work to put in the background, and starting any would
    // create a Bluetooth central that the real one then has to share its restore identifier with.
    guard !awaitingStore else {
      flushLogs()
      backgroundRefresh.schedule(reason: "entered background")
      return
    }
    appState.handleEnterBackground()
    holdWiFiWorkThroughBackground()
    flushLogs()
    backgroundRefresh.schedule(reason: "entered background")
  }

  /// Flushes the shared buffer, not services?.debugLogBuffer: while disconnected (a failing
  /// reconnect is exactly that window) services is nil, and unflushed entries die with the
  /// process if iOS terminates the suspended app. Runs under a background task, since it starts
  /// as the app leaves the foreground and a suspension mid-write would lose the entries.
  ///
  /// The RX log batches its saves (up to a second) and the neighbour table writes its changed
  /// rows every few seconds; both are written first. Stock firmware resends nothing after a
  /// relaunch, so what they hold would otherwise be lost.
  func flushLogs() {
    let backgroundTask = BackgroundTaskAssertion(name: "Flush logs")
    Task {
      defer { backgroundTask.end() }
      await flushLogsNow()
    }
  }

  /// The flush itself, awaited: a Background App Refresh run writes what it logged before it
  /// completes, within the time it already has.
  func flushLogsNow() async {
    let appState = appState
    await DebugLogBuffer.shared?.flush()
    if let services = appState.services {
      await services.rxLogService.flushPendingEntries()
      await services.neighbourService.flush()
    }
    try? await appState.connectionManager.persistenceStore.flushPendingRxLogEntries()
  }

  /// Bluetooth events wake a suspended app; a WiFi socket gets nothing of the kind, and a
  /// suspension stops it mid-exchange. While a WiFi connect, reconnect, or sync is still under
  /// way, keep running until it settles or iOS reclaims the time.
  private func holdWiFiWorkThroughBackground() {
    let manager = appState.connectionManager
    guard manager.hasWiFiWorkInFlight else { return }
    wifiBackgroundTask?.end()
    let backgroundTask = BackgroundTaskAssertion(name: "Finish WiFi sync")
    wifiBackgroundTask = backgroundTask
    logger.info("Holding a background task while WiFi work finishes")
    Task { [weak self] in
      defer {
        backgroundTask.end()
        if self?.wifiBackgroundTask === backgroundTask {
          self?.wifiBackgroundTask = nil
        }
      }
      while backgroundTask.isActive, manager.hasWiFiWorkInFlight {
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  /// Creates the Bluetooth central as the process launches, ahead of the launch sequence, so a
  /// relaunch for Bluetooth state restoration finds a central to restore into. Skipped before
  /// first unlock: that `AppState` is a placeholder replaced once the store opens, and a central
  /// created on it would claim the restore identifier a second central needs.
  func prepareBluetoothCentral() {
    guard !awaitingStore else { return }
    let manager = appState.connectionManager
    Task {
      await manager.prepareBluetoothCentral()
    }
  }

  /// A scene became active. Launch already reconciles once at its end, so until it has finished
  /// the request is only noted; afterwards it runs the foreground reconciliation.
  func returnToForeground() {
    wifiBackgroundTask?.end()
    wifiBackgroundTask = nil
    backgroundRefresh.appDidBecomeForeground()
    guard hasLaunched else {
      foregroundRequestedDuringLaunch = true
      // back in front with the store still closed: another try, without waiting for the button
      if awaitingStore, storeFailure != nil {
        Task { await retryOpeningStore() }
      }
      return
    }
    let appState = appState
    Task {
      await appState.handleReturnToForeground()
    }
  }

  func carPlayDidConnect() {
    isCarPlayConnected = true
    wifiBackgroundTask?.end()
    wifiBackgroundTask = nil
    backgroundRefresh.appDidBecomeForeground()
  }

  /// The car is gone; if no phone window is showing either, the app is now in the background
  /// and nothing else will say so (the windows already reported their own change earlier).
  func carPlayDidDisconnect() {
    isCarPlayConnected = false
    guard hasLaunched, !hasForegroundWindowScene else { return }
    enterBackground()
  }

  /// A scene that was already active when launch began never reports a phase change, so
  /// launch reconciles once itself. The application state covers every scene, the CarPlay
  /// screen included, where SwiftUI's `scenePhase` only knows about its windows. A scene that
  /// reported `.active` while launch ran was held off (see `returnToForeground()`) and is
  /// served here too.
  private func runInitialForegroundReconciliationIfNeeded() async {
    let requested = foregroundRequestedDuringLaunch
    foregroundRequestedDuringLaunch = false
    guard requested || UIApplication.shared.applicationState == .active else { return }
    await appState.handleReturnToForeground()
  }
}

/// A UIKit background task: keeps the app running briefly after it leaves the foreground, for
/// work a suspension would cut off mid-way (a firmware image going over WiFi, a WiFi sync, a log
/// flush). It ends exactly once, on `end()` or from the expiration handler when iOS reclaims the
/// time, so it never leaks into iOS terminating the app.
@MainActor
final class BackgroundTaskAssertion {
  private let name: String
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  /// False once ended, by the caller or by expiration.
  var isActive: Bool {
    identifier != .invalid
  }

  init(name: String) {
    self.name = name
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
      MainActor.assumeIsolated {
        logger.warning("Background task '\(self.name, privacy: .public)' expired before its work finished")
        end()
      }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
