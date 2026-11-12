import SwiftUI

/// A small "i" that explains the control or section it sits beside, in place of a footer
/// paragraph. Tapping it shows the explanation in a popover (a popover on iPhone too, so it stays
/// next to what it explains). Use it where text is needed to understand a setting but would
/// otherwise push the controls down the page.
struct InfoButton: View {
  let title: String?
  let message: String
  @State private var isPresented = false

  init(_ message: String, title: String? = nil) {
    self.title = title
    self.message = message
  }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Image(systemName: "info.circle")
        .font(.body)
        .foregroundStyle(Color.accentColor)
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title.map { L10n.Localizable.Common.moreInfoAbout($0) } ?? L10n.Localizable.Common.moreInfo)
    .accessibilityHint(message)
    .popover(isPresented: $isPresented, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 6) {
        if let title {
          Text(title)
            .font(.headline)
        }
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding()
      .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
      .presentationCompactAdaptation(.popover)
    }
  }
}

/// A section or card header with an `InfoButton` after the title.
struct InfoHeader: View {
  let title: String
  let info: String

  init(_ title: String, info: String) {
    self.title = title
    self.info = info
  }

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
      InfoButton(info, title: title)
        .textCase(nil)
    }
  }
}
