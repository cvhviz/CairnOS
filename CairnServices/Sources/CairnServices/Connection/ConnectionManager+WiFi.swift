import Foundation
import MeshCore

extension ConnectionManager {
  // MARK: - WiFi Heartbeat

  /// Starts periodic heartbeat to detect dead WiFi connections.
  /// ESP32's TCP stack doesn't respond to TCP keepalives, so we use application-level probes.
  func startWiFiHeartbeat() {
    stopWiFiHeartbeat()

    wifiHeartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.wifiHeartbeatInterval)
        } catch {
          break
        }

        guard let self,
              currentTransportType == .wifi,
              connectionState.isOperational,
              let session else { break }

        if shouldPauseWiFiHeartbeatProbe {
          logger.debug("WiFi heartbeat skipped while sync activity is active")
          continue
        }

        // Probe connection with lightweight command
        do {
          _ = try await session.getTime()
        } catch {
          if shouldPauseWiFiHeartbeatProbe {
            logger.debug("WiFi heartbeat timeout during sync activity treated as inconclusive")
            continue
          }
          logger.warning("WiFi heartbeat failed: \(error.localizedDescription)")
          await handleWiFiDisconnection(error: error, transport: wifiTransport)
          break
        }
      }
    }
  }

  var shouldPauseWiFiHeartbeatProbe: Bool {
    connectionState == .syncing || resyncTask != nil || channelRetryTask != nil
  }

  /// Stops the WiFi heartbeat loop
  func stopWiFiHeartbeat() {
    wifiHeartbeatTask?.cancel()
    wifiHeartbeatTask = nil
  }

  // MARK: - WiFi Disconnection Handling

  /// Handles unexpected WiFi connection loss
  /// - Parameter lostTransport: The transport that reported the loss. Only the current one
  ///   counts: a late report from a transport already replaced (an earlier reconnect
  ///   attempt's, or one a newer connect swapped out) concerns nothing live.
  func handleWiFiDisconnection(error: Error?, transport lostTransport: WiFiTransport?) async {
    // User-initiated disconnect - don't reconnect
    guard connectionIntent.wantsConnection else { return }

    // Only handle WiFi disconnections
    guard currentTransportType == .wifi else { return }

    if let lostTransport, lostTransport !== wifiTransport {
      logger.info("WiFi loss reported by a replaced transport, ignoring")
      return
    }

    // Prevent re-entrant calls: multiple disconnection callbacks can fire
    // simultaneously from the transport handler and heartbeat. The flag
    // covers the window between entry and startWiFiReconnection() where
    // await suspension points could allow interleaving on @MainActor.
    guard !isHandlingWiFiDisconnection else {
      logger.info("WiFi disconnection already being handled, ignoring duplicate")
      return
    }
    isHandlingWiFiDisconnection = true
    defer { isHandlingWiFiDisconnection = false }

    stopWiFiHeartbeat()
    cancelResyncLoop()
    cancelChannelRetry()

    // Capture and clear synchronously, mirroring teardownSessionForReconnect:
    // a reconnect can install a new container during the awaits below, and
    // re-reading self.services would tear that new container down.
    let oldServices = services
    let oldSession = session
    services = nil
    session = nil

    // A connect or reconnect attempt is mid-handshake or mid-sync on this transport. Its
    // session and services go now so it fails at once rather than on a timeout; the retry
    // belongs to the attempt's owner (the reconnect loop's next attempt, or the connect's
    // own failure and recovery path), not to a second loop started from here.
    let attemptInFlight = connectionAttemptTransport == .wifi
    if attemptInFlight {
      logger.warning("WiFi connection lost during a connect attempt: \(error?.localizedDescription ?? "unknown")")
    } else {
      logger.warning("WiFi connection lost: \(error?.localizedDescription ?? "unknown")")
    }

    await oldSession?.stop(disconnectTransport: false)
    if let oldServices {
      // Mark room sessions disconnected before tearing down services
      _ = await oldServices.remoteNodeService.handleBLEDisconnection()
      // Reset sync state before destroying services to prevent stuck "Syncing" pill
      await oldServices.syncCoordinator.onDisconnected(notificationService: oldServices.notificationService)
      await oldServices.tearDown()
    }

    guard !attemptInFlight else { return }

    // Show connecting state (pulsing indicator)
    logger.info("[WiFi] State → .connecting (WiFi disconnection, starting reconnection)")
    connectionState = .connecting

    // A loop whose last attempt already succeeded can still be finishing; left in place it
    // would turn the start below into a no-op and strand the link.
    cancelWiFiReconnection()

    // Start reconnection attempts
    startWiFiReconnection()
  }

  // MARK: - WiFi Reconnection

  /// Starts the WiFi reconnection retry loop.
  ///
  /// The loop runs a fast window of attempts, then a slow capped backoff that
  /// keeps going for as long as the user wants the connection. It ends only
  /// on success, on cancellation (a manual disconnect or a BLE connect), or
  /// when the connection intent is withdrawn.
  ///
  /// - Parameters:
  ///   - ignoringCooldown: Starts the fast window at once even inside
  ///     the cooldown. Used for user-driven retries such as an app foreground,
  ///     which cannot storm the way a flapping link can.
  ///   - startingWithSlowBackoff: Skips the fast window and goes straight to the slow
  ///     backoff, for a link observers already know is down: a Background App Refresh run
  ///     whose reconnect failed hands the link back this way, so the foreground finds the
  ///     loop it would have found without the run.
  private func startWiFiReconnection(ignoringCooldown: Bool = false, startingWithSlowBackoff: Bool = false) {
    // If a reconnect task is already running, don't start another
    if wifiReconnectTask != nil {
      logger.info("WiFi reconnection already in progress, skipping")
      return
    }

    // Rate limiting: a drop inside the cooldown defers its fast window to the
    // end of the cooldown instead of opening a new one at once.
    let deferral = ignoringCooldown || startingWithSlowBackoff ? nil : Self.wifiReconnectDeferral(
      sinceLastStart: lastWiFiReconnectStartTime.map { Date().timeIntervalSince($0) }
    )

    wifiReconnectAttempt = 0
    isWiFiReconnectBackingOff = startingWithSlowBackoff

    if startingWithSlowBackoff {
      wifiReconnectTask = Task {
        defer {
          if !Task.isCancelled {
            wifiReconnectTask = nil
            wifiReconnectAttempt = 0
            isWiFiReconnectBackingOff = false
          }
        }
        await runSlowWiFiReconnectBackoff()
      }
      return
    }

    wifiReconnectTask = Task {
      // Only self-nil when not cancelled: startWiFiReconnection cancels the
      // old task before assigning a new one, and an unconditional defer in
      // the cancelled old task would destroy the replacement's handle (the
      // same pattern resyncTask and channelRetryTask document).
      defer {
        if !Task.isCancelled {
          wifiReconnectTask = nil
          wifiReconnectAttempt = 0
          isWiFiReconnectBackingOff = false
        }
      }

      if let deferral {
        logger.warning("WiFi dropped too soon after the last reconnect window; retrying in \(deferral.components.seconds)s")
        try? await Task.sleep(for: deferral)
        guard !Task.isCancelled, connectionIntent.wantsConnection else { return }
      }
      lastWiFiReconnectStartTime = Date()

      if await runFastWiFiReconnectWindow() { return }
      guard !Task.isCancelled, connectionIntent.wantsConnection else { return }

      logger.info("WiFi reconnect window expired; continuing with slow backoff")
      isWiFiReconnectBackingOff = true
      await cleanupConnection()
      await onConnectionLost?()

      await runSlowWiFiReconnectBackoff()
    }
  }

  /// Runs the fast reconnect window: attempts with 0.5 s to 4 s backoff for up
  /// to `wifiMaxReconnectDuration`, and at least `wifiMinFastReconnectAttempts` of them.
  /// - Returns: `true` when a reconnect succeeded.
  private func runFastWiFiReconnectWindow() async -> Bool {
    let startTime = ContinuousClock.now

    while !Task.isCancelled, connectionIntent.wantsConnection {
      if Self.isFastWiFiReconnectWindowSpent(
        elapsed: ContinuousClock.now - startTime,
        attempts: wifiReconnectAttempt
      ) {
        return false
      }
      // The radio is waiting for someone to allow this phone: more attempts in the background
      // would only light its screen again. The slow backoff waits for the user.
      if await isWiFiAttemptAwaitingApproval() {
        logger.info("WiFi fast reconnect window ended: the radio is waiting for approval")
        return false
      }

      wifiReconnectAttempt += 1
      logger.info("WiFi reconnect attempt \(self.wifiReconnectAttempt)")

      do {
        try await reconnectWiFi()
        logger.info("WiFi reconnection succeeded")
        return true
      } catch {
        logger.warning("WiFi reconnect failed: \(error.localizedDescription)")
      }

      // Exponential backoff: 0.5s, 1s, 2s, 4s (capped)
      let delay = min(0.5 * pow(2.0, Double(wifiReconnectAttempt - 1)), 4.0)
      try? await Task.sleep(for: .seconds(delay))
    }
    return false
  }

  /// Runs the slow backoff after the fast window: one attempt per
  /// `wifiSlowReconnectDelay(afterAttempt:)` while the user still wants the
  /// WiFi connection. Observers were already told of the loss, so a failed
  /// attempt returns the state to `.disconnected` without notifying again.
  private func runSlowWiFiReconnectBackoff() async {
    var slowAttempt = 0

    while !Task.isCancelled, connectionIntent.wantsConnection, currentTransportType == .wifi {
      slowAttempt += 1
      let delay = Self.wifiSlowReconnectDelay(afterAttempt: slowAttempt)
      logger.info("WiFi slow reconnect: next attempt in \(delay.components.seconds)s")
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, connectionIntent.wantsConnection, currentTransportType == .wifi else { return }

      // The sleep returns on any wake (a Background App Refresh run among them); a radio
      // waiting for approval is left alone until the user is back.
      if await isWiFiAttemptAwaitingApproval() {
        logger.info("WiFi slow reconnect: skipping the attempt, the radio is waiting for approval")
        continue
      }

      wifiReconnectAttempt += 1
      logger.info("WiFi reconnect attempt \(self.wifiReconnectAttempt) (slow backoff)")

      do {
        try await reconnectWiFi()
        logger.info("WiFi reconnection succeeded")
        return
      } catch {
        logger.warning("WiFi reconnect failed: \(error.localizedDescription)")
      }

      // reconnectWiFi may have reached .connected and built a session before
      // failing; drop back to the disconnected state observers were given.
      guard !Task.isCancelled else { return }
      if connectionState != .disconnected || session != nil || services != nil {
        await cleanupConnection()
      }
    }
  }

  /// Whether the fast reconnect window is over: its duration has passed and it has made its
  /// minimum attempts. Time spent suspended counts toward the duration but makes no attempts,
  /// so a window that iOS froze still tries a few times once the app is back.
  static func isFastWiFiReconnectWindowSpent(elapsed: Duration, attempts: Int) -> Bool {
    elapsed > wifiMaxReconnectDuration && attempts >= wifiMinFastReconnectAttempts
  }

  /// How long a drop must wait before opening a fast reconnect window.
  /// - Parameter elapsed: Seconds since the last window started, or `nil` if none has.
  /// - Returns: The rest of the cooldown, or `nil` to start at once.
  static func wifiReconnectDeferral(sinceLastStart elapsed: TimeInterval?) -> Duration? {
    guard let elapsed, elapsed >= 0, elapsed < wifiReconnectCooldown else { return nil }
    return .seconds(wifiReconnectCooldown - elapsed)
  }

  /// Delay before the given slow-backoff attempt (1-based): 30 s, then
  /// doubling up to the 5 minute cap.
  static func wifiSlowReconnectDelay(afterAttempt attempt: Int) -> Duration {
    let doublings = min(max(attempt - 1, 0), 16)
    let delay = wifiSlowReconnectInitialDelay * (1 << doublings)
    return min(delay, wifiSlowReconnectMaxDelay)
  }

  /// Stands the WiFi side down ahead of a BLE connect. A reconnect loop left
  /// running would stop the BLE session on its next attempt and tear the BLE
  /// services down when its reconnect window expires.
  func releaseWiFiForBLEConnect() async {
    cancelWiFiReconnection()
    stopWiFiHeartbeat()
    guard let wifiTransport else { return }
    self.wifiTransport = nil
    await wifiTransport.disconnect()
  }

  /// Hands a WiFi link that is wanted but down to the reconnect loop, from its address
  /// alone: the radio was unreachable at launch, a failing resync dropped it, or it dropped
  /// mid initial sync. The loop finds the address on `wifiTransport`, which a failed or
  /// dropped connect no longer leaves behind, so a fresh unconnected one carries it.
  /// - Parameter startingWithSlowBackoff: Leaves the link at `.disconnected` and starts the
  ///   loop in its slow backoff (see `startWiFiReconnection`).
  func startWiFiRecovery(host: String, port: UInt16, startingWithSlowBackoff: Bool = false) async {
    guard connectionIntent.wantsConnection else { return }
    if wifiTransport == nil {
      let placeholder = WiFiTransport()
      await placeholder.setConnectionInfo(host: host, port: port)
      guard connectionIntent.wantsConnection, wifiTransport == nil else { return }
      wifiTransport = placeholder
    }
    currentTransportType = .wifi
    cancelWiFiReconnection()
    if startingWithSlowBackoff {
      logger.info("[WiFi] Starting WiFi recovery for \(host):\(port) in slow backoff")
      startWiFiReconnection(startingWithSlowBackoff: true)
      return
    }
    logger.info("[WiFi] State → .connecting (starting WiFi recovery for \(host):\(port))")
    connectionState = .connecting
    startWiFiReconnection(ignoringCooldown: true)
  }

  /// Attempts to reconnect to the WiFi device using stored connection info
  private func reconnectWiFi() async throws {
    guard let wifiTransport,
          let (host, port) = await wifiTransport.connectionInfo else {
      throw ConnectionError.connectionFailed("No WiFi connection info")
    }
    // A cancelled loop has handed the connection to a disconnect or a BLE
    // connect; the session below is theirs, not this attempt's.
    try Task.checkCancellation()

    // Each attempt claims the link; a user connect, a BLE connect, or a disconnect that
    // lands during one of the awaits below supersedes it.
    let attempt = beginConnectionAttempt(.wifi)
    let stillOwns = { [unowned self] in !Task.isCancelled && ownsConnectionAttempt(attempt) }
    var newTransport: WiFiTransport?
    var newSession: MeshCoreSession?
    // TCP is up and APP_START has not been answered: where a radio holding this phone for
    // approval leaves an attempt.
    var awaitingAppStart = false
    var handshakeStartedAt: ContinuousClock.Instant?

    do {
      // Stop any existing session to prevent receive loops racing for transport data
      let staleSession = session
      session = nil
      await staleSession?.stop()

      // Disconnect old transport cleanly
      await wifiTransport.disconnect()
      guard stillOwns() else { throw CancellationError() }

      // Create fresh transport with same connection info. Its loss handler is wired before
      // it connects, so a drop during this attempt's own handshake or sync is not missed.
      let freshTransport = WiFiTransport()
      newTransport = freshTransport
      await freshTransport.setConnectionInfo(host: host, port: port)
      await freshTransport.setFailsFastOnLocalNetworkPrompt(hasSeenLocalNetworkDenial)
      await freshTransport.setDisconnectionHandler { [weak self, weak freshTransport] error in
        Task { @MainActor in
          await self?.handleWiFiDisconnection(error: error, transport: freshTransport)
        }
      }
      guard stillOwns() else { throw CancellationError() }
      self.wifiTransport = freshTransport

      // Connect
      try await freshTransport.connect()
      awaitingAppStart = true
      handshakeStartedAt = .now
      guard stillOwns() else { throw CancellationError() }
      connectionState = .connected

      // Re-establish session
      let reconnectSession = MeshCoreSession(transport: freshTransport)
      newSession = reconnectSession
      session = reconnectSession
      try await reconnectSession.start()
      awaitingAppStart = false
      clearWiFiApprovalGate(reason: "the radio answered")
      guard stillOwns() else { throw CancellationError() }

      guard let selfInfo = await reconnectSession.currentSelfInfo else {
        throw ConnectionError.initializationFailed("No self info")
      }

      let deviceID = DeviceIdentity.deriveUUID(from: selfInfo.publicKey)
      try await completeWiFiReconnection(
        session: reconnectSession,
        transport: freshTransport,
        deviceID: deviceID,
        stillOwns: stillOwns
      )
      endConnectionAttempt(attempt)
    } catch {
      // Drop what this attempt built. Its transport keeps the address the next attempt
      // reads, but stops reporting: a late drop of it must not read as a new loss.
      if let newSession {
        if session === newSession {
          session = nil
        }
        await newSession.stop(disconnectTransport: false)
      }
      await newTransport?.disconnect()
      if case WiFiTransportError.localNetworkDenied = error {
        hasSeenLocalNetworkDenial = true
      }
      await recordWiFiApprovalSignatureIfNeeded(
        host: host,
        port: port,
        transportConnected: awaitingAppStart,
        handshakeStartedAt: handshakeStartedAt,
        error: error
      )
      if ownsConnectionAttempt(attempt) {
        endConnectionAttempt(attempt)
        // The loop shows its fast window as connecting; a link that came up and failed
        // must not stay at .connected with no session behind it.
        if connectionState == .connected {
          connectionState = .connecting
        }
      }
      throw error
    }
  }

  /// Completes WiFi reconnection by re-establishing services
  /// - Parameter stillOwns: The attempt's ownership check, re-run after every await.
  /// - Throws: `CancellationError` when superseded, or a connection error when the link
  ///   dropped before the connection was promoted, so the loop tries again.
  private func completeWiFiReconnection(
    session: MeshCoreSession,
    transport: WiFiTransport,
    deviceID: UUID,
    stillOwns: @escaping () -> Bool
  ) async throws {
    let capabilities = try await session.queryDevice()
    guard stillOwns() else { throw CancellationError() }
    detectAndStorePlatform(model: capabilities.model, transportType: .wifi)
    guard let selfInfo = await session.currentSelfInfo else {
      throw ConnectionError.initializationFailed("No self info")
    }

    let (newServices, radioID) = try await buildServicesAndSaveDevice(
      deviceID: deviceID,
      session: session,
      selfInfo: selfInfo,
      capabilities: capabilities,
      isStillOwner: stillOwns
    )
    persistConnection(deviceID: deviceID, radioID: radioID, deviceName: selfInfo.name, transport: .wifi)

    await onConnectionReady?()
    // onConnectionReady can suspend; a reentrant main-actor WiFi disconnect may
    // clear connectedDevice or replace services during that await. Recheck so an
    // aborted reconnect bails here instead of syncing a torn-down session.
    guard stillOwns(),
          connectionIntent.wantsConnection,
          services === newServices,
          connectedDevice != nil
    else {
      logger.info("[WiFi] reconnect aborted after onConnectionReady: connection state changed")
      await abandonWiFiReconnect(services: newServices)
      throw reconnectAbortError(stillOwns: stillOwns)
    }
    let syncSucceeded = await performInitialSync(radioID: radioID, services: newServices, transportType: .wifi, context: "WiFi reconnect")

    guard await promoteToReady(
      syncSucceeded: syncSucceeded,
      expectedServices: newServices,
      transportType: .wifi,
      additionalGuard: stillOwns
    ) else {
      await abandonWiFiReconnect(services: newServices)
      throw reconnectAbortError(stillOwns: stillOwns)
    }

    hasSeenLocalNetworkDenial = false
    stopReconnectionWatchdog()
    // A connection promoted to .syncing (initial sync failed, resync running) needs the
    // heartbeat too: it pauses its probes while sync runs and takes over once it ends.
    if connectionState.isOperational {
      startWiFiHeartbeat()
    }
  }

  /// Tears down a reconnect attempt's services, clearing them only while still current.
  private func abandonWiFiReconnect(services attemptServices: ServiceContainer) async {
    if services === attemptServices {
      services = nil
    }
    await attemptServices.tearDown()
  }

  /// The error an aborted reconnect attempt throws, so `reconnectWiFi` stops its session:
  /// `CancellationError` when superseded or when the user disconnected (the loop then ends),
  /// a connection error when the link dropped while still wanted (the loop tries again).
  private func reconnectAbortError(stillOwns: () -> Bool) -> Error {
    guard stillOwns(), connectionIntent.wantsConnection else { return CancellationError() }
    return ConnectionError.connectionFailed("WiFi link lost while reconnecting")
  }

  // MARK: - WiFi Background Work

  /// Whether WiFi work a suspension would cut off is under way: a connect or reconnect
  /// attempt, the initial sync, a resync, or a channel retry. Bluetooth events wake a
  /// suspended app, but a WiFi socket simply stops, so the app holds a background task
  /// while this is true. The slow reconnect backoff, idle at `.disconnected`, does not count.
  public var hasWiFiWorkInFlight: Bool {
    guard currentTransportType == .wifi else { return false }
    if connectionAttemptTransport == .wifi || resyncTask != nil || channelRetryTask != nil {
      return true
    }
    if services?.syncCoordinator.state.isSyncing == true {
      return true
    }
    switch connectionState {
    case .connecting, .connected, .syncing:
      return true
    case .disconnected, .ready:
      return false
    }
  }

  // MARK: - WiFi Connection Health

  /// Suspension after which a WiFi link that still looks connected is probed on return.
  static let wifiResumeProbeThreshold: TimeInterval = 5

  /// How long the post-resume probe waits for the radio to answer.
  static let wifiResumeProbeTimeout: Duration = .seconds(4)

  /// Checks if the WiFi connection is still alive (call on app foreground)
  public func checkWiFiConnectionHealth() async {
    let suspendedFor = lastBackgroundedAt.map { Date().timeIntervalSince($0) }
    lastBackgroundedAt = nil
    // Runs ahead of `appDidBecomeActive()`, so the attempts below may already ask the radio.
    clearWiFiApprovalGate(reason: "returned to the foreground")

    if wifiReconnectTask != nil {
      // The slow backoff can be minutes from its next attempt; a foreground
      // is the moment to try now, with a fresh fast window.
      if isWiFiReconnectBackingOff, connectionState == .disconnected,
         connectionIntent.wantsConnection {
        logger.info("WiFi reconnect backing off on foreground; retrying now")
        cancelWiFiReconnection()
        connectionState = .connecting
        startWiFiReconnection(ignoringCooldown: true)
        return
      }
      // A fast window is running; let it finish
      logger.info("WiFi reconnection already in progress on foreground")
      return
    }

    // Launch, or a connect the user started, owns the link and handles its own failure;
    // a second connect from here would tear that one down.
    if isExplicitConnectInFlight {
      logger.info("WiFi foreground check standing down: an explicit connect is in flight")
      return
    }

    // Case 1: We think we're connected but the transport died while backgrounded
    if currentTransportType == .wifi,
       connectionState.isOperational,
       let wifiTransport {
      let isConnected = await wifiTransport.isConnected
      if !isConnected {
        logger.info("WiFi connection died while backgrounded")
        await handleWiFiDisconnection(error: nil, transport: wifiTransport)
        return
      }
      // A suspended app reads nothing from its socket, so a radio that went away (or a
      // network that dropped the connection) has not surfaced as an error yet and the
      // transport still reports connected. After more than a moment away, ask the radio.
      if let suspendedFor, suspendedFor > Self.wifiResumeProbeThreshold {
        await probeWiFiLinkAfterResume(transport: wifiTransport, suspendedFor: suspendedFor)
      }
      return
    }

    // Case 2: Connection was lost and cleanup already ran while backgrounded,
    // but user still wants to be connected — attempt fresh reconnection
    if connectionState == .disconnected,
       connectionIntent.wantsConnection {
      // A radio last used over Bluetooth is the Bluetooth health check's to reconnect;
      // trying its WiFi address first here would hold that check off for up to a minute.
      guard let endpoint = await lastRadioWiFiEndpoint(), endpoint.prefersWiFi else { return }
      let (host, port) = (endpoint.host, endpoint.port)
      // Re-check after the fetch: launch or a user connect may have started meanwhile.
      guard connectionState == .disconnected, connectionIntent.wantsConnection, !isExplicitConnectInFlight else { return }
      logger.info("WiFi foreground reconnect to \(host):\(port)")
      do {
        try await connectViaWiFi(host: host, port: port, failsFastOnLocalNetworkPrompt: hasSeenLocalNetworkDenial)
      } catch {
        logger.warning("WiFi foreground reconnect failed: \(error.localizedDescription)")
      }
    }
  }

  /// A saved radio's WiFi addresses, edited from Connections: `adding` goes in (in the place of
  /// `removing` when both are given, which is a change of address), `removing` alone takes one
  /// away. The record is saved, and when it is the radio connected now its live copy follows.
  /// Nothing happens for a record that is gone.
  @discardableResult
  public func updateSavedWiFiAddresses(
    deviceID: UUID,
    adding: ConnectionMethod? = nil,
    removing: ConnectionMethod? = nil
  ) async throws -> DeviceDTO? {
    guard let device = try await persistenceStore.fetchDevice(id: deviceID) else { return nil }
    var methods = device.connectionMethods
    var insertAt = methods.endIndex
    if let removing, let index = methods.firstIndex(where: { $0.id == removing.id }) {
      methods.remove(at: index)
      insertAt = index
    }
    if let adding, adding.isWiFi {
      methods.removeAll { $0.id == adding.id }
      methods.insert(adding, at: min(insertAt, methods.endIndex))
    }
    guard methods != device.connectionMethods else { return device }
    let updated = device.copy { $0.connectionMethods = methods }
    try await persistenceStore.saveDevice(updated)
    if connectedDevice?.id == deviceID { connectedDevice = updated }
    logger.info("WiFi addresses of \(deviceID.uuidString.prefix(8)) now \(methods.filter(\.isWiFi).count)")
    return updated
  }

  /// The last radio's stored WiFi address, and whether it was last used over WiFi (so WiFi is
  /// the transport to reconnect it over). Nil without a last radio, a record, or an address.
  func lastRadioWiFiEndpoint() async -> (host: String, port: UInt16, prefersWiFi: Bool)? {
    guard let lastDeviceID = lastConnectedDeviceID,
          let device = try? await persistenceStore.fetchDevice(id: lastDeviceID),
          let wifiMethod = device.connectionMethods.first(where: { $0.isWiFi }),
          case let .wifi(host, port, _) = wifiMethod else { return nil }
    let prefersWiFi = Self.prefersWiFiAtLaunch(
      lastTransport: lastTransport(forRadio: device.radioID),
      deviceID: device.id,
      publicKey: device.publicKey
    )
    return (host, port, prefersWiFi)
  }

  /// Confirms a WiFi link that survived a suspension still reaches the radio, showing it as
  /// connecting until the radio answers. A link that does not answer is handled as lost.
  private func probeWiFiLinkAfterResume(transport probedTransport: WiFiTransport, suspendedFor: TimeInterval) async {
    guard connectionState == .ready,
          !shouldPauseWiFiHeartbeatProbe,
          let probedSession = session,
          let probedServices = services else { return }
    logger.info("[WiFi] Probing the link after \(Int(suspendedFor))s suspended")
    connectionState = .connecting
    do {
      _ = try await withTimeout(Self.wifiResumeProbeTimeout, operationName: "wifiResumeProbe") {
        try await probedSession.getTime()
      }
      // Restore only the connection that was probed: a disconnect or a reconnect that ran
      // meanwhile has set its own state.
      guard connectionState == .connecting,
            session === probedSession,
            services === probedServices,
            wifiTransport === probedTransport else { return }
      logger.info("[WiFi] Link answered after resume")
      connectionState = .ready
    } catch {
      guard session === probedSession, wifiTransport === probedTransport else { return }
      logger.warning("[WiFi] Link did not answer after resume: \(error.localizedDescription)")
      await handleWiFiDisconnection(error: error, transport: probedTransport)
    }
  }

  // MARK: - Radio Approval (background attempts)

  /// Whether a failed WiFi attempt looks like a radio holding this phone for approval (FRAMEWORK.md
  /// §15.3 on the L2): TCP connected, then APP_START got no answer (a timeout) or the radio closed
  /// the socket (Cancel refuses the address for a while and closes right after accepting). The app
  /// has no explicit signal for either, so this is a heuristic; a hung radio matches too, and is
  /// then left alone until the next foreground, which is the safe direction.
  /// - Parameter transportConnected: TCP was up and APP_START not yet answered when it failed.
  nonisolated static func isRadioApprovalSignature(transportConnected: Bool, error: Error) -> Bool {
    guard transportConnected else { return false }
    switch error {
    case is CancellationError:
      // Superseded by a disconnect or a newer attempt: says nothing about the radio.
      return false
    case is TimeoutError:
      return true
    case let error as MeshCoreError:
      switch error {
      case .timeout, .notConnected, .connectionLost, .sessionNotStarted:
        return true
      default:
        return false
      }
    case let error as WiFiTransportError:
      switch error {
      case .notConnected, .sendFailed, .sendTimeout, .connectionFailed:
        return true
      case .connectionTimeout, .localNetworkDenied, .invalidHost, .invalidPort, .notConfigured:
        return false
      }
    case let error as ConnectionError:
      if case .connectionFailed = error { return true }
      return false
    default:
      return false
    }
  }

  /// Whether the app is in the background for the approval gate. The live application state
  /// comes first: a foreground return runs its WiFi check before the lifecycle transition
  /// records it, and an attempt there may ask the radio because someone can answer.
  func isRunningInBackgroundForApprovalGate() async -> Bool {
    if let appStateProvider {
      return await !appStateProvider.isInForeground
    }
    return await isAppInBackground()
  }

  /// Whether the next background attempt to the current WiFi endpoint should wait for the user.
  func isWiFiAttemptAwaitingApproval() async -> Bool {
    guard backgroundWiFiGate.hasBlockedEndpoints,
          let (host, port) = await wifiTransport?.connectionInfo else { return false }
    guard backgroundWiFiGate.isBlocked(endpoint: BackgroundWiFiApprovalGate.key(host: host, port: port)) else {
      return false
    }
    return await isRunningInBackgroundForApprovalGate()
  }

  /// Whether a failed handshake outlived its own timeouts: TCP gives up after 10 s, APP_START
  /// after 5 s (10 s at most around it), and a radio that closes the socket does so at once. A
  /// failure seen later than this means iOS suspended the app mid-handshake (a background task or
  /// a refresh run ended under it): on the next wake its timeout fires at once, which says
  /// nothing about the radio.
  nonisolated static func handshakeOutlivedItsTimeouts(elapsed: Duration, window: Duration) -> Bool {
    elapsed > window
  }

  /// Records a background attempt that failed the way a radio awaiting approval fails. A
  /// cancelled attempt (a refresh run that ended, a loop that was stopped) and one suspended
  /// mid-handshake are not recorded.
  /// - Parameter handshakeStartedAt: When TCP came up, nil when it never did.
  private func recordWiFiApprovalSignatureIfNeeded(
    host: String,
    port: UInt16,
    transportConnected: Bool,
    handshakeStartedAt: ContinuousClock.Instant?,
    error: Error
  ) async {
    guard !Task.isCancelled,
          Self.isRadioApprovalSignature(transportConnected: transportConnected, error: error),
          await isRunningInBackgroundForApprovalGate() else { return }
    let endpoint = BackgroundWiFiApprovalGate.key(host: host, port: port)
    if let handshakeStartedAt,
       Self.handshakeOutlivedItsTimeouts(elapsed: .now - handshakeStartedAt, window: wifiApprovalHandshakeWindow) {
      backgroundRefreshLogger.info("Approval gate: \(endpoint) not recorded; the handshake failed long after its timeouts (the app was suspended)")
      return
    }
    guard !backgroundWiFiGate.isBlocked(endpoint: endpoint) else { return }
    backgroundWiFiGate.recordUnanswered(endpoint: endpoint)
    backgroundRefreshLogger.info("Approval gate: recorded \(endpoint); background attempts wait for the user")
  }

  /// Lifts the approval gate; logs only when something was blocked.
  func clearWiFiApprovalGate(reason: String) {
    guard backgroundWiFiGate.hasBlockedEndpoints else { return }
    backgroundWiFiGate.clear()
    backgroundRefreshLogger.info("Approval gate: cleared (\(reason))")
  }

  // MARK: - WiFi Connection

  /// How long a connect the user started waits for the radio's first answer: the radio asks its
  /// owner to allow an unknown phone once its screen has been idle 1.5 s, and drops the phone if
  /// nobody answers within 60 s (the firmware's `PENDING_MS`).
  public static let radioApprovalWait: TimeInterval = 60

  /// Connects to a device via WiFi/TCP.
  ///
  /// - Parameters:
  ///   - host: The hostname or IP address of the device
  ///   - port: The TCP port to connect to
  ///   - forceFullSync: When true, performs a complete sync ignoring cached timestamps
  ///   - failsFastOnLocalNetworkPrompt: When true, a connect parked on Local Network access
  ///     fails at once instead of waiting for the prompt (background launches, and access
  ///     already refused). User-initiated connects leave it off so the prompt can be answered.
  ///   - waitsForRadioApproval: When true, the opening handshake waits up to
  ///     ``radioApprovalWait`` for the radio's answer instead of a few seconds. A radio that
  ///     doesn't know this phone holds the connection unread while it asks its owner "Allow app
  ///     over Wi-Fi?", which takes longer than the default wait. Set for connects the user starts
  ///     (adding a radio, connecting a saved one), where someone is at the radio to answer; launch
  ///     and background reconnects keep the short wait and the approval gate.
  /// - Throws: Connection or session errors
  public func connectViaWiFi(
    host: String,
    port: UInt16,
    forceFullSync: Bool = false,
    failsFastOnLocalNetworkPrompt: Bool = false,
    waitsForRadioApproval: Bool = false
  ) async throws {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty else {
      throw WiFiTransportError.invalidHost
    }

    logger.info("Connecting via WiFi to \(host):\(port)")

    // In front, someone is there to answer the radio if it asks to allow this phone.
    if await !isRunningInBackgroundForApprovalGate() {
      clearWiFiApprovalGate(reason: "connect in the foreground")
    }

    // Disconnect existing connection if any
    if connectionState != .disconnected {
      await disconnect(reason: .wifiReconnectPrep)
    }
    // A reconnect loop in its slow backoff sits at .disconnected, so the
    // disconnect above skips it; left running it would tear this connect's
    // session down on its next attempt.
    cancelWiFiReconnection()

    // Claim after the disconnect above, which invalidates attempts. Marking WiFi as the
    // current transport now is what keeps the Bluetooth health check (run on every
    // foreground, including the one after tapping Allow on the Local Network prompt) from
    // reading this connect as a stale Bluetooth link and tearing it down.
    let attempt = beginConnectionAttempt(.wifi)
    let stillOwns = { [unowned self] in ownsConnectionAttempt(attempt) }

    connectionIntent = .wantsConnection()
    persistIntent()
    connectionState = .connecting

    // Create and configure WiFi transport
    let newWiFiTransport = WiFiTransport()
    var newSession: MeshCoreSession?
    var newServices: ServiceContainer?
    var transportConnected = false
    var handshakeStartedAt: ContinuousClock.Instant?

    do {
      await newWiFiTransport.setConnectionInfo(host: host, port: port)
      await newWiFiTransport.setFailsFastOnLocalNetworkPrompt(failsFastOnLocalNetworkPrompt)
      // Wired before connecting: the handler fires only for an established link that
      // drops, and a drop during the handshake or initial sync must reach it.
      await newWiFiTransport.setDisconnectionHandler { [weak self, weak newWiFiTransport] error in
        Task { @MainActor in
          await self?.handleWiFiDisconnection(error: error, transport: newWiFiTransport)
        }
      }
      guard stillOwns() else { throw CancellationError() }
      wifiTransport = newWiFiTransport

      // Connect the transport
      try await newWiFiTransport.connect()
      transportConnected = true
      handshakeStartedAt = .now
      guard stillOwns() else { throw CancellationError() }

      connectionState = .connected

      // Create session (same as BLE)
      let connectSession = MeshCoreSession(transport: newWiFiTransport)
      newSession = connectSession
      session = connectSession

      let (meshCoreSelfInfo, deviceCapabilities) = try await initializeSession(
        connectSession,
        appStartTimeout: waitsForRadioApproval ? Self.radioApprovalWait : nil
      )
      clearWiFiApprovalGate(reason: "the radio answered")
      guard stillOwns() else { throw CancellationError() }
      detectAndStorePlatform(model: deviceCapabilities.model, transportType: .wifi)

      // Derive device ID from public key (WiFi devices don't have Bluetooth UUIDs)
      let deviceID = DeviceIdentity.deriveUUID(from: meshCoreSelfInfo.publicKey)

      let wifiMethod = ConnectionMethod.wifi(host: host, port: port, displayName: nil)
      let (builtServices, radioID) = try await buildServicesAndSaveDevice(
        deviceID: deviceID,
        session: connectSession,
        selfInfo: meshCoreSelfInfo,
        capabilities: deviceCapabilities,
        connectionMethods: [wifiMethod],
        isStillOwner: stillOwns
      )
      newServices = builtServices

      // Persist connection for potential future use
      persistConnection(deviceID: deviceID, radioID: radioID, deviceName: meshCoreSelfInfo.name, transport: .wifi)

      await onConnectionReady?()
      guard stillOwns() else { throw CancellationError() }
      let syncSucceeded = await performInitialSync(radioID: radioID, services: builtServices, transportType: .wifi, forceFullSync: forceFullSync)

      guard await promoteToReady(
        syncSucceeded: syncSucceeded,
        expectedServices: builtServices,
        transportType: .wifi,
        additionalGuard: stillOwns
      ) else {
        await handleSuppressedWiFiPromotion(
          attempt: attempt,
          session: connectSession,
          services: builtServices,
          transport: newWiFiTransport,
          host: host,
          port: port
        )
        return
      }

      endConnectionAttempt(attempt)
      hasSeenLocalNetworkDenial = false
      stopReconnectionWatchdog()
      // A connection promoted to .syncing (initial sync failed, resync running) needs the
      // heartbeat too: it pauses its probes while sync runs and takes over once it ends.
      if connectionState.isOperational {
        startWiFiHeartbeat()
      }
      logger.info("WiFi connection complete - device ready")

    } catch {
      if case WiFiTransportError.localNetworkDenied = error {
        hasSeenLocalNetworkDenial = true
      }
      // An answered APP_START leaves the session's self info behind (a later step failed).
      let awaitingAppStart = if transportConnected {
        await newSession?.currentSelfInfo == nil
      } else {
        false
      }
      await recordWiFiApprovalSignatureIfNeeded(
        host: host,
        port: port,
        transportConnected: awaitingAppStart,
        handshakeStartedAt: handshakeStartedAt,
        error: error
      )
      // Clean up only what this attempt built: by now a newer connect (WiFi or BLE) or a
      // disconnect may own the link, and its session and services must survive.
      if let newSession {
        if session === newSession {
          session = nil
        }
        await newSession.stop(disconnectTransport: false)
      }
      if let newServices {
        if services === newServices {
          services = nil
        }
        await newServices.tearDown()
      }
      await newWiFiTransport.disconnect()
      if wifiTransport === newWiFiTransport {
        wifiTransport = nil
      }
      if ownsConnectionAttempt(attempt) {
        endConnectionAttempt(attempt, clearingTransport: true)
        logger.info("[WiFi] State → .disconnected (connect failed)")
        connectionState = .disconnected
        connectedDevice = nil
        allowedRepeatFreqRanges = []
      }
      throw error
    }
  }

  /// A WiFi connect whose promotion was suppressed. Superseded: drop this attempt's own
  /// session and services and leave the rest to the new owner. Still owned with the user
  /// still wanting the link: it dropped during the initial sync, so the reconnect loop
  /// takes over. Otherwise the user disconnected and `disconnect(reason:)` cleaned up.
  private func handleSuppressedWiFiPromotion(
    attempt: UInt64,
    session attemptSession: MeshCoreSession,
    services attemptServices: ServiceContainer,
    transport attemptTransport: WiFiTransport,
    host: String,
    port: UInt16
  ) async {
    guard ownsConnectionAttempt(attempt) else {
      if session === attemptSession {
        session = nil
      }
      if services === attemptServices {
        services = nil
      }
      await attemptSession.stop(disconnectTransport: false)
      await attemptServices.tearDown()
      if wifiTransport !== attemptTransport {
        await attemptTransport.disconnect()
      }
      return
    }
    endConnectionAttempt(attempt)
    guard connectionIntent.wantsConnection, currentTransportType == .wifi else { return }
    logger.warning("[WiFi] Link dropped during the initial sync; handing it to the reconnect loop")
    await startWiFiRecovery(host: host, port: port)
  }
}
