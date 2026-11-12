// Cairn/Views/Chats/Components/FallbackMatchIndicatorView.swift
import SwiftUI

/// Tappable indicator showing a node name was resolved from a short prefix with multiple matches.
struct FallbackMatchIndicatorView: View {
  /// Hit-area growth around the small glyph. The button is padded and then negatively
  /// padded, so it overflows its slot and the surrounding text line keeps its layout.
  /// Kept short vertically because the indicator sits inline between other rows of text
  /// and controls.
  private static let horizontalHitSlop: CGFloat = 15
  private static let verticalHitSlop: CGFloat = 8

  let accessibilityLabel: String
  let accessibilityHint: String
  let title: String
  let explanation: String

  @State private var isShowingExplanation = false

  init(
    accessibilityLabel: String = L10n.Chats.Chats.Path.Hop.possibleMatch,
    accessibilityHint: String = L10n.Chats.Chats.Path.Hop.possibleMatchExplanation,
    title: String = L10n.Chats.Chats.Path.Hop.possibleMatchTitle,
    explanation: String = L10n.Chats.Chats.Path.Hop.possibleMatchExplanation
  ) {
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityHint = accessibilityHint
    self.title = title
    self.explanation = explanation
  }

  var body: some View {
    Button {
      isShowingExplanation = true
    } label: {
      Image(systemName: "questionmark.circle")
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.horizontalHitSlop)
        .padding(.vertical, Self.verticalHitSlop)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, -Self.horizontalHitSlop)
    .padding(.vertical, -Self.verticalHitSlop)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
    .popover(isPresented: $isShowingExplanation) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.headline)

        Text(explanation)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding()
      .frame(idealWidth: 280, maxWidth: 300)
      .presentationSizing(.fitted)
      .presentationCompactAdaptation(.popover)
    }
  }
}
