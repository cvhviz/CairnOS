import Foundation
@testable import Cairn
import Testing

@Suite("SolarCalculator")
struct SolarCalculatorTests {
  /// Published almanac times are to the minute; the NOAA method is good to about one.
  private static let tolerance: TimeInterval = 3 * 60

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in zone: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func expectTimes(
    latitude: Double, longitude: Double, zone: String,
    on day: (Int, Int, Int),
    sunrise: (Int, Int), sunset: (Int, Int)
  ) {
    let noon = date(day.0, day.1, day.2, 12, 0, in: zone)
    let result = SolarCalculator.sunTimes(
      on: noon, latitude: latitude, longitude: longitude, timeZone: TimeZone(identifier: zone)!
    )
    guard case let .times(rise, set) = result else {
      Issue.record("Expected sunrise and sunset, got \(result)")
      return
    }
    let expectedRise = date(day.0, day.1, day.2, sunrise.0, sunrise.1, in: zone)
    let expectedSet = date(day.0, day.1, day.2, sunset.0, sunset.1, in: zone)
    #expect(abs(rise.timeIntervalSince(expectedRise)) < Self.tolerance)
    #expect(abs(set.timeIntervalSince(expectedSet)) < Self.tolerance)
  }

  @Test
  func `London midsummer matches the almanac in summer time`() {
    expectTimes(latitude: 51.5074, longitude: -0.1278, zone: "Europe/London",
                on: (2024, 6, 21), sunrise: (4, 43), sunset: (21, 21))
  }

  @Test
  func `New York midwinter matches the almanac`() {
    expectTimes(latitude: 40.7128, longitude: -74.0060, zone: "America/New_York",
                on: (2024, 12, 21), sunrise: (7, 16), sunset: (16, 32))
  }

  @Test
  func `Tokyo sunrise falls on the previous UTC day and still lands on the local date`() {
    expectTimes(latitude: 35.6762, longitude: 139.6503, zone: "Asia/Tokyo",
                on: (2024, 6, 21), sunrise: (4, 25), sunset: (19, 0))
  }

  @Test
  func `Sydney works south of the equator`() {
    expectTimes(latitude: -33.8688, longitude: 151.2093, zone: "Australia/Sydney",
                on: (2024, 12, 21), sunrise: (5, 41), sunset: (20, 5))
  }

  @Test
  func `Polar day and polar night above the Arctic Circle`() {
    let zone = TimeZone(identifier: "Europe/Oslo")!
    let summer = date(2024, 6, 21, 12, 0, in: "Europe/Oslo")
    let winter = date(2024, 12, 21, 12, 0, in: "Europe/Oslo")
    #expect(SolarCalculator.sunTimes(on: summer, latitude: 69.6492, longitude: 18.9553, timeZone: zone) == .polarDay)
    #expect(SolarCalculator.sunTimes(on: winter, latitude: 69.6492, longitude: 18.9553, timeZone: zone) == .polarNight)
  }

  @Test
  func `Julian day of the J2000 epoch date`() {
    #expect(SolarCalculator.julianDayAtMidnightUTC(year: 2000, month: 1, day: 1) == 2_451_544.5)
  }
}
