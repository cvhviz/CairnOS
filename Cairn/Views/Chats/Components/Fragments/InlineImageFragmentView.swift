import CairnServices
import SwiftUI
import UIKit

/// Fragment-level view that renders the inline-image slot of a message bubble.
/// Reserves correct height before bytes arrive using `InlineImage.cachedAspect`
/// (falling back to 16:9), so the bubble does not jump when the image loads.
struct InlineImageFragmentView: View {
  let inlineImage: InlineImage
  let isOutgoing: Bool
  let imageResolver: (ImageReference) -> UIImage?
  let onTap: () -> Void
  let onRetry: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = RichPreviewMetrics.minHeroHeight
  @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = RichPreviewMetrics.maxHeroHeight
  @ScaledMetric(relativeTo: .subheadline) private var retryHeight: CGFloat = 44

  private static let crossFadeDuration: Double = 0.2
  private static let skeletonCornerRadius: CGFloat = RichPreviewMetrics.cornerRadius
  private static let retryIconSpacing: CGFloat = 8
  private static let retryForegroundOpacity: Double = 0.7

  private var aspect: Double {
    inlineImage.cachedAspect ?? RichPreviewMetrics.fallbackAspect
  }

  var body: some View {
    if isFailed {
      // A failed fetch has no bytes coming, so it drops the reserved hero
      // height and the loading shimmer for a compact retry row.
      retryLayer
        .frame(maxWidth: .infinity, minHeight: retryHeight)
    } else {
      // No card chrome here: the inline image is edge-to-edge in the bubble
      // box, which supplies the rounding and the surface, so the reserved
      // frame carries no corner clip or background of its own.
      RichPreviewCard(
        aspect: CGFloat(aspect),
        minHeight: minHeight,
        maxHeight: maxHeight
      ) {
        ZStack {
          PreviewSkeleton()
            .opacity(isLoaded ? 0 : 1)

          loadedLayer
            .opacity(isLoaded ? 1 : 0)
        }
      }
      .animation(
        reduceMotion ? nil : .easeOut(duration: Self.crossFadeDuration),
        value: isLoaded
      )
    }
  }

  private var isFailed: Bool {
    if case .failed = inlineImage.state { return true }
    return false
  }

  private var isLoaded: Bool {
    if case let .loaded(ref, _) = inlineImage.state,
       imageResolver(ref) != nil {
      return true
    }
    return false
  }

  @ViewBuilder
  private var loadedLayer: some View {
    if case let .loaded(ref, isGIF) = inlineImage.state,
       let image = imageResolver(ref) {
      InlineImageView(
        image: image,
        isGIF: isGIF,
        autoPlayGIFs: inlineImage.autoPlayGIFs,
        isEmbedded: true,
        onTap: onTap
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Outgoing bubbles are filled with the theme accent, so the retry row pairs with the
  /// theme's outgoing text color rather than a fixed white.
  private var retryForeground: AnyShapeStyle {
    isOutgoing
      ? AnyShapeStyle(theme.outgoingTextColor.opacity(Self.retryForegroundOpacity))
      : AnyShapeStyle(.secondary)
  }

  private var retryLayer: some View {
    Button(action: onRetry) {
      ZStack {
        RoundedRectangle(cornerRadius: Self.skeletonCornerRadius, style: .continuous)
          .fill(Color(.tertiarySystemFill))
        HStack(spacing: Self.retryIconSpacing) {
          Image(systemName: "arrow.clockwise")
            .foregroundStyle(retryForeground)
          Text(L10n.Chats.Chats.InlineImage.tapToRetry)
            .font(.subheadline)
            .foregroundStyle(retryForeground)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Chats.Chats.InlineImage.failedLabel)
    .accessibilityHint(L10n.Chats.Chats.InlineImage.retryHint)
  }
}
