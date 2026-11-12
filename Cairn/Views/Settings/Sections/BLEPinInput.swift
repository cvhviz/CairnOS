import Foundation

/// Pure input handling for the six-digit BLE pairing PIN.
enum BLEPinInput {
  static let length = 6

  /// Keeps ASCII digits only, truncated to six characters.
  static func sanitized(_ text: String) -> String {
    String(text.filter { $0.isASCII && $0.isNumber }.prefix(length))
  }

  /// The PIN when `text` is exactly six digits inside `allowed`, else nil.
  static func validatedPin(_ text: String, allowed: ClosedRange<UInt32>) -> UInt32? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.count == length,
          trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
          let pin = UInt32(trimmed),
          allowed.contains(pin) else { return nil }
    return pin
  }

  /// Zero-padded six-digit display, without grouping separators.
  static func display(_ pin: UInt32) -> String {
    String(format: "%06u", pin)
  }
}
