@preconcurrency import CoreBluetooth
import MeshCore

extension ConnectionManager {
  /// The connection methods recorded for a freshly connected BLE device. Centralized so the
  /// BLE connect and device-switch paths persist an identical `.bluetooth` descriptor rather
  /// than repeating the literal at each call site.
  static func bleConnectionMethods(for deviceID: UUID) -> [ConnectionMethod] {
    [.bluetooth(peripheralUUID: deviceID, displayName: nil)]
  }

  // MARK: - BLE Diagnostics

  /// Returns a best-effort snapshot of the BLE state machine for debug exports.
  public func currentBLEDiagnosticsSummary() async -> String {
    let diagnostics = await stateMachine.linkDiagnostics
    let bleState = diagnostics.centralState
    let blePhase = diagnostics.phase
    let blePeripheralState = diagnostics.peripheralState ?? "none"
    let isConnected = await stateMachine.isConnected
    let isAutoReconnecting = await stateMachine.isAutoReconnecting
    let connectedDeviceShort = await stateMachine.connectedDeviceID?.uuidString.prefix(8) ?? "none"
    let sessionPresent = session != nil
    let servicesPresent = services != nil
    let eventMonitoringActive = services?.isEventMonitoringActive ?? false
    let autoFetchActive: Bool = if let services {
      await services.messagePollingService.isAutoFetching
    } else {
      false
    }
    let activeReconnectDeviceShort = reconnectionCoordinator.reconnectingDeviceID?.uuidString.prefix(8) ?? "none"
    let sessionRebuildDeviceShort = sessionRebuildDeviceID?.uuidString.prefix(8) ?? "none"
    return
      "BLE: state=\(bleState), " +
      "phase=\(blePhase), " +
      "peripheralState=\(blePeripheralState), " +
      "isConnected=\(isConnected), " +
      "isAutoReconnecting=\(isAutoReconnecting), " +
      "connectedDevice=\(connectedDeviceShort), " +
      "sessionPresent=\(sessionPresent), " +
      "servicesPresent=\(servicesPresent), " +
      "eventMonitoringActive=\(eventMonitoringActive), " +
      "autoFetchActive=\(autoFetchActive), " +
      "activeReconnectDevice=\(activeReconnectDeviceShort), " +
      "sessionRebuildDevice=\(sessionRebuildDeviceShort)"
  }

  // MARK: - BLE Device Checks

  /// Checks if a device is connected to the system by another app.
  /// Returns false during auto-reconnect or when the device is already connected by us.
  /// - Parameter deviceID: The UUID of the device to check
  /// - Returns: `true` if device appears connected to another app
  public func isDeviceConnectedToOtherApp(_ deviceID: UUID) async -> Bool {
    let isAutoReconnecting = await stateMachine.isAutoReconnecting
    let smIsConnected = await stateMachine.isConnected
    let smConnectedDeviceID = await stateMachine.connectedDeviceID
    let systemConnected = await stateMachine.isDeviceConnectedToSystem(deviceID)
    let allSystemConnected = await stateMachine.systemConnectedPeripheralIDs()

    logger.info(
      "[OtherAppCheck] device=\(deviceID.uuidString.prefix(8)), " +
        "connectionState=\(String(describing: connectionState)), " +
        "isAutoReconnecting=\(isAutoReconnecting), " +
        "smIsConnected=\(smIsConnected), " +
        "smConnectedDevice=\(smConnectedDeviceID?.uuidString.prefix(8) ?? "nil"), " +
        "isDeviceConnectedToSystem=\(systemConnected), " +
        "allSystemConnectedCount=\(allSystemConnected.count), " +
        "allSystemConnected=\(allSystemConnected.map { String($0.uuidString.prefix(8)) })"
    )

    // Don't check during auto-reconnect - that's our own connection
    guard !isAutoReconnecting else { return false }

    // Don't check if we're already connected (switching devices)
    guard connectionState == .disconnected else { return false }

    // Don't report our own connection as "another app" (state restoration may have completed)
    if smIsConnected, smConnectedDeviceID == deviceID {
      return false
    }

    return systemConnected
  }

  /// True when a system-connected NUS peripheral is this app's radio: last
  /// connected, in-flight ASK pair, or still in the system pairing registry.
  func isOwnedSystemConnectedLink(_ deviceID: UUID) -> Bool {
    if deviceID == lastConnectedDeviceID { return true }
    if isPairingInProgress { return true }
    if pairing.hasSystemPairingRegistry {
      return pairing.isDeviceConnectable(deviceID)
    }
    return false
  }

  /// Attempts to adopt a system-connected BLE link.
  ///
  /// iOS can keep a BLE link alive across app termination (notably after app updates) while state
  /// restoration does not fire for the new process. In that case, CoreBluetooth may report the
  /// radio as system-connected even though our state machine is `.idle`.
  ///
  /// Rather than treating this as "connected elsewhere" and blocking reconnect, we can adopt the
  /// existing link by running the restoration discovery chain against the connected peripheral.
  ///
  /// - Parameter requireLastConnected: Health check and activate pass `true` so they
  ///   only adopt the last radio. User-initiated connect passes `false` after
  ///   `isOwnedSystemConnectedLink`.
  /// - Returns: `true` if an adoption attempt was started.
  func startAdoptingLastSystemConnectedPeripheralIfAvailable(
    deviceID: UUID,
    context: String,
    requireLastConnected: Bool = true
  ) async -> Bool {
    if requireLastConnected {
      guard deviceID == lastConnectedDeviceID else { return false }
    }
    guard currentTransportType == nil || currentTransportType == .bluetooth else { return false }
    guard connectionState == .disconnected else { return false }
    guard connectionIntent.wantsConnection else { return false }

    // Don't interfere with iOS auto-reconnect or an active BLE connection.
    guard await !(stateMachine.isAutoReconnecting) else { return false }
    if await stateMachine.isConnected, await stateMachine.connectedDeviceID == deviceID {
      return false
    }

    // Adoption is only valid from an idle BLE state machine. If restoration or another
    // discovery chain is already in progress, let that flow own the reconnect.
    let diagnostics = await stateMachine.linkDiagnostics
    guard diagnostics.phase == .idle else { return false }
    let blePhase = diagnostics.phase

    // Avoid doing teardown/UI transitions when there is no system-level link.
    guard await stateMachine.isDeviceConnectedToSystem(deviceID) else { return false }

    let bleState = diagnostics.centralState
    let blePeripheralState = diagnostics.peripheralState ?? "none"
    logger.warning(
      "[BLE] \(context): device appears system-connected while disconnected; attempting adoption - " +
        "device=\(deviceID.uuidString.prefix(8)), " +
        "bleState=\(bleState), " +
        "blePhase=\(blePhase), " +
        "blePeripheralState=\(blePeripheralState)"
    )

    // Prepare session layer + UI timeout window before starting adoption.
    await reconnectionCoordinator.handleEnteringAutoReconnect(deviceID: deviceID)

    let started = await stateMachine.startAdoptingSystemConnectedPeripheral(deviceID)
    guard started else {
      logger.warning("[BLE] \(context): startAdoptingSystemConnectedPeripheral returned false after system-connected preflight")
      // Undo UI timeout + state changes so downstream health checks remain accurate.
      reconnectionCoordinator.cancelTimeout()
      reconnectionCoordinator.clearReconnectingDevice()
      if connectionState == .connecting {
        connectionState = .disconnected
      }
      return false
    }

    persistDisconnectDiagnostic(
      "source=\(context).adoptSystemConnectedPeripheral, " +
        "device=\(deviceID.uuidString.prefix(8)), " +
        "bleState=\(bleState), " +
        "blePhase=\(blePhase), " +
        "blePeripheralState=\(blePeripheralState), " +
        "intent=\(connectionIntent)"
    )
    return true
  }

  // MARK: - BLE Scanning

  /// Starts scanning for nearby BLE devices and returns an AsyncStream of `DiscoveredDevice`.
  /// Scanning is orthogonal to the connection lifecycle — works while connected.
  /// Streams open at the same time share the scan, each getting every discovery. Cancel the
  /// consuming task to end its stream; the last one to end stops scanning.
  public func startBLEScanning() -> AsyncStream<DiscoveredDevice> {
    let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self)
    bleScanTask?.cancel()
    bleScanRequestID &+= 1
    let requestID = bleScanRequestID
    let subscribers = bleScanSubscribers
    subscribers.withLock { $0[requestID] = continuation }

    bleScanTask = Task { @MainActor [weak self] in
      guard let self else { return }
      guard !Task.isCancelled, subscribers.withLock({ $0[requestID] != nil }) else { return }

      await stateMachine.setDeviceDiscoveredHandler { @Sendable deviceID, name, rssi in
        let device = DiscoveredDevice(id: deviceID, name: name, rssi: rssi)
        for continuation in subscribers.withLock({ Array($0.values) }) {
          continuation.yield(device)
        }
      }

      guard !Task.isCancelled, subscribers.withLock({ $0[requestID] != nil }) else { return }
      await stateMachine.startScanning()
    }

    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        // Only the last open stream stops the scan; one dropped by stopBLEScanning() is gone already.
        let wasLast = subscribers.withLock { open in
          open.removeValue(forKey: requestID) != nil && open.isEmpty
        }
        guard wasLast else { return }
        self.bleScanTask?.cancel()
        self.bleScanTask = nil
        await self.stateMachine.setDeviceDiscoveredHandler { _, _, _ in }
        // A stream opened meanwhile installed its handler after this one and keeps the scan.
        guard subscribers.withLock({ $0.isEmpty }) else { return }
        await self.stateMachine.stopScanning()
      }
    }

    return stream
  }

  /// Manually stops BLE scanning (the pairing flow runs its own). Streams open now get nothing
  /// more and ending them later does nothing; their consumers start a new one when they want it.
  public func stopBLEScanning() async {
    bleScanSubscribers.withLock { $0.removeAll() }
    bleScanTask?.cancel()
    bleScanTask = nil
    await stateMachine.setDeviceDiscoveredHandler { _, _, _ in }
    await stateMachine.stopScanning()
  }

  // MARK: - Reconnection Watchdog

  /// Starts a watchdog that periodically retries connection when the user wants to be
  /// connected but the device is stuck in disconnected state (e.g., after auto-reconnect failure).
  /// Uses exponential backoff: 30s → 60s → 120s (capped).
  func startReconnectionWatchdog() {
    stopReconnectionWatchdog()

    reconnectionWatchdogGeneration += 1
    let generation = reconnectionWatchdogGeneration
    reconnectionWatchdogTask = Task {
      // Nil the property on every natural exit so "arm if nil" cannot see a
      // finished Task as live. Generation fence avoids nilling a replacement.
      defer {
        if reconnectionWatchdogGeneration == generation {
          reconnectionWatchdogTask = nil
        }
      }

      #if DEBUG
        var delay: Duration = testWatchdogInitialDelay ?? .seconds(30)
      #else
        var delay: Duration = .seconds(30)
      #endif
      let maxDelay: Duration = .seconds(120)

      while !Task.isCancelled {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }

        guard connectionIntent.wantsConnection,
              connectionState == .disconnected else {
          logger.info("[BLE] Watchdog exiting: intent or state changed")
          return
        }

        if await stateMachine.isBluetoothPoweredOff {
          logger.info("[BLE] Watchdog skipping: Bluetooth powered off")
          delay = min(delay * 2, maxDelay)
          continue
        }

        if await stateMachine.isAutoReconnecting {
          logger.info("[BLE] Watchdog skipping: iOS auto-reconnect in progress")
          delay = min(delay * 2, maxDelay)
          continue
        }

        logger.info("[BLE] Watchdog attempting reconnection (delay was \(delay))")
        await checkBLEConnectionHealth()

        delay = min(delay * 2, maxDelay)
      }
    }

    // The watchdog's sleeps only run while the process is awake. In the background, also
    // leave iOS a pending connect so it resumes the app the moment the radio is reachable.
    Task { await ensureWakeSource(context: "watchdog armed") }
  }

  /// Stops the reconnection watchdog
  func stopReconnectionWatchdog() {
    reconnectionWatchdogGeneration += 1
    reconnectionWatchdogTask?.cancel()
    reconnectionWatchdogTask = nil
  }

  // MARK: - BLE Connection Health

  /// Attempts BLE reconnection if user expects to be connected but iOS auto-reconnect gave up.
  /// Called when the app returns to foreground (`appDidBecomeActive`) and from the reconnection
  /// watchdog loop.
  ///
  /// The guards below run as an ordered priority ladder, each ending in an early return so the
  /// first matching situation wins. Order is load-bearing: cheap stand-down checks (wrong
  /// transport, pairing, no intent, reconnect already in flight) come first so the expensive
  /// state-machine queries below them only run when a reconnect is actually warranted; the live
  /// transport check precedes the disconnected paths so an already-healthy link is reconciled
  /// rather than torn down; stale-state cleanup runs before the adopt/other-app/reconnect
  /// strategies so they start from a clean `connectionState`. Reordering can either tear down a
  /// good connection or attempt a redundant reconnect.
  public func checkBLEConnectionHealth() async {
    // Only check BLE connections
    guard currentTransportType == nil || currentTransportType == .bluetooth else { return }

    // The simulator's mock radio has no BLE link to check; treating it as one would read it as
    // stale and tear it down on the next foreground pass.
    if isSimulatorMode, lastConnectedDeviceID == MockDataProvider.simulatorDeviceID { return }

    if shouldDeferOpportunisticReconnect {
      logger.info("[BLE] Foreground health check standing down: pairing in progress")
      return
    }

    // Launch, a user connect, or a device switch owns the link; its own failure handling
    // covers recovery. Reconnecting here would cancel it (connect(to:) replaces an attempt
    // for a different device) or, for the stale-state branch below, tear it down mid-sync.
    if isExplicitConnectInFlight {
      logger.info("[BLE] Foreground health check standing down: an explicit connect is in flight")
      return
    }

    let deviceShort = lastConnectedDeviceID?.uuidString.prefix(8) ?? "none"
    let diagnostics = await stateMachine.linkDiagnostics
    let bleState = diagnostics.centralState
    let blePhase = diagnostics.phase
    logger.info("""
    [BLE] Foreground health check - \
    connectionIntent: \(connectionIntent), \
    lastDevice: \(deviceShort), \
    connectionState: \(String(describing: connectionState)), \
    bleState: \(bleState), \
    blePhase: \(blePhase)
    """)

    // Check if user expects to be connected
    guard connectionIntent.wantsConnection, lastConnectedDeviceID != nil else { return }

    // Any attempt in flight counts, including a fresh connect between its BLE link coming
    // up and its services being installed: a rebuild started then would build a second
    // session over the same transport, and the connect's retry cleanup would kill both.
    if let activeID = activeConnectionAttemptDeviceID {
      logger.info("[BLE] Skipping foreground reconnect: connect/reconnect/session rebuild already in progress for \(activeID.uuidString.prefix(8))")
      return
    }

    // The last radio's Bluetooth peripheral, which differs from its device ID when the
    // radio was last reached over WiFi.
    guard let deviceID = await lastRadioBluetoothPeripheralID() else {
      logger.info("[BLE] Skipping foreground reconnect: the last radio has no Bluetooth method")
      return
    }
    guard connectionIntent.wantsConnection, activeConnectionAttemptDeviceID == nil, !isExplicitConnectInFlight else { return }

    // Check actual BLE state. A live BLE transport is only healthy if the
    // Cairn session, services, and listeners are alive too.
    let bleConnected = await stateMachine.isConnected
    if bleConnected {
      await reconcileConnectedBLEAppStack(deviceID: deviceID)
      return
    }

    // Don't interfere if iOS auto-reconnect is still in progress
    if await stateMachine.isAutoReconnecting {
      logger.info("[BLE] Skipping foreground reconnect: iOS auto-reconnect still in progress")
      return
    }

    // Don't attempt reconnection when Bluetooth is off
    if await stateMachine.isBluetoothPoweredOff {
      logger.info("[BLE] Skipping foreground reconnect: Bluetooth is powered off")
      return
    }

    // Detect stale connection state: app thinks connected but BLE is actually disconnected
    // This happens when iOS terminates the BLE connection while app is suspended
    if connectionState.isConnected {
      logger.warning("[BLE] Detected stale connection state on foreground: connectionState=\(String(describing: connectionState)) but BLE disconnected, triggering cleanup")
      await handleConnectionLoss(deviceID: deviceID, error: nil)
    }

    // If iOS kept a system-level BLE link alive (common across app updates) but our state machine is idle,
    // adopt the existing connection rather than treating it as "connected elsewhere".
    if await startAdoptingLastSystemConnectedPeripheralIfAvailable(
      deviceID: deviceID,
      context: "checkBLEConnectionHealth",
      requireLastConnected: false
    ) {
      return
    }

    // Don't reconnect if device is connected to another app
    if await isDeviceConnectedToOtherApp(deviceID) {
      let blePeripheralState = await stateMachine.linkDiagnostics.peripheralState ?? "none"
      persistDisconnectDiagnostic(
        "source=checkBLEConnectionHealth.otherAppConnected, " +
          "device=\(deviceID.uuidString.prefix(8)), " +
          "bleState=\(bleState), " +
          "blePhase=\(blePhase), " +
          "blePeripheralState=\(blePeripheralState), " +
          "intent=\(connectionIntent)"
      )

      // Ensure retries continue even when this method is called directly
      // (outside appDidBecomeActive's watchdog re-arm path).
      if reconnectionWatchdogTask == nil {
        startReconnectionWatchdog()
      }
      logger.info("[BLE] Skipping foreground reconnect: device connected to another app")
      return
    }

    logger.info("[BLE] Attempting foreground reconnection to \(deviceID.uuidString.prefix(8))")
    await attemptOpportunisticReconnect(deviceID: deviceID, reason: "foreground health check")
  }

  private func reconcileConnectedBLEAppStack(deviceID: UUID) async {
    if await stateMachine.isAutoReconnecting {
      logger.info("[BLE] Skipping connected-transport recovery: iOS auto-reconnect still in progress")
      return
    }

    let bleConnectedDeviceID = await stateMachine.connectedDeviceID
    if let bleConnectedDeviceID, bleConnectedDeviceID != deviceID {
      logger.warning(
        "[BLE] Connected transport belongs to \(bleConnectedDeviceID.uuidString.prefix(8)); expected \(deviceID.uuidString.prefix(8))"
      )
      return
    }

    guard let services,
          session != nil,
          let connectedDevice,
          connectedDevice.id == deviceID else {
      await rebuildConnectedBLEAppStack(deviceID: deviceID)
      return
    }

    guard connectionState.isOperational else {
      logger.info(
        "[BLE] Connected transport app stack present while state is \(String(describing: connectionState)); leaving active connection flow in place"
      )
      return
    }

    await reconcileConnectedBLEListeners(
      services: services,
      radioID: connectedDevice.radioID
    )
  }

  private func rebuildConnectedBLEAppStack(deviceID: UUID) async {
    // Claim before any further await so concurrent health Tasks (watchdog +
    // foreground after preserve) cannot both observe connected and enter rebuild.
    // Same structural single-flight the coordinator retry gap requires. A fresh
    // connect counts too: its link is up before its services are installed.
    guard activeConnectionAttemptDeviceID == nil else {
      logger.info(
        "[BLE] Skipping connected-transport rebuild: connect/reconnect/session rebuild already in progress for \(activeConnectionAttemptDeviceID?.uuidString.prefix(8) ?? "nil")"
      )
      return
    }
    sessionRebuildDeviceID = deviceID
    defer {
      if sessionRebuildDeviceID == deviceID {
        sessionRebuildDeviceID = nil
      }
    }

    logger.warning(
      "[BLE] Connected BLE transport has missing app stack; rebuilding session for \(deviceID.uuidString.prefix(8))"
    )
    connectionState = .connecting

    do {
      try await rebuildSessionForHealthCheck(deviceID: deviceID)
    } catch {
      logger.warning("[BLE] Connected-transport session rebuild failed: \(error.localizedDescription)")
      await handleReconnectionFailure()
    }
  }

  private func rebuildSessionForHealthCheck(deviceID: UUID) async throws {
    #if DEBUG
      if let rebuildSessionForHealthCheckOverride {
        try await rebuildSessionForHealthCheckOverride(deviceID)
        return
      }
    #endif

    try await rebuildSession(deviceID: deviceID)
  }

  private func reconcileConnectedBLEListeners(
    services: ServiceContainer,
    radioID: UUID
  ) async {
    let eventMonitoringActive = services.isEventMonitoringActive
    let autoFetchActive = await services.messagePollingService.isAutoFetching

    guard !eventMonitoringActive || !autoFetchActive else { return }

    logger.warning(
      "[BLE] Connected BLE app stack missing listeners; restarting event pipeline for \(radioID.uuidString.prefix(8))"
    )

    if !eventMonitoringActive {
      await services.startEventMonitoring(radioID: radioID)
    } else {
      await services.messagePollingService.startAutoFetch(radioID: radioID)
    }
  }

  // MARK: - BLE Connection

  /// Connects with retry logic for reconnection scenarios
  /// - Parameter token: The connect attempt's ownership token. Every retry checks it, so a
  ///   switch or a newer connect that claimed the link stops the loop before its cleanup
  ///   can stop the newer session or disconnect the transport it now uses.
  func connectWithRetry(deviceID: UUID, maxAttempts: Int, attempt token: UInt64) async throws {
    var lastError: Error = ConnectionError.connectionFailed("Unknown error")
    let stillOwns = { [unowned self] in connectingDeviceID == deviceID && ownsConnectionAttempt(token) }

    for attempt in 1...maxAttempts {
      guard stillOwns() else { throw CancellationError() }

      do {
        try await performConnection(deviceID: deviceID, attempt: token)

        recordConnectionSuccess()
        if attempt > 1 {
          logger.info("Reconnection succeeded on attempt \(attempt)")
        }
        return

      } catch {
        lastError = error
        guard stillOwns() else { throw error }

        // BLE precondition failures won't resolve between retries.
        // Exit without retrying or tripping the circuit breaker so that
        // onBluetoothPoweredOn can reconnect cleanly when BLE comes back.
        // Auth failures also bypass retry — the bond is bad, the user has to
        // intervene; four sequential auth failures just delays the recovery alert.
        if let bleError = error as? BLEError {
          switch bleError {
          case .bluetoothPoweredOff, .bluetoothUnavailable, .bluetoothUnauthorized:
            throw error
          case .authenticationFailed:
            // The peripheral connected before auth failed, leaving the
            // BLE state machine in a non-idle phase. Tear down before
            // bypassing retries so subsequent connects start fresh.
            await cleanupResources()
            await transport.disconnect()
            throw error
          default:
            break
          }
        }

        // State restoration claimed this radio's link mid-setup (it fails the pending setup
        // before taking over): the restored cycle owns the link and its session rebuild, and
        // disconnecting the transport below would cancel it.
        if await stateMachine.isAutoReconnecting, await stateMachine.connectedDeviceID == deviceID {
          logger.info("[BLE] Connect to \(deviceID.uuidString.prefix(8)) handed to state restoration; not retrying")
          if connectingDeviceID == deviceID { connectingDeviceID = nil }
          return
        }
        guard stillOwns() else { throw error }

        if isDeviceNotFoundError(error) {
          await logDeviceNotFoundDiagnostics(deviceID: deviceID, context: "connectWithRetry attempt \(attempt)")
        }

        // Diagnostic: Log BLE state on each failed attempt
        let diagnostics = await stateMachine.linkDiagnostics
        let blePhase = diagnostics.phase
        let blePeripheralState = diagnostics.peripheralState ?? "none"
        let backoffDelay = attempt < maxAttempts ? 0.3 * pow(2.0, Double(attempt - 1)) : 0.0
        let backoffStr = backoffDelay.formatted(.number.precision(.fractionLength(2)))
        logger.warning(
          "[BLE] Reconnection attempt \(attempt)/\(maxAttempts) failed - error: \(error.localizedDescription), blePhase: \(blePhase), blePeripheralState: \(blePeripheralState), nextBackoff: \(backoffStr)s"
        )

        // Clean up resources but keep state as .connecting
        guard stillOwns() else { throw error }
        await cleanupResources()
        guard stillOwns() else { throw error }
        await transport.disconnect()

        if attempt < maxAttempts {
          // Backoff delay - state remains .connecting
          let baseDelay = 0.3 * pow(2.0, Double(attempt - 1))
          let jitter = Double.random(in: 0...0.1) * baseDelay
          try await Task.sleep(for: .seconds(baseDelay + jitter))
        }
      }
    }

    // All retries exhausted - trip circuit breaker, then throw
    recordConnectionFailure()

    // Diagnostic: Log final failure state
    let finalDiagnostics = await stateMachine.linkDiagnostics
    let finalBlePhase = finalDiagnostics.phase
    let finalBlePeripheralState = finalDiagnostics.peripheralState ?? "none"
    logger.error(
      "[BLE] All \(maxAttempts) reconnection attempts exhausted - lastError: \(lastError.localizedDescription), blePhase: \(finalBlePhase), blePeripheralState: \(finalBlePeripheralState)"
    )

    throw lastError
  }

  /// Performs the actual connection to a device
  /// - Parameter token: The connect attempt's ownership token. Checked after every await:
  ///   once a switch, a newer connect, a disconnect, or the auto-reconnect cycle has taken
  ///   the link, this attempt stops only what it built and throws `CancellationError`,
  ///   leaving the transport to the new owner.
  func performConnection(deviceID: UUID, attempt token: UInt64) async throws {
    // Note: connectionState is already .connecting (set by caller)
    let stillOwns = { [unowned self] in connectingDeviceID == deviceID && ownsConnectionAttempt(token) }

    // Stop any existing session to prevent multiple receive loops racing for transport data
    let staleSession = session
    session = nil
    await staleSession?.stop()
    guard stillOwns() else { throw CancellationError() }

    // Set device ID and connect
    await transport.setDeviceID(deviceID)
    try await transport.connect()
    guard stillOwns() else { throw CancellationError() }

    logger.info("[BLE] State → .connected (transport connected for device: \(deviceID.uuidString.prefix(8)))")
    connectionState = .connected

    // Create session
    let newSession = MeshCoreSession(transport: transport)
    session = newSession

    let (meshCoreSelfInfo, deviceCapabilities) = try await initializeSession(newSession)
    guard stillOwns() else {
      await abandonSupersededConnect(session: newSession)
      throw CancellationError()
    }

    // Session traffic flowed over the encrypted UART link, so the bond is
    // proven healthy as of now. Also marks the app session live for RSSI refresh.
    await recordBondVerification(deviceID: deviceID)

    // Configure BLE write pacing based on device platform
    await configureBLEPacing(for: deviceCapabilities)

    let newServices: ServiceContainer
    let radioID: UUID
    do {
      (newServices, radioID) = try await buildServicesAndSaveDevice(
        deviceID: deviceID,
        session: newSession,
        selfInfo: meshCoreSelfInfo,
        capabilities: deviceCapabilities,
        connectionMethods: Self.bleConnectionMethods(for: deviceID),
        isStillOwner: stillOwns
      )
    } catch {
      if !stillOwns() {
        await abandonSupersededConnect(session: newSession)
      }
      throw error
    }

    // Persist connection for auto-reconnect
    persistConnection(deviceID: deviceID, radioID: radioID, deviceName: meshCoreSelfInfo.name, transport: .bluetooth)

    // Notify observers before sync starts so they can wire callbacks
    // (e.g., AppState needs to set sync activity callbacks for the syncing pill)
    await onConnectionReady?()
    guard stillOwns() else {
      await abandonSupersededConnect(session: newSession, services: newServices)
      throw CancellationError()
    }
    let shouldForceFullSync: Bool
    if case let .wantsConnection(force) = connectionIntent {
      shouldForceFullSync = force
      if force { connectionIntent = .wantsConnection() }
    } else {
      shouldForceFullSync = false
    }
    let syncSucceeded = await performInitialSync(radioID: radioID, services: newServices, forceFullSync: shouldForceFullSync)

    guard await promoteToReady(
      syncSucceeded: syncSucceeded,
      expectedServices: newServices,
      transportType: .bluetooth,
      additionalGuard: stillOwns
    ) else {
      // A released or superseded claim means the link now belongs to the
      // auto-reconnect cycle or a newer connect; disconnecting the transport
      // here would cancel the OS pending connect recovering it.
      if stillOwns() {
        await newSession.stop()
      } else {
        await abandonSupersededConnect(session: newSession, services: newServices)
      }
      return
    }

    stopReconnectionWatchdog()
    logger.info("Connection complete - device ready")
  }

  /// Stops what a superseded BLE connect built, without disconnecting the transport the new
  /// owner is using, and clears the stored references only while they are still this
  /// attempt's.
  private func abandonSupersededConnect(session attemptSession: MeshCoreSession, services attemptServices: ServiceContainer? = nil) async {
    logger.info("[BLE] Connect superseded; stopping its session without touching the transport")
    if session === attemptSession {
      session = nil
    }
    if let attemptServices, services === attemptServices {
      services = nil
    }
    await attemptSession.stop(disconnectTransport: false)
    await attemptServices?.tearDown()
  }

  // MARK: - BLE Diagnostics Helpers

  func logDeviceNotFoundDiagnostics(deviceID: UUID, context: String) async {
    let diagnostics = await stateMachine.linkDiagnostics
    let bleState = diagnostics.centralState
    let blePhase = diagnostics.phase
    let lastDeviceShort = lastConnectedDeviceID?.uuidString.prefix(8) ?? "none"
    let registeredDevices = pairing.registeredDeviceInfos()
    let pairedSummary = registeredDevices.prefix(5).map { info in
      "\(info.name)(\(info.id.uuidString.prefix(8)))"
    }
    let pairedSummaryText = pairedSummary.isEmpty ? "none" : pairedSummary.joined(separator: ", ")

    logger.warning(
      // swiftlint:disable:next line_length
      "[BLE] Device not found diagnostics (\(context)) - device: \(deviceID.uuidString.prefix(8)), lastDevice: \(lastDeviceShort), connectionIntent: \(connectionIntent), bleState: \(bleState), blePhase: \(blePhase), pairingSessionActive: \(pairing.isSessionActive), pairedCount: \(registeredDevices.count), paired: \(pairedSummaryText)"
    )
  }

  func isDeviceNotFoundError(_ error: Error) -> Bool {
    if case ConnectionError.deviceNotFound = error { return true }
    if case BLEError.deviceNotFound = error { return true }
    return false
  }

  // MARK: - Connection Loss Handling

  /// Handles unexpected connection loss
  func handleConnectionLoss(deviceID: UUID, error: Error?) async {
    // The radio is on WiFi (connected, connecting, or reconnecting there): a Bluetooth loss
    // concerns a link the app no longer uses, and handling it would tear the WiFi session down.
    if currentTransportType == .wifi {
      logger.info("[BLE] Ignoring BLE connection loss for \(deviceID.uuidString.prefix(8)): the radio is on WiFi")
      return
    }

    // Don't clobber a newer connection attempt
    if connectionState == .connecting {
      let activeID = connectingDeviceID ?? reconnectionCoordinator.reconnectingDeviceID
      if let activeID, activeID != deviceID {
        logger.info("[BLE] Ignoring connection loss for \(deviceID.uuidString.prefix(8)) — connecting to \(activeID.uuidString.prefix(8))")
        return
      }
    }

    let stateBeforeLoss = connectionState
    var errorInfo = "none"
    if let error = error as NSError? {
      errorInfo = "domain=\(error.domain), code=\(error.code), desc=\(error.localizedDescription)"
    }
    logger.warning("[BLE] Connection lost: \(deviceID.uuidString.prefix(8)), currentState: \(String(describing: connectionState)), error: \(errorInfo)")

    // Cancel any pending auto-reconnect timeout and clear device identity
    reconnectionCoordinator.cancelTimeout()
    reconnectionCoordinator.clearReconnectingDevice()

    cancelResyncLoop()

    // Capture and clear synchronously, mirroring teardownSessionForReconnect:
    // a same-device rebuild can install a new container during the awaits
    // below, and re-reading self.services would tear that new container down.
    let oldServices = services
    services = nil
    session = nil

    logger.warning("[BLE] State → .disconnected (connection loss for device: \(deviceID.uuidString.prefix(8)))")
    connectionState = .disconnected
    if connectingDeviceID == deviceID { connectingDeviceID = nil }
    connectedDevice = nil
    allowedRepeatFreqRanges = []

    if let oldServices {
      // Mark room sessions disconnected before tearing down services
      _ = await oldServices.remoteNodeService.handleBLEDisconnection()
      await oldServices.tearDown()
      // Reset sync state to prevent stuck "Syncing" pill
      await oldServices.syncCoordinator.onDisconnected(notificationService: oldServices.notificationService)
    }

    persistDisconnectDiagnostic(
      "source=handleConnectionLoss, " +
        "device=\(deviceID.uuidString.prefix(8)), " +
        "stateBefore=\(String(describing: stateBeforeLoss)), " +
        "error=\(errorInfo), " +
        "intent=\(connectionIntent)"
    )

    // Keep transport reference for iOS auto-reconnect to use

    // Notify UI layer of connection loss
    await onConnectionLost?()

    // An invalidated bond can't heal through auto-reconnect or the watchdog;
    // surface the guided pairing-failure recovery instead of retrying silently.
    if let error, case BLEError.authenticationFailed = error {
      surfaceAuthenticationFailure(deviceID: deviceID)
    }

    // iOS auto-reconnect handles normal disconnects via reconnectionCoordinator
    // Bluetooth power-cycle handled via onBluetoothPoweredOn callback
    // Watchdog provides fallback retry if both fail; in the background it also arms a pending
    // connect (ensureWakeSource), except after a bond failure the user has to resolve.
    if connectionIntent.wantsConnection {
      startReconnectionWatchdog()
    }
  }

  /// Publishes user-actionable Bluetooth availability for the pickers and logs the change.
  /// Disconnect logic is not duplicated here — BLEStateMachine already handles
  /// `.poweredOff` via `cancelCurrentOperation` which fires `onDisconnection`.
  func handleBluetoothStateChange(_ state: CBManagerState) {
    let stateName = switch state {
    case .unknown: "unknown"
    case .resetting: "resetting"
    case .unsupported: "unsupported"
    case .unauthorized: "unauthorized"
    case .poweredOff: "poweredOff"
    case .poweredOn: "poweredOn"
    @unknown default: "unknown(\(state.rawValue))"
    }
    bluetoothAvailability = Self.bluetoothAvailability(for: state)
    logger.info("[BLE] Bluetooth state changed: \(stateName), connectionState: \(String(describing: connectionState)), connectionIntent: \(connectionIntent)")

    // Nothing reaches the radio while Bluetooth is off: tell a backgrounded user now, rather than
    // only when the "may not be receiving" reminder fires.
    if let listeningReminder, connectionIntent.wantsConnection, currentTransportType != .wifi {
      switch state {
      case .poweredOff:
        let deviceName = lastConnectedDeviceName
        Task { await listeningReminder.bluetoothPoweredOff(deviceName: deviceName) }
      case .poweredOn:
        listeningReminder.bluetoothPoweredOn()
      default:
        break
      }
    }
  }

  /// Maps a raw `CBManagerState` to the user-actionable availability the pickers display. Only the
  /// two states a person can resolve get a distinct case; transient and unsupported states stay
  /// `.ready` so the picker keeps scanning rather than offering a remedy that does nothing.
  private static func bluetoothAvailability(for state: CBManagerState) -> BluetoothAvailability {
    switch state {
    case .poweredOff: .poweredOff
    case .unauthorized: .unauthorized
    default: .ready
    }
  }
}
