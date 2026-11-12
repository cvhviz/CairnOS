import CairnServices
import SwiftUI

/// Decimal entry that accepts either decimal separator and saves on every keystroke.
///
/// A `TextField(value:format:)` pinned to the POSIX locale rejects ",", the only separator the
/// decimal pad offers in comma-decimal regions, so a frequency such as 869,525 could not be typed.
struct DecimalTextField: View {
  let title: String
  let value: Double?
  var fractionLength = 3
  /// Called with nil while the text isn't a number.
  let onChange: (Double?) -> Void

  @State private var text = ""

  var body: some View {
    TextField(title, text: $text)
      .keyboardType(.decimalPad)
      .multilineTextAlignment(.trailing)
      .onAppear { text = Self.format(value, fractionLength: fractionLength) }
      // A reload changes the value from outside; show it unless it's what was typed.
      .onChange(of: value) { _, newValue in
        if Self.parse(text) != newValue { text = Self.format(newValue, fractionLength: fractionLength) }
      }
      .onChange(of: text) { _, newText in
        // Showing a value rounded for display isn't an edit and must not change it.
        guard newText != Self.format(value, fractionLength: fractionLength) else { return }
        let parsed = Self.parse(newText)
        if parsed != value { onChange(parsed) }
      }
  }

  static func format(_ value: Double?, fractionLength: Int) -> String {
    guard let value else { return "" }
    return value.formatted(.number.precision(.fractionLength(fractionLength)).grouping(.never).locale(.posix))
  }

  /// Accepts a comma decimal separator and the Unicode minus some keyboards and locales insert.
  static func parse(_ text: String) -> Double? {
    let normalized = text
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "\u{2212}", with: "-")
      .replacingOccurrences(of: ",", with: ".")
    guard let parsed = Double(normalized), parsed.isFinite else { return nil }
    return parsed
  }
}
