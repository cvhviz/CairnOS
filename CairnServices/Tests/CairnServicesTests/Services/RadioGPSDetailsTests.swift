import Testing
@testable import CairnServices

/// Cairn firmware's `gps_info` custom var, as `test/test_gps_info` in the firmware writes it.
@Suite("Radio GPS details")
struct RadioGPSDetailsTests {
  @Test
  func `a fix with everything`() throws {
    let details = try #require(RadioGPSDetails(customVar: "12/18/9/1000/27000/523/1"))
    #expect(details.satellites == 12)
    #expect(details.satellitesInView == 18)
    #expect(details.hdop == 0.9)
    #expect(abs((details.metersPerSecond ?? 0) - 0.514444) < 0.000001)
    #expect(details.courseDegrees == 27)
    #expect(details.secondsSinceSignal == 0.523)
    #expect(details.hasFix)
  }

  @Test
  func `what the receiver doesn't say stays unknown`() throws {
    let details = try #require(RadioGPSDetails(customVar: "0/-1/-1/-1/-1/-1/0"))
    #expect(details.satellites == 0)
    #expect(details.satellitesInView == nil)
    #expect(details.hdop == nil)
    #expect(details.metersPerSecond == nil)
    #expect(details.courseDegrees == nil)
    #expect(details.secondsSinceSignal == nil)
    #expect(!details.hasFix)
  }

  @Test
  func `a later firmware's extra fields are ignored, and a short or bad value is no details`() {
    #expect(RadioGPSDetails(customVar: "1/2/3/4/5/6/1/99")?.satellites == 1)
    #expect(RadioGPSDetails(customVar: "1/2/3") == nil)
    #expect(RadioGPSDetails(customVar: "a/2/3/4/5/6/1") == nil)
    #expect(RadioGPSDetails(customVar: "") == nil)
  }

  @Test
  func `only firmware that sends it has details`() {
    let stock = SettingsService.deviceGPSState(from: ["gps": "1"])
    #expect(stock.details == nil)
    #expect(stock.isEnabled)
    let cairn = SettingsService.deviceGPSState(from: ["gps": "1", "gps_mode": "2", "gps_info": "9/12/9/0/-1/400/1"])
    #expect(cairn.details?.satellites == 9)
    #expect(cairn.isEco == true)
  }
}
