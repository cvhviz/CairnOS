import CoreGraphics
import Foundation
import MeshCore

// The radio's Channel view laid out for the device card: where a column, a dB row, a level band, a
// gridline, a mark and a density cell fall, in the firmware's own rules (`SpecChannelView`,
// `SpecPaint`, `SpecMath`), kept free of views so each is unit-tested on its own.

// MARK: - Layout

/// The device card's plot heights: the lane, the trace and the density, sharing one x.
struct SpectrumDeviceLayout: Equatable {
  /// Regular width (iPad, Mac): 240 columns and the taller trace and density.
  let regular: Bool
  /// Heights of their own (the full-screen plot, the Dashboard card); nil for the card's.
  var customTraceHeight: CGFloat?
  var customDensityHeight: CGFloat?
  /// The plot's outer corners (the trace panel's top, the bottom panel's bottom): the other
  /// styles' glass radius, so every style rounds the same.
  var cornerRadius: CGFloat = 12
  /// The corners where the trace and density panels meet.
  static let innerCornerRadius: CGFloat = 3

  init(regular: Bool) {
    self.regular = regular
  }

  /// The plot with these heights under its lane, however wide (the full-screen view takes the
  /// screen; the Dashboard card the trace alone, no density).
  init(traceHeight: CGFloat, densityHeight: CGFloat) {
    regular = false
    customTraceHeight = traceHeight
    customDensityHeight = densityHeight
  }

  static let laneHeight: CGFloat = 10
  /// Between the trace's panel and the density's.
  static let gap: CGFloat = 2
  /// The trace's data sits this far inside its panel, top and bottom (`TRACE_IN_Y`).
  static let traceInset: CGFloat = 2
  /// The density's rows sit this far inside its panel (`DENS_IN_Y`).
  static let densityInset: CGFloat = 1

  var traceHeight: CGFloat { customTraceHeight ?? (regular ? 180 : 140) }
  var densityHeight: CGFloat { customDensityHeight ?? (regular ? 144 : 112) }
  var totalHeight: CGFloat { Self.laneHeight + traceHeight + (densityHeight > 0 ? Self.gap + densityHeight : 0) }

  func lane(width: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: width, height: Self.laneHeight) }
  func trace(width: CGFloat) -> CGRect { CGRect(x: 0, y: Self.laneHeight, width: width, height: traceHeight) }
  /// The trace's data area: the panel less its inset.
  func traceInner(width: CGFloat) -> CGRect { trace(width: width).insetBy(dx: 0, dy: Self.traceInset) }
  func density(width: CGFloat) -> CGRect {
    CGRect(x: 0, y: Self.laneHeight + traceHeight + Self.gap, width: width, height: densityHeight)
  }
  func densityInner(width: CGFloat) -> CGRect { density(width: width).insetBy(dx: 0, dy: Self.densityInset) }
}

// MARK: - Columns

/// The shared x: column `i` of `columns` starts at `i * width / columns`, newest at the right.
struct SpectrumColumnGeometry: Equatable {
  let columns: Int
  let width: CGFloat
  /// The column position at the plot's right edge, column `i` spanning `i..<i + 1`: `columns`
  /// at rest, and on as the grid slides by the clock between replies (`SpectrumDeviceMotion`).
  let edge: Double
  /// How many columns span the width.
  let visible: Double

  init(columns: Int, width: CGFloat, edge: Double? = nil, visible: Double? = nil) {
    self.columns = columns
    self.width = width
    self.edge = edge ?? Double(columns)
    self.visible = max(visible ?? Double(columns), 1)
  }

  /// A lane mark is never drawn narrower than this, however short its airtime.
  static let minimumMarkWidth: CGFloat = 2

  var columnWidth: CGFloat { columns > 0 ? width / CGFloat(visible) : 0 }

  func x(_ column: Int) -> CGFloat {
    x(Double(column))
  }

  /// Where a column position falls: `i` is column `i`'s left edge, `i + 0.5` its middle.
  func x(_ position: Double) -> CGFloat {
    columns > 0 ? width - CGFloat(edge - position) * columnWidth : 0
  }

  /// The column under `x`, clamped to the grid.
  func column(at x: CGFloat) -> Int {
    guard columns > 0, width > 0 else { return 0 }
    return min(max(Int((edge - Double((width - x) / columnWidth)).rounded(.down)), 0), columns - 1)
  }

  /// A mark's x span over its columns, widened to the minimum on its left (on its right at the
  /// grid's left edge), so its end stays where the packet ended.
  func markSpan(_ range: Range<Int>) -> ClosedRange<CGFloat> {
    var lower = x(range.lowerBound)
    var upper = x(range.upperBound)
    if upper - lower < Self.minimumMarkWidth {
      lower = upper - Self.minimumMarkWidth
      if lower < 0 {
        lower = 0
        upper = min(width, Self.minimumMarkWidth)
      }
    }
    return lower...upper
  }
}

// MARK: - Trace

/// The trace's dB scale, the landscape radio's: 56 one-dB rows up from the held bottom, so a value
/// outside clamps to an edge row (`yFor`), with gridlines on whole multiples of 12 dBm.
struct SpectrumTraceGeometry: Equatable {
  static let span = 56
  static let gridStep = 12
  /// No scale label this close to the top (the key row) or to the floor rule, in the radio's
  /// rows: `gy < top + 14` and `|gy - floorY| < 8` on its 1 dB a pixel trace. The top's is at
  /// least 16 pt, the floor's at least a label's 10 pt, should the trace ever be squeezed.
  static let labelTopClearance: CGFloat = 16
  static let labelTopClearanceRows: CGFloat = 14
  static let labelFloorClearance: CGFloat = 10
  static let labelFloorClearanceRows = 8

  /// The bottom row's dBm.
  let scaleLo: Int
  /// The data area's height; y runs down from its top.
  let height: CGFloat

  var rowHeight: CGFloat { height / CGFloat(Self.span) }

  /// The row `dBm` falls in, 0 = the bottom, clamped to the scale.
  func row(_ dBm: Int) -> Int {
    min(max(dBm - scaleLo, 0), Self.span - 1)
  }

  /// The middle of `dBm`'s row: where a rule or a dot at that level goes.
  func y(_ dBm: Int) -> CGFloat {
    height - (CGFloat(row(dBm)) + 0.5) * rowHeight
  }

  /// Where a level between rows falls (the trace's line, easing between readings), clamped to
  /// the scale as `row` is.
  func y(level dBm: Double) -> CGFloat {
    let rows = min(max(dBm - Double(scaleLo), 0), Double(Self.span - 1))
    return height - (rows + 0.5) * rowHeight
  }

  /// A column's min..max bar, whole rows from the max's top to the min's bottom, so a column whose
  /// readings all fell in one dB still shows a row.
  func bar(min low: Int, max high: Int) -> ClosedRange<CGFloat> {
    let top = height - CGFloat(row(Swift.max(low, high)) + 1) * rowHeight
    let bottom = height - CGFloat(row(Swift.min(low, high))) * rowHeight
    return top...bottom
  }

  /// The gridlines, every 12 dB inside the scale (the radio stops below its top row).
  var gridlines: [Int] {
    let first = scaleLo + (Self.gridStep - ((scaleLo % Self.gridStep) + Self.gridStep) % Self.gridStep) % Self.gridStep
    return Array(stride(from: first, through: scaleLo + Self.span - 1, by: Self.gridStep))
  }

  /// The gridlines that get a label: none under the key row at the top, none within 8 dB rows of
  /// the floor rule.
  func labelledGridlines(floor: Int) -> [Int] {
    let floorY = y(floor)
    let floorRow = row(floor)
    let topClearance = max(Self.labelTopClearance, Self.labelTopClearanceRows * rowHeight)
    return gridlines.filter { dBm in
      let lineY = y(dBm)
      return lineY >= topClearance
        && abs(row(dBm) - floorRow) >= Self.labelFloorClearanceRows
        && abs(lineY - floorY) >= Self.labelFloorClearance
    }
  }

  /// Where a scale label `labelHeight` tall is centred for a gridline at `lineY`: on the line, but
  /// moved in just far enough to stay inside `bounds` (the trace's panel), so the bottom row's label
  /// never hangs into the gap over the density.
  static func labelCentre(lineY: CGFloat, labelHeight: CGFloat, in bounds: ClosedRange<CGFloat>) -> CGFloat {
    let half = labelHeight / 2
    guard bounds.upperBound - bounds.lowerBound >= labelHeight else { return (bounds.lowerBound + bounds.upperBound) / 2 }
    return min(max(lineY, bounds.lowerBound + half), bounds.upperBound - half)
  }

  /// The four level classes' horizontal bands over `floor`, bottom (noise) first, each only where
  /// it has room: a row is in the class of its dB over the floor (`levelRows`), split at +6, +20
  /// and +35.
  func levelBands(floor: Int) -> [(level: SpectrumLevel, top: CGFloat, bottom: CGFloat)] {
    func edge(_ level: SpectrumLevel) -> CGFloat {
      let rows = min(max(floor + Int(level.from) - scaleLo, 0), Self.span)
      return height - CGFloat(rows) * rowHeight
    }
    let edges: [CGFloat] = [height, edge(.signal), edge(.strong), edge(.veryStrong), 0]
    return SpectrumLevel.allCases.enumerated().compactMap { index, level in
      let bottom = edges[index]
      let top = edges[index + 1]
      return top < bottom ? (level, top, bottom) : nil
    }
  }
}

// MARK: - Density

/// The density's 28 rows of 2 dB, row 0 at the bottom (`spec::densityRows`).
enum SpectrumDensityGeometry {
  static let rows = CairnSpectrumColumn.rows

  /// Row `row`'s y span in a density `height` tall.
  static func rowSpan(_ row: Int, height: CGFloat) -> ClosedRange<CGFloat> {
    let rowHeight = height / CGFloat(rows)
    let bottom = height - CGFloat(row) * rowHeight
    return (bottom - rowHeight)...bottom
  }
}

// MARK: - The radio's view, read

extension SpectrumDeviceHistory {
  static let windowMilliseconds: [UInt32] = [10_000, 60_000, 600_000, 3_600_000]

  var windowMs: UInt32 {
    Self.windowMilliseconds[min(Int(window), Self.windowMilliseconds.count - 1)]
  }

  /// The level colours' and the floor rule's reference: the window's floor, or Cairn's stand-in.
  var floorReference: Int {
    refFloor.map(Int.init) ?? Int(SpectrumStats.uncalibratedFloor)
  }

  /// The age at a column's middle, ms (`spec::ageForCol`).
  func age(ofColumn column: Int) -> UInt32 {
    guard ncols > 0 else { return 0 }
    let back = ncols - 1 - min(max(column, 0), ncols - 1)
    return UInt32(UInt64(windowMs) * UInt64(2 * back + 1) / UInt64(2 * ncols))
  }

  /// The mark nearest `column`, within `reach` columns of its span (`hitMark`); ties go to the
  /// newer one.
  func nearestMark(toColumn column: Int, within reach: Int = 5) -> DeviceMark? {
    var best: (mark: DeviceMark, distance: Int)?
    for mark in marks {
      guard let range = columnRange(of: mark) else { continue }
      let end = range.upperBound - 1
      let distance = column < range.lowerBound ? range.lowerBound - column : (column > end ? column - end : 0)
      if distance <= reach, distance <= (best?.distance ?? .max) {
        best = (mark, distance)
      }
    }
    return best?.mark
  }

  /// The newest mark whose span covers `column` (`markAt`): the readout's SNR.
  func mark(overColumn column: Int) -> DeviceMark? {
    marks.last { columnRange(of: $0)?.contains(column) == true }
  }

  /// The cursor readout's inputs for `column`.
  func readoutInput(column: Int) -> SpectrumReadout.Input {
    let when = SpectrumReadout.age(milliseconds: age(ofColumn: column))
    guard columns.indices.contains(column), let value = columns[column] else {
      return SpectrumReadout.Input(when: when, hasData: false, isTX: false)
    }
    guard value.isData else {
      return SpectrumReadout.Input(when: when, hasData: false, isTX: value.isTX)
    }
    return SpectrumReadout.Input(
      when: when,
      hasData: true,
      isTX: value.isTX,
      min: Int(value.min),
      avg: Int(value.avg),
      max: Int(value.max),
      nf: value.nf.map(Int.init),
      snrX4: mark(overColumn: column).map { Int($0.mark.snrX4) },
      busy: value.busy.map(Int.init)
    )
  }

  /// The level class of a column's max over the window's floor: the readout's stripe.
  func level(ofColumn column: Int) -> SpectrumLevel? {
    guard columns.indices.contains(column), let value = columns[column], value.isData else { return nil }
    return SpectrumLevel(dBAboveFloor: Double(Int(value.max) - floorReference))
  }
}

// MARK: - Marks and the RX log

enum SpectrumDeviceMarkMatch {
  /// A heard packet and a mark are the same when they agree on type, land within 2 s and read
  /// within 1 dB of each other.
  static let maximumTimeGap: TimeInterval = 2
  static let maximumRSSIGap = 1.0

  /// When a mark's packet arrived, from the radio's clock at the reply and when the reply landed.
  static func date(of mark: CairnSpectrumMark, radioNowMs: UInt32, receivedAt: Date) -> Date {
    receivedAt.addingTimeInterval(-Double(radioNowMs &- mark.rxMs) / 1000)
  }

  static func matches(
    mark: CairnSpectrumMark, markDate: Date, packetKind: SpectrumPacketKind, packetDate: Date, packetRSSI: Double?
  ) -> Bool {
    guard SpectrumPacketKind(mark.payloadType) == packetKind,
          abs(packetDate.timeIntervalSince(markDate)) <= maximumTimeGap,
          let packetRSSI else { return false }
    return abs(packetRSSI - Double(mark.rssi)) <= maximumRSSIGap
  }
}

// MARK: - NF 24h

/// The radio's 24 h floor line (`drawFoot`): its range from the points that have a floor, and a
/// span of at least 4 dB centred on it, so a steady floor draws flat in the middle.
struct SpectrumTrendScale: Equatable {
  static let minimumSpan = 4

  let low: Int
  let high: Int

  init?(points: [Int8?]) {
    let values = points.compactMap(\.self).map(Int.init)
    guard let low = values.min(), let high = values.max() else { return nil }
    self.low = low
    self.high = high
  }

  /// The drawn scale's bottom and span (`lo -= (4 - span) / 2`).
  var drawn: (bottom: Int, span: Int) {
    let span = high - low
    guard span < Self.minimumSpan else { return (low, span) }
    return (low - (Self.minimumSpan - span) / 2, Self.minimumSpan)
  }

  /// y of `value` in a box `height` tall, 0 at the top.
  func y(_ value: Int, height: CGFloat) -> CGFloat {
    let (bottom, span) = drawn
    return height - CGFloat(value - bottom) / CGFloat(span) * height
  }

  /// "-115…-109", or the one value when the floor never moved.
  var label: String {
    low == high ? "\(low)" : "\(low)…\(high)"
  }
}

// MARK: - Cells

/// The five readings' text and colour classes, as `SpecChannelView::computeStats` sets them.
enum SpectrumDeviceCells {
  /// BUSY and AIR's thresholds: warning past 30 %, critical past 60 %.
  enum Load: Equatable {
    case normal
    case warning
    case critical

    init(percent: Double) {
      self = percent > 60 ? .critical : (percent > 30 ? .warning : .normal)
    }
  }

  /// "6.0" under 100 a minute, "123" from there.
  static func packetsPerMinute(x10: UInt16) -> String {
    x10 >= 1000
      ? (Int(x10) / 10).formatted()
      : (Double(x10) / 10).formatted(.number.precision(.fractionLength(1)))
  }

  /// "3.6%": tenths of a percent.
  static func airtime(x10: UInt16) -> String {
    (Double(x10) / 1000).formatted(.percent.precision(.fractionLength(1)))
  }

  /// "7%".
  static func busy(_ percent: UInt8) -> String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
  }

  /// The floor's verdict over thermal (`spec::floorCondition`).
  static func condition(floor: Int8, thermal: Int8) -> ChannelCondition {
    ChannelCondition(desensitization: Double(Int(floor) - Int(thermal)))
  }
}
