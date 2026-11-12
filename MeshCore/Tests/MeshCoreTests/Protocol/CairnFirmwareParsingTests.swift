import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn firmware update parsing")
struct CairnFirmwareParsingTests {
  // MARK: - Builder

  @Test
  func `commands are the code then the sub-command`() {
    #expect(PacketBuilder.cairnFirmware(.status) == Data([0xC0, 0x01]))
    #expect(PacketBuilder.cairnFirmware(.start) == Data([0xC0, 0x02]))
    #expect(PacketBuilder.cairnFirmware(.cancel) == Data([0xC0, 0x03]))
  }

  // MARK: - STATUS

  @Test
  func `STATUS reply parses every field`() throws {
    let frame = statusFrame(realm: "MeshCore L2", build: "Cairn 111", wifi: 3, ip: [10, 0, 1, 140], updater: 0, heapKB: 61)
    guard case let .cairnFirmwareStatus(status) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStatus")
      return
    }
    #expect(status.protocolVersion == 1)
    #expect(status.realm == "MeshCore L2")
    #expect(status.build == "Cairn 111")
    #expect(status.wifi == .connected)
    #expect(status.ipAddress == "10.0.1.140")
    #expect(status.updater == .off)
    #expect(status.largestFreeHeapKB == 61)
  }

  @Test
  func `STATUS without Wi-Fi has no address`() {
    let frame = statusFrame(realm: "MeshCore M9", build: "Cairn dev", wifi: 2, ip: [0, 0, 0, 0], updater: 1, heapKB: 300)
    guard case let .cairnFirmwareStatus(status) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStatus")
      return
    }
    #expect(status.wifi == .notConnected)
    #expect(status.ipAddress == nil)
    #expect(status.updater == .ready)
    #expect(status.largestFreeHeapKB == 300)
  }

  @Test
  func `STATUS ignores fields a later protocol appends`() {
    var frame = statusFrame(realm: "MeshCore TDeck", build: "Cairn 112", wifi: 3, ip: [192, 168, 1, 9], updater: 0, heapKB: 40)
    frame.append(contentsOf: [0xAA, 0xBB, 0xCC])
    guard case let .cairnFirmwareStatus(status) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStatus")
      return
    }
    #expect(status.build == "Cairn 112")
    #expect(status.largestFreeHeapKB == 40)
  }

  @Test
  func `STATUS keeps unknown Wi-Fi and updater values raw`() {
    let frame = statusFrame(realm: "MeshCore L2", build: "Cairn 111", wifi: 9, ip: [1, 2, 3, 4], updater: 7, heapKB: 1)
    guard case let .cairnFirmwareStatus(status) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStatus")
      return
    }
    #expect(status.wifi == nil)
    #expect(status.wifiRaw == 9)
    #expect(status.updater == nil)
    #expect(status.updaterRaw == 7)
  }

  @Test
  func `truncated STATUS is a parse failure`() {
    let full = statusFrame(realm: "MeshCore L2", build: "Cairn 111", wifi: 3, ip: [10, 0, 0, 2], updater: 0, heapKB: 61)
    for length in [2, 3, 5, full.count - 1] {
      guard case .parseFailure = PacketParser.parse(full.prefix(length)) else {
        Issue.record("Expected parseFailure at \(length) bytes")
        continue
      }
    }
  }

  // MARK: - START and CANCEL replies

  @Test
  func `START reply maps each status`() {
    let cases: [(UInt8, CairnFirmwareStartReply)] = [
      (0, .asking), (2, .wifiNotConnected), (3, .busy), (4, .notNow), (9, .other(9)),
    ]
    for (status, expected) in cases {
      guard case let .cairnFirmwareStartReply(reply) = PacketParser.parse(Data([0xC0, 0x02, status])) else {
        Issue.record("Expected cairnFirmwareStartReply for \(status)")
        continue
      }
      #expect(reply == expected)
    }
  }

  @Test
  func `CANCEL reply parses`() {
    guard case .cairnFirmwareCancelled = PacketParser.parse(Data([0xC0, 0x03, 0x00])) else {
      Issue.record("Expected cairnFirmwareCancelled")
      return
    }
  }

  @Test
  func `unknown sub-command is a parse failure`() {
    guard case .parseFailure = PacketParser.parse(Data([0xC0, 0x7F, 0x00])) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  // MARK: - START push

  @Test
  func `allowed push carries address and login`() {
    let frame = pushFrame(result: 0, ip: [10, 0, 1, 140], port: 80, user: "meshcore", password: "abcdefghjk23")
    guard case let .cairnFirmwareStartResult(result) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStartResult")
      return
    }
    #expect(result.outcome == .allowed)
    #expect(result.ipAddress == "10.0.1.140")
    #expect(result.port == 80)
    #expect(result.user == "meshcore")
    #expect(result.password == "abcdefghjk23")
  }

  @Test
  func `declined push has no login`() {
    let frame = pushFrame(result: 1, ip: [0, 0, 0, 0], port: 0, user: "", password: "")
    guard case let .cairnFirmwareStartResult(result) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStartResult")
      return
    }
    #expect(result.outcome == .declined)
    #expect(result.ipAddress == nil)
    #expect(result.password.isEmpty)
  }

  @Test
  func `short push still names its outcome`() {
    for (byte, outcome) in [(UInt8(2), CairnFirmwareStartResult.Outcome.failed), (3, .noAnswer), (8, .other(8))] {
      guard case let .cairnFirmwareStartResult(result) = PacketParser.parse(Data([0xC1, 0x02, byte])) else {
        Issue.record("Expected cairnFirmwareStartResult for \(byte)")
        continue
      }
      #expect(result.outcome == outcome)
    }
  }

  @Test
  func `allowed push without a password is a parse failure`() {
    let frame = pushFrame(result: 0, ip: [10, 0, 1, 140], port: 80, user: "meshcore", password: "")
    guard case .parseFailure = PacketParser.parse(frame) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  // MARK: - Frames

  private func statusFrame(realm: String, build: String, wifi: UInt8, ip: [UInt8], updater: UInt8, heapKB: UInt16) -> Data {
    var data = Data([0xC0, 0x01, 0x00, 0x01])
    data.append(string(realm))
    data.append(string(build))
    data.append(wifi)
    data.append(contentsOf: ip)
    data.append(updater)
    data.append(contentsOf: withUnsafeBytes(of: heapKB.littleEndian) { Array($0) })
    return data
  }

  private func pushFrame(result: UInt8, ip: [UInt8], port: UInt16, user: String, password: String) -> Data {
    var data = Data([0xC1, 0x02, result])
    data.append(contentsOf: ip)
    data.append(contentsOf: withUnsafeBytes(of: port.littleEndian) { Array($0) })
    data.append(string(user))
    data.append(string(password))
    return data
  }

  private func string(_ text: String) -> Data {
    let bytes = Data(text.utf8)
    return Data([UInt8(bytes.count)]) + bytes
  }
}
