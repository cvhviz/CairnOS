import Foundation
@testable import CairnServices
import Testing

@Suite("Device time zone")
struct DeviceTimeZoneTests {
  @Test
  func `parses the firmware's replies in hours to minutes`() {
    #expect(DeviceTimeZone.parseReply("> -5") == -300)
    #expect(DeviceTimeZone.parseReply("> 0") == 0)
    #expect(DeviceTimeZone.parseReply("> 5.50") == 330)
    #expect(DeviceTimeZone.parseReply("-3.5") == -210)
    #expect(DeviceTimeZone.parseReply("> 14") == 840)
    #expect(DeviceTimeZone.parseReply("> 15") == nil)
    #expect(DeviceTimeZone.parseReply("Error: unknown command") == nil)
    #expect(DeviceTimeZone.parseReply("") == nil)
  }

  @Test
  func `writes whole hours plain and fractions as decimal hours`() {
    #expect(DeviceTimeZone.commandArgument(minutes: -300) == "-5")
    #expect(DeviceTimeZone.commandArgument(minutes: 0) == "0")
    #expect(DeviceTimeZone.commandArgument(minutes: 330) == "5.5")
    #expect(DeviceTimeZone.commandArgument(minutes: 345) == "5.75")
    #expect(DeviceTimeZone.commandArgument(minutes: -210) == "-3.5")
    // rounded to the firmware's quarter hours and clamped to its range
    #expect(DeviceTimeZone.commandArgument(minutes: 340) == "5.75")
    #expect(DeviceTimeZone.commandArgument(minutes: 900) == "14")
  }

  @Test
  func `labels read as the boards print them`() {
    #expect(DeviceTimeZone.label(minutes: 0) == "UTC")
    #expect(DeviceTimeZone.label(minutes: -300) == "UTC-5")
    #expect(DeviceTimeZone.label(minutes: 330) == "UTC+5:30")
    #expect(DeviceTimeZone.label(minutes: -210) == "UTC-3:30")
  }

  @Test
  func `the phone's offset follows daylight saving`() throws {
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    let july = Date(timeIntervalSince1970: 1_752_000_000)      // 2025-07-08
    let january = Date(timeIntervalSince1970: 1_736_000_000)   // 2025-01-04
    #expect(DeviceTimeZone.phoneOffsetMinutes(at: july, in: newYork) == -240)
    #expect(DeviceTimeZone.phoneOffsetMinutes(at: january, in: newYork) == -300)
    let kathmandu = try #require(TimeZone(identifier: "Asia/Kathmandu"))
    #expect(DeviceTimeZone.phoneOffsetMinutes(at: july, in: kathmandu) == 345)
  }

  @Test
  func `the picker offers every whole hour and the fractional zones in use`() {
    #expect(DeviceTimeZone.pickerOffsets.first == -720)
    #expect(DeviceTimeZone.pickerOffsets.last == 840)
    #expect(DeviceTimeZone.pickerOffsets.contains(330))   // India
    #expect(DeviceTimeZone.pickerOffsets.contains(345))   // Nepal
    #expect(DeviceTimeZone.pickerOffsets.contains(-210))  // Newfoundland
    #expect(DeviceTimeZone.pickerOffsets == DeviceTimeZone.pickerOffsets.sorted())
  }
}
