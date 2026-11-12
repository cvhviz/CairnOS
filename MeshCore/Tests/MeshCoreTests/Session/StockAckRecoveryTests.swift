import Foundation
@testable import MeshCore
import Testing

/// A delivery confirmation (0x82) the radio's full send queue dropped is recovered from the 0x88
/// copy of the ACK packet, which official firmware queues first and also sends for every later
/// copy it hears. Frames come from ``StockFirmwareFrames``; time is the session's test clock.
@Suite("Stock delivery confirmation recovery")
struct StockAckRecoveryTests {
  private static let ack: [UInt8] = [0x1A, 0x2B, 0x3C, 0x4D]
  private static let sendMessage = CommandCode.sendMessage.rawValue

  private struct Fixture {
    let session: MeshCoreSession
    let transport: StockTestTransport
    let clock: StockTestClock
    let recorder: EventRecorder
    let recording: Task<Void, Never>

    /// Waits until the session has dispatched an event `matching`, so every frame before it was handled.
    func settle(after frame: Data, matching: @escaping @Sendable (MeshEvent) -> Bool) async throws {
      let before = await recorder.events.filter(matching).count
      await transport.receive(frame)
      try await waitUntil("the session should handle \(frame.hexString)") {
        await recorder.events.filter(matching).count > before
      }
    }

    /// Feeds a 0x88 frame and waits for its `.rxLogData`.
    func hear(_ raw: [UInt8]) async throws {
      try await settle(after: StockFirmwareFrames.logRx(raw: raw)) { event in
        if case .rxLogData = event { true } else { false }
      }
    }

    /// Feeds a frame no recovery cares about, after which every earlier frame was handled.
    func flush() async throws {
      try await settle(after: StockFirmwareFrames.noMoreMessages) { event in
        if case .noMoreMessages = event { true } else { false }
      }
    }

    var acknowledgements: [(code: Data, tripTime: UInt32?)] {
      get async { await recorder.acknowledgements }
    }
  }

  private func makeFixture() async throws -> Fixture {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: clock)
    let (recorder, recording) = await EventRecorder.recording(session)
    return Fixture(session: session, transport: transport, clock: clock, recorder: recorder, recording: recording)
  }

  /// Sends a DM the way the app does and answers it with RESP_CODE_SENT for `ack`.
  private func sendDM(_ fixture: Fixture, ack: [UInt8] = ack) async throws {
    let before = await fixture.transport.sent(code: Self.sendMessage).count
    let send = Task { try await fixture.session.sendMessage(to: Data(repeating: 0xB0, count: 6), text: "hi") }
    try await waitUntil("CMD_SEND_TXT_MSG should be sent") {
      await fixture.transport.sent(code: Self.sendMessage).count > before
    }
    await fixture.transport.receive(StockFirmwareFrames.messageSent(ack: ack))
    #expect(try await send.value.expectedAck == Data(ack))
  }

  // MARK: - Recovery

  @Test
  func `a confirmation whose push was lost is dispatched once after the grace`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack))
    try await waitUntil("the recovery should wait out its grace") { fixture.clock.sleeperCount == 1 }
    fixture.clock.advance(by: .milliseconds(1400))
    try await fixture.flush()
    #expect(await fixture.acknowledgements.isEmpty, "the radio's own push still has time to arrive")

    fixture.clock.advance(by: .milliseconds(100))
    try await waitUntil("the recovered confirmation should be dispatched") {
      await fixture.acknowledgements.count == 1
    }
    let recovered = try #require(await fixture.acknowledgements.first)
    #expect(recovered.code == Data(Self.ack))
    #expect(recovered.tripTime == nil, "a recovered confirmation has no round-trip time")
  }

  @Test
  func `the radio's own confirmation inside the grace is the only one dispatched`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack))
    try await waitUntil("the recovery should wait out its grace") { fixture.clock.sleeperCount == 1 }
    await fixture.transport.receive(StockFirmwareFrames.sendConfirmed(ack: Self.ack, tripMs: 812))
    try await waitUntil("the radio's confirmation should cancel the recovery") { fixture.clock.sleeperCount == 0 }

    fixture.clock.advance(by: .seconds(5))
    try await fixture.flush()
    let acks = await fixture.acknowledgements
    #expect(acks.count == 1)
    #expect(acks.first?.tripTime == 812)
  }

  @Test
  func `the radio's late confirmation after a recovery is not dispatched again`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)
    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack))
    try await waitUntil("grace") { fixture.clock.sleeperCount == 1 }
    fixture.clock.advance(by: .milliseconds(1500))
    try await waitUntil("recovered") { await fixture.acknowledgements.count == 1 }

    // A user-set rx_delay_base can hold the radio's own processing for up to 32 s.
    fixture.clock.advance(by: .seconds(20))
    await fixture.transport.receive(StockFirmwareFrames.sendConfirmed(ack: Self.ack))
    try await fixture.flush()
    #expect(await fixture.acknowledgements.count == 1)
  }

  @Test
  func `later copies of the same ACK are ignored`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    // multi_acks: a multipart ACK, then the plain one 300 ms later, plus a flood repeat.
    try await fixture.hear(StockFirmwareFrames.multipartAckPacket(code: Self.ack))
    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack))
    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack, route: StockFirmwareFrames.routeFlood, path: [1, 2]))
    try await waitUntil("grace") { fixture.clock.sleeperCount == 1 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.clock.sleeperCount == 1, "one recovery per code")
    fixture.clock.advance(by: .milliseconds(1500))
    try await waitUntil("recovered") { await fixture.acknowledgements.count == 1 }

    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack))
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.clock.sleeperCount == 0)
    fixture.clock.advance(by: .seconds(5))
    try await fixture.flush()
    #expect(await fixture.acknowledgements.count == 1)
  }

  enum AckShape: CaseIterable, Sendable {
    case plain4, plain6, multipart

    func packet(_ code: [UInt8]) -> [UInt8] {
      switch self {
      case .plain4: StockFirmwareFrames.ackPacket(code: code)
      case .plain6: StockFirmwareFrames.ackPacket6(code: code, attempt: 1)
      case .multipart: StockFirmwareFrames.multipartAckPacket(code: code)
      }
    }
  }

  @Test(arguments: AckShape.allCases)
  func `every readable ACK shape recovers its code`(shape: AckShape) async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    try await fixture.hear(shape.packet(Self.ack))
    try await waitUntil("grace") { fixture.clock.sleeperCount == 1 }
    fixture.clock.advance(by: .milliseconds(1500))
    try await waitUntil("recovered") { await fixture.acknowledgements.count == 1 }
    #expect(await fixture.acknowledgements.first?.code == Data(Self.ack))
  }

  @Test
  func `someone else's ACK recovers nothing`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    try await fixture.hear(StockFirmwareFrames.ackPacket(code: [0xDE, 0xAD, 0xBE, 0xEF]))
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.clock.sleeperCount == 0)
    fixture.clock.advance(by: .seconds(5))
    try await fixture.flush()
    #expect(await fixture.acknowledgements.isEmpty)
  }

  @Test
  func `an ACK heard with no message in flight recovers nothing`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }

    try await fixture.hear(StockFirmwareFrames.ackPacket(code: Self.ack))
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.clock.sleeperCount == 0)
    #expect(await fixture.acknowledgements.isEmpty)
  }

  @Test
  func `sendMessageWithRetry stops waiting on a recovered confirmation`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    let key = Data(repeating: 0xB0, count: 32)

    let send = Task { try await fixture.session.sendMessageWithRetry(to: key, text: "hi", timeout: 30) }
    try await waitUntil("CMD_SEND_TXT_MSG should be sent") {
      await fixture.transport.sent(code: Self.sendMessage).count == 1
    }
    await fixture.transport.receive(StockFirmwareFrames.messageSent(ack: Self.ack))
    // The retry loop now waits up to 30 s for this code's confirmation.
    try await waitUntil("the ACK wait should start") { fixture.clock.sleeperDeadlines.contains(.seconds(30)) }

    try await fixture.hear(StockFirmwareFrames.ackPacket6(code: Self.ack))
    try await waitUntil("grace") { fixture.clock.sleeperDeadlines.contains(.milliseconds(1500)) }
    fixture.clock.advance(by: .milliseconds(1500))

    let delivered = try await send.value
    #expect(delivered?.expectedAck == Data(Self.ack))
    #expect(await fixture.transport.sent(code: Self.sendMessage).count == 1, "a delivered message is never resent")
  }

  // MARK: - Held for RX_SYNC

  /// A Cairn radio whose RX_SYNC setup failed: 0x88 frames held while the probe was answered are
  /// released without coming back through the receive path, so recovery must see them on arrival.
  @Test
  func `an ACK copy held for RX_SYNC and released after a failed setup still recovers`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    await fixture.session.beginRxSyncHold()
    await fixture.transport.receive(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: Self.ack)))
    try await waitUntil("the held copy should start the grace") { fixture.clock.sleeperCount == 1 }
    #expect(await fixture.recorder.events.contains { if case .rxLogData = $0 { true } else { false } } == false)

    // The probe failed (unsupported, refused or timed out): the held frames are passed on.
    await fixture.session.releaseRxSyncHold()
    try await waitUntil("the held frame should be dispatched") {
      await fixture.recorder.events.contains { if case .rxLogData = $0 { true } else { false } }
    }
    fixture.clock.advance(by: .milliseconds(1500))
    try await waitUntil("the recovered confirmation should be dispatched") {
      await fixture.acknowledgements.count == 1
    }
    try await fixture.flush()
    #expect(await fixture.acknowledgements.count == 1)
    #expect(await fixture.acknowledgements.first?.code == Data(Self.ack))
  }

  @Test
  func `a held ACK copy whose push arrives is dispatched once`() async throws {
    let fixture = try await makeFixture()
    defer { fixture.recording.cancel() }
    try await sendDM(fixture)

    await fixture.session.beginRxSyncHold()
    await fixture.transport.receive(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: Self.ack)))
    try await waitUntil("grace") { fixture.clock.sleeperCount == 1 }
    // 0x82 pushes are never held
    await fixture.transport.receive(StockFirmwareFrames.sendConfirmed(ack: Self.ack, tripMs: 640))
    try await waitUntil("the radio's confirmation should cancel the recovery") { fixture.clock.sleeperCount == 0 }
    await fixture.session.releaseRxSyncHold()

    fixture.clock.advance(by: .seconds(5))
    try await fixture.flush()
    let acks = await fixture.acknowledgements
    #expect(acks.count == 1)
    #expect(acks.first?.tripTime == 640)
  }

  // MARK: - Tracker

  @Test
  func `the tracker forgets codes after their lifetime and beyond its limit`() {
    var tracker = ExpectedAckTracker()
    tracker.noteSent(Data([1, 2, 3, 4]), at: .zero)
    let expired = tracker.heard(Data([1, 2, 3, 4]), at: ExpectedAckTracker.pendingLifetime + .seconds(1))
    #expect(expired == false)

    for index in 0..<(ExpectedAckTracker.pendingLimit + 1) {
      tracker.noteSent(Data([0xEE, 0, 0, UInt8(index)]), at: .seconds(700))
    }
    #expect(tracker.pendingCount == ExpectedAckTracker.pendingLimit)
    let oldest = tracker.heard(Data([0xEE, 0, 0, 0]), at: .seconds(701))
    #expect(oldest == false, "the oldest was forgotten")
    let next = tracker.heard(Data([0xEE, 0, 0, 1]), at: .seconds(701))
    #expect(next)
  }

  @Test
  func `the tracker ignores a zero code`() {
    var tracker = ExpectedAckTracker()
    tracker.noteSent(Data([0, 0, 0, 0]), at: .zero)
    #expect(tracker.pendingCount == 0)
    let heard = tracker.heard(Data([0, 0, 0, 0]), at: .zero)
    #expect(heard == false)
  }

  @Test
  func `a recovered code swallows the radio's confirmation for a minute only`() {
    var tracker = ExpectedAckTracker()
    let code = Data([1, 2, 3, 4])
    tracker.noteSent(code, at: .zero)
    let heard = tracker.heard(code, at: .seconds(1))
    #expect(heard)
    let recovered = tracker.graceEnded(code, at: .seconds(2))
    #expect(recovered)
    let late = tracker.radioConfirmed(code, at: .seconds(30))
    #expect(late == .swallow)
    let muchLater = tracker.radioConfirmed(code, at: .seconds(63))
    #expect(muchLater == .dispatch(cancelsRecovery: false))
  }
}
