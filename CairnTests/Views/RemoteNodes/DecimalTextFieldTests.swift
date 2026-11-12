import Foundation
@testable import Cairn
import Testing

@Suite("DecimalTextField")
@MainActor
struct DecimalTextFieldTests {
  @Test
  func `a comma decimal separator parses like a point`() {
    #expect(DecimalTextField.parse("869,525") == 869.525)
    #expect(DecimalTextField.parse("869.525") == 869.525)
    #expect(DecimalTextField.parse(" 915 ") == 915)
    #expect(DecimalTextField.parse("433,") == 433)
  }

  @Test
  func `the Unicode minus parses as a sign`() {
    #expect(DecimalTextField.parse("\u{2212}1,5") == -1.5)
    #expect(DecimalTextField.parse("-1.5") == -1.5)
  }

  @Test
  func `text that is not a finite number parses to nil`() {
    #expect(DecimalTextField.parse("") == nil)
    #expect(DecimalTextField.parse(",") == nil)
    #expect(DecimalTextField.parse("1.234,5") == nil)
    #expect(DecimalTextField.parse("abc") == nil)
    #expect(DecimalTextField.parse("inf") == nil)
    #expect(DecimalTextField.parse("nan") == nil)
  }

  @Test
  func `formatting uses a point, no grouping, and round-trips through parse`() {
    #expect(DecimalTextField.format(869.525, fractionLength: 3) == "869.525")
    #expect(DecimalTextField.format(2400, fractionLength: 3) == "2400.000")
    #expect(DecimalTextField.format(nil, fractionLength: 3) == "")
    #expect(DecimalTextField.parse(DecimalTextField.format(869.525, fractionLength: 3)) == 869.525)
  }
}
