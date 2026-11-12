import Foundation
@testable import Cairn
import Testing

@Suite("RadioStatusLineText")
@MainActor
struct RadioStatusLineTextTests {
  @Test
  func `nothing known shows nothing`() {
    #expect(RadioStatusLineText.text(batteryPercentage: nil, txPower: nil).isEmpty)
  }

  @Test
  func `battery and TX power show together, battery first`() {
    let text = RadioStatusLineText.text(batteryPercentage: 87, txPower: 22)
    let parts = text.components(separatedBy: " · ")
    #expect(parts.count == 2)
    #expect(parts[0].contains("87") && parts[0].contains("%"))
    #expect(parts[1].contains("22") && parts[1].contains("dBm"))
  }

  @Test
  func `TX power shows alone before the first battery reading`() {
    let text = RadioStatusLineText.text(batteryPercentage: nil, txPower: 22)
    #expect(text.contains("22") && text.contains("dBm"))
    #expect(!text.contains("·"))
  }

  @Test
  func `negative TX power is kept`() {
    #expect(RadioStatusLineText.text(batteryPercentage: nil, txPower: -9).contains("9"))
  }

  @Test
  func `out-of-range battery readings are clamped`() {
    #expect(
      RadioStatusLineText.text(batteryPercentage: 140, txPower: nil)
        == RadioStatusLineText.text(batteryPercentage: 100, txPower: nil)
    )
    #expect(
      RadioStatusLineText.text(batteryPercentage: -5, txPower: nil)
        == RadioStatusLineText.text(batteryPercentage: 0, txPower: nil)
    )
  }
}
