import CoreGraphics
import SwiftUI

/// The Waterfall style of the Spectrum tab's channel (Settings › Spectrum › Chart Style): the
/// channel as an SDR's waterfall shows it, frequency across and time down. The band is centred on
/// the radio's channel, the channel's own width lit by what the radio reads: the reading's level
/// through the firmware's inferno ramp, from the floor's dim violet to a strong packet's yellow,
/// rolling off at the channel's edges. The newest moment is the top row under a bright line for
/// now, and the rows flow down by the clock and off the bottom. The radio reads its channel about
/// once a second (a Cairn radio several times a second); between readings the raster interpolates
/// in time and each reading eases in over a few frames, so the picture flows rather than steps.
/// Outside the channel the radio measures nothing: that stretch is drawn at the floor, dim, so
/// the channel reads as a band on it. The packets heard sit as markers across the channel at the
/// moment they came, in their kinds' colours. Holds still with Reduce Motion on.
struct WaterfallSpectrumView: View {
  let frame: MiniSpectrumFrame
  /// The channel's centre and width, for the band and its labels; nil draws a nameless band.
  var channelHz: Double?
  var bandwidthHz: Double?
  /// Unused by the waterfall, whose packets sit on the band itself; kept so every style takes the
  /// same arguments.
  var laneHeight: CGFloat = 20
  /// The picked mark, ringed with a line across its row.
  var selectedPacketID: UUID?
  var selectedRxMs: UInt32?
  /// A tap picks the packet nearest it, or nil away from any. Nil leaves taps to what's around it.
  var onSelectMark: ((MiniSpectrumFrame.Mark?) -> Void)?
  /// The moment the plot is held at while its page is paused; nil while live.
  var heldAt: Date?
  /// The cursor, as seconds before the newest bar's end (`SpectrumCursor`); nil for none.
  var cursor: TimeInterval?
  /// A tap away from any packet puts the cursor there (or clears it): the moment tapped, or nil.
  var onCursorTap: ((TimeInterval?) -> Void)?
  /// The glass's corners.
  var cornerRadius: CGFloat = 12

  /// A tap this close to a packet's row picks it.
  private static let hitRadius: CGFloat = 14

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @State private var isVisible = false
  @State private var plotSize: CGSize = .zero
  @State private var raster = WaterfallRaster()

  private func geometry(at date: Date, size: CGSize) -> WaterfallGeometry {
    WaterfallGeometry(
      barCount: frame.bars.count,
      barSeconds: frame.barSeconds,
      secondsPastNewest: reduceMotion ? 0 : date.timeIntervalSince(frame.newestDate),
      size: size
    )
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !isVisible || scenePhase != .active || heldAt != nil)) { timeline in
      Canvas { context, size in
        let date = heldAt ?? timeline.date
        let geometry = geometry(at: date, size: size)
        let band = WaterfallBand(channelHz: channelHz, bandwidthHz: bandwidthHz)
        let image = raster.render(
          frame: frame,
          geometry: geometry,
          band: band,
          at: date,
          animated: !reduceMotion,
          scale: min(displayScale, 2)
        )
        WaterfallPainter(
          frame: frame,
          geometry: geometry,
          band: band,
          raster: image,
          selectedPacketID: selectedPacketID,
          selectedRxMs: selectedRxMs
        ).draw(in: &context)
        // The cursor: a line across the plot at its moment.
        if let cursor {
          let y = geometry.y(secondsBeforeNewest: cursor).rounded()
          if y >= geometry.plot.minY, y <= geometry.plot.maxY {
            context.fill(
              Path(CGRect(x: geometry.plot.minX, y: y - 0.5, width: geometry.plot.width, height: 1)),
              with: .color(.white.opacity(0.85))
            )
            SpectrumMarkerGlyph.tag(in: &context, "M1", at: CGPoint(x: geometry.plot.minX + 2, y: y + 2), color: .white)
          }
        }
      }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { plotSize = $0 }
    .gesture(SpatialTapGesture().onEnded { value in
      guard onSelectMark != nil || onCursorTap != nil else { return }
      let geometry = geometry(at: heldAt ?? .now, size: plotSize)
      let nearest = frame.marks
        .map { (mark: $0, gap: abs(geometry.y(secondsBeforeNewest: $0.secondsBeforeNewest) - value.location.y)) }
        .min { $0.gap < $1.gap }
      if let onSelectMark, let mark = nearest.flatMap({ $0.gap <= Self.hitRadius ? $0.mark : nil }) {
        onSelectMark(mark)
        onCursorTap?(nil)
      } else {
        onSelectMark?(nil)
        onCursorTap?(SpectrumCursor.toggled(
          cursor, tapped: geometry.secondsBeforeNewest(atY: value.location.y), barSeconds: frame.barSeconds
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

/// Where the waterfall puts each moment: the raster fills the whole plot, time running down it
/// from the newest moment at the top; the frequency labels along the bottom sit over it.
struct WaterfallGeometry {
  let barCount: Int
  let barSeconds: TimeInterval
  /// How far the present has moved past the newest bar's end; below 0 that bar is still coming.
  let secondsPastNewest: TimeInterval
  let size: CGSize

  /// The frequency labels along the bottom.
  static let labelHeight: CGFloat = 14

  var plot: CGRect {
    CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
  }

  /// How long the plot spans, top to bottom.
  var span: TimeInterval {
    Double(max(barCount, 1)) * barSeconds
  }

  /// The y of a moment `seconds` before the newest bar's end.
  func y(secondsBeforeNewest seconds: TimeInterval) -> CGFloat {
    plot.minY + CGFloat((seconds + secondsPastNewest) / max(span, 0.001)) * plot.height
  }

  /// The moment `y` stands for, in seconds before the newest bar's end.
  func secondsBeforeNewest(atY y: CGFloat) -> TimeInterval {
    Double((y - plot.minY) / max(plot.height, 1)) * span - secondsPastNewest
  }
}

/// The band across the waterfall: the channel's centre and width, and the stretch shown around it.
struct WaterfallBand {
  let channelHz: Double?
  let bandwidthHz: Double?

  /// The stretch shown: four channel widths, so the channel sits as a band in the middle of it.
  var spanHz: Double {
    max((bandwidthHz ?? 125_000) * 4, 100_000)
  }

  /// The channel's share of the plot's width, 0 to 1, as a centred range.
  var channelRange: ClosedRange<Double> {
    let half = (bandwidthHz ?? spanHz / 4) / spanHz / 2
    return (0.5 - half)...(0.5 + half)
  }

  /// How much of the reading reaches `position` across the plot (0 to 1): all of it within the
  /// channel, rolling off as a raised cosine over a sixth of the channel past each edge, none
  /// further out.
  func profile(at position: Double) -> Double {
    let range = channelRange
    let width = range.upperBound - range.lowerBound
    let rollOff = width / 6
    if range.contains(position) { return 1 }
    let distance = position < range.lowerBound ? range.lowerBound - position : position - range.upperBound
    guard distance < rollOff else { return 0 }
    return 0.5 * (1 + cos(.pi * distance / rollOff))
  }
}

/// The waterfall's pixels: a bitmap of the plot drawn fresh each frame from the readings, every
/// row a moment and every column a frequency. A reading's level is interpolated in time between
/// the bars' centres and eased in over a few frames as it lands, so rows never step. Kept by the
/// view across frames for the eased levels, keyed by each bar's place on the clock as
/// `MiniSpectrumHistory` keeps its bars.
@MainActor
final class WaterfallRaster {
  /// How long a reading takes to ease in.
  nonisolated static let easeIn: TimeInterval = 0.25
  /// The scale's floor, where the dark of the ramp begins.
  nonisolated static let floorLevel = MiniSpectrumFrame.height(dBOverFloor: 0)
  /// The grain over the band, a touch of the ramp, so the raster reads as a measurement rather
  /// than a fill. Cosmetic and tiny: well under a decibel.
  nonisolated static let grain = 0.018

  /// The firmware's inferno ramp, smoothed to 256 steps, as 0xAARRGGBB.
  nonisolated static let ramp: [UInt32] = {
    let stops = (0..<SpectrumHeat.count).map { SpectrumHeat.rgb($0) }
    return (0..<256).map { step in
      let position = Double(step) / 255 * Double(stops.count - 1)
      let index = min(Int(position), stops.count - 2)
      let fraction = position - Double(index)
      func channel(_ shift: Int) -> UInt32 {
        let low = Double((stops[index] >> shift) & 0xFF)
        let high = Double((stops[index + 1] >> shift) & 0xFF)
        return UInt32((low + (high - low) * fraction).rounded())
      }
      return 0xFF00_0000 | channel(16) << 16 | channel(8) << 8 | channel(0)
    }
  }()

  private var eased: [Int64: Double] = [:]
  private var lastTick: TimeInterval?
  private var barSeconds: TimeInterval = 0
  private var newestKey: Int64?

  /// The plot's bitmap for `frame` at `date`, `scale` pixels to the point.
  func render(
    frame: MiniSpectrumFrame,
    geometry: WaterfallGeometry,
    band: WaterfallBand,
    at date: Date,
    animated: Bool,
    scale: CGFloat
  ) -> CGImage? {
    let levels = easedLevels(frame: frame, at: date, animated: animated)
    let plot = geometry.plot
    let width = max(Int((plot.width * scale).rounded()), 1)
    let height = max(Int((plot.height * scale).rounded()), 1)
    let count = levels.count
    guard count > 0 else { return nil }

    // Each column's share of the reading, and the grain's seed for it.
    let profile = (0..<width).map { band.profile(at: (Double($0) + 0.5) / Double(width)) }
    let floorLevel = Self.floorLevel
    let span = geometry.span
    let barSeconds = max(frame.barSeconds, 0.001)
    let grainStep = barSeconds / 4

    var pixels = [UInt32](repeating: Self.ramp[0], count: width * height)
    pixels.withUnsafeMutableBufferPointer { buffer in
      for row in 0..<height {
        // The moment this row stands for, by the bars' centres: the newest bar's centre is half
        // a bar before its end, and the present holds the newest reading until the next lands.
        let seconds = max((Double(row) + 0.5) / Double(height) * span - geometry.secondsPastNewest, 0)
        let position = Double(count) - 0.5 - seconds / barSeconds
        let level: Double
        if position >= Double(count - 1) {
          level = levels[count - 1]
        } else if position <= 0 {
          level = levels[0]
        } else {
          let index = Int(position)
          let fraction = position - Double(index)
          // Smoothstep, so a row sits on each reading rather than on the straight line between them.
          let eased = fraction * fraction * (3 - 2 * fraction)
          level = levels[index] + (levels[index + 1] - levels[index]) * eased
        }
        let rowSeed = Int64((seconds + geometry.secondsPastNewest) / grainStep) &* 19_349_663
        let base = row * width
        for column in 0..<width {
          let hash = (Int64(column) &* 73_856_093) ^ rowSeed
          let noise = (Double(hash & 0xFF) / 255 - 0.5) * Self.grain
          var intensity = floorLevel + (level - floorLevel) * profile[column] + noise
          intensity = min(max(intensity, 0), 1)
          buffer[base + column] = Self.ramp[Int(intensity * 255)]
        }
      }
    }
    return Self.image(from: pixels, width: width, height: height)
  }

  /// Each bar's level on its way to its reading, oldest first; a bar without a reading sits at
  /// the floor.
  private func easedLevels(frame: MiniSpectrumFrame, at date: Date, animated: Bool) -> [Double] {
    let now = date.timeIntervalSinceReferenceDate
    let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
    lastTick = now
    let count = Int64(frame.bars.count)
    let jumpedBack = newestKey.map { frame.newestKey < $0 - count } ?? false
    if abs(frame.barSeconds - barSeconds) > 0.0001 || jumpedBack {
      eased = [:]
      barSeconds = frame.barSeconds
    }
    newestKey = frame.newestKey
    let blend = animated ? 1 - exp(-dt / Self.easeIn) : 1

    var levels: [Double] = []
    levels.reserveCapacity(frame.bars.count)
    for (index, bar) in frame.bars.enumerated() {
      let key = frame.newestKey - (count - 1 - Int64(index))
      let target = bar.dBm != nil ? bar.height(current: frame.floor) : Self.floorLevel
      let shown: Double = if let current = eased[key] {
        current + (target - current) * blend
      } else {
        animated && bar.dBm != nil ? Self.floorLevel + (target - Self.floorLevel) * blend : target
      }
      eased[key] = shown
      levels.append(shown)
    }
    let oldest = frame.newestKey - count
    eased = eased.filter { $0.key > oldest }
    return levels
  }

  private static func image(from pixels: [UInt32], width: Int, height: Int) -> CGImage? {
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  }
}

/// One frame of the Waterfall: the raster, then the channel's edges, the present, the frequency
/// and time labels and the packets over it.
private struct WaterfallPainter {
  let frame: MiniSpectrumFrame
  let geometry: WaterfallGeometry
  let band: WaterfallBand
  let raster: CGImage?
  let selectedPacketID: UUID?
  let selectedRxMs: UInt32?

  private static let nowColor = Color(red: 0.25, green: 0.95, blue: 0.80)
  private static let txColor = Color(red: 1, green: 0.40, blue: 0.62)
  private static let labelFont = Font.system(size: 9, weight: .medium).monospacedDigit()

  func draw(in context: inout GraphicsContext) {
    let size = geometry.size
    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.01, green: 0.01, blue: 0.03)))
    let plot = geometry.plot
    if let raster {
      context.draw(Image(decorative: raster, scale: 1).interpolation(.medium), in: plot)
    }
    // A shade under the labels, so they read over a bright band.
    let strip = CGRect(x: plot.minX, y: plot.maxY - WaterfallGeometry.labelHeight - 6, width: plot.width, height: WaterfallGeometry.labelHeight + 6)
    context.fill(Path(strip), with: .linearGradient(
      Gradient(colors: [.black.opacity(0), .black.opacity(0.6)]),
      startPoint: CGPoint(x: 0, y: strip.minY),
      endPoint: CGPoint(x: 0, y: strip.maxY)
    ))
    drawChannel(in: &context, plot: plot)
    drawTimeLabels(in: &context, plot: plot)
    drawNow(in: &context, plot: plot)
    drawMarks(in: &context, plot: plot)
  }

  /// The channel's edges and centre down the plot, with the band's frequencies along the bottom.
  private func drawChannel(in context: inout GraphicsContext, plot: CGRect) {
    let range = band.channelRange
    var edges = Path()
    for position in [range.lowerBound, range.upperBound] {
      let x = plot.minX + plot.width * CGFloat(position)
      edges.move(to: CGPoint(x: x, y: plot.minY))
      edges.addLine(to: CGPoint(x: x, y: plot.maxY))
    }
    context.stroke(edges, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
    var centre = Path()
    centre.move(to: CGPoint(x: plot.midX, y: plot.minY))
    centre.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
    context.stroke(centre, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 4]))

    let labelY = plot.maxY - WaterfallGeometry.labelHeight / 2
    guard let channelHz = band.channelHz else { return }
    let half = band.spanHz / 2
    let labels: [(CGFloat, String, UnitPoint)] = [
      (plot.minX + 4, SpectrumFormat.megahertz(channelHz - half), .leading),
      (plot.midX, SpectrumFormat.megahertz(channelHz), .center),
      (plot.maxX - 4, SpectrumFormat.megahertz(channelHz + half), .trailing),
    ]
    for (x, text, anchor) in labels {
      context.draw(
        Text(text).font(Self.labelFont).foregroundStyle(.white.opacity(anchor == .center ? 0.85 : 0.5)),
        at: CGPoint(x: x, y: labelY),
        anchor: anchor
      )
    }
    if let bandwidthHz = band.bandwidthHz, plot.width >= 240 {
      // The channel's width, just under the now line between its edges.
      context.draw(
        Text(SpectrumFormat.kilohertz(bandwidthHz)).font(Self.labelFont).foregroundStyle(.white.opacity(0.6)),
        at: CGPoint(x: plot.midX, y: plot.minY + 9),
        anchor: .center
      )
    }
  }

  /// How far down is how long ago: halfway and the plot's whole span, on the right edge.
  private func drawTimeLabels(in context: inout GraphicsContext, plot: CGRect) {
    let span = geometry.span
    guard span > 0, plot.height >= 80 else { return }
    for fraction in [0.5, 1.0] {
      let labelY = min(plot.minY + plot.height * CGFloat(fraction), plot.maxY - WaterfallGeometry.labelHeight - 8)
      context.draw(
        Text(MiniSpectrumTimeAxis.ago(span * fraction)).font(Self.labelFont).foregroundStyle(.white.opacity(0.55)),
        at: CGPoint(x: plot.maxX - 4, y: labelY),
        anchor: .trailing
      )
    }
  }

  /// The present: a bright line along the top, where the next row lands.
  private func drawNow(in context: inout GraphicsContext, plot: CGRect) {
    var line = Path()
    line.move(to: CGPoint(x: plot.minX, y: plot.minY + 0.5))
    line.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + 0.5))
    context.drawLayer { glow in
      glow.addFilter(.blur(radius: 3))
      glow.opacity = 0.8
      glow.stroke(line, with: .color(Self.nowColor), lineWidth: 2.5)
    }
    context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 1)
    if plot.height >= 80 {
      context.draw(
        Text(L10n.Tools.Tools.Spectrum.Axis.now).font(Self.labelFont).foregroundStyle(Self.nowColor),
        at: CGPoint(x: plot.maxX - 4, y: plot.minY + 9),
        anchor: .trailing
      )
    }
  }

  /// The packets heard, each a marker across the channel's band at the moment it came, in its
  /// kind's colour with a dark rim so it reads over the band; the radio's own transmissions a pink
  /// stripe down the left edge. The picked packet is ringed, with a line across its row.
  private func drawMarks(in context: inout GraphicsContext, plot: CGRect) {
    var tx = Path()
    let rowHeight = plot.height / CGFloat(max(frame.bars.count, 1))
    for (index, bar) in frame.bars.enumerated() where bar.isTX {
      let top = geometry.y(secondsBeforeNewest: Double(frame.bars.count - index) * frame.barSeconds)
      guard top + rowHeight >= plot.minY, top <= plot.maxY else { continue }
      tx.addRect(CGRect(x: plot.minX, y: top, width: 2.5, height: rowHeight + 0.5))
    }
    context.fill(tx, with: .color(Self.txColor))

    let range = band.channelRange
    let left = plot.minX + plot.width * CGFloat(range.lowerBound)
    let right = plot.minX + plot.width * CGFloat(range.upperBound)
    for mark in frame.marks {
      let markY = geometry.y(secondsBeforeNewest: mark.secondsBeforeNewest)
      guard markY >= plot.minY - 3, markY <= plot.maxY + 3 else { continue }
      let marker = CGRect(x: left + 2, y: markY - 1.5, width: max(right - left - 4, 6), height: 3)
      let shape = Path(roundedRect: marker, cornerRadius: 1.5)
      context.stroke(shape, with: .color(.black.opacity(0.55)), lineWidth: 1.5)
      context.fill(shape, with: .color(mark.kind.color))
      let isSelected = (mark.packetID != nil && mark.packetID == selectedPacketID)
        || (mark.rxMs != nil && mark.rxMs == selectedRxMs)
      if isSelected {
        context.stroke(Path(roundedRect: marker.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 4), with: .color(.white), lineWidth: 1)
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: markY))
        line.addLine(to: CGPoint(x: plot.maxX, y: markY))
        context.stroke(line, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
      }
    }
  }
}
