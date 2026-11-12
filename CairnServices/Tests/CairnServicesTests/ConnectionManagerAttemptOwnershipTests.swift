import Foundation
@testable import CairnServices
import MeshCore
import Network
import os
import Testing

/// Covers who owns the link while a connect is in flight: a WiFi connect must not be read as a
/// stale Bluetooth link by the foreground health check, an opportunistic reconnect must never
/// cancel a connect the user started, a radio switch mid handshake must survive the superseded
/// connect's failure, a failing WiFi connect must not tear down a Bluetooth connection that
/// took over meanwhile, and launch must try the transport the radio last used.
@Suite("ConnectionManager Attempt Ownership Tests")
@MainActor
struct ConnectionManagerAttemptOwnershipTests {
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

  private func makeServices() async throws -> (MeshCoreSession, ServiceContainer) {
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "OwnershipTest")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    return (session, services)
  }

  // MARK: - WiFi connect in flight vs the BLE health check

  /// Tapping Allow on the Local Network prompt (or any Control Center pull, or a Mac window
  /// focus) foregrounds the app while the WiFi connect is mid handshake. The BLE health check
  /// must see a WiFi attempt, not a stale Bluetooth link to tear down or reconnect over.
  @Test(.timeLimit(.minutes(1)))
  func `a WiFi connect in flight is not mistaken for a stale Bluetooth link`() async throws {
    let listener = try await SilentTCPListener.start()
    defer { listener.stop() }
    let harness = try makeManager(transport: MockMeshTransport())
    defer { harness.cleanup() }
    let manager = harness.manager
    manager.testLastConnectedDeviceID = UUID()
    manager.setTestState(connectionIntent: .wantsConnection())

    let wifiConnect = Task { try await manager.connectViaWiFi(host: "127.0.0.1", port: listener.port) }
    try await waitUntil("the WiFi connect should reach its handshake") {
      manager.connectionState == .connected
    }
    #expect(manager.currentTransportType == .wifi, "The in-flight WiFi attempt marks its transport at once")

    await manager.appDidBecomeActive()
    await manager.checkBLEConnectionHealth()

    #expect(manager.connectionState == .connected, "The health check must not tear the WiFi connect down")
    #expect(manager.wifiTransport != nil)
    #expect(await harness.transport.connectInvocations.isEmpty, "No Bluetooth connect may start over a WiFi attempt")
    #expect(!manager.isReconnectionWatchdogRunning, "The BLE watchdog stands down while WiFi owns the link")

    await manager.disconnect(reason: .userInitiated)
    await #expect(throws: (any Error).self) { try await wifiConnect.value }
  }

  @Test
  func `an opportunistic reconnect never cancels a connect the user started`() async throws {
    let harness = try makeManager(transport: MockMeshTransport())
    defer { harness.cleanup() }
    let manager = harness.manager
    let lastRadio = UUID()
    let userTarget = UUID()
    manager.testLastConnectedDeviceID = lastRadio
    manager.setTestState(
      connectionState: .connecting,
      connectionIntent: .wantsConnection(),
      connectingDeviceID: userTarget
    )

    await manager.attemptOpportunisticReconnect(deviceID: lastRadio, reason: "test")
    await manager.checkBLEConnectionHealth()

    #expect(manager.connectingDeviceID == userTarget)
    #expect(manager.connectionState == .connecting)
    #expect(await harness.transport.connectInvocations.isEmpty)
    #expect(await harness.transport.disconnectInvocations == 0)
  }

  /// Between a fresh connect's BLE link coming up and its services being installed, the
  /// health check sees a connected transport with no app stack. Rebuilding then would start
  /// a second session over the same link.
  @Test
  func `a fresh connect between link-up and services is not rebuilt by the health check`() async throws {
    let harness = try makeManager(transport: MockMeshTransport())
    defer { harness.cleanup() }
    let manager = harness.manager
    let stateMachine = harness.stateMachine
    let deviceID = UUID()
    manager.testLastConnectedDeviceID = deviceID
    await stateMachine.setStubbedIsConnected(true)
    await stateMachine.setStubbedConnectedDeviceID(deviceID)
    manager.setTestState(
      connectionState: .connected,
      connectionIntent: .wantsConnection(),
      connectingDeviceID: deviceID
    )

    await manager.checkBLEConnectionHealth()

    #expect(manager.sessionRebuildDeviceID == nil, "No second session may be rebuilt under the connect")
    #expect(manager.connectionState == .connected)
    #expect(manager.connectingDeviceID == deviceID)
  }

  // MARK: - Switching radios mid handshake

  /// Radio A's connect hangs in its handshake when the user picks radio B. The switch claims
  /// the link; A's connect then fails, and its retry loop must neither stop B's session nor
  /// disconnect the transport B now uses, nor retry A over it.
  @Test(.timeLimit(.minutes(1)))
  func `switching radios mid handshake survives the superseded connect's failure`() async throws {
    let transport = GatedHandshakeTransport()
    let harness = try makeManager(transport: transport)
    defer { harness.cleanup() }
    let manager = harness.manager
    let radioA = UUID()
    let radioB = UUID()
    await transport.setAnsweringDevice(radioB)

    let connectA = Task { try await manager.connect(to: radioA) }
    try await waitUntil("A should reach its handshake") {
      manager.connectionState == .connected && manager.connectingDeviceID == radioA
    }

    try await manager.connect(to: radioB)
    #expect(manager.connectedDevice?.id == radioB)
    let sessionB = try #require(manager.session)
    let servicesB = try #require(manager.services)
    let disconnectsAfterSwitch = await transport.disconnectInvocations

    await #expect(throws: (any Error).self) { try await connectA.value }

    #expect(manager.session === sessionB, "A's failure must not stop B's session")
    #expect(manager.services === servicesB)
    #expect(manager.connectedDevice?.id == radioB)
    #expect(await transport.disconnectInvocations == disconnectsAfterSwitch, "A's retry must not disconnect B's transport")
    #expect(await transport.currentDevice == radioB)
    let connectsForA = await transport.connectCount(for: radioA)
    #expect(connectsForA == 1, "A must not be retried over B's link (connects: \(connectsForA))")
    #expect(manager.connectingDeviceID == nil)
    #expect(manager.connectionAttemptTransport == nil)

    manager.cancelResyncLoop()
    manager.cancelChannelRetry()
    await manager.disconnect(reason: .userInitiated)
  }

  // MARK: - WiFi failure vs a Bluetooth connection that took over

  @Test(.timeLimit(.minutes(1)))
  func `a failing WiFi connect leaves a Bluetooth connection that took over untouched`() async throws {
    let listener = try await SilentTCPListener.start()
    defer { listener.stop() }
    let harness = try makeManager(transport: MockMeshTransport())
    defer { harness.cleanup() }
    let manager = harness.manager

    let wifiConnect = Task { try await manager.connectViaWiFi(host: "127.0.0.1", port: listener.port) }
    try await waitUntil("the WiFi connect should reach its handshake") {
      manager.connectionState == .connected && manager.currentTransportType == .wifi
    }

    // A Bluetooth connect claims the link and finishes while the WiFi handshake hangs.
    let (bleSession, bleServices) = try await makeServices()
    let bleAttempt = manager.beginConnectionAttempt(.bluetooth)
    manager.setTestState(
      connectionState: .ready,
      services: bleServices,
      session: bleSession,
      connectedDevice: DeviceDTO.testDevice(),
      currentTransportType: .bluetooth
    )
    manager.endConnectionAttempt(bleAttempt)

    wifiConnect.cancel()
    await #expect(throws: (any Error).self) { try await wifiConnect.value }

    #expect(manager.services === bleServices, "The WiFi failure path must not tear down the Bluetooth services")
    #expect(manager.session === bleSession)
    #expect(manager.connectionState == .ready)
    #expect(manager.currentTransportType == .bluetooth)
    #expect(manager.wifiTransport == nil, "The failed attempt still releases its own transport")
  }

  @Test(.timeLimit(.minutes(1)))
  func `a failed WiFi connect it still owns returns to disconnected`() async throws {
    let closedPort = try await SilentTCPListener.closedPort()
    let harness = try makeManager(transport: MockMeshTransport())
    defer { harness.cleanup() }
    let manager = harness.manager

    await #expect(throws: (any Error).self) {
      try await manager.connectViaWiFi(host: "127.0.0.1", port: closedPort)
    }

    #expect(manager.connectionState == .disconnected)
    #expect(manager.currentTransportType == nil)
    #expect(manager.connectionAttemptTransport == nil)
    #expect(manager.wifiTransport == nil)
  }

  // MARK: - Launch transport order

  @Test
  func `launch prefers the transport the radio last used`() {
    let key = Data(repeating: 0x07, count: 32)
    let derived = DeviceIdentity.deriveUUID(from: key)
    let peripheral = UUID()

    #expect(ConnectionManager.prefersWiFiAtLaunch(lastTransport: .wifi, deviceID: peripheral, publicKey: key))
    #expect(!ConnectionManager.prefersWiFiAtLaunch(lastTransport: .bluetooth, deviceID: derived, publicKey: key))
    // Nothing recorded: a record whose ID derives from the key was last saved over WiFi.
    #expect(ConnectionManager.prefersWiFiAtLaunch(lastTransport: nil, deviceID: derived, publicKey: key))
    #expect(!ConnectionManager.prefersWiFiAtLaunch(lastTransport: nil, deviceID: peripheral, publicKey: key))
    #expect(!ConnectionManager.prefersWiFiAtLaunch(lastTransport: nil, deviceID: peripheral, publicKey: nil))
  }

  @Test
  func `the last transport is remembered per radio`() throws {
    let suiteName = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let store = LastConnectionStore(defaults: defaults)
    let radioA = UUID()
    let radioB = UUID()

    store.persistTransport(.wifi, forRadio: radioA)
    store.persistTransport(.bluetooth, forRadio: radioB)

    #expect(store.transport(forRadio: radioA) == .wifi)
    #expect(store.transport(forRadio: radioB) == .bluetooth)
    #expect(store.transport(forRadio: UUID()) == nil)

    store.persistTransport(.bluetooth, forRadio: radioA)
    #expect(store.transport(forRadio: radioA) == .bluetooth)
  }

  /// A radio saved with both transports, last used over Bluetooth: launch connects over
  /// Bluetooth and never tries the WiFi address first.
  @Test(.timeLimit(.minutes(1)))
  func `launch tries Bluetooth first for a radio last used over Bluetooth`() async throws {
    let listener = try await SilentTCPListener.start()
    defer { listener.stop() }
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    let manager = env.manager
    env.accessorySetupKit.isSessionActive = false
    await env.transport.setConnectError(BLEError.connectionTimeout)

    let peripheralID = UUID()
    let device = DeviceDTO.testDevice(id: peripheralID).copy {
      $0.connectionMethods = [
        .bluetooth(peripheralUUID: peripheralID, displayName: nil),
        .wifi(host: "127.0.0.1", port: listener.port, displayName: nil),
      ]
    }
    try await manager.persistenceStore.saveDevice(device)
    manager.persistConnection(deviceID: peripheralID, radioID: device.radioID, deviceName: "Radio", transport: .bluetooth)
    manager.testLastConnectedDeviceID = peripheralID

    await manager.activate()
    await manager.launchReconnectTask?.value

    let invocations = await env.transport.connectInvocations
    #expect(!invocations.isEmpty, "Launch should connect over Bluetooth")
    #expect(invocations.allSatisfy { $0.deviceID == peripheralID })
    #expect(listener.acceptCount == 0, "The WiFi address must not be tried first")
    #expect(manager.isReconnectionWatchdogRunning, "A failed Bluetooth launch reconnect arms the watchdog")

    manager.stopReconnectionWatchdog()
  }

  /// Connect on Launch off: launch leaves the last radio alone, connecting nothing, starting no
  /// reconnect and arming no watchdog, and doesn't want the link until the user connects.
  @Test(.timeLimit(.minutes(1)))
  func `launch leaves the radio alone with Connect on Launch off`() async throws {
    let suiteName = "ConnectOnLaunchOff-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: AppStorageKey.connectOnLaunch.rawValue)
    let env = try ConnectionManager.createForPairingTesting(defaults: defaults)
    defer { env.cleanup() }
    let manager = env.manager
    env.accessorySetupKit.isSessionActive = false

    let peripheralID = UUID()
    let device = DeviceDTO.testDevice(id: peripheralID).copy {
      $0.connectionMethods = [.bluetooth(peripheralUUID: peripheralID, displayName: nil)]
    }
    try await manager.persistenceStore.saveDevice(device)
    manager.persistConnection(deviceID: peripheralID, radioID: device.radioID, deviceName: "Radio", transport: .bluetooth)
    manager.testLastConnectedDeviceID = peripheralID

    await manager.activate()

    #expect(manager.launchReconnectTask == nil, "No launch reconnect should start")
    #expect(await env.transport.connectInvocations.isEmpty, "Launch must not connect")
    #expect(!manager.isReconnectionWatchdogRunning)
    #expect(!manager.isConnectionWanted, "The link is wanted only once the user connects")
    #expect(!manager.shouldSuppressDisconnectedPill, "The disconnected pill offers the connect")
  }

  /// A radio last used over WiFi whose address is unreachable at launch: the Bluetooth
  /// fallback must reach for the radio's stored peripheral, not the key-derived device ID,
  /// and once that fails too the WiFi reconnect loop keeps trying.
  @Test(.timeLimit(.minutes(1)))
  func `launch falls back to the stored Bluetooth peripheral and keeps retrying WiFi`() async throws {
    let closedPort = try await SilentTCPListener.closedPort()
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    let manager = env.manager
    env.accessorySetupKit.isSessionActive = false
    await env.transport.setConnectError(BLEError.connectionTimeout)

    let key = Data(repeating: 0x05, count: 32)
    let derivedID = DeviceIdentity.deriveUUID(from: key)
    let peripheralID = UUID()
    let device = DeviceDTO.testDevice(id: derivedID, publicKey: key).copy {
      $0.connectionMethods = [
        .bluetooth(peripheralUUID: peripheralID, displayName: nil),
        .wifi(host: "127.0.0.1", port: closedPort, displayName: nil),
      ]
    }
    try await manager.persistenceStore.saveDevice(device)
    manager.persistConnection(deviceID: derivedID, radioID: device.radioID, deviceName: "Radio", transport: .wifi)
    manager.testLastConnectedDeviceID = derivedID

    await manager.activate()
    await manager.launchReconnectTask?.value

    let invocations = await env.transport.connectInvocations
    #expect(!invocations.isEmpty, "The Bluetooth fallback should run after WiFi failed")
    #expect(invocations.allSatisfy { $0.deviceID == peripheralID }, "The fallback must use the stored peripheral ID")
    #expect(manager.wifiReconnectTask != nil, "The radio was last on WiFi: its reconnect loop takes over")
    #expect(manager.currentTransportType == .wifi)
    #expect(!manager.isReconnectionWatchdogRunning, "Only one retry loop runs")

    await manager.disconnect(reason: .userInitiated)
    #expect(manager.wifiReconnectTask == nil)
  }
}

// MARK: - Test doubles

/// A localhost TCP listener that accepts connections and never answers, standing in for a
/// radio whose WiFi handshake hangs.
private final class SilentTCPListener: @unchecked Sendable {
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

  static func start() async throws -> SilentTCPListener {
    let accepted = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])
    let listener = try NWListener(using: .tcp)
    listener.newConnectionHandler = { connection in
      accepted.withLock { $0.append(connection) }
      connection.start(queue: .global())
    }
    let states = AsyncStream<NWListener.State>.makeStream()
    listener.stateUpdateHandler = { state in
      states.continuation.yield(state)
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
    let wrapper = SilentTCPListener(listener: listener, port: port)
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

/// BLE transport double for two radios on one link: the handshake (app start and device
/// query) is answered only while the link is switched to the answering radio, so a connect
/// to any other radio hangs in its handshake. Later commands fail, so a connect that got
/// through reaches its sync phase and that sync fails fast. Each connect or switch vends a
/// fresh data stream, as the real transport does.
private actor GatedHandshakeTransport: iOSMeshTransport {
  private var dataStream: AsyncStream<Data>
  private var dataContinuation: AsyncStream<Data>.Continuation
  private var connected = false
  private var answeringDevice: UUID?
  private var linkedDevice: UUID?
  private(set) var currentDevice: UUID?
  private(set) var disconnectInvocations = 0
  private var connectCounts: [UUID: Int] = [:]

  init() {
    (dataStream, dataContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(512))
  }

  func setAnsweringDevice(_ deviceID: UUID) {
    answeringDevice = deviceID
  }

  func connectCount(for deviceID: UUID) -> Int {
    connectCounts[deviceID, default: 0]
  }

  var receivedData: AsyncStream<Data> {
    dataStream
  }

  var isConnected: Bool {
    connected
  }

  /// Idempotent for the device already linked, as the real transport is: a session's
  /// `start()` calls it again over the link its caller just opened.
  func connect() async throws {
    guard !connected || linkedDevice != currentDevice else { return }
    if let currentDevice {
      connectCounts[currentDevice, default: 0] += 1
    }
    renewStream()
    connected = true
    linkedDevice = currentDevice
  }

  func disconnect() async {
    disconnectInvocations += 1
    connected = false
    linkedDevice = nil
  }

  func send(_ data: Data) async throws {
    guard currentDevice != nil, currentDevice == answeringDevice else { return }
    switch data.first {
    case CommandCode.appStart.rawValue:
      dataContinuation.yield(Self.selfInfoPacket())
    case CommandCode.deviceQuery.rawValue:
      dataContinuation.yield(Self.deviceInfoPacket())
    default:
      throw MeshTransportError.notConnected
    }
  }

  func setDeviceID(_ id: UUID) {
    currentDevice = id
  }

  func switchDevice(to deviceID: UUID) async throws {
    currentDevice = deviceID
    connectCounts[deviceID, default: 0] += 1
    renewStream()
    connected = true
    linkedDevice = deviceID
  }

  func setDisconnectionHandler(_ handler: @escaping @Sendable (UUID, Error?) -> Void) {}
  func setReconnectionHandler(_ handler: @escaping @Sendable (UUID) -> Void) {}
  func refreshDataStream() {
    renewStream()
  }

  private func renewStream() {
    (dataStream, dataContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(512))
  }

  private static func selfInfoPacket() -> Data {
    var payload = Data([ResponseCode.selfInfo.rawValue])
    payload.append(1) // adv type
    payload.append(UInt8(bitPattern: 22)) // tx power
    payload.append(UInt8(bitPattern: 22)) // max tx power
    payload.append(Data(repeating: 0x02, count: 32)) // pubkey
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
