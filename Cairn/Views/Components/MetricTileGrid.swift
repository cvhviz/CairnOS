import SwiftUI

/// Lays out tiles in balanced rows with no holes: as many equal columns as fit (two on a phone,
/// more on iPad and Mac), the tiles spread evenly over as few rows as possible (five in two
/// columns: 2 + 2 + 1), and a short last row stretched to the full width, so an odd count never
/// leaves an empty cell. One column at accessibility text sizes so values never truncate. Tiles
/// in a row share the tallest tile's height. Not lazy: for small groups of tiles. Long collections
/// (node cards) use `LazyCardGrid`.
struct MetricTileGrid<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title3) private var minimumTileWidth: CGFloat = 150
  /// At most this many columns, however wide (the Dashboard's side column on iPad); nil for as
  /// many as fit.
  let maxColumns: Int?
  /// The rows share out any height offered beyond their own, so the tiles reach the bottom of a
  /// column that fills the screen (the Dashboard's side column on iPad).
  let fillsHeight: Bool
  @ViewBuilder let content: () -> Content

  init(maxColumns: Int? = nil, fillsHeight: Bool = false, @ViewBuilder content: @escaping () -> Content) {
    self.maxColumns = maxColumns
    self.fillsHeight = fillsHeight
    self.content = content
  }

  var body: some View {
    JustifiedTileLayout(
      minimumTileWidth: minimumTileWidth,
      spacing: CardStyle.spacing,
      singleColumn: dynamicTypeSize.isAccessibilitySize,
      maxColumns: maxColumns,
      fillsHeight: fillsHeight
    ) {
      content()
    }
    // Tiles stay cards in a Settings section, beside its grouped rows rather than in them.
    .settingsStandalone()
  }
}

/// A lazy grid of equal-width cards for long collections (node lists in card mode), where building
/// every card up front would be too slow. A short last row keeps its empty cells here.
struct LazyCardGrid<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title3) private var minimumTileWidth: CGFloat = 150
  @ViewBuilder let content: () -> Content

  init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: CardStyle.spacing) {
      content()
    }
    .settingsStandalone()
  }

  private var columns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return [GridItem(.flexible(), spacing: CardStyle.spacing)]
    }
    return [GridItem(.adaptive(minimum: minimumTileWidth), spacing: CardStyle.spacing, alignment: .top)]
  }
}

/// A grid of tiles placed in a `List`, the way the radio dashboard sits at the top of Settings.
///
/// The tiles go in a section header rather than a row: a row is clipped to the list's rounded row
/// shape, which cuts the corners off the tiles, and a row's background would draw a second card
/// behind them. An optional title sits above the tiles like a normal section header, and an
/// optional footer below them like a normal section footer.
struct MetricTileSection<Content: View>: View {
  let title: String?
  /// An explanation behind an `InfoButton` beside the title, in place of a footer paragraph.
  let info: String?
  let footer: String?
  @ViewBuilder let content: () -> Content

  init(
    _ title: String? = nil,
    info: String? = nil,
    footer: String? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.info = info
    self.footer = footer
    self.content = content
  }

  var body: some View {
    Section {
    } header: {
      VStack(alignment: .leading, spacing: 8) {
        if let title {
          // Keeps the list's own header styling, inset to line up with the other headers.
          Group {
            if let info {
              InfoHeader(title, info: info)
            } else {
              Text(title)
            }
          }
          .padding(.horizontal, 16)
          .accessibilityAddTraits(.isHeader)
        }
        MetricTileGrid(content: content)
          // Section headers dim their content, and a hierarchical `.primary` would resolve to that
          // dimmed color; tiles are content, not a caption, so they get the concrete label colors.
          .foregroundStyle(Color.primary)
          .textCase(nil)
      }
      .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
    } footer: {
      if let footer, !footer.isEmpty {
        Text(footer)
      }
    }
  }
}
