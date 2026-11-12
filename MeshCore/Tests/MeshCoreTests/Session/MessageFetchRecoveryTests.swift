import Foundation
@testable import MeshCore
import Testing

/// A message fetch must end on every answer the radio can give, and the auto-drain must not
/// leave the radio's queue behind on the first failure: either one stranded the rest of the
/// offline queue until the radio's next MSG_WAITING push.
@Suite("MeshCoreSession message fetch recovery")
struct MessageFetchRecoveryTests {
  private static let getMessage = CommandCode.getMessage.rawValue
  private static let noMoreMessages = Data([ResponseCode.noMoreMessages.rawValue])

  private func dmFrame(_ text: String) -> Data {
    var frame = Data([ResponseCode.contactMessageReceivedV3.rawValue, 0x14, 0, 0])
    frame.append(Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6]))
    frame.append(0x02) // path length
    frame.append(0x00) // plain text
    frame.append(contentsOf: withUnsafeBytes(of: UInt32(1_760_000_000).littleEndian) { Array($0) })
    frame.append(contentsOf: text.utf8)
    return frame
  }

  private func fetchCount(_ transport: MockTransport) async -> Int {
    await transport.sentData.filter { $0.first == Self.getMessage }.count
  }

  // MARK: - Unreadable answers

  @Test(arguments: [
    Data([0x7E, 0x01, 0x02]), // a code below the push range this library doesn't know
    Data([ResponseCode.contactMessageReceivedV3.rawValue, 0x01]), // truncated DM
    Data([ResponseCode.channelMessageReceivedV3.rawValue]), // truncated channel message
    Data([ResponseCode.sentEcho.rawValue, 0x03]) // Cairn echo of an unknown kind
  ])
  func `unreadable answer is skipped and the next one returned`(unreadable: Data) async throws {
    let (session, transport) = try await startedSession()

    let fetch = Task { try await session.getMessage(timeout: 2) }
    try await waitUntil("first fetch") { await fetchCount(transport) == 1 }
    await transport.simulateReceive(unreadable)
    try await waitUntil("the fetch should ask again") { await fetchCount(transport) == 2 }
    await transport.simulateReceive(dmFrame("after the unreadable one"))

    guard case let .contactMessage(message) = try await fetch.value else {
      Issue.record("Expected the DM after the unreadable frame")
      return
    }
    #expect(message.text == "after the unreadable one")
  }

  @Test
  func `unreadable push does not answer a fetch`() async throws {
    let (session, transport) = try await startedSession()

    let fetch = Task { try await session.getMessage(timeout: 2) }
    try await waitUntil("first fetch") { await fetchCount(transport) == 1 }
    // A malformed advert push (0x80 range) is not this fetch's answer.
    await transport.simulateReceive(Data([ResponseCode.advertisement.rawValue, 0x01]))
    try await Task.sleep(for: .milliseconds(50))
    #expect(await fetchCount(transport) == 1)
    await transport.simulateReceive(Self.noMoreMessages)

    guard case .noMoreMessages = try await fetch.value else {
      Issue.record("Expected noMoreMessages")
      return
    }
  }

  @Test
  func `a run of unreadable answers ends the fetch with an error`() async throws {
    let (session, transport) = try await startedSession()

    let fetch = Task { try await session.getMessage(timeout: 2) }
    for ask in 1...MeshCoreSession.maxUndecodableFetchAnswers {
      try await waitUntil("fetch \(ask)") { await fetchCount(transport) == ask }
      await transport.simulateReceive(Data([0x7E]))
    }

    await #expect(throws: MeshCoreError.self) {
      _ = try await fetch.value
    }
  }

  // MARK: - Drain requests

  @Test
  func `requestMessageDrain drains without a push`() async throws {
    let (session, transport) = try await startedSession()
    await session.startAutoMessageFetching()
    defer { Task { await session.stopAutoMessageFetching() } }

    await session.requestMessageDrain()
    try await waitUntil("drain should fetch") { await fetchCount(transport) == 1 }
    await transport.simulateReceive(dmFrame("queued before connect"))
    try await waitUntil("drain should keep going") { await fetchCount(transport) == 2 }
    await transport.simulateReceive(Self.noMoreMessages)
  }

  @Test
  func `requestMessageDrain is a no-op while auto-fetch is off`() async throws {
    let (session, transport) = try await startedSession()

    await session.requestMessageDrain()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await fetchCount(transport) == 0)
  }

  @Test
  func `auto-drain asks again after a failed fetch`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 0.1, clientIdentifier: "MeshCore-Tests")
    )
    try await startSession(session, transport: transport)
    await session.startAutoMessageFetching()
    defer { Task { await session.stopAutoMessageFetching() } }

    await transport.simulateReceive(Data([ResponseCode.messagesWaiting.rawValue]))
    try await waitUntil("first drain fetch") { await fetchCount(transport) == 1 }
    // No answer: the fetch times out. The drain backs off and asks again on its own.
    try await waitUntil("drain should retry after the timeout", timeout: .seconds(5)) {
      await fetchCount(transport) >= 2
    }
    await transport.simulateReceive(Self.noMoreMessages)
  }

  // MARK: - Helpers

  private func startedSession() async throws -> (MeshCoreSession, MockTransport) {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 2, clientIdentifier: "MeshCore-Tests")
    )
    try await startSession(session, transport: transport)
    return (session, transport)
  }

  private func startSession(_ session: MeshCoreSession, transport: MockTransport) async throws {
    let startTask = Task { try await session.start() }
    try await waitUntil("appStart command should be sent") {
      await transport.sentData.count >= 1
    }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await startTask.value
    await transport.clearSentData()
  }

  private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting: \(description)")
    throw MeshCoreError.timeout
  }

  private func makeSelfInfoPacket() -> Data {
    var payload = Data([ResponseCode.selfInfo.rawValue])
    payload.append(0x01) // advType
    payload.append(UInt8(bitPattern: Int8(20))) // txPower
    payload.append(UInt8(bitPattern: Int8(22))) // maxTxPower
    payload.append(Data(repeating: 0xAA, count: 32)) // publicKey
    payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) }) // lat
    payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) }) // lon
    payload.append(0x00) // multiAcks
    payload.append(0x00) // adv policy
    payload.append(0x00) // telemetry mode
    payload.append(0x01) // manual add
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(910_525).littleEndian) { Data($0) }) // freq
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(62500).littleEndian) { Data($0) }) // bw
    payload.append(0x07) // sf
    payload.append(0x05) // cr
    payload.append("TestNode".data(using: .utf8)!)
    return payload
  }
}
