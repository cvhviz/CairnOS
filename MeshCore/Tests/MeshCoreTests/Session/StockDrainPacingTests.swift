import Foundation
@testable import MeshCore
import Testing

/// Official companion firmware takes a message off its offline queue before it writes the answer
/// to `CMD_SYNC_NEXT_MESSAGE`, and ignores a failed write (companion-v1.7.0 MyMesh.cpp:921-931,
/// v1.18.0 :1415-1423); its Bluetooth send queue drops any frame written while it is full. The
/// stock command set has no way to look before taking or to ask again, so a fetch answer crowded
/// out by a burst of pushes loses that message for good. These tests run the session against a
/// model of that firmware and check that the quiet-link gate leaves the answer room.
@Suite("Stock message drain pacing")
struct StockDrainPacingTests {
  private static let getMessage = CommandCode.getMessage.rawValue

  // MARK: - Against the firmware's send queue

  @Test(arguments: [StockCompanionLinkModel.Board.esp32, .nrf52])
  func `a gated drain loses no message to a burst`(board: StockCompanionLinkModel.Board) async throws {
    let run = try await LinkRun(board: board)
    defer { run.stop() }

    try await run.advance(until: .seconds(2))

    #expect(await run.model.lostMessages.isEmpty, "the answer found room in the send queue")
    #expect(await run.receivedTexts() == ["hello"])
    #expect(await run.session.possiblyLostMessageFetches == 0)
    #expect(await run.model.droppedFrames.isEmpty == false, "the burst did overflow the queue")
  }

  @Test(arguments: [StockCompanionLinkModel.Board.esp32, .nrf52])
  func `an ungated drain loses the message and keeps draining`(board: StockCompanionLinkModel.Board) async throws {
    let run = try await LinkRun(board: board)
    defer { run.stop() }
    // The fetch goes out as soon as the push arrives, as it did before the gate.
    await run.session.setFetchQuietWaitForTest(quiet: QuietLink.quiet, maxWait: .zero)

    try await run.advance(until: .seconds(2))
    #expect(await run.model.lostMessages.count == 1, "the radio took the message, then dropped its answer")

    // The fetch times out (5 s), is counted, and the drain asks again after its backoff.
    try await run.advance(until: .seconds(8), step: .milliseconds(50))
    #expect(await run.session.possiblyLostMessageFetches == 1)
    #expect(await run.model.fetches == 2, "the retry still drains the rest of the queue")
    #expect(await run.receivedTexts().isEmpty)
  }

  // MARK: - The gate itself

  @Test
  func `a fetch waits for the link to go quiet`() async throws {
    let (session, transport, clock) = try await started()
    await push(transport, session, expectFrames: 1)

    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the quiet wait should start") { clock.sleeperDeadlines.contains(QuietLink.quiet) }
    clock.advance(by: .milliseconds(200))
    await push(transport, session, expectFrames: 2) // the link is busy again at 200 ms
    clock.advance(by: .milliseconds(200))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sent(code: Self.getMessage).isEmpty, "only 200 ms since the last push")

    clock.advance(by: .milliseconds(100))
    try await waitUntil("300 ms after the last push the fetch should go out") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    guard case .noMoreMessages = try await fetch.value else {
      Issue.record("Expected noMoreMessages")
      return
    }
  }

  @Test
  func `no push since the radio's last answer means no wait`() async throws {
    let (session, transport, _) = try await started()
    await push(transport, session, expectFrames: 1)
    // An answer leaves the send queue after every push queued before it.
    await transport.receive(Data([ResponseCode.ok.rawValue]))
    try await Task.sleep(for: .milliseconds(20))

    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the fetch should go out without the clock moving") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `maxWait is honoured under continuous traffic`() async throws {
    let (session, transport, clock) = try await started()
    await push(transport, session, expectFrames: 1)

    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the quiet wait should start") { clock.sleeperCount == 1 }
    // A push every 100 ms: the link is never quiet for 300 ms.
    for step in 1...49 {
      clock.advance(by: .milliseconds(100))
      await push(transport, session, expectFrames: UInt64(step + 1))
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sent(code: Self.getMessage).isEmpty, "4.9 s in")

    clock.advance(by: .milliseconds(100))
    try await waitUntil("at 5 s the fetch should go out anyway") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `a hold defers the fetch until it ends`() async throws {
    let (session, transport, clock) = try await started()
    await session.holdBackgroundTraffic(for: .seconds(1), owner: "scan")
    await session.holdBackgroundTraffic(for: .seconds(2), owner: "scan") // a later call extends it
    await session.holdBackgroundTraffic(for: .milliseconds(500), owner: "scan") // but never shortens it

    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the fetch should wait for the hold") { clock.sleeperDeadlines.contains(.seconds(2)) }
    clock.advance(by: .milliseconds(1900))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sent(code: Self.getMessage).isEmpty)

    clock.advance(by: .milliseconds(100))
    try await waitUntil("the fetch should go out when the hold ends") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `a hold lasts 30 seconds at most`() async throws {
    let (session, _, clock) = try await started()
    await session.holdBackgroundTraffic(for: .seconds(90), owner: "scan")
    let wait = Task { await session.waitForQuietLink() }
    try await waitUntil("the wait should sleep until the capped hold ends") {
      clock.sleeperDeadlines.contains(QuietLink.holdLimit)
    }
    clock.advance(by: QuietLink.holdLimit)
    await wait.value
  }

  @Test
  func `a released hold lets a waiting fetch go at once`() async throws {
    let (session, transport, clock) = try await started()
    // A scan's send failed (ERR unsupported, a timeout) or was stopped: its replies won't come.
    await session.holdBackgroundTraffic(for: .seconds(6), owner: "scan")
    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the fetch should wait for the hold") { clock.sleeperDeadlines.contains(.seconds(6)) }

    await session.releaseBackgroundTraffic(owner: "scan")
    try await waitUntil("the fetch should go out without the clock moving") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    #expect(clock.now.offset == .zero)
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `releasing one owner's hold keeps another's`() async throws {
    let (session, transport, clock) = try await started()
    await session.holdBackgroundTraffic(for: .seconds(6), owner: "scan")
    await session.holdBackgroundTraffic(for: .seconds(4), owner: "regionDiscovery")
    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the fetch should wait for the longer hold") { clock.sleeperDeadlines.contains(.seconds(6)) }

    await session.releaseBackgroundTraffic(owner: "scan")
    try await waitUntil("the wait should follow the hold still running") { clock.sleeperDeadlines == [.seconds(4)] }
    await session.releaseBackgroundTraffic(owner: "nobody") // no hold: nothing changes
    clock.advance(by: .milliseconds(3900))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sent(code: Self.getMessage).isEmpty)

    clock.advance(by: .milliseconds(100))
    try await waitUntil("the fetch should go out when the other hold ends") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `a fetch that waited behind another exchange looks at the link again`() async throws {
    let (session, transport, clock) = try await started()
    // A stats read holds the serializer while the fetch passes its quiet gate; its reply is
    // dropped, so it holds it until its timeout.
    let read = Task { try await session.getStatsPackets() }
    try await waitUntil("the stats request should be written") {
      await transport.sent(code: CommandCode.getStats.rawValue).count == 1
    }
    let fetch = Task { try await session.getMessage() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sent(code: Self.getMessage).isEmpty, "the serializer is still held")

    // A burst begins just before the read times out, after the gate passed.
    clock.advance(by: .milliseconds(4900))
    await push(transport, session, expectFrames: 1)
    clock.advance(by: .milliseconds(100))
    _ = await #expect(throws: MeshCoreError.self) { try await read.value }
    try await waitUntil("the fetch should wait for quiet inside the serializer") {
      clock.sleeperDeadlines.contains(.milliseconds(5200))
    }
    #expect(await transport.sent(code: Self.getMessage).isEmpty)

    clock.advance(by: .milliseconds(200))
    try await waitUntil("the fetch should go out once the link is quiet") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `the wait inside the serializer ignores holds and is short`() async throws {
    let (session, transport, clock) = try await started()
    let read = Task { try await session.getStatsPackets() }
    try await waitUntil("the stats request should be written") {
      await transport.sent(code: CommandCode.getStats.rawValue).count == 1
    }
    let fetch = Task { try await session.getMessage() }
    try await Task.sleep(for: .milliseconds(20))
    // A scan starts a hold once the fetch is already queued on the serializer.
    await session.holdBackgroundTraffic(for: .seconds(20), owner: "scan")
    clock.advance(by: .milliseconds(4900))
    await push(transport, session, expectFrames: 1)
    clock.advance(by: .milliseconds(100))
    _ = await #expect(throws: MeshCoreError.self) { try await read.value }
    try await waitUntil("the fetch should wait inside the serializer") {
      clock.sleeperDeadlines.contains(.milliseconds(5200))
    }
    // A push every 100 ms: never quiet.
    for step in 1...9 {
      clock.advance(by: .milliseconds(100))
      await push(transport, session, expectFrames: UInt64(step + 1))
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sent(code: Self.getMessage).isEmpty, "5.9 s: within the 1 s limit")
    clock.advance(by: .milliseconds(100))
    try await waitUntil("after 1 s the fetch goes out, hold or not") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    await transport.receive(StockFirmwareFrames.noMoreMessages)
    _ = try await fetch.value
  }

  @Test
  func `the gate is a no-op while RX_SYNC is active`() async throws {
    let (session, transport, clock) = try await started()
    await session.setRxSyncActiveForTest(true)
    await session.holdBackgroundTraffic(for: .seconds(10), owner: "scan")
    await push(transport, session, expectFrames: 1)

    let fetch = Task { try await session.getMessage() }
    try await waitUntil("the fetch should go out at once") {
      await transport.sent(code: Self.getMessage).count == 1
    }
    #expect(clock.now.offset == .zero)

    // RX_SYNC radios keep room for answers, so an unanswered fetch there is not counted.
    clock.advance(by: .seconds(5))
    _ = await #expect(throws: MeshCoreError.self) { try await fetch.value }
    #expect(await session.possiblyLostMessageFetches == 0)
  }

  // MARK: - Catch-up drain

  @Test
  func `the catch-up drain runs every 120 s while auto-fetch is on`() async throws {
    let (session, transport, clock) = try await started()
    await session.startAutoMessageFetching()
    defer { Task { await session.stopAutoMessageFetching() } }

    for round in 1...2 {
      // Only the catch-up timer sleeps: the previous round's fetch has been answered.
      try await waitUntil("catch-up timer \(round) should be set") {
        clock.sleeperDeadlines == [MeshCoreSession.autoMessageCatchUpInterval * round]
      }
      clock.advance(by: MeshCoreSession.autoMessageCatchUpInterval)
      try await waitUntil("catch-up drain \(round) should fetch") {
        await transport.sent(code: Self.getMessage).count == round
      }
      await transport.receive(StockFirmwareFrames.noMoreMessages)
    }
  }

  @Test
  func `no catch-up drain while auto-fetch is off`() async throws {
    let (session, transport, clock) = try await started()
    await session.startAutoMessageFetching()
    await session.stopAutoMessageFetching()
    try await waitUntil("the catch-up timer should be gone") { clock.sleeperCount == 0 }

    clock.advance(by: MeshCoreSession.autoMessageCatchUpInterval * 2)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await transport.sent(code: Self.getMessage).isEmpty)
  }

  @Test
  func `no catch-up drain on an RX_SYNC link`() async throws {
    let (session, transport, clock) = try await started()
    await session.setRxSyncActiveForTest(true)
    await session.startAutoMessageFetching()
    defer { Task { await session.stopAutoMessageFetching() } }

    let interval = MeshCoreSession.autoMessageCatchUpInterval
    try await waitUntil("the catch-up timer should be set") { clock.sleeperDeadlines.contains(interval) }
    clock.advance(by: interval)
    try await waitUntil("the timer should be set again") { clock.sleeperDeadlines.contains(interval * 2) }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await transport.sent(code: Self.getMessage).isEmpty)
  }

  // MARK: - Helpers

  private func started() async throws -> (MeshCoreSession, StockTestTransport, StockTestClock) {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: clock)
    return (session, transport, clock)
  }

  /// Delivers one 0x88 push and waits until the session has counted it.
  private func push(_ transport: StockTestTransport, _ session: MeshCoreSession, expectFrames count: UInt64) async {
    await transport.receive(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: [9, 9, 9, 9])))
    try? await waitUntil("the push should be counted") { await session.receivedRxLogFrames == count }
  }
}

// MARK: - Link Run

/// One session with auto-fetch on, against a ``StockCompanionLinkModel`` playing a direct
/// message that arrives inside a burst of received packets, followed by a quiet gap.
private struct LinkRun {
  let model: StockCompanionLinkModel
  let session: MeshCoreSession
  let clock: StockTestClock
  let recorder: EventRecorder
  let recording: Task<Void, Never>

  init(board: StockCompanionLinkModel.Board) async throws {
    let clock = StockTestClock()
    // A DM at 20 ms, inside a burst of one received packet every 20 ms until 600 ms, then nothing.
    var script: [(Duration, StockCompanionLinkModel.Heard)] = [(.milliseconds(20), .directMessage(text: "hello"))]
    for ms in stride(from: 20, through: 600, by: 20) {
      let raw = StockFirmwareFrames.packet(payloadType: 0x05, route: StockFirmwareFrames.routeFlood, path: [UInt8(ms % 251)], payload: Array(repeating: 0x3C, count: 40))
      script.append((.milliseconds(ms), .packet(frames: [StockFirmwareFrames.logRx(raw: raw)])))
    }
    let model = StockCompanionLinkModel(board: board, clock: clock, script: script)
    let session = MeshCoreSession(
      transport: model,
      configuration: SessionConfiguration(defaultTimeout: 5, clientIdentifier: "MeshCore-Tests"),
      clock: clock
    )
    try await session.start()
    let (recorder, recording) = await EventRecorder.recording(session)
    await session.startAutoMessageFetching()
    self.model = model
    self.session = session
    self.clock = clock
    self.recorder = recorder
    self.recording = recording
  }

  /// Steps simulated time: each step the session reacts to the clock first, then the radio's
  /// main loop runs (it sends a queued frame when it may, then hears what is due).
  func advance(until end: Duration, step: Duration = .milliseconds(10)) async throws {
    while clock.now.offset < end {
      clock.advance(by: step)
      try await settle()
      await model.tick()
      try await settle()
    }
  }

  private func settle() async throws {
    for _ in 0..<4 {
      await Task.yield()
    }
    try await Task.sleep(for: .milliseconds(2))
  }

  func receivedTexts() async -> [String] {
    await recorder.events.compactMap { event in
      if case let .contactMessageReceived(message) = event { return message.text }
      return nil
    }
  }

  func stop() {
    recording.cancel()
    Task { await session.stopAutoMessageFetching() }
  }
}

// MARK: - Stock Companion Link Model

/// Official companion firmware's side of the Bluetooth link, reduced to what decides whether a
/// frame reaches the app (companion-v1.18.0 src/helpers/{esp32,nrf52}/SerialBLEInterface.cpp,
/// the same since v1.7.0):
/// - `writeFrame` appends to a first-in-first-out send queue and drops the frame when the queue
///   holds FRAME_QUEUE_SIZE frames (ESP32 4, esp32/SerialBLEInterface.h:28 and .cpp:175;
///   nRF52 12, nrf52/SerialBLEInterface.h:24 and .cpp:288);
/// - the main loop sends one queued frame at a time: ESP32 no sooner than BLE_WRITE_MIN_INTERVAL
///   (60 ms, esp32 .cpp:189) after the last; nRF52 every pass, but 250 ms apart while
///   `bleuart.write` keeps failing (modelled as a congested window);
/// - `logRxRaw` queues the 0x88 frame of every packet heard, and a direct message is then put on
///   the offline queue with one `PUSH_CODE_MSG_WAITING` tickle (MyMesh.cpp:291-301, 440-473);
/// - `CMD_SYNC_NEXT_MESSAGE` takes the message off the offline queue, then writes it, ignoring
///   whether the write was dropped (MyMesh.cpp:1415-1423).
actor StockCompanionLinkModel: MeshTransport {
  struct Board: Sendable, CustomTestStringConvertible {
    let name: String
    let queueSize: Int
    let writeInterval: Duration
    let congested: Range<Duration>?
    let congestedInterval: Duration

    static let esp32 = Board(
      name: "ESP32", queueSize: 4, writeInterval: .milliseconds(60), congested: nil, congestedInterval: .zero
    )
    static let nrf52 = Board(
      name: "nRF52", queueSize: 12, writeInterval: .milliseconds(10),
      congested: .zero ..< .milliseconds(1000), congestedInterval: .milliseconds(250)
    )

    var testDescription: String {
      name
    }
  }

  /// What the radio hears at a scripted time.
  enum Heard: Sendable {
    /// A packet, as the frames the firmware writes for it.
    case packet(frames: [Data])
    /// A direct message for this radio: its 0x88, then the offline queue and the tickle.
    case directMessage(text: String)
  }

  private let board: Board
  private let clock: StockTestClock
  private var script: [(at: Duration, heard: Heard)]
  private var sendQueue: [Data] = []
  private var offlineQueue: [Data] = []
  private var lastWriteAt: Duration?
  private let stream: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation

  /// Frames `writeFrame` dropped on a full send queue.
  private(set) var droppedFrames: [Data] = []
  /// Commands the app wrote.
  private(set) var commands: [Data] = []
  private(set) var isConnected = false

  init(board: Board, clock: StockTestClock, script: [(Duration, Heard)]) {
    self.board = board
    self.clock = clock
    self.script = script.map { (at: $0.0, heard: $0.1) }
    (stream, continuation) = AsyncStream.makeStream(of: Data.self)
  }

  /// Queued messages whose answer was dropped: gone from the radio, never seen by the app.
  var lostMessages: [Data] {
    droppedFrames.filter { $0.first == ResponseCode.contactMessageReceivedV3.rawValue }
  }

  /// `CMD_SYNC_NEXT_MESSAGE` commands received.
  var fetches: Int {
    commands.filter { $0.first == CommandCode.getMessage.rawValue }.count
  }

  var receivedData: AsyncStream<Data> {
    stream
  }

  func connect() async throws {
    isConnected = true
  }

  func disconnect() async {
    isConnected = false
    continuation.finish()
  }

  func send(_ data: Data) async throws {
    commands.append(data)
    switch data.first {
    case CommandCode.appStart.rawValue:
      writeFrame(StockFirmwareFrames.selfInfo)
    case CommandCode.getMessage.rawValue:
      if offlineQueue.isEmpty {
        writeFrame(StockFirmwareFrames.noMoreMessages)
      } else {
        writeFrame(offlineQueue.removeFirst())
      }
    default:
      break
    }
    sendQueuedFrame()
  }

  /// One pass of the main loop at the clock's time: send a queued frame if one may go, then
  /// handle what the radio hears now.
  func tick() {
    sendQueuedFrame()
    let now = clock.now.offset
    while let next = script.first, next.at <= now {
      script.removeFirst()
      switch next.heard {
      case let .packet(frames):
        frames.forEach(writeFrame)
      case let .directMessage(text):
        let raw = StockFirmwareFrames.packet(payloadType: 0x02, route: StockFirmwareFrames.routeDirect, payload: [0xAA, 0xA1] + Array(repeating: 0x5E, count: 24))
        writeFrame(StockFirmwareFrames.logRx(raw: raw))
        offlineQueue.append(StockFirmwareFrames.contactMsgV3(text: text))
        writeFrame(StockFirmwareFrames.msgWaiting)
      }
    }
    sendQueuedFrame()
  }

  private func writeFrame(_ frame: Data) {
    guard sendQueue.count < board.queueSize else {
      droppedFrames.append(frame)
      return
    }
    sendQueue.append(frame)
  }

  private func sendQueuedFrame() {
    guard !sendQueue.isEmpty else { return }
    let now = clock.now.offset
    let interval = board.congested?.contains(now) == true ? board.congestedInterval : board.writeInterval
    if let lastWriteAt, now < lastWriteAt + interval { return }
    lastWriteAt = now
    continuation.yield(sendQueue.removeFirst())
  }
}
