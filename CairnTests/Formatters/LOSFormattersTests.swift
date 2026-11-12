import Foundation
@testable import Cairn
import Testing

@Suite("LOSFormatters")
struct LOSFormattersTests {
  private let locale = Locale(identifier: "en_US")

  @Test
  func `elevation follows the measurement preference in whole meters or feet`() {
    #expect(LOSFormatters.formatElevation(1234.4, usesImperial: false, locale: locale) == "1,234 m")
    #expect(LOSFormatters.formatElevation(1234.4, usesImperial: true, locale: locale) == "4,050 ft")
  }

  @Test
  func `a high elevation is not promoted to kilometers or miles`() {
    #expect(LOSFormatters.formatElevation(4810, usesImperial: false, locale: locale) == "4,810 m")
    #expect(LOSFormatters.formatElevation(4810, usesImperial: true, locale: locale) == "15,781 ft")
  }
}
