import SwiftUI

private let pillSpacing: CGFloat = 8
private let barHorizontalPadding: CGFloat = 16
private let barTopPadding: CGFloat = -4
private let barBottomPadding: CGFloat = 8
/// The segmented `Picker` has no intrinsic vertical padding, so the glass pills' negative top
/// inset would clip its top edge. It gets a positive inset matching the bottom for even spacing.
private let segmentedTopPadding: CGFloat = 8
private let regularPillHorizontalPadding: CGFloat = 14
private let regularPillVerticalPadding: CGFloat = 6
private let largePillHorizontalPadding: CGFloat = 18
private let largePillVerticalPadding: CGFloat = 9
private let dimmedOpacity: Double = 0.5
private let minimumPillHitHeight: CGFloat = 44
/// Hueless tint marking the selected pill, flipped by color scheme (darker in light, lighter in
/// dark) so the selection holds contrast on every theme canvas without a hue that clashes with one.
private let selectedSegmentTintLight = Color.black.opacity(0.12)
private let selectedSegmentTintDark = Color.white.opacity(0.16)

/// Pinned filter bar that renders as Liquid Glass capsule pills on iOS 26 and
/// falls back to a standard segmented `Picker` on iOS 18.
///
/// Designed to be hosted via `.safeAreaInset(edge: .top)` so list content
/// scrolls behind the glass on iOS 26.
struct GlassFilterBar<Filter: Hashable & CaseIterable & Sendable>: View
  where Filter.AllCases: RandomAccessCollection {
  /// Pill sizing. `regular` is the compact default for the chat/contact filters;
  /// `large` gives the roomier pills used by the node management sheet.
  enum Size {
    case regular
    case large

    var horizontalPadding: CGFloat {
      switch self {
      case .regular: regularPillHorizontalPadding
      case .large: largePillHorizontalPadding
      }
    }

    var verticalPadding: CGFloat {
      switch self {
      case .regular: regularPillVerticalPadding
      case .large: largePillVerticalPadding
      }
    }

    var font: Font {
      switch self {
      case .regular: .subheadline
      case .large: .callout
      }
    }

    var controlSize: ControlSize {
      switch self {
      case .regular: .regular
      case .large: .large
      }
    }
  }

  @Binding var selection: Filter
  let isSearching: Bool
  let pickerLabel: String
  let title: @Sendable (Filter) -> String
  var size: Size = .regular
  /// Another bar's titles, by position: each pill is as wide as the wider of its own title and
  /// the one at its index here, so two bars that swap in place (Saved and Heard) line up.
  var matchingTitles: [String] = []
  /// A standard segmented control on every iOS, in place of the glass pills: for a bar whose
  /// segments should read as one control (the Nodes tab's).
  var alwaysSegmented = false

  @Namespace private var glassNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  private var selectedSegmentTint: Color {
    colorScheme == .dark ? selectedSegmentTintDark : selectedSegmentTintLight
  }

  var body: some View {
    Group {
      if #available(iOS 26.0, *), !alwaysSegmented {
        glassPills
      } else {
        segmentedFallback
      }
    }
    .opacity(isSearching ? dimmedOpacity : 1.0)
    .disabled(isSearching)
  }

  @available(iOS 26.0, *)
  private var glassPills: some View {
    ViewThatFits(in: .horizontal) {
      pillsRow
      ScrollView(.horizontal, showsIndicators: false) {
        pillsRow
      }
      .scrollClipDisabled()
    }
    // Leading whether the pills fit or scroll, so a bar with fewer pills starts where one with
    // more does.
    .frame(maxWidth: .infinity, alignment: .leading)
    // Scope the pill morph to the bar so it doesn't leak a transaction into consumer
    // content (a list's row transitions would otherwise animate on every filter tap).
    .animation(reduceMotion ? nil : .smooth, value: selection)
  }

  @available(iOS 26.0, *)
  private var pillsRow: some View {
    GlassEffectContainer(spacing: pillSpacing) {
      HStack(spacing: pillSpacing) {
        ForEach(Array(Filter.allCases.enumerated()), id: \.element) { index, filter in
          pill(for: filter, matching: index < matchingTitles.count ? matchingTitles[index] : nil)
        }
      }
      .padding(.horizontal, barHorizontalPadding)
      .padding(.top, barTopPadding)
      .padding(.bottom, barBottomPadding)
    }
  }

  @available(iOS 26.0, *)
  @ViewBuilder
  private func pill(for filter: Filter, matching: String?) -> some View {
    let isSelected = selection == filter
    Button {
      selection = filter
    } label: {
      // Sized by hidden semibold copies: the pill keeps its width when selected, and matches
      // the other bar's pill at this position.
      ZStack {
        Text(title(filter)).fontWeight(.semibold).hidden()
        if let matching {
          Text(matching).fontWeight(.semibold).hidden()
        }
        Text(title(filter))
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(.primary)
      }
        .lineLimit(1)
        .font(size.font)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(
      isSelected ? .regular.tint(selectedSegmentTint).interactive() : .regular.interactive(),
      in: .capsule
    )
    .glassEffectID(filter, in: glassNamespace)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    // Invisible and behind the pill: it overflows above and below to give a 44 pt tall
    // target while the glass capsule and the bar keep their compact height. A content
    // shape cannot do this, since hit testing clips it to the button's own frame.
    .background {
      Button {
        selection = filter
      } label: {
        Color.clear
          .frame(minHeight: minimumPillHitHeight)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)
    }
  }

  private var segmentedFallback: some View {
    Picker(pickerLabel, selection: $selection) {
      ForEach(Filter.allCases, id: \.self) { filter in
        Text(title(filter)).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .controlSize(size.controlSize)
    .padding(.horizontal, barHorizontalPadding)
    .padding(.top, segmentedTopPadding)
    .padding(.bottom, barBottomPadding)
  }
}

extension View {
  /// Opaque themed canvas on iOS 18, where the fallback segmented `Picker` is
  /// transparent. iOS 26 glass pills already carry their own material.
  @ViewBuilder
  func pinnedFilterHeaderBackground(_ theme: Theme) -> some View {
    if #available(iOS 26.0, *) {
      self
    } else {
      background(theme.canvasColor ?? Color(.systemBackground))
    }
  }
}

private enum FilterBarPreviewFilter: String, CaseIterable {
  case all, unread, dms, channels, rooms

  var label: String {
    switch self {
    case .all: "All"
    case .unread: "Unread"
    case .dms: "DMs"
    case .channels: "Channels"
    case .rooms: "Rooms"
    }
  }
}

#Preview {
  @Previewable @State var selection = FilterBarPreviewFilter.all

  List(0..<20) { row in
    Text("Row \(row)")
  }
  .safeAreaInset(edge: .top, spacing: 0) {
    GlassFilterBar(
      selection: $selection,
      isSearching: false,
      pickerLabel: "View",
      title: { $0.label }
    )
    .frame(maxWidth: .infinity)
  }
}
