import Foundation
@testable import MeshCore
import Testing

/// `CMD_RUN_CLI_COMMAND` (0x42) and its `RESP_CODE_CLI_REPLY` (0x1D), MeshCore 1.18, firmware v14+.
@Suite("Run CLI command")
struct RunCLICommandTests {
  @Test
  func `the command is the code then the command line text`() {
    let packet = PacketBuilder.runCLICommand("get radio.rxgain")
    #expect(packet.first == 0x42)
    #expect(packet.dropFirst() == Data("get radio.rxgain".utf8))
  }

  @Test
  func `a reply parses to its text`() {
    var frame = Data([0x1D])
    frame.append(contentsOf: "> on".utf8)
    guard case let .cliReply(text) = PacketParser.parse(frame) else {
      Issue.record("Expected .cliReply")
      return
    }
    #expect(text == "> on")
  }

  @Test
  func `an empty reply parses to empty text`() {
    guard case let .cliReply(text) = PacketParser.parse(Data([0x1D])) else {
      Issue.record("Expected .cliReply")
      return
    }
    #expect(text.isEmpty)
  }
}
