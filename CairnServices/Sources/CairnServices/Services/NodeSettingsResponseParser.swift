import Foundation

/// Pure parsing of repeater and room CLI responses for the node settings
/// screens: clock parsing, owner-info wire mapping, and success/error
/// classification. Builds on `CLIResponse` and holds no state, so every
/// function is directly unit-testable.
public enum NodeSettingsResponseParser {
  // MARK: - Late Reply Recovery

  /// Attribution by elimination for an out-of-band CLI reply. One command is
  /// in flight per node, so a reply that no pending command claimed can only
  /// answer a command that timed out unanswered. Returns the parsed value when
  /// the reply parses to a query-specific shape for exactly one of the given
  /// queries; several matches are ambiguous, so nothing is returned.
  public static func recoveredResponse(
    _ response: String,
    unansweredQueries: Set<String>
  ) -> (query: String, value: CLIResponse)? {
    let matches = unansweredQueries.compactMap { query -> (query: String, value: CLIResponse)? in
      guard CLIResponse.isStructuredQuery(query) else { return nil }
      switch CLIResponse.parse(response, forQuery: query) {
      case .raw, .ok, .error, .unknownCommand, .version:
        // Query-independent shapes match every query equally; not attributable.
        return nil
      case let value:
        return (query, value)
      }
    }
    guard matches.count == 1, let match = matches.first else { return nil }
    return match
  }

  // MARK: - Device Clock

  private static let clockResponseDateFormat = "HH:mm d/M/yyyy"

  /// The UTC clock shape in firmware text, including inside an `OK - clock set:` reply.
  public static func clockResponseText(in text: String) -> String? {
    // Regex isn't Sendable, so the literal lives here instead of in a static.
    let clockResponseRegex = /(\d{1,2}:\d{2}) - (\d{1,2}\/\d{1,2}\/\d{4}) UTC/
    guard let match = text.firstMatch(of: clockResponseRegex) else { return nil }
    return String(match.output.0)
  }

  /// Parses a firmware clock response like "06:40 - 18/4/2025 UTC" into a `Date`.
  /// Returns `nil` when the text doesn't carry the expected UTC clock shape.
  public static func utcDate(fromClockResponse response: String) -> Date? {
    // Regex isn't Sendable, so the literal lives here instead of in a static.
    let clockResponseRegex = /(\d{1,2}:\d{2}) - (\d{1,2}\/\d{1,2}\/\d{4}) UTC/
    guard let match = response.firstMatch(of: clockResponseRegex) else { return nil }

    // A fresh formatter per call keeps this Sendable; clock parsing is rare.
    let formatter = DateFormatter()
    formatter.dateFormat = clockResponseDateFormat
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: "\(match.output.1) \(match.output.2)")
  }

  /// Seconds the node's clock is ahead of `now`. Nil when `response` has no clock shape.
  ///
  /// The firmware gives its time to the minute ("06:40"), so the node's clock is somewhere in that
  /// minute: 0 when `now` falls in it too (in sync, as far as the reply can tell), else the middle of
  /// the range the reply allows. Taking the minute's start as the node's time read a node synced a
  /// moment ago as up to 59 s behind (the user, 2026-11-09: "44 sec behind" right after Sync Time).
  public static func clockDrift(
    fromClockResponse response: String,
    relativeTo now: Date
  ) -> TimeInterval? {
    guard let minuteStart = utcDate(fromClockResponse: response) else { return nil }
    let earliest = minuteStart.timeIntervalSince(now)   // the node at the minute's first second
    let latest = earliest + 60                           // ... and just before its last
    if earliest <= 0, latest > 0 { return 0 }
    return earliest + 30
  }

  // MARK: - Clock Sync

  /// Outcome of a `clock sync` command response.
  public enum ClockSyncOutcome: Equatable, Sendable {
    case synced
    /// Firmware refused the sync because its clock is ahead of the phone's.
    case clockAhead
    /// Firmware reported an error; `message` is the response with the
    /// "ERR: " prefix stripped and may be empty.
    case failed(message: String)
    case unexpected
  }

  private static let clockAheadErrorFragment = "clock cannot go backwards"
  private static let cliErrorPrefix = "ERR: "

  /// Classifies a `clock sync` response into a typed outcome.
  public static func classifyClockSyncResponse(_ response: String) -> ClockSyncOutcome {
    switch CLIResponse.parse(response) {
    case .ok:
      return .synced
    case let .error(message):
      if message.contains(clockAheadErrorFragment) {
        return .clockAhead
      }
      return .failed(message: message.replacing(cliErrorPrefix, with: ""))
    default:
      return .unexpected
    }
  }

  /// How far a node's clock may read from the phone's and still count as set. The `clock` reply
  /// shows minutes only, so a reading can be up to a minute behind the node's clock.
  public static let clockSyncTolerance: TimeInterval = 60

  /// Whether a sync the node refused as going backwards (`.clockAhead`) means its clock is already
  /// right: a `time` stamped ahead of the phone lands just behind a clock it set a moment earlier.
  /// - Parameters:
  ///   - drift: The node's clock ahead of the phone, from the last `clock` reading; nil when unread.
  ///   - earlierAttemptUnanswered: A sync sent before this one got no reply, so it most likely set the clock.
  /// - Returns: true when the clock reads within ``clockSyncTolerance`` of the phone, or no reading
  ///   says otherwise after an unanswered sync; false when it reads further ahead (the clock really
  ///   is ahead); nil when unsure, and the caller reads the clock to decide.
  public static func refusedSyncMeansInSync(drift: TimeInterval?, earlierAttemptUnanswered: Bool) -> Bool? {
    if let drift, drift > clockSyncTolerance { return false }
    if earlierAttemptUnanswered { return true }
    guard let drift else { return nil }
    // Far behind and still refused: the reading is out of date.
    return drift >= -clockSyncTolerance ? true : nil
  }

  // MARK: - Password

  /// Firmware echoes "password now: {pw}" on success instead of "OK".
  private static let passwordChangedPrefix = "password now:"

  /// Whether a `password` command response indicates the change was accepted.
  public static func isPasswordChangeSuccessful(_ response: String) -> Bool {
    switch CLIResponse.parse(response) {
    case .ok:
      true
    case let .raw(text):
      text.hasPrefix(passwordChangedPrefix)
    default:
      false
    }
  }

  // MARK: - Owner Info

  /// Firmware stores owner info as a single line with "|" separating rows.
  private static let ownerInfoWireSeparator = "|"
  private static let ownerInfoDisplaySeparator = "\n"

  /// Maps the wire form ("|"-separated) to the multi-line display form.
  public static func displayOwnerInfo(fromWire wire: String) -> String {
    wire.replacing(ownerInfoWireSeparator, with: ownerInfoDisplaySeparator)
  }

  /// Maps the multi-line display form back to the "|"-separated wire form.
  public static func wireOwnerInfo(fromDisplay display: String) -> String {
    display.replacing(ownerInfoDisplaySeparator, with: ownerInfoWireSeparator)
  }
}
