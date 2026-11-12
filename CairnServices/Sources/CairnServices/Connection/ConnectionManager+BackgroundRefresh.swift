import Foundation
import MeshCore

// MARK: - Background App Refresh

/// Why a Background App Refresh run did nothing.
public enum BackgroundRefreshSkipReason: String, Sendable {
  // Decided by the connection manager.
  /// No connection is wanted: the user disconnected, or Connect on Launch is off and nobody
  /// connected in this process.
  case notWanted
  /// The last radio is the demo (simulator) radio.
  case simulator
  /// A pairing flow owns the radio.
  case pairing
  /// The radio is waiting for someone to allow this phone (`BackgroundWiFiApprovalGate`).
  case wifiAwaitingApproval
  /// Local Network access was refused; a background attempt cannot ask for it.
  case localNetworkDenied
  /// The radio has no WiFi address to reconnect to.
  case noEndpoint
  /// A Bluetooth connect is already pending (it is the wake source), or a rebuild is in flight.
  case bluetoothPending
  /// Bluetooth is off.
  case bluetoothOff
  /// Background rebuilds of the Bluetooth stack keep failing; link activity's back-off applies.
  case rebuildBackingOff
  /// Nothing to arm a wake source for (no Bluetooth method, or the link is not idle).
  case nothingToArm
  /// Too little of the run's time is left to start a connect.
  case notEnoughTime

  // Decided by the app before the run reaches the connection manager.
  /// The app is in front (a window or a car's screen): the foreground owns the link.
  case inForeground
  /// Demo mode is on.
  case demoMode
  /// Running on a Mac, where the app is not suspended.
  case onMac
  /// Screenshot capture (debug builds).
  case screenshotMode
}

/// What a Background App Refresh run did.
public enum BackgroundRefreshOutcome: Equatable, Sendable {
  case skipped(BackgroundRefreshSkipReason)
  /// The radio's queue was drained; the count when this run did the drain itself.
  case drained(count: Int?)
  /// A pending Bluetooth connect now stands ready to wake the app.
  case wakeSourceArmed
  case failed(String)
  /// The run's time ran out first.
  case timedOut

  /// Whether the run did what it could, for `BGTask.setTaskCompleted(success:)`. A skip is a
  /// success: there was nothing to do, and iOS should not read it as a failing app.
  public var isSuccess: Bool {
    switch self {
    case .skipped, .drained, .wakeSourceArmed: true
    case .failed, .timedOut: false
    }
  }

  /// One word or two for the log.
  public var summary: String {
    switch self {
    case let .skipped(reason): "skipped(\(reason.rawValue))"
    case let .drained(count): "drained(\(count.map(String.init) ?? "by connect"))"
    case .wakeSourceArmed: "wakeSourceArmed"
    case let .failed(detail): "failed(\(detail))"
    case .timedOut: "timedOut"
    }
  }
}

/// The reconnect loop's state, as a refresh run sees it.
enum BackgroundRefreshWiFiLoop: Equatable {
  case none
  case fastWindow
  case backingOff
}

/// The Bluetooth state machine's state, as a refresh run sees it.
enum BackgroundRefreshBLEPhase: Equatable {
  /// No link, no pending connect: nothing will wake the app.
  case idle
  /// Connecting, a pending connect, iOS auto-reconnect or restoration: a wake source exists.
  case pending
  case poweredOff
}

/// Everything a refresh run decides from, read once.
struct BackgroundRefreshSnapshot: Equatable {
  var wantsConnection: Bool
  var isSimulatorRadio: Bool
  var isPairing: Bool
  var transport: TransportType?
  var lastRadioPrefersWiFi: Bool
  var hasWiFiEndpoint: Bool
  var connectionState: DeviceConnectionState
  /// A connect, a WiFi reconnect attempt, the launch reconnect, or a Bluetooth rebuild.
  var explicitConnectInFlight: Bool
  var wifiLoop: BackgroundRefreshWiFiLoop
  var approvalBlocked: Bool
  var localNetworkDenied: Bool
  var bleLinkUp: Bool
  var blePhase: BackgroundRefreshBLEPhase

  /// One line for the log.
  var summary: String {
    let transportName = switch transport {
    case .bluetooth: "bluetooth"
    case .wifi: "wifi"
    case nil: "none"
    }
    return "wants=\(wantsConnection), transport=\(transportName), state=\(connectionState), " +
      "inFlight=\(explicitConnectInFlight), wifiLoop=\(wifiLoop), prefersWiFi=\(lastRadioPrefersWiFi), " +
      "endpoint=\(hasWiFiEndpoint), approvalBlocked=\(approvalBlocked), lnDenied=\(localNetworkDenied), " +
      "bleLink=\(bleLinkUp), blePhase=\(blePhase), sim=\(isSimulatorRadio), pairing=\(isPairing)"
  }
}

/// What a refresh run does with the link it finds.
enum BackgroundRefreshAction: Equatable {
  case skip(BackgroundRefreshSkipReason)
  /// A connect already owns the link and drains on its own: wait for it.
  case waitForInFlightConnect
  /// The link is up: (over WiFi, check the radio still answers, then) drain its queue.
  case drainLiveLink(probeFirst: Bool)
  /// The WiFi link is down: one connect, which drains before its contact sync.
  case reconnectWiFi(cancelBackoff: Bool)
  /// A live Bluetooth link with no app stack: rebuild it in place, which drains first.
  case rebuildBLEStack
  /// Nothing will wake the app over Bluetooth: arm a pending connect.
  case armBLEWakeSource
}

/// Background App Refresh: iOS wakes the app now and then (minutes to hours apart, at its own
/// discretion) for a short run. Bluetooth already wakes a suspended app for every notification
/// and for a pending connect (``ensureWakeSource(context:)``); a WiFi socket wakes nothing, so a
/// radio on WiFi queues its messages until the user opens the app. A refresh run checks in on the
/// radio once: it drains a link that is still up, reconnects one that is down, and otherwise
/// leaves the link exactly as backgrounding leaves it. It never keeps a socket open, never loops
/// past its deadline, never widens the connection intent, and never asks for approval twice.
public extension ConnectionManager {
  /// Whether a refresh run could do anything: a connection is wanted (the user connected, or
  /// Connect on Launch reconnected, and nobody disconnected since), there is a last radio, and
  /// it is not the demo radio. The app schedules the next run only while this is true.
  var wantsBackgroundRefresh: Bool {
    connectionIntent.wantsConnection && lastConnectedDeviceID != nil && !wasSimulatorConnection
  }

  /// One refresh run: reads the link, picks an action (``backgroundRefreshAction(for:)``) and
  /// carries it out before `deadline`. Cancelling the calling task ends the run's waiting; a
  /// connect it started runs on as any connect would.
  func performBackgroundRefresh(deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome {
    let runStart = Date()
    let clockStart = ContinuousClock.now
    let outcome = await runBackgroundRefresh(runStart: runStart, deadline: deadline)
    let elapsed = ContinuousClock.now - clockStart
    backgroundRefreshLogger.info("Run finished: \(outcome.summary) in \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
    if !outcome.isSuccess {
      persistDisconnectDiagnostic(
        "source=backgroundRefresh, " +
          "outcome=\(outcome.summary), " +
          "state=\(String(describing: connectionState)), " +
          "intent=\(connectionIntent)"
      )
    }
    return outcome
  }
}

extension ConnectionManager {
  /// The decision table. Order matters: the stand-down cases come first, then a connect already
  /// in flight (waited for, never duplicated), then the transport the radio is on.
  nonisolated static func backgroundRefreshAction(for snapshot: BackgroundRefreshSnapshot) -> BackgroundRefreshAction {
    guard snapshot.wantsConnection else { return .skip(.notWanted) }
    if snapshot.isSimulatorRadio { return .skip(.simulator) }
    if snapshot.isPairing { return .skip(.pairing) }
    if snapshot.explicitConnectInFlight || snapshot.wifiLoop == .fastWindow {
      return .waitForInFlightConnect
    }

    let onWiFi = snapshot.transport == .wifi
      || (snapshot.transport == nil && snapshot.lastRadioPrefersWiFi && snapshot.hasWiFiEndpoint)
    if onWiFi {
      if snapshot.connectionState.isOperational { return .drainLiveLink(probeFirst: true) }
      if snapshot.approvalBlocked { return .skip(.wifiAwaitingApproval) }
      if snapshot.localNetworkDenied { return .skip(.localNetworkDenied) }
      guard snapshot.hasWiFiEndpoint else { return .skip(.noEndpoint) }
      return .reconnectWiFi(cancelBackoff: snapshot.wifiLoop == .backingOff)
    }

    if snapshot.bleLinkUp {
      if snapshot.connectionState.isOperational { return .drainLiveLink(probeFirst: false) }
      if snapshot.connectionState == .disconnected { return .rebuildBLEStack }
      return .skip(.bluetoothPending)
    }
    switch snapshot.blePhase {
    case .idle: return .armBLEWakeSource
    case .pending: return .skip(.bluetoothPending)
    case .poweredOff: return .skip(.bluetoothOff)
    }
  }

  /// Reads the snapshot, and the WiFi endpoint a reconnect would use: the live transport's, or
  /// the last radio's stored address.
  func backgroundRefreshSnapshot() async -> (BackgroundRefreshSnapshot, (host: String, port: UInt16)?) {
    var endpoint: (host: String, port: UInt16)?
    if let info = await wifiTransport?.connectionInfo {
      endpoint = (info.0, info.1)
    }
    var prefersWiFi = false
    if let stored = await lastRadioWiFiEndpoint() {
      prefersWiFi = stored.prefersWiFi
      if endpoint == nil {
        endpoint = (stored.host, stored.port)
      }
    }
    let approvalBlocked = endpoint.map {
      backgroundWiFiGate.isBlocked(endpoint: BackgroundWiFiApprovalGate.key(host: $0.host, port: $0.port))
    } ?? false

    let bleLinkUp = await stateMachine.isConnected
    let blePhase: BackgroundRefreshBLEPhase = if await stateMachine.isBluetoothPoweredOff {
      .poweredOff
    } else if await stateMachine.linkDiagnostics.phase == .idle, await !stateMachine.isAutoReconnecting {
      .idle
    } else {
      .pending
    }
    let wifiLoop: BackgroundRefreshWiFiLoop = if wifiReconnectTask == nil {
      .none
    } else if isWiFiReconnectBackingOff {
      .backingOff
    } else {
      .fastWindow
    }

    let snapshot = BackgroundRefreshSnapshot(
      wantsConnection: connectionIntent.wantsConnection,
      isSimulatorRadio: wasSimulatorConnection,
      isPairing: shouldDeferOpportunisticReconnect,
      transport: currentTransportType,
      lastRadioPrefersWiFi: prefersWiFi,
      hasWiFiEndpoint: endpoint != nil,
      connectionState: connectionState,
      explicitConnectInFlight: isExplicitConnectInFlight || activeConnectionAttemptDeviceID != nil,
      wifiLoop: wifiLoop,
      approvalBlocked: approvalBlocked,
      localNetworkDenied: hasSeenLocalNetworkDenial,
      bleLinkUp: bleLinkUp,
      blePhase: blePhase
    )
    return (snapshot, endpoint)
  }

  private func runBackgroundRefresh(runStart: Date, deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome {
    // A pass ends the run unless it waited out a connect in flight or its WiFi probe found the
    // link dead (the fast reconnect window that starts is then waited for). Each of those happens
    // at most once, so three passes at most.
    var hasWaited = false
    var hasProbed = false
    for pass in 1...3 {
      let (snapshot, endpoint) = await backgroundRefreshSnapshot()
      let action = Self.backgroundRefreshAction(for: snapshot)
      backgroundRefreshLogger.info("Pass \(pass): \(snapshot.summary) → \(action)")

      switch action {
      case let .skip(reason):
        return .skipped(reason)

      case .waitForInFlightConnect:
        guard !hasWaited else { return .timedOut }
        hasWaited = true
        // The connect drains before its contact sync; that drain, delivered, is the run's goal.
        let settled = await waitForBackgroundRefresh(until: deadline) { [unowned self] in
          await hasDeliveredDrain(since: runStart)
            || !(isExplicitConnectInFlight || activeConnectionAttemptDeviceID != nil
              || (wifiReconnectTask != nil && !isWiFiReconnectBackingOff))
        }
        if await hasDeliveredDrain(since: runStart) {
          backgroundRefreshLogger.info("In-flight connect drained the radio")
          await noteLinkActivityForReminder()
          return .drained(count: nil)
        }
        guard settled, !Task.isCancelled else { return .timedOut }

      case let .drainLiveLink(probeFirst):
        if probeFirst, !hasProbed {
          hasProbed = true
          // A loss starts a fast reconnect window (unless the radio awaits approval); the next
          // pass waits for it.
          if await !probeWiFiLinkForBackgroundRefresh() { continue }
        }
        return await drainLiveLinkForBackgroundRefresh(deadline: deadline)

      case let .reconnectWiFi(cancelBackoff):
        guard let endpoint else { return .skipped(.noEndpoint) }
        return await reconnectWiFiForBackgroundRefresh(
          host: endpoint.host,
          port: endpoint.port,
          cancelBackoff: cancelBackoff,
          runStart: runStart,
          deadline: deadline
        )

      case .rebuildBLEStack:
        return await rebuildBLEStackForBackgroundRefresh(runStart: runStart, deadline: deadline)

      case .armBLEWakeSource:
        let armed = await ensureWakeSource(context: "background refresh")
        return armed ? .wakeSourceArmed : .skipped(.nothingToArm)
      }
    }
    return .timedOut
  }

  // MARK: Actions

  /// The post-resume probe, without touching `lastBackgroundedAt` (the foreground return still
  /// needs it). Sync activity in progress already proves the link, so it is not probed then.
  /// - Returns: `false` when the radio did not answer and the link was handled as lost.
  private func probeWiFiLinkForBackgroundRefresh() async -> Bool {
    guard !shouldPauseWiFiHeartbeatProbe,
          let probedSession = session,
          let probedTransport = wifiTransport else { return true }
    do {
      _ = try await withTimeout(Self.wifiResumeProbeTimeout, operationName: "backgroundRefreshProbe") {
        try await probedSession.getTime()
      }
      backgroundRefreshLogger.info("WiFi probe: the radio answered")
      return true
    } catch {
      guard !Task.isCancelled, session === probedSession, wifiTransport === probedTransport else { return true }
      backgroundRefreshLogger.warning("WiFi probe: no answer (\(type(of: error))); handling the link as lost")
      await handleWiFiDisconnection(error: error, transport: probedTransport)
      return false
    }
  }

  /// Drains the live link's queue, capped well inside the run. The drain stores each message
  /// before fetching the next and checks for cancellation between them, so a cut-off drain
  /// leaves at most one fetched message unsaved, as any drain cut off by suspension would.
  private func drainLiveLinkForBackgroundRefresh(deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome {
    guard let services else { return .failed("no services") }
    let available = deadline - ContinuousClock.now - .seconds(2)
    let cap = min(available, Self.backgroundRefreshDrainCap)
    guard cap >= .seconds(1) else { return .skipped(.notEnoughTime) }
    let poller = services.messagePollingService
    do {
      let count = try await withTimeout(cap, operationName: "backgroundRefreshDrain") {
        try await poller.pollAllMessages()
      }
      backgroundRefreshLogger.info("Drained \(count) message(s) from the live link")
      await noteLinkActivityForReminder()
      return .drained(count: count)
    } catch is TimeoutError {
      return .timedOut
    } catch is CancellationError {
      return .timedOut
    } catch {
      return .failed("drain: \(type(of: error))")
    }
  }

  /// One WiFi connect, started in its own task: it owns its lifecycle through its attempt token
  /// like any connect, and once the radio has answered APP_START the run's end never cuts it.
  /// The run waits only for the drain the connect does before its contact sync, delivered. If
  /// the run ends in the background before the radio answered, the connect is cancelled
  /// (``abandonUnansweredRefreshConnect(_:result:)``). A failed or cancelled connect hands the
  /// link back to the reconnect loop: its slow backoff in the background (where the foreground
  /// return finds and restarts it, as before), a fresh window if the app came to the front
  /// meanwhile.
  private func reconnectWiFiForBackgroundRefresh(
    host: String,
    port: UInt16,
    cancelBackoff: Bool,
    runStart: Date,
    deadline: ContinuousClock.Instant
  ) async -> BackgroundRefreshOutcome {
    guard deadline - ContinuousClock.now >= backgroundRefreshMinimumForConnect else {
      return .skipped(.notEnoughTime)
    }
    if cancelBackoff {
      cancelWiFiReconnection()
    }
    backgroundRefreshLogger.info("WiFi connect started to \(host):\(port)")
    let result = BackgroundRefreshConnectResult()
    let connect = Task { [weak self] in
      guard let self else { return }
      do {
        try await connectViaWiFi(host: host, port: port, failsFastOnLocalNetworkPrompt: true)
        result.value = .succeeded
      } catch {
        result.value = .failed(String(describing: type(of: error)))
        backgroundRefreshLogger.warning("WiFi connect failed: \(type(of: error))")
        // Superseded (a disconnect, another connect): the new owner has the link. Cancelled by
        // the run's end: the loop takes it back like any failure.
        guard Task.isCancelled || !(error is CancellationError) else { return }
        await handBackgroundRefreshFailureToLoop(host: host, port: port)
      }
    }

    _ = await waitForBackgroundRefresh(until: deadline) { [unowned self] in
      if result.value != nil { return true }
      return await hasDeliveredDrain(since: runStart)
    }
    let abandoned = await abandonUnansweredRefreshConnect(connect, result: result)
    if await hasDeliveredDrain(since: runStart) {
      backgroundRefreshLogger.info("WiFi connect drained the radio")
      await noteLinkActivityForReminder()
      return .drained(count: nil)
    }
    // The run's time ran out on it; its CancellationError says nothing more.
    if abandoned { return .timedOut }
    switch result.value {
    case .succeeded:
      await noteLinkActivityForReminder()
      return .drained(count: nil)
    case let .failed(detail):
      return .failed("connect: \(detail)")
    case nil:
      return .timedOut
    }
  }

  /// The run is ending with its connect still under way. In front it carries on: the app keeps
  /// running and someone is there to answer the radio. In the background iOS suspends the app
  /// once the run completes, and a connect frozen before APP_START is answered leaves the radio
  /// holding a half-open session (on an L2, the quarantine that lights its screen), keeps the
  /// attempt token claimed so the next foreground's WiFi check stands down, and fails on the
  /// next wake with a timeout. So it is cancelled here, with a moment to close its socket; the
  /// slow backoff takes the link back. A connect past APP_START is left as backgrounding leaves
  /// any link: the radio accepted this phone, and dropping it would make the next run
  /// reconnect, the one step that can make a radio ask.
  /// - Returns: Whether the connect was cancelled.
  private func abandonUnansweredRefreshConnect(_ connect: Task<Void, Never>, result: BackgroundRefreshConnectResult) async -> Bool {
    guard result.value == nil,
          connectionAttemptTransport == .wifi,
          await isRunningInBackgroundForApprovalGate(),
          await isWiFiHandshakeUnanswered() else { return false }
    backgroundRefreshLogger.info("Run ending before the radio answered APP_START: cancelling the WiFi connect")
    connect.cancel()
    // An expired run (this task cancelled) completes at once; the cancel still stands.
    let grace = ContinuousClock.now + Self.backgroundRefreshCancelGrace
    while result.value == nil, ContinuousClock.now < grace, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  /// Whether the WiFi link has no answer to APP_START yet: TCP is not up (no session), or the
  /// session has no self info.
  private func isWiFiHandshakeUnanswered() async -> Bool {
    guard let session else { return true }
    return await session.currentSelfInfo == nil
  }

  /// After a refresh run's connect failed: the reconnect loop takes the link back, unless the
  /// user disconnected, another connect owns it, or a loop already runs.
  private func handBackgroundRefreshFailureToLoop(host: String, port: UInt16) async {
    guard connectionIntent.wantsConnection,
          connectionState == .disconnected,
          !isExplicitConnectInFlight,
          wifiReconnectTask == nil else { return }
    let inBackground = await isRunningInBackgroundForApprovalGate()
    await startWiFiRecovery(host: host, port: port, startingWithSlowBackoff: inBackground)
  }

  /// A live Bluetooth link with no app stack: the rebuild link activity would do, under the same
  /// back-off, in its own task (a rebuild and its sync outlast a run). Waits for its drain.
  private func rebuildBLEStackForBackgroundRefresh(runStart: Date, deadline: ContinuousClock.Instant) async -> BackgroundRefreshOutcome {
    if let lastBackgroundRebuildFailureAt {
      let wait = Self.linkActivityRebuildDelay(failures: backgroundRebuildFailures)
      guard Date().timeIntervalSince(lastBackgroundRebuildFailureAt) >= wait else {
        return .skipped(.rebuildBackingOff)
      }
    }
    backgroundRefreshLogger.info("Rebuilding the Bluetooth app stack on a live link")
    Task { [weak self] in
      await self?.checkBLEConnectionHealth()
    }
    let drained = await waitForBackgroundRefresh(until: deadline) { [unowned self] in
      await hasDeliveredDrain(since: runStart)
    }
    guard drained else { return .timedOut }
    await noteLinkActivityForReminder()
    return .drained(count: nil)
  }

  // MARK: Helpers

  /// Whether the current link's queue was drained to its end since `date` and that drain was
  /// delivered: its handlers stored every message, catch-up suppression was lifted and the
  /// tally posted (`SyncCoordinator.lastCatchUpDeliveredAt`). The queue empties first; until the
  /// delivery the messages are stored but not notified, and a run that completed in between
  /// would leave their notifications to the next wake, which drops them if that is a foreground.
  func hasDeliveredDrain(since date: Date) async -> Bool {
    guard let services else { return false }
    return await Self.isDrainDelivered(
      drainedAt: services.messagePollingService.lastDrainCompletedAt,
      deliveredAt: services.syncCoordinator.lastCatchUpDeliveredAt,
      since: date
    )
  }

  /// ``hasDeliveredDrain(since:)``'s rule: a drain and a delivery both since `date`. Not "the
  /// delivery after the last drain": auto-fetch may finish another drain right after the
  /// delivery (its messages notify directly, suppression being lifted), and the run would then
  /// wait out its deadline for a mark that comes only when the contact sync ends.
  nonisolated static func isDrainDelivered(drainedAt: Date?, deliveredAt: Date?, since date: Date) -> Bool {
    guard let drainedAt, drainedAt >= date, let deliveredAt else { return false }
    return deliveredAt >= date
  }

  /// Polls `condition` every 250 ms until it holds, the deadline passes, or the task is cancelled.
  /// - Returns: Whether the condition held.
  private func waitForBackgroundRefresh(
    until deadline: ContinuousClock.Instant,
    _ condition: () async -> Bool
  ) async -> Bool {
    while ContinuousClock.now < deadline, !Task.isCancelled {
      if await condition() { return true }
      let remaining = deadline - ContinuousClock.now
      try? await Task.sleep(for: min(.milliseconds(250), max(remaining, .zero)))
    }
    return await condition()
  }
}

/// The outcome of a refresh run's connect, filled in by the connect's own task.
@MainActor
private final class BackgroundRefreshConnectResult {
  enum Value {
    case succeeded
    case failed(String)
  }

  var value: Value?
}
