import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn firmware update session methods")
struct CairnFirmwareSessionTests {
  @Test
  func `status sends the STATUS command and returns the reply`() async throws {
    let (session, transport) = try await makeStartedSession()

    let task = Task { try await session.getCairnFirmwareStatus() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x01]))

    var reply = Data([0xC0, 0x01, 0x00, 0x01, 11])
    reply.append(Data("MeshCore L2".utf8))
    reply.append(9)
    reply.append(Data("Cairn 111".utf8))
    reply.append(contentsOf: [3, 10, 0, 1, 140, 0, 61, 0])
    await transport.simulateReceive(reply)

    let status = try await task.value
    #expect(status.build == "Cairn 111")
    #expect(status.ipAddress == "10.0.1.140")
    await session.stop()
  }

  @Test
  func `status on other firmware throws the unsupported command error`() async throws {
    let (session, transport) = try await makeStartedSession()

    let task = Task { try await session.getCairnFirmwareStatus() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    await transport.simulateError(code: ErrorCode.unsupportedCommand.rawValue)

    let error = await #expect(throws: MeshCoreError.self) { try await task.value }
    guard case let .deviceError(code)? = error else {
      Issue.record("Expected deviceError, got \(String(describing: error))")
      await session.stop()
      return
    }
    #expect(code == ErrorCode.unsupportedCommand.rawValue)
    await session.stop()
  }

  @Test
  func `start returns the reply, then the push arrives`() async throws {
    let (session, transport) = try await makeStartedSession()

    let wait = Task { await session.waitForCairnFirmwareStartResult(timeout: 10) }
    let start = Task { try await session.startCairnFirmwareUpdate() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x02]))
    await transport.simulateReceive(Data([0xC0, 0x02, 0x00]))
    #expect(try await start.value == .asking)

    var push = Data([0xC1, 0x02, 0x00, 10, 0, 1, 140, 80, 0, 8])
    push.append(Data("meshcore".utf8))
    push.append(12)
    push.append(Data("abcdefghjk23".utf8))
    await transport.simulateReceive(push)

    let result = await wait.value
    #expect(result?.outcome == .allowed)
    #expect(result?.password == "abcdefghjk23")
    await session.stop()
  }

  @Test
  func `cancel sends CANCEL and awaits its reply`() async throws {
    let (session, transport) = try await makeStartedSession()

    let task = Task { try await session.cancelCairnFirmwareUpdate() }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x03]))
    await transport.simulateReceive(Data([0xC0, 0x03, 0x00]))
    try await task.value
    await session.stop()
  }
}

private func makeStartedSession() async throws -> (MeshCoreSession, MockTransport) {
  let transport = MockTransport()
  let session = MeshCoreSession(
    transport: transport,
    configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
  )
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeSelfInfoPacket())
  try await startTask.value
  return (session, transport)
}

private func makeSelfInfoPacket() -> Data {
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
