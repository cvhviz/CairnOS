import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// Settings › Radio › Receive: the companion's receive-gain switches read and set through its own
/// command line (`CMD_RUN_CLI_COMMAND`, firmware v14+), against a session on a stand-in transport.
@Suite("Receive gain")
struct ReceiveGainTests {
  @Test
  func `a reply reads as on, off, or no such switch`() {
    #expect(SettingsService.switchState(fromReply: "> on") == true)
    #expect(SettingsService.switchState(fromReply: "> off") == false)
    #expect(SettingsService.switchState(fromReply: "on\n") == true)
    #expect(SettingsService.switchState(fromReply: "Error: unsupported") == nil)
    #expect(SettingsService.switchState(fromReply: "Unknown command") == nil)
    #expect(SettingsService.switchState(fromReply: "OK") == nil)
    #expect(SettingsService.switchState(fromReply: "> 22") == nil)
  }

  @Test
  @MainActor
  func `both switches are read through the command line, a missing one left out`() async throws {
    let (session, transport) = try await startedSession()
    defer { Task { await session.stop() } }
    let service = SettingsService(session: session)

    let read = Task { await service.readReceiveGain() }
    let first = try await expectCommand("get radio.rxgain", sentAt: 1, on: transport)
    await transport.simulateReceive(reply("> on", tag: first))
    let second = try await expectCommand("get radio.fem.rxgain", sentAt: 2, on: transport)
    await transport.simulateReceive(reply("Error: unsupported", tag: second))

    let gain = await read.value
    #expect(gain == ReceiveGain(boostedRX: true, femLNA: nil))
    #expect(!gain.isEmpty)
  }

  @Test
  @MainActor
  func `firmware without the command line has neither switch`() async throws {
    let (session, transport) = try await startedSession()
    defer { Task { await session.stop() } }
    let service = SettingsService(session: session)

    let read = Task { await service.readReceiveGain() }
    try await waitUntil("first read sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(Data([ResponseCode.error.rawValue, ErrorCode.unsupportedCommand.rawValue]))
    try await waitUntil("second read sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(Data([ResponseCode.error.rawValue, ErrorCode.unsupportedCommand.rawValue]))

    #expect(await read.value.isEmpty)
  }

  @Test
  @MainActor
  func `setting the LNA sends the command and accepts the radio's OK`() async throws {
    let (session, transport) = try await startedSession()
    defer { Task { await session.stop() } }
    let service = SettingsService(session: session)

    let write = Task { try await service.setFEMLNA(true) }
    let tag = try await expectCommand("set radio.fem.rxgain on", sentAt: 1, on: transport)
    await transport.simulateReceive(reply("OK - LoRa FEM RX gain on", tag: tag))
    try await write.value
  }

  @Test
  @MainActor
  func `a late reply to an earlier command never answers this one`() async throws {
    let (session, transport) = try await startedSession()
    defer { Task { await session.stop() } }
    let service = SettingsService(session: session)

    let read = Task { await service.readReceiveGain() }
    let first = try await expectCommand("get radio.rxgain", sentAt: 1, on: transport)
    await transport.simulateReceive(reply("> off", tag: "zz|"))   // another command's, come late
    await transport.simulateReceive(reply("> on", tag: first))
    let second = try await expectCommand("get radio.fem.rxgain", sentAt: 2, on: transport)
    await transport.simulateReceive(reply("> off", tag: second))

    #expect(await read.value == ReceiveGain(boostedRX: true, femLNA: false))
  }

  @Test
  @MainActor
  func `a refused set throws`() async throws {
    let (session, transport) = try await startedSession()
    defer { Task { await session.stop() } }
    let service = SettingsService(session: session)

    let write = Task { try await service.setBoostedRX(false) }
    let tag = try await expectCommand("set radio.rxgain off", sentAt: 1, on: transport)
    await transport.simulateReceive(reply("Error: busy", tag: tag))
    await #expect(throws: SettingsServiceError.self) { try await write.value }
  }

  @Test
  @MainActor
  func `a chip without boosted mode is put back and reported as unsupported`() async throws {
    let (session, transport) = try await startedSession()
    defer { Task { await session.stop() } }
    let service = SettingsService(session: session)

    let write = Task { try await service.setBoostedRX(true) }
    let tag = try await expectCommand("set radio.rxgain on", sentAt: 1, on: transport)
    await transport.simulateReceive(reply("Error: unsupported", tag: tag))
    // the firmware saved "on" before asking the chip: it is set back to off
    let back = try await expectCommand("set radio.rxgain off", sentAt: 2, on: transport)
    await transport.simulateReceive(reply("Error: unsupported", tag: back))
    do {
      try await write.value
      Issue.record("Expected unsupportedSetting")
    } catch SettingsServiceError.unsupportedSetting {
    } catch {
      Issue.record("Expected unsupportedSetting, got \(error)")
    }
  }

  // MARK: - Helpers

  @MainActor
  private func startedSession() async throws -> (MeshCoreSession, MockTransport) {
    let transport = MockTransport()
    let session = MeshCoreSession(transport: transport)
    let startTask = Task { try await session.start() }
    try await waitUntil("session should send app start") { await transport.sentData.count == 1 }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await startTask.value
    return (session, transport)
  }

  /// Waits for `command` (after its 3-character tag) and returns the tag, for the reply.
  @discardableResult
  private func expectCommand(_ command: String, sentAt index: Int, on transport: MockTransport) async throws -> String {
    try await waitUntil("'\(command)' sent") { await transport.sentData.count == index + 1 }
    let sent = await transport.sentData[index]
    #expect(sent.first == CommandCode.runCLICommand.rawValue)
    let line = String(decoding: sent.dropFirst(), as: UTF8.self)
    let tag = String(line.prefix(3))
    #expect(tag.count == 3 && tag.hasSuffix("|"))
    #expect(line.dropFirst(3) == command[...])
    return tag
  }

  /// The companion's reply: the command's tag echoed, then the text.
  private func reply(_ text: String, tag: String) -> Data {
    var packet = Data([ResponseCode.cliReply.rawValue])
    packet.append(contentsOf: (tag + text).utf8)
    return packet
  }

  private func makeSelfInfoPacket() -> Data {
    var payload = Data()
    payload.append(1)
    payload.append(22)
    payload.append(22)
    payload.append(Data(repeating: 0x01, count: 32))
    payload.append(Data(count: 8))
    payload.append(0)
    payload.append(0)
    payload.append(0)
    payload.append(withUnsafeBytes(of: UInt32(915_000).littleEndian) { Data($0) })
    payload.append(withUnsafeBytes(of: UInt32(125_000).littleEndian) { Data($0) })
    payload.append(7)
    payload.append(5)
    payload.append(contentsOf: "Test".utf8)
    var packet = Data([ResponseCode.selfInfo.rawValue])
    packet.append(payload)
    return packet
  }
}
