@testable import Cairn
import Testing

@Suite("BLEPinInput")
struct BLEPinInputTests {
  private let range: ClosedRange<UInt32> = 100_000...999_999

  @Test
  func `Sanitizing keeps six ASCII digits`() {
    #expect(BLEPinInput.sanitized("12a3 4-5678") == "123456")
    #expect(BLEPinInput.sanitized("١٢٣") == "")
  }

  @Test
  func `Validation requires exactly six digits within range`() {
    #expect(BLEPinInput.validatedPin("654321", allowed: range) == 654_321)
    #expect(BLEPinInput.validatedPin("012345", allowed: range) == nil)
    #expect(BLEPinInput.validatedPin("12345", allowed: range) == nil)
    #expect(BLEPinInput.validatedPin("1234567", allowed: range) == nil)
    #expect(BLEPinInput.validatedPin("12e456", allowed: range) == nil)
  }

  @Test
  func `Display zero-pads without grouping`() {
    #expect(BLEPinInput.display(123_456) == "123456")
    #expect(BLEPinInput.display(42) == "000042")
  }
}
