import CairnServices
import Foundation

/// A saved path's runs as a CSV, and a trace's result as a few lines of text, for sharing. Pure,
/// so the tests can pin the columns and the lines.
enum TraceExport {
  static let runHeaders = ["date_utc", "success", "round_trip_ms", "hops", "hop_snr_db"]

  /// One row per run, newest first: when, whether it answered, the round trip, and the SNR at
  /// each hop (as "5.0|3.25|-2.0").
  static func runsTable(for path: SavedTracePathDTO) -> CSVTable {
    var table = CSVTable(headers: runHeaders)
    for run in path.runs.sorted(by: { $0.date > $1.date }) {
      table.append([
        ExportFormat.timestamp(run.date),
        run.success ? "true" : "false",
        run.success ? ExportFormat.integer(run.roundTripMs) : nil,
        ExportFormat.integer(run.hopsSNR.count),
        run.hopsSNR.compactMap { ExportFormat.number($0, fractionDigits: 2) }.joined(separator: "|"),
      ])
    }
    return table
  }

  /// The runs CSV staged for sharing, named after the path.
  static func runsExport(for path: SavedTracePathDTO, date: Date = Date()) -> ExportedFile {
    let table = runsTable(for: path)
    let name = path.name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    return ExportedFile(
      data: table.renderData(),
      filename: "Cairn-trace-\(name.isEmpty ? "path" : name)-\(ExportFormat.filenameStamp(date)).csv",
      contentType: .commaSeparatedText,
      recordCount: table.rows.count
    )
  }

  /// A trace's outcome in text: the path, how long the round trip took, the hops and the SNR at
  /// each, or why it failed.
  static func summary(for result: TraceResult, date: Date = Date()) -> String {
    var lines: [String] = [
      "\(L10n.Contacts.Contacts.Trace.title) · \(date.formatted(date: .abbreviated, time: .shortened))",
      L10n.Tools.Tools.TracePath.Summary.path(result.tracedPathString),
    ]
    if result.success {
      lines.append(L10n.Tools.Tools.TracePath.Summary.roundTrip(result.durationMs.formatted()))
      let hops = result.hops.filter { !$0.isStartNode && !$0.isEndNode }
      lines.append(L10n.Tools.Tools.TracePath.Summary.hops(hops.count))
      for (index, hop) in hops.enumerated() {
        let name = hop.resolvedName ?? hop.hashDisplayString ?? "?"
        lines.append("\(index + 1). \(name) · \(hop.snr.formatted(.number.precision(.fractionLength(1)))) dB")
      }
    } else {
      lines.append(result.errorMessage ?? L10n.Contacts.Contacts.PathDetail.failed)
    }
    return lines.joined(separator: "\n")
  }
}
