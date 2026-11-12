import SwiftUI

/// One line of text that scrolls sideways, as a ticker does, when it is too long for its space:
/// it rests at the start, glides to show the rest, and comes round again, with the edges faded so
/// the words slip in and out. Text that fits stays still. With Reduce Motion it truncates instead.
/// VoiceOver reads the whole text either way.
struct MarqueeText: View {
  let text: String
  var font: Font = .subheadline

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var textWidth: CGFloat = 0
  @State private var boxWidth: CGFloat = 0
  /// When the current text started scrolling, so new text starts again from its beginning.
  @State private var startDate = Date.now

  /// Points per second.
  private static let speed: CGFloat = 32
  /// The space between the end of the text and its next pass.
  private static let gap: CGFloat = 36
  /// How long it rests at the start of each pass.
  private static let pause: TimeInterval = 1.6
  private static let fadeWidth: CGFloat = 14

  private var scrolls: Bool {
    !reduceMotion && textWidth > boxWidth + 1 && boxWidth > 0
  }

  var body: some View {
    // Sizes the row: one line, as tall as the text, as wide as it is given.
    Text(text)
      .font(font)
      .lineLimit(1)
      .truncationMode(.tail)
      .opacity(scrolls ? 0 : 1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
      .background(alignment: .leading) {
        Text(text)
          .font(font)
          .lineLimit(1)
          .fixedSize()
          .hidden()
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
      }
      .overlay(alignment: .leading) {
        if scrolls {
          TimelineView(.animation) { context in
            HStack(spacing: Self.gap) {
              Text(text)
              Text(text)
            }
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .offset(x: offset(at: context.date))
          }
          // A fixed width: a flexible frame grows to fit text wider than it, and wouldn't clip.
          .frame(width: boxWidth, alignment: .leading)
          .clipped()
          .mask(edgeFade)
        }
      }
      // Nothing of the moving text draws outside the line, whatever its parent does.
      .clipShape(.rect)
      .onChange(of: text) { startDate = .now }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
  }

  /// Where the text sits `date` into its loop: still for the pause, then sliding left until the
  /// copy behind it is where it started, which is the next pass's start.
  private func offset(at date: Date) -> CGFloat {
    let travel = textWidth + Self.gap
    let loop = Self.pause + Double(travel / Self.speed)
    let into = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: loop)
    guard into > Self.pause else { return 0 }
    return -CGFloat(into - Self.pause) * Self.speed
  }

  private var edgeFade: some View {
    HStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
        .frame(width: Self.fadeWidth)
      Rectangle()
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: Self.fadeWidth)
    }
  }
}
