import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn sent-message echo session")
struct SentEchoSessionTests {
  @Test
  func `setCairnSyncSent sends sub 0x04 and returns the state`() async throws {
    let (session, transport) = try await makeStartedEchoSession()

    let task = Task { try await session.setCairnSyncSent(on: true) }
    try await waitUntil("command should be sent") { await transport.sentData.count == 2 }
    #expect(await transport.sentData[1] == Data([0xC0, 0x04, 0x01]))
    await transport.simulateReceive(Data([0xC0, 0x04, 0x00, 0x01, 0x02]))

    let state = try await task.value
    #expect(state.isOn)
    #expect(state.queued == 2)
    await session.stop()
  }

  @Test
  func `setCairnSyncSent on stock firmware throws unsupported`() async throws {
    let (session, transport) = try await makeStartedEchoSession()

    let task = Task { try await session.setCairnSyncSent(on: true) }
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
  func `sendAppStart renews the opt-in after a mid-session APP_START`() async throws {
    let (session, transport) = try await makeStartedEchoSession()

    let optIn = Task { try await session.setCairnSyncSent(on: true) }
    try await waitUntil("opt-in should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([0xC0, 0x04, 0x00, 0x01, 0x00]))
    _ = try await optIn.value

    // The board opts the link out on every APP_START: the session must ask again right after.
    let refresh = Task { try await session.sendAppStart() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(makeEchoSelfInfoPacket())
    try await waitUntil("opt-in should be renewed") { await transport.sentData.count == 4 }
    #expect(await transport.sentData[3] == Data([0xC0, 0x04, 0x01]))
    await transport.simulateReceive(Data([0xC0, 0x04, 0x00, 0x01, 0x00]))
    _ = try await refresh.value
    await session.stop()
  }

  @Test
  func `sendAppStart does not opt in when the app never did or opted out`() async throws {
    let (session, transport) = try await makeStartedEchoSession()

    let optOut = Task { try await session.setCairnSyncSent(on: false) }
    try await waitUntil("opt-out should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([0xC0, 0x04, 0x00, 0x00, 0x00]))
    _ = try await optOut.value

    let refresh = Task { try await session.sendAppStart() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(makeEchoSelfInfoPacket())
    _ = try await refresh.value
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.sentData.count == 3)
    await session.stop()
  }

  @Test
  func `getMessage returns a queued echo but never a live one`() async throws {
    let (session, transport) = try await makeStartedEchoSession()

    let task = Task { try await session.getMessage() }
    try await waitUntil("getMessage should be sent") { await transport.sentData.count == 2 }

    // A live echo inside the fetch window must not end the fetch.
    await transport.simulateReceive(echo(code: 0xC3, flags: 0x01, dest: [2, 0, 0, 0, 0, 0],
                                         timestamp: 10, ack: 0, text: "live"))
    await transport.simulateReceive(echo(code: 0xC2, flags: 0x00, dest: [1, 2, 3, 4, 5, 6],
                                         timestamp: 11, ack: 0xDEAD_BEEF, text: "queued"))

    let result = try await task.value
    guard case let .radioSentMessage(msg) = result else {
      Issue.record("Expected .radioSentMessage, got \(result)")
      await session.stop()
      return
    }
    #expect(!msg.isLive)
    #expect(msg.text == "queued")
    #expect(msg.ackCode == 0xDEAD_BEEF)
    await session.stop()
  }

  @Test
  func `live echo reaches event subscribers`() async throws {
    let (session, transport) = try await makeStartedEchoSession()
    let events = await session.events(filter: .radioSentMessage)

    let collector = Task { () -> RadioSentMessage? in
      for await event in events {
        if case let .radioSentMessage(msg) = event { return msg }
      }
      return nil
    }
    try await Task.sleep(for: .milliseconds(50))
    await transport.simulateReceive(echo(code: 0xC3, flags: 0x00, dest: [1, 2, 3, 4, 5, 6],
                                         timestamp: 99, ack: 7, text: "hi"))
    let msg = await collector.value
    #expect(msg?.isLive == true)
    #expect(msg?.text == "hi")
    await session.stop()
  }
}

private func makeStartedEchoSession() async throws -> (MeshCoreSession, MockTransport) {
  let transport = MockTransport()
  let session = MeshCoreSession(
    transport: transport,
    configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
  )
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeEchoSelfInfoPacket())
  try await startTask.value
  return (session, transport)
}

private func makeEchoSelfInfoPacket() -> Data {
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
