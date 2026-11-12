import Charts
import CairnServices
import SwiftUI

/// Cairn's Channel view on one time axis: a packet lane along the top, one marker per received
/// packet in its type's color and as wide as its airtime, and under it the noise floor's
/// min-to-max band with its average, each packet at the strength it arrived with, the floor now
/// (dashed) and the window's peak (dotted). Tapping a marker or a packet selects it.
///
/// The chart lays its content out once a tick (`now`), a little past the window either way, and
/// between ticks the plot scrolls across it by the clock at the screen's pace, so the line slides
/// smoothly without the chart being laid out again each frame. Its columns sit on a grid fixed
/// on the clock, so nothing drawn changes shape as it goes by.
struct SpectrumChannelChart: View {
  let channel: LoRaChannelMath
  let viewModel: SpectrumViewModel
  /// The packet ring in time order, as laid out once for this tick.
  let packets: [SpectrumPacket]
  let window: SpectrumWindow
  /// The tick the content is laid out for; the plot's right edge runs on from it by the clock.
  let now: Date
  @Binding var selectedPacketID: UUID?
  /// The cursor's moment: a tap away from any packet puts it there, another near it clears it.
  @State private var cursorDate: Date?
  /// The plot's frame within the chart, for the taps and the time axis under it.
  @State private var plotFrame: CGRect = .zero
  @State private var chartWidth: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  /// The lane sits above the trace on the same dB axis, in a band this share of the trace's
  /// span, so the two can never drift out of line horizontally.
  private static let laneGap = 0.05
  private static let laneHeight = 0.12
  /// A tap this close to a packet (in points) selects it.
  private static let hitRadius: CGFloat = 16
  /// The narrowest a lane marker is drawn, as a share of the window: a 40 ms packet on the
  /// hour window would otherwise vanish.
  private static let minimumMarkerShare = 1.0 / 180

  /// The window as of the tick, for the figures and VoiceOver.
  private var domain: ClosedRange<Date> { now.addingTimeInterval(-window.duration)...now }

  /// What the chart lays out: the window and a tick's worth either side, for the plot to scroll
  /// across before the next tick lays out again.
  private var dataDomain: ClosedRange<Date> {
    now.addingTimeInterval(-window.duration - window.refreshInterval)...now.addingTimeInterval(window.refreshInterval)
  }

  private var visiblePackets: [SpectrumPacket] {
    Array(self.packets.suffix(since: dataDomain.lowerBound, date: \.date).prefix { $0.date <= now })
  }

  var body: some View {
    let packets = visiblePackets
    // The long windows draw a thinned set of marks; the peak and VoiceOver still see them all.
    let marks = window.packetMarkColumns.map {
      SpectrumPacketMarks.thin(packets, in: dataDomain, columns: $0, keeping: selectedPacketID)
    } ?? packets
    let buckets = SpectrumBuckets.aligned(
      viewModel.noise.elements.suffix(since: dataDomain.lowerBound.addingTimeInterval(-MiniSpectrumFrame.floorHold), date: \.date),
      in: dataDomain,
      width: window.duration / Double(window.bucketCount(readingInterval: viewModel.readingInterval)),
      // A missed reading or two, or history read at Normal on a Live chart, isn't a gap.
      bridging: 2.5 * viewModel.readingInterval,
      holding: MiniSpectrumFrame.floorHold
    )
    let peak = packets.compactMap(\.rssi).max()
    let floor = viewModel.currentNoiseFloor
    let bottom = viewModel.traceBottom ?? SpectrumTraceScale.bottom(floor: floor)
    let trace = SpectrumTraceScale.domain(bottom: bottom, peak: peak)
    let span = trace.upperBound - trace.lowerBound
    let lane = (trace.upperBound + span * Self.laneGap)...(trace.upperBound + span * (Self.laneGap + Self.laneHeight))
    let lonely = Set(Dictionary(grouping: buckets, by: \.segment).filter { $0.value.count == 1 }.keys)

    VStack(spacing: 2) {
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || viewModel.isPaused || scenePhase != .active)) { timeline in
        chart(
          packets: packets, marks: marks, buckets: buckets, peak: peak, floor: floor, trace: trace, lane: lane, lonely: lonely,
          liveNow: reduceMotion ? now : viewModel.displayNow(max(timeline.date, now))
        )
      }
      MiniSpectrumTimeAxis(window: window)
        .padding(.leading, plotFrame.minX)
        .padding(.trailing, max(chartWidth - plotFrame.maxX, 0))
    }
  }

  /// The chart's content as laid out for the tick, scrolled so its right edge is `liveNow`.
  private func chart(
    packets: [SpectrumPacket], marks: [SpectrumPacket], buckets: [SpectrumBucket], peak: Double?, floor: Double?,
    trace: ClosedRange<Double>, lane: ClosedRange<Double>, lonely: Set<Int>, liveNow: Date
  ) -> some View {
    Chart {
      // The floor's spread in each column, then its average as the line through it.
      ForEach(buckets) { bucket in
        AreaMark(
          x: .value("Time", bucket.mid),
          yStart: .value("dBm", bucket.min),
          yEnd: .value("dBm", bucket.max),
          series: .value("Segment", "band-\(bucket.segment)")
        )
        .foregroundStyle(SpectrumPalette.noise.opacity(0.22))
        .interpolationMethod(.monotone)

        LineMark(
          x: .value("Time", bucket.mid),
          y: .value("dBm", bucket.avg),
          series: .value("Segment", "avg-\(bucket.segment)")
        )
        .foregroundStyle(SpectrumPalette.noise)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.monotone)

        // A reading with no neighbour draws no line; give it a dot.
        if lonely.contains(bucket.segment) {
          PointMark(x: .value("Time", bucket.mid), y: .value("dBm", bucket.avg))
            .foregroundStyle(SpectrumPalette.noise)
            .symbolSize(20)
        }
      }

      if let floor {
        RuleMark(y: .value("dBm", floor))
          .foregroundStyle(Color.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
      if let peak {
        RuleMark(y: .value("dBm", peak))
          .foregroundStyle(SpectrumPalette.peak)
          .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
      }

      if let cursorDate {
        RuleMark(x: .value("Time", cursorDate))
          .foregroundStyle(Color.primary.opacity(0.7))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(position: .top, alignment: .leading, spacing: 2) {
            cursorLabel(cursorDate, buckets: buckets)
          }
      }
      ForEach(marks) { packet in
        laneMarker(packet, lane: lane)
        if let rssi = packet.rssi {
          let y = min(max(rssi, trace.lowerBound), trace.upperBound)
          let selected = packet.id == selectedPacketID
          // A packet clear of the noise wears a ring in its level's color (Cairn's level
          // classes), with a hairline of the surface between ring and dot; in the noise, the
          // surface-colored ring alone keeps dots apart where they overlap the band.
          let ring = SpectrumLevel(rssi: rssi, floor: floor).color
          if let ring {
            PointMark(x: .value("Time", packet.date), y: .value("dBm", y))
              .foregroundStyle(ring)
              .symbolSize(selected ? 190 : 100)
          }
          PointMark(x: .value("Time", packet.date), y: .value("dBm", y))
            .foregroundStyle(.background)
            .symbolSize(ring == nil ? (selected ? 150 : 80) : (selected ? 140 : 60))
          PointMark(x: .value("Time", packet.date), y: .value("dBm", y))
            .foregroundStyle(packet.kind.color)
            .symbolSize(selected ? 90 : 36)
        }
      }
    }
    .chartXScale(domain: dataDomain)
    .chartScrollableAxes(.horizontal)
    .chartXVisibleDomain(length: window.duration)
    .chartScrollPosition(x: .constant(liveNow.addingTimeInterval(-window.duration)))
    .scrollDisabled(true)
    .chartYScale(domain: trace.lowerBound...lane.upperBound)
    .chartYAxis {
      AxisMarks(position: .leading, values: SpectrumTraceScale.gridlines(in: trace)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(SpectrumPalette.grid)
        AxisValueLabel {
          if let dBm = value.as(Double.self) {
            Text(Int(dBm), format: .number)
              .monospacedDigit()
          }
        }
      }
    }
    // The time axis is drawn under the chart (`MiniSpectrumTimeAxis`): its labels are ages, which
    // would slide with the content here.
    .chartXAxis(.hidden)
    .chartOverlay { proxy in
      // The plot's frame, taken from the proxy here: its anchor goes into the change closure, not
      // the proxy itself, which isn't Sendable.
      let plotAnchor = proxy.plotFrame
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(.rect)
          .onTapGesture { location in
            select(at: location, packets: marks)
          }
          .onGeometryChange(for: CGRect.self) { geo in plotAnchor.map { geo[$0] } ?? .zero } action: { plotFrame = $0 }
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
      }
    }
    .overlay {
      if buckets.isEmpty, packets.isEmpty {
        Text(viewModel.isCalibrating ? L10n.Tools.Tools.Spectrum.calibrating : L10n.Tools.Tools.Spectrum.waiting)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Tools.Tools.Spectrum.Chart.label)
    .accessibilityValue(L10n.Tools.Tools.Spectrum.Chart.summary(buckets.reduce(0) { $0 + $1.count }, packets.count, window.spokenTitle))
    .accessibilityChartDescriptor(SpectrumChartDescriptor(window: window, now: now, buckets: buckets, packets: packets, trace: trace))
  }

  /// A packet's slot in the lane: ending when it was captured, as wide as its time on air.
  private func laneMarker(_ packet: SpectrumPacket, lane: ClosedRange<Double>) -> some ChartContent {
    let width = max(channel.timeOnAir(payloadBytes: packet.size), window.duration * Self.minimumMarkerShare)
    let selected = packet.id == selectedPacketID
    return RectangleMark(
      xStart: .value("Time", packet.date.addingTimeInterval(-width)),
      xEnd: .value("Time", packet.date),
      yStart: .value("dBm", lane.lowerBound),
      yEnd: .value("dBm", lane.upperBound)
    )
    .foregroundStyle(packet.kind.color)
    .cornerRadius(1.5)
    .opacity(selectedPacketID == nil || selected ? 1 : 0.55)
  }

  /// Selects the packet nearest the tap along the time axis, or clears the selection when none
  /// is within reach. Ties go to the newer packet, as on the radio. Placed on the plot as it
  /// stands at the tap, its right edge at the clock.
  private func select(at location: CGPoint, packets: [SpectrumPacket]) {
    guard plotFrame.width > 0 else { return }
    let start = (reduceMotion ? now : viewModel.displayNow(.now)).addingTimeInterval(-window.duration)
    func position(of date: Date) -> CGFloat {
      plotFrame.minX + CGFloat(date.timeIntervalSince(start) / window.duration) * plotFrame.width
    }
    let x = location.x
    var best: (id: UUID, distance: CGFloat)?
    for packet in packets {
      let distance = abs(position(of: packet.date) - x)
      if distance <= Self.hitRadius, distance <= (best?.distance ?? .infinity) {
        best = (packet.id, distance)
      }
    }
    selectedPacketID = best?.id == selectedPacketID ? nil : best?.id
    // Away from any packet: the cursor goes there, or away when it was already near.
    guard best == nil else {
      cursorDate = nil
      return
    }
    if let cursorDate, abs(position(of: cursorDate) - x) <= Self.hitRadius {
      self.cursorDate = nil
    } else {
      cursorDate = start.addingTimeInterval(Double((x - plotFrame.minX) / plotFrame.width) * window.duration)
    }
  }

  /// The cursor's readout: its age, and the floor's lowest and highest readings in that moment's
  /// bucket, as the Radio Screen's cursor reads a column.
  private func cursorLabel(_ date: Date, buckets: [SpectrumBucket]) -> some View {
    let when = SpectrumReadout.age(milliseconds: UInt32(clamping: Int(max(0, now.timeIntervalSince(date)) * 1000)))
    let bucket = buckets.first { $0.start <= date && date < $0.end } ?? buckets.last { $0.start <= date }
    let text = bucket.map { "\(when) · \(Int($0.min.rounded()))…\(Int($0.max.rounded())) dBm" } ?? when
    return Text(text)
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.primary)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(SpectrumPalette.card, in: .rect(cornerRadius: 3))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SpectrumPalette.border, lineWidth: 1))
  }
}

// MARK: - Audio graph

/// The chart for VoiceOver's audio graph: the floor's average and each packet, by age.
private struct SpectrumChartDescriptor: AXChartDescriptorRepresentable {
  let window: SpectrumWindow
  let now: Date
  let buckets: [SpectrumBucket]
  let packets: [SpectrumPacket]
  let trace: ClosedRange<Double>

  func makeChartDescriptor() -> AXChartDescriptor {
    let xAxis = AXNumericDataAxisDescriptor(
      title: L10n.Tools.Tools.Spectrum.Axis.secondsAgo,
      range: -window.duration...0,
      gridlinePositions: []
    ) { value in
      Duration.seconds(abs(value).rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
    let yAxis = AXNumericDataAxisDescriptor(
      title: L10n.Tools.Tools.Spectrum.Axis.dbm,
      range: trace,
      gridlinePositions: []
    ) { value in
      SpectrumFormat.dBm(value)
    }
    let noise = AXDataSeriesDescriptor(
      name: L10n.Tools.Tools.Spectrum.Legend.noise,
      isContinuous: true,
      dataPoints: buckets.map { AXDataPoint(x: $0.mid.timeIntervalSince(now), y: $0.avg) }
    )
    let heard = AXDataSeriesDescriptor(
      name: L10n.Tools.Tools.Spectrum.Legend.packets,
      isContinuous: false,
      dataPoints: packets.compactMap { packet in
        packet.rssi.map { AXDataPoint(x: packet.date.timeIntervalSince(now), y: $0, label: packet.kind.title) }
      }
    )
    return AXChartDescriptor(
      title: L10n.Tools.Tools.Spectrum.Chart.label,
      summary: nil,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: [noise, heard]
    )
  }
}

// MARK: - Legend

/// What each mark means, drawn the way the chart draws it, then the packet types by color and
/// the level key their rings follow.
struct SpectrumChartLegend: View {
  /// The chart's own marks: the radio-style chart's, which the large spectrum doesn't draw.
  var showsSeries = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsSeries {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 14) { series }
          VStack(alignment: .leading, spacing: 6) { series }
        }
      }
      // Each kind's code beside its name, which is where the chart's and the log's codes are
      // learned, as many to a line as fit.
      FlowRow(spacing: 7) {
        ForEach(SpectrumPacketKind.legendOrder, id: \.self) { kind in
          HStack(spacing: 3) {
            SpectrumKindPill(kind: kind)
              .accessibilityHidden(true)
            Text(kind.title)
              .font(.caption2)
              .lineLimit(1)
              .fixedSize()
          }
        }
      }
      .accessibilityElement(children: .combine)
      levelKey
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var series: some View {
    entry(L10n.Tools.Tools.Spectrum.Legend.floorRange) {
      RoundedRectangle(cornerRadius: 2)
        .fill(SpectrumPalette.noise.opacity(0.22))
        .frame(width: 16, height: 10)
    }
    entry(L10n.Tools.Tools.Spectrum.Legend.noise) { stroke(SpectrumPalette.noise, StrokeStyle(lineWidth: 2, lineCap: .round)) }
    entry(L10n.Tools.Tools.Spectrum.Legend.peakPacket) { stroke(SpectrumPalette.peak, StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3])) }
    entry(L10n.Tools.Tools.Spectrum.Legend.packets) {
      Circle().fill(Color.secondary).frame(width: 7, height: 7)
    }
  }

  /// Cairn's level key: "+6 +20 +35" in the ring colors, then what the numbers measure. A packet
  /// under +6 has no ring.
  private var levelKey: some View {
    HStack(spacing: 4) {
      HStack(spacing: 3) {
        ForEach([SpectrumLevel.signal, .strong, .veryStrong], id: \.self) { level in
          Text("+" + Int(level.from).formatted())
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(level.color ?? .secondary)
        }
      }
      Text(L10n.Tools.Tools.Spectrum.Legend.levels)
    }
    .accessibilityElement(children: .combine)
  }

  private func entry(_ title: String, @ViewBuilder swatch: () -> some View) -> some View {
    HStack(spacing: 4) {
      swatch()
        .frame(width: 18, height: 10)
        .accessibilityHidden(true)
      Text(title)
    }
  }

  private func stroke(_ color: Color, _ style: StrokeStyle) -> some View {
    Path { path in
      path.move(to: CGPoint(x: 1, y: 5))
      path.addLine(to: CGPoint(x: 17, y: 5))
    }
    .stroke(color, style: style)
  }
}

/// A packet type as Cairn prints it: the three-letter code in the type's color, read aloud as
/// the type's name; or the name itself where there's room for it.
struct SpectrumKindPill: View {
  let kind: SpectrumPacketKind
  var showsName = false

  var body: some View {
    Text(showsName ? kind.title : kind.code)
      .font(showsName ? .caption.weight(.bold) : .caption.weight(.bold).monospaced())
      .foregroundStyle(kind.color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(kind.color.opacity(0.14), in: .capsule)
      .accessibilityLabel(kind.title)
  }
}
