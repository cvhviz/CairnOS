import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("DiscoveredNodesFile")
struct DiscoveredNodesFileTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let heard = Date(timeIntervalSince1970: 1_700_000_500)

  private func key(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: 32)
  }

  private func hex(_ byte: UInt8) -> String {
    String(repeating: String(format: "%02x", byte), count: 32)
  }

  /// A valid entry; tests replace or remove one field to make it invalid.
  private func entry(_ keyByte: UInt8 = 0xA1, changing changes: [String: Any?] = [:]) -> [String: Any] {
    var entry: [String: Any] = [
      "publicKey": hex(keyByte),
      "name": "Hilltop",
      "type": "repeater",
      "latitude": 45.4215,
      "longitude": -75.6972,
      "lastAdvertTimestamp": 1_700_000_000,
      "lastHeard": "2023-11-14T22:21:40Z"
    ]
    for (field, value) in changes {
      entry[field] = value
    }
    return entry
  }

  private func file(
    format: Any? = DiscoveredNodesFile.formatIdentifier,
    version: Any? = DiscoveredNodesFile.currentVersion,
    exportedAt: Any? = "2026-09-27T14:03:05Z",
    nodes: Any? = [[String: Any]]()
  ) throws -> Data {
    var root: [String: Any] = [:]
    root["format"] = format
    root["version"] = version
    root["exportedAt"] = exportedAt
    root["nodes"] = nodes
    return try JSONSerialization.data(withJSONObject: root)
  }

  private func parse(_ entries: [Any]) throws -> DiscoveredNodesFile.Contents {
    try DiscoveredNodesFile.parse(file(nodes: entries), now: now)
  }

  // MARK: - Valid Files

  @Test
  func `reads a valid file`() throws {
    let contents = try parse([entry()])

    #expect(contents.nodes == [
      DiscoveredNodesFile.Node(
        publicKey: key(0xA1),
        name: "Hilltop",
        type: .repeater,
        latitude: 45.4215,
        longitude: -75.6972,
        lastAdvertTimestamp: 1_700_000_000,
        lastHeard: Date(timeIntervalSince1970: 1_700_000_500)
      )
    ])
    #expect(contents.rejected.isEmpty)
    #expect(contents.duplicateCount == 0)
    #expect(contents.entryCount == 1)
    #expect(contents.exportedAt == Date(timeIntervalSince1970: 1_790_517_785))
  }

  @Test
  func `reads a file with no nodes`() throws {
    let contents = try parse([])

    #expect(contents.nodes.isEmpty)
    #expect(contents.entryCount == 0)
  }

  @Test(arguments: ["companion", "repeater", "room"])
  func `reads every node type`(name: String) throws {
    let expected: [String: ContactType] = ["companion": .chat, "repeater": .repeater, "room": .room]

    let contents = try parse([entry(changing: ["type": name])])

    #expect(contents.nodes.map(\.type) == [expected[name]])
  }

  @Test
  func `a node without coordinates has no location`() throws {
    var noLocation = entry()
    noLocation["latitude"] = nil
    noLocation["longitude"] = nil
    let explicitNull = entry(0xB2, changing: ["latitude": NSNull(), "longitude": NSNull()])

    let contents = try parse([noLocation, explicitNull])

    #expect(contents.nodes.count == 2)
    #expect(contents.nodes.allSatisfy { $0.latitude == nil && $0.longitude == nil })
  }

  @Test
  func `accepts coordinates on the edge of the range`() throws {
    let contents = try parse([
      entry(0xA1, changing: ["latitude": 90, "longitude": 180]),
      entry(0xB2, changing: ["latitude": -90, "longitude": -180])
    ])

    #expect(contents.nodes.count == 2)
    #expect(contents.rejected.isEmpty)
  }

  @Test
  func `accepts upper-case keys, an empty name, emoji, and fractional seconds`() throws {
    let contents = try parse([
      entry(changing: ["publicKey": hex(0xAB).uppercased()]),
      entry(0xB2, changing: ["name": ""]),
      entry(0xC3, changing: ["name": "👨‍👩‍👧 Base"]),
      entry(0xD4, changing: ["lastHeard": "2023-11-14T22:21:40.250Z"])
    ])

    #expect(contents.rejected.isEmpty)
    #expect(contents.nodes.map(\.publicKey) == [key(0xAB), key(0xB2), key(0xC3), key(0xD4)])
    #expect(contents.nodes[2].name == "👨‍👩‍👧 Base")
  }

  @Test
  func `accepts a name that fills the firmware field`() throws {
    let name = String(repeating: "n", count: ProtocolLimits.maxUsableNameBytes)

    let contents = try parse([entry(changing: ["name": name])])

    #expect(contents.nodes.map(\.name) == [name])
  }

  @Test
  func `ignores fields it does not know, such as a radio identifier`() throws {
    var withExtras = entry()
    withExtras["radioID"] = UUID().uuidString
    withExtras["outPath"] = "aabbcc"
    var root = try #require(JSONSerialization.jsonObject(with: file(nodes: [withExtras])) as? [String: Any])
    root["radioID"] = UUID().uuidString

    let contents = try DiscoveredNodesFile.parse(JSONSerialization.data(withJSONObject: root), now: now)

    #expect(contents.nodes.count == 1)
    #expect(contents.rejected.isEmpty)
  }

  @Test
  func `a last heard date in the future is capped at now`() throws {
    let contents = try parse([entry(changing: ["lastHeard": "2099-01-01T00:00:00Z"])])

    #expect(contents.nodes.map(\.lastHeard) == [now])
  }

  @Test
  func `an unreadable export date does not stop the import`() throws {
    let data = try file(exportedAt: "yesterday", nodes: [entry()])

    let contents = try DiscoveredNodesFile.parse(data, now: now)

    #expect(contents.exportedAt == nil)
    #expect(contents.nodes.count == 1)
  }

  // MARK: - Invalid Entries

  @Test(arguments: [
    "",
    "a1",
    String(repeating: "a1", count: 31),
    String(repeating: "a1", count: 33),
    String(repeating: "zz", count: 32),
    String(repeating: "a1", count: 31) + " a1",
    String(repeating: "a1 ", count: 32)
  ])
  func `rejects a public key that is not 32 bytes of hex`(publicKey: String) throws {
    let contents = try parse([entry(changing: ["publicKey": publicKey])])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected == [DiscoveredNodesFile.Rejection(index: 0, field: .publicKey)])
  }

  @Test
  func `rejects a missing or mistyped public key`() throws {
    var missing = entry()
    missing["publicKey"] = nil

    let contents = try parse([missing, entry(changing: ["publicKey": 42])])

    #expect(contents.rejected.map(\.field) == [.publicKey, .publicKey])
  }

  @Test(arguments: [
    String(repeating: "n", count: ProtocolLimits.maxUsableNameBytes + 1),
    String(repeating: "é", count: 16),
    "Line\nbreak",
    "Tab\there",
    "Bell\u{07}",
    "Nul\u{00}byte",
    "Escape\u{1B}[31m",
    "Delete\u{7F}",
    "C1\u{85}control"
  ])
  func `rejects a name that is too long or holds a control character`(name: String) throws {
    let contents = try parse([entry(changing: ["name": name])])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected == [DiscoveredNodesFile.Rejection(index: 0, field: .name)])
  }

  @Test
  func `rejects a missing or mistyped name`() throws {
    var missing = entry()
    missing["name"] = nil

    let contents = try parse([missing, entry(changing: ["name": 7]), entry(changing: ["name": NSNull()])])

    #expect(contents.rejected.map(\.field) == [.name, .name, .name])
  }

  @Test(arguments: ["sensor", "Repeater", "chat", "", "2"])
  func `rejects an unknown type`(type: String) throws {
    let contents = try parse([entry(changing: ["type": type])])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected == [DiscoveredNodesFile.Rejection(index: 0, field: .type)])
  }

  @Test
  func `rejects a missing or numeric type`() throws {
    var missing = entry()
    missing["type"] = nil

    let contents = try parse([missing, entry(changing: ["type": 2])])

    #expect(contents.rejected.map(\.field) == [.type, .type])
  }

  @Test(arguments: [
    (90.0001, 0.0),
    (-90.0001, 0.0),
    (0.0, 180.0001),
    (0.0, -180.0001),
    (1000.0, 1000.0)
  ])
  func `rejects coordinates out of range`(latitude: Double, longitude: Double) throws {
    let contents = try parse([entry(changing: ["latitude": latitude, "longitude": longitude])])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected == [DiscoveredNodesFile.Rejection(index: 0, field: .coordinates)])
  }

  @Test
  func `rejects half a coordinate pair and coordinates that are not numbers`() throws {
    var latitudeOnly = entry()
    latitudeOnly["longitude"] = nil
    var longitudeOnly = entry()
    longitudeOnly["latitude"] = nil

    let contents = try parse([
      latitudeOnly,
      longitudeOnly,
      entry(changing: ["latitude": "45.4"]),
      entry(changing: ["longitude": true])
    ])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected.map(\.field) == [.coordinates, .coordinates, .coordinates, .coordinates])
  }

  @Test
  func `rejects an advert timestamp that is not an unsigned 32-bit integer`() throws {
    var missing = entry()
    missing["lastAdvertTimestamp"] = nil

    let contents = try parse([
      missing,
      entry(changing: ["lastAdvertTimestamp": -1]),
      entry(changing: ["lastAdvertTimestamp": Int(UInt32.max) + 1]),
      entry(changing: ["lastAdvertTimestamp": 1_700_000_000.5]),
      entry(changing: ["lastAdvertTimestamp": "1700000000"]),
      entry(changing: ["lastAdvertTimestamp": true])
    ])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected.map(\.field) == Array(repeating: .lastAdvertTimestamp, count: 6))
  }

  @Test
  func `accepts the largest advert timestamp`() throws {
    let contents = try parse([entry(changing: ["lastAdvertTimestamp": Int(UInt32.max)])])

    #expect(contents.nodes.map(\.lastAdvertTimestamp) == [UInt32.max])
  }

  @Test
  func `rejects a last heard date that is not ISO 8601`() throws {
    var missing = entry()
    missing["lastHeard"] = nil

    let contents = try parse([
      missing,
      entry(changing: ["lastHeard": "14/11/2023"]),
      entry(changing: ["lastHeard": ""]),
      entry(changing: ["lastHeard": 1_700_000_500])
    ])

    #expect(contents.nodes.isEmpty)
    #expect(contents.rejected.map(\.field) == [.lastHeard, .lastHeard, .lastHeard, .lastHeard])
  }

  @Test
  func `rejects an entry that is not an object`() throws {
    let contents = try parse([42, "node", [1, 2], NSNull(), entry()])

    #expect(contents.nodes.count == 1)
    #expect(contents.rejected == [
      DiscoveredNodesFile.Rejection(index: 0, field: .entry),
      DiscoveredNodesFile.Rejection(index: 1, field: .entry),
      DiscoveredNodesFile.Rejection(index: 2, field: .entry),
      DiscoveredNodesFile.Rejection(index: 3, field: .entry)
    ])
  }

  @Test
  func `an invalid entry does not take valid ones with it`() throws {
    let contents = try parse([
      entry(0xA1),
      entry(0xB2, changing: ["type": "sensor"]),
      entry(0xC3)
    ])

    #expect(contents.nodes.map(\.publicKey) == [key(0xA1), key(0xC3)])
    #expect(contents.rejected == [DiscoveredNodesFile.Rejection(index: 1, field: .type)])
    #expect(contents.entryCount == 3)
  }

  // MARK: - Duplicate Keys

  @Test
  func `of two entries with one key the newer advert is kept`() throws {
    let contents = try parse([
      entry(0xA1, changing: ["name": "Old", "lastAdvertTimestamp": 100]),
      entry(0xB2),
      entry(0xA1, changing: ["name": "New", "lastAdvertTimestamp": 300]),
      entry(0xA1, changing: ["name": "Middle", "lastAdvertTimestamp": 200])
    ])

    #expect(contents.nodes.map(\.name) == ["New", "Hilltop"])
    #expect(contents.nodes.map(\.publicKey) == [key(0xA1), key(0xB2)])
    #expect(contents.duplicateCount == 2)
    #expect(contents.entryCount == 4)
  }

  @Test
  func `of two entries with one key and one advert the first is kept`() throws {
    let contents = try parse([
      entry(0xA1, changing: ["name": "First"]),
      entry(0xA1, changing: ["name": "Second"])
    ])

    #expect(contents.nodes.map(\.name) == ["First"])
    #expect(contents.duplicateCount == 1)
  }

  @Test
  func `keys that differ only in case are one key`() throws {
    let contents = try parse([
      entry(changing: ["publicKey": hex(0xAB)]),
      entry(changing: ["publicKey": hex(0xAB).uppercased()])
    ])

    #expect(contents.nodes.count == 1)
    #expect(contents.duplicateCount == 1)
  }

  // MARK: - Invalid Files

  @Test
  func `refuses a file over the size limit`() {
    let data = Data(repeating: UInt8(ascii: " "), count: DiscoveredNodesFile.maxFileBytes + 1)

    #expect(throws: DiscoveredNodesFile.FileError.tooLarge(bytes: DiscoveredNodesFile.maxFileBytes + 1)) {
      try DiscoveredNodesFile.parse(data, now: now)
    }
  }

  @Test
  func `reads a file exactly at the size limit`() throws {
    var data = try file(nodes: [entry()])
    data.append(Data(repeating: UInt8(ascii: " "), count: DiscoveredNodesFile.maxFileBytes - data.count))

    let contents = try DiscoveredNodesFile.parse(data, now: now)

    #expect(contents.nodes.count == 1)
  }

  @Test(arguments: [
    "",
    "not json",
    "[]",
    "42",
    "{\"format\":\"cairn.discovered-nodes\",\"version\":1",
    "{\"format\":\"cairn.discovered-nodes\",\"version\":1}",
    "{\"format\":\"cairn.discovered-nodes\",\"version\":1,\"nodes\":{}}",
    "{\"format\":\"cairn.discovered-nodes\",\"version\":1,\"nodes\":\"none\"}"
  ])
  func `refuses a file that is not a discovered-nodes document`(text: String) {
    #expect(throws: DiscoveredNodesFile.FileError.unreadable) {
      try DiscoveredNodesFile.parse(Data(text.utf8), now: now)
    }
  }

  @Test
  func `refuses a file of another format`() throws {
    let missing = try file(format: nil, nodes: [entry()])
    let other = try file(format: "cairn.backup", nodes: [entry()])
    let mistyped = try file(format: 1, nodes: [entry()])

    for data in [missing, other, mistyped] {
      #expect(throws: DiscoveredNodesFile.FileError.wrongFormat) {
        try DiscoveredNodesFile.parse(data, now: now)
      }
    }
  }

  @Test(arguments: [0, 2, -1, 99])
  func `refuses a version it does not know`(version: Int) throws {
    let data = try file(version: version, nodes: [entry()])

    #expect(throws: DiscoveredNodesFile.FileError.unsupportedVersion(version)) {
      try DiscoveredNodesFile.parse(data, now: now)
    }
  }

  @Test
  func `refuses a missing or mistyped version`() throws {
    let missing = try file(version: nil, nodes: [entry()])
    let mistyped = try file(version: "1", nodes: [entry()])

    for data in [missing, mistyped] {
      #expect(throws: DiscoveredNodesFile.FileError.unsupportedVersion(nil)) {
        try DiscoveredNodesFile.parse(data, now: now)
      }
    }
  }

  // MARK: - Reading From Disk

  @Test
  func `reads a file from disk`() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try file(nodes: [entry()])
    try data.write(to: url)

    #expect(try DiscoveredNodesFile.read(contentsOf: url) == data)
  }

  @Test
  func `refuses an oversized file on disk without parsing it`() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let size = DiscoveredNodesFile.maxFileBytes + 1
    try Data(repeating: UInt8(ascii: " "), count: size).write(to: url)

    #expect(throws: DiscoveredNodesFile.FileError.tooLarge(bytes: size)) {
      try DiscoveredNodesFile.read(contentsOf: url)
    }
  }

  @Test
  func `a file that is not there cannot be read`() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")

    #expect(throws: (any Error).self) {
      try DiscoveredNodesFile.read(contentsOf: url)
    }
  }

  // MARK: - Export

  private func discoveredNode(
    _ keyByte: UInt8,
    name: String = "Hilltop",
    typeRawValue: UInt8 = ContactType.repeater.rawValue,
    latitude: Double = 45.4215,
    longitude: Double = -75.6972,
    publicKey: Data? = nil
  ) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: publicKey ?? key(keyByte),
      name: name,
      typeRawValue: typeRawValue,
      lastHeard: heard,
      lastAdvertTimestamp: 1_700_000_000,
      latitude: latitude,
      longitude: longitude,
      outPathLength: 2,
      outPath: Data([0xAA, 0xBB]),
      inboundHopCount: 3,
      inboundHopAdvertTimestamp: 1_700_000_000
    )
  }

  @Test
  func `an export reads back as the same nodes`() throws {
    let nodes = DiscoveredNodesFile.nodes(from: [
      discoveredNode(0xA1, name: "Alpha", typeRawValue: ContactType.chat.rawValue),
      discoveredNode(0xB2, name: "Bravo"),
      discoveredNode(0xC3, name: "Charlie 👨‍👩‍👧", typeRawValue: ContactType.room.rawValue, latitude: 0, longitude: 0)
    ])

    let data = try DiscoveredNodesFile.encode(nodes, exportedAt: Date(timeIntervalSince1970: 1_790_000_000))
    let contents = try DiscoveredNodesFile.parse(data, now: now)

    #expect(contents.nodes == nodes)
    #expect(contents.rejected.isEmpty)
    #expect(contents.exportedAt == Date(timeIntervalSince1970: 1_790_000_000))
  }

  @Test
  func `an export carries the format, the version, and only advertised fields`() throws {
    let data = try DiscoveredNodesFile.encode(
      DiscoveredNodesFile.nodes(from: [discoveredNode(0xA1)]),
      exportedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(root.keys) == ["format", "version", "exportedAt", "nodes"])
    #expect(root["format"] as? String == "cairn.discovered-nodes")
    #expect(root["version"] as? Int == 1)
    #expect(root["exportedAt"] as? String == "2026-09-21T14:13:20Z")

    let entries = try #require(root["nodes"] as? [[String: Any]])
    let node = try #require(entries.first)
    #expect(Set(node.keys) == [
      "publicKey", "name", "type", "latitude", "longitude", "lastAdvertTimestamp", "lastHeard"
    ])
    #expect(node["publicKey"] as? String == hex(0xA1))
    #expect(node["type"] as? String == "repeater")
    #expect(node["lastAdvertTimestamp"] as? Int == 1_700_000_000)
    #expect(node["lastHeard"] as? String == "2023-11-14T22:21:40Z")
  }

  @Test
  func `an export leaves out a location the node does not have or that is out of range`() throws {
    let nodes = DiscoveredNodesFile.nodes(from: [
      discoveredNode(0xA1, latitude: 0, longitude: 0),
      discoveredNode(0xB2, latitude: 123, longitude: 45),
      discoveredNode(0xC3, latitude: 45, longitude: 181)
    ])

    #expect(nodes.count == 3)
    #expect(nodes.allSatisfy { $0.latitude == nil && $0.longitude == nil })

    let root = try #require(
      JSONSerialization.jsonObject(with: DiscoveredNodesFile.encode(nodes)) as? [String: Any]
    )
    let entries = try #require(root["nodes"] as? [[String: Any]])
    #expect(entries.allSatisfy { $0["latitude"] == nil && $0["longitude"] == nil })
  }

  @Test
  func `an export cleans a name so that it imports`() throws {
    let nodes = DiscoveredNodesFile.nodes(from: [
      discoveredNode(0xA1, name: "Two\nLines\u{07}"),
      discoveredNode(0xB2, name: String(repeating: "é", count: 20))
    ])

    #expect(nodes.map(\.name) == ["TwoLines", String(repeating: "é", count: 15)])
    let contents = try DiscoveredNodesFile.parse(DiscoveredNodesFile.encode(nodes), now: now)
    #expect(contents.rejected.isEmpty)
    #expect(contents.nodes.count == 2)
  }

  @Test
  func `an export leaves out rows it cannot carry`() {
    let nodes = DiscoveredNodesFile.nodes(from: [
      discoveredNode(0xA1),
      discoveredNode(0xB2, publicKey: Data(repeating: 0xB2, count: 6)),
      discoveredNode(0xC3, typeRawValue: 9)
    ])

    #expect(nodes.map(\.publicKey) == [key(0xA1)])
  }

  @Test
  func `an export sorts nodes by name, then key`() throws {
    let nodes = DiscoveredNodesFile.nodes(from: [
      discoveredNode(0xC3, name: "Node 10"),
      discoveredNode(0xB2, name: "Node 2"),
      discoveredNode(0xA1, name: "Node 2")
    ])

    let contents = try DiscoveredNodesFile.parse(DiscoveredNodesFile.encode(nodes), now: now)

    #expect(contents.nodes.map(\.publicKey) == [key(0xA1), key(0xB2), key(0xC3)])
  }
}
