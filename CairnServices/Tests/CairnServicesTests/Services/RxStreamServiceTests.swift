import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

@Suite("RxStreamService")
struct RxStreamServiceTests {
  private static let epoch: UInt32 = 0x1234_5678

  // MARK: - Probe

  @Test
  func `a device without Cairn firmware is never asked`() async {
    let session = MockRxSyncSession()
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: .testDevice())
    await service.waitForStart()

    #expect(await service.mode == .stock)
    #expect(await service.stockReason == .otherFirmware)
    #expect(await service.deliveryStats().stockReason == .otherFirmware)
    #expect(await session.stateCalls == 0)
    #expect(await session.subscribeCalls.isEmpty)
    #expect(await session.steps.isEmpty)
  }

  @Test
  func `Cairn firmware without RX_SYNC stays on stock frames`() async {
    let session = MockRxSyncSession()
    await session.setStateError(.deviceError(code: ErrorCode.unsupportedCommand.rawValue))
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .stock)
    #expect(await service.stockReason == .recoveryUnsupported)
    #expect(await session.stateCalls == 1)
    #expect(await session.subscribeCalls.isEmpty)
    // the 0x88 frames held for the probe are passed on when no SUBSCRIBE follows
    #expect(await session.steps == ["hold", "state", "release"])
  }

  @Test
  func `a probe with no reply is stock for now and asked again on the next start`() async {
    let session = MockRxSyncSession()
    await session.setStateError(.timeout)
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())
    let radioID = UUID()

    await service.start(radioID: radioID, device: Self.cairnDevice())
    await service.waitForStart()
    #expect(await service.mode == .stock)
    #expect(await service.stockReason == .recoveryFailed)

    await session.setStateError(nil)
    await service.start(radioID: radioID, device: Self.cairnDevice())
    await service.waitForStart()
    #expect(await service.mode == .synced)
    #expect(await service.stockReason == nil)
    #expect(await session.stateCalls == 2)
  }

  // MARK: - Subscribe

  @Test
  func `a supported radio is subscribed from the stored cursor`() async {
    let radioID = UUID()
    let session = MockRxSyncSession()
    let store = MemoryCursorStore()
    await store.seed(RxStreamCursor(epoch: Self.epoch, seq: 120), radioID: radioID)
    let service = RxStreamService(session: session, cursorStore: store)

    await service.start(radioID: radioID, device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .synced)
    let calls = await session.subscribeCalls
    #expect(calls.count == 1)
    #expect(calls.first?.on == true)
    #expect(calls.first?.epoch == Self.epoch)
    #expect(calls.first?.seq == 120)
    #expect(calls.first?.max == 512)
    #expect(await store.cursor(radioID: radioID) == RxStreamCursor(epoch: Self.epoch, seq: 120))
    // frames are held from before STATE until the SUBSCRIBE reply settles them
    #expect(await session.steps == ["hold", "state", "subscribe"])
  }

  @Test
  func `a new journal epoch resets the cursor and subscribes live`() async {
    let radioID = UUID()
    let session = MockRxSyncSession()
    let store = MemoryCursorStore()
    await store.seed(RxStreamCursor(epoch: 0xAAAA, seq: 900), radioID: radioID)
    let service = RxStreamService(session: session, cursorStore: store)

    await service.start(radioID: radioID, device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .synced)
    #expect(await store.cursor(radioID: radioID) == nil)
    let call = await session.subscribeCalls.first
    #expect(call?.epoch == 0)
    #expect(call?.seq == 0)
  }

  @Test
  func `a refused subscribe leaves stock mode`() async {
    let session = MockRxSyncSession()
    await session.setSubscribeError(.commandFailed(.cairnFirmware, reason: "BUSY"))
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .stock)
    #expect(await service.stockReason == .recoveryFailed)
  }

  @Test
  func `a subscribe the radio leaves off is a failed recovery`() async {
    let session = MockRxSyncSession()
    await session.setSubscribeAnswersOff(true)
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .stock)
    #expect(await service.stockReason == .recoveryFailed)
    #expect(await service.deliveryStats().stockReason == .recoveryFailed)
  }

  /// The radio opts the link in before it writes the SUBSCRIBE reply: a reply lost in a full send
  /// queue left it pushing records, and no 0x88 frames, to a connection settled on stock.
  @Test
  func `a SUBSCRIBE with no reply is sent again live once the link is quiet`() async {
    let radioID = UUID()
    let session = MockRxSyncSession()
    await session.setSubscribeTimeouts(1)
    let store = MemoryCursorStore()
    await store.seed(RxStreamCursor(epoch: Self.epoch, seq: 120), radioID: radioID)
    let service = RxStreamService(session: session, cursorStore: store)

    await service.start(radioID: radioID, device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .synced)
    #expect(await service.stockReason == nil)
    let calls = await session.subscribeCalls
    #expect(calls.count == 2)
    #expect(calls.first?.seq == 120, "the first asks to resume")
    // the frames held for the first were passed on when it failed: the retry asks live
    #expect(calls.last?.on == true)
    #expect(calls.last?.epoch == 0)
    #expect(calls.last?.seq == 0)
    // ... and the catch-up a resume would have sent, up to the newest record STATE saw, is fetched
    #expect(await session.backlogs == [CairnRxBacklog(epoch: Self.epoch, afterSeq: 120, throughSeq: 1000, limit: 512)])
    #expect(await session.steps == ["hold", "state", "subscribe", "quiet", "hold", "backlog", "subscribe"])
    #expect(await store.cursor(radioID: radioID) == RxStreamCursor(epoch: Self.epoch, seq: 120), "the cursor is kept")
  }

  @Test
  func `a live retry with no stored cursor owes nothing`() async {
    let session = MockRxSyncSession()
    await session.setSubscribeTimeouts(1)
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .synced)
    #expect(await session.backlogs.isEmpty)
    #expect(await session.steps == ["hold", "state", "subscribe", "quiet", "hold", "subscribe"])
  }

  @Test
  func `a SUBSCRIBE that never gets a reply is turned off and settles stock`() async {
    let session = MockRxSyncSession()
    await session.setSubscribeTimeouts(1 + RxStreamService.subscribeRetries)
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.mode == .stock)
    #expect(await service.stockReason == .recoveryFailed)
    let calls = await session.subscribeCalls
    #expect(calls.map(\.on) == [true, true, false], "the radio may have opted in all the same: off restores 0x88")
    #expect(await session.steps == ["hold", "state", "subscribe", "quiet", "hold", "subscribe", "quiet", "subscribe-off"])
  }

  @Test
  func `a refused SUBSCRIBE is not sent again`() async {
    let session = MockRxSyncSession()
    await session.setSubscribeError(.commandFailed(.cairnFirmware, reason: "BUSY"))
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await session.subscribeCalls.count == 1, "the radio answered: nothing was lost")
    #expect(await service.mode == .stock)
  }

  @Test
  func `another subscribe error is a failed recovery`() async {
    let session = MockRxSyncSession()
    await session.setSubscribeError(.timeout)
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    #expect(await service.stockReason == .recoveryFailed)
    await service.stop()
    #expect(await service.stockReason == nil)
    #expect(await service.deliveryStats().stockReason == nil)
  }

  // MARK: - Stock Delivery

  @Test(arguments: [
    ("companion-v1.7.0", 169), ("companion-v1.11.0", 169), ("companion-v1.15.0", 169),
    ("companion-v1.16.0", 173), ("companion-v1.18.0", 173),
  ])
  func `stock delivery names the longest packet the firmware forwards`(tag: String, limit: Int) async {
    let session = MockRxSyncSession()
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: StockCompanionFrames.device(tag))
    let stats = await service.deliveryStats()

    #expect(stats.mode == .stock)
    #expect(stats.forwardLimit == limit)
    #expect(stats.radioLoss == nil, "nothing measures delivery without a monitor")
  }

  @Test
  func `stock delivery stats carry the radio's measured loss`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .packets28)
    let session = try await radio.startedSession()
    let service = RxStreamService(
      session: session,
      cursorStore: MemoryCursorStore(),
      deliveryMonitor: StockDeliveryMonitor(session: session, quiet: .zero)
    )

    await service.start(radioID: UUID(), device: StockCompanionFrames.device("companion-v1.18.0"))
    try await waitUntil("the baseline reading is asked for as stock mode settles") { await radio.statsRequests == 1 }
    #expect(await service.deliveryStats().radioLoss == nil, "one reading measures nothing yet")

    await radio.hear(30, delivered: 26, linkDropped: 1)
    await service.setDeliveryWatching(true)
    try await waitUntil("watching reads the counters at once") { await service.deliveryStats().radioLoss != nil }

    let stats = await service.deliveryStats()
    #expect(stats.mode == .stock)
    #expect(stats.stockReason == .otherFirmware)
    #expect(stats.radioLoss == StockRadioLoss(heard: 30, missed: 4))
    #expect(stats.linkDrops == 1, "the refused frame is shown apart, and is already one of the missed")
    #expect(stats.forwardLimit == 173)
    await service.stop()
    await session.stop()
  }

  @Test
  func `a stock window counts the packets the radio heard that never reached the app`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .packets24)
    let session = try await radio.startedSession()
    let service = RxStreamService(
      session: session,
      cursorStore: MemoryCursorStore(),
      deliveryMonitor: StockDeliveryMonitor(session: session, quiet: .zero)
    )
    await service.start(radioID: UUID(), device: StockCompanionFrames.device("companion-v1.11.0"))

    let mark = try #require(await service.deliveryMark())
    await radio.hear(12, delivered: 9)
    #expect(await service.packetsMissed(since: mark) == 3)

    // A new connection's readings don't compare with the old mark.
    await service.start(radioID: UUID(), device: StockCompanionFrames.device("companion-v1.11.0"))
    #expect(await service.packetsMissed(since: mark) == nil)
    await service.stop()
    await session.stop()
  }

  @Test
  func `firmware before v1.11 is never asked for its packet counter`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .unsupported)
    let session = try await radio.startedSession()
    let service = RxStreamService(
      session: session,
      cursorStore: MemoryCursorStore(),
      deliveryMonitor: StockDeliveryMonitor(session: session, quiet: .zero)
    )
    let device = StockCompanionFrames.device("companion-v1.10.0")
    #expect(device.firmwareVersion == 8)
    #expect(device.firmwareVersionString == "v1.10.0")

    await service.start(radioID: UUID(), device: device)
    await service.setDeliveryWatching(true)
    #expect(await service.deliveryMark() == nil)
    await radio.hear(4, delivered: 3, linkDropped: 1)
    try await Task.sleep(for: .milliseconds(100))

    let stats = await service.deliveryStats()
    #expect(await radio.statsRequests == 0, "no CMD_GET_STATS is written")
    #expect(stats.radioLoss == nil)
    #expect(stats.linkDrops == 1, "the app's own drops are counted on every firmware")
    #expect(stats.forwardLimit == 169)
    #expect(stats.stockReason == .otherFirmware)
    await service.stop()
    await session.stop()
  }

  @Test
  func `synced delivery uses RX_SYNC's counters and never reads the packet counter`() async throws {
    let session = MockRxSyncSession()
    await session.setDroppedTransportFrames(2)
    let service = RxStreamService(
      session: session,
      cursorStore: MemoryCursorStore(),
      deliveryMonitor: StockDeliveryMonitor(session: session, quiet: .zero)
    )
    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()
    await service.setDeliveryWatching(true)

    let stats = await service.deliveryStats()
    #expect(stats.mode == .synced)
    #expect(stats.stockReason == nil)
    #expect(stats.radioLoss == nil)
    #expect(stats.forwardLimit == nil)
    #expect(stats.linkDrops == 2)

    await session.setLoss(lostAtRadio: 1, unrecovered: 0)
    let mark = try #require(await service.deliveryMark())
    await session.setLoss(lostAtRadio: 4, unrecovered: 2)
    #expect(await service.packetsMissed(since: mark) == 5)
    #expect(await session.statsCalls == 0)
    await service.stop()
  }

  @Test
  func `a mark doesn't compare across modes`() async throws {
    let session = MockRxSyncSession()
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())
    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()
    let mark = try #require(await service.deliveryMark())

    await service.stop()
    #expect(await service.deliveryMark() == nil)
    #expect(await service.packetsMissed(since: mark) == nil)
  }

  // MARK: - Loss

  @Test
  func `a refused advert push asks for an advert resync`() async throws {
    let session = MockRxSyncSession()
    let calls = LossCalls()
    let service = RxStreamService(
      session: session,
      cursorStore: MemoryCursorStore(),
      onAdvertLoss: { await calls.advert() },
      onMessageLoss: { await calls.message() }
    )
    await service.start(radioID: UUID(), device: Self.cairnDevice())
    await service.waitForStart()

    await session.emit(.cairnRxLoss(CairnRxLoss(epoch: Self.epoch, overwritten: 0, refusedMask: 1 << 0, refusedCount: 2)))
    try await waitUntil("the advert loss reached its callback") { await calls.adverts == 1 }
    #expect(await calls.messages == 0)

    await session.emit(.cairnRxLoss(CairnRxLoss(epoch: Self.epoch, overwritten: 0, refusedMask: 1 << 3, refusedCount: 1)))
    try await waitUntil("the message loss reached its callback") { await calls.messages == 1 }
    #expect(await calls.adverts == 1)

    await session.emit(.cairnRxLoss(CairnRxLoss(epoch: Self.epoch, overwritten: 0, refusedMask: 1 << 10, refusedCount: 1)))
    try await waitUntil("the new-advert loss reached its callback") { await calls.adverts == 2 }

    let stats = await service.deliveryStats()
    #expect(stats.mode == .synced)
    #expect(stats.lossReports == 3)
    #expect(stats.refusedFrames == 4)
    await service.stop()
  }

  @Test
  func `delivery stats report the app's drops by label`() async {
    let session = MockRxSyncSession()
    await session.setDrops([RxLogService.eventLabel: 3])
    let service = RxStreamService(session: session, cursorStore: MemoryCursorStore())

    await service.start(radioID: UUID(), device: .testDevice())
    let stats = await service.deliveryStats()

    #expect(stats.mode == .stock)
    #expect(stats.appDrops[RxLogService.eventLabel] == 3)
    #expect(stats.appDrops["neighbours"] == 0)
  }

  // MARK: - Cursor Persistence

  @Test
  func `the store keeps the cursor on the device row`() async throws {
    let radioID = UUID()
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    try await store.saveDevice(.testDevice(radioID: radioID))

    #expect(try await store.fetchRxStreamCursor(radioID: radioID) == nil)
    try await store.saveRxStreamCursor(RxStreamCursor(epoch: Self.epoch, seq: 77), radioID: radioID)
    #expect(try await store.fetchRxStreamCursor(radioID: radioID) == RxStreamCursor(epoch: Self.epoch, seq: 77))
    try await store.saveRxStreamCursor(nil, radioID: radioID)
    #expect(try await store.fetchRxStreamCursor(radioID: radioID) == nil)

    let unknown = UUID()
    try await store.saveRxStreamCursor(RxStreamCursor(epoch: 1, seq: 1), radioID: unknown)
    #expect(try await store.fetchRxStreamCursor(radioID: unknown) == nil, "a radio without a device row keeps none")
  }

  @Test
  func `the device hint follows Cairn firmware`() {
    #expect(!DeviceDTO.testDevice().supportsRxSync)
    #expect(Self.cairnDevice().supportsRxSync)
    #expect(StockCompanionFrames.device(fromDeviceInfo: StockCompanionFrames.cairnForkDeviceInfo(build: 7))?.supportsRxSync == true)
    for release in StockCompanionFrames.releases {
      #expect(StockCompanionFrames.device(release.tag).supportsRxSync == false, "\(release.tag)")
    }
  }

  // MARK: - Helpers

  private static func cairnDevice() -> DeviceDTO {
    .testDevice().copy { $0.cairnBuild = 42 }
  }
}

// MARK: - Test Doubles

private actor LossCalls {
  private(set) var adverts = 0
  private(set) var messages = 0

  func advert() {
    adverts += 1
  }

  func message() {
    messages += 1
  }
}

private actor MemoryCursorStore: RxStreamCursorPersisting {
  private var cursors: [UUID: RxStreamCursor] = [:]

  func seed(_ cursor: RxStreamCursor, radioID: UUID) {
    cursors[radioID] = cursor
  }

  func cursor(radioID: UUID) -> RxStreamCursor? {
    cursors[radioID]
  }

  func fetchRxStreamCursor(radioID: UUID) async throws -> RxStreamCursor? {
    cursors[radioID]
  }

  func saveRxStreamCursor(_ cursor: RxStreamCursor?, radioID: UUID) async throws {
    cursors[radioID] = cursor
  }
}

/// Answers STATE and SUBSCRIBE as a Cairn companion with RX_SYNC would, unless told to fail.
private actor MockRxSyncSession: CairnRxSyncSessionOps, SessionEventStreaming {
  struct SubscribeCall {
    let on: Bool
    let epoch: UInt32
    let seq: UInt32
    let max: UInt16
  }

  static let epoch: UInt32 = 0x1234_5678

  private(set) var stateCalls = 0
  private(set) var subscribeCalls: [SubscribeCall] = []
  /// The records each live retry asked the session to fetch.
  private(set) var backlogs: [CairnRxBacklog] = []
  /// The order the probe's hold, STATE, SUBSCRIBE and release happened in.
  private(set) var steps: [String] = []
  private var stateError: MeshCoreError?
  private var subscribeError: MeshCoreError?
  private var subscribeAnswersOff = false
  private var subscribeTimeouts = 0
  private var drops: [String: Int] = [:]
  private var lostAtRadio = 0
  private var unrecovered = 0
  /// Packet-counter reads asked of this session.
  private(set) var statsCalls = 0
  private var droppedFrames = 0
  private var subscribers: [(filter: EventFilter, continuation: AsyncStream<MeshEvent>.Continuation)] = []

  func setStateError(_ error: MeshCoreError?) {
    stateError = error
  }

  func setSubscribeError(_ error: MeshCoreError?) {
    subscribeError = error
  }

  func setSubscribeAnswersOff(_ off: Bool) {
    subscribeAnswersOff = off
  }

  /// The next `count` SUBSCRIBEs get no reply (time out); later ones are answered.
  func setSubscribeTimeouts(_ count: Int) {
    subscribeTimeouts = count
  }

  func setDrops(_ drops: [String: Int]) {
    self.drops = drops
  }

  func setLoss(lostAtRadio: Int, unrecovered: Int) {
    self.lostAtRadio = lostAtRadio
    self.unrecovered = unrecovered
  }

  func setDroppedTransportFrames(_ count: Int) {
    droppedFrames = count
  }

  func emit(_ event: MeshEvent) {
    for subscriber in subscribers where subscriber.filter.matches(event) {
      subscriber.continuation.yield(event)
    }
  }

  // MARK: CairnRxSyncSessionOps

  func setCairnRxSync(
    on: Bool, resumeEpoch: UInt32, resumeSeq: UInt32, resumeMax: UInt16, timeout _: TimeInterval?
  ) async throws -> CairnRxSubscribeResult {
    subscribeCalls.append(SubscribeCall(on: on, epoch: resumeEpoch, seq: resumeSeq, max: resumeMax))
    steps.append(on ? "subscribe" : "subscribe-off")
    if subscribeTimeouts > 0 {
      subscribeTimeouts -= 1
      throw MeshCoreError.timeout
    }
    if let subscribeError { throw subscribeError }
    let resumed = resumeEpoch == Self.epoch && resumeSeq > 0
    return CairnRxSubscribeResult(
      isOn: on && !subscribeAnswersOff, resumed: resumed, epoch: Self.epoch, firstSeq: 1, lastSeq: 1000,
      cursor: resumed ? resumeSeq + 1 : 1001
    )
  }

  func cairnRxSyncState(timeout _: TimeInterval?) async throws -> CairnRxSyncState {
    stateCalls += 1
    steps.append("state")
    if let stateError { throw stateError }
    return CairnRxSyncState(
      version: 1, epoch: Self.epoch, firstSeq: 1, lastSeq: 1000, capacityBytes: 8192,
      isOptedIn: false, overwritten: 0, pushRefused: 0, refusedMask: 0
    )
  }

  func beginRxSyncHold() {
    steps.append("hold")
  }

  func waitForQuietLink(quiet _: Duration, maxWait _: Duration) async {
    steps.append("quiet")
  }

  func releaseRxSyncHold() async {
    steps.append("release")
  }

  func expectRxBacklog(_ backlog: CairnRxBacklog) {
    backlogs.append(backlog)
    steps.append("backlog")
  }

  func requestRxReplay(from _: UInt32, count _: Int) -> Bool {
    false
  }

  var rxDeliveryStats: RxDeliveryStats {
    RxDeliveryStats(
      isActive: !subscribeCalls.isEmpty, epoch: subscribeCalls.isEmpty ? nil : Self.epoch, lastSeq: nil,
      delivered: 0, recovered: 0, lostAtRadio: lostAtRadio, unrecovered: unrecovered, missing: 0, duplicates: 0
    )
  }

  // MARK: SessionEventStreaming

  var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { $0.finish() }
  }

  func events() async -> AsyncStream<MeshEvent> {
    await events(filter: EventFilter { _ in true })
  }

  func events(filter: EventFilter) async -> AsyncStream<MeshEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: MeshEvent.self)
    subscribers.append((filter, continuation))
    return stream
  }

  func eventDropCount(label: String) async -> Int {
    drops[label] ?? 0
  }

  func waitForEvent(filter _: EventFilter, timeout _: TimeInterval?) async -> MeshEvent? {
    nil
  }
}

// MARK: StockDeliverySessionOps

extension MockRxSyncSession: StockDeliverySessionOps {
  func getStatsPackets() async throws -> PacketStats {
    statsCalls += 1
    throw MeshCoreError.timeout
  }

  var statsSupport: Bool? {
    nil
  }

  var droppedTransportFrames: Int {
    droppedFrames
  }
}
