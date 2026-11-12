import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn chat history session methods")
struct CairnHistorySessionTests {
  @Test
  func `query returns the board's count`() async throws {
    let (session, transport) = try await makeHistorySession()
    let task = Task { try await session.queryCairnHistory() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x05]))
    await transport.simulateReceive(Data([0xC0, 0x05, 0x00, 7, 0, 0, 0, 3, 0, 0]))
    let reply = try await task.value
    #expect(reply.storeID == 7)
    #expect(reply.total == 3)
    await session.stop()
  }

  @Test
  func `a page collects its records, joins a split one, and ends on END`() async throws {
    let (session, transport) = try await makeHistorySession()
    let task = Task { try await session.fetchCairnHistoryPage(sinceSeq: 0, max: 3) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x05, 0, 0, 0, 0, 3]))
    await transport.simulateReceive(Data([0xC0, 0x05, 0x00, 7, 0, 0, 0, 3, 0, 3]))
    await transport.simulateReceive(recordFrame(flags: 0, seq: 1, key: [1, 2, 3, 4, 5, 6], channel: -1, pathLen: 0,
                                                stored: 10, sent: 0, snr: 0, rssi: 0, text: "one"))
    await transport.simulateReceive(recordFrame(flags: 0x80, seq: 2, key: [1, 2, 3, 4, 5, 6], channel: -1, pathLen: 0,
                                                stored: 11, sent: 0, snr: 0, rssi: 0, text: String(repeating: "b", count: 147)))
    await transport.simulateReceive(Data([0xC4, 0x40, 2, 0, 0, 0]) + Data("tail".utf8))
    await transport.simulateReceive(recordFrame(flags: 0x01, seq: 3, key: [1, 2, 3, 4, 5, 6], channel: -1, pathLen: 0,
                                                stored: 12, sent: 0, snr: 0, rssi: 0, text: "three"))
    await transport.simulateReceive(Data([0xC5, 0x00, 3, 0, 0, 0, 0, 0, 7, 0, 0, 0]))
    let page = try await task.value
    #expect(page.records.map { $0.seq } == [1, 2, 3])
    #expect(page.records[1].string == String(repeating: "b", count: 147) + "tail")
    #expect(page.records[2].flags.contains(.outgoing))
    #expect(page.end?.lastSeq == 3)
    #expect(page.nextSince(after: 0) == 3)
    await session.stop()
  }

  @Test
  func `a page cut short keeps whole records and drops a head without its tail`() async throws {
    let (session, transport) = try await makeHistorySession()
    let task = Task { try await session.fetchCairnHistoryPage(sinceSeq: 5, max: 4, inactivity: 0.3) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([0xC0, 0x05, 0x00, 7, 0, 0, 0, 4, 0, 4]))
    await transport.simulateReceive(recordFrame(flags: 0, seq: 6, key: [1, 2, 3, 4, 5, 6], channel: -1, pathLen: 0,
                                                stored: 10, sent: 0, snr: 0, rssi: 0, text: "six"))
    await transport.simulateReceive(recordFrame(flags: 0x80, seq: 7, key: [1, 2, 3, 4, 5, 6], channel: -1, pathLen: 0,
                                                stored: 11, sent: 0, snr: 0, rssi: 0, text: String(repeating: "c", count: 147)))
    let page = try await task.value   // the link goes quiet: no tail, no END
    #expect(page.records.map { $0.seq } == [6])
    #expect(page.end == nil)
    #expect(page.nextSince(after: 5) == 6)   // record 7 is asked for again
    await session.stop()
  }

  @Test
  func `BUSY returns at once with no records`() async throws {
    let (session, transport) = try await makeHistorySession()
    let task = Task { try await session.fetchCairnHistoryPage(sinceSeq: 0) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([0xC0, 0x05, 0x01, 7, 0, 0, 0, 9, 0, 0]))
    let page = try await task.value
    #expect(page.reply.status == CairnHistoryPageReply.Status.busy)
    #expect(page.records.isEmpty)
    await session.stop()
  }

  @Test
  func `other firmware throws unsupported`() async throws {
    let (session, transport) = try await makeHistorySession()
    let task = Task { try await session.queryCairnHistory() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateError(code: ErrorCode.unsupportedCommand.rawValue)
    await #expect(throws: MeshCoreError.self) { try await task.value }
    await session.stop()
  }
}

private func makeHistorySession() async throws -> (MeshCoreSession, MockTransport) {
  let transport = MockTransport()
  let session = MeshCoreSession(
    transport: transport,
    configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
  )
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeHistorySelfInfo())
  try await startTask.value
  return (session, transport)
}

private func makeHistorySelfInfo() -> Data {
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
