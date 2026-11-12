import SwiftUI

/// The footnote a radio page shows when its read from the radio failed, so the values on it are
/// known to be the last ones the app holds rather than fresh (as Device Info's "Radio didn't
/// answer"). Pages keep their `try?` reads but remember the outcome in a flag that shows this.
struct RadioReadFootnote: View {
  var body: some View {
    Label(L10n.Settings.Radio.readFailed, systemImage: "exclamationmark.arrow.circlepath")
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
      .accessibilityIdentifier("radio.readFailed")
  }
}

#Preview {
  RadioReadFootnote()
    .padding()
}
