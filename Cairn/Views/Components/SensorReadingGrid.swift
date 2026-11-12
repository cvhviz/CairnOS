import SwiftUI

/// Lays its items out on as few lines as hold them, and spreads them evenly over those lines rather
/// than filling each line before starting the next: five that fit four to a line go three and two, four
/// that fit three go two and two, so a reading is never left alone on a line of its own. Each item keeps
/// its own width, so one long reading ("-12° / 145°" while the radio moves) costs only its own room, not
/// every column's. Each line is justified (the user, 2026-11-09): its first item flush left, its last
/// flush right, the ones between evenly apart; a lone item flush left, as the first of a line is (the
/// user, 2026-11-09: a reading alone in the middle of a card looked stranded).
struct BalancedGridLayout: Layout {
  var spacing: CGFloat = 12
  var lineSpacing: CGFloat = 8
  /// Flush left in columns instead of justified (the node headers; the user, 2026-11-09: two sensors,
  /// one at each edge, looked stranded): each line's items start at the same column positions, each
  /// column as wide as its widest item, `spacing` apart. A table too wide for the space falls back to
  /// each line's items `spacing` apart from the left.
  var leading = false

  /// Which items go on each line: the fewest lines whose items fit `width` with `spacing` between
  /// them, the count spread evenly (the longer lines first). One item to a line when nothing fits.
  static func lines(widths: [CGFloat], width: CGFloat, spacing: CGFloat) -> [Range<Int>] {
    let count = widths.count
    guard count > 0 else { return [] }
    for lineCount in 1...count {
      let base = count / lineCount, extra = count % lineCount
      var ranges: [Range<Int>] = []
      var start = 0
      for line in 0..<lineCount {
        let size = base + (line < extra ? 1 : 0)
        ranges.append(start..<start + size)
        start += size
      }
      let fits = ranges.allSatisfy { range in
        range.map { widths[$0] }.reduce(0, +) + spacing * CGFloat(range.count - 1) <= width
      }
      if fits || !width.isFinite { return ranges }
    }
    return (0..<count).map { $0..<$0 + 1 }
  }

  private func widths(_ subviews: Subviews) -> [CGFloat] {
    subviews.map { $0.sizeThatFits(.unspecified).width }
  }

  private func heights(_ lines: [Range<Int>], _ subviews: Subviews) -> [CGFloat] {
    lines.map { line in line.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = widths(subviews)
    let available = proposal.width ?? .infinity
    let lines = Self.lines(widths: w, width: available, spacing: spacing)
    let lineHeights = heights(lines, subviews)
    let height = lineHeights.reduce(0, +) + lineSpacing * CGFloat(max(0, lineHeights.count - 1))
    let natural = lines.map { line in line.map { w[$0] }.reduce(0, +) + spacing * CGFloat(line.count - 1) }.max() ?? 0
    return CGSize(width: available.isFinite ? available : natural, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let w = widths(subviews)
    let lines = Self.lines(widths: w, width: bounds.width, spacing: spacing)
    let lineHeights = heights(lines, subviews)
    if leading {
      placeLeading(lines: lines, widths: w, lineHeights: lineHeights, in: bounds, subviews: subviews)
      return
    }
    var y = bounds.minY
    for (index, line) in lines.enumerated() {
      let used = line.map { w[$0] }.reduce(0, +)
      // justified: the first flush left, the last flush right, the ones between evenly apart (a lone
      // one flush left); never closer than `spacing`
      let gap = line.count > 1 ? max(spacing, (bounds.width - used) / CGFloat(line.count - 1)) : 0
      var x = bounds.minX
      for item in line {
        subviews[item].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
        x += w[item] + gap
      }
      y += lineHeights[index] + lineSpacing
    }
  }
}

extension BalancedGridLayout {
  /// The leading layout's columns: where each column starts, from the widest item in it; nil when the
  /// table doesn't fit the width.
  static func columnStarts(lines: [Range<Int>], widths: [CGFloat], width: CGFloat, spacing: CGFloat) -> [CGFloat]? {
    let columns = lines.map(\.count).max() ?? 0
    var columnWidths = [CGFloat](repeating: 0, count: columns)
    for line in lines {
      for (column, item) in line.enumerated() {
        columnWidths[column] = max(columnWidths[column], widths[item])
      }
    }
    var starts: [CGFloat] = []
    var x: CGFloat = 0
    for columnWidth in columnWidths {
      starts.append(x)
      x += columnWidth + spacing
    }
    return x - spacing <= width ? starts : nil
  }

  fileprivate func placeLeading(
    lines: [Range<Int>], widths w: [CGFloat], lineHeights: [CGFloat], in bounds: CGRect, subviews: Subviews
  ) {
    let starts = Self.columnStarts(lines: lines, widths: w, width: bounds.width, spacing: spacing)
    var y = bounds.minY
    for (index, line) in lines.enumerated() {
      var x = bounds.minX
      for (column, item) in line.enumerated() {
        if let starts { x = bounds.minX + starts[column] }
        subviews[item].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
        x += w[item] + spacing
      }
      y += lineHeights[index] + lineSpacing
    }
  }
}

/// One sensor reading for `SensorReadingGrid`: its name, its value and a glyph.
struct SensorReadingItem: Identifiable, Equatable {
  let id: String
  let label: String
  let value: String
  let systemImage: String
  /// The glyph's colour, when the reading has a meaning of its own (a climb green, a descent orange);
  /// nil takes the grid's colour for its kind of reading.
  var tint: Color?

  /// A radio's readings as the grid shows them: every chip but a GPS fix (the page shows the position
  /// its own way), the channel named with the reading when there are several. `idPrefix` keeps two
  /// pages' identifiers apart.
  static func items(from groups: [DeviceSensorChipGroup], idPrefix: String = "") -> [SensorReadingItem] {
    groups.flatMap { group in
      group.chips.compactMap { chip -> SensorReadingItem? in
        if case .gps = chip.kind { return nil }
        return SensorReadingItem(
          id: idPrefix + chip.id,
          label: group.title.map { NodeRouteFormat.joined([chip.label, $0]) } ?? chip.label,
          value: chip.value,
          systemImage: chip.systemImage
        )
      }
    }
  }
}

/// A radio's or node's sensor readings as an even grid (`BalancedGridLayout`): each one's name small
/// above its value and glyph, the value as Home's sunrise and sunset line has its times. Home's header
/// and every node header (Device Info's included) show them this way.
struct SensorReadingGrid: View {
  let items: [SensorReadingItem]
  /// Flush left in columns rather than justified edge to edge (`BalancedGridLayout.leading`).
  var leading = false

  var body: some View {
    BalancedGridLayout(spacing: leading ? 24 : 12, lineSpacing: 8, leading: leading) {
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 2) {
          Text(item.label)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Label {
            Text(item.value)
              .monospacedDigit()
          } icon: {
            Image(systemName: item.systemImage)
              .foregroundStyle(item.tint ?? Self.tint(for: item.systemImage))
          }
          .font(.footnote.weight(.medium))
          .foregroundStyle(HomeCardDetail.ink)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.value)
        .accessibilityIdentifier("node.card.\(item.id)")
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// A colour per kind of reading, so a glance finds the one it wants: warm for heat, blue for water
  /// and air, the compass teal, movement green.
  static func tint(for systemImage: String) -> Color {
    switch systemImage {
    case "thermometer.medium": .red
    case "humidity", "barometer": .cyan
    case "location.north.line", "level", "move.3d", "gyroscope": .teal
    case "figure.walk", "figure.walk.motion", "figure.stand": .green
    case "sun.max", "bolt", "bolt.horizontal", "powerplug", "bolt.batteryblock": .orange
    case "aqi.medium": .purple
    default: .secondary
    }
  }
}
