import SwiftUI

/// How many tiles go in each row. Pure, so the arithmetic is tested without a view.
enum TileRowPlanner {
  /// Columns of at least `minimumTileWidth` that fit in `width`, never fewer than one. A width
  /// that isn't finite (an ideal-size proposal) or a tile wider than the room gives one column.
  static func columnsThatFit(width: CGFloat, minimumTileWidth: CGFloat, spacing: CGFloat) -> Int {
    let columns = (width + spacing) / (minimumTileWidth + spacing)
    guard minimumTileWidth > 0, columns.isFinite else { return 1 }
    return max(1, Int(columns))
  }

  /// Tiles per row for `count` tiles with room for `maxColumns`: as few rows as fit, with the
  /// tiles spread evenly over them (six in four columns: 3 + 3, not 4 + 2). Any remainder sits
  /// in the last row, which the layout stretches to the full width.
  static func rowSizes(count: Int, maxColumns: Int) -> [Int] {
    guard count > 0 else { return [] }
    let fit = max(1, maxColumns)
    let rows = (count + fit - 1) / fit
    let perRow = (count + rows - 1) / rows
    var sizes: [Int] = []
    var remaining = count
    while remaining > 0 {
      let size = min(perRow, remaining)
      sizes.append(size)
      remaining -= size
    }
    return sizes
  }
}

/// Lays subviews out in the rows `TileRowPlanner` plans, splitting each row's width equally and
/// giving every tile in a row the tallest tile's height.
struct JustifiedTileLayout: Layout {
  var minimumTileWidth: CGFloat
  var spacing: CGFloat
  var singleColumn: Bool
  /// At most this many columns; nil for as many as fit.
  var maxColumns: Int?
  /// Offered more height than the rows need, take it all and share the rest out evenly over the
  /// rows, so the tiles reach the bottom of a column that fills the screen.
  var fillsHeight = false

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    // A stack sizing its children ideally proposes an infinite width: answer with the fallback.
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? fallbackWidth
    let height = Self.height(of: measuredRows(width: width, subviews: subviews), spacing: spacing)
    if fillsHeight, let offered = proposal.height, offered.isFinite, offered > height {
      return CGSize(width: width, height: offered)
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    let rows = measuredRows(width: bounds.width, subviews: subviews)
    let extra = fillsHeight && !rows.isEmpty
      ? max(0, bounds.height - Self.height(of: rows, spacing: spacing)) / CGFloat(rows.count)
      : 0
    var y = bounds.minY
    for row in rows {
      var x = bounds.minX
      let height = row.height + extra
      for index in row.indices {
        subviews[index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(width: row.tileWidth, height: height)
        )
        x += row.tileWidth + spacing
      }
      y += height + spacing
    }
  }

  private static func height(of rows: [Row], spacing: CGFloat) -> CGFloat {
    rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
  }

  private var fallbackWidth: CGFloat {
    singleColumn ? minimumTileWidth : minimumTileWidth * 2 + spacing
  }

  private struct Row {
    let indices: Range<Int>
    let tileWidth: CGFloat
    let height: CGFloat
  }

  private func measuredRows(width: CGFloat, subviews: Subviews) -> [Row] {
    let fit = singleColumn
      ? 1
      : TileRowPlanner.columnsThatFit(width: width, minimumTileWidth: minimumTileWidth, spacing: spacing)
    let maxColumns = min(fit, max(1, self.maxColumns ?? fit))
    var rows: [Row] = []
    var start = 0
    for size in TileRowPlanner.rowSizes(count: subviews.count, maxColumns: maxColumns) {
      let indices = start..<(start + size)
      let tileWidth = max(0, (width - spacing * CGFloat(size - 1)) / CGFloat(size))
      let height = indices
        .map { subviews[$0].sizeThatFits(ProposedViewSize(width: tileWidth, height: nil)).height }
        .max() ?? 0
      rows.append(Row(indices: indices, tileWidth: tileWidth, height: height))
      start += size
    }
    return rows
  }
}
