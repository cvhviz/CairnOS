import SwiftUI

extension View {
  /// Applies the shared styling for a map control toolbar button: a fixed
  /// 44pt icon-only tappable square with a medium-weight glyph and the given tint.
  /// `caption` is a short word under the glyph, on the maps people open most.
  @ViewBuilder
  func mapControlButton(tint: Color, caption: String? = nil) -> some View {
    if let caption {
      font(.body.weight(.medium))
        .foregroundStyle(tint)
        .frame(width: MapControlButtonMetrics.captionedWidth, height: MapControlButtonMetrics.captionedHeight)
        .contentShape(.rect)
        .buttonStyle(.plain)
        .labelStyle(MapControlCaptionLabelStyle(caption: caption))
    } else {
      font(.body.weight(.medium))
        .foregroundStyle(tint)
        .frame(width: MapControlButtonMetrics.size, height: MapControlButtonMetrics.size)
        .contentShape(.rect)
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
    }
  }
}

/// A map control's glyph over its short word. VoiceOver reads the button's full name, not the word.
struct MapControlCaptionLabelStyle: LabelStyle {
  let caption: String

  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 2) {
      configuration.icon
      MapControlCaption(text: caption)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel { _ in configuration.title }
  }
}

/// The short word under a map control's glyph, for a button whose label isn't a `Label`.
struct MapControlCaption: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}

private enum MapControlButtonMetrics {
  static let size: CGFloat = 44
  static let captionedWidth: CGFloat = 56
  static let captionedHeight: CGFloat = 50
}
