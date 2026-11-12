import MeshCore
import SwiftUI

/// How the Radio Screen's column grid moves between the radio's replies: by the clock, so the
/// plot slides on at a steady pace at the screen's frame rate rather than stepping each time a
/// reply lands. The newest columns sit `lag` past the plot's edge at rest, long enough for the
/// reply that fills them to land before they slide into view (as the Modern plot's bars do).
struct SpectrumDeviceMotion: Equatable {
  /// The phone's time at which the newest (partial) column's slot began; nil before it can be
  /// told, when the grid stands still.
  var newestSlotStart: Date?
  var slotSeconds: TimeInterval
  var lag: TimeInterval

  /// Long enough for the next reply (1 s, or 0.5 s on the 10 s window) to land past the edge.
  static func lag(window: TimeInterval, slotSeconds: TimeInterval) -> TimeInterval {
    window <= 10 ? 1.5 : max(2.5, slotSeconds * 1.5)
  }

  /// The grid for `history` as of `date`; the grid at rest, its newest column at the edge, for
  /// nil (Reduce Motion, tests).
  func columns(history: SpectrumDeviceHistory, width: CGFloat, at date: Date?) -> SpectrumColumnGeometry {
    let ncols = history.ncols
    guard slotSeconds > 0, ncols > 2, let date, let newestSlotStart else {
      return SpectrumColumnGeometry(columns: ncols, width: width)
    }
    let lagColumns = min(lag / slotSeconds, Double(ncols) / 2)
    let elapsed = max(date.timeIntervalSince(newestSlotStart) / slotSeconds, 0)
    return SpectrumColumnGeometry(
      columns: ncols, width: width, edge: Double(ncols) - lagColumns + elapsed, visible: Double(ncols) - lagColumns
    )
  }
}

/// How far each of the Radio Screen's columns has come toward its reading, so a column that lands
/// rises there over a quarter of a second rather than stepping, and one landing at the newest edge
/// starts from the column before it, continuing the line. Kept by the view across frames by each
/// column's slot, as `MiniSpectrumEasing` keeps the Modern plot's bars; a column already drawn
/// moves only if the radio sends it a new reading.
@MainActor
final class SpectrumDeviceEasing {
  struct Level: Equatable {
    var min: Double
    var max: Double
    var avg: Double
    var nf: Double?

    func moved(toward target: Level, by blend: Double) -> Level {
      Level(
        min: min + (target.min - min) * blend,
        max: max + (target.max - max) * blend,
        avg: avg + (target.avg - avg) * blend,
        nf: target.nf.map { to in nf.map { $0 + (to - $0) * blend } ?? to }
      )
    }
  }

  /// How long a reading takes to arrive.
  nonisolated static let easeIn: TimeInterval = 0.25

  private var shown: [Int64: Level] = [:]
  private var lastTick: TimeInterval?
  private var epoch: UInt16?
  private var ncols = 0

  /// Each column's drawn readings, oldest first; nil where there's none.
  func levels(history: SpectrumDeviceHistory, at date: Date, animated: Bool) -> [Level?] {
    let now = date.timeIntervalSinceReferenceDate
    let first = lastTick == nil
    let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
    lastTick = now
    let nowSlot = Int64(history.nowSlot)
    let count = Int64(history.ncols)
    let jumpedBack = shown.keys.max().map { nowSlot < $0 - count } ?? false
    if history.epoch != epoch || history.ncols != ncols || jumpedBack {
      shown = [:]
      epoch = history.epoch
      ncols = history.ncols
    }
    let previousNewest = shown.keys.max()
    let blend = animated ? 1 - exp(-dt / Self.easeIn) : 1

    var levels: [Level?] = []
    levels.reserveCapacity(history.columns.count)
    for (index, column) in history.columns.enumerated() {
      guard let column, column.isData else {
        levels.append(nil)
        continue
      }
      let key = nowSlot - (count - 1 - Int64(index))
      let target = Level(min: Double(column.min), max: Double(column.max), avg: Double(column.avg), nf: column.nf.map(Double.init))
      let level: Level
      if let current = shown[key] {
        level = current.moved(toward: target, by: blend)
      } else if animated, !first, let previousNewest, key > previousNewest, let neighbour = shown[key - 1] {
        level = neighbour.moved(toward: target, by: blend)
      } else {
        level = target
      }
      shown[key] = level
      levels.append(level)
    }
    shown = shown.filter { $0.key > nowSlot - count }
    return levels
  }
}

/// The density panel as one small image, a pixel per cell (a column by a 2 dB row) in the heat
/// colour, drawn stretched over the panel with interpolation, so the heat shades smoothly between
/// cells rather than standing in blocks. Kept by the view and remade only when the history
/// changes, not on every frame it slides.
@MainActor
final class SpectrumDensityRaster {
  private var history: SpectrumDeviceHistory?
  private var image: CGImage?

  func image(for history: SpectrumDeviceHistory) -> CGImage? {
    if let image, self.history == history { return image }
    let made = Self.render(history)
    self.history = history
    image = made
    return made
  }

  private static func render(_ history: SpectrumDeviceHistory) -> CGImage? {
    let width = history.ncols
    let rows = SpectrumDensityGeometry.rows
    guard width > 0, rows > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * rows * 4)
    var any = false
    for (column, cell) in history.columns.enumerated() {
      guard let cell, cell.isData else { continue }
      for (row, heat) in cell.occupancy.enumerated() where heat > 0 && row < rows {
        let rgb = SpectrumHeat.rgb(min(Int(heat), SpectrumHeat.count - 1))
        let offset = ((rows - 1 - row) * width + column) * 4
        bytes[offset] = UInt8((rgb >> 16) & 0xFF)
        bytes[offset + 1] = UInt8((rgb >> 8) & 0xFF)
        bytes[offset + 2] = UInt8(rgb & 0xFF)
        bytes[offset + 3] = 0xFF
        any = true
      }
    }
    guard any, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
  }
}

/// The radio's Channel plot in one Canvas, drawn from an immutable copy of its view the way
/// `SpecChannelView` lays it out, on one shared x: the packet lane (TX ticks and the packet marks in
/// their type colours), the trace (dotted 12 dB gridlines, the dashed floor rule, the columns'
/// maxima as one smooth line with the span down to their minima filled under it in the level bands
/// over the floor, the average and the floor as thin lines, TX-only columns, the dashed peak rule
/// with its ▼, the scale labels and the keys), and the density heat map under it. Given a
/// `motion`, the grid slides on by the clock at the screen's frame rate and the columns ease in as
/// they land; without one it stands still and redraws only when the view changes.
struct SpectrumDeviceCanvas: View {
  let history: SpectrumDeviceHistory
  let layout: SpectrumDeviceLayout
  /// The cursor's column, drawn as a line through the trace and the density.
  let cursor: Int?
  /// The selected mark's `rxMs`: outlined on the lane.
  let selectedMark: UInt32?
  /// The keys hide while the cursor or a packet card is up, as on the radio.
  let showsKeys: Bool
  /// How the grid moves between replies; nil holds it still.
  var motion: SpectrumDeviceMotion?
  /// Paused: the grid where it stood then.
  var heldAt: Date?

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var easing = SpectrumDeviceEasing()
  @State private var density = SpectrumDensityRaster()
  @State private var isVisible = false

  var body: some View {
    let history = history
    let layout = layout
    let cursor = cursor
    let selectedMark = selectedMark
    let showsKeys = showsKeys
    let motion = motion
    let heldAt = heldAt
    let increased = contrast == .increased
    let animated = motion != nil && !reduceMotion
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animated || !isVisible || scenePhase != .active || heldAt != nil)) { timeline in
      Canvas { context, size in
        let date = heldAt ?? timeline.date
        let columns = motion?.columns(history: history, width: size.width, at: animated ? date : nil)
          ?? SpectrumColumnGeometry(columns: history.ncols, width: size.width)
        let painter = SpectrumDevicePainter(
          history: history,
          layout: layout,
          columns: columns,
          levels: easing.levels(history: history, at: date, animated: animated),
          increasedContrast: increased
        )
        painter.drawLane(in: context, selectedMark: selectedMark)
        painter.drawTrace(in: context, showsKeys: showsKeys)
        painter.drawDensity(in: context, raster: density.image(for: history), showsKeys: showsKeys)
        if let cursor { painter.drawCursor(in: context, column: cursor) }
      }
    }
    .frame(height: layout.totalHeight)
    // the in-plot labels stay inside their chips however large the text
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
  }
}

/// One frame's drawing, from the copy of the radio's view.
private struct SpectrumDevicePainter {
  let history: SpectrumDeviceHistory
  let layout: SpectrumDeviceLayout
  let columns: SpectrumColumnGeometry
  /// Each column's drawn readings (`SpectrumDeviceEasing`); nil where there's none.
  let levels: [SpectrumDeviceEasing.Level?]
  let increasedContrast: Bool

  var width: CGFloat { columns.width }

  private static let labelFont = Font.caption2.monospacedDigit()
  private static let keyFont = Font.caption2.weight(.semibold)
  private static let traceWidth: CGFloat = 1.5

  /// The keys' plain words ("rare", "often", the " · "): a step brighter with Increase Contrast,
  /// as the gridlines and the average are.
  private var keyTextColor: Color { increasedContrast ? SpectrumPalette.text2 : SpectrumPalette.text3 }

  /// A column's drawn rect from x(i) to x(i + 1), so neighbours meet without seams.
  private func columnSpan(_ index: Int) -> (x: CGFloat, width: CGFloat) {
    let x = columns.x(index)
    return (x, max(columns.x(index + 1) - x, 0.5))
  }

  /// A column's middle.
  private func columnMid(_ index: Int) -> CGFloat {
    columns.x(Double(index) + 0.5)
  }

  private var scale: SpectrumTraceGeometry {
    let bottom = history.scaleLo != 0
      ? Int(history.scaleLo)
      : Int(SpectrumTraceScale.bottom(floor: history.refFloor.map(Double.init)))
    return SpectrumTraceGeometry(scaleLo: bottom, height: layout.traceInner(width: width).height)
  }

  // MARK: Lane

  func drawLane(in context: GraphicsContext, selectedMark: UInt32?) {
    let lane = layout.lane(width: width)
    context.fill(
      Path(CGRect(x: 0, y: lane.maxY - 1, width: width, height: 1)),
      with: .color(SpectrumPalette.border)
    )
    // our own transmissions: the slots the radio spent sending
    var ticks = Path()
    for (index, column) in history.columns.enumerated() where column?.isTX == true {
      let span = columnSpan(index)
      ticks.addRect(CGRect(x: span.x, y: lane.minY + 3, width: max(1, span.width), height: 5))
    }
    context.fill(ticks, with: .color(SpectrumPalette.warning))

    var selected: CGRect?
    for mark in history.marks {
      guard let range = history.columnRange(of: mark) else { continue }
      let span = columns.markSpan(range)
      let rect = CGRect(x: span.lowerBound, y: lane.minY + 1, width: span.upperBound - span.lowerBound, height: 7)
      context.fill(Path(rect), with: .color(SpectrumPacketKind(mark.mark.payloadType).color))
      if mark.mark.rxMs == selectedMark { selected = rect }
    }
    if let selected {
      context.stroke(Path(selected.insetBy(dx: -1, dy: -1)), with: .color(.primary), lineWidth: 1)
    }
  }

  // MARK: Trace

  func drawTrace(in context: GraphicsContext, showsKeys: Bool) {
    let panel = layout.trace(width: width)
    let panelPath = tracePanelPath(panel)
    context.fill(panelPath, with: .color(SpectrumPalette.panel))
    let inner = layout.traceInner(width: width)
    let scale = scale
    let floor = history.floorReference
    func y(_ dBm: Int) -> CGFloat { inner.minY + scale.y(dBm) }
    func y(level dBm: Double) -> CGFloat { inner.minY + scale.y(level: dBm) }

    // 1. gridlines every 12 dB, dotted
    let gridColor = increasedContrast ? SpectrumPalette.text3 : SpectrumPalette.border
    for dBm in scale.gridlines {
      context.stroke(
        horizontal(at: y(dBm)),
        with: .color(gridColor),
        style: StrokeStyle(lineWidth: 1, dash: [1, 2])
      )
    }
    // 2. the floor rule, dashed
    if history.refFloor != nil {
      context.stroke(
        horizontal(at: y(floor)),
        with: .color(SpectrumPalette.text3),
        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
      )
    }

    if history.hasData {
      // 3. the trace: each run of columns with readings as one smooth line along their maxima,
      // the span down to their minima filled under it, the average and the floor as thin lines
      var area = Path()
      var maxLine = Path()
      var avgLine = Path()
      var floorLine = Path()
      for run in runs() {
        let xs: [CGFloat]
        let runLevels: [SpectrumDeviceEasing.Level]
        if run.count == 1, let level = levels[run[0]] {
          // one column on its own: flat across it
          let span = columnSpan(run[0])
          xs = [span.x, span.x + span.width]
          runLevels = [level, level]
        } else {
          xs = run.map(columnMid)
          runLevels = run.compactMap { levels[$0] }
        }
        let tops = zip(xs, runLevels).map { CGPoint(x: $0, y: y(level: $1.max)) }
        let bottoms = zip(xs, runLevels).map { CGPoint(x: $0, y: y(level: $1.min)) }
        let averages = zip(xs, runLevels).map { CGPoint(x: $0, y: y(level: $1.avg)) }
        Self.smooth(tops, into: &maxLine, continuing: false)
        Self.smooth(averages, into: &avgLine, continuing: false)
        var floors: [CGPoint] = []
        for (x, level) in zip(xs, runLevels) {
          if let nf = level.nf {
            floors.append(CGPoint(x: x, y: y(level: nf)))
          } else if !floors.isEmpty {
            Self.smooth(floors, into: &floorLine, continuing: false)
            floors.removeAll()
          }
        }
        Self.smooth(floors, into: &floorLine, continuing: false)
        Self.smooth(tops, into: &area, continuing: false)
        Self.smooth(Array(bottoms.reversed()), into: &area, continuing: true)
        area.closeSubpath()
      }
      let bands = scale.levelBands(floor: floor)
      // Clipped to the panel, not the data area inside it: a reading on the top row sits half
      // a row under the data area's edge, and the line's stroke would be cut flat there.
      let panelClip = panelPath
      context.drawLayer { layer in
        layer.clip(to: panelClip)
        layer.clip(to: area)
        for band in bands {
          layer.fill(
            Path(CGRect(x: 0, y: inner.minY + band.top, width: width, height: band.bottom - band.top)),
            with: .color(SpectrumPalette.band(band.level))
          )
        }
      }
      context.drawLayer { layer in
        layer.clip(to: panelClip)
        layer.clip(to: maxLine.strokedPath(StrokeStyle(lineWidth: Self.traceWidth, lineCap: .round, lineJoin: .round)))
        for band in bands {
          layer.fill(
            Path(CGRect(x: 0, y: inner.minY + band.top, width: width, height: band.bottom - band.top)),
            with: .color(SpectrumPalette.line(band.level))
          )
        }
      }
      context.drawLayer { layer in
        layer.clip(to: panelClip)
        layer.stroke(floorLine, with: .color(SpectrumPalette.text2), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        layer.stroke(
          avgLine,
          with: .color(increasedContrast ? SpectrumPalette.noise : SpectrumPalette.avgRef),
          style: StrokeStyle(lineWidth: 1, lineJoin: .round)
        )
      }

      // 4. columns spent transmitting, with no reading
      var transmitting = Path()
      for (index, column) in history.columns.enumerated() {
        guard let column, !column.isData, column.isTX else { continue }
        let span = columnSpan(index)
        transmitting.addRect(CGRect(x: span.x + span.width / 2 - 0.5, y: inner.minY, width: 1, height: inner.height))
      }
      context.fill(transmitting, with: .color(SpectrumPalette.text3.opacity(0.35)))

      // 5. the window's peak: a dashed rule and a ▼ over its column
      if let peak = history.peak {
        let peakY = y(Int(peak))
        context.stroke(
          horizontal(at: peakY),
          with: .color(SpectrumPalette.warning),
          style: StrokeStyle(lineWidth: 1, dash: [2, 2])
        )
        if let column = history.peakColumn {
          let x = min(max(columnMid(column), 3.5), width - 3.5)
          context.fill(peakMarker(x: x, ruleY: peakY, above: peakY - 9 >= panel.minY), with: .color(SpectrumPalette.warning))
        }
      }
    } else {
      let text = context.resolve(
        Text(L10n.Tools.Tools.Spectrum.Device.sampling).font(.caption).foregroundStyle(SpectrumPalette.text3)
      )
      context.draw(text, at: CGPoint(x: panel.midX, y: panel.midY), anchor: .center)
    }

    // 6. the scale labels, on panel chips at the left
    for dBm in scale.labelledGridlines(floor: floor) {
      chip(
        in: context,
        Text(String(dBm)).font(Self.labelFont).foregroundStyle(SpectrumPalette.text3),
        at: CGPoint(x: 1, y: y(dBm)),
        anchor: .leading,
        within: panel.minY...panel.maxY
      )
    }

    // 7. the keys: "+6 +20 +35" at the top left, "avg · peak" at the top right
    if showsKeys, history.hasData {
      let keyY = inner.minY + 8
      let levels = [SpectrumLevel.signal, .strong, .veryStrong].map { level in
        Text("+" + String(Int(level.from))).foregroundStyle(SpectrumPalette.line(level))
      }
      let levelKey = levels.dropFirst().reduce(levels[0]) { Text("\($0) \($1)") }
      chip(in: context, levelKey.font(Self.keyFont), at: CGPoint(x: 1, y: keyY), anchor: .leading)

      let average = Text(L10n.Tools.Tools.Spectrum.Device.Key.avg)
        .foregroundStyle(increasedContrast ? SpectrumPalette.noise : SpectrumPalette.avgRef)
      let dotText = Text(" · ").foregroundStyle(keyTextColor)
      let peak = Text(L10n.Tools.Tools.Spectrum.Device.Key.peak).foregroundStyle(SpectrumPalette.warning)
      chip(in: context, Text("\(average)\(dotText)\(peak)").font(Self.keyFont), at: CGPoint(x: width - 1, y: keyY), anchor: .trailing)
    }
  }

  /// The columns with readings, as runs of neighbours: a column without one breaks the line.
  private func runs() -> [[Int]] {
    var runs: [[Int]] = []
    var run: [Int] = []
    for (index, level) in levels.enumerated() {
      if level != nil {
        run.append(index)
      } else if !run.isEmpty {
        runs.append(run)
        run = []
      }
    }
    if !run.isEmpty { runs.append(run) }
    return runs
  }

  /// `points` as a curve through each of them (a Catmull-Rom spline as cubic curves), its
  /// control points held within each segment's levels so the line never overshoots a peak or a
  /// trough. Appended to `path` as a new subpath, or joined to its current point when continuing.
  static func smooth(_ points: [CGPoint], into path: inout Path, continuing: Bool) {
    guard let first = points.first else { return }
    if continuing {
      path.addLine(to: first)
    } else {
      path.move(to: first)
    }
    guard points.count > 1 else { return }
    for index in 0..<(points.count - 1) {
      let p0 = points[max(index - 1, 0)]
      let p1 = points[index]
      let p2 = points[index + 1]
      let p3 = points[min(index + 2, points.count - 1)]
      let low = min(p1.y, p2.y)
      let high = max(p1.y, p2.y)
      let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(max(p1.y + (p2.y - p0.y) / 6, low), high))
      let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(max(p2.y - (p3.y - p1.y) / 6, low), high))
      path.addCurve(to: p2, control1: c1, control2: c2)
    }
  }

  /// ▼ with its tip 2 pt over the rule, or ▲ 2 pt under it when the panel has no room above.
  private func peakMarker(x: CGFloat, ruleY: CGFloat, above: Bool) -> Path {
    var path = Path()
    let tip = above ? ruleY - 2 : ruleY + 2
    let base = above ? tip - 5 : tip + 5
    path.move(to: CGPoint(x: x, y: tip))
    path.addLine(to: CGPoint(x: x - 3.5, y: base))
    path.addLine(to: CGPoint(x: x + 3.5, y: base))
    path.closeSubpath()
    return path
  }

  // MARK: Density

  func drawDensity(in context: GraphicsContext, raster: CGImage?, showsKeys: Bool) {
    let panel = layout.density(width: width)
    let panelPath = densityPanelPath(panel)
    context.fill(panelPath, with: .color(SpectrumPalette.panel))
    guard history.hasData, let raster, history.ncols > 0 else { return }
    let inner = layout.densityInner(width: width)
    // The heat image stretched over the grid, a pixel per cell, interpolated between them: it
    // slides with the columns, its left edge at column 0 and its right at the newest column's end.
    let left = columns.x(0)
    let right = columns.x(history.ncols)
    context.drawLayer { layer in
      layer.clip(to: panelPath)
      layer.clip(to: Path(inner))
      layer.draw(
        Image(decorative: raster, scale: 1).resizable().interpolation(.high),
        in: CGRect(x: left, y: inner.minY, width: max(right - left, 1), height: inner.height)
      )
    }

    // the key in the top rows, which are high dB and rarely filled
    if showsKeys {
      heatKey(in: context, trailing: width - 1, y: inner.minY + 8)
    }
  }

  /// "rare ▬▬▬ often" on a panel chip, its right edge at `trailing`.
  private func heatKey(in context: GraphicsContext, trailing: CGFloat, y: CGFloat) {
    let rare = context.resolve(Text(L10n.Tools.Tools.Spectrum.Device.Key.rare).font(Self.keyFont).foregroundStyle(keyTextColor))
    let often = context.resolve(Text(L10n.Tools.Tools.Spectrum.Device.Key.often).font(Self.keyFont).foregroundStyle(keyTextColor))
    let rareSize = rare.measure(in: CGSize(width: width, height: 40))
    let oftenSize = often.measure(in: CGSize(width: width, height: 40))
    let ramp: CGFloat = 32
    let gap: CGFloat = 3
    let total = rareSize.width + gap + ramp + gap + oftenSize.width + 4
    let height = max(rareSize.height, oftenSize.height)
    let left = trailing - total
    context.fill(Path(CGRect(x: left, y: y - height / 2, width: total, height: height)), with: .color(SpectrumPalette.panel))
    var x = left + 2
    context.draw(rare, at: CGPoint(x: x, y: y), anchor: .leading)
    x += rareSize.width + gap
    for step in 0..<Int(ramp) {
      context.fill(
        Path(CGRect(x: x + CGFloat(step), y: y - 2, width: 1, height: 4)),
        with: .color(SpectrumHeat.color(SpectrumHeat.keyIndex(step, steps: Int(ramp))))
      )
    }
    x += ramp + gap
    context.draw(often, at: CGPoint(x: x, y: y), anchor: .leading)
  }

  // MARK: Cursor

  func drawCursor(in context: GraphicsContext, column: Int) {
    let x = columnMid(min(max(column, 0), max(history.ncols - 1, 0))) - 0.5
    guard x >= 0, x <= width else { return }
    let trace = layout.traceInner(width: width)
    let density = layout.densityInner(width: width)
    context.fill(Path(CGRect(x: x, y: trace.minY, width: 1, height: trace.height)), with: .color(.primary))
    context.fill(Path(CGRect(x: x, y: density.minY, width: 1, height: density.height)), with: .color(.primary))
  }

  // MARK: Helpers

  /// The trace panel: the plot's outer radius on top, and where it meets the density panel the
  /// small inner radius (the outer one too when there is no density panel under it).
  private func tracePanelPath(_ panel: CGRect) -> Path {
    let outer = layout.cornerRadius
    let bottom = layout.densityHeight > 0 ? SpectrumDeviceLayout.innerCornerRadius : outer
    return Path(roundedRect: panel, cornerRadii: RectangleCornerRadii(topLeading: outer, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: outer), style: .continuous)
  }

  /// The density panel: the small inner radius where it meets the trace, the outer one below.
  private func densityPanelPath(_ panel: CGRect) -> Path {
    let outer = layout.cornerRadius
    let inner = SpectrumDeviceLayout.innerCornerRadius
    return Path(roundedRect: panel, cornerRadii: RectangleCornerRadii(topLeading: inner, bottomLeading: outer, bottomTrailing: outer, topTrailing: inner), style: .continuous)
  }

  private func horizontal(at y: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: 0, y: y))
    path.addLine(to: CGPoint(x: width, y: y))
    return path
  }

  /// `text` on a panel-coloured chip, so nothing shows through it; kept inside `within` (a y
  /// range) when one is given.
  private func chip(
    in context: GraphicsContext, _ text: Text, at point: CGPoint, anchor: UnitPoint,
    within bounds: ClosedRange<CGFloat>? = nil
  ) {
    let resolved = context.resolve(text)
    let size = resolved.measure(in: CGSize(width: width, height: 40))
    let chipWidth = size.width + 4
    let left = anchor == .trailing ? point.x - chipWidth : point.x
    let centre = bounds.map {
      SpectrumTraceGeometry.labelCentre(lineY: point.y, labelHeight: size.height, in: $0)
    } ?? point.y
    context.fill(
      Path(CGRect(x: left, y: centre - size.height / 2, width: chipWidth, height: size.height)),
      with: .color(SpectrumPalette.panel)
    )
    context.draw(resolved, at: CGPoint(x: left + 2, y: centre), anchor: .leading)
  }
}
