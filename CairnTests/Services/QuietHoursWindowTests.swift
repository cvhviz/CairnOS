import Foundation
@testable import CairnServices
import Testing

@Suite("Quiet hours window")
struct QuietHoursWindowTests {
  private func minute(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

  @Test
  func `a same-day window holds its start and not its end`() {
    let window = QuietHoursWindow(startMinute: minute(13), endMinute: minute(15))
    #expect(window.contains(minuteOfDay: minute(13)))
    #expect(window.contains(minuteOfDay: minute(14, 30)))
    #expect(!window.contains(minuteOfDay: minute(15)))
    #expect(!window.contains(minuteOfDay: minute(12, 59)))
    #expect(!window.contains(minuteOfDay: minute(23)))
  }

  @Test
  func `an overnight window spans midnight`() {
    let window = QuietHoursWindow(startMinute: minute(22), endMinute: minute(7))
    #expect(window.contains(minuteOfDay: minute(22)))
    #expect(window.contains(minuteOfDay: minute(23, 59)))
    #expect(window.contains(minuteOfDay: 0))
    #expect(window.contains(minuteOfDay: minute(6, 59)))
    #expect(!window.contains(minuteOfDay: minute(7)))
    #expect(!window.contains(minuteOfDay: minute(12)))
    #expect(!window.contains(minuteOfDay: minute(21, 59)))
  }

  @Test
  func `equal ends cover the whole day`() {
    let window = QuietHoursWindow(startMinute: minute(9), endMinute: minute(9))
    #expect(window.contains(minuteOfDay: 0))
    #expect(window.contains(minuteOfDay: minute(9)))
    #expect(window.contains(minuteOfDay: minute(23, 59)))
  }

  @Test
  func `minutes wrap into the day`() {
    let window = QuietHoursWindow(startMinute: -60, endMinute: 24 * 60 + 60)
    #expect(window.startMinute == 23 * 60)
    #expect(window.endMinute == 60)
    #expect(window.contains(minuteOfDay: 24 * 60 + 30))
  }

  @Test
  func `a date is judged by its local time of day`() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let window = QuietHoursWindow(startMinute: minute(22), endMinute: minute(7))
    let lateNight = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 30)))
    let earlyMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 6, minute: 59)))
    let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12)))
    #expect(window.contains(lateNight, calendar: calendar))
    #expect(window.contains(earlyMorning, calendar: calendar))
    #expect(!window.contains(noon, calendar: calendar))
  }

  @Test
  func `the picker's date and the stored minute round-trip`() {
    let calendar = Calendar.current
    for stored in [0, minute(7), minute(22, 15), minute(23, 59)] {
      let date = QuietHoursWindow.date(forMinute: stored, calendar: calendar)
      #expect(QuietHoursWindow.minute(of: date, calendar: calendar) == stored)
    }
  }
}
