import SwiftUI

/// One of Home's status cards, after Cairn's: a small caption title beside a tinted glyph, an
/// optional pill (the unread count), and the card's own lines below. Shared chrome only; each card
/// supplies its content and what VoiceOver reads.
///
/// The card is one accessibility element named by its title, with `accessibilityValue` as its
/// reading and `hint` saying where it goes. Wrap it in the `Button` that opens the page.
struct HomeCard<Content: View, TitleDetail: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  var pill: String?
  /// The pill is a reading (Traffic's "2/min"), not a count to clear: drawn in the app theme's
  /// accent on a faint fill of it, rather than white on the card's tint as a badge is.
  var pillIsReading = false
  /// A state's own colour for the pill ("Fix" green, "Checking…" grey): drawn in it on a faint fill of it.
  var pillTint: Color?
  let accessibilityValue: String
  let hint: String
  /// The chevron and button trait, for a card that opens something. Off for a card that only reads.
  var opensPage = true
  /// A count right after the title, in the reading's ink ("NODES 4"): for a card whose figure is a
  /// small number that doesn't need a line of its own (the user, 2026-11-09).
  var titleCount: String?
  /// The count's colour: a state that has one ("Fix" green, "Checking…" grey) rather than a number.
  var titleCountTint: Color = .primary
  /// Small readings on the title row, between the title and the pill.
  @ViewBuilder var titleDetail: () -> TitleDetail
  @ViewBuilder let content: () -> Content

  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.caption.weight(.semibold))
          .textCase(.uppercase)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
          .fixedSize()
        if let titleCount {
          Text(titleCount)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(titleCountTint)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
        }
        Spacer(minLength: 0)
        titleDetail()
        if let pill {
          pillLabel(pill)
            .foregroundStyle(pillTint ?? (pillIsReading ? theme.accentColor : .white))
            .background(pillTint.map { $0.opacity(0.16) } ?? (pillIsReading ? theme.accentColor.opacity(0.16) : tint), in: Capsule())
            .contentTransition(.numericText())
        }
        // The row keeps a pill's height with or without one, so a count or a rate coming and going
        // doesn't move the card's lines (the user, 2026-11-07: the Dashboard's cards grew and shrank).
        pillLabel("0")
          .hidden()
          .frame(width: 0)
          .accessibilityHidden(true)
        if opensPage {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(.tertiaryLabel))
        }
      }

      content()
    }
    .cardSurface(padding: 12)
    .cardInteractionShape()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(hint)
    .accessibilityAddTraits(opensPage ? .isButton : [])
  }
}

extension HomeCard {
  /// A pill's text in its capsule's padding, without its colours.
  fileprivate func pillLabel(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.bold).monospacedDigit())
      .padding(.horizontal, 7)
      .padding(.vertical, 1)
      .lineLimit(1)
      .fixedSize()
  }
}

extension HomeCard where TitleDetail == EmptyView {
  init(
    title: String,
    systemImage: String,
    tint: Color,
    pill: String? = nil,
    pillTint: Color? = nil,
    accessibilityValue: String,
    hint: String,
    opensPage: Bool = true,
    titleCount: String? = nil,
    titleCountTint: Color = .primary,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      title: title,
      systemImage: systemImage,
      tint: tint,
      pill: pill,
      pillTint: pillTint,
      accessibilityValue: accessibilityValue,
      hint: hint,
      opensPage: opensPage,
      titleCount: titleCount,
      titleCountTint: titleCountTint,
      titleDetail: { EmptyView() },
      content: content
    )
  }
}

/// The card's loud line: a reading such as "78%" or "910.525 MHz", with an optional quieter
/// note beside it ("Good", "+4 new") that drops below when the two don't fit.
struct HomeCardValue: View {
  let value: String
  var valueTint: Color = .primary
  var note: String?
  var noteTint: Color = .secondary
  /// Draws what follows the decimal separator a size down, so a frequency reads by its whole
  /// megahertz: "910" large, ".525 MHz" smaller (the user, 2026-11-08).
  var shrinksFraction = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        valueText
          .fixedSize()
        noteText
          .fixedSize()
      }
      VStack(alignment: .leading, spacing: 0) {
        valueText
        noteText
      }
    }
  }

  private var valueText: some View {
    styledValue
      .font(.title2.weight(.bold).monospacedDigit())
      .foregroundStyle(valueTint)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
  }

  /// The value, its fraction and unit a size down when `shrinksFraction` and it has one.
  private var styledValue: Text {
    guard shrinksFraction,
          let separator = Locale.current.decimalSeparator,
          let split = value.range(of: separator) else { return Text(value) }
    let whole = String(value[..<split.lowerBound])
    let fraction = String(value[split.lowerBound...])
    return Text("\(Text(whole))\(Text(fraction).font(.headline.weight(.bold).monospacedDigit()))")
  }

  @ViewBuilder
  private var noteText: some View {
    if let note, !note.isEmpty {
      Text(note)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(noteTint)
        .lineLimit(1)
    }
  }
}

/// A detail line under a card's value: "SF7 · 250 kHz", "4.12 V", "Custom PIN". Sized and colored
/// to be read at a glance rather than squinted at: subheadline rather than footnote, digits that
/// don't jitter as readings change, and near-primary ink rather than the secondary grey, which
/// sat too faint on the cards in both appearances. Long lines (a preset such as "New Zealand
/// (Gisborne)", a node's name) wrap to a second line instead of losing their end.
struct HomeCardDetail: View {
  /// The ink for detail lines: quieter than the value, clearly stronger than `.secondary`.
  static let ink = Color.primary.opacity(0.75)

  private let parts: [String]
  private let tint: Color
  private let lineLimit: Int

  init(_ text: String, tint: Color = HomeCardDetail.ink, lineLimit: Int = 2) {
    parts = [text]
    self.tint = tint
    self.lineLimit = lineLimit
  }

  /// Facts that read best as one line ("SF7 · 250 kHz · CR 4/5"), split one to a line when the card
  /// is too narrow for them all, so no fact is cut off mid-word.
  init(parts: [String], tint: Color = HomeCardDetail.ink) {
    self.parts = parts.filter { !$0.isEmpty }
    self.tint = tint
    // A group of one (the preset's name) has nothing to split onto further lines, so it wraps
    // to a second line like a plain detail rather than losing its end.
    lineLimit = self.parts.count > 1 ? 1 : 2
  }

  var body: some View {
    Group {
      if parts.count > 1 {
        ViewThatFits(in: .horizontal) {
          line(NodeRouteFormat.joined(parts))
            .fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
              line(part)
            }
          }
        }
      } else {
        line(parts.first ?? "")
      }
    }
    .font(.subheadline.monospacedDigit())
    .foregroundStyle(tint)
  }

  private func line(_ text: String) -> some View {
    Text(text)
      .lineLimit(lineLimit)
      .minimumScaleFactor(0.85)
  }
}
