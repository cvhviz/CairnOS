import Foundation
import MeshCore
import Testing
@testable import CairnServices

/// The demo radio (`SimulatorMockTransport`) behind a real `MeshCoreSession` and `SettingsService`:
/// picking a preset writes it, reads it back and publishes it, as on a radio, and the refusals
/// a write can meet surface as settings errors.
@Suite("SettingsService on the simulator radio")
struct SettingsServiceSimulatorRadioTests {
  private static let device = MockDataProvider.simulatorDevice

  /// A started session over a fresh simulator radio, with its settings service and the events it
  /// publishes.
  private static func makeRadio() async throws -> (SimulatorMockTransport, SettingsService, SettingsEventLog) {
    let transport = SimulatorMockTransport(device: device, unemulated: .failAtOnce)
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let service = SettingsService(session: session)
    let log = SettingsEventLog()
    await log.listen(to: service)
    return (transport, service, log)
  }

  @Test
  func `the session starts on the seeded device's settings`() async throws {
    let (_, service, _) = try await Self.makeRadio()
    let info = try await service.getSelfInfo()
    #expect(info.name == Self.device.nodeName)
    #expect(Self.device.updating(from: info) == Self.device, "a read-back before any write must change nothing")
  }

  @Test
  func `a PIN set on the demo radio reads back, survives its reboot and can go back to default`() async throws {
    let (_, service, _) = try await Self.makeRadio()
    #expect(try await service.readBlePin() == 0)
    try await service.setBlePin(654_321)
    #expect(try await service.readBlePin() == 654_321)
    try await service.reboot()
    #expect(try await service.readBlePin() == 654_321)
    try await service.setBlePin(0)
    #expect(try await service.readBlePin() == 0)
  }

  @Test
  func `applying USA writes it, reads it back and publishes it with its id`() async throws {
    let (transport, service, log) = try await Self.makeRadio()
    let usa = try #require(RadioPresets.all.first { $0.id == "us-ca" })

    let info = try await service.applyRadioPresetVerified(usa)

    #expect(info.radioFrequencyKHz == 910_525)
    #expect(info.radioBandwidthHz == 62_500)
    #expect(info.radioSpreadingFactor == 7)
    #expect(info.radioCodingRate == 5)
    let radio = await transport.radio
    #expect(radio.frequencyKHz == 910_525 && radio.bandwidthHz == 62_500)
    #expect(radio.spreadingFactor == 7 && radio.codingRate == 5)
    try await log.waitFor { $0.contains { $0.appliedID == "us-ca" } }
    let updated = try #require(await log.deviceUpdates.last)
    let device = Self.device.updating(from: updated.info)
    #expect(device.frequency == 910_525 && device.bandwidth == 62_500)
    #expect(device.spreadingFactor == 7 && device.codingRate == 5)
  }

  @Test
  func `every catalog preset applies and reads back on the simulator radio`() async throws {
    let (transport, service, _) = try await Self.makeRadio()
    for preset in RadioPresets.all {
      let info = try await service.applyRadioPresetVerified(preset)
      #expect(info.radioFrequencyKHz == preset.frequencyKHz, "\(preset.id)")
      #expect(info.radioBandwidthHz == preset.bandwidthHz, "\(preset.id)")
      if let mode = preset.pathHashMode {
        #expect(await transport.radio.pathHashMode == mode, "\(preset.id)")
      }
    }
  }

  @Test
  func `a path-hash preset publishes its frequency settings before its catalog id`() async throws {
    let (transport, service, log) = try await Self.makeRadio()
    let wcmesh = try #require(RadioPresets.all.first { $0.id == "wcmesh" })

    _ = try await service.applyRadioPresetVerified(wcmesh)

    #expect(await transport.radio.pathHashMode == 2)
    try await log.waitFor { $0.contains { $0.appliedID == "wcmesh" } }
    let updates = await log.deviceUpdates
    #expect(updates.map(\.appliedID) == [nil, "wcmesh"])
    #expect(updates.allSatisfy { $0.info.radioFrequencyKHz == 927_875 })
    #expect(await log.pathHashModes == [2])
  }

  @Test
  func `a refused path hash write publishes the new frequency settings without an id and can be retried`() async throws {
    let transport = SimulatorMockTransport(device: Self.device, refusingOnce: [.setPathHashMode], unemulated: .failAtOnce)
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let service = SettingsService(session: session)
    let log = SettingsEventLog()
    await log.listen(to: service)
    let wcmesh = try #require(RadioPresets.all.first { $0.id == "wcmesh" })

    do {
      _ = try await service.applyRadioPresetVerified(wcmesh)
      Issue.record("expected the hash step to fail")
    } catch let error as SettingsServiceError {
      guard case let .presetPathHashNotApplied(name) = error else {
        Issue.record("expected .presetPathHashNotApplied, got \(error)")
        return
      }
      #expect(name == wcmesh.name)
      #expect(!error.isRetryable)
    }
    #expect(await transport.radio.frequencyKHz == 927_875)
    #expect(await transport.radio.pathHashMode == Self.device.pathHashMode)
    try await log.waitFor { !$0.isEmpty }
    #expect(await log.deviceUpdates.map(\.appliedID) == [nil])

    // Picking it again writes it again, and this time the hash size lands with the catalog id.
    _ = try await service.applyRadioPresetVerified(wcmesh)
    #expect(await transport.radio.pathHashMode == 2)
    try await log.waitFor { $0.contains { $0.appliedID == "wcmesh" } }
  }

  @Test
  func `a link drop during the path hash step stays a retryable error`() async throws {
    let inner = SimulatorMockTransport(device: Self.device, unemulated: .failAtOnce)
    let transport = DroppingTransport(inner: inner, stream: await inner.receivedData)
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let service = SettingsService(session: session)
    let wcmesh = try #require(RadioPresets.all.first { $0.id == "wcmesh" })
    await transport.drop(.deviceQuery)

    do {
      _ = try await service.applyRadioPresetVerified(wcmesh)
      Issue.record("expected the hash step to fail")
    } catch let error as SettingsServiceError {
      #expect(error.isRetryable, "got \(error)")
    }
    #expect(await inner.radio.frequencyKHz == 927_875)
  }

  @Test
  func `the one-shot refusal list reads the emulated commands' names`() {
    #expect(SimulatorMockTransport.commands(named: "setPathHashMode, setRadio,bogus") == [.setPathHashMode, .setRadio])
    #expect(SimulatorMockTransport.commands(named: nil).isEmpty)
  }

  @Test
  func `the simulator radio refuses Repeat Mode off the repeat frequencies, as the firmware does`() async throws {
    let (transport, service, _) = try await Self.makeRadio()
    do {
      _ = try await service.setRadioParamsVerified(
        frequencyKHz: 910_525,
        bandwidthKHz: 62_500,
        spreadingFactor: 7,
        codingRate: 5,
        clientRepeat: true
      )
      Issue.record("expected the radio to refuse")
    } catch SettingsServiceError.sessionError(.deviceError(let code)) {
      #expect(code == ErrorCode.illegalArgument.rawValue)
    }
    #expect(await transport.radio.frequencyKHz == Self.device.frequency)
  }

  @Test
  func `a radio write over a link that is down is a retryable not-connected error`() async throws {
    // No start(): the transport never connects, as when the link has dropped.
    let service = SettingsService(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let usa = try #require(RadioPresets.all.first { $0.id == "us-ca" })
    do {
      _ = try await service.applyRadioPresetVerified(usa)
      Issue.record("expected the write to fail")
    } catch let error as SettingsServiceError {
      guard case .notConnected = error else {
        Issue.record("expected .notConnected, got \(error)")
        return
      }
      #expect(error.isRetryable)
    }
  }

  @Test
  func `commands the simulator radio doesn't emulate still fail at once`() async throws {
    let transport = SimulatorMockTransport(device: Self.device, unemulated: .failAtOnce)
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let started = ContinuousClock.now
    await #expect(throws: (any Error).self) {
      _ = try await session.getBattery()
    }
    #expect(ContinuousClock.now - started < .seconds(2))
  }

  /// The firmware answers a discover request with OK once it has sent it; the demo radio does
  /// too, so a scan or Wardrive on it listens instead of failing as not connected.
  @Test
  func `the simulator radio sends a node discover request and answers OK`() async throws {
    let transport = SimulatorMockTransport(device: Self.device, unemulated: .failAtOnce)
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let started = ContinuousClock.now
    let tag = try await session.sendNodeDiscoverRequest(filter: 0x04, prefixOnly: false, tag: 0xC0FFEE) // repeaters
    #expect(tag == 0xC0FFEE)
    #expect(ContinuousClock.now - started < .seconds(2))
  }

  @Test
  func `transport failures map to settings errors`() {
    guard case .notConnected = SettingsServiceError(transportError: .notConnected) else {
      Issue.record("notConnected")
      return
    }
    guard case .sendFailed = SettingsServiceError(transportError: .sendFailed("x")) else {
      Issue.record("sendFailed")
      return
    }
  }
}

/// The `SettingsEvent`s a service publishes, in order.
private actor SettingsEventLog {
  struct DeviceUpdate: Sendable {
    let info: MeshCore.SelfInfo
    let appliedID: String?
  }

  private(set) var deviceUpdates: [DeviceUpdate] = []
  private(set) var pathHashModes: [UInt8] = []
  private var task: Task<Void, Never>?

  func listen(to service: SettingsService) async {
    let stream = await service.events()
    task = Task {
      for await event in stream {
        self.record(event)
      }
    }
  }

  private func record(_ event: SettingsEvent) {
    switch event {
    case let .deviceUpdated(info, appliedID):
      deviceUpdates.append(DeviceUpdate(info: info, appliedID: appliedID))
    case let .pathHashModeUpdated(mode):
      pathHashModes.append(mode)
    default:
      break
    }
  }

  func waitFor(
    _ condition: @Sendable ([DeviceUpdate]) -> Bool,
    timeout: Duration = .seconds(5)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(deviceUpdates) {
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out waiting for settings events: \(deviceUpdates.map(\.appliedID))")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// The simulator radio behind a link that drops on one command, as a Bluetooth link can mid-write.
private actor DroppingTransport: MeshTransport {
  private let inner: SimulatorMockTransport
  private let stream: AsyncStream<Data>
  private var dropping: CommandCode?

  init(inner: SimulatorMockTransport, stream: AsyncStream<Data>) {
    self.inner = inner
    self.stream = stream
  }

  func drop(_ code: CommandCode) {
    dropping = code
  }

  var receivedData: AsyncStream<Data> {
    stream
  }

  var isConnected: Bool {
    get async { await inner.isConnected }
  }

  var droppedFrameCount: Int {
    0
  }

  func connect() async throws {
    try await inner.connect()
  }

  func disconnect() async {
    await inner.disconnect()
  }

  func send(_ data: Data) async throws {
    if let dropping, data.first == dropping.rawValue {
      throw MeshTransportError.notConnected
    }
    try await inner.send(data)
  }
}
