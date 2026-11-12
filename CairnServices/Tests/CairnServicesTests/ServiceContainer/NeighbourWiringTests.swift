import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// The container's neighbour, RX log and RX_SYNC lifecycle, and where RX_SYNC LOSS reports go.
@Suite("Neighbour wiring")
@MainActor
struct NeighbourWiringTests {
  private static let epoch: UInt32 = 0x5EED_0001

  // MARK: - Lifecycle

  @Test
  func `startEventMonitoring starts neighbours and RX_SYNC, stopEventMonitoring stops them`() async throws {
    let session = MeshCoreSession(transport: SimulatorMockTransport())
    let radioID = UUID()
    let container = try await ServiceContainer.forTesting(session: session, radioID: radioID)
    try await container.dataStore.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID))

    await container.startEventMonitoring(radioID: radioID, enableAutoFetch: false, enableAdvertisementMonitoring: false)
    // Neighbours subscribe before start returns, ahead of the RX log.
    #expect(await container.neighbourService.radioID == radioID)
    await container.rxStreamService.waitForStart()
    // A radio without Cairn firmware is never asked for RX_SYNC.
    #expect(await container.rxStreamService.mode == .stock)

    await container.stopEventMonitoring()
    #expect(await container.neighbourService.radioID == nil)
    #expect(await container.rxStreamService.mode == .idle)
  }

  @Test
  func `repeated start and stop leaves no subscription behind`() async throws {
    let session = MeshCoreSession(transport: SimulatorMockTransport())
    let radioID = UUID()
    let container = try await ServiceContainer.forTesting(session: session, radioID: radioID)
    try await container.dataStore.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID))

    await container.startEventMonitoring(radioID: radioID, enableAutoFetch: false, enableAdvertisementMonitoring: false)
    await container.stopEventMonitoring()
    try await Task.sleep(for: .milliseconds(200))
    let afterOneRun = await session.subscriberCountForTest

    for _ in 0 ..< 3 {
      await container.startEventMonitoring(radioID: radioID, enableAutoFetch: false, enableAdvertisementMonitoring: false)
      await container.stopEventMonitoring()
    }
    try await waitUntil("each run must release its subscriptions") {
      await session.subscriberCountForTest == afterOneRun
    }
  }

  @Test
  func `tearDown ends the neighbour update streams`() async throws {
    let session = MeshCoreSession(transport: SimulatorMockTransport())
    let radioID = UUID()
    let container = try await ServiceContainer.forTesting(session: session, radioID: radioID)
    try await container.dataStore.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID))

    let updates = await container.neighbourService.updates()
    let overheard = await container.neighbourService.overheardRequests()
    let ended = EndedStreams()
    let updatesTask = Task {
      for await _ in updates {}
      await ended.markUpdates()
    }
    let overheardTask = Task {
      for await _ in overheard {}
      await ended.markOverheard()
    }

    await container.startEventMonitoring(radioID: radioID, enableAutoFetch: false, enableAdvertisementMonitoring: false)
    await container.tearDown()

    try await waitUntil("tearDown must finish both neighbour streams") {
      let updatesEnded = await ended.updates
      let overheardEnded = await ended.overheard
      return updatesEnded && overheardEnded
    }
    _ = await updatesTask.result
    _ = await overheardTask.result
  }

  // MARK: - LOSS Reports

  @Test
  func `refused advert pushes ask for exactly one advert resync round`() async throws {
    let (session, transport) = try await makeStartedSession()
    let radioID = UUID()
    let container = try await makeCairnContainer(session: session, radioID: radioID)

    await container.startEventMonitoring(radioID: radioID, enableAutoFetch: false, enableAdvertisementMonitoring: false)
    await container.rxStreamService.waitForStart()
    #expect(await container.rxStreamService.mode == .synced)

    let advertisementService = container.advertisementService
    #expect(await advertisementService.deltaSyncTask == nil)
    #expect(await advertisementService.resyncRequested == false)
    let generation = await advertisementService.deltaSyncGeneration

    // 0x80 refused, then 0x8A refused while that round still waits for its debounce.
    await transport.simulateReceive(Self.loss(refusedMask: 1 << 0))
    try await waitUntil("the LOSS report must reach requestResync") {
      await advertisementService.resyncRequested
    }
    await transport.simulateReceive(Self.loss(refusedMask: 1 << 10))
    try await waitUntil("the second LOSS report must be handled") {
      await container.rxStreamService.deliveryStats().lossReports == 2
    }

    #expect(await advertisementService.deltaSyncGeneration == generation &+ 1)
    #expect(await advertisementService.deltaSyncTask != nil)
    #expect(await advertisementService.hasPendingDeltaSyncWork)

    await container.tearDown()
    await session.stop()
  }

  @Test
  func `a refused messages-waiting push drains the radio's message queue`() async throws {
    let (session, transport) = try await makeStartedSession()
    let radioID = UUID()
    let container = try await makeCairnContainer(session: session, radioID: radioID)

    await container.startEventMonitoring(radioID: radioID, enableAutoFetch: true, enableAdvertisementMonitoring: false)
    await container.rxStreamService.waitForStart()
    #expect(await container.rxStreamService.mode == .synced)
    // Auto-fetch drains once as it starts.
    try await waitUntil("auto-fetch must drain once on start") {
      await transport.messageFetches == 1
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.messageFetches == 1)

    await transport.simulateReceive(Self.loss(refusedMask: 1 << 3))
    try await waitUntil("the LOSS report must drain the queue again") {
      await transport.messageFetches == 2
    }
    #expect(await container.advertisementService.resyncRequested == false)

    await container.tearDown()
    await session.stop()
  }

  // MARK: - Helpers

  private func makeStartedSession() async throws -> (MeshCoreSession, RxSyncRadioTransport) {
    let transport = RxSyncRadioTransport(epoch: Self.epoch)
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 5, clientIdentifier: "MCTst")
    )
    try await session.start()
    return (session, transport)
  }

  private func makeCairnContainer(session: MeshCoreSession, radioID: UUID) async throws -> ServiceContainer {
    let container = try await ServiceContainer.forTesting(session: session, radioID: radioID)
    var device = DeviceDTO.testDevice(id: radioID, radioID: radioID)
    device.cairnBuild = 120
    try await container.dataStore.saveDevice(device)
    return container
  }

  /// A LOSS report: `[0xC9][1][epoch u32][overwritten u32][refused_mask u32][refused_count u16]`.
  private static func loss(refusedMask: UInt32) -> Data {
    Data([ResponseCode.rxSyncStatus.rawValue, 0x01]) + le32(epoch) + le32(0) + le32(refusedMask) + Data([0x01, 0x00])
  }
}

// MARK: - Test Doubles

private actor EndedStreams {
  private(set) var updates = false
  private(set) var overheard = false

  func markUpdates() {
    updates = true
  }

  func markOverheard() {
    overheard = true
  }
}

/// A Cairn companion with RX_SYNC: answers APP_START, RX_SYNC STATE and SUBSCRIBE, and message
/// fetches (with an empty queue). Anything else goes unanswered.
private actor RxSyncRadioTransport: MeshTransport {
  let receivedData: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let epoch: UInt32
  private var connected = false
  /// Message fetches (`CMD_SYNC_NEXT_MESSAGE`) the session sent.
  private(set) var messageFetches = 0

  var isConnected: Bool {
    connected
  }

  init(epoch: UInt32) {
    self.epoch = epoch
    (receivedData, continuation) = AsyncStream.makeStream(of: Data.self)
  }

  func connect() async throws {
    connected = true
  }

  func disconnect() async {
    connected = false
    continuation.finish()
  }

  func send(_ data: Data) async throws {
    guard connected else { throw MeshTransportError.notConnected }
    // The session subscribes before it sends, so answering here can't be missed.
    if let reply = reply(to: data) {
      continuation.yield(reply)
    }
  }

  func simulateReceive(_ data: Data) {
    continuation.yield(data)
  }

  private func reply(to data: Data) -> Data? {
    guard let code = data.first else { return nil }
    switch code {
    case CommandCode.appStart.rawValue:
      return selfInfoFrame()
    case CommandCode.getMessage.rawValue:
      messageFetches += 1
      return Data([ResponseCode.noMoreMessages.rawValue])
    case CommandCode.cairnFirmware.rawValue where data.count >= 3 && data[1] == CairnFirmwareSubcommand.rxSync:
      switch data[2] {
      case CairnRxSyncOp.state.rawValue:
        // [0xC0][0x07][OK][STATE][ver][epoch][first][last][cap][opted][overwritten][refused][mask]
        return Data([0xC0, 0x07, 0x00, 0x00, 0x01]) + le32(epoch) + le32(1) + le32(0) + le32(8192)
          + Data([0x00]) + le32(0) + le32(0) + le32(0)
      case CairnRxSyncOp.subscribe.rawValue:
        // [0xC0][0x07][OK][SUBSCRIBE][on][resumed][epoch][first][last][cursor]
        return Data([0xC0, 0x07, 0x00, 0x01, data.count > 3 ? data[3] : 0, 0x00]) + le32(epoch) + le32(1)
          + le32(0) + le32(1)
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private func selfInfoFrame() -> Data {
    var payload = Data([ResponseCode.selfInfo.rawValue])
    payload.append(1) // adv type
    payload.append(22) // tx power
    payload.append(22) // max tx power
    payload.append(Data(repeating: 0x01, count: 32)) // pubkey
    payload.append(le32(0)) // lat
    payload.append(le32(0)) // lon
    payload.append(contentsOf: [0, 0, 0, 0]) // multi acks, adv loc policy, telemetry mode, manual add
    payload.append(le32(869_525)) // freq
    payload.append(le32(250_000)) // bw
    payload.append(11) // sf
    payload.append(5) // cr
    return payload
  }
}

private func le32(_ value: UInt32) -> Data {
  withUnsafeBytes(of: value.littleEndian) { Data($0) }
}
