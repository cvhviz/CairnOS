import Foundation
@testable import MeshCore
import Testing

/// Covers the wire half of MeshCore 1.18's companion command line: a command goes as
/// `CMD_SEND_TXT_MSG` with `TXT_TYPE_CLI_COMMAND`, the reply comes back as CLI data in a
/// V3 contact message, and the permission is contact flag 0x10 in the contact record.
@Suite("Companion CLI")
struct CompanionCLITests {
  private let destination = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
  private let timestamp = Date(timeIntervalSince1970: 1_704_067_200)

  // MARK: - Send frame

  @Test
  func `companion command frame carries txt_type 3`() {
    let packet = PacketBuilder.sendCommand(
      to: destination,
      command: "00|ver",
      timestamp: timestamp,
      textType: .cliCommand
    )

    #expect(packet[0] == 0x02, "CMD_SEND_TXT_MSG")
    #expect(packet[1] == 0x03, "TXT_TYPE_CLI_COMMAND")
    #expect(packet[2] == 0x00, "attempt")
    #expect(packet.readUInt32LE(at: 3) == 1_704_067_200, "timestamp LE")
    #expect(Data(packet[7..<13]) == destination.prefix(6), "6-byte destination prefix")
    #expect(String(data: Data(packet[13...]), encoding: .utf8) == "00|ver")
    #expect(packet.count == 13 + 6)
  }

  @Test
  func `default command frame stays CLI data`() {
    let packet = PacketBuilder.sendCommand(to: destination, command: "ver", timestamp: timestamp)
    #expect(packet[1] == 0x01, "TXT_TYPE_CLI_DATA for repeaters and rooms")
  }

  @Test
  func `companion and repeater frames differ only in the type byte`() {
    let companion = PacketBuilder.sendCommand(
      to: destination, command: "get name", timestamp: timestamp, textType: .cliCommand
    )
    let repeater = PacketBuilder.sendCommand(to: destination, command: "get name", timestamp: timestamp)
    var patched = repeater
    patched[1] = 0x03
    #expect(companion == patched)
  }

  @Test
  func `text type raw values match the firmware`() {
    #expect(TextType.plainText.rawValue == 0)
    #expect(TextType.cliData.rawValue == 1)
    #expect(TextType.signed.rawValue == 2)
    #expect(TextType.cliCommand.rawValue == 3)
  }

  // MARK: - Received frames

  /// A `RESP_CODE_CONTACT_MSG_RECV_V3` frame as the radio queues it.
  private func contactMessageV3(textType: UInt8, text: String) -> Data {
    var frame = Data([0x10, 0x28, 0x00, 0x00])
    frame.append(destination.prefix(6))
    frame.append(0x02) // path length
    frame.append(textType)
    frame.append(contentsOf: withUnsafeBytes(of: UInt32(1_704_067_201).littleEndian) { Array($0) })
    frame.append(Data(text.utf8))
    return frame
  }

  @Test
  func `tagged CLI data reply parses with its tag intact`() throws {
    guard case let .contactMessageReceived(message) = PacketParser.parse(
      contactMessageV3(textType: 0x01, text: "00|> Field unit")
    ) else {
      Issue.record("expected contactMessageReceived")
      return
    }
    #expect(message.textType == 0x01)
    #expect(message.text == "00|> Field unit")
    #expect(message.senderPublicKeyPrefix == destination.prefix(6))
    #expect(message.signature == nil)
  }

  @Test
  func `incoming companion command parses as txt_type 3`() throws {
    guard case let .contactMessageReceived(message) = PacketParser.parse(
      contactMessageV3(textType: 0x03, text: "4F|ver")
    ) else {
      Issue.record("expected contactMessageReceived")
      return
    }
    #expect(message.textType == TextType.cliCommand.rawValue)
    #expect(message.text == "4F|ver")
    #expect(message.signature == nil, "only txt_type 2 carries a signature")
  }

  // MARK: - Permission flag

  @Test
  func `remote CLI flag is bit 4`() {
    #expect(ContactFlags.remoteCLI.rawValue == 0x10)
    #expect(ContactFlags.remoteCLI.isDisjoint(with: [.favorite, .telemetryAll]))
  }

  @Test
  func `flag update frame writes 0x10 at the flags byte and keeps the other bits`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let contact = MeshContact(
      id: "test",
      publicKey: Data(repeating: 0xAA, count: 32),
      type: .chat,
      flags: [.favorite, .telemetryBase],
      outPathLength: 2,
      outPath: Data([0x11, 0x22]),
      advertisedName: "Node",
      lastAdvertisement: Date(timeIntervalSince1970: 1000),
      latitude: 0,
      longitude: 0,
      lastModified: Date()
    )

    let grant = Task { try await session.changeContactFlags(contact, flags: contact.flags.union(.remoteCLI)) }
    try await waitUntil("grant should be sent") { await transport.sentData.count == 1 }
    let granted = await transport.sentData[0]
    await transport.simulateOK()
    try await grant.value

    #expect(granted[0] == 0x09, "CMD_ADD_UPDATE_CONTACT")
    #expect(Data(granted[1..<33]) == contact.publicKey)
    #expect(granted[33] == ContactType.chat.rawValue)
    #expect(granted[34] == 0x13, "favourite + base telemetry + remote commands")
    #expect(granted[35] == 0x02, "out path length unchanged")
    #expect(Data(granted[36..<38]) == contact.outPath)

    let revoke = Task {
      try await session.changeContactFlags(contact, flags: contact.flags.union(.remoteCLI).subtracting(.remoteCLI))
    }
    try await waitUntil("revoke should be sent") { await transport.sentData.count == 2 }
    let revoked = await transport.sentData[1]
    await transport.simulateOK()
    try await revoke.value

    #expect(revoked[34] == 0x03, "only bit 4 cleared")
    await session.stop()
  }

  // MARK: - Session

  @Test
  func `sendCompanionCommand sends txt_type 3 and returns the sent info`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task { try await session.sendCompanionCommand(to: destination, command: "07|board") }
    try await waitUntil("command should be sent") { await transport.sentData.count == 1 }

    let sent = await transport.sentData[0]
    #expect(sent[0] == 0x02)
    #expect(sent[1] == 0x03)
    #expect(Data(sent[7..<13]) == destination.prefix(6))
    #expect(String(data: Data(sent[13...]), encoding: .utf8) == "07|board")

    await transport.simulateReceive(messageSentPacket(flood: true, timeoutMs: 4200))
    let info = try await task.value
    #expect(info.route == 1)
    #expect(info.suggestedTimeoutMs == 4200)
    await session.stop()
  }

  @Test
  func `older firmware rejecting txt_type 3 surfaces device error 1`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task { try await session.sendCompanionCommand(to: destination, command: "00|ver") }
    try await waitUntil("command should be sent") { await transport.sentData.count == 1 }
    await transport.simulateError(code: 1) // ERR_CODE_UNSUPPORTED_CMD

    let error = await #expect(throws: MeshCoreError.self) { try await task.value }
    guard case let .deviceError(code)? = error else {
      Issue.record("expected deviceError, got \(String(describing: error))")
      await session.stop()
      return
    }
    #expect(code == 1)
    await session.stop()
  }

  // MARK: - Helpers

  /// `RESP_CODE_SENT`: route, expected ACK (zero for CLI), suggested timeout.
  private func messageSentPacket(flood: Bool, timeoutMs: UInt32) -> Data {
    var data = Data([ResponseCode.messageSent.rawValue, flood ? 1 : 0, 0, 0, 0, 0])
    data.append(contentsOf: withUnsafeBytes(of: timeoutMs.littleEndian) { Array($0) })
    return data
  }

  private func startSession(_ session: MeshCoreSession, transport: MockTransport) async throws {
    let startTask = Task { try await session.start() }
    try await waitUntil("transport should have sent appStart") {
      await transport.sentData.count >= 1
    }
    await transport.simulateReceive(selfInfoPacket())
    try await startTask.value
    await transport.clearSentData()
  }

  private func selfInfoPacket() -> Data {
    var data = Data([ResponseCode.selfInfo.rawValue])
    data.append(0) // advType
    data.append(0) // txPower
    data.append(0) // maxTxPower
    data.append(Data(repeating: 0x01, count: 32)) // publicKey
    data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
    data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
    data.append(contentsOf: [0, 0, 0, 0]) // multi acks, loc policy, telemetry, manual add
    data.append(contentsOf: withUnsafeBytes(of: UInt32(915_000).littleEndian) { Array($0) }) // freq
    data.append(contentsOf: withUnsafeBytes(of: UInt32(125_000).littleEndian) { Array($0) }) // bw
    data.append(7) // sf
    data.append(5) // cr
    data.append(contentsOf: "Test".utf8) // name
    return data
  }
}
