import Foundation
@testable import CairnServices
import MeshCore
import Network
import os
import Testing

/// Background App Refresh: one short run per wake that checks in on the radio. It acts only for a
/// connection the user wants, never on the demo radio or during pairing, waits for a connect
/// already in flight instead of starting a second, drains a live link, reconnects WiFi once, and
/// leaves Bluetooth to its own wake source (re-arming one that is missing).
@Suite("Background refresh: decision table")
struct BackgroundRefreshDecisionTests {
  /// A WiFi radio that is wanted, disconnected, with an address and nothing in flight.
  private func snapshot(
    wantsConnection: Bool = true,
    isSimulatorRadio: Bool = false,
    isPairing: Bool = false,
    transport: TransportType? = .wifi,
    lastRadioPrefersWiFi: Bool = true,
    hasWiFiEndpoint: Bool = true,
    connectionState: DeviceConnectionState = .disconnected,
    explicitConnectInFlight: Bool = false,
    wifiLoop: BackgroundRefreshWiFiLoop = .none,
    approvalBlocked: Bool = false,
    localNetworkDenied: Bool = false,
    bleLinkUp: Bool = false,
    blePhase: BackgroundRefreshBLEPhase = .idle
  ) -> BackgroundRefreshSnapshot {
    BackgroundRefreshSnapshot(
      wantsConnection: wantsConnection,
      isSimulatorRadio: isSimulatorRadio,
      isPairing: isPairing,
      transport: transport,
      lastRadioPrefersWiFi: lastRadioPrefersWiFi,
      hasWiFiEndpoint: hasWiFiEndpoint,
      connectionState: connectionState,
      explicitConnectInFlight: explicitConnectInFlight,
      wifiLoop: wifiLoop,
      approvalBlocked: approvalBlocked,
      localNetworkDenied: localNetworkDenied,
      bleLinkUp: bleLinkUp,
      blePhase: blePhase
    )
  }

  private func action(_ snapshot: BackgroundRefreshSnapshot) -> BackgroundRefreshAction {
    ConnectionManager.backgroundRefreshAction(for: snapshot)
  }

  @Test
  func `no wanted connection, the demo radio, and pairing all skip`() {
    // .userDisconnected and .none both read as not wanted: the run never widens the intent.
    #expect(action(snapshot(wantsConnection: false)) == .skip(.notWanted))
    #expect(action(snapshot(wantsConnection: false, connectionState: .disconnected, explicitConnectInFlight: true)) == .skip(.notWanted))
    #expect(action(snapshot(isSimulatorRadio: true)) == .skip(.simulator))
    #expect(action(snapshot(isPairing: true, explicitConnectInFlight: true)) == .skip(.pairing))
  }

  @Test
  func `a connect in flight or a fast reconnect window is waited for`() {
    #expect(action(snapshot(explicitConnectInFlight: true)) == .waitForInFlightConnect)
    #expect(action(snapshot(wifiLoop: .fastWindow)) == .waitForInFlightConnect)
    #expect(action(snapshot(transport: .bluetooth, explicitConnectInFlight: true)) == .waitForInFlightConnect)
  }

  @Test
  func `an operational WiFi link is probed, then drained`() {
    #expect(action(snapshot(connectionState: .ready)) == .drainLiveLink(probeFirst: true))
    #expect(action(snapshot(connectionState: .syncing, approvalBlocked: true)) == .drainLiveLink(probeFirst: true))
  }

  @Test
  func `a WiFi link down reconnects once, cancelling a backing-off loop`() {
    #expect(action(snapshot()) == .reconnectWiFi(cancelBackoff: false))
    #expect(action(snapshot(wifiLoop: .backingOff)) == .reconnectWiFi(cancelBackoff: true))
    // Cold launch: nothing marked the transport yet, the last radio was on WiFi.
    #expect(action(snapshot(transport: nil)) == .reconnectWiFi(cancelBackoff: false))
  }

  @Test
  func `a radio awaiting approval, refused Local Network access, or no address is left alone`() {
    #expect(action(snapshot(wifiLoop: .backingOff, approvalBlocked: true)) == .skip(.wifiAwaitingApproval))
    #expect(action(snapshot(localNetworkDenied: true)) == .skip(.localNetworkDenied))
    #expect(action(snapshot(transport: .wifi, hasWiFiEndpoint: false)) == .skip(.noEndpoint))
  }

  @Test
  func `a radio last used over Bluetooth takes the Bluetooth path even with a WiFi address`() {
    #expect(action(snapshot(transport: nil, lastRadioPrefersWiFi: false)) == .armBLEWakeSource)
    #expect(action(snapshot(transport: .bluetooth)) == .armBLEWakeSource)
  }

  @Test
  func `the Bluetooth path drains, rebuilds, arms, or stands down`() {
    let ble = { (state: DeviceConnectionState, linkUp: Bool, phase: BackgroundRefreshBLEPhase) in
      snapshot(transport: .bluetooth, connectionState: state, bleLinkUp: linkUp, blePhase: phase)
    }
    #expect(action(ble(.ready, true, .pending)) == .drainLiveLink(probeFirst: false))
    #expect(action(ble(.disconnected, true, .pending)) == .rebuildBLEStack)
    #expect(action(ble(.connecting, true, .pending)) == .skip(.bluetoothPending))
    #expect(action(ble(.disconnected, false, .idle)) == .armBLEWakeSource)
    #expect(action(ble(.disconnected, false, .pending)) == .skip(.bluetoothPending))
    #expect(action(ble(.disconnected, false, .poweredOff)) == .skip(.bluetoothOff))
  }

  @Test
  func `a drain counts only once its catch-up notifications were delivered`() {
    let runStart = Date()
    let drained = runStart.addingTimeInterval(1)
    // The queue emptied, but the handlers and the catch-up flush have not finished.
    #expect(!ConnectionManager.isDrainDelivered(drainedAt: drained, deliveredAt: nil, since: runStart))
    #expect(!ConnectionManager.isDrainDelivered(
      drainedAt: drained,
      deliveredAt: runStart.addingTimeInterval(-60),
      since: runStart
    ), "an earlier connection's delivery does not count")
    #expect(ConnectionManager.isDrainDelivered(drainedAt: drained, deliveredAt: drained.addingTimeInterval(2), since: runStart))
    #expect(ConnectionManager.isDrainDelivered(
      drainedAt: drained.addingTimeInterval(3),
      deliveredAt: drained.addingTimeInterval(2),
      since: runStart
    ), "an auto-fetch drain after the delivery does not undo it")
    #expect(!ConnectionManager.isDrainDelivered(
      drainedAt: runStart.addingTimeInterval(-5),
      deliveredAt: runStart.addingTimeInterval(-4),
      since: runStart
    ), "a drain from before the run is not this run's")
  }

  @Test
  func `skips and an armed wake source count as success`() {
    #expect(BackgroundRefreshOutcome.skipped(.notWanted).isSuccess)
    #expect(BackgroundRefreshOutcome.drained(count: 3).isSuccess)
    #expect(BackgroundRefreshOutcome.wakeSourceArmed.isSuccess)
    #expect(!BackgroundRefreshOutcome.timedOut.isSuccess)
    #expect(!BackgroundRefreshOutcome.failed("x").isSuccess)
  }
}

// MARK: - Approval signature

@Suite("Background refresh: radio approval signature")
struct RadioApprovalSignatureTests {
  @Test
  func `a handshake that times out or is closed after TCP connected looks like a radio awaiting approval`() {
    let timeout = TimeoutError(operationName: "session.start", timeout: .seconds(10))
    #expect(ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: timeout))
    #expect(ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: MeshCoreError.timeout))
    // The radio closed the socket right after accepting it (Cancel), or mid handshake.
    #expect(ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: WiFiTransportError.connectionFailed("closed")))
    #expect(ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: MeshCoreError.connectionLost(underlying: nil)))
  }

  @Test
  func `failures before TCP connected, Local Network refusals, and supersession do not`() {
    #expect(!ConnectionManager.isRadioApprovalSignature(transportConnected: false, error: MeshCoreError.timeout))
    #expect(!ConnectionManager.isRadioApprovalSignature(transportConnected: false, error: WiFiTransportError.connectionTimeout))
    #expect(!ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: WiFiTransportError.connectionTimeout))
    #expect(!ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: WiFiTransportError.localNetworkDenied))
    #expect(!ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: CancellationError()))
    #expect(!ConnectionManager.isRadioApprovalSignature(transportConnected: true, error: MeshCoreError.deviceError(code: 1)))
  }

  @Test
  func `a handshake failure seen long after its own timeouts came from a suspension`() {
    let window = Duration.seconds(15)
    #expect(!ConnectionManager.handshakeOutlivedItsTimeouts(elapsed: .seconds(5), window: window), "APP_START's own timeout")
    #expect(!ConnectionManager.handshakeOutlivedItsTimeouts(elapsed: .seconds(10), window: window), "the outer timeout")
    #expect(ConnectionManager.handshakeOutlivedItsTimeouts(elapsed: .seconds(600), window: window))
  }
}

// MARK: - Approval gate

@Suite("Background refresh: WiFi approval gate")
@MainActor
struct BackgroundWiFiApprovalGateTests {
  private func makeDefaults() throws -> (UserDefaults, () -> Void) {
    let name = "test.gate.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    return (defaults, { UserDefaults().removePersistentDomain(forName: name) })
  }

  @Test
  func `recording blocks only that endpoint, and persists`() throws {
    let (defaults, cleanup) = try makeDefaults()
    defer { cleanup() }
    let gate = BackgroundWiFiApprovalGate(defaults: defaults)
    let endpoint = BackgroundWiFiApprovalGate.key(host: "192.168.4.1", port: 5000)

    gate.recordUnanswered(endpoint: endpoint)

    #expect(gate.isBlocked(endpoint: endpoint))
    #expect(!gate.isBlocked(endpoint: BackgroundWiFiApprovalGate.key(host: "192.168.4.2", port: 5000)))
    #expect(!gate.isBlocked(endpoint: BackgroundWiFiApprovalGate.key(host: "192.168.4.1", port: 5001)))
    // A background relaunch reads the same block.
    #expect(BackgroundWiFiApprovalGate(defaults: defaults).isBlocked(endpoint: endpoint))

    gate.clear()
    #expect(!BackgroundWiFiApprovalGate(defaults: defaults).isBlocked(endpoint: endpoint))
    #expect(!gate.hasBlockedEndpoints)
  }

  @Test
  func `a block lapses after the retry interval, and a new refusal restarts it`() throws {
    let (defaults, cleanup) = try makeDefaults()
    defer { cleanup() }
    let gate = BackgroundWiFiApprovalGate(defaults: defaults)
    let endpoint = BackgroundWiFiApprovalGate.key(host: "192.168.4.1", port: 5000)
    let recordedAt = Date()
    let interval = BackgroundWiFiApprovalGate.retryInterval

    gate.recordUnanswered(endpoint: endpoint, now: recordedAt)

    #expect(gate.isBlocked(endpoint: endpoint, now: recordedAt.addingTimeInterval(interval - 60)))
    // One background attempt may go through: a trusted radio that was only busy recovers.
    let lapsed = recordedAt.addingTimeInterval(interval + 1)
    #expect(!gate.isBlocked(endpoint: endpoint, now: lapsed))

    gate.recordUnanswered(endpoint: endpoint, now: lapsed)
    #expect(gate.isBlocked(endpoint: endpoint, now: lapsed.addingTimeInterval(60)))
  }

  private func makeManager(inForeground: Bool) throws -> PairingTestEnvironment {
    let env = try ConnectionManager.createForPairingTesting()
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: inForeground)
    env.manager.backgroundWiFiGate.recordUnanswered(endpoint: "192.168.4.1:5000")
    return env
  }

  @Test
  func `becoming active clears the gate`() async throws {
    let env = try makeManager(inForeground: true)
    defer { env.cleanup() }

    await env.manager.appDidBecomeActive()

    #expect(!env.manager.backgroundWiFiGate.hasBlockedEndpoints)
  }

  @Test
  func `the foreground WiFi check clears the gate before it reconnects`() async throws {
    let env = try makeManager(inForeground: true)
    defer { env.cleanup() }

    await env.manager.checkWiFiConnectionHealth()

    #expect(!env.manager.backgroundWiFiGate.hasBlockedEndpoints)
  }

  @Test(.timeLimit(.minutes(1)))
  func `a connect in the foreground clears the gate, one in the background does not`() async throws {
    let closedPort = try await QuarantineTCPListener.closedPort()

    let background = try makeManager(inForeground: false)
    defer { background.cleanup() }
    await #expect(throws: (any Error).self) {
      try await background.manager.connectViaWiFi(host: "127.0.0.1", port: closedPort, failsFastOnLocalNetworkPrompt: true)
    }
    #expect(background.manager.backgroundWiFiGate.hasBlockedEndpoints)

    let foreground = try makeManager(inForeground: true)
    defer { foreground.cleanup() }
    await #expect(throws: (any Error).self) {
      try await foreground.manager.connectViaWiFi(host: "127.0.0.1", port: closedPort)
    }
    #expect(!foreground.manager.backgroundWiFiGate.hasBlockedEndpoints)
  }

  @Test(.timeLimit(.minutes(1)))
  func `a background connect the radio holds unanswered blocks that endpoint`() async throws {
    let listener = try await QuarantineTCPListener.start()
    defer { listener.stop() }
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: false)

    await #expect(throws: (any Error).self) {
      try await env.manager.connectViaWiFi(host: "127.0.0.1", port: listener.port, failsFastOnLocalNetworkPrompt: true)
    }

    #expect(listener.acceptCount == 1)
    #expect(env.manager.backgroundWiFiGate.isBlocked(endpoint: "127.0.0.1:\(listener.port)"))
  }

  @Test(.timeLimit(.minutes(1)))
  func `a handshake that failed only after a suspension is not recorded`() async throws {
    let listener = try await QuarantineTCPListener.start()
    defer { listener.stop() }
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: false)
    // Stands in for a connect frozen mid-handshake: on the next wake its timeout fires at once,
    // far later than any handshake can fail while the app runs.
    env.manager.wifiApprovalHandshakeWindow = .zero

    await #expect(throws: (any Error).self) {
      try await env.manager.connectViaWiFi(host: "127.0.0.1", port: listener.port, failsFastOnLocalNetworkPrompt: true)
    }

    #expect(listener.acceptCount == 1)
    #expect(!env.manager.backgroundWiFiGate.hasBlockedEndpoints, "suspension, not the radio, timed it out")
  }

  @Test(.timeLimit(.minutes(1)))
  func `a refused connect is not mistaken for a radio awaiting approval`() async throws {
    let closedPort = try await QuarantineTCPListener.closedPort()
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: false)

    await #expect(throws: (any Error).self) {
      try await env.manager.connectViaWiFi(host: "127.0.0.1", port: closedPort, failsFastOnLocalNetworkPrompt: true)
    }

    #expect(!env.manager.backgroundWiFiGate.hasBlockedEndpoints)
  }

  @Test(.timeLimit(.minutes(1)))
  func `in the background a blocked endpoint gets no reconnect attempt`() async throws {
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    let manager = env.manager
    manager.appStateProvider = MockAppStateProvider(isInForeground: false)
    manager.setTestState(connectionIntent: .wantsConnection())
    manager.backgroundWiFiGate.recordUnanswered(endpoint: "192.168.4.1:5000")

    await manager.startWiFiRecovery(host: "192.168.4.1", port: 5000)

    try await waitUntil("the fast window should hand over to the slow backoff") {
      manager.isWiFiReconnectBackingOff
    }
    #expect(manager.wifiReconnectAttempt == 0, "no attempt may light the radio's screen again")
    #expect(manager.connectionState == .disconnected)

    await manager.disconnect(reason: .userInitiated)
    #expect(manager.wifiReconnectTask == nil)
  }
}

// MARK: - Runs

@Suite("Background refresh: runs")
@MainActor
struct BackgroundRefreshRunTests {
  private let deviceID = UUID()

  private func makeManager(
    intent: ConnectionIntent = .wantsConnection(),
    transport: TransportType? = .bluetooth
  ) throws -> PairingTestEnvironment {
    let env = try ConnectionManager.createForPairingTesting()
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: false)
    env.manager.testLastConnectedDeviceID = deviceID
    env.manager.setTestState(
      connectionState: .disconnected,
      currentTransportType: transport,
      connectionIntent: intent
    )
    return env
  }

  private var deadline: ContinuousClock.Instant {
    .now + .seconds(23)
  }

  @Test
  func `wanted only for a connection the user wants to a real radio`() throws {
    let wanted = try makeManager()
    defer { wanted.cleanup() }
    #expect(wanted.manager.wantsBackgroundRefresh)

    let disconnected = try makeManager(intent: .userDisconnected)
    defer { disconnected.cleanup() }
    #expect(!disconnected.manager.wantsBackgroundRefresh)

    let manual = try makeManager(intent: .none)
    defer { manual.cleanup() }
    #expect(!manual.manager.wantsBackgroundRefresh, "Connect on Launch off and nothing connected yet")

    let demo = try makeManager()
    defer { demo.cleanup() }
    demo.manager.testLastConnectedDeviceID = MockDataProvider.simulatorDeviceID
    #expect(!demo.manager.wantsBackgroundRefresh)
  }

  @Test
  func `an idle Bluetooth link gets exactly one pending connect`() async throws {
    let env = try makeManager()
    defer { env.cleanup() }

    let outcome = await env.manager.performBackgroundRefresh(deadline: deadline)

    #expect(outcome == .wakeSourceArmed)
    #expect(await env.stateMachine.armPendingReconnectCalls == [deviceID])
    #expect(await env.transport.connectInvocations.isEmpty, "the run never connects over Bluetooth itself")
  }

  @Test
  func `a pending Bluetooth connect is left alone`() async throws {
    let env = try makeManager()
    defer { env.cleanup() }
    await env.stateMachine.setStubbedPhase(.connecting)

    let outcome = await env.manager.performBackgroundRefresh(deadline: deadline)

    #expect(outcome == .skipped(.bluetoothPending))
    #expect(await env.stateMachine.armPendingReconnectCalls.isEmpty)
  }

  @Test
  func `a user disconnect is never undone`() async throws {
    let env = try makeManager(intent: .userDisconnected)
    defer { env.cleanup() }

    let outcome = await env.manager.performBackgroundRefresh(deadline: deadline)

    #expect(outcome == .skipped(.notWanted))
    #expect(await env.stateMachine.armPendingReconnectCalls.isEmpty)
    #expect(env.manager.connectionIntent == .userDisconnected)
  }

  @Test
  func `the demo radio is skipped`() async throws {
    let env = try makeManager()
    defer { env.cleanup() }
    env.manager.testLastConnectedDeviceID = MockDataProvider.simulatorDeviceID

    #expect(await env.manager.performBackgroundRefresh(deadline: deadline) == .skipped(.simulator))
  }

  private func placeWiFiTransport(on manager: ConnectionManager, port: UInt16) async {
    let transport = WiFiTransport()
    await transport.setConnectionInfo(host: "127.0.0.1", port: port)
    manager.wifiTransport = transport
  }

  @Test
  func `a radio awaiting approval is not asked again`() async throws {
    let env = try makeManager(transport: .wifi)
    defer { env.cleanup() }
    await placeWiFiTransport(on: env.manager, port: 5000)
    env.manager.backgroundWiFiGate.recordUnanswered(endpoint: "127.0.0.1:5000")

    #expect(await env.manager.performBackgroundRefresh(deadline: deadline) == .skipped(.wifiAwaitingApproval))
    #expect(env.manager.connectionState == .disconnected)
  }

  @Test
  func `a WiFi reconnect needs enough of the run left`() async throws {
    let env = try makeManager(transport: .wifi)
    defer { env.cleanup() }
    await placeWiFiTransport(on: env.manager, port: 5000)

    let outcome = await env.manager.performBackgroundRefresh(deadline: .now + .seconds(5))

    #expect(outcome == .skipped(.notEnoughTime))
    #expect(env.manager.connectionState == .disconnected)
  }

  @Test(.timeLimit(.minutes(1)))
  func `a run that ends before the radio answers cancels its connect and records nothing`() async throws {
    let listener = try await QuarantineTCPListener.start()
    defer { listener.stop() }
    let env = try makeManager(transport: .wifi)
    defer { env.cleanup() }
    let manager = env.manager
    await placeWiFiTransport(on: manager, port: listener.port)
    // The radio takes APP_START's full 5 s to fail; the run ends well before that.
    manager.backgroundRefreshMinimumForConnect = .seconds(1)
    let start = ContinuousClock.now

    let outcome = await manager.performBackgroundRefresh(deadline: .now + .seconds(2))

    #expect(outcome == .timedOut)
    #expect(ContinuousClock.now - start < .seconds(4), "the run does not wait out the handshake")
    #expect(listener.acceptCount == 1)
    try await waitUntil("the cancelled connect should hand the link to the reconnect loop") {
      manager.wifiReconnectTask != nil && manager.connectionAttemptTransport == nil
    }
    #expect(manager.isWiFiReconnectBackingOff, "in the background the loop resumes in its slow backoff")
    #expect(manager.connectionState == .disconnected)
    #expect(!manager.backgroundWiFiGate.hasBlockedEndpoints, "a cancelled attempt says nothing about the radio")

    await manager.disconnect(reason: .userInitiated)
  }

  @Test(.timeLimit(.minutes(1)))
  func `a failed WiFi reconnect hands the link back to the slow backoff`() async throws {
    let closedPort = try await QuarantineTCPListener.closedPort()
    let env = try makeManager(transport: .wifi)
    defer { env.cleanup() }
    let manager = env.manager
    await placeWiFiTransport(on: manager, port: closedPort)

    let outcome = await manager.performBackgroundRefresh(deadline: deadline)

    guard case .failed = outcome else {
      Issue.record("expected a failed run, got \(outcome)")
      return
    }
    try await waitUntil("the reconnect loop should take the link back") {
      manager.wifiReconnectTask != nil
    }
    #expect(manager.isWiFiReconnectBackingOff, "in the background the loop resumes in its slow backoff")
    #expect(manager.wifiReconnectAttempt == 0)
    #expect(manager.connectionState == .disconnected)
    #expect(manager.currentTransportType == .wifi)
    #expect(!manager.backgroundWiFiGate.hasBlockedEndpoints, "a refused connect is not a radio awaiting approval")

    await manager.disconnect(reason: .userInitiated)
  }
}

// MARK: - Test doubles

/// A localhost TCP listener that accepts connections and never answers, as a radio holding a new
/// phone in quarantine does while it asks whether to allow it.
private final class QuarantineTCPListener: @unchecked Sendable {
  private let listener: NWListener
  let port: UInt16
  private let accepted = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])

  var acceptCount: Int {
    accepted.withLock { $0.count }
  }

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
  }

  static func start() async throws -> QuarantineTCPListener {
    let listener = try NWListener(using: .tcp)
    let states = AsyncStream<NWListener.State>.makeStream()
    listener.stateUpdateHandler = { state in
      states.continuation.yield(state)
    }
    let pending = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])
    listener.newConnectionHandler = { connection in
      pending.withLock { $0.append(connection) }
      connection.start(queue: .global())
    }
    listener.start(queue: .global(qos: .userInitiated))
    for await state in states.stream {
      if state == .ready { break }
      if case let .failed(error) = state {
        states.continuation.finish()
        throw error
      }
    }
    states.continuation.finish()
    let port = try #require(listener.port?.rawValue)
    let wrapper = QuarantineTCPListener(listener: listener, port: port)
    listener.newConnectionHandler = { connection in
      wrapper.accepted.withLock { $0.append(connection) }
      connection.start(queue: .global())
    }
    return wrapper
  }

  /// A localhost port nothing listens on, so a connect to it is refused at once.
  static func closedPort() async throws -> UInt16 {
    let listener = try await start()
    let port = listener.port
    listener.stop()
    try await Task.sleep(for: .milliseconds(100))
    return port
  }

  func stop() {
    accepted.withLock { connections in
      for connection in connections {
        connection.cancel()
      }
    }
    listener.cancel()
  }
}
