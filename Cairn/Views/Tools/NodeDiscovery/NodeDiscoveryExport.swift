import CairnServices
import Foundation

/// The nodes a scan or Wardrive heard, as a CSV: one row per listed node with its key, name and
/// kind, the signal both ways, where and when it was heard, and whether it answered the scan.
/// Pure, so the tests can pin the columns. No route is exported: the heard-at position of each
/// node is as far as it goes.
enum NodeDiscoveryExport {
  static let headers = [
    "key_hex", "name", "type", "is_contact", "snr_you_hear_db", "snr_they_hear_db", "rssi_dbm",
    "heard_at_utc", "heard_lat", "heard_lon", "heard_accuracy_m", "answered_scan", "sources",
    "distance_m", "node_lat", "node_lon", "earlier",
  ]

  /// "repeater", "sensor", "contact", "room": the row's node kind, as its type byte says.
  static func typeName(_ nodeType: UInt8, filter: NodeDiscoveryFilter) -> String {
    switch nodeType {
    case ContactType.chat.rawValue: "contact"
    case ContactType.repeater.rawValue: "repeater"
    case ContactType.room.rawValue: "room"
    case NeighbourDirectory.sensorType: "sensor"
    default: filter == .sensors ? "sensor" : "repeater"
    }
  }

  /// The table for `entries`, in the order given.
  static func csvTable(for entries: [NodeDiscoveryEntry]) -> CSVTable {
    var table = CSVTable(headers: headers)
    for entry in entries {
      let result = entry.result
      let heard = result.heardFrom
      table.append([
        ExportFormat.hex(result.key),
        result.isNamed ? result.name : "",
        typeName(result.nodeType, filter: result.scanFilter),
        entry.isContact ? "true" : "false",
        ExportFormat.number(result.snr, fractionDigits: 2),
        ExportFormat.number(result.uplinkSNR, fractionDigits: 2),
        ExportFormat.integer(result.rssi),
        ExportFormat.timestamp(result.receivedAt),
        ExportFormat.number(heard?.fix.latitude),
        ExportFormat.number(heard?.fix.longitude),
        ExportFormat.number(heard?.fix.horizontalAccuracy, fractionDigits: 1),
        result.sources.contains(.replyToUs) ? "true" : "false",
        result.sources.map(\.rawValue).sorted().joined(separator: "|"),
        ExportFormat.number(entry.distance, fractionDigits: 1),
        ExportFormat.number(entry.coordinate?.latitude),
        ExportFormat.number(entry.coordinate?.longitude),
        result.isEarlier ? "true" : "false",
      ])
    }
    return table
  }

  /// The CSV of `entries`, staged for the file exporter.
  static func csvExport(for entries: [NodeDiscoveryEntry], date: Date = Date()) -> ExportedFile {
    let table = csvTable(for: entries)
    return ExportedFile(
      data: table.renderData(),
      filename: "Cairn-scan-nodes-\(ExportFormat.filenameStamp(date)).csv",
      contentType: .commaSeparatedText,
      recordCount: table.rows.count
    )
  }
}
