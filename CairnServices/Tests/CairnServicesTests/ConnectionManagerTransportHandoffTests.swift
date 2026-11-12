import Foundation
@testable import CairnServices
import MeshCore
import MeshCoreTestSupport
import Testing

/// Covers the points where one connection flow hands the link to another: the
/// heartbeat a resync-recovered WiFi connection must gain, the WiFi reconnect
/// loop a BLE connect must stand down, the retry and observer notification a
/// lost WiFi link owes, the BLE link a manual connect must leave to the reconnect
/// cycle that adopted it, and the re-auth set a repeated BLE drop must keep.
@Suite("ConnectionManager Transport Handoff Tests")
@MainActor
struct ConnectionManagerTransportHandoffTests {
  // MARK: - Test Helpers

  /// Pairing stub with no active system session, so `connect(to:)` and
  /// `switchDevice` skip the registration guard and reach the transport.
  @MainActor
  private final class InactivePairingService: DevicePairingService {
    var delegate: (any DevicePairingDelegate)?

    var isSessionActive: Bool {
      false
    }

    var registeredDeviceCount: Int {
      0
    }

    var hasSystemPairingRegistry: Bool {
      false
    }

    var supportsSystemRename: Bool {
      false
    }

    func activate() async throws {}
    func discoverDevice() async throws -> UUID {
      throw CancellationError()
    }

    func isDeviceConnectable(_ id: UUID) -> Bool {
      true
    }

    func registeredDeviceInfos() -> [(id: UUID, name: String)] {
      []
    }

    func removeDevice(_ id: UUID) async throws {}
    func renameDevice(_ id: UUID) async throws {}
    func clearStaleRegistrations() async {}
  }

  private struct ManagerHarness<Transport: iOSMeshTransport> {
    let manager: ConnectionManager
    let stateMachine: MockBLEStateMachine
    let transport: Transport
    let cleanup: () -> Void
  }

  private func makeManager<Transport: iOSMeshTransport>(
    transport: Transport
  ) throws -> ManagerHarness<Transport> {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let suiteName = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let stateMachine = MockBLEStateMachine()
    let manager = ConnectionManager(
      modelContainer: container,
      defaults: defaults,
      stateMachine: stateMachine,
      transport: transport,
      pairing: InactivePairingService()
    )
    return ManagerHarness(
      manager: manager,
      stateMachine: stateMachine,
      transport: transport,
      cleanup: { UserDefaults().removePersistentDomain(forName: suiteName) }
    )
  }

  /// Manager over a BLE transport that fails every connect and switch, so a
  /// connect attempt runs its pre-connect path and then fails fast.
  private func makeManager() throws -> ManagerHarness<UnreachableBLETransport> {
    try makeManager(transport: UnreachableBLETransport())
  }

  private func makeServices() async throws -> (MeshCoreSession, ServiceContainer) {
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "WiFiHandoffTest")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    return (session, services)
  }

  /// Stand-in for a running reconnect or heartbeat loop: parked until cancelled.
  private func parkedTask() -> Task<Void, Never> {
    Task { try? await Task.sleep(for: Self.parkedTaskDuration) }
  }

  /// Longer than any test here runs, so a parked task only ends by cancellation.
  private static let parkedTaskDuration: Duration = .seconds(300)

  // MARK: - Heartbeat after resync

  @Test(
    .timeLimit(.minutes(1))
  )
  func `resync success over WiFi starts the heartbeat`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager
    let deviceID = UUID()
    let (session, services) = try await makeServices()
    await services.syncCoordinator.setPerformResyncOverride { _, _ in true }
    manager.setTestState(
      connectionState: .syncing,
      services: services,
      session: session,
      connectedDevice: DeviceDTO.testDevice(id: deviceID),
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    #expect(manager.wifiHeartbeatTask == nil)

    manager.startResyncLoop(radioID: deviceID, services: services, transportType: .wifi)

    try await waitUntil(timeout: .seconds(10), "resync should promote to .ready") {
      manager.connectionState == .ready
    }
    #expect(manager.wifiHeartbeatTask != nil, "A WiFi connection recovered by resync must gain a heartbeat")

    try await waitUntil(timeout: .seconds(10), "resync loop should finish") {
      manager.resyncTask == nil
    }
    manager.stopWiFiHeartbeat()
  }

  @Test(
    .timeLimit(.minutes(1))
  )
  func `resync success over Bluetooth starts no heartbeat`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager
    let deviceID = UUID()
    let (session, services) = try await makeServices()
    await services.syncCoordinator.setPerformResyncOverride { _, _ in true }
    manager.setTestState(
      connectionState: .syncing,
      services: services,
      session: session,
      connectedDevice: DeviceDTO.testDevice(id: deviceID),
      currentTransportType: .bluetooth,
      connectionIntent: .wantsConnection()
    )

    manager.startResyncLoop(radioID: deviceID, services: services, transportType: .bluetooth)

    try await waitUntil(timeout: .seconds(10), "resync loop should finish") {
      manager.connectionState == .ready && manager.resyncTask == nil
    }
    #expect(manager.wifiHeartbeatTask == nil)
  }

  // MARK: - BLE connect during WiFi reconnection

  @Test
  func `connecting to a BLE radio during WiFi reconnection stands the WiFi side down`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager

    // A lost WiFi link mid-reconnect: state .connecting, loop and heartbeat live.
    manager.setTestState(
      connectionState: .connecting,
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    let reconnectTask = parkedTask()
    manager.wifiReconnectTask = reconnectTask
    manager.wifiHeartbeatTask = parkedTask()
    manager.wifiTransport = WiFiTransport()

    await #expect(throws: (any Error).self) {
      try await manager.connect(to: UUID(), forceReconnect: true)
    }

    #expect(reconnectTask.isCancelled, "The WiFi reconnect loop must not outlive a BLE connect")
    #expect(manager.wifiReconnectTask == nil)
    #expect(manager.wifiHeartbeatTask == nil)
    #expect(manager.wifiTransport == nil)
    #expect(await harness.transport.connectAttempts > 0, "The BLE connect itself must still proceed")
  }

  /// In the slow backoff the loop sits at `.disconnected`, which skips the
  /// `.connecting` stand-down above; the BLE connect must still release it.
  @Test
  func `connecting to a BLE radio during the WiFi slow backoff stands the WiFi side down`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager

    manager.setTestState(
      connectionState: .disconnected,
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    let reconnectTask = parkedTask()
    manager.wifiReconnectTask = reconnectTask
    manager.isWiFiReconnectBackingOff = true
    manager.wifiTransport = WiFiTransport()

    await #expect(throws: (any Error).self) {
      try await manager.connect(to: UUID(), forceReconnect: true)
    }

    #expect(reconnectTask.isCancelled, "The WiFi slow backoff must not outlive a BLE connect")
    #expect(manager.wifiReconnectTask == nil)
    #expect(!manager.isWiFiReconnectBackingOff)
    #expect(manager.wifiTransport == nil)
    #expect(await harness.transport.connectAttempts > 0, "The BLE connect itself must still proceed")
  }

  @Test
  func `switching to a BLE radio stands the WiFi side down`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager

    manager.setTestState(
      connectionState: .ready,
      connectedDevice: DeviceDTO.testDevice(id: UUID()),
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    let reconnectTask = parkedTask()
    manager.wifiReconnectTask = reconnectTask
    manager.wifiHeartbeatTask = parkedTask()
    manager.wifiTransport = WiFiTransport()

    await #expect(throws: (any Error).self) {
      try await manager.switchDevice(to: UUID())
    }

    #expect(reconnectTask.isCancelled)
    #expect(manager.wifiReconnectTask == nil)
    #expect(manager.wifiHeartbeatTask == nil)
    #expect(manager.wifiTransport == nil)
  }

  @Test
  func `connecting to the radio already connected over WiFi keeps the heartbeat`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager
    let deviceID = UUID()

    manager.setTestState(
      connectionState: .ready,
      connectedDevice: DeviceDTO.testDevice(id: deviceID),
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    let heartbeat = parkedTask()
    manager.wifiHeartbeatTask = heartbeat
    manager.wifiTransport = WiFiTransport()

    try await manager.connect(to: deviceID)

    #expect(!heartbeat.isCancelled)
    #expect(manager.wifiHeartbeatTask != nil)
    #expect(manager.wifiTransport != nil)

    manager.stopWiFiHeartbeat()
  }

  // MARK: - Manual connect adopted by auto-reconnect

  /// The link drops while a manual connect is mid-setup and the auto-reconnect
  /// entry adopts it, releasing the manual claim. When the manual flow then
  /// finds its promotion suppressed, it must stop its session without
  /// disconnecting the transport the reconnect cycle now waits on.
  @Test(
    .timeLimit(.minutes(1))
  )
  func `manual connect adopted by auto-reconnect leaves the transport link up`() async throws {
    let harness = try makeManager(transport: HandshakeOnlyBLETransport())
    defer { harness.cleanup() }
    let manager = harness.manager
    let stateMachine = harness.stateMachine
    let deviceID = UUID()

    try await waitUntil("auto-reconnect handler should be installed") {
      await stateMachine.hasAutoReconnectingHandler
    }

    manager.onConnectionReady = {
      await stateMachine.simulateAutoReconnecting(deviceID: deviceID)
      try? await waitUntil("entry should adopt the connect and tear its session down") {
        manager.reconnectionCoordinator.reconnectingDeviceID == deviceID && manager.services == nil
      }
    }

    try await manager.connect(to: deviceID, forceReconnect: true)

    #expect(manager.reconnectionCoordinator.reconnectingDeviceID == deviceID)
    #expect(manager.connectionState == .connecting)
    #expect(
      await harness.transport.disconnectInvocations == 0,
      "Disconnecting here cancels the OS pending connect the reconnect cycle is waiting on"
    )

    manager.onConnectionReady = nil
    manager.reconnectionCoordinator.cancelTimeout()
    manager.cancelResyncLoop()
  }

  // MARK: - WiFi reconnect after the fast window

  /// A drop inside the cooldown still owes a retry: the loop defers its fast
  /// window to the cooldown's end instead of abandoning the link.
  @Test
  func `WiFi loss inside the reconnect cooldown defers the retry instead of giving up`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager
    let (session, services) = try await makeServices()
    manager.setTestState(
      connectionState: .ready,
      services: services,
      session: session,
      connectedDevice: DeviceDTO.testDevice(),
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    // Never connected, so the health check sees a dead link.
    manager.wifiTransport = WiFiTransport()
    let lastStart = Date()
    manager.lastWiFiReconnectStartTime = lastStart

    let lostTracker = CallTracker()
    manager.onConnectionLost = { lostTracker.markCalled() }

    await manager.checkWiFiConnectionHealth()

    #expect(manager.wifiReconnectTask != nil, "A drop inside the cooldown must still schedule a retry")
    #expect(manager.connectionState == .connecting)
    #expect(manager.services == nil)
    #expect(!lostTracker.wasCalled, "The deferred window has not run, so the link is not given up")
    #expect(manager.lastWiFiReconnectStartTime == lastStart, "The deferred window must not restart the cooldown early")

    manager.cancelWiFiReconnection()
  }

  /// Runs the real reconnect window: the loop has no connection info to
  /// reconnect with, so every attempt fails until the window expires. The loss
  /// is reported then, and the loop carries on in the slow backoff.
  @Test(
    .timeLimit(.minutes(2))
  )
  func `WiFi reconnect window expiry notifies connection lost and keeps retrying`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager
    let (session, services) = try await makeServices()
    manager.setTestState(
      connectionState: .ready,
      services: services,
      session: session,
      connectedDevice: DeviceDTO.testDevice(),
      currentTransportType: .wifi,
      connectionIntent: .wantsConnection()
    )
    manager.wifiTransport = WiFiTransport()

    let lostTracker = CallTracker()
    manager.onConnectionLost = { lostTracker.markCalled() }

    await manager.checkWiFiConnectionHealth()
    #expect(manager.connectionState == .connecting)
    #expect(!lostTracker.wasCalled, "The loss is reported when the fast window expires, not while it runs")

    try await waitUntil(timeout: Self.giveUpObservationWindow, "window expiry must notify observers of the loss") {
      lostTracker.wasCalled
    }
    #expect(lostTracker.callCount == 1)
    #expect(manager.connectionState == .disconnected)
    #expect(manager.isWiFiReconnectBackingOff)
    let backoffTask = try #require(manager.wifiReconnectTask, "The loop must keep retrying after the fast window")

    // A foreground skips the remaining backoff with a fresh fast window.
    await manager.checkWiFiConnectionHealth()
    #expect(backoffTask.isCancelled)
    #expect(manager.wifiReconnectTask != nil)
    #expect(!manager.isWiFiReconnectBackingOff)
    #expect(manager.connectionState == .connecting)

    // A manual disconnect ends the loop for good.
    await manager.disconnect(reason: .userInitiated)
    #expect(manager.wifiReconnectTask == nil)
    #expect(!manager.isWiFiReconnectBackingOff)
  }

  /// Covers `wifiMaxReconnectDuration` plus the loop's final backoff sleep.
  private static let giveUpObservationWindow: Duration = .seconds(60)

  @Test
  func `WiFi slow reconnect backoff doubles from 30 seconds to a 5 minute cap`() {
    let delays = (1...7).map { ConnectionManager.wifiSlowReconnectDelay(afterAttempt: $0) }
    #expect(delays == [.seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(300), .seconds(300), .seconds(300)])
    #expect(ConnectionManager.wifiSlowReconnectDelay(afterAttempt: 1000) == .seconds(300))
  }

  @Test
  func `WiFi reconnect deferral covers only the rest of the cooldown`() {
    #expect(ConnectionManager.wifiReconnectDeferral(sinceLastStart: nil) == nil)
    #expect(ConnectionManager.wifiReconnectDeferral(sinceLastStart: 0) == .seconds(35))
    #expect(ConnectionManager.wifiReconnectDeferral(sinceLastStart: 10) == .seconds(25))
    #expect(ConnectionManager.wifiReconnectDeferral(sinceLastStart: 35) == nil)
    #expect(ConnectionManager.wifiReconnectDeferral(sinceLastStart: 120) == nil)
  }

  // MARK: - Sessions awaiting re-auth

  @Test
  func `a second reconnect teardown keeps the sessions still awaiting re-auth`() async throws {
    let harness = try makeManager()
    defer { harness.cleanup() }
    let manager = harness.manager
    let roomSessionID = UUID()

    let (firstSession, firstServices) = try await makeServices()
    try await firstServices.dataStore.saveRemoteNodeSessionDTO(
      RemoteNodeSessionDTO.testSession(id: roomSessionID, radioID: UUID(), isConnected: true)
    )
    manager.setTestState(
      connectionState: .connecting,
      services: firstServices,
      session: firstSession,
      connectionIntent: .wantsConnection()
    )

    await manager.teardownSessionForReconnect()
    #expect(manager.sessionsAwaitingReauth == [roomSessionID])

    // The link drops again before re-auth ran: the rebuilt container finds
    // no connected sessions, since the first drop already marked them down.
    let (secondSession, secondServices) = try await makeServices()
    manager.setTestState(services: secondServices, session: secondSession)

    await manager.teardownSessionForReconnect()

    #expect(
      manager.sessionsAwaitingReauth == [roomSessionID],
      "A second drop must not discard the sessions still owed a re-auth"
    )
  }
}

/// BLE transport double for a radio that cannot be reached: every connect and
/// switch fails immediately, so connect paths fail fast after their
/// pre-connect work instead of waiting on a session handshake.
private actor UnreachableBLETransport: iOSMeshTransport {
  private let dataStream: AsyncStream<Data>
  private let dataContinuation: AsyncStream<Data>.Continuation
  private(set) var connectAttempts = 0

  init() {
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    dataStream = stream
    dataContinuation = continuation
  }

  var receivedData: AsyncStream<Data> {
    dataStream
  }

  var isConnected: Bool {
    false
  }

  func connect() async throws {
    connectAttempts += 1
    throw BLEError.bluetoothPoweredOff
  }

  func disconnect() async {}

  func send(_ data: Data) async throws {
    throw MeshTransportError.notConnected
  }

  func setDeviceID(_ id: UUID) {}

  func switchDevice(to deviceID: UUID) async throws {
    throw BLEError.bluetoothPoweredOff
  }

  func setDisconnectionHandler(_ handler: @escaping @Sendable (UUID, Error?) -> Void) {}
  func setReconnectionHandler(_ handler: @escaping @Sendable (UUID) -> Void) {}
  func refreshDataStream() {}
}

/// BLE transport double that completes the session handshake and the device
/// query, then fails every later command, so a connect reaches its sync phase
/// and that sync fails fast instead of waiting out command timeouts.
private actor HandshakeOnlyBLETransport: iOSMeshTransport {
  private let dataStream: AsyncStream<Data>
  private let dataContinuation: AsyncStream<Data>.Continuation
  private var connected = false
  private(set) var disconnectInvocations = 0

  init() {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingOldest(512)
    )
    dataStream = stream
    dataContinuation = continuation
  }

  var receivedData: AsyncStream<Data> {
    dataStream
  }

  var isConnected: Bool {
    connected
  }

  func connect() async throws {
    connected = true
  }

  func disconnect() async {
    disconnectInvocations += 1
    connected = false
  }

  func send(_ data: Data) async throws {
    switch data.first {
    case CommandCode.appStart.rawValue:
      dataContinuation.yield(Self.selfInfoPacket())
    case CommandCode.deviceQuery.rawValue:
      dataContinuation.yield(Self.deviceInfoPacket())
    default:
      throw MeshTransportError.notConnected
    }
  }

  func setDeviceID(_ id: UUID) {}
  func switchDevice(to deviceID: UUID) async throws {}
  func setDisconnectionHandler(_ handler: @escaping @Sendable (UUID, Error?) -> Void) {}
  func setReconnectionHandler(_ handler: @escaping @Sendable (UUID) -> Void) {}
  func refreshDataStream() {}

  private static func selfInfoPacket() -> Data {
    var payload = Data([ResponseCode.selfInfo.rawValue])
    payload.append(1) // adv type
    payload.append(UInt8(bitPattern: 22)) // tx power
    payload.append(UInt8(bitPattern: 22)) // max tx power
    payload.append(Data(repeating: 0x01, count: 32)) // pubkey
    payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
    payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
    payload.append(0) // multi acks
    payload.append(0) // adv loc policy
    payload.append(0) // telemetry mode
    payload.append(0) // manual add
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) }) // freq
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) }) // bw
    payload.append(11) // sf
    payload.append(5) // cr
    return payload
  }

  private static func deviceInfoPacket() -> Data {
    var payload = Data([ResponseCode.deviceInfo.rawValue])
    payload.append(8) // firmware version
    payload.append(50) // max contacts / 2
    payload.append(8) // max channels
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // ble pin
    payload.append(Data(count: 12)) // firmware build
    payload.append(Data(count: 40)) // model
    payload.append(Data(count: 20)) // version
    return payload
  }
}
