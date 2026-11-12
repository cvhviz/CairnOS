import Foundation
@testable import Cairn
import Testing

@Suite("RadioStatsFormatter")
struct RadioStatsFormatterTests {
  private let locale = Locale(identifier: "en_US")

  @Test
  func `Airtime fraction is relative to uptime and capped at one`() {
    #expect(RadioStatsFormatter.airtimeFraction(airtimeSeconds: 36, uptimeSeconds: 3600) == 0.01)
    #expect(RadioStatsFormatter.airtimeFraction(airtimeSeconds: 10, uptimeSeconds: 0) == nil)
    #expect(RadioStatsFormatter.airtimeFraction(airtimeSeconds: 7200, uptimeSeconds: 3600) == 1)
  }

  @Test
  func `Voltage converts millivolts to volts`() {
    #expect(RadioStatsFormatter.voltage(millivolts: 4123, locale: locale) == "4.12 V")
  }

  @Test
  func `Receive error rate counts errors against all receive attempts`() {
    #expect(RadioStatsFormatter.receiveErrorRate(errors: 1, received: 99) == 0.01)
    #expect(RadioStatsFormatter.receiveErrorRate(errors: 0, received: 0) == nil)
  }

  @Test
  func `Duration shows at most three units`() {
    let text = RadioStatsFormatter.duration(seconds: 2 * 86400 + 3 * 3600 + 14 * 60 + 5, locale: locale)
    #expect(text.contains("2d"))
    #expect(text.contains("3h"))
    #expect(text.contains("14m"))
    #expect(!text.contains("5s"))
  }

  @Test
  func `Airtime share needs an uptime and formats as a percentage`() {
    #expect(RadioStatsFormatter.airtimeShare(seconds: 60, uptimeSeconds: nil, locale: locale) == nil)
    #expect(RadioStatsFormatter.airtimeShare(seconds: 60, uptimeSeconds: 0, locale: locale) == nil)
    #expect(RadioStatsFormatter.airtimeShare(seconds: 36, uptimeSeconds: 3600, locale: locale) == "1.00%")
  }
}
