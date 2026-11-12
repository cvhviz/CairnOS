import Foundation

/// A daily window during which notifications arrive quietly: no sound, and delivered passively (to
/// Notification Center, without a banner or a wake of the screen). The badge still counts and
/// nothing is dropped, so the morning shows what came in overnight.
///
/// Both ends are minutes past midnight. A window whose end is before its start spans midnight
/// (22:00–07:00); one whose ends are equal covers the whole day.
public struct QuietHoursWindow: Equatable, Sendable {
  public static let minutesPerDay = 24 * 60

  public var startMinute: Int
  public var endMinute: Int

  public init(startMinute: Int, endMinute: Int) {
    self.startMinute = Self.wrapped(startMinute)
    self.endMinute = Self.wrapped(endMinute)
  }

  /// Whether `minuteOfDay` (0..<1440) falls inside the window. The start is inside, the end is not,
  /// so 22:00–07:00 is quiet at 22:00 and loud again at 07:00.
  public func contains(minuteOfDay minute: Int) -> Bool {
    let minute = Self.wrapped(minute)
    if startMinute == endMinute { return true }
    if startMinute < endMinute {
      return minute >= startMinute && minute < endMinute
    }
    // Overnight: from the start to midnight, then midnight to the end.
    return minute >= startMinute || minute < endMinute
  }

  /// Whether `date` falls inside the window on the calendar's local day.
  public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return contains(minuteOfDay: (components.hour ?? 0) * 60 + (components.minute ?? 0))
  }

  /// The minute as a time on an arbitrary day, for a time-only `DatePicker`.
  public static func date(forMinute minute: Int, calendar: Calendar = .current) -> Date {
    let start = calendar.startOfDay(for: Date())
    return calendar.date(byAdding: .minute, value: wrapped(minute), to: start) ?? start
  }

  /// The minute past midnight a time-only `DatePicker`'s date names.
  public static func minute(of date: Date, calendar: Calendar = .current) -> Int {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return wrapped((components.hour ?? 0) * 60 + (components.minute ?? 0))
  }

  private static func wrapped(_ minute: Int) -> Int {
    ((minute % minutesPerDay) + minutesPerDay) % minutesPerDay
  }
}
