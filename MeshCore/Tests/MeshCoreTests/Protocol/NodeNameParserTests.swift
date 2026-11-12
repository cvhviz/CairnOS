import Foundation
@testable import MeshCore
import Testing

@Suite("NodeNameParser")
struct NodeNameParserTests {
  /// Reply layout: 4-byte node clock, then the text.
  private func response(_ text: String, trailing: [UInt8] = []) -> Data {
    Data([0x10, 0x20, 0x30, 0x40]) + Data(text.utf8) + Data(trailing)
  }

  @Test
  func `name and owner are split on the first newline`() throws {
    let info = try NodeNameParser.parse(response("Twin Peaks\nKJ6ABC, call 555-0100"))

    #expect(info == NodeOwnerInfo(nodeName: "Twin Peaks", ownerInfo: "KJ6ABC, call 555-0100"))
  }

  @Test
  func `line breaks in owner text become spaces`() throws {
    let info = try NodeNameParser.parse(response("Ridge\nline one\nline two"))

    #expect(info.nodeName == "Ridge")
    #expect(info.ownerInfo == "line one line two")
  }

  @Test
  func `name without owner`() throws {
    let info = try NodeNameParser.parse(response("Summit"))

    #expect(info == NodeOwnerInfo(nodeName: "Summit", ownerInfo: ""))
  }

  @Test
  func `text stops at the first NUL`() throws {
    let info = try NodeNameParser.parse(response("Summit\nowner", trailing: [0x00, 0x41, 0x42]))

    #expect(info == NodeOwnerInfo(nodeName: "Summit", ownerInfo: "owner"))
  }

  @Test
  func `non-ASCII names survive`() throws {
    let info = try NodeNameParser.parse(response("Zürich Üetliberg 🗼\n"))

    #expect(info.nodeName == "Zürich Üetliberg 🗼")
  }

  @Test
  func `invalid UTF-8 is replaced, not rejected`() throws {
    let data = Data([0, 0, 0, 0]) + Data("Hill".utf8) + Data([0xFF]) + Data("top\n".utf8)

    let info = try NodeNameParser.parse(data)

    #expect(info.nodeName == "Hill\u{FFFD}top")
  }

  @Test
  func `overlong name is cut at a character boundary`() throws {
    let info = try NodeNameParser.parse(response(String(repeating: "é", count: 40)))

    #expect(info.nodeName == String(repeating: "é", count: 15))
    #expect(info.nodeName.utf8.count <= NodeNameParser.maxNameBytes)
  }

  @Test(arguments: [Data(), Data([1, 2, 3]), Data([1, 2, 3, 4])])
  func `too short throws`(data: Data) {
    #expect(throws: MeshCoreError.self) {
      try NodeNameParser.parse(data)
    }
  }

  @Test(arguments: ["", "\nowner only", "   \nowner", "\u{01}\u{02}\n"])
  func `missing name throws`(text: String) {
    #expect(throws: MeshCoreError.self) {
      try NodeNameParser.parse(response(text))
    }
  }

  @Test
  func `parses from a slice with a non-zero start index`() throws {
    let padded = Data([0xEE, 0xEE]) + response("Offset\nok")

    let info = try NodeNameParser.parse(padded.dropFirst(2))

    #expect(info == NodeOwnerInfo(nodeName: "Offset", ownerInfo: "ok"))
  }
}

@Suite("PacketBuilder.sendAnonReq owner request")
struct SendAnonOwnerReqTests {
  @Test
  func `zero-hop owner request wire format`() {
    let pubkey = Data((0..<32).map { UInt8($0) })

    let packet = PacketBuilder.sendAnonReq(to: pubkey, type: .owner, pathLength: 0, path: Data())

    #expect(packet.count == 35)
    #expect(packet[0] == 0x39, "Command code")
    #expect(Data(packet[1..<33]) == pubkey, "Destination key")
    #expect(packet[33] == 0x02, "ANON_REQ_TYPE_OWNER")
    #expect(packet[34] == 0x00, "Zero-hop path length")
  }
}

@Suite("Temporary contact detection")
struct TemporaryContactTests {
  private func contact(typeRawValue: UInt8, name: String) -> MeshContact {
    MeshContact(
      id: "k",
      publicKey: Data(repeating: 0x01, count: 32),
      type: ContactType(rawValue: typeRawValue) ?? .chat,
      typeRawValue: typeRawValue,
      flags: [],
      outPathLength: 0,
      outPath: Data(),
      advertisedName: name,
      lastAdvertisement: Date(timeIntervalSince1970: 0),
      latitude: 0,
      longitude: 0,
      lastModified: Date(timeIntervalSince1970: 0)
    )
  }

  @Test
  func `type 0 with no name is a placeholder`() {
    #expect(contact(typeRawValue: 0, name: "").isTemporaryPlaceholder)
  }

  @Test(arguments: [(UInt8(2), ""), (UInt8(0), "Named"), (UInt8(1), "Alice")])
  func `real contacts are never treated as placeholders`(typeRawValue: UInt8, name: String) {
    #expect(!contact(typeRawValue: typeRawValue, name: name).isTemporaryPlaceholder)
  }
}
