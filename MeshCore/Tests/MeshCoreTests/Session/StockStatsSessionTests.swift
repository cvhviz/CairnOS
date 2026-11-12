import Foundation
@testable import MeshCore
import Testing

/// Stats on official companion firmware: v1.7 to v1.10 have no `CMD_GET_STATS` and answer
/// `ERR_CODE_UNSUPPORTED_CMD` at once; v1.11+ answers, and its packet counter pairs with the
/// session's 0x88 frame count to measure what never reached the app. The clock never moves
/// unless a test advances it, so a call that returns proved it didn't wait out a timeout.
@Suite("Stock stats on the session")
struct StockStatsSessionTests {
  private static let getStats = CommandCode.getStats.rawValue

  @Test
  func `ERR unsupported fails at once and is not asked again`() async throws {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: clock)

    let first = Task { try await session.getStatsRadio() }
    try await waitUntil("CMD_GET_STATS should be sent") { await transport.sent(code: Self.getStats).count == 1 }
    await transport.receive(StockFirmwareFrames.unsupported)

    let radioError = await #expect(throws: MeshCoreError.self) { try await first.value }
    #expect(isDeviceError(radioError, 1))
    #expect(clock.now.offset == .zero, "no timeout was waited out")
    #expect(await session.statsSupport == false)

    // Every stats kind now fails without writing to the radio.
    let packetsError = await #expect(throws: MeshCoreError.self) { try await session.getStatsPackets() }
    #expect(isDeviceError(packetsError, 1))
    let coreError = await #expect(throws: MeshCoreError.self) { try await session.getStatsCore() }
    #expect(isDeviceError(coreError, 1))
    #expect(await transport.sent(code: Self.getStats).count == 1)
  }

  @Test
  func `other device errors don't mark stats unsupported`() async throws {
    let transport = StockTestTransport()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: StockTestClock())

    let call = Task { try await session.getStatsPackets() }
    try await waitUntil("CMD_GET_STATS should be sent") { await transport.sent(code: Self.getStats).count == 1 }
    await transport.receive(StockFirmwareFrames.err(6)) // ERR_CODE_ILLEGAL_ARG
    let illegalArgumentError = await #expect(throws: MeshCoreError.self) { try await call.value }
    #expect(isDeviceError(illegalArgumentError, 6))
    #expect(await session.statsSupport == nil)
  }

  @Test
  func `a stats reply marks stats supported`() async throws {
    let transport = StockTestTransport()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: StockTestClock())
    #expect(await session.statsSupport == nil)

    let call = Task { try await session.getStatsPackets() }
    try await waitUntil("CMD_GET_STATS should be sent") { await transport.sent(code: Self.getStats).count == 1 }
    await transport.receive(StockFirmwareFrames.statsPackets24(received: 500))
    #expect(try await call.value.received == 500)
    #expect(await session.statsSupport == true)
  }

  @Test
  func `a packet stats reply carries the 0x88 frames received before it`() async throws {
    let transport = StockTestTransport()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: StockTestClock())
    let (recorder, recording) = await EventRecorder.recording(session)
    defer { recording.cancel() }

    // Seven frames, one of them too short to parse: it still reached the session.
    let ack = StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: [1, 2, 3, 4]))
    for _ in 0..<6 {
      await transport.receive(ack)
    }
    await transport.receive(Data([0x88, 0x10]))

    let call = Task { try await session.getStatsPackets() }
    try await waitUntil("CMD_GET_STATS should be sent") { await transport.sent(code: Self.getStats).count == 1 }
    await transport.receive(StockFirmwareFrames.statsPackets28(received: 1043))

    let stats = try await call.value
    #expect(stats.received == 1043)
    #expect(stats.appRxLogFrames == 7)
    #expect(await session.receivedRxLogFrames == 7)
    try await waitUntil("the stats event should be recorded") {
      await recorder.events.contains { if case .statsPackets = $0 { true } else { false } }
    }
    let dispatched = await recorder.events.compactMap { event -> PacketStats? in
      if case let .statsPackets(stats) = event { return stats }
      return nil
    }
    #expect(dispatched.map(\.appRxLogFrames) == [7])
  }

  /// A Cairn radio that opted the link in to RX_SYNC behind a lost SUBSCRIBE reply sends records in
  /// place of 0x88 frames while the app measures stock delivery. Each live record is counted once,
  /// apart from the 0x88 frames: the radio paces records by its journal, not in the pass that
  /// counts their packets, so they never feed the same-pass barrier.
  @Test
  func `live RX_SYNC records are counted once each, apart from 0x88 frames`() async throws {
    let transport = StockTestTransport()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: StockTestClock())

    func record(_ flags: UInt8, seq: UInt32) -> Data {
      var frame = Data([0xC8, flags])
      withUnsafeBytes(of: seq.littleEndian) { frame.append(contentsOf: $0) }
      return frame + Data([0xFA, 0x00, 0x00, 0x00, 0x14, 0xA6, 0x11, 0x00, UInt8(seq & 0xFF)])
    }
    await transport.receive(record(0x00, seq: 1))   // a whole live record
    await transport.receive(record(0x08, seq: 4))   // live, after a gap
    await transport.receive(record(0x02, seq: 5))   // live, its tail follows ...
    var tail = Data([0xC8, 0x04])                  // ... and is not counted again
    withUnsafeBytes(of: UInt32(5).littleEndian) { tail.append(contentsOf: $0) }
    await transport.receive(tail + Data([5, 0xAB]))
    await transport.receive(record(0x01, seq: 2))   // backfill: heard earlier, counted then
    await transport.receive(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: [1, 2, 3, 4])))

    // the stats reply is the barrier: it carries the count of every frame before it
    let call = Task { try await session.getStatsPackets() }
    try await waitUntil("CMD_GET_STATS should be sent") { await transport.sent(code: Self.getStats).count == 1 }
    await transport.receive(StockFirmwareFrames.statsPackets28(received: 4))
    let stats = try await call.value
    #expect(stats.appRxLogFrames == 1, "only the 0x88 frame")
    #expect(stats.appLiveRxRecords == 3, "one per live record: not its tail, not backfill")
    #expect(await session.receivedRxLogFrames == 1)
    #expect(await session.receivedLiveRxRecords == 3)
  }

  @Test
  func `a late reply keeps the frame count it arrived with`() async throws {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: clock)
    let (recorder, recording) = await EventRecorder.recording(session)
    defer { recording.cancel() }
    let frame = StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: [1, 2, 3, 4]))

    // The first request's reply is late: the request times out.
    let first = Task { try await session.getStatsPackets() }
    try await waitUntil("first CMD_GET_STATS") { await transport.sent(code: Self.getStats).count == 1 }
    await transport.receive(frame)
    await transport.receive(frame)
    try await waitUntil("the first request should be waiting") { clock.sleeperCount >= 1 }
    clock.advance(by: .seconds(5))
    let timeout = await #expect(throws: MeshCoreError.self) { try await first.value }
    #expect(isTimeout(timeout))

    // The second request takes the late reply, paired with the 2 frames before it, not with the
    // frames that arrive after it.
    let second = Task { try await session.getStatsPackets() }
    try await waitUntil("second CMD_GET_STATS") { await transport.sent(code: Self.getStats).count == 2 }
    await transport.receive(StockFirmwareFrames.statsPackets24(received: 102))
    for _ in 0..<3 {
      await transport.receive(frame)
    }
    await transport.receive(StockFirmwareFrames.statsPackets24(received: 105))

    let late = try await second.value
    #expect(late.received == 102)
    #expect(late.appRxLogFrames == 2)
    try await waitUntil("both replies should be dispatched") {
      await recorder.events.filter { if case .statsPackets = $0 { true } else { false } }.count == 2
    }
    let pairs = await recorder.events.compactMap { event -> (UInt32, UInt64?)? in
      if case let .statsPackets(stats) = event { return (stats.received, stats.appRxLogFrames) }
      return nil
    }
    #expect(pairs.map(\.0) == [102, 105])
    #expect(pairs.map(\.1) == [2, 5])
  }

  @Test
  func `transport drops are counted from the session's start`() async throws {
    let transport = StockTestTransport()
    await transport.setDroppedFrameCount(7) // an earlier connection's drops
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: StockTestClock())
    #expect(await session.droppedTransportFrames == 0)

    await transport.setDroppedFrameCount(10)
    #expect(await session.droppedTransportFrames == 3)
  }

  @Test
  func `transports that don't count drops report none`() async {
    #expect(await MockTransport().droppedFrameCount == 0)
  }
}
