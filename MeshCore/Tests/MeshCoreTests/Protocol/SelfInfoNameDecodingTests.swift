import Foundation
@testable import MeshCore
import Testing

@Suite("SelfInfo name decoding")
struct SelfInfoNameDecodingTests {
  /// Builds a SelfInfo body in the shape `Parsers.SelfInfo.parse` consumes: the
  /// 57-byte fixed header followed by the raw name bytes.
  private func selfInfoBody(nameBytes: Data) -> Data {
    var data = Data()
    data.append(contentsOf: [1, 20, 30]) // 0..<3   advType, txPower, maxTxPower
    data.append(Data(repeating: 0xBB, count: 32)) // 3..<35  publicKey
    data.appendLittleEndian(Int32(0)) // lat
    data.appendLittleEndian(Int32(0)) // lon
    data.append(contentsOf: [0, 0, 0, 0]) // multiAcks, advLocPolicy, telemetryMode, manualAdd
    data.appendLittleEndian(UInt32(906_875)) // radioFreq
    data.appendLittleEndian(UInt32(250_000)) // radioBW
    data.append(contentsOf: [11, 8]) // radioSF, radioCR
    data.append(nameBytes)
    return data
  }

  private func parsedName(_ nameBytes: Data) throws -> String {
    guard case let .selfInfo(info) = Parsers.SelfInfo.parse(selfInfoBody(nameBytes: nameBytes)) else {
      throw SelfInfoParseFailure()
    }
    return info.name
  }

  private struct SelfInfoParseFailure: Error {}

  @Test
  func `Flag emoji cut mid-codepoint decodes to a readable prefix instead of blank`() throws {
    var name = Data("Base".utf8)
    name.append(contentsOf: [0xF0, 0x9F, 0x87]) // first three bytes of a regional indicator
    #expect(try parsedName(name) == "Base")
  }

  @Test
  func `A flag name that arrives whole decodes unchanged`() throws {
    #expect(try parsedName(Data("Team \u{1F1FA}\u{1F1F8}".utf8)) == "Team \u{1F1FA}\u{1F1F8}")
  }

  @Test
  func `Plain ASCII name still decodes`() throws {
    #expect(try parsedName(Data("MyNode".utf8)) == "MyNode")
  }

  @Test
  func `Name stops at the first null terminator`() throws {
    #expect(try parsedName(Data("MyNode".utf8) + Data([0x00, 0x41, 0x42])) == "MyNode")
  }

  @Test
  func `Empty name decodes to empty`() throws {
    #expect(try parsedName(Data()).isEmpty)
  }
}
