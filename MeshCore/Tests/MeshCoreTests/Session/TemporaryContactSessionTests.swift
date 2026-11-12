import Foundation
@testable import MeshCore
import Testing

@Suite("Temporary contact session methods")
struct TemporaryContactSessionTests {
  @Test
  func `addTemporaryContact writes a nameless zero-hop type 0 entry`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let key = Data((0 ..< 32).map { UInt8($0) })

    let task = Task { try await session.addTemporaryContact(publicKey: key) }
    try await waitUntil("lookup should be sent") {
      await transport.sentData.count == 2
    }
    #expect(await transport.sentData[1][0] == CommandCode.getContactByKey.rawValue)
    await transport.simulateError(code: 2)
    try await waitUntil("command should be sent") {
      await transport.sentData.count == 3
    }

    let sent = await transport.sentData[2]
    #expect(sent.count == 144)
    #expect(sent[0] == CommandCode.updateContact.rawValue)
    #expect(Data(sent[1 ... 32]) == key)
    #expect(sent[33] == 0, "type 0")
    #expect(sent[35] == 0, "zero-hop direct")
    #expect(Data(sent[100 ..< 132]) == Data(count: 32), "no name")

    await transport.simulateOK()
    #expect(try await task.value)
    await session.stop()
  }

  @Test
  func `addTemporaryContact leaves an entry the radio already holds untouched`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let key = Data((0 ..< 32).map { UInt8($0) })

    let task = Task { try await session.addTemporaryContact(publicKey: key) }
    try await waitUntil("lookup should be sent") {
      await transport.sentData.count == 2
    }
    await transport.simulateReceive(makeContactPacket(publicKey: key, name: ""))

    #expect(try await task.value == false)
    #expect(await transport.sentData.count == 2, "nothing is written over the existing entry")
    await session.stop()
  }

  @Test
  func `addTemporaryContact adds nothing when the lookup fails`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 0.2, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let key = Data((0 ..< 32).map { UInt8($0) })

    await #expect(throws: MeshCoreError.self) {
      try await session.addTemporaryContact(publicKey: key)
    }
    #expect(await transport.sentData.count == 2, "only the lookup is sent")
    await session.stop()
  }

  @Test
  func `addTemporaryContact rejects a key prefix`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    await #expect(throws: MeshCoreError.self) {
      try await session.addTemporaryContact(publicKey: Data(repeating: 0xAB, count: 6))
    }
    #expect(await transport.sentData.count == 1)
    await session.stop()
  }
}

private func startSession(
  _ session: MeshCoreSession,
  transport: MockTransport
) async throws {
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeSelfInfoPacket())
  try await startTask.value
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

private func makeContactPacket(publicKey: Data, name: String) -> Data {
  var packet = Data([ResponseCode.contact.rawValue])
  packet.append(publicKey)
  packet.append(ContactType.chat.rawValue)
  packet.append(ContactFlags().rawValue)
  packet.append(0xFF)
  packet.append(Data(repeating: 0, count: 64))
  let nameBytes = Array(name.utf8.prefix(31))
  packet.append(contentsOf: nameBytes)
  packet.append(Data(repeating: 0, count: 32 - nameBytes.count))
  packet.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
  packet.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })
  packet.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })
  packet.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
  return packet
}
