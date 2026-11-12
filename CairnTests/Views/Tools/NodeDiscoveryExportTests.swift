import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import Testing

/// The nodes CSV: one row per listed node, with its key, name, kind, signal both ways, where and
/// when it was heard, and whether it answered the scan.
@Suite("Scan nodes CSV export")
struct NodeDiscoveryExportTests {
  private let heardAt = Date(timeIntervalSince1970: 1_790_000_000)

  private func result(
    byte: UInt8,
    name: String,
    isNamed: Bool = true,
    snr: Double,
    uplink: Double? = nil,
    heard: Bool,
    answered: Bool,
    isEarlier: Bool = false
  ) -> NodeDiscoveryResult {
    NodeDiscoveryResult(
      name: name,
      isNamed: isNamed,
      publicKey: Data(repeating: byte, count: 32),
      nodeType: ContactType.repeater.rawValue,
      snr: snr,
      rssi: -88,
      scanFilter: .repeaters,
      receivedAt: heardAt,
      heardFrom: heard ? NodeDiscoveryHeardFrom(
        fix: NodeDiscoveryFix(latitude: 37.5, longitude: -122.25, horizontalAccuracy: 12, timestamp: heardAt),
        snr: snr
      ) : nil,
      coordinate: CLLocationCoordinate2D(latitude: 37.6, longitude: -122.3),
      sources: answered ? [.replyToUs, .advert] : [.relay],
      uplinkSNR: uplink,
      isEarlier: isEarlier
    )
  }

  private func column(_ name: String) throws -> Int {
    try #require(NodeDiscoveryExport.headers.firstIndex(of: name))
  }

  @Test
  func `each node is a row with its key, signal both ways and where it was heard`() throws {
    let alpha = result(byte: 0xA1, name: "Alpha", snr: 7.25, uplink: 3.5, heard: true, answered: true)
    let relay = result(byte: 0xB2, name: "Unknown (B2B2B2B2)", isNamed: false, snr: -2, heard: false, answered: false, isEarlier: true)
    let entries = NodeDiscoveryEntries.make(
      results: [alpha, relay],
      contacts: [Data(repeating: 0xA1, count: 32): TrafficClaremontFixtures.contact(Data(repeating: 0xA1, count: 32), name: "Alpha", type: ContactType.repeater.rawValue)],
      discovered: [:]
    )
    let table = NodeDiscoveryExport.csvTable(for: entries)
    #expect(table.headers == NodeDiscoveryExport.headers)
    #expect(table.rows.count == 2)

    let first = table.rows[0]
    #expect(first[try column("key_hex")] == String(repeating: "a1", count: 32))
    #expect(first[try column("name")] == "Alpha")
    #expect(first[try column("type")] == "repeater")
    #expect(first[try column("is_contact")] == "true")
    #expect(first[try column("snr_you_hear_db")] == "7.25")
    #expect(first[try column("snr_they_hear_db")] == "3.5")
    #expect(first[try column("rssi_dbm")] == "-88")
    #expect(first[try column("heard_at_utc")] == ExportFormat.timestamp(heardAt))
    #expect(first[try column("heard_at_utc")].hasSuffix("Z"), "ISO 8601 in UTC")
    #expect(first[try column("heard_lat")] == "37.5")
    #expect(first[try column("heard_lon")] == "-122.25")
    #expect(first[try column("heard_accuracy_m")] == "12")
    #expect(first[try column("answered_scan")] == "true")
    #expect(first[try column("sources")] == "advert|replyToUs")
    #expect(first[try column("node_lat")] == "37.6")
    #expect(first[try column("earlier")] == "false")
    #expect(Double(first[try column("distance_m")]) ?? 0 > 10000, "measured from where it was heard to where it is")

    let second = table.rows[1]
    #expect(second[try column("name")] == "", "a placeholder name is not the node's name")
    #expect(second[try column("is_contact")] == "false")
    #expect(second[try column("snr_they_hear_db")] == "")
    #expect(second[try column("heard_lat")] == "", "heard without a fix: no position")
    #expect(second[try column("answered_scan")] == "false")
    #expect(second[try column("distance_m")] == "")
    #expect(second[try column("earlier")] == "true")
  }

  @Test
  func `the export is a CSV file named for the scan with one record per node`() {
    let entries = NodeDiscoveryEntries.make(results: [result(byte: 0xC3, name: "Charlie", snr: 1, heard: true, answered: false)], contacts: [:], discovered: [:])
    let export = NodeDiscoveryExport.csvExport(for: entries, date: heardAt)
    defer { export.removeTemporaryFile() }
    #expect(export.recordCount == 1)
    #expect(export.filename.hasPrefix("Cairn-scan-nodes-"))
    #expect(export.filename.hasSuffix(".csv"))
    let text = String(decoding: export.data.dropFirst(3), as: UTF8.self)
    #expect(text.hasPrefix("key_hex,name,type"))
    #expect(text.contains("Charlie"))
  }

  @Test
  func `node kinds are named by their type byte`() {
    #expect(NodeDiscoveryExport.typeName(ContactType.repeater.rawValue, filter: .repeaters) == "repeater")
    #expect(NodeDiscoveryExport.typeName(ContactType.chat.rawValue, filter: .repeaters) == "contact")
    #expect(NodeDiscoveryExport.typeName(ContactType.room.rawValue, filter: .repeaters) == "room")
    #expect(NodeDiscoveryExport.typeName(NeighbourDirectory.sensorType, filter: .repeaters) == "sensor")
    #expect(NodeDiscoveryExport.typeName(0, filter: .sensors) == "sensor")
    #expect(NodeDiscoveryExport.typeName(0, filter: .repeaters) == "repeater")
  }
}
