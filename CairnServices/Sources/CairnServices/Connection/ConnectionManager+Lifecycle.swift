import Foundation
import MeshCore

public extension ConnectionManager {
  internal var activeConnectionAttemptDeviceID: UUID? {
    connectingDeviceID ?? sessionRebuildDeviceID ?? reconnectionCoordinator.reconnectingDeviceID
  }

  internal var activeReconnectDeviceID: UUID? {
    sessionRebuildDeviceID ?? reconnectionCoordinator.reconnectingDeviceID
  }

  // MARK: - App Lifecycle

  /// Called when the app enters background. Pauses foreground-only BLE operations.
  func appDidEnterBackground() async {
    let transportName = switch currentTransportType {
    case .bluetooth: "bluetooth"
    case .wifi: "wifi"
    case nil: "none"
    }
    logger.info(
      "[BLE] Lifecycle transition: entering background, " +
        "transport: \(transportName), " +
        "connectionIntent: \(connectionIntent), " +
        "connectionState: \(String(describing: connectionState))"
    )
    lastBackgroundedAt = Date()
    lifecycleIsBackground = true
    AppActivity.isBackground = true
    await stateMachine.appDidEnterBackground()
    // The watchdog's sleeps do not run while the app is suspended; a pending connect does.
    stopReconnectionWatchdog()
    await ensureWakeSource(context: "entering background")
    await listeningReminder?.appEnteredBackground(
      wantsConnection: connectionIntent.wantsConnection,
      deviceName: lastConnectedDeviceName
    )
    let diagnostics = await stateMachine.linkDiagnostics
    let bleState = diagnostics.centralState
    let blePhase = diagnostics.phase
    logger.info(
      "[BLE] Lifecycle transition complete: backgrounded, " +
        "bleState: \(bleState), " +
        "blePhase: \(blePhase)"
    )
  }

  /// Called when the app becomes active. Reconciles BLE state and restarts
  /// foreground operations.
  func appDidBecomeActive() async {
    let transportName = switch currentTransportType {
    case .bluetooth: "bluetooth"
    case .wifi: "wifi"
    case nil: "none"
    }
    logger.info(
      "[BLE] Lifecycle transition: becoming active, " +
        "transport: \(transportName), " +
        "connectionIntent: \(connectionIntent), " +
        "connectionState: \(String(describing: connectionState))"
    )
    lifecycleIsBackground = false
    AppActivity.isBackground = false
    // Someone is there to answer the radio if it asks to allow this phone.
    clearWiFiApprovalGate(reason: "app became active")
    // The foreground owns recovery again (health check, watchdog): the background backoffs start over.
    backgroundResyncFailedLoops = 0
    backgroundRebuildFailures = 0
    lastBackgroundRebuildFailureAt = nil
    await listeningReminder?.appBecameActive()
    await stateMachine.appDidBecomeActive()
    await checkBLEConnectionHealth()
    let diagnostics = await stateMachine.linkDiagnostics
    let bleState = diagnostics.centralState
    let blePhase = diagnostics.phase
    logger.info(
      "[BLE] Lifecycle transition complete: active health check finished, " +
        "connectionState: \(String(describing: connectionState)), " +
        "bleState: \(bleState), " +
        "blePhase: \(blePhase)"
    )

    guard currentTransportType == nil || currentTransportType == .bluetooth else { return }
    guard connectionIntent.wantsConnection, connectionState == .disconnected else { return }

    if shouldDeferOpportunisticReconnect {
      logger.info("[BLE] ConnectionManager: not re-arming watchdog on foreground (pairing in progress)")
      return
    }

    // A WiFi connect in flight marks its transport, which the guard above already reads;
    // this covers launch and a user connect whose claim the watchdog would race.
    if isExplicitConnectInFlight {
      logger.info("[BLE] ConnectionManager: not re-arming watchdog on foreground (explicit connect in flight)")
      return
    }

    if await stateMachine.isAutoReconnecting {
      logger.info("[BLE] ConnectionManager: not re-arming watchdog on foreground (iOS auto-reconnect in progress)")
      return
    }

    startReconnectionWatchdog()
    logger.info("[BLE] ConnectionManager: re-armed watchdog on foreground while disconnected")
  }

  // MARK: - Sync Health

  /// Triggers resync if connected but sync state is failed.
  /// Called when app returns to foreground.
  func checkSyncHealth() async {
    guard connectionState.isOperational,
          connectionIntent.wantsConnection,
          let services,
          let radioID = connectedDevice?.radioID else { return }

    let syncCoordinator = services.syncCoordinator
    let syncState = syncCoordinator.state
    guard case .failed = syncState else { return }

    guard resyncTask == nil else {
      logger.info("Resync loop already running, skipping foreground trigger")
      return
    }

    logger.info("Foreground return: sync state is failed, starting resync loop")
    startResyncLoop(radioID: radioID, services: services, transportType: currentTransportType ?? .bluetooth)
  }

  // MARK: - Activation

  /// Activates the connection manager on app launch.
  /// Call this once during app initialization.
  ///
  /// Awaits only the wiring: lifecycle handlers, the pairing session, and the Bluetooth
  /// central. The reconnect to the last radio runs detached in `launchReconnectTask`, so
  /// launch (notification taps, deep links, CarPlay) never waits on a connect and initial
  /// sync that can take a minute.
  func activate() async {
    launchActivationStarted = true
    // Until the reconnect below is handed to its task, launch owns the first attempt.
    isAwaitingLaunchActivation = true
    defer { isAwaitingLaunchActivation = false }

    // Ensure lifecycle handlers are installed before anything below can
    // construct the CBCentralManager; creating the central can fire
    // restoration callbacks synchronously, and a missed handler would
    // strand the restored link without a session rebuild.
    await wireTransportHandlers()

    let lastDeviceShort = lastConnectedDeviceID?.uuidString.prefix(8) ?? "none"
    let bleState = await stateMachine.linkDiagnostics.centralState
    logger.info("""
    Activating ConnectionManager - \
    connectionIntent: \(connectionIntent), \
    lastConnectedDeviceID: \(lastDeviceShort), \
    connectionState: \(String(describing: connectionState)), \
    bleState: \(bleState)
    """)

    // Reset stale room session connections from previous app launch
    try? await persistenceStore.resetAllRemoteNodeSessionConnections()

    #if targetEnvironment(simulator)
      // Skip auto-reconnect if user explicitly disconnected
      if connectionIntent.isUserDisconnected {
        logger.info("Simulator: skipping auto-reconnect - user previously disconnected")
        return
      }
      guard connectsOnLaunch else {
        logger.info("Simulator: skipping auto-reconnect - Connect on Launch is off")
        return
      }
      // On simulator, skip ASK entirely and auto-reconnect to simulator device
      if let lastDeviceID = lastConnectedDeviceID,
         lastDeviceID == MockDataProvider.simulatorDeviceID {
        logger.info("Simulator: auto-reconnecting to mock device")
        connectionIntent = .wantsConnection()
        do {
          try await simulatorConnect()
        } catch {
          logger.warning("Simulator auto-reconnect failed: \(error.localizedDescription)")
        }
        return
      }
      // Simulator doesn't support real BLE devices - show connection UI for simulator pairing
      return
    #else
      // Activate the pairing session early; on iOS this is AccessorySetupKit, required for
      // ASK events and iOS 26 state restoration. On macOS this is a no-op. Failure is
      // logged inside: WiFi doesn't need the pairing session.
      await activatePairingSession()

      // Skip auto-reconnect if user explicitly disconnected
      if connectionIntent.isUserDisconnected {
        logger.info("Skipping auto-reconnect: user previously disconnected")
        return
      }

      // Off in Settings › Connections: the radio waits for a tap (the disconnected pill, or a
      // row in Connections). The central still comes up on the first connect.
      guard connectsOnLaunch else {
        logger.info("Skipping auto-reconnect: Connect on Launch is off")
        return
      }

      guard let lastDeviceID = lastConnectedDeviceID else {
        logger.info("No last connected device - skipping auto-reconnect")
        return
      }
      logger.info("Attempting auto-reconnect to last device: \(lastDeviceID)")

      // Set intent before checking state
      connectionIntent = .wantsConnection()

      // Create the central before deciding anything, whichever transport goes first: state
      // restoration reaches only a central that exists, and a WiFi attempt can take a minute.
      // Must be after: ASK activation, explicit disconnect guard.
      // Must be before: isAutoReconnecting check, isDeviceConnectedToSystem.
      await stateMachine.activate()

      launchReconnectTask = Task { [weak self] in
        guard let self else { return }
        await runLaunchReconnect(lastDeviceID: lastDeviceID)
        launchReconnectTask = nil
      }
    #endif
  }

  /// The reconnect to the last radio that `activate()` starts. Tries the transport the radio
  /// last connected over first: the old order (WiFi whenever the radio had an address)
  /// delayed a Bluetooth radio by up to a minute, and once WiFi had been used the Bluetooth
  /// fallback reached for a key-derived ID CoreBluetooth cannot resolve.
  func runLaunchReconnect(lastDeviceID: UUID) async {
    // A restoration claim or a connect the user started meanwhile owns the link.
    guard connectionIntent.wantsConnection,
          connectionState == .disconnected,
          activeConnectionAttemptDeviceID == nil,
          connectionAttemptTransport == nil else {
      logger.info("Launch reconnect standing down: the link is already owned (state: \(String(describing: connectionState)))")
      return
    }

    let device = try? await persistenceStore.fetchDevice(id: lastDeviceID)
    // every address the radio was saved with, the one used last first: each is tried in turn
    var wifiEndpoints: [(host: String, port: UInt16)] = []
    for case let .wifi(host, port, _) in device?.connectionMethods ?? [] {
      wifiEndpoints.append((host, port))
    }
    let wifiEndpoint = wifiEndpoints.first
    let bluetoothID: UUID? = if let device, !device.connectionMethods.isEmpty {
      device.connectionMethods.compactMap(\.bluetoothPeripheralID).first
    } else {
      lastDeviceID
    }
    let prefersWiFi = Self.prefersWiFiAtLaunch(
      lastTransport: device.flatMap { lastTransport(forRadio: $0.radioID) },
      deviceID: lastDeviceID,
      publicKey: device?.publicKey
    )
    logger.info(
      "Launch reconnect order: \(prefersWiFi ? "WiFi first" : "Bluetooth first"), " +
        "wifi: \(wifiEndpoint != nil), bluetooth: \(bluetoothID?.uuidString.prefix(8) ?? "none")"
    )

    if let wifiEndpoint, prefersWiFi || bluetoothID == nil {
      // A restored BLE link to the radio wins over a WiFi attempt: iOS relaunched the app
      // for it, or kept it across the update.
      if await stateMachine.isAutoReconnecting {
        logger.info("Launch reconnect: BLE state restoration in progress; leaving WiFi alone")
        return
      }
      for endpoint in wifiEndpoints {
        if await connectLaunchWiFi(host: endpoint.host, port: endpoint.port) { return }
        guard isLaunchReconnectStillWanted else { return }
      }
      if let bluetoothID, await reconnectLaunchBLE(deviceID: bluetoothID, armsWatchdog: false) { return }
      guard isLaunchReconnectStillWanted else { return }
      // The radio was last on WiFi: keep retrying it there, as a dropped link would.
      await startWiFiRecovery(host: wifiEndpoint.host, port: wifiEndpoint.port)
      return
    }

    guard let bluetoothID else {
      logger.info("Launch reconnect: the last radio has no Bluetooth or WiFi method to reach it by")
      return
    }
    _ = await reconnectLaunchBLE(deviceID: bluetoothID, armsWatchdog: true)
  }

  /// Whether the launch reconnect should go on after a failed attempt: nothing else claimed
  /// the link meanwhile and the user still wants it.
  private var isLaunchReconnectStillWanted: Bool {
    connectionIntent.wantsConnection
      && connectionState == .disconnected
      && connectingDeviceID == nil
      && connectionAttemptTransport == nil
      && activeConnectionAttemptDeviceID == nil
  }

  /// Whether launch should try WiFi before Bluetooth. The radio's recorded transport decides;
  /// for a radio connected before that was recorded, a record whose ID derives from the key
  /// was last saved over WiFi (a Bluetooth connect stores the peripheral's ID instead).
  static func prefersWiFiAtLaunch(lastTransport: TransportType?, deviceID: UUID, publicKey: Data?) -> Bool {
    switch lastTransport {
    case .wifi: true
    case .bluetooth: false
    case nil: publicKey.map { DeviceIdentity.deriveUUID(from: $0) == deviceID } ?? false
    }
  }

  /// The launch's WiFi attempt. In the background no Local Network prompt can show, and one
  /// already refused stays refused, so either case fails fast instead of waiting a minute. A
  /// background launch also leaves a radio that is waiting for someone to allow this phone
  /// alone (`BackgroundWiFiApprovalGate`).
  private func connectLaunchWiFi(host: String, port: UInt16) async -> Bool {
    let inForeground = await appStateProvider?.isInForeground ?? true
    if !inForeground, backgroundWiFiGate.isBlocked(endpoint: BackgroundWiFiApprovalGate.key(host: host, port: port)) {
      logger.info("WiFi auto-reconnect skipped in the background: \(host):\(port) is waiting for approval")
      return false
    }
    logger.info("Auto-reconnecting via WiFi to \(host):\(port)")
    do {
      try await connectViaWiFi(
        host: host,
        port: port,
        failsFastOnLocalNetworkPrompt: hasSeenLocalNetworkDenial || !inForeground
      )
      return true
    } catch {
      logger.warning("WiFi auto-reconnect failed: \(error.localizedDescription)")
      return false
    }
  }

  /// The launch's Bluetooth reconnect to `deviceID`: defers to state restoration or an
  /// adoptable system link, skips a radio another app holds, otherwise connects.
  /// - Parameter armsWatchdog: Whether a failure arms the Bluetooth watchdog. Off when WiFi
  ///   is the radio's transport and its own reconnect loop takes over.
  /// - Returns: `true` when the link is connected or owned by a restoration or adoption.
  private func reconnectLaunchBLE(deviceID: UUID, armsWatchdog: Bool) async -> Bool {
    // If state machine is already auto-reconnecting (from state restoration),
    // let it complete rather than fighting with it
    if await stateMachine.isAutoReconnecting {
      let diagnostics = await stateMachine.linkDiagnostics
      let blePhase = diagnostics.phase
      let blePeripheralState = diagnostics.peripheralState ?? "none"
      logger.info(
        "State restoration in progress - blePhase: \(blePhase), blePeripheralState: \(blePeripheralState), waiting for auto-reconnect"
      )
      return true
    }

    if await stateMachine.isConnected, await stateMachine.connectedDeviceID == deviceID {
      logger.info("State restoration complete - device already connected, waiting for session setup")
      return true
    }

    // If iOS kept the BLE link alive (common across app updates) but restoration didn't fire,
    // adopt the system-connected peripheral rather than treating it as "connected elsewhere".
    // The ID was resolved from the last radio, which may not equal its last device ID.
    if await startAdoptingLastSystemConnectedPeripheralIfAvailable(
      deviceID: deviceID,
      context: "activate",
      requireLastConnected: false
    ) {
      return true
    }

    // Check if device is connected to another app before auto-reconnect
    // Silently skip per HIG: minimize interruptions on app launch
    if await isDeviceConnectedToOtherApp(deviceID) {
      logger.info("Auto-reconnect skipped: device connected to another app")
      let diagnostics = await stateMachine.linkDiagnostics
      let bleState = diagnostics.centralState
      let blePhase = diagnostics.phase
      let blePeripheralState = diagnostics.peripheralState ?? "none"
      persistDisconnectDiagnostic(
        "source=activate.autoReconnectSkippedOtherApp, " +
          "device=\(deviceID.uuidString.prefix(8)), " +
          "bleState=\(bleState), " +
          "blePhase=\(blePhase), " +
          "blePeripheralState=\(blePeripheralState), " +
          "intent=\(connectionIntent)"
      )

      // Keep intent so we can retry on foreground/watchdog, but avoid
      // fighting another app's connection on launch.
      if armsWatchdog {
        startReconnectionWatchdog()
      }
      return false
    }

    do {
      try await connect(to: deviceID)
      return true
    } catch {
      logger.warning("Auto-reconnect failed: \(error.localizedDescription)")
      let diagnostics = await stateMachine.linkDiagnostics
      let bleState = diagnostics.centralState
      let blePhase = diagnostics.phase
      let blePeripheralState = diagnostics.peripheralState ?? "none"
      persistDisconnectDiagnostic(
        "source=activate.autoReconnectFailed, " +
          "device=\(deviceID.uuidString.prefix(8)), " +
          "bleState=\(bleState), " +
          "blePhase=\(blePhase), " +
          "blePeripheralState=\(blePeripheralState), " +
          "error=\(error.localizedDescription), " +
          "intent=\(connectionIntent)"
      )
      // A setup-phase auth failure arrives here as a thrown error and never
      // fires onDisconnection, so surface the guided recovery now rather than
      // waiting for the watchdog's first tick. The latch keeps the watchdog
      // from re-presenting it.
      if case BLEError.authenticationFailed = error {
        surfaceAuthenticationFailure(deviceID: deviceID)
      }
      // Don't propagate - auto-reconnect failure is not fatal
      if armsWatchdog, connectionIntent.wantsConnection {
        startReconnectionWatchdog()
      }
      return false
    }
  }

  // MARK: - Connection

  /// Connects to a previously paired device.
  ///
  /// This method handles all connection scenarios:
  /// - If disconnected: connects to the device
  /// - If already connected to this device: no-op
  /// - If connected to a different device: switches to the new device
  ///
  /// - Parameters:
  ///   - deviceID: The UUID of the device to connect to
  ///   - forceFullSync: Whether to force a full sync instead of incremental
  ///   - forceReconnect: When `true`, marks the connect as user-initiated: it bypasses the
  ///     circuit breaker, and on a platform without a system pairing registry (macOS) it also
  ///     bounds the retry budget to `unverifiedConnectAttempts`, so a tap on an out-of-range
  ///     radio fails fast instead of hanging the full budget. Background reconnects pass
  ///     `false` to keep the full budget for unattended recovery.
  /// - Throws: Connection errors
  func connect(to deviceID: UUID, forceFullSync: Bool = false, forceReconnect: Bool = false) async throws {
    // Honor cancellation before any state mutation. Without this checkpoint
    // a cancelled `pairNewDevice` task whose preceding awaits all swallowed
    // cancellation would still drive a real BLE connect to completion.
    try Task.checkCancellation()

    // Circuit breaker: prevent rapid reconnection loops after repeated failures
    guard shouldAllowConnection(force: forceReconnect) else {
      logger.info("[BLE] Circuit breaker open, rejecting connection to \(deviceID.uuidString.prefix(8))")
      throw BLEError.connectionFailed("Connection blocked by circuit breaker (cooling down)")
    }

    if activeReconnectDeviceID == deviceID {
      if forceReconnect, connectionState == .disconnected, sessionRebuildDeviceID != deviceID {
        await abandonStuckReconnect(deviceID: deviceID)
      } else {
        connectionIntent = .wantsConnection(forceFullSync: forceFullSync)
        persistIntent()
        if sessionRebuildDeviceID != deviceID {
          reconnectionCoordinator.restartTimeout(deviceID: deviceID)
        }
        logger.info("[BLE] Reconnect already in progress for \(deviceID.uuidString.prefix(8)), deferring duplicate connect request")
        return
      }
    }

    // Prevent concurrent connection attempts
    if connectionState == .connecting {
      let currentDeviceID = activeConnectionAttemptDeviceID

      if currentDeviceID == deviceID {
        if connectingDeviceID == nil {
          // Auto-reconnect same device — refresh UI timeout
          connectionIntent = .wantsConnection(forceFullSync: forceFullSync)
          persistIntent()
          reconnectionCoordinator.restartTimeout(deviceID: deviceID)
        }
        logger.info("Connection already in progress for \(deviceID.uuidString.prefix(8)), ignoring")
        return
      }

      // Different device — cancel current and fall through
      logger.info("Cancelling connection to \(currentDeviceID?.uuidString.prefix(8) ?? "unknown") to connect to \(deviceID.uuidString.prefix(8))")
      connectingDeviceID = nil
      // The cancelled attempt must find, after its next await, that it no longer owns the
      // link, so it stands down instead of retrying over the transport torn down below.
      invalidateConnectionAttempt()
      reconnectionCoordinator.cancelTimeout()
      reconnectionCoordinator.clearReconnectingDevice()
      cancelResyncLoop()
      stopReconnectionWatchdog()
      await releaseWiFiForBLEConnect()
      await cleanupResources()
      await transport.disconnect()
      connectionState = .disconnected
    }

    // Handle already-connected cases
    if connectionState != .disconnected {
      if connectedDevice?.id == deviceID {
        logger.info("Already connected to device: \(deviceID)")
        return
      }
      // Connected to different device - switch to new one
      logger.info("Switching from current device to: \(deviceID)")
      try await switchDevice(to: deviceID)
      return
    }

    // Claim the attempt before the pre-connect awaits below. Two connect
    // calls interleaving at those suspension points would otherwise both
    // pass the guards above and build duplicate sessions over one
    // transport. The newest claim wins; a superseded call observes the
    // mismatch after each await and bails.
    if connectingDeviceID == deviceID {
      logger.info("Connection already claimed for \(deviceID.uuidString.prefix(8)), ignoring")
      return
    }
    connectingDeviceID = deviceID
    let attempt = beginConnectionAttempt(.bluetooth)
    let stillOwns = { [unowned self] in connectingDeviceID == deviceID && ownsConnectionAttempt(attempt) }
    // Every exit that still owns the attempt releases it; a failed one (state back at
    // .disconnected) also drops the Bluetooth mark set by the claim. A superseded
    // attempt leaves both to whoever took over.
    defer {
      if ownsConnectionAttempt(attempt) {
        if connectingDeviceID == deviceID { connectingDeviceID = nil }
        endConnectionAttempt(attempt, clearingTransport: connectionState == .disconnected)
      }
    }

    // A WiFi reconnect loop in its slow backoff sits at .disconnected, so none
    // of the paths above stood it down; left running it would stop this BLE
    // session on its next attempt.
    if wifiReconnectTask != nil || wifiTransport != nil {
      await releaseWiFiForBLEConnect()
      guard stillOwns() else { throw CancellationError() }
    }

    // Handle state restoration auto-reconnect
    let transportAutoReconnecting = await stateMachine.isAutoReconnecting
    guard stillOwns() else { throw CancellationError() }
    if transportAutoReconnecting {
      let restoringDeviceID = await stateMachine.connectedDeviceID
      let diagnostics = await stateMachine.linkDiagnostics
      let blePhase = diagnostics.phase
      let blePeripheralState = diagnostics.peripheralState ?? "none"
      guard stillOwns() else { throw CancellationError() }

      if restoringDeviceID != deviceID {
        logger.info("Cancelling state restoration auto-reconnect to \(restoringDeviceID?.uuidString ?? "unknown") to connect to \(deviceID)")
        await transport.disconnect()
        guard stillOwns() else { throw CancellationError() }
      } else if forceReconnect, connectionState == .disconnected {
        // Reached when the coordinator's reconnect cycle was already cleared while
        // the state machine itself is still mid auto-reconnect for this device.
        await abandonStuckReconnect(
          deviceID: deviceID,
          detail: " - blePhase: \(blePhase), blePeripheralState: \(blePeripheralState)"
        )
        guard stillOwns() else { throw CancellationError() }
      } else {
        // Same device - let auto-reconnect complete instead of racing with it.
        // The reconnection handler will create the session when auto-reconnect succeeds.
        // Release the claim: the reconnect cycle owns identity tracking from here.
        connectingDeviceID = nil
        endConnectionAttempt(attempt)
        // Preserve user intent so the watchdog can retry if auto-reconnect fails.
        connectionIntent = .wantsConnection(forceFullSync: forceFullSync)
        persistIntent()
        // Show connecting UI so the user sees their tap did something
        if connectionState != .connecting {
          connectionState = .connecting
        }
        // Re-arm timeout in case the previous one already fired
        reconnectionCoordinator.restartTimeout(deviceID: deviceID)
        logger.warning(
          "[BLE] Deferring to iOS auto-reconnect for device \(deviceID.uuidString.prefix(8)) - connectionState: \(String(describing: connectionState)), blePhase: \(blePhase), blePeripheralState: \(blePeripheralState)"
        )
        return
      }
    }

    if try await adoptOrRejectSystemConnectedLink(deviceID: deviceID, forceFullSync: forceFullSync) {
      endConnectionAttempt(attempt)
      return
    }

    // Clear intentional disconnect flag before changing state,
    // so the didSet invariant check sees consistent state
    connectionIntent = .wantsConnection(forceFullSync: forceFullSync)
    persistIntent()

    // Set connecting state for immediate UI feedback
    // (connectingDeviceID was already claimed above)
    connectionState = .connecting

    logger.info("Connecting to device: \(deviceID)")

    // Cancel any pending auto-reconnect timeout and clear device identity
    reconnectionCoordinator.cancelTimeout()
    reconnectionCoordinator.clearReconnectingDevice()

    do {
      // Validate device is still registered with the pairing registry. macOS reports
      // no active session, so this guard is skipped and CoreBluetooth resolves the device.
      if pairing.isSessionActive {
        let isConnectable = pairing.isDeviceConnectable(deviceID)

        if !isConnectable {
          await logDeviceNotFoundDiagnostics(deviceID: deviceID, context: "connect(to:) paired accessories mismatch")
          throw ConnectionError.deviceNotFound
        }
      }

      // Attempt connection with retry. Without a system pairing registry (macOS),
      // CoreBluetooth cannot pre-reject an absent saved peripheral, so a user-initiated
      // tap on an out-of-range radio would hang the full retry budget. Bound user taps
      // there; background reconnects (forceReconnect == false) keep the full budget so
      // unattended recovery still gets every attempt.
      let maxAttempts = (forceReconnect && !pairing.hasSystemPairingRegistry)
        ? Self.unverifiedConnectAttempts
        : Self.defaultConnectAttempts
      try await connectWithRetry(deviceID: deviceID, maxAttempts: maxAttempts, attempt: attempt)
    } catch {
      guard stillOwns() else {
        // The auto-reconnect cycle adopted this same radio's link mid-connect: it owns the
        // link and the session rebuild now, so the connect has not failed.
        if reconnectionCoordinator.reconnectingDeviceID == deviceID {
          logger.info("Connection to \(deviceID.uuidString.prefix(8)) adopted by the auto-reconnect cycle")
          return
        }
        logger.info("Connection to \(deviceID.uuidString.prefix(8)) superseded")
        throw error
      }
      if error is CancellationError {
        logger.info("Connection cancelled")
      } else {
        logger.warning("Connection failed: \(error.localizedDescription)")
      }
      connectionState = .disconnected
      throw error
    }
    // The deferred release clears the claim only while this attempt still owns it: a
    // newer connect or switch that claimed meanwhile keeps its own.
  }

  /// Adopts leftover GATT this app owns, or throws if another app holds the link.
  /// Settings forget clears last-connected; ASK membership or an in-flight pair still marks it ours.
  private func adoptOrRejectSystemConnectedLink(
    deviceID: UUID,
    forceFullSync: Bool
  ) async throws -> Bool {
    let ownedLink = isOwnedSystemConnectedLink(deviceID)
    if ownedLink {
      connectionIntent = .wantsConnection(forceFullSync: forceFullSync)
      persistIntent()

      if await startAdoptingLastSystemConnectedPeripheralIfAvailable(
        deviceID: deviceID,
        context: "connect(to:)",
        requireLastConnected: false
      ) {
        if isPairingInProgress {
          do {
            try await waitForPairingAdoptionToSettle()
          } catch {
            if connectingDeviceID == deviceID { connectingDeviceID = nil }
            throw error
          }
        }
        if connectingDeviceID == deviceID { connectingDeviceID = nil }
        return true
      }
      guard connectingDeviceID == deviceID else { throw CancellationError() }
    }

    if await isDeviceConnectedToOtherApp(deviceID), !ownedLink {
      if connectingDeviceID == deviceID { connectingDeviceID = nil }
      throw BLEError.deviceConnectedToOtherApp
    }
    guard connectingDeviceID == deviceID else { throw CancellationError() }
    return false
  }

  /// Break-glass teardown for a user-initiated (`forceReconnect`) connect that found
  /// a stuck reconnect: the UI already abandoned the cycle (pill shows "Disconnected")
  /// but the OS pending connect never resolved, e.g. the bond was invalidated.
  /// Deferring again would restart the same doomed wait forever, so cancel the cycle
  /// and tear down the pending connect; the caller falls through to a fresh attempt
  /// that surfaces the real CoreBluetooth error instead.
  private func abandonStuckReconnect(deviceID: UUID, detail: String = "") async {
    logger.warning("[BLE] Break-glass: abandoning stuck reconnect for \(deviceID.uuidString.prefix(8)) to allow a fresh connect attempt\(detail)")
    reconnectionCoordinator.cancelTimeout()
    reconnectionCoordinator.clearReconnectingDevice()
    await transport.disconnect()
  }

  /// Disconnects from the current device.
  /// - Parameter reason: The reason for disconnecting (for debugging)
  func disconnect(reason: DisconnectReason = .userInitiated) async {
    let initialState = String(describing: connectionState)
    let transportName = switch currentTransportType {
    case .bluetooth: "bluetooth"
    case .wifi: "wifi"
    case nil: "none"
    }
    let activeDevice = connectedDevice?.id.uuidString.prefix(8) ?? "none"

    logger.info(
      "Disconnecting from device (" +
        "reason: \(reason.rawValue), " +
        "transport: \(transportName), " +
        "device: \(activeDevice), " +
        "initialState: \(initialState), " +
        "intent: \(connectionIntent)" +
        ")"
    )

    // Cancel any pending auto-reconnect timeout and clear device identity
    reconnectionCoordinator.cancelTimeout()
    reconnectionCoordinator.clearReconnectingDevice()
    connectingDeviceID = nil
    // A connect or switch that resumes after this must find it no longer owns the link.
    invalidateConnectionAttempt()

    // Cancel any WiFi reconnection in progress
    cancelWiFiReconnection()

    // Stop WiFi heartbeat
    stopWiFiHeartbeat()

    // Stop reconnection watchdog
    stopReconnectionWatchdog()

    cancelResyncLoop()
    cancelChannelRetry()

    // Only clear user intent and clean-channel state for explicit disconnects.
    // Transient reasons preserve both so the next reconnect can skip redundant channel sync.
    switch reason {
    case .userInitiated, .statusMenuDisconnectTap, .forgetDevice, .deviceRemovedFromSettings, .factoryReset, .switchingDevice,
         .firmwareUpdate:
      connectionIntent = .userDisconnected
      persistIntent()
      await listeningReminder?.connectionAbandoned()
      surfacedAuthFailureDeviceID = nil
      clearCleanChannelSyncRecords()
    case .resyncFailed, .wifiAddressChange, .wifiReconnectPrep, .pairingFailed:
      // Preserve .wantsConnection so health check can retry
      break
    }

    // Capture and clear synchronously, mirroring teardownSessionForReconnect:
    // a racing connect can install a new container during the awaits below,
    // and re-reading self.services would tear that new container down.
    let oldServices = services
    let oldSession = session
    services = nil
    session = nil
    logger.info("[BLE] disconnect: state → .disconnected")
    connectionState = .disconnected
    connectingDeviceID = nil
    connectedDevice = nil
    allowedRepeatFreqRanges = []

    if let oldServices {
      // Mark room sessions disconnected before tearing down services
      _ = await oldServices.remoteNodeService.handleBLEDisconnection()
      sessionsAwaitingReauth = []
      await oldServices.tearDown()
      // Reset sync state and clear notification suppression (safety net)
      await oldServices.syncCoordinator.onDisconnected(notificationService: oldServices.notificationService)
    }

    // Stop session
    await oldSession?.stop()

    // Disconnect appropriate transport based on current type
    var wifiEndpoint: (host: String, port: UInt16)?
    if let wifiTransport {
      self.wifiTransport = nil
      await wifiTransport.disconnect()
      // Kept for a still-wanted link's reconnect below; the transport keeps its address.
      wifiEndpoint = await wifiTransport.connectionInfo
    } else {
      await transport.disconnect()
    }

    // Clear transport type
    currentTransportType = nil

    persistDisconnectDiagnostic(
      "source=disconnect(reason), " +
        "reason=\(reason.rawValue), " +
        "transport=\(transportName), " +
        "device=\(activeDevice), " +
        "initialState=\(initialState), " +
        "finalState=\(String(describing: connectionState)), " +
        "intent=\(connectionIntent)"
    )

    logger.info(
      "Disconnected (" +
        "reason: \(reason.rawValue), " +
        "transport: \(transportName), " +
        "device: \(activeDevice), " +
        "initialState: \(initialState), " +
        "finalState: \(String(describing: connectionState)), " +
        "intent: \(connectionIntent)" +
        ")"
    )

    // A Bluetooth link dropped because its resync kept failing is still wanted: re-arm the
    // watchdog so it reconnects on its own. Otherwise only the next return to the foreground
    // would, and a window that stays in front (a Mac's) never does.
    if reason == .resyncFailed, transportName == "bluetooth", connectionIntent.wantsConnection {
      startReconnectionWatchdog()
      logger.info("[BLE] Re-armed watchdog after resync failure")
    }

    await onDisconnected?(reason)

    // The WiFi counterpart: the watchdog is Bluetooth-only, so a WiFi link dropped for a
    // failing resync is handed to the WiFi reconnect loop. Started after onDisconnected so
    // the app's teardown sees the disconnect before the loop shows the link as connecting.
    if reason == .resyncFailed, transportName == "wifi", let wifiEndpoint,
       connectionIntent.wantsConnection, connectionState == .disconnected, !isExplicitConnectInFlight {
      logger.info("[WiFi] Re-arming WiFi reconnection after resync failure")
      await startWiFiRecovery(host: wifiEndpoint.host, port: wifiEndpoint.port)
    }
  }

  // MARK: - Simulator

  /// Commands the simulator radio refuses once, from the `-simulatorRadioRefusesOnce` launch
  /// argument (debug builds, for UI tests that need one radio write to fail).
  internal static var simulatorRadioRefusals: Set<CommandCode> {
    #if DEBUG
      SimulatorMockTransport.commands(named: UserDefaults.standard.string(forKey: "simulatorRadioRefusesOnce"))
    #else
      []
    #endif
  }

  /// Connects to the simulator device with mock data.
  /// Used for simulator builds and demo mode on device.
  func simulatorConnect() async throws {
    logger.info("Starting simulator connection")

    connectionIntent = .wantsConnection()
    persistIntent()
    connectingDeviceID = MockDataProvider.simulatorDeviceID
    connectionState = .connecting

    do {
      // Connect simulator mode
      await simulatorMode.connect()

      // The mock data is seeded directly into the persistence store. The session runs over the
      // simulator's radio, which answers only the radio's own settings (presets, parameters,
      // TX power, path hash size), so Settings → Radio and onboarding can apply a preset and read
      // it back; every other command still fails at once, as the demo always has.
      let mockTransport = SimulatorMockTransport(
        device: MockDataProvider.simulatorDevice,
        refusingOnce: Self.simulatorRadioRefusals,
        unemulated: .failAtOnce
      )
      let session = MeshCoreSession(transport: mockTransport)
      self.session = session
      do {
        try await session.start()
      } catch {
        // Never fail the demo over its radio: without it, radio writes fail as they used to.
        logger.warning("Simulator radio session did not start: \(error.localizedDescription)")
      }

      // Create services
      let newServices = ServiceContainer(
        session: session,
        dataStore: persistenceStore,
        radioID: MockDataProvider.simulatorDeviceID,
        appStateProvider: appStateProvider,
        connectionStateEvents: connectionStateEvents,
        initialConnectionState: connectionState
      )
      await wireCleanChannelSyncCallback(on: newServices)
      await newServices.chatSendQueueService.hydrate()
      services = newServices

      // Seed mock data
      try await simulatorMode.seedDataStore(newServices.dataStore)
      // Read in what the demo radio has heard (seeded above), for the Traffic maps and the RX Log
      await newServices.startSimulatorObservations(radioID: MockDataProvider.simulatorDeviceID)

      // Set connected device
      connectedDevice = MockDataProvider.simulatorDevice

      // Persist for auto-reconnect
      persistConnection(
        deviceID: MockDataProvider.simulatorDeviceID,
        radioID: MockDataProvider.simulatorDeviceID,
        deviceName: "Cairn Sim"
      )

      // Notify observers
      await onConnectionReady?()

      connectingDeviceID = nil
      connectionState = .ready
      await onDeviceSynced?()
      logger.info("Simulator connection complete")
    } catch {
      connectingDeviceID = nil
      await cleanupConnection()
      throw error
    }
  }

  // MARK: - Device Switching

  /// Switches to a different device.
  ///
  /// - Parameter deviceID: UUID of the new device to connect to
  func switchDevice(to deviceID: UUID) async throws {
    logger.info("Switching to device: \(deviceID)")
    clearCleanChannelSyncRecords()

    // Claim the link before the first await. A connect still in its handshake or sync for
    // the previous radio checks this claim after each await and stands down, instead of
    // retrying (or disconnecting) over the transport this switch is now using. Ending the
    // reconnect cycle invalidates its generation, so a rebuild in flight stands down too.
    connectingDeviceID = deviceID
    let attempt = beginConnectionAttempt(.bluetooth)
    let stillOwns = { [unowned self] in connectingDeviceID == deviceID && ownsConnectionAttempt(attempt) }
    reconnectionCoordinator.cancelTimeout()
    reconnectionCoordinator.clearReconnectingDevice()
    var newSession: MeshCoreSession?

    // Update intent
    connectionIntent = .wantsConnection()
    persistIntent()

    do {
      // Validate device is registered with the pairing registry. Skipped on macOS,
      // which has no active session; CoreBluetooth resolves the device on connect.
      if pairing.isSessionActive {
        let isConnectable = pairing.isDeviceConnectable(deviceID)
        if !isConnectable {
          await logDeviceNotFoundDiagnostics(deviceID: deviceID, context: "switchDevice paired accessories mismatch")
          throw ConnectionError.deviceNotFound
        }
      }

      // Cancel any resync loop from the old device before teardown
      cancelResyncLoop()
      await releaseWiFiForBLEConnect()
      guard stillOwns() else { throw CancellationError() }

      // Capture and clear before the awaits below, so they tear down the old radio's
      // stack and never one a racing flow installs meanwhile.
      let oldServices = services
      let oldSession = session
      services = nil
      session = nil

      // Reset sync state before destroying services to prevent stuck "Syncing" pill
      if let oldServices {
        await oldServices.syncCoordinator.onDisconnected(notificationService: oldServices.notificationService)
        // Mark the old radio's room sessions disconnected, as disconnect(reason:)
        // does; otherwise they stay "connected" against a radio that is gone.
        _ = await oldServices.remoteNodeService.handleBLEDisconnection()
      }
      sessionsAwaitingReauth = []

      // Stop current services
      // tearDown cancels the old container's connection-state subscription;
      // it was already cleared above, before the connect ceremony installs
      // its replacement.
      await oldServices?.tearDown()
      await oldSession?.stop()
      await stateMachine.setAppSessionLive(deviceID: nil)
      guard stillOwns() else { throw CancellationError() }

      // Switch transport
      logger.info("[BLE] switchDevice: state → .connecting for device: \(deviceID.uuidString.prefix(8))")
      connectionState = .connecting
      try await transport.switchDevice(to: deviceID)
      guard stillOwns() else { throw CancellationError() }
      logger.info("[BLE] switchDevice: state → .connected for device: \(deviceID.uuidString.prefix(8))")
      connectionState = .connected

      // Re-create session with existing transport
      let switchedSession = MeshCoreSession(transport: transport)
      newSession = switchedSession
      session = switchedSession

      let (meshCoreSelfInfo, deviceCapabilities) = try await initializeSession(switchedSession)
      guard stillOwns() else { throw CancellationError() }

      // Session traffic flowed over the encrypted UART link, so the bond is
      // proven healthy as of now. Also marks the app session live for RSSI refresh.
      await recordBondVerification(deviceID: deviceID)

      // Configure BLE write pacing based on device platform
      await configureBLEPacing(for: deviceCapabilities)

      let (newServices, radioID) = try await buildServicesAndSaveDevice(
        deviceID: deviceID,
        session: switchedSession,
        selfInfo: meshCoreSelfInfo,
        capabilities: deviceCapabilities,
        connectionMethods: Self.bleConnectionMethods(for: deviceID),
        isStillOwner: stillOwns
      )

      // Persist connection for auto-reconnect
      persistConnection(deviceID: deviceID, radioID: radioID, deviceName: meshCoreSelfInfo.name, transport: .bluetooth)

      // Notify observers before sync starts so they can wire callbacks
      await onConnectionReady?()
      let syncSucceeded = await performInitialSync(radioID: radioID, services: newServices, context: "Device switch", forceFullSync: true)

      guard await promoteToReady(
        syncSucceeded: syncSucceeded,
        expectedServices: newServices,
        transportType: .bluetooth,
        additionalGuard: stillOwns
      ) else {
        // Superseded: the link belongs to the newer flow, so only this switch's own
        // session stops, leaving the transport up.
        if !stillOwns() {
          if session !== switchedSession {
            await switchedSession.stop(disconnectTransport: false)
          }
        }
        releaseSwitchClaim(deviceID: deviceID, attempt: attempt)
        return
      }

      // Refill the rebuild-preserve budget so a spent counter on radio A cannot
      // force radio B's first rebuild failure to sever.
      resetPreserveBudgetAfterDeviceSwitch()
      stopReconnectionWatchdog()
      releaseSwitchClaim(deviceID: deviceID, attempt: attempt)
      logger.info("Device switch complete - device ready")
    } catch {
      guard stillOwns() else {
        // A newer connect, switch, or disconnect owns the link now: stop only the
        // session this switch built (unless the newer flow already replaced it)
        // and leave the transport and state to that flow.
        logger.info("Switch to \(deviceID.uuidString.prefix(8)) superseded")
        if let newSession, session !== newSession {
          await newSession.stop(disconnectTransport: false)
        }
        releaseSwitchClaim(deviceID: deviceID, attempt: attempt)
        throw error is CancellationError ? error : CancellationError()
      }
      releaseSwitchClaim(deviceID: deviceID, attempt: attempt, clearingTransport: true)
      // Without this, a partial switch would leave services, session, and
      // connectedDevice pointing at the old device with state stuck on
      // .connecting or .connected. pairNewDevice routes through here when
      // an old radio is still connected, so the failure alert's recovery
      // actions need clean state.
      await cleanupConnection()
      await transport.disconnect()
      // cleanupConnection tore down the session without firing onConnectionLost,
      // so observers (and the radio's Live Activity) would otherwise be stranded
      // on the old device's "connected" state. Route through the same callback the
      // transport-loss and reconnect-failure paths use.
      await onConnectionLost?()
      throw error
    }
  }

  /// Releases the claim a switch made, only while it still holds it.
  private func releaseSwitchClaim(deviceID: UUID, attempt: UInt64, clearingTransport: Bool = false) {
    guard ownsConnectionAttempt(attempt) else { return }
    if connectingDeviceID == deviceID { connectingDeviceID = nil }
    endConnectionAttempt(attempt, clearingTransport: clearingTransport)
  }
}
