import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("Data export formatters")
struct DataExportFormatterTests {
  // MARK: - CSV escaping

  @Test
  func `plain fields are not quoted`() {
    #expect(CSVTable.escape("hello") == "hello")
    #expect(CSVTable.escape("-7.25") == "-7.25")
    #expect(CSVTable.escape("") == "")
  }

  @Test
  func `fields with commas, quotes and newlines are quoted`() {
    #expect(CSVTable.escape("a,b") == "\"a,b\"")
    #expect(CSVTable.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    #expect(CSVTable.escape("line1\nline2") == "\"line1\nline2\"")
    #expect(CSVTable.escape("cr\rhere") == "\"cr\rhere\"")
  }

  @Test
  func `formula-looking fields are neutralized`() {
    #expect(CSVTable.escape("=SUM(A1)") == "'=SUM(A1)")
    #expect(CSVTable.escape("@cmd") == "'@cmd")
    #expect(CSVTable.escape("+1,2") == "\"'+1,2\"")
  }

  @Test
  func `fields starting with TAB or CR are neutralized`() {
    #expect(CSVTable.escape("\t=SUM(A1)") == "'\t=SUM(A1)")
    #expect(CSVTable.escape("\r=SUM(A1)") == "\"'\r=SUM(A1)\"")
    #expect(CSVTable.escape("\r\n=SUM(A1)") == "\"'\r\n=SUM(A1)\"")
  }

  @Test
  func `a formula trigger followed by a combining mark is still neutralized`() {
    #expect(CSVTable.escape("=\u{0301}SUM(A1)") == "'=\u{0301}SUM(A1)")
  }

  @Test
  func `a CRLF pair inside a field is quoted`() {
    #expect(CSVTable.escape("line1\r\nline2") == "\"line1\r\nline2\"")
    var table = CSVTable(headers: ["text"])
    table.append(["line1\r\nline2"])
    #expect(table.render() == "text\r\n\"line1\r\nline2\"\r\n")
  }

  @Test
  func `table renders header and rows with CRLF and pads short rows`() {
    var table = CSVTable(headers: ["a", "b", "c"])
    table.append(["1", nil])
    table.append(["x,y", "2", "3", "extra"])
    #expect(table.render() == "a,b,c\r\n1,,\r\n\"x,y\",2,3\r\n")
    #expect(table.renderData().prefix(3) == Data([0xEF, 0xBB, 0xBF]))
  }

  // MARK: - Cell formats

  @Test
  func `timestamps are ISO 8601 UTC`() {
    #expect(ExportFormat.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    #expect(ExportFormat.timestamp(epochSeconds: 1_700_000_000) == "2023-11-14T22:13:20Z")
    #expect(ExportFormat.timestamp(epochSeconds: 0) == nil)
  }

  @Test
  func `numbers are locale independent and trimmed`() {
    #expect(ExportFormat.number(47.5) == "47.5")
    #expect(ExportFormat.number(-122.0) == "-122")
    #expect(ExportFormat.number(.nan) == nil)
    #expect(ExportFormat.hex(Data([0x0A, 0xFF])) == "0aff")
  }

  // MARK: - Tables

  @Test
  func `messages CSV resolves conversation, sender and direction`() {
    let radioID = UUID()
    let contactID = UUID()
    let incoming = MessageDTO.testDirectMessage(
      radioID: radioID,
      contactID: contactID,
      text: "Hi, \"you\"",
      timestamp: 1_700_000_000,
      createdAt: Date(timeIntervalSince1970: 1_700_000_005),
      direction: .incoming,
      status: .delivered,
      pathLength: 2,
      snr: 6.5
    )
    let outgoing = MessageDTO.testChannelMessage(
      radioID: radioID,
      channelIndex: 1,
      text: "hello",
      timestamp: 1_700_000_100,
      createdAt: Date(timeIntervalSince1970: 1_700_000_100),
      direction: .outgoing,
      status: .sent
    )
    let context = DataExportFormatter.MessageContext(
      contactNames: [contactID: "Alice"],
      channelNames: [1: "#mesh"],
      ownName: "Me Node"
    )
    let rows = DataExportFormatter.messagesCSV([outgoing, incoming], context: context).rows
    #expect(rows.count == 2)
    #expect(rows[0][0] == "2023-11-14T22:13:25Z")
    #expect(rows[0][2] == "Alice")
    #expect(rows[0][3] == "direct")
    #expect(rows[0][4] == "Alice")
    #expect(rows[0][5] == "incoming")
    #expect(rows[0][6] == "Hi, \"you\"")
    #expect(rows[0][7] == "2")
    #expect(rows[0][8] == "6.5")
    #expect(rows[0][9] == "received")
    #expect(rows[1][2] == "#mesh")
    #expect(rows[1][3] == "channel")
    #expect(rows[1][4] == "Me Node")
    #expect(rows[1][9] == "sent")
    #expect(rows[1][7] == "")
  }

  @Test
  func `messages CSV leaves hops empty for direct-routed messages`() {
    let direct = MessageDTO.testDirectMessage(
      radioID: UUID(),
      contactID: UUID(),
      text: "direct",
      direction: .incoming,
      pathLength: 0xFF
    )
    #expect(direct.isDirectRouted)
    let table = DataExportFormatter.messagesCSV([direct], context: DataExportFormatter.MessageContext())
    let hops = table.headers.firstIndex(of: "hops")!
    #expect(table.rows[0][hops] == "")
  }

  @Test
  func `messages CSV labels a channel with an empty or missing name by its slot`() {
    let radioID = UUID()
    let unnamed = MessageDTO.testChannelMessage(
      radioID: radioID,
      channelIndex: 3,
      text: "a",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      direction: .incoming
    )
    let unknown = MessageDTO.testChannelMessage(
      radioID: radioID,
      channelIndex: 5,
      text: "b",
      createdAt: Date(timeIntervalSince1970: 1_700_000_001),
      direction: .incoming
    )
    let context = DataExportFormatter.MessageContext(channelNames: [3: ""])
    let rows = DataExportFormatter.messagesCSV([unnamed, unknown], context: context).rows
    #expect(rows[0][2] == "Channel 3")
    #expect(rows[1][2] == "Channel 5")
  }

  @Test
  func `contacts CSV includes hex key, location only when known, and last heard`() {
    let key = Data((0..<32).map { UInt8($0) })
    let located = ContactDTO.testContact(
      publicKey: key,
      name: "Repeater, North",
      typeRawValue: ContactType.repeater.rawValue,
      latitude: 47.6,
      longitude: -122.3,
      lastHeardTimestamp: 1_700_000_000
    )
    let unlocated = ContactDTO.testContact(name: "Bob")
    let table = DataExportFormatter.contactsCSV([located, unlocated])
    #expect(table.rows[0][0] == "Bob")
    #expect(table.rows[0][4] == "")
    #expect(table.rows[1][0] == "Repeater, North")
    #expect(table.rows[1][2] == "repeater")
    #expect(table.rows[1][3] == ExportFormat.hex(key))
    #expect(table.rows[1][4] == "47.6")
    #expect(table.rows[1][5] == "-122.3")
    #expect(table.rows[1][6] == "2023-11-14T22:13:20Z")
    #expect(table.rows[1][8] == "flood")
    #expect(table.render().contains("\"Repeater, North\""))
  }

  @Test
  func `node status CSV names nodes and flattens telemetry`() {
    let key = Data(repeating: 0xDD, count: 32)
    let snapshot = NodeStatusSnapshotDTO.testSnapshot(
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      nodePublicKey: key,
      batteryMillivolts: 3950,
      telemetryEntries: [TelemetrySnapshotEntry(channel: 1, type: "temperature", value: 21.5)]
    )
    let table = DataExportFormatter.nodeStatusCSV([snapshot], nodeNames: [key: "Hilltop"])
    let row = table.rows[0]
    #expect(row[0] == "2023-11-14T22:13:20Z")
    #expect(row[1] == "Hilltop")
    #expect(row[3] == "3950")
    #expect(row[table.headers.firstIndex(of: "telemetry")!] == "ch1 temperature=21.5")
  }

  // MARK: - GPX

  @Test
  func `GPX escapes XML and orders waypoint children per schema`() {
    let gpx = GPXDocument.render(waypoints: [
      GPXWaypoint(
        latitude: 47.1234567,
        longitude: -122.5,
        name: "A&B <\"Ridge\">",
        description: "repeater 'x'",
        time: Date(timeIntervalSince1970: 0),
        type: "repeater"
      ),
    ])
    #expect(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
    #expect(gpx.contains("<gpx version=\"1.1\""))
    #expect(gpx.contains("<wpt lat=\"47.1234567\" lon=\"-122.5\">"))
    #expect(gpx.contains("<name>A&amp;B &lt;&quot;Ridge&quot;&gt;</name>"))
    #expect(gpx.contains("<desc>repeater &apos;x&apos;</desc>"))
    let time = gpx.range(of: "<time>1970-01-01T00:00:00Z</time>")!.lowerBound
    let name = gpx.range(of: "<name>")!.lowerBound
    #expect(time < name)
    #expect(gpx.hasSuffix("</gpx>\n"))
  }

  @Test
  func `GPX escaping drops control characters XML cannot carry`() {
    #expect(GPXDocument.escape("a\u{01}b\tc") == "ab\tc")
  }

  @Test
  func `waypoints include located contacts and deduplicate discovered nodes`() {
    let key = Data(repeating: 0x01, count: 32)
    let contact = ContactDTO.testContact(publicKey: key, name: "Zed", latitude: 1, longitude: 2)
    let hidden = ContactDTO.testContact(publicKey: Data(repeating: 0x02, count: 32), name: "NoLoc")
    let waypoints = DataExportFormatter.waypoints(contacts: [contact, hidden])
    #expect(waypoints.count == 1)
    #expect(waypoints[0].name == "Zed")
    #expect(waypoints[0].type == "companion")
  }

  @Test
  func `waypoints skip discovered nodes whose coordinates are out of range`() {
    let radioID = UUID()
    func node(_ keyByte: UInt8, _ name: String, _ latitude: Double, _ longitude: Double) -> DiscoveredNodeDTO {
      DiscoveredNodeDTO(
        id: UUID(),
        radioID: radioID,
        publicKey: Data(repeating: keyByte, count: 32),
        name: name,
        typeRawValue: ContactType.repeater.rawValue,
        lastHeard: Date(timeIntervalSince1970: 1_700_000_000),
        lastAdvertTimestamp: 1_700_000_000,
        latitude: latitude,
        longitude: longitude,
        outPathLength: 0xFF,
        outPath: Data(),
        inboundHopCount: nil,
        inboundHopAdvertTimestamp: nil
      )
    }
    let waypoints = DataExportFormatter.waypoints(contacts: [], discoveredNodes: [
      node(1, "Valid", 47.6, -122.3),
      node(2, "LatitudeHigh", 90.5, 10),
      node(3, "LongitudeLow", 10, -180.5),
      node(4, "NotANumber", .nan, 10),
      node(5, "Infinite", 10, .infinity),
      node(6, "Edge", -90, 180)
    ])
    #expect(waypoints.map(\.name) == ["Edge", "Valid"])
  }
}
