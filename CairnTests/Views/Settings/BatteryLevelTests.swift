@testable import Cairn
import CairnServices
import Testing

@Suite("BatteryLevel")
struct BatteryLevelTests {
  @Test
  func `Levels use the low-battery notification thresholds`() {
    #expect(BatteryLevel(percent: 100) == .good)
    #expect(BatteryLevel(percent: 20) == .good)
    #expect(BatteryLevel(percent: 19) == .low)
    #expect(BatteryLevel(percent: 10) == .low)
    #expect(BatteryLevel(percent: 9) == .critical)
    #expect(BatteryLevel(percent: 0) == .critical)
  }

  @Test
  func `Every level has a word, so the state never rests on color`() {
    for level in [BatteryLevel.good, .low, .critical] {
      #expect(!level.title.isEmpty)
    }
  }

  @Test
  func `Battery glyph steps with the charge`() {
    #expect(BatteryLevel.symbol(for: nil) == "battery.0")
    #expect(BatteryLevel.symbol(for: 100) == "battery.100")
    #expect(BatteryLevel.symbol(for: 88) == "battery.100")
    #expect(BatteryLevel.symbol(for: 70) == "battery.75")
    #expect(BatteryLevel.symbol(for: 50) == "battery.50")
    #expect(BatteryLevel.symbol(for: 20) == "battery.25")
    #expect(BatteryLevel.symbol(for: 5) == "battery.0")
  }

  @Test
  func `Missing percent reads as a dash`() {
    #expect(BatteryLevel.formattedPercent(nil) == "—")
    #expect(BatteryLevel.formattedPercent(87).contains("87"))
  }

  @Test
  func `Curve range spans empty to full`() {
    let range = BatteryLevel.formattedRange(ocvArray: OCVPreset.liIon.ocvArray)
    #expect(range?.contains("–") == true)
    #expect(BatteryLevel.formattedRange(ocvArray: []) == nil)
    #expect(BatteryLevel.formattedRange(ocvArray: [4200]) == nil)
  }
}
