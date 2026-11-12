import SwiftUI
import UIKit

/// Shows a message's text in a selectable, read-only text view so part of it
/// can be copied. SwiftUI's `.textSelection` only copies the whole string on
/// iOS, and the bubble's own gestures would fight a selection anyway.
struct SelectTextSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  let text: String

  var body: some View {
    NavigationStack {
      SelectableTextView(text: text)
        .themedCanvas(theme)
        .flashingNavigationTitle(L10n.Chats.Chats.Message.Action.selectText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Chats.Chats.Common.done) { dismiss() }
            .keyboardShortcut(.defaultAction)
          }
        }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct SelectableTextView: UIViewRepresentable {
  let text: String

  private static let inset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.textContainerInset = Self.inset
    textView.alwaysBounceVertical = true
    // Links stay plain text: tapping here should place a selection, not navigate.
    textView.dataDetectorTypes = []
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    if textView.text != text {
      textView.text = text
    }
  }
}
