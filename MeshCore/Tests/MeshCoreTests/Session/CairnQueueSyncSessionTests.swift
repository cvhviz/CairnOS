import Foundation
@testable import MeshCore
import Testing

/// Queue sync's ARM and NEXT exchanges over a session (the firmware's `net/QUEUE_SYNC.md`).
@Suite("Cairn queue sync session")
struct CairnQueueSyncSessionTests {
  @Test
  func `a stray ERR ahead of NEXT's reply is not NEXT's answer`() async throws {
    let (session, transport) = try await makeStartedQueueSyncSession()

    let next = Task { try await session.nextCairnQueuedFrame(ackSeq: 0) }
    try await waitUntil("NEXT should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == hex("C0 08 02 00 00 00 00"))
    // A late reply to another command, or another link's error the radio writes to every interface.
    await transport.simulateError(code: ErrorCode.unsupportedCommand.rawValue)
    await transport.simulateReceive(hex("C0 08 00 02 E8 03 00 00 00 00"))
    await transport.simulateReceive(Data([ResponseCode.noMoreMessages.rawValue]))

    let frame = try await next.value
    #expect(frame.seq == 1000)
    guard case .noMoreMessages = frame.content else {
      Issue.record("Expected the queue's end, got \(frame.content)")
      await session.stop()
      return
    }
    await session.stop()
  }

  @Test
  func `NEXT still fails on the radio's own BUSY refusal`() async throws {
    let (session, transport) = try await makeStartedQueueSyncSession()

    let next = Task { try await session.nextCairnQueuedFrame(ackSeq: 7) }
    try await waitUntil("NEXT should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(hex("C0 08 01 02"))

    let error = await #expect(throws: MeshCoreError.self) { try await next.value }
    guard case let .deviceError(code)? = error else {
      Issue.record("Expected deviceError, got \(String(describing: error))")
      await session.stop()
      return
    }
    #expect(code == MeshCoreSession.queueSyncBusyCode)
    await session.stop()
  }

  @Test
  func `ARM waits for the radio's pushes to drain before it asks`() async throws {
    let (session, transport) = try await makeStartedQueueSyncSession()

    // A push burst right after connecting: the radio's reply to ARM would join a full send queue.
    await transport.simulateReceive(Data([ResponseCode.messagesWaiting.rawValue]))
    let arm = Task { try await session.armCairnQueueSync(on: true) }
    try await Task.sleep(for: .milliseconds(80))
    #expect(await transport.sentData.count == 1, "ARM held while the link is busy")

    try await waitUntil("ARM should go once the link is quiet") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == hex("C0 08 01 01"))
    await transport.simulateReceive(hex("C0 08 00 01 01 01 00 00 00 01 E8 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))

    let state = try await arm.value
    #expect(state.isArmed)
    await session.stop()
  }

  @Test
  func `ARM on stock firmware throws unsupported`() async throws {
    let (session, transport) = try await makeStartedQueueSyncSession()

    let arm = Task { try await session.armCairnQueueSync(on: true) }
    try await waitUntil("ARM should be sent") { await transport.sentData.count == 2 }
    await transport.simulateError(code: ErrorCode.unsupportedCommand.rawValue)

    let error = await #expect(throws: MeshCoreError.self) { try await arm.value }
    guard case let .deviceError(code)? = error else {
      Issue.record("Expected deviceError, got \(String(describing: error))")
      await session.stop()
      return
    }
    #expect(code == ErrorCode.unsupportedCommand.rawValue)
    await session.stop()
  }
}

private func hex(_ string: String) -> Data {
  Data(string.split(separator: " ").compactMap { UInt8($0, radix: 16) })
}

private func makeStartedQueueSyncSession() async throws -> (MeshCoreSession, MockTransport) {
  let transport = MockTransport()
  let session = MeshCoreSession(
    transport: transport,
    configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
  )
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeQueueSyncSelfInfoPacket())
  try await startTask.value
  return (session, transport)
}

private func makeQueueSyncSelfInfoPacket() -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1)
  payload.append(UInt8(bitPattern: 22))
  payload.append(UInt8(bitPattern: 22))
  payload.append(Data(repeating: 0x01, count: 32))
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })
  payload.append(0)
  payload.append(0)
  payload.append(0)
  payload.append(0)
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) })
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) })
  payload.append(11)
  payload.append(5)
  return payload
}
