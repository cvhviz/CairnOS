import Foundation

/// Rewrites remote `clock sync` to `time <host-epoch>`. Companion firmware
/// restamps CLI packets to its own RTC, so the packet timestamp is not the phone clock.
public enum RemoteCLICommandRewriter: Sendable {
  public static let clockSyncCommand = "clock sync"
  public static let timeCommandPrefix = "time "

  /// The longest a `time` is stamped ahead of the phone: past it, a slow route would leave the node ahead.
  static let maximumClockSyncLead: TimeInterval = 5
  /// The lead for a flood route, or a node whose route isn't known.
  static let floodClockSyncLead: TimeInterval = 2

  public static func isClockSync(_ command: String) -> Bool {
    command.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() == clockSyncCommand
  }

  /// `lead` is how long the command takes to reach the node: the time is stamped that far ahead,
  /// rounded up, since the firmware sets its clock to the value exactly and refuses one that isn't
  /// ahead of its own (`CommonCLI` `time`).
  public static func rewrite(_ command: String, now: Date = Date(), lead: TimeInterval = 0) -> String {
    guard isClockSync(command) else { return command }
    return timeCommandPrefix + String(epochSeconds32(now.addingTimeInterval(max(0, lead))))
  }

  /// How long a command takes to reach a node: about a second for the last transmission and one
  /// more for each repeater on a direct route (`pathHopCount`), or `floodClockSyncLead` for a flood
  /// route (nil). Capped at `maximumClockSyncLead`.
  public static func clockSyncLead(pathHopCount: Int?) -> TimeInterval {
    guard let pathHopCount else { return floodClockSyncLead }
    return min(TimeInterval(1 + max(0, pathHopCount)), maximumClockSyncLead)
  }

  /// Rounds up, and saturates pre-1970 and post-2106 dates instead of trapping `UInt32(_:)`.
  private static func epochSeconds32(_ date: Date) -> UInt32 {
    let seconds = date.timeIntervalSince1970.rounded(.up)
    guard seconds.isFinite, seconds > 0 else { return 0 }
    guard seconds < Double(UInt32.max) else { return UInt32.max }
    return UInt32(seconds)
  }
}
