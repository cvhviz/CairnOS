import CairnServices
import SwiftUI

/// The quoted part of a MeshCore reply (`@[Name]\n>quote..\n`), drawn as a block at the top of
/// the bubble: an accent bar, the replied-to `@Name` styled and tappable like any mention, and
/// the quoted preview beneath it. The reply's own text follows as the bubble's normal text.
struct BubbleReplyQuote: View {
  let quote: ReplyQuote
  /// The `@Name` header pre-styled by the bake (mention colour and link); nil falls back to
  /// plain text.
  let header: AttributedString?
  let isOutgoing: Bool
  /// Jumps to the quoted message; nil draws the quote without a tap.
  var onTap: (() -> Void)?

  @Environment(\.appTheme) private var theme

  private static let barWidth: CGFloat = 3
  private static let cornerRadius: CGFloat = 10
  private static let maxQuoteLines = 3

  var body: some View {
    if let onTap {
      // A tap gesture rather than a Button, so the `@Name` header keeps its own mention link.
      quoteBlock
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L10n.Chats.Chats.Message.Reply.jumpHint)
        .accessibilityAction { onTap() }
    } else {
      quoteBlock
    }
  }

  private var quoteBlock: some View {
    HStack(alignment: .top, spacing: 8) {
      Capsule()
        .fill(barColor)
        .frame(width: Self.barWidth)

      VStack(alignment: .leading, spacing: 1) {
        Text(header ?? AttributedString("@" + MessageText.displayName(for: quote.mentionName)))
          .font(.caption.weight(.semibold))
          .foregroundStyle(isOutgoing ? theme.outgoingTextColor : Color.primary)
        Text(quote.quotedText)
          .font(.caption)
          .foregroundStyle(quoteColor)
          .lineLimit(Self.maxQuoteLines)
      }
      .frame(minWidth: 0, alignment: .leading)
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 5)
    .padding(.leading, 6)
    .padding(.trailing, 10)
    .background(backgroundStyle, in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
    .padding(.bottom, 2)
    .contentShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.Chats.Chats.Message.Reply.accessibilityLabel(
      MessageText.displayName(for: quote.mentionName),
      quote.quotedText
    ))
  }

  private var barColor: Color {
    isOutgoing ? theme.outgoingTextColor.opacity(0.8) : theme.accentColor
  }

  private var quoteColor: Color {
    isOutgoing ? theme.outgoingTextColor.opacity(0.8) : .secondary
  }

  private var backgroundStyle: AnyShapeStyle {
    isOutgoing
      ? AnyShapeStyle(theme.outgoingTextColor.opacity(0.15))
      : AnyShapeStyle(.quaternary)
  }
}
