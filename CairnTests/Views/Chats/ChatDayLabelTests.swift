import Foundation
@testable import Cairn
import Testing

@Suite("ChatDayLabel")
struct ChatDayLabelTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  /// Wednesday 7 October 2026, 15:00 UTC.
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15))!
  }

  private func daysAgo(_ days: Int, hour: Int = 9) -> Date {
    let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
    return calendar.date(byAdding: .hour, value: hour, to: day)!
  }

  private func named(_ days: Int) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    formatter.formattingContext = .standalone
    return formatter.localizedString(from: DateComponents(day: -days))
  }

  @Test
  func `Today and yesterday are named, whatever the hour`() {
    #expect(ChatDayLabel.text(for: daysAgo(0, hour: 1), relativeTo: now, calendar: calendar) == named(0))
    // 30 hours earlier, but the calendar day before: Yesterday, not "30 hours ago".
    #expect(ChatDayLabel.text(for: daysAgo(1, hour: 9), relativeTo: now, calendar: calendar) == named(1))
  }

  @Test
  func `The past week reads as weekdays, then dates`() {
    let threeDays = daysAgo(3)
    #expect(ChatDayLabel.text(for: threeDays, relativeTo: now, calendar: calendar)
      == threeDays.formatted(.dateTime.weekday(.wide)))
    let tenDays = daysAgo(10)
    #expect(ChatDayLabel.text(for: tenDays, relativeTo: now, calendar: calendar)
      == tenDays.formatted(.dateTime.month(.abbreviated).day()))
  }

  @Test
  func `A past year's date carries the year`() {
    let lastYear = daysAgo(400)
    #expect(ChatDayLabel.text(for: lastYear, relativeTo: now, calendar: calendar)
      == lastYear.formatted(.dateTime.month(.abbreviated).day().year()))
  }
}
