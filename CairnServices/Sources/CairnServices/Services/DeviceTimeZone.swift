import Foundation

/// The radio's clock zone: a fixed offset from UTC that the firmware's `tz.offset` CLI setting
/// holds in hours ("-5", "5.5" = +05:30, "-3.5"), taken in quarter-hour steps. The boards' own
/// screens show the local time by it (Cairn 129 and later: every companion screen; before that only
/// the touch boards read it). The app keeps it in minutes.
public enum DeviceTimeZone {
  /// The firmware's accepted range, in minutes.
  public static let range: ClosedRange<Int> = (-12 * 60)...(14 * 60)
  /// The firmware rounds to this step.
  public static let stepMinutes = 15

  /// Minutes from UTC the phone's zone is at right now (daylight saving included), in the firmware's steps.
  public static func phoneOffsetMinutes(at date: Date = Date(), in zone: TimeZone = .current) -> Int {
    rounded(zone.secondsFromGMT(for: date) / 60)
  }

  /// The firmware's `get tz.offset` reply ("> -5", "> 5.50", "-3.5") as minutes; nil when it is not a number.
  public static func parseReply(_ reply: String) -> Int? {
    var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
    guard let hours = Double(text), hours.isFinite else { return nil }
    let minutes = Int((hours * 60).rounded())
    guard range.contains(minutes) else { return nil }
    return rounded(minutes)
  }

  /// The `set tz.offset` argument for an offset in minutes: whole hours plain, else decimal hours
  /// ("5.5", "5.75", "-3.5"); the firmware rounds to its quarter-hour step.
  public static func commandArgument(minutes: Int) -> String {
    let minutes = rounded(minutes)
    if minutes % 60 == 0 { return String(minutes / 60) }
    let hours = Double(minutes) / 60
    return String(format: "%.2f", hours).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
  }

  /// "UTC", "UTC-5", "UTC+5:30": the offset as the boards' screens print it.
  public static func label(minutes: Int) -> String {
    if minutes == 0 { return "UTC" }
    let sign = minutes < 0 ? "-" : "+"
    let abs = Swift.abs(minutes)
    if abs % 60 == 0 { return "UTC\(sign)\(abs / 60)" }
    return String(format: "UTC%@%d:%02d", sign, abs / 60, abs % 60)
  }

  /// The offsets a picker offers: every whole hour, plus the half- and quarter-hour zones in use.
  public static let pickerOffsets: [Int] = {
    var set = Set((-12...14).map { $0 * 60 })
    for fractional in [-570, -210, 210, 270, 330, 345, 390, 525, 570, 630, 765] { set.insert(fractional) }
    return set.sorted()
  }()

  /// Clamped to the firmware's range and rounded to its step.
  static func rounded(_ minutes: Int) -> Int {
    let stepped = Int((Double(minutes) / Double(stepMinutes)).rounded()) * stepMinutes
    return min(max(stepped, range.lowerBound), range.upperBound)
  }
}
