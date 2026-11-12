import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn spectrum session methods")
struct CairnSpectrumSessionTests {
  @Test
  func `STATS sends the window and marks the radio as supported`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    #expect(await session.cairnSpectrumSupport == nil)
    let task = Task { try await session.getCairnSpectrumStats(window: 2) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x06, 0x00, 0x02]))
    await transport.simulateReceive(SpectrumFrames.statsReply(SpectrumFrames.statsBlock(window: 2)))
    let reply = try await task.value
    #expect(reply.status == .ok)
    #expect(reply.stats?.window == 2)
    #expect(await session.cairnSpectrumSupport == true)
    await session.stop()
  }

  @Test
  func `a HISTORY assembles its columns, marks and end`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let request = CairnSpectrumHistoryRequest(window: 1, columns: 180, epoch: 3, sinceSlot: 394, scaleLo: -120, markSince: 100)
    let task = Task { try await session.fetchCairnSpectrumHistory(request) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == PacketBuilder.cairnSpectrumHistory(request))
    // an earlier transfer's late frame and its aborted end arrive first
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 8, back: 0, columns: [SpectrumFrames.txColumn]))
    await transport.simulateReceive(SpectrumFrames.end(xfer: 8, aborted: true))
    await transport.simulateReceive(SpectrumFrames.historyReply(xfer: 9, vflags: 0x02, count: 6, marks: 1, frames: 3))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 9, back: 5, columns: [
      SpectrumFrames.dataColumn, SpectrumFrames.gapColumn, SpectrumFrames.dataColumn, SpectrumFrames.gapColumn,
    ]))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 8, back: 0, columns: [SpectrumFrames.txColumn]))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 9, back: 1, columns: [
      SpectrumFrames.txColumn, SpectrumFrames.dataColumn,
    ]))
    await transport.simulateReceive(SpectrumFrames.marksPush(xfer: 9, marks: [SpectrumFrames.mark]))
    await transport.simulateReceive(SpectrumFrames.end(xfer: 9))
    let history = try await task.value
    #expect(history.completed)
    #expect(history.reply.xfer == 9)
    #expect(history.reply.nowSlot == 400)
    #expect(history.columns.map { $0?.isData } == [true, false, true, false, false, true])
    #expect(history.columns[4]?.isTX == true)
    #expect(history.marks.map(\.rxMs) == [123_456])
    await session.stop()
  }

  @Test
  func `a HISTORY is dated when its reply arrives, not at its end`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task { try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 1, columns: 180)) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    let beforeReply = Date()
    await transport.simulateReceive(SpectrumFrames.historyReply(xfer: 3, count: 1, marks: 0, frames: 1))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 3, back: 0, columns: [SpectrumFrames.gapColumn]))
    try await Task.sleep(for: .milliseconds(600))
    let beforeEnd = Date()
    await transport.simulateReceive(SpectrumFrames.end(xfer: 3))
    let history = try await task.value
    #expect(history.completed)
    #expect(history.receivedAt >= beforeReply)
    #expect(history.receivedAt < beforeEnd)
    await session.stop()
  }

  @Test
  func `a late reply for another window or width is not taken for this request`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task { try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 1, columns: 180)) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    // a cancelled poll's answer: the 10 min window, then the right window at another width
    await transport.simulateReceive(SpectrumFrames.historyReply(block: SpectrumFrames.statsBlock(window: 2), xfer: 1, count: 1, marks: 0, frames: 0))
    await transport.simulateReceive(SpectrumFrames.historyReply(xfer: 2, ncols: 240, count: 1, marks: 0, frames: 0))
    await transport.simulateReceive(SpectrumFrames.historyReply(xfer: 3, count: 1, marks: 0, frames: 1))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 3, back: 0, columns: [SpectrumFrames.gapColumn]))
    await transport.simulateReceive(SpectrumFrames.end(xfer: 3))
    let history = try await task.value
    #expect(history.reply.xfer == 3)
    #expect(history.completed)
    await session.stop()
  }

  @Test
  func `a transfer that goes quiet is not completed`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task {
      try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 1, columns: 180), inactivity: 0.3)
    }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(SpectrumFrames.historyReply(xfer: 4, count: 6, marks: 0, frames: 2))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 4, back: 5, columns: [
      SpectrumFrames.gapColumn, SpectrumFrames.gapColumn, SpectrumFrames.gapColumn, SpectrumFrames.gapColumn,
    ]))
    let history = try await task.value   // the second frame and the end never come
    #expect(!history.completed)
    #expect(history.columns.prefix(4).allSatisfy { $0 == .gap })
    #expect(history.columns.suffix(2).allSatisfy { $0 == nil })
    await session.stop()
  }

  @Test
  func `an aborted end or a missing frame is not completed`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task { try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 0, columns: 180)) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(SpectrumFrames.historyReply(block: SpectrumFrames.statsBlock(window: 0), xfer: 5, count: 1, marks: 0, frames: 1))
    await transport.simulateReceive(SpectrumFrames.end(xfer: 5, aborted: true))
    #expect(try await !task.value.completed)

    let second = Task { try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 0, columns: 180)) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(SpectrumFrames.historyReply(block: SpectrumFrames.statsBlock(window: 0), xfer: 6, count: 1, marks: 1, frames: 2))
    await transport.simulateReceive(SpectrumFrames.columnsPush(xfer: 6, back: 0, columns: [SpectrumFrames.gapColumn]))
    await transport.simulateReceive(SpectrumFrames.end(xfer: 6))   // the marks frame was lost
    let history = try await second.value
    #expect(!history.completed)
    #expect(history.columns == [.gap])
    await session.stop()
  }

  @Test
  func `BUSY and TOO_SOON return at once without pushes`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let busy = Task { try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 1, columns: 180)) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([0xC0, 0x06, 0x01, 0x01]))
    let busyHistory = try await busy.value
    #expect(busyHistory.reply.status == .busy)
    #expect(busyHistory.columns.isEmpty)
    #expect(!busyHistory.completed)

    let soon = Task { try await session.fetchCairnSpectrumHistory(CairnSpectrumHistoryRequest(window: 1, columns: 180)) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(Data([0xC0, 0x06, 0x03, 0x01]))
    #expect(try await soon.value.reply.status == .tooSoon)
    #expect(await session.cairnSpectrumSupport == nil)   // neither says yes or no
    await session.stop()
  }

  @Test
  func `UNAVAILABLE marks the radio as without the feature`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task { try await session.getCairnSpectrumStats(window: 1) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([0xC0, 0x06, 0x02, 0x00]))
    #expect(try await task.value.status == .unavailable)
    #expect(await session.cairnSpectrumSupport == false)
    await session.stop()
  }

  @Test
  func `other firmware throws unsupported and is remembered`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task { try await session.getCairnSpectrumStats(window: 1) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateError(code: ErrorCode.unsupportedCommand.rawValue)
    do {
      _ = try await task.value
      Issue.record("Expected deviceError")
    } catch let MeshCoreError.deviceError(code) {
      #expect(code == ErrorCode.unsupportedCommand.rawValue)
    }
    #expect(await session.cairnSpectrumSupport == false)
    await session.stop()
  }

  @Test
  func `TREND returns its points`() async throws {
    let (session, transport) = try await makeSpectrumSession()
    let task = Task { try await session.fetchCairnSpectrumTrend() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x06, 0x02, 160]))
    await transport.simulateReceive(Data([0xC0, 0x06, 0x00, 0x02, 0x03, 0x00, 0x88, 0x01, 2, 0x8D, 0x00]))
    let reply = try await task.value
    #expect(reply.trend?.points == [-115, nil])
    await session.stop()
  }
}

private func makeSpectrumSession() async throws -> (MeshCoreSession, MockTransport) {
  let transport = MockTransport()
  let session = MeshCoreSession(
    transport: transport,
    configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
  )
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeSpectrumSelfInfo())
  try await startTask.value
  return (session, transport)
}

private func makeSpectrumSelfInfo() -> Data {
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
