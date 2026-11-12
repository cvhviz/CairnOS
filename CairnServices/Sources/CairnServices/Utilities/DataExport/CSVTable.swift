import Foundation

/// An RFC 4180 CSV table: a header row plus data rows, rendered with CRLF line endings.
public struct CSVTable: Sendable, Equatable {
  public let headers: [String]
  public private(set) var rows: [[String]] = []

  public init(headers: [String]) {
    self.headers = headers
  }

  /// Appends a row. Missing trailing cells render empty; extra cells are dropped.
  public mutating func append(_ row: [String?]) {
    var cells = row.prefix(headers.count).map { $0 ?? "" }
    if cells.count < headers.count {
      cells.append(contentsOf: repeatElement("", count: headers.count - cells.count))
    }
    rows.append(cells)
  }

  /// The CSV text, header first, every line terminated by CRLF.
  public func render() -> String {
    var output = Self.line(headers)
    for row in rows {
      output += Self.line(row)
    }
    return output
  }

  /// UTF-8 bytes with a leading byte-order mark so spreadsheet apps detect the encoding.
  public func renderData() -> Data {
    Data([0xEF, 0xBB, 0xBF]) + Data(render().utf8)
  }

  private static func line(_ cells: [String]) -> String {
    cells.map(escape).joined(separator: ",") + "\r\n"
  }

  /// Quotes a field when it contains a comma, quote, CR or LF, doubling inner quotes.
  /// Fields starting with a spreadsheet formula trigger (`=`, `+`, `-`, `@`, TAB, CR) followed
  /// by a non-numeric character are prefixed with `'` so opening the file cannot execute them.
  ///
  /// Both checks read Unicode scalars: `"\r\n"` and a trigger followed by a combining mark
  /// are each a single `Character` that equals none of the characters being looked for.
  public static func escape(_ field: String) -> String {
    var value = field
    if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first), Double(value) == nil {
      value = "'" + value
    }
    let needsQuoting = value.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
    guard needsQuoting else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// Shared cell formatting for data exports.
public enum ExportFormat {
  /// ISO 8601 UTC, e.g. `2026-09-27T14:03:05Z`.
  public static func timestamp(_ date: Date?) -> String? {
    date?.formatted(.iso8601)
  }

  /// ISO 8601 UTC for a Unix epoch seconds value; nil or zero means unknown.
  public static func timestamp(epochSeconds: UInt32?) -> String? {
    guard let epochSeconds, epochSeconds > 0 else { return nil }
    return timestamp(Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
  }

  /// Lowercase hex without separators.
  public static func hex(_ data: Data?) -> String? {
    guard let data, !data.isEmpty else { return nil }
    return data.map { String(format: "%02x", $0) }.joined()
  }

  /// Locale-independent decimal (always `.` separator).
  public static func number(_ value: Double?, fractionDigits: Int = 6) -> String? {
    guard let value, value.isFinite else { return nil }
    var text = String(format: "%.\(fractionDigits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    if text.contains(".") {
      while text.hasSuffix("0") {
        text.removeLast()
      }
      if text.hasSuffix(".") { text.removeLast() }
    }
    return text
  }

  public static func integer(_ value: (some BinaryInteger)?) -> String? {
    value.map { String($0) }
  }

  /// Filename-safe local timestamp suffix, e.g. `20260927-1403`.
  public static func filenameStamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return formatter.string(from: date)
  }
}
