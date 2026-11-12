import SwiftUI

/// The Analyzer style of the Spectrum tab's channel (Settings › Spectrum › Chart Style): the same
/// readings as the Modern plot, drawn like an instrument's screen. On a dark panel with faint
/// scanlines, the trace of each moment's peak runs as a bright line coloured by its level, a glow
/// fading away beneath it, the dBm scale down the left. What is drawn stays: only the newest
/// column moves, and only as its reading settles. The radio reports about once a second; between its readings the trace keeps moving at
/// the display's rate, springing to each reading as it lands like a heartbeat, the live cursor at
/// the edge breathes on the newest one, and a packet ripples out from its mark on the lane as it's
/// heard. Only the
/// readings are real: the motion between them is the drawing settling, never a reading the radio
/// didn't send. With Reduce Motion on the same picture holds still and changes only as readings
/// land.
struct AnalyzerSpectrumView: View {
  let frame: MiniSpectrumFrame
  /// The packet lane's height.
  var laneHeight: CGFloat = 20
  /// The picked mark, ringed with a line down the plot.
  var selectedPacketID: UUID?
  var selectedRxMs: UInt32?
  /// A tap picks the packet nearest it, or nil away from any. Nil leaves taps to what's around it.
  var onSelectMark: ((MiniSpectrumFrame.Mark?) -> Void)?
  /// The moment the plot is held at while its page is paused: nothing scrolls, springs or
  /// ripples; nil while live.
  var heldAt: Date?
  /// The cursor, as seconds before the newest bar's end (`SpectrumCursor`); nil for none.
  var cursor: TimeInterval?
  /// A tap away from any packet puts the cursor there (or clears it): the moment tapped, or nil.
  var onCursorTap: ((TimeInterval?) -> Void)?
  /// The glass's corners.
  var cornerRadius: CGFloat = 12

  /// A tap this close to a packet picks it.
  private static let hitRadius: CGFloat = 18

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @State private var isVisible = false
  @State private var plotWidth: CGFloat = 0
  @State private var motion = AnalyzerMotion()

  /// Where the plot's edge stands against the newest bar's end: the bar at the edge springs up in
  /// view as its reading lands, rather than scrolling in from past it as the Modern plot's does.
  private func secondsPastNewest(at date: Date) -> TimeInterval {
    reduceMotion ? 0 : date.timeIntervalSince(frame.newestDate)
  }

  private func geometry(at date: Date) -> AnalyzerGeometry {
    AnalyzerGeometry(barCount: frame.bars.count, barSeconds: frame.barSeconds, secondsPastNewest: secondsPastNewest(at: date))
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !isVisible || scenePhase != .active || heldAt != nil)) { timeline in
      Canvas { context, size in
        let date = heldAt ?? timeline.date
        let state = motion.advance(to: date, frame: frame, animated: !reduceMotion)
        AnalyzerPainter(
          frame: frame,
          state: state,
          geometry: geometry(at: date),
          animated: !reduceMotion,
          laneHeight: laneHeight,
          selectedPacketID: selectedPacketID,
          selectedRxMs: selectedRxMs,
          scale: displayScale,
          cursorSeconds: cursor
        ).draw(in: &context, size: size)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
    .gesture(SpatialTapGesture().onEnded { value in
      guard onSelectMark != nil || onCursorTap != nil else { return }
      // The plot sits between the scale's column and the ramp's key.
      let geometry = geometry(at: heldAt ?? .now)
      let plotX = value.location.x - AnalyzerGeometry.scaleWidth
      let width = max(plotWidth - AnalyzerGeometry.scaleWidth - AnalyzerGeometry.keyWidth, 1)
      let nearest = frame.marks
        .map { (mark: $0, gap: abs(geometry.x(secondsBeforeNewest: $0.secondsBeforeNewest, width: width) - plotX)) }
        .min { $0.gap < $1.gap }
      if let onSelectMark, let mark = nearest.flatMap({ $0.gap <= Self.hitRadius ? $0.mark : nil }) {
        onSelectMark(mark)
        onCursorTap?(nil)
      } else {
        onSelectMark?(nil)
        onCursorTap?(SpectrumCursor.toggled(
          cursor, tapped: geometry.secondsBeforeNewest(atX: plotX, width: width), barSeconds: frame.barSeconds
        ))
      }
    }, including: onSelectMark == nil && onCursorTap == nil ? .subviews : .all)
    .overlay {
      if !frame.hasData {
        Text(L10n.Tools.Tools.Spectrum.measuring)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
    }
    .environment(\.colorScheme, .dark)
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .accessibilityHidden(true)
  }
}

/// Where the Analyzer plot puts each moment: the bars share the width evenly, the newest ending at
/// the right edge and moving left by the clock.
struct AnalyzerGeometry {
  let barCount: Int
  let barSeconds: TimeInterval
  /// How far the plot's edge has moved past the newest bar's end; below 0 that bar is still coming.
  let secondsPastNewest: TimeInterval

  /// The scale's column down the left of the plot, and the margin at its right.
  static let scaleWidth: CGFloat = 34
  static let keyWidth: CGFloat = 8

  func pitch(in width: CGFloat) -> CGFloat {
    width / CGFloat(max(barCount, 1))
  }

  /// Where the plot puts a moment `seconds` before the newest bar's end.
  func x(secondsBeforeNewest seconds: TimeInterval, width: CGFloat) -> CGFloat {
    width - CGFloat((seconds + secondsPastNewest) / max(barSeconds, 0.001)) * pitch(in: width)
  }

  /// The moment `x` stands for, in seconds before the newest bar's end: the inverse of `x(secondsBeforeNewest:width:)`.
  func secondsBeforeNewest(atX x: CGFloat, width: CGFloat) -> TimeInterval {
    Double((width - x) / max(pitch(in: width), 0.001)) * barSeconds - secondsPastNewest
  }

  /// The left edge of the bar at `index`, oldest first.
  func barX(_ index: Int, width: CGFloat) -> CGFloat {
    x(secondsBeforeNewest: Double(barCount - index) * barSeconds, width: width)
  }
}

/// What moves on the Analyzer plot between the radio's readings, advanced once per drawn frame:
/// each column's height on its way to its reading (a critically damped spring from the column
/// before it, so a new reading continues the trace rather than climbing from the floor), its peak
/// cap (held, then falling; kept for the model's tests, not drawn: history stays put), and the ripples of the
/// packets heard since the last frame. Columns are kept by their place on the clock, as
/// `MiniSpectrumHistory` keeps its bars, so a column keeps its motion as it slides left. A new
/// scale or a clock that jumps back starts over.
@MainActor
final class AnalyzerMotion {
  struct Column {
    /// The column's place on the clock, for its shimmer's phase.
    var key: Int64
    /// Where the column stands now, 0 at the bottom and 1 at the top.
    var shown = 0.0
    var velocity = 0.0
    /// Where its reading puts it.
    var target = 0.0
    var hasData = false
    var isTX = false
    /// How far over its floor the reading reached, for its colour class.
    var dBOverFloor: Double?
    /// The peak cap: the highest the column has stood lately.
    var cap = 0.0
    var capRaisedAt = 0.0
    var capVelocity = 0.0
  }

  struct Ripple {
    let mark: MiniSpectrumFrame.Mark
    /// Seconds since the packet was first drawn.
    let age: TimeInterval
  }

  /// One drawn frame's worth: a column per bar, oldest first, nil where no column has formed.
  struct State {
    var columns: [Column?]
    var ripples: [Ripple]
    /// Seconds since the plot came up, for its pulses and shimmer.
    var time: TimeInterval
    /// Seconds since the newest reading last rose into the strong band; nil once the bloom is over.
    var bloomAge: TimeInterval?
  }

  /// The spring a column settles on: critically damped, so a new reading rises quickly to its
  /// height and stops there, never past it and back.
  nonisolated static let stiffness = 260.0
  nonisolated static let damping = 32.25
  /// How long a peak cap holds before it falls, and how fast it gathers speed (plot heights per
  /// second squared): a short hold and a quick drop, so a peak reads as a moment, not a ledge.
  nonisolated static let capHold: TimeInterval = 0.3
  nonisolated static let capGravity = 5.0
  /// How long a packet's ripple runs.
  nonisolated static let rippleLife: TimeInterval = 0.9
  /// How long the bloom at the dot runs after the newest reading rises into the strong band.
  nonisolated static let bloomLife: TimeInterval = 0.7
  /// The strong band's lower edge on the plot's scale.
  nonisolated static let strongHeight = MiniSpectrumFrame.height(dBOverFloor: 20)

  private var columns: [Int64: Column] = [:]
  /// By the packet's identity, when it was first drawn.
  private var markSeen: [String: TimeInterval] = [:]
  /// The newest column stood in the strong band last frame, and when it last rose into it.
  private var wasStrong = false
  private var bloomAt: TimeInterval?
  private var lastTick: TimeInterval?
  private var started: TimeInterval?
  private var barSeconds: TimeInterval = 0
  private var newestKey: Int64?

  /// The plot as of `date`, after the time since the last frame has passed. Without `animated`
  /// every column stands at its reading and nothing ripples or falls.
  func advance(to date: Date, frame: MiniSpectrumFrame, animated: Bool) -> State {
    let now = date.timeIntervalSinceReferenceDate
    let first = lastTick == nil
    // A frame drawn again for the same moment, or the clock going back, moves nothing.
    let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
    lastTick = now
    if started == nil { started = now }

    let count = Int64(frame.bars.count)
    let jumpedBack = newestKey.map { frame.newestKey < $0 - count } ?? false
    if abs(frame.barSeconds - barSeconds) > 0.0001 || jumpedBack {
      columns = [:]
      markSeen = [:]
      barSeconds = frame.barSeconds
    }
    // Where the plot's newest reading stood last frame: only a reading past it is live. A
    // radio's history arriving in chunks as the page opens, or a bar filled in further back,
    // is the past, and stands on its reading at once.
    let previousNewest = columns.keys.max()
    newestKey = frame.newestKey

    var state = State(columns: [], ripples: [], time: now - (started ?? now))
    state.columns.reserveCapacity(frame.bars.count)
    for (index, bar) in frame.bars.enumerated() {
      let key = frame.newestKey - (count - 1 - Int64(index))
      let hasData = bar.dBm != nil
      guard hasData || bar.isTX || columns[key] != nil else {
        state.columns.append(nil)
        continue
      }
      let target = hasData ? bar.height(current: frame.floor) : 0
      // A column that lands at the newest edge carries on from the one before it, so a reading
      // lands as a movement from the last level rather than a climb from the floor.
      let isLive = animated && !first && previousNewest.map { key > $0 } ?? false
      let start = isLive ? (columns[key - 1]?.shown ?? target) : target
      var column = columns[key] ?? Column(key: key, shown: start, target: target, cap: start, capRaisedAt: now)
      column.hasData = hasData
      column.isTX = bar.isTX
      column.dBOverFloor = bar.dBOverFloor(current: frame.floor)
      column.target = target
      Self.settle(&column, dt: dt, now: now, animated: animated)
      columns[key] = column
      state.columns.append(column)
    }
    let oldest = frame.newestKey - count
    columns = columns.filter { $0.key > oldest }

    // The bloom: the newest reading rising into the strong band, once per rise.
    if let newest = state.columns.last(where: { $0?.hasData == true }) ?? nil {
      let isStrong = newest.shown >= Self.strongHeight
      if isStrong, !wasStrong, animated, !first { bloomAt = now }
      wasStrong = isStrong
    }
    if let bloomAt, now - bloomAt < Self.bloomLife {
      state.bloomAge = now - bloomAt
    }

    var present: Set<String> = []
    for mark in frame.marks {
      guard let id = mark.packetID?.uuidString ?? mark.rxMs.map(String.init) else { continue }
      present.insert(id)
      // What was already on the plot when it came up doesn't ripple.
      let seen = markSeen[id] ?? (first || !animated ? -.infinity : now)
      markSeen[id] = seen
      let age = now - seen
      if age < Self.rippleLife {
        state.ripples.append(Ripple(mark: mark, age: age))
      }
    }
    markSeen = markSeen.filter { present.contains($0.key) }
    return state
  }

  /// The column's spring and its cap, `dt` seconds on.
  private static func settle(_ column: inout Column, dt: TimeInterval, now: TimeInterval, animated: Bool) {
    if animated {
      // Semi-implicit Euler in short steps, so a long frame can't make the spring blow up.
      var remaining = dt
      while remaining > 0 {
        let step = min(remaining, 1.0 / 120)
        let acceleration = stiffness * (column.target - column.shown) - damping * column.velocity
        column.velocity += acceleration * step
        column.shown += column.velocity * step
        remaining -= step
      }
      column.shown = min(max(column.shown, 0), 1)
      if column.shown >= column.cap {
        column.cap = column.shown
        column.capRaisedAt = now
        column.capVelocity = 0
      } else if now - column.capRaisedAt > capHold {
        column.capVelocity += capGravity * dt
        column.cap = max(column.shown, column.cap - column.capVelocity * dt)
      }
    } else {
      column.shown = column.target
      column.velocity = 0
      column.cap = column.target
      column.capVelocity = 0
    }
  }
}

/// One frame of the Analyzer plot.
private struct AnalyzerPainter {
  let frame: MiniSpectrumFrame
  let state: AnalyzerMotion.State
  let geometry: AnalyzerGeometry
  let animated: Bool
  let laneHeight: CGFloat
  let selectedPacketID: UUID?
  let selectedRxMs: UInt32?
  /// Pixels per point, for the columns' edges: snapped to whole pixels, so a plot sliding by the
  /// clock steps a pixel at a time rather than smearing each column's edge across two.
  var scale: CGFloat = 2
  /// The cursor's moment, seconds before the newest bar's end; nil for none.
  var cursorSeconds: TimeInterval?

  /// The panel and its lettering: an instrument's dark glass, whatever the app's appearance.
  private static let panelColor = SpectrumPersistenceRamp.panel
  private static let gridColor = Color.white.opacity(0.12)
  private static let labelColor = Color.white.opacity(0.62)
  private static let floorColor = Color.white.opacity(0.5)
  private static let txColor = Color(red: 1, green: 0.40, blue: 0.62)
  private static let noiseColor = Color(red: 0.16, green: 0.55, blue: 0.52)
  private static let signalColor = Color(red: 0.25, green: 0.95, blue: 0.80)
  private static let strongColor = Color(red: 1, green: 0.66, blue: 0.20)
  private static let criticalColor = Color(red: 1, green: 0.27, blue: 0.27)

  private static var scaleWidth: CGFloat { AnalyzerGeometry.scaleWidth }
  private static var keyWidth: CGFloat { AnalyzerGeometry.keyWidth }
  /// The dBm gridlines' step over the plot's 28 dB.
  private static let gridStepDB = 4.0

  /// `x` on the pixel grid.
  private func snap(_ x: CGFloat) -> CGFloat {
    (x * scale).rounded() / scale
  }

  /// A column's pixel-snapped left edge and width at `index`: the columns meet, no gap, as the
  /// cells of a persistence display do.
  private func columnSpan(_ index: Int, in plot: CGRect) -> (left: CGFloat, width: CGFloat) {
    let pitch = geometry.pitch(in: plot.width)
    let edge = plot.minX + geometry.barX(index, width: plot.width)
    let left = snap(edge)
    return (left, max(snap(edge + pitch) - left, 1 / scale))
  }

  func draw(in context: inout GraphicsContext, size: CGSize) {
    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.panelColor))
    let plot = CGRect(
      x: Self.scaleWidth,
      y: laneHeight + 3,
      width: max(size.width - Self.scaleWidth - Self.keyWidth, 1),
      height: max(size.height - laneHeight - 6, 1)
    )
    let heights = columnHeights()
    drawGrid(in: &context, plot: plot)
    drawFloorRule(in: &context, plot: plot)
    drawFill(in: &context, plot: plot, heights: heights)
    drawTrace(in: &context, plot: plot, heights: heights)
    drawSweep(in: &context, plot: plot, heights: heights)
    drawBloom(in: &context, plot: plot, heights: heights)
    drawHead(in: &context, plot: plot, heights: heights)
    drawPeakMarker(in: &context, plot: plot, heights: heights)
    drawCursor(in: &context, plot: plot, heights: heights)
    drawMarks(in: &context, plot: plot, heights: heights)
  }

  /// ▼ over the loudest column in view.
  private func drawPeakMarker(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard frame.hasData, let peakHeight = frame.peakHeight, peakHeight >= MiniSpectrumFrame.height(dBOverFloor: 2),
          let index = frame.bars.indices.max(by: { (frame.bars[$0].dBm ?? -.infinity) < (frame.bars[$1].dBm ?? -.infinity) }),
          let height = index < heights.count ? heights[index] : nil
    else { return }
    let x = plot.minX + geometry.barX(index, width: plot.width) + geometry.pitch(in: plot.width) / 2
    guard x >= plot.minX, x <= plot.maxX else { return }
    let tip = CGPoint(x: x, y: max(y(height, in: plot) - 3, plot.minY + 8))
    context.fill(SpectrumMarkerGlyph.peak(at: tip), with: .color(Self.strongColor))
  }

  /// The sweep at the plot's edge: a band that brightens the last stretch of the line as it
  /// enters, white at the edge and gone a little way in, like a radar's sweep.
  private func drawSweep(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard animated, let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot)),
          plot.width > Self.sweepWidth else { return }
    let band = CGRect(x: plot.maxX - Self.sweepWidth, y: plot.minY, width: Self.sweepWidth, height: plot.height)
    let shading = GraphicsContext.Shading.linearGradient(
      Gradient(colors: [.white.opacity(0), .white.opacity(0.95)]),
      startPoint: CGPoint(x: band.minX, y: band.midY),
      endPoint: CGPoint(x: band.maxX, y: band.midY)
    )
    context.fill(Path(band), with: .linearGradient(
      Gradient(colors: [Self.signalColor.opacity(0), Self.signalColor.opacity(0.1)]),
      startPoint: CGPoint(x: band.minX, y: band.midY),
      endPoint: CGPoint(x: band.maxX, y: band.midY)
    ))
    let line = tracePath(trace, plot: plot)
    context.drawLayer { layer in
      layer.clip(to: Path(band))
      layer.stroke(line, with: shading, style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
    }
  }

  private static let sweepWidth: CGFloat = 28

  /// The bloom: when the newest reading rises into the strong band, a ring bursts from the dot in
  /// amber and the +20 line flashes, then both fade within the second.
  private func drawBloom(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard let age = state.bloomAge, let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot)) else { return }
    let progress = min(max(age / AnalyzerMotion.bloomLife, 0), 1)
    let fade = 1 - progress
    let headX = plot.maxX - 3
    let headY = y(trace.level(at: position(atX: plot.maxX, plot: plot)), in: plot)
    let radius = 6 + 26 * progress
    let ring = Path(ellipseIn: CGRect(x: headX - radius, y: headY - radius, width: radius * 2, height: radius * 2))
    context.drawLayer { glow in
      glow.addFilter(.blur(radius: 4))
      glow.stroke(ring, with: .color(Self.strongColor.opacity(0.8 * fade)), lineWidth: 3)
    }
    context.stroke(ring, with: .color(Self.strongColor.opacity(0.9 * fade)), lineWidth: 1.25)
    let lineY = snap(y(AnalyzerMotion.strongHeight, in: plot))
    var line = Path()
    line.move(to: CGPoint(x: plot.minX, y: lineY))
    line.addLine(to: CGPoint(x: plot.maxX, y: lineY))
    context.stroke(line, with: .color(Self.strongColor.opacity(0.55 * fade)), lineWidth: 1)
  }

  /// The cursor: a line down the plot at its moment.
  /// The cursor: a line down the plot at its moment, a marker diamond where it crosses the trace
  /// and its tag at the top.
  private func drawCursor(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard let cursorSeconds else { return }
    let cx = snap(plot.minX + geometry.x(secondsBeforeNewest: cursorSeconds, width: plot.width))
    guard cx >= plot.minX, cx <= plot.maxX else { return }
    context.fill(
      Path(CGRect(x: cx - 0.5, y: plot.minY, width: 1, height: plot.height)),
      with: Self.verticalFade(.white.opacity(0.85), x: cx, plot: plot)
    )
    if let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot)) {
      let position = position(atX: cx, plot: plot)
      if position >= trace.first, position <= trace.last {
        let diamond = SpectrumMarkerGlyph.diamond(at: CGPoint(x: cx, y: y(trace.level(at: position), in: plot)))
        context.fill(diamond, with: .color(.white))
        context.stroke(diamond, with: .color(.black), lineWidth: 1)
      }
    }
    SpectrumMarkerGlyph.tag(in: &context, "M1", at: CGPoint(x: min(cx + 2, plot.maxX - 22), y: plot.minY + 1), color: .white)
  }

  private func y(_ height: Double, in plot: CGRect) -> CGFloat {
    plot.maxY - plot.height * height
  }

  /// A vertical line's shading: `color` along its middle, fading to nothing over the top and
  /// bottom tenth of the plot, so the line ends softly rather than being cut flat at the edges.
  private static func verticalFade(_ color: Color, x: CGFloat, plot: CGRect) -> GraphicsContext.Shading {
    .linearGradient(
      Gradient(stops: [
        .init(color: color.opacity(0), location: 0),
        .init(color: color, location: 0.12),
        .init(color: color, location: 0.88),
        .init(color: color.opacity(0), location: 1),
      ]),
      startPoint: CGPoint(x: x, y: plot.minY),
      endPoint: CGPoint(x: x, y: plot.maxY)
    )
  }

  /// Each column's drawn height: where it stands on its way to its reading; nil where there's no
  /// reading.
  private func columnHeights() -> [Double?] {
    state.columns.map { column in
      guard let column, column.hasData else { return nil }
      return min(max(column.shown, 0), 1)
    }
  }

  // MARK: Trace model

  /// The trace as a continuous line over the columns: the eased level of each column with a
  /// reading at its centre, a smoothstep between neighbours (so the line sits on each reading and
  /// bends between them rather than cornering), and the newest reading's level held flat from
  /// there to the plot's edge. The trace always reaches now, so a reading that lands bends its end
  /// rather than extending it a column at a time.
  private struct Trace {
    let positions: [Double]
    let levels: [Double]

    /// - Parameter edgePosition: The plot's right edge as a column position. A newest column whose
    ///   centre is still past the edge (its bar is filling) is taken as at the edge instead, so the
    ///   line's end stands at that reading and moves only with its spring; otherwise the edge would
    ///   slide along the curve between the previous column and the newest as the bar filled, and
    ///   back down as the next arrived, which read as a pulse at every peak.
    init?(heights: [Double?], edgePosition: Double = .infinity) {
      var positions: [Double] = []
      var levels: [Double] = []
      for (index, height) in heights.enumerated() {
        guard let height else { continue }
        positions.append(Double(index))
        levels.append(height)
      }
      guard !positions.isEmpty else { return nil }
      if let last = positions.last, last > edgePosition {
        let floor = positions.count >= 2 ? positions[positions.count - 2] + 0.01 : edgePosition
        positions[positions.count - 1] = max(edgePosition, floor)
      }
      self.positions = positions
      self.levels = levels
    }

    var first: Double { positions[0] }
    var last: Double { positions[positions.count - 1] }

    func level(at position: Double) -> Double {
      if position <= first { return levels[0] }
      if position >= last { return levels[levels.count - 1] }
      var low = 0
      var high = positions.count - 1
      while high - low > 1 {
        let mid = (low + high) / 2
        if positions[mid] <= position { low = mid } else { high = mid }
      }
      let span = positions[high] - positions[low]
      guard span > 0 else { return levels[low] }
      let fraction = (position - positions[low]) / span
      let eased = fraction * fraction * (3 - 2 * fraction)
      return levels[low] + (levels[high] - levels[low]) * eased
    }
  }

  /// A point on the plot as a continuous column position: column `i`'s centre is `i`.
  private func position(atX x: CGFloat, plot: CGRect) -> Double {
    let pitch = geometry.pitch(in: plot.width)
    return Double((x - plot.minX - geometry.barX(0, width: plot.width)) / pitch) - 0.5
  }

  // MARK: Layers

  /// The dBm gridlines every 4 dB, dotted, each labelled down the left in the scale's column.
  private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
    var over = -MiniSpectrumFrame.dBUnderFloor
    while over <= MiniSpectrumFrame.spanDB - MiniSpectrumFrame.dBUnderFloor + 0.01 {
      let lineY = snap(y(MiniSpectrumFrame.height(dBOverFloor: over), in: plot))
      if over > -MiniSpectrumFrame.dBUnderFloor + 0.01, over < MiniSpectrumFrame.spanDB - MiniSpectrumFrame.dBUnderFloor - 0.01 {
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: lineY))
        line.addLine(to: CGPoint(x: plot.maxX, y: lineY))
        context.stroke(line, with: .color(Self.gridColor), style: StrokeStyle(lineWidth: 0.5, dash: [1, 3]))
      }
      if frame.hasData {
        context.draw(
          Text("\(Int((frame.floor + over).rounded()))")
            .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(Self.labelColor),
          at: CGPoint(x: plot.minX - 4, y: min(max(lineY, plot.minY + 5), plot.maxY - 5)),
          anchor: .trailing
        )
      }
      over += Self.gridStepDB
    }
  }

  /// The floor the columns stand against, dashed.
  private func drawFloorRule(in context: inout GraphicsContext, plot: CGRect) {
    let floorY = snap(y(MiniSpectrumFrame.height(dBOverFloor: 0), in: plot))
    var line = Path()
    line.move(to: CGPoint(x: plot.minX, y: floorY))
    line.addLine(to: CGPoint(x: plot.maxX, y: floorY))
    context.stroke(line, with: .color(Self.floorColor), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
  }

  /// The trace's line through the plot, sampled every two points from the plot's left edge to its
  /// right, so it moves as one piece.
  /// The trace as a polyline, sampled on its own knots (each reading's column centre) and at
  /// fixed fractions between them rather than on a screen-space grid: a grid the trace slides
  /// across would land on a peak's apex one frame and either side of it the next, and the peak
  /// would bob as it scrolled. Sampled this way the line only ever translates.
  private func tracePath(_ trace: Trace, plot: CGRect) -> Path {
    var line = Path()
    let pitch = geometry.pitch(in: plot.width)
    let origin = plot.minX + geometry.barX(0, width: plot.width)
    let start = position(atX: plot.minX, plot: plot)
    let end = position(atX: plot.maxX, plot: plot)
    func point(at position: Double) -> CGPoint {
      CGPoint(x: origin + CGFloat(position + 0.5) * pitch, y: y(trace.level(at: position), in: plot))
    }
    func sample(from: Double, to: Double) {
      let steps = max(Int(((to - from) * Double(pitch) / 2).rounded(.up)), 1)
      if steps > 1 {
        for step in 1..<steps {
          line.addLine(to: point(at: from + (to - from) * Double(step) / Double(steps)))
        }
      }
    }
    line.move(to: CGPoint(x: plot.minX, y: y(trace.level(at: start), in: plot)))
    var previous = start
    for knot in trace.positions where knot > start && knot < end {
      sample(from: previous, to: knot)
      line.addLine(to: point(at: knot))
      previous = knot
    }
    sample(from: previous, to: end)
    line.addLine(to: CGPoint(x: plot.maxX, y: y(trace.level(at: end), in: plot)))
    return line
  }

  /// The level gradient up the plot: noise teal to +6, signal cyan to +20, amber past it.
  private func levelShading(in plot: CGRect, alpha: Double = 1) -> GraphicsContext.Shading {
    let signalEdge = MiniSpectrumFrame.height(dBOverFloor: 6)
    let strongEdge = MiniSpectrumFrame.height(dBOverFloor: 20)
    return .linearGradient(
      Gradient(stops: [
        .init(color: Self.noiseColor.opacity(0.8 * alpha), location: 0),
        .init(color: Self.noiseColor.opacity(alpha), location: signalEdge - 0.02),
        .init(color: Self.signalColor.opacity(alpha), location: signalEdge + 0.02),
        .init(color: Self.signalColor.opacity(alpha), location: strongEdge - 0.02),
        .init(color: Self.strongColor.opacity(alpha), location: strongEdge + 0.02),
        .init(color: Self.strongColor.opacity(alpha), location: 1),
      ]),
      startPoint: CGPoint(x: 0, y: plot.maxY),
      endPoint: CGPoint(x: 0, y: plot.minY)
    )
  }

  /// The glow under the trace: a soft fill from the line down to the floor, bright at the line and
  /// gone by the bottom, with faint scanlines through it.
  private func drawFill(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot)), plot.maxX - plot.minX > 2 else { return }
    var area = tracePath(trace, plot: plot)
    area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
    area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
    area.closeSubpath()
    context.fill(area, with: .linearGradient(
      Gradient(stops: [
        .init(color: Self.signalColor.opacity(0.28), location: 0),
        .init(color: Self.signalColor.opacity(0.1), location: 0.45),
        .init(color: Self.signalColor.opacity(0), location: 1),
      ]),
      startPoint: CGPoint(x: 0, y: plot.minY),
      endPoint: CGPoint(x: 0, y: plot.maxY)
    ))
    // scanlines: every third pixel row a touch darker, as a phosphor screen reads
    var lines = Path()
    var rowY = snap(plot.minY) + 1 / scale
    while rowY < plot.maxY {
      lines.addRect(CGRect(x: plot.minX, y: rowY, width: plot.width, height: 1 / scale))
      rowY += 3 / scale
    }
    context.drawLayer { layer in
      layer.clip(to: area)
      layer.fill(lines, with: .color(.black.opacity(0.18)))
    }
  }

  /// The bright trace of each moment's peak: the heartbeat, coloured by its level up the plot,
  /// under a soft glow.
  private func drawTrace(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot)), plot.maxX - plot.minX > 2 else { return }
    let line = tracePath(trace, plot: plot)
    let stroke = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
    context.drawLayer { glow in
      glow.addFilter(.blur(radius: 7))
      glow.opacity = 0.85
      glow.stroke(line, with: levelShading(in: plot), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
    }
    context.drawLayer { glow in
      glow.addFilter(.blur(radius: 2))
      glow.stroke(line, with: levelShading(in: plot), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
    context.stroke(line, with: .color(.white.opacity(0.9)), style: stroke)
  }

  /// The live cursor at the plot's edge, riding the trace's end: a line down it and a dot that
  /// breathes, in the newest reading's level colour.
  private func drawHead(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    guard let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot)),
          let index = heights.indices.last(where: { heights[$0] != nil }) else { return }
    // On the line's own end point, so the dot rides exactly where the trace is drawn to, however
    // fast the newest reading springs; drawn a hair in from the edge so the whole dot shows.
    let headX = plot.maxX - 3
    let headY = y(trace.level(at: position(atX: plot.maxX, plot: plot)), in: plot)
    let color = headColor(state.columns[index]?.dBOverFloor)

    var cursor = Path()
    cursor.move(to: CGPoint(x: headX, y: plot.minY))
    cursor.addLine(to: CGPoint(x: headX, y: plot.maxY))
    context.stroke(cursor, with: Self.verticalFade(color.opacity(0.35), x: headX, plot: plot), lineWidth: 1)

    let dot = Path(ellipseIn: CGRect(x: headX - 3, y: headY - 3, width: 6, height: 6))
    context.drawLayer { glow in
      glow.addFilter(.blur(radius: 5))
      glow.fill(dot, with: .color(color))
    }
    context.fill(dot, with: .color(.white.opacity(0.95)))
    guard animated else { return }
    // One ring a little over every second, growing from the dot and fading as it goes.
    let phase = (state.time * 0.85).truncatingRemainder(dividingBy: 1)
    let radius = 4 + 9 * phase
    let ring = Path(ellipseIn: CGRect(x: headX - radius, y: headY - radius, width: radius * 2, height: radius * 2))
    context.stroke(ring, with: .color(color.opacity(0.7 * (1 - phase))), lineWidth: 1.25)
  }

  private func headColor(_ dBOverFloor: Double?) -> Color {
    switch SpectrumLevel(dBAboveFloor: dBOverFloor ?? 0) {
    case .noise: Self.noiseColor
    case .signal: Self.signalColor
    case .strong: Self.strongColor
    case .veryStrong: Self.criticalColor
    }
  }

  /// The packets heard, each a tick in its kind's colour on the lane over the plot's columns; one
  /// just heard ripples out from its tick. The picked one is ringed, with a line down to its
  /// column.
  private func drawMarks(in context: inout GraphicsContext, plot: CGRect, heights: [Double?]) {
    let trace = Trace(heights: heights, edgePosition: position(atX: plot.maxX, plot: plot))
    for mark in frame.marks {
      let tickX = plot.minX + geometry.x(secondsBeforeNewest: mark.secondsBeforeNewest, width: plot.width)
      guard tickX >= plot.minX - 2, tickX <= plot.maxX + 2 else { continue }
      let tick = CGRect(x: tickX - 2, y: 4, width: 4, height: laneHeight - 5)
      context.fill(Path(roundedRect: tick, cornerRadius: 1.5), with: .color(mark.kind.color))
      let isSelected = (mark.packetID != nil && mark.packetID == selectedPacketID)
        || (mark.rxMs != nil && mark.rxMs == selectedRxMs)
      if isSelected {
        context.stroke(Path(roundedRect: tick.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 2.5), with: .color(.white), lineWidth: 1)
        var line = Path()
        line.move(to: CGPoint(x: tickX, y: tick.maxY + 2))
        line.addLine(to: CGPoint(x: tickX, y: plot.maxY))
        context.stroke(line, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
      }
    }

    for ripple in state.ripples {
      let tickX = plot.minX + geometry.x(secondsBeforeNewest: ripple.mark.secondsBeforeNewest, width: plot.width)
      guard tickX >= plot.minX - 20, tickX <= plot.maxX + 20 else { continue }
      let progress = min(max(ripple.age / AnalyzerMotion.rippleLife, 0), 1)
      let fade = 1 - progress
      let color = ripple.mark.kind.color
      let center = CGPoint(x: tickX, y: laneHeight / 2 + 1)
      let radius = 3 + 18 * progress
      let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
      context.stroke(ring, with: .color(color.opacity(0.9 * fade)), lineWidth: 1.5)
      // and a ping on the line itself, where the packet landed
      if let trace, tickX >= plot.minX, tickX <= plot.maxX {
        let pingY = y(trace.level(at: position(atX: tickX, plot: plot)), in: plot)
        let pingRadius = 4 + 22 * progress
        let ping = Path(ellipseIn: CGRect(x: tickX - pingRadius, y: pingY - pingRadius, width: pingRadius * 2, height: pingRadius * 2))
        context.drawLayer { glow in
          glow.addFilter(.blur(radius: 3))
          glow.stroke(ping, with: .color(color.opacity(0.7 * fade)), lineWidth: 2.5)
        }
        context.stroke(ping, with: .color(color.opacity(0.9 * fade)), lineWidth: 1.25)
      }
    }
  }
}
