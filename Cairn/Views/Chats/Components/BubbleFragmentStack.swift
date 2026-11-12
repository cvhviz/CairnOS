import CairnServices
import SwiftUI

/// The colored, clipped bubble box: text, optional footer, and optional inline
/// image. Reactions, malware warnings, and link previews are emitted as
/// siblings by `UnifiedMessageBubble.body` so they sit below the bubble box.
///
/// Conforms to `Equatable` on `item` and `bubbleColor` — the parent resolves
/// the contrast-aware color and passes it in so the env read doesn't
/// invalidate body on every visible cell. Closures and dynamic-type
/// environment changes propagate through the parent rebody path.
struct BubbleFragmentStack: View, Equatable {
  /// Corner radius for the bubble box, shared by the text-only shape-fill
  /// background, the inline-image clip path, and the context-menu lift shape
  /// applied by `UnifiedMessageBubble`.
  static let cornerRadius: CGFloat = 18

  let item: MessageItem
  /// The box-resident text and inline image from the shared partition.
  /// Excluded from `==` (which stays `item`/`bubbleColor`): it is a pure
  /// function of `item.content`, so equal items yield equal box fragments.
  let layout: FragmentLayout
  let bubbleColor: Color
  /// Color for the in-bubble send time. Passed in (not read from the theme
  /// environment) for the same reason as `bubbleColor`: keep body invalidation
  /// off the per-cell env-read path.
  let timeColor: Color
  let callbacks: MessageBubbleCallbacks
  let imageResolver: (ImageReference) -> UIImage?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  nonisolated static func == (lhs: BubbleFragmentStack, rhs: BubbleFragmentStack) -> Bool {
    lhs.item == rhs.item && lhs.bubbleColor == rhs.bubbleColor && lhs.timeColor == rhs.timeColor
  }

  private var hasFooter: Bool {
    item.footer.sendTimeToShow != nil
      || item.footer.showsRouteChip
      || item.footer.formattedPath != nil
      || item.footer.regionToShow != nil
      || item.footer.showStatusRow
  }

  /// The source URL when the inline image is parked at the scope-off
  /// tap-to-load placeholder. The placeholder carries its own material chrome
  /// and sits inside the padded content stack, so this case renders like a
  /// text-only bubble (shape fill, no edge-to-edge clip), never as an
  /// edge-to-edge `InlineImageFragmentView`.
  private var disabledImageURL: URL? {
    if case let .disabled(url) = layout.inlineImage?.state { url } else { nil }
  }

  /// Showing uses the translated string as plain `Text` so mention/hashtag runs are not applied.
  private func translationBody(_ textPayload: MessageTextPayload) -> Text {
    if case let .showing(translated, _) = textPayload.translation?.phase {
      Text(translated)
    } else {
      Text(textPayload.formatted ?? AttributedString(textPayload.raw))
    }
  }

  var body: some View {
    let stack = VStack(alignment: item.envelope.isOutgoing ? .trailing : .leading, spacing: 0) {
      // Stack alignment carries the footer placement: the time sits at the
      // bubble's trailing edge for outgoing, leading for incoming. Driving it
      // through alignment (rather than a greedy `Spacer`/`maxWidth`) keeps the
      // bubble hugging its content — a flexible-width child here leaves the
      // self-sizing hosting cell without a resolvable intrinsic width, which
      // SwiftUI surfaces as a fatal "invalid reuse after initialization failure".
      VStack(alignment: item.envelope.isOutgoing ? .trailing : .leading, spacing: 2) {
        if let chrome = layout.textPayload?.translation {
          BubbleTranslationControl(
            phase: chrome.phase,
            onTap: { callbacks.onTranslationAction?() }
          )
        }
        if let textPayload = layout.textPayload, let quote = textPayload.replyQuote, !textPayload.isShowingTranslation {
          BubbleReplyQuote(
            quote: quote,
            header: textPayload.replyHeader,
            isOutgoing: item.envelope.isOutgoing,
            onTap: callbacks.onReplyQuoteTap
          )
        }
        if let textPayload = layout.textPayload, textPayload.hasVisibleBody {
          // Native `Text`: the precomputed `formatted` string already carries every run's color,
          // underline, bold, and `.link`, so link taps route through the injected `\.openURL` and
          // Dynamic Type scales for free. `foregroundStyle` colors the raw fallback when unformatted.
          translationBody(textPayload)
            .font(.body)
            .foregroundStyle(textPayload.baseColor.swiftUIColor)
        }

        if let disabledImageURL {
          TapToLoadPreview(
            url: disabledImageURL,
            isLoading: false,
            onTap: { callbacks.onManualPreviewFetch?() }
          )
        }

        if hasFooter {
          BubbleFooterRow(
            footer: item.footer,
            dynamicTypeSize: dynamicTypeSize,
            timeColor: timeColor,
            onRetry: callbacks.onRetry,
            onSendAgain: callbacks.onSendAgain
          )
        }
      }
      .bubbleContentPadding()

      if let inlineImage = layout.inlineImage, disabledImageURL == nil {
        InlineImageFragmentView(
          inlineImage: inlineImage,
          isOutgoing: item.envelope.isOutgoing,
          imageResolver: imageResolver,
          onTap: { callbacks.onImageTap?() },
          onRetry: { callbacks.onRetryInlineImage?() }
        )
      }
    }

    if layout.inlineImage == nil || disabledImageURL != nil {
      // Text-only bubbles (and the scope-off tap-to-load placeholder) draw
      // their surface in the rounded shape directly, which avoids the mask
      // `.clipShape` installs and its offscreen render pass per bubble while
      // scrolling.
      stack.background { BubbleBackground(color: bubbleColor, isTinted: item.envelope.isOutgoing) }
    } else {
      // Image bubbles keep the clip so the edge-to-edge image inherits the
      // rounded corners.
      stack
        .background { BubbleBackground(color: bubbleColor, isTinted: item.envelope.isOutgoing) }
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
    }
  }
}

/// A message bubble's surface: Liquid Glass on iOS 26, lightly tinted with the bubble's colour for
/// the user's own messages so they keep the accent and their white text, clear for incoming ones.
/// Reduce Transparency and earlier systems keep the solid fill; Increase Contrast rims the glass,
/// as it does a glass card.
struct BubbleBackground: View {
  let color: Color
  let isTinted: Bool

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private static let contrastStrokeOpacity = 0.35
  /// How much of the bubble's colour tints the user's own glass: enough to read as theirs and to
  /// keep white text legible, light enough that the glass shows through.
  private static let tintOpacity = 0.7

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: BubbleFragmentStack.cornerRadius, style: .continuous)
  }

  var body: some View {
    if #available(iOS 26.0, *), !reduceTransparency {
      Color.clear
        .glassEffect(isTinted ? .regular.tint(color.opacity(Self.tintOpacity)) : .regular, in: shape)
        .overlay {
          if contrast == .increased {
            shape.strokeBorder(Color.primary.opacity(Self.contrastStrokeOpacity), lineWidth: 1)
          }
        }
    } else {
      shape.fill(color)
    }
  }
}

extension MessageTextPayload {
  /// The in-bubble translation is showing; it replaces the whole text, quote included.
  var isShowingTranslation: Bool {
    if case .showing = translation?.phase { true } else { false }
  }

  /// A reply that is only its quote has no text line under the quote block.
  var hasVisibleBody: Bool {
    guard replyQuote != nil, !isShowingTranslation else { return true }
    return !(formatted.map { $0.characters.isEmpty } ?? raw.isEmpty)
  }
}

private extension BaseColorSlot {
  /// Resolves the direction-tagged slot to a concrete SwiftUI `Color` at render time. Outgoing
  /// bubbles render on a filled background and need white text; incoming bubbles use the system
  /// primary colour. Lives in the Cairn layer because CairnServices intentionally has no SwiftUI
  /// dependency.
  var swiftUIColor: Color {
    switch self {
    case .outgoing: .white
    case .incoming: .primary
    }
  }
}
