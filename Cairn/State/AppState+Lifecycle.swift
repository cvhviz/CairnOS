import Foundation
import CairnServices

/// Temporary resume snapshot for the iOS 26 toolbar exclusivity abort.
/// `.notice` so unified logs keep it; grep `[DBG-toolbar-resume]` to remove.
private enum ToolbarResumeProbe {
  static let tag = "[DBG-toolbar-resume]"
  static let log = PersistentLogger(subsystem: "cvhvisuals.Cairn.diag", category: "toolbar-resume")
}

/// The foreground reconciliation in flight for each `AppState`, so a second `.active` (another
/// window, the active fallback, CarPlay, launch's own pass) joins it instead of running a second
/// WiFi connect or BLE health check alongside it. `backgroundEpoch` counts background
/// transitions: a reconciliation started before the latest one is waited out, not joined, so
/// the return after it still queues its own BLE foreground transition.
@MainActor
private enum ForegroundReconciliation {
  struct Running {
    let token: UUID
    let task: Task<Void, Never>
    let backgroundEpoch: Int
  }

  static var running: [ObjectIdentifier: Running] = [:]
  static var backgroundEpoch: [ObjectIdentifier: Int] = [:]
}

// MARK: - App Lifecycle

extension AppState {
  private enum BLELifecycleTransition {
    case enterBackground
    case becomeActive
  }

  @discardableResult
  private func enqueueBLELifecycleTransition(_ transition: BLELifecycleTransition) -> Task<Void, Never> {
    let priorTask = bleLifecycleTransitionTask
    let manager = connectionManager

    let transitionTask = Task { @MainActor in
      await priorTask?.value

      #if DEBUG
        switch transition {
        case .enterBackground:
          if let override = bleEnterBackgroundOverride {
            await override()
            return
          }
        case .becomeActive:
          if let override = bleBecomeActiveOverride {
            await override()
            return
          }
        }
      #endif

      switch transition {
      case .enterBackground:
        await manager.appDidEnterBackground()
      case .becomeActive:
        await manager.appDidBecomeActive()
      }
    }

    bleLifecycleTransitionTask = transitionTask
    return transitionTask
  }

  /// Called when app enters background
  func handleEnterBackground() {
    logToolbarResumeProbe(source: "enterBackground")
    ForegroundReconciliation.backgroundEpoch[ObjectIdentifier(self), default: 0] += 1
    activeRecoveryFallbackTask?.cancel()
    activeRecoveryFallbackTask = nil

    stopRadioPositionRefresh()

    // Keep battery polling alive when the live activity is visible on the lock screen
    if !liveActivityManager.hasActiveActivity {
      batteryMonitor.stop()
    }

    // Stop room keepalives to save battery/bandwidth
    Task {
      await services?.remoteNodeService.stopAllKeepAlives()
    }

    // Queue BLE lifecycle transition so background/foreground hooks stay ordered.
    enqueueBLELifecycleTransition(.enterBackground)
  }

  /// Called when app returns to foreground. Serialized per `AppState`: a call while one is
  /// running joins it, unless the app went to the background since it started, in which case
  /// it waits for it and then runs its own.
  func handleReturnToForeground() async {
    let key = ObjectIdentifier(self)
    let epoch = ForegroundReconciliation.backgroundEpoch[key, default: 0]
    while let running = ForegroundReconciliation.running[key] {
      await running.task.value
      if running.backgroundEpoch == epoch { return }
    }

    let token = UUID()
    let task = Task { @MainActor in
      await performReturnToForeground()
      if ForegroundReconciliation.running[key]?.token == token {
        ForegroundReconciliation.running[key] = nil
      }
    }
    ForegroundReconciliation.running[key] = ForegroundReconciliation.Running(
      token: token,
      task: task,
      backgroundEpoch: epoch
    )
    await task.value
  }

  private func performReturnToForeground() async {
    logToolbarResumeProbe(source: "returnToForeground")
    await Task.yield()
    await DebugLogBuffer.shared?.flush()

    // Update badge count from database
    await services?.notificationService.updateBadgeCount()

    // Room keepalives are managed by RoomConversationView lifecycle
    // (started on view appear, stopped on disappear, restarted via scenePhase)

    // Reconcile transport state first (WiFi check + BLE lifecycle transition,
    // which internally fires checkBLEConnectionHealth) so any stale "connected"
    // state gets cleaned up via
    // handleConnectionLoss → onConnectionLost → liveActivityManager.handleConnectionLost
    // before the Live Activity tries to validate or restart.
    await connectionManager.checkWiFiConnectionHealth()
    await enqueueBLELifecycleTransition(.becomeActive).value

    if let advertisementService = services?.advertisementService {
      await advertisementService.handleReturnToForeground()
    }

    // Re-prime warm chats that got messages while backgrounded (deferred then
    // so a busy channel didn't keep priming with nobody looking).
    chatPrewarmRefresher?.refreshStaleConversations()

    startRadioPositionRefresh()
    liveActivityManager.handleReturnToForeground()
    await liveActivityManager.validateActivityState()
    await restartLiveActivityIfMissing()

    // Check for expired ACKs
    if connectionState == .ready {
      try? await services?.messageService.checkExpiredAcks()
    }

    // Trigger resync if sync failed while connected
    await connectionManager.checkSyncHealth()

    // Check for missed battery thresholds and restart polling only once the
    // connection is ready; a reconnecting link would just time out the reads.
    // wireServicesIfConnected starts polling when the connection comes up.
    if connectionState == .ready, let services {
      await batteryMonitor.checkMissedBatteryThreshold(device: connectedDevice, services: services)
      batteryMonitor.startRefreshLoop(services: services) { [weak self] in self?.connectedDevice }
    }

    offlineMapService.resumeAllPacks()
    logToolbarResumeProbe(source: "returnToForegroundDone")
  }

  func logToolbarResumeProbe(source: String, scene: String? = nil) {
    ToolbarResumeProbe.log.notice(toolbarResumeProbeMessage(source: source, scene: scene))
  }

  func toolbarResumeProbeMessage(source: String, scene: String? = nil) -> String {
    let tab = AppTab(rawValue: navigation.selectedTab).map { String(describing: $0) }
      ?? "unknown(\(navigation.selectedTab))"
    let chatRoute = navigation.chatsSelectedRoute.map { String(describing: $0.kind) } ?? "none"
    let nodesDetail = if navigation.nodesShowingDiscovery {
      "discovery"
    } else if navigation.selectedContact != nil {
      "contact"
    } else {
      "none"
    }
    var parts = [
      ToolbarResumeProbe.tag,
      "source=\(source)",
    ]
    if let scene {
      parts.append("scene=\(scene)")
    }
    parts.append(contentsOf: [
      "tab=\(tab)",
      "tabBar=\(navigation.tabBarVisibility)",
      "chatRoute=\(chatRoute)",
      "nodesDetail=\(nodesDetail)",
      "tool=\(navigation.selectedTool.map { String(describing: $0) } ?? "none")",
      "settings=\(navigation.isSettingsPresented)",
      "connection=\(connectionState)",
      "hasDevice=\(connectedDevice != nil)",
      "clientRepeat=\(connectedDevice?.clientRepeat == true)",
    ])
    return parts.joined(separator: " ")
  }
}
