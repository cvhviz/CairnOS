import Foundation
import MeshCore

/// Background delivery: the rules that keep a suspended app reachable by the radio.
///
/// iOS resumes (or relaunches) a bluetooth-central app for two things only: a notification on a
/// live GATT subscription, and the completion of a pending `CBCentralManager.connect`. Timers do
/// not run while the app is suspended, so the reconnection watchdog cannot recover a link the
/// app gave up on in the background; the radio then queues messages until the user opens the
/// app, and drops them once its queue is full. Two rules close that gap:
///
/// 1. Never leave the app without a wake source while a connection is wanted: whenever the
///    Bluetooth state machine ends up idle in the background, arm an untimed pending connect
///    (``ensureWakeSource(context:)``).
/// 2. Use every wake: a notification arriving while the app stack is dead (or its sync failed)
///    rebuilds or resyncs in place (``handleLinkActivity()``).
extension ConnectionManager {
  /// Whether the app is in the background, from the last lifecycle transition, or from the app
  /// state provider before the first one (a Bluetooth relaunch starts in the background without
  /// one). Without either, the app counts as in front (tests, macOS).
  func isAppInBackground() async -> Bool {
    if let lifecycleIsBackground { return lifecycleIsBackground }
    guard let appStateProvider else { return false }
    return await !appStateProvider.isInForeground
  }

  /// Arms an OS pending connect to the last radio when the app is in the background, a Bluetooth
  /// connection is wanted, and nothing else holds a wake source (link up, connect pending, iOS
  /// auto-reconnect, restoration). In front the watchdog and the foreground health check own
  /// recovery, and this does nothing.
  ///
  /// Stands down for a user disconnect, a pairing flow, an explicit connect or session rebuild in
  /// flight, a radio on WiFi, Bluetooth powered off, and a bond failure the user has to resolve
  /// (re-arming there would loop pairing prompts and fight the guided recovery).
  ///
  /// - Parameter context: Why it was called, for the debug log.
  /// - Returns: Whether a pending connect was armed.
  @discardableResult
  func ensureWakeSource(context: String) async -> Bool {
    guard await isAppInBackground() else { return false }
    guard let deviceID = await lastRadioBluetoothPeripheralID() else { return false }
    guard wakeSourceAllowed(deviceID: deviceID) else { return false }

    let diagnostics = await stateMachine.linkDiagnostics
    // Connected, connecting, auto-reconnecting or restoring: a wake source already exists.
    guard diagnostics.phase == .idle else { return false }
    guard await !stateMachine.isBluetoothPoweredOff else { return false }
    // Re-check after the awaits: a connect or disconnect may have run meanwhile.
    guard wakeSourceAllowed(deviceID: deviceID) else { return false }

    let armed = await stateMachine.armPendingReconnect(deviceID: deviceID)
    if armed {
      logger.info("[BLE] Wake source: armed a pending connect to \(deviceID.uuidString.prefix(8)) (\(context))")
      persistDisconnectDiagnostic(
        "source=ensureWakeSource, " +
          "context=\(context), " +
          "device=\(deviceID.uuidString.prefix(8)), " +
          "intent=\(connectionIntent)"
      )
    } else {
      logger.warning("[BLE] Wake source: could not arm a pending connect to \(deviceID.uuidString.prefix(8)) (\(context))")
    }
    return armed
  }

  /// The synchronous half of ``ensureWakeSource(context:)``'s gate.
  private func wakeSourceAllowed(deviceID: UUID) -> Bool {
    guard connectionIntent.wantsConnection else { return false }
    guard currentTransportType == nil || currentTransportType == .bluetooth else { return false }
    guard connectionState == .disconnected else { return false }
    guard !shouldDeferOpportunisticReconnect, !isExplicitConnectInFlight else { return false }
    guard connectingDeviceID == nil, sessionRebuildDeviceID == nil else { return false }
    guard surfacedAuthFailureDeviceID != deviceID else { return false }
    return true
  }

  /// The radio sent something (throttled by the state machine's delegate). Repairs what the
  /// background left broken, now that the process is awake:
  /// - a live link with no app stack (a failed rebuild that preserved the link) is rebuilt in
  ///   place, which drains the radio's queue first; in the background, failed rebuilds back off
  ///   (``linkActivityRebuildDelay(failures:)``);
  /// - a connected stack whose sync failed is resynced (at most once a minute, backing off to
  ///   30 minutes while background resyncs keep failing), and auto-fetch is restarted if it is off.
  func handleLinkActivity() async {
    await onLinkActivity?()
    await noteLinkActivityForReminder()

    guard connectionIntent.wantsConnection,
          currentTransportType == nil || currentTransportType == .bluetooth,
          !shouldDeferOpportunisticReconnect,
          !isExplicitConnectInFlight,
          activeConnectionAttemptDeviceID == nil else { return }

    if connectionState == .disconnected {
      guard await stateMachine.isConnected,
            await !stateMachine.isAutoReconnecting else { return }
      guard connectionIntent.wantsConnection,
            connectionState == .disconnected,
            activeConnectionAttemptDeviceID == nil else { return }
      if let lastBackgroundRebuildFailureAt, await isAppInBackground() {
        let wait = Self.linkActivityRebuildDelay(failures: backgroundRebuildFailures)
        guard Date().timeIntervalSince(lastBackgroundRebuildFailureAt) >= wait else { return }
      }
      logger.info("[BLE] Link activity on a live link without an app stack: rebuilding in place")
      await checkBLEConnectionHealth()
      return
    }

    guard connectionState.isOperational,
          let services,
          let radioID = connectedDevice?.radioID else { return }

    if services.isEventMonitoringActive, await !services.messagePollingService.isAutoFetching {
      logger.warning("[BLE] Link activity: auto-fetch was off; starting it")
      await services.messagePollingService.startAutoFetch(radioID: radioID)
    }

    guard case .failed = services.syncCoordinator.state, resyncTask == nil else { return }
    if let lastLinkActivityResyncAt,
       Date().timeIntervalSince(lastLinkActivityResyncAt) < Self.linkActivityResyncDelay(failedLoops: backgroundResyncFailedLoops) {
      return
    }
    guard self.services === services, connectionState.isOperational else { return }
    lastLinkActivityResyncAt = Date()
    logger.info("[BLE] Link activity: sync is failed; starting the resync loop")
    startResyncLoop(radioID: radioID, services: services, transportType: currentTransportType ?? .bluetooth)
  }

  /// The least time between two resyncs started by link activity.
  static let linkActivityResyncInterval: TimeInterval = 60
  /// The longest wait between two resyncs started by link activity.
  static let linkActivityResyncMaxInterval: TimeInterval = 30 * 60

  /// How long link activity waits after the last resync before starting another, given how many
  /// resync loops in a row failed in the background: a minute, doubling per failed loop, at most
  /// 30 minutes. Auto-fetch keeps the radio's queue draining meanwhile, so a slow cadence costs no
  /// messages, only how soon contacts and channels catch up.
  static func linkActivityResyncDelay(failedLoops: Int) -> TimeInterval {
    guard failedLoops > 1 else { return linkActivityResyncInterval }
    let doublings = min(failedLoops - 1, 10)
    return min(linkActivityResyncInterval * Double(1 << doublings), linkActivityResyncMaxInterval)
  }

  /// The base and the longest wait before link activity rebuilds a dead app stack again after
  /// failed background rebuilds.
  static let linkActivityRebuildBaseInterval: TimeInterval = 15
  static let linkActivityRebuildMaxInterval: TimeInterval = 15 * 60

  /// How long after the last failed background rebuild link activity waits before the next:
  /// 15 s × 2^failures, at most 15 minutes. The link (the wake source) stays up meanwhile.
  static func linkActivityRebuildDelay(failures: Int) -> TimeInterval {
    guard failures > 0 else { return 0 }
    let doublings = min(failures, 10)
    return min(linkActivityRebuildBaseInterval * Double(1 << doublings), linkActivityRebuildMaxInterval)
  }

  /// Pushes the "may not be receiving" reminder back. A Bluetooth relaunch into the background sees
  /// no lifecycle transition, so the first activity there arms the reminder (replacing the one the
  /// terminated process left pending). A Background App Refresh run in which the radio answered
  /// counts as activity too, so a radio on WiFi that refresh keeps draining does not trigger it.
  func noteLinkActivityForReminder() async {
    guard let listeningReminder else { return }
    if await isAppInBackground(), !listeningReminder.currentPolicy.inBackground {
      await listeningReminder.appEnteredBackground(
        wantsConnection: connectionIntent.wantsConnection,
        deviceName: lastConnectedDeviceName
      )
    } else {
      await listeningReminder.linkActivity(deviceName: lastConnectedDeviceName)
    }
  }
}
