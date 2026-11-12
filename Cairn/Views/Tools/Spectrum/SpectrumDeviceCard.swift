import CairnServices
import MeshCore
import SwiftUI

/// The radio's own Channel view, top to bottom as `SpecChannelView` lays it out, for a Cairn radio
/// that sends it (``SpectrumViewModel/Source/device``): the window chips and a Channel pill (the
/// Band sweep stays on the radio), the five boxed readings NOW / FLOOR / BUSY / PKT/MIN / AIR, the
/// plot (lane, trace and density on one x), the time axis and the 24 h floor line.
///
/// A tap on the lane picks the packet nearest it; a tap on the trace or the density puts the
/// cursor there (a tap near it clears it), and a press-and-drag scrubs it, so a plain swipe still
/// scrolls the page.
struct SpectrumDeviceCard: View {
  let viewModel: SpectrumViewModel
  let window: SpectrumWindow
  let onSelectWindow: (SpectrumWindow) -> Void
  /// The selected lane mark's `rxMs`; its card shows under this one.
  @Binding var selectedMark: UInt32?
  /// The view to draw instead of the radio's own: the one the app puts together from its
  /// readings on a radio without one (`SpectrumRadioScreenSource`).
  var history: SpectrumDeviceHistory?
  /// The 24 h floor line to draw instead of the radio's own trend.
  var trend: CairnSpectrumTrend?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The radio's slot under the cursor, so the cursor travels with the columns as they arrive (as a
  /// packet's mark does) rather than standing at one place on the plot; gone once it leaves the window.
  @State private var cursorSlot: Int64?
  @State private var plotWidth: CGFloat = 0

  /// A tap this many columns or fewer from the cursor clears it.
  private static let cursorClearColumns = 3
  /// Taps this far under the lane still reach its marks (`MARK_HIT_BELOW`).
  private static let markHitBelow: CGFloat = 8

  /// The cursor's column on the plot as it stands now.
  private var cursor: Int? {
    (history ?? viewModel.deviceHistory).column(ofSlot: cursorSlot)
  }

  private var layout: SpectrumDeviceLayout {
    SpectrumDeviceLayout(regular: horizontalSizeClass == .regular)
  }

  var body: some View {
    let history = history ?? viewModel.deviceHistory
    VStack(alignment: .leading, spacing: 8) {
      topRow
      SpectrumDeviceReadings(viewModel: viewModel, stats: history.stats)
      plot(history)
      MiniSpectrumTimeAxis(window: window)
        .frame(minHeight: 14)
      SpectrumDeviceTrendRow(trend: trend ?? viewModel.deviceTrend)
    }
    .cardSurface(padding: 12)
    .onChange(of: window) { cursorSlot = nil }
    .onChange(of: history.ncols) { cursorSlot = nil }
    .accessibilityIdentifier("spectrum.device.card")
  }

  // MARK: Top row

  private var topRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        windowChips
        Spacer(minLength: 0)
        channelPill
      }
      VStack(alignment: .leading, spacing: 8) {
        windowChips
        channelPill
      }
    }
  }

  /// The radio's 10s / 1m / 10m / 1h chips: the selected one on the accent's ground.
  private var windowChips: some View {
    HStack(spacing: 2) {
      ForEach(SpectrumWindow.allCases) { option in
        let selected = option == window
        Button {
          onSelectWindow(option)
        } label: {
          Text(option.shortTitle)
            .font(.subheadline.weight(selected ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(selected ? SpectrumPalette.noise : .secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(minWidth: 40, minHeight: 28)
            .background(selected ? SpectrumPalette.accentBackground : .clear, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(option.spokenTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SpectrumPalette.border, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.Tools.Tools.Spectrum.window)
  }

  /// The radio's Channel / Band toggle, Channel alone: the Band sweep runs on the radio.
  private var channelPill: some View {
    HStack(spacing: 0) {
      Text(L10n.Tools.Tools.Spectrum.Figure.channel)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(SpectrumPalette.noise)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(SpectrumPalette.accentBackground, in: .rect(cornerRadius: 5))
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SpectrumPalette.border, lineWidth: 1))
        .accessibilityAddTraits(.isHeader)
      InfoButton(L10n.Tools.Tools.Spectrum.Device.bandInfo, title: L10n.Tools.Tools.Spectrum.Figure.channel)
    }
  }

  // MARK: Plot

  private func plot(_ history: SpectrumDeviceHistory) -> some View {
    let layout = layout
    let sweeping = history.stats?.sweeping == true
    return SpectrumDeviceCanvas(
      history: history,
      layout: layout,
      cursor: cursor,
      selectedMark: selectedMark,
      showsKeys: cursor == nil && selectedMark == nil,
      motion: motion(history),
      heldAt: viewModel.pausedAt
    )
    .overlay(alignment: .topLeading) {
      if let cursor {
        SpectrumReadoutChip(history: history, column: cursor)
          .padding(.top, SpectrumDeviceLayout.laneHeight + SpectrumDeviceLayout.traceInset)
          .padding(.horizontal, 2)
          .onTapGesture { cursorSlot = nil }
      }
    }
    .overlay(alignment: .top) {
      if sweeping {
        SpectrumSweepBanner()
          .padding(.top, SpectrumDeviceLayout.laneHeight + layout.traceHeight / 2 - 14)
          .allowsHitTesting(false)
      }
    }
    .contentShape(.rect)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
    .gesture(
      SpatialTapGesture()
        .onEnded { tap(at: $0.location, history: history) }
    )
    // press and hold, then drag: a UIKit long press, which lets the page's scroll view have every
    // swipe that moves before it fires (a SwiftUI drag here held the scroll)
    .gesture(SpectrumScrubGesture { location in
      guard location.y >= SpectrumDeviceLayout.laneHeight else { return }
      selectedMark = nil
      cursorSlot = history.slot(ofColumn: column(at: location.x, history: history))
    })
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Tools.Tools.Spectrum.Device.Chart.label(window.spokenTitle))
    .accessibilityValue(accessibilityValue(history))
    .accessibilityAdjustableAction { direction in
      let step = max(1, history.ncols / 20)
      let current = cursor ?? history.ncols - 1
      switch direction {
      case .increment: cursorSlot = history.slot(ofColumn: min(history.ncols - 1, current + (cursor == nil ? 0 : step)))
      case .decrement: cursorSlot = history.slot(ofColumn: max(0, current - step))
      @unknown default: break
      }
    }
    .accessibilityChartDescriptor(SpectrumDeviceChartDescriptor(history: history, window: window))
    .accessibilityIdentifier("spectrum.device.plot")
  }

  private func motion(_ history: SpectrumDeviceHistory) -> SpectrumDeviceMotion {
    SpectrumRadioScreenSource.motion(viewModel: viewModel, window: window, history: history)
  }

  /// The column under `x` on the grid as it stands now (it slides by the clock).
  private func column(at x: CGFloat, history: SpectrumDeviceHistory) -> Int {
    motion(history)
      .columns(history: history, width: plotWidth, at: reduceMotion ? nil : viewModel.displayNow(.now))
      .column(at: x)
  }

  /// The radio's tap rules (`SpecChannelView::handleGesture`): the lane's band picks a packet, a tap
  /// elsewhere first closes a packet's card, then sets or clears the cursor.
  private func tap(at location: CGPoint, history: SpectrumDeviceHistory) {
    let column = column(at: location.x, history: history)
    if location.y < SpectrumDeviceLayout.laneHeight + Self.markHitBelow,
       let mark = history.nearestMark(toColumn: column) {
      cursorSlot = nil
      selectedMark = selectedMark == mark.mark.rxMs ? nil : mark.mark.rxMs
      return
    }
    if selectedMark != nil {
      selectedMark = nil
      return
    }
    guard location.y >= SpectrumDeviceLayout.laneHeight else { return }
    if let cursor, abs(column - cursor) <= Self.cursorClearColumns {
      cursorSlot = nil
    } else {
      cursorSlot = history.slot(ofColumn: column)
    }
  }

  /// "Floor -112 dBm, peak -84 dBm 32 seconds ago, busy 7%, 6 packets", or the cursor's readout.
  private func accessibilityValue(_ history: SpectrumDeviceHistory) -> String {
    if let cursor {
      return SpectrumReadout.line(history.readoutInput(column: cursor), level: 0)
    }
    guard let stats = history.stats else { return L10n.Tools.Tools.Spectrum.Device.Chart.noData }
    var parts: [String] = []
    if let floor = stats.floor {
      parts.append(L10n.Tools.Tools.Spectrum.Device.Chart.floor(SpectrumFormat.dBm(Double(floor))))
    }
    if let peak = history.peak, let column = history.peakColumn {
      let age = Duration.milliseconds(Int(history.age(ofColumn: column)))
        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
      parts.append(L10n.Tools.Tools.Spectrum.Device.Chart.peak(SpectrumFormat.dBm(Double(peak)), age))
    }
    if let busy = stats.busyPercent {
      parts.append(L10n.Tools.Tools.Spectrum.Device.Chart.busy(SpectrumDeviceCells.busy(busy)))
    }
    parts.append(L10n.Tools.Tools.RxLog.packetsCount(Int(stats.packets)))
    if stats.sweeping { parts.append(L10n.Tools.Tools.Spectrum.Device.sweepBanner) }
    return parts.joined(separator: ", ")
  }
}

/// The cursor's scrub: a long press (0.25 s) that then follows the finger.
private struct SpectrumScrubGesture: UIGestureRecognizerRepresentable {
  let onChange: (CGPoint) -> Void

  func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
    let recognizer = UILongPressGestureRecognizer()
    recognizer.minimumPressDuration = 0.25
    return recognizer
  }

  func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
    switch recognizer.state {
    case .began, .changed:
      onChange(context.converter.localLocation)
    default:
      break
    }
  }
}

// MARK: - Readings

/// The radio's five boxed readings in one row (a 3 + 2 grid at the accessibility text sizes), in
/// its colours: NOW in its level over the floor, FLOOR with its verdict dot, BUSY and AIR amber
/// past 30 % and red past 60 % with a warning glyph, PKT/MIN plain.
private struct SpectrumDeviceReadings: View {
  let viewModel: SpectrumViewModel
  let stats: CairnSpectrumStats?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showsFloorHistory = false
  @State private var showsAirSplit = false

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      Grid(horizontalSpacing: 6, verticalSpacing: 6) {
        GridRow {
          now
          floor
          busy
        }
        GridRow {
          packets
          air
          Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
      }
    } else {
      HStack(spacing: 6) {
        now
        floor
        busy
        packets
        air
      }
    }
  }

  private static let none = "--"

  private var now: some View {
    let rssi = stats?.nowRSSI
    let sweeping = stats?.sweeping == true
    let level = rssi.map { SpectrumLevel(rssi: Double($0), floor: stats?.floor.map(Double.init)) }
    let tint: Color = if rssi == nil || sweeping {
      .secondary
    } else {
      level?.color ?? .primary
    }
    let value = rssi.map { String(Int($0)) } ?? Self.none
    let spoken = rssi.map { rssi in
      [SpectrumFormat.dBm(Double(rssi)), sweeping ? L10n.Tools.Tools.Spectrum.Device.paused : level?.spokenName]
        .compactMap(\.self).joined(separator: ", ")
    } ?? L10n.Tools.Tools.Spectrum.measuring
    return SpectrumDeviceCell(caption: L10n.Tools.Tools.Spectrum.Meter.now, spoken: L10n.Tools.Tools.Spectrum.Meter.now, spokenValue: spoken) {
      Text(value).foregroundStyle(tint)
    }
    .accessibilityIdentifier("spectrum.device.now")
  }

  private var floor: some View {
    let floor = stats?.floor
    let thermal = stats?.thermal ?? 0
    let condition = floor.flatMap { thermal != 0 ? SpectrumDeviceCells.condition(floor: $0, thermal: thermal) : nil }
    let uncalibrated = floor == nil && stats?.nowRSSI != nil
    let spoken: String = if let floor {
      [SpectrumFormat.dBm(Double(floor)), condition?.title].compactMap(\.self).joined(separator: ", ")
    } else if uncalibrated {
      "≈ " + SpectrumFormat.dBm(SpectrumStats.uncalibratedFloor) + ", " + L10n.Tools.Tools.Spectrum.Meter.calibrating
    } else {
      L10n.Tools.Tools.Spectrum.measuring
    }
    return Button {
      showsFloorHistory = true
    } label: {
      SpectrumDeviceCell(caption: L10n.Tools.Tools.Spectrum.Meter.floor, spoken: L10n.Tools.Tools.Spectrum.Meter.floor, spokenValue: spoken) {
        HStack(spacing: 4) {
          if let floor {
            Text(String(Int(floor)))
              .foregroundStyle(.primary)
            if let condition {
              Circle()
                .fill(condition.color)
                .frame(width: 6, height: 6)
            }
          } else if uncalibrated {
            Text("~" + String(Int(SpectrumStats.uncalibratedFloor)))
              .foregroundStyle(.secondary)
          } else {
            Text(Self.none)
              .foregroundStyle(.secondary)
          }
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Tools.Tools.Spectrum.Hint.floorHistory)
    .accessibilityIdentifier("spectrum.device.floor")
    .popover(isPresented: $showsFloorHistory) {
      SpectrumFloorHistoryPopover(viewModel: viewModel)
        .presentationCompactAdaptation(.popover)
    }
  }

  private var busy: some View {
    let busy = stats?.busyPercent
    let load = busy.map { SpectrumDeviceCells.Load(percent: Double($0)) }
    let value = busy.map(SpectrumDeviceCells.busy)
    let verdict: String? = switch load {
    case .warning?: L10n.Tools.Tools.Spectrum.Device.Busy.warning
    case .critical?: L10n.Tools.Tools.Spectrum.Device.Busy.critical
    default: nil
    }
    return SpectrumDeviceCell(
      caption: L10n.Tools.Tools.Spectrum.Device.Cell.busy,
      spoken: L10n.Tools.Tools.Spectrum.Device.Spoken.busy,
      spokenValue: [value ?? L10n.Tools.Tools.Spectrum.measuring, verdict].compactMap(\.self).joined(separator: ", ")
    ) {
      SpectrumLoadValue(text: value, load: load)
    }
  }

  private var packets: some View {
    let value = stats?.packetsPerMinuteX10.map(SpectrumDeviceCells.packetsPerMinute(x10:))
    return SpectrumDeviceCell(
      caption: L10n.Tools.Tools.Spectrum.Device.Cell.packetsPerMinute,
      spoken: L10n.Tools.Tools.Spectrum.Device.Spoken.packetsPerMinute,
      spokenValue: value ?? L10n.Tools.Tools.Spectrum.measuring
    ) {
      Text(value ?? Self.none)
        .foregroundStyle(value == nil ? .secondary : .primary)
    }
  }

  private var air: some View {
    let air = stats?.airX10
    let load = air.map { SpectrumDeviceCells.Load(percent: Double($0) / 10) }
    let value = air.map(SpectrumDeviceCells.airtime(x10:))
    let split: String? = if let rx = stats?.rxAirX10, let tx = stats?.txAirX10 {
      L10n.Tools.Tools.Spectrum.Meter.airCaption(
        SpectrumDeviceCells.airtime(x10: rx), SpectrumDeviceCells.airtime(x10: tx)
      )
    } else {
      nil
    }
    let verdict: String? = switch load {
    case .warning?: L10n.Tools.Tools.Spectrum.Meter.heavyUse
    case .critical?: L10n.Tools.Tools.Spectrum.Meter.veryHeavyUse
    default: nil
    }
    return Button {
      showsAirSplit = true
    } label: {
      SpectrumDeviceCell(
        caption: L10n.Tools.Tools.Spectrum.Meter.air,
        spoken: L10n.Tools.Tools.Spectrum.Figure.airtime,
        spokenValue: [value ?? L10n.Tools.Tools.Spectrum.measuring, verdict, split].compactMap(\.self).joined(separator: ", ")
      ) {
        SpectrumLoadValue(text: value, load: load)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(split == nil)
    .accessibilityIdentifier("spectrum.device.air")
    .popover(isPresented: $showsAirSplit) {
      if let split {
        Text(split)
          .font(.subheadline.monospacedDigit())
          .padding()
          .presentationCompactAdaptation(.popover)
      }
    }
  }
}

/// One boxed reading, as the radio's cells: the caption over the value, both centred, in a 1 pt
/// BORDER outline. One element for VoiceOver.
private struct SpectrumDeviceCell<Value: View>: View {
  let caption: String
  let spoken: String
  let spokenValue: String
  @ViewBuilder let value: () -> Value

  var body: some View {
    VStack(spacing: 1) {
      Text(caption)
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      value()
        .font(.headline.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, minHeight: 48)
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SpectrumPalette.border, lineWidth: 1))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityValue(spokenValue)
  }
}

/// BUSY's and AIR's value: amber or red with a warning glyph past their limits, so the colour is
/// never the only sign.
private struct SpectrumLoadValue: View {
  let text: String?
  let load: SpectrumDeviceCells.Load?

  var body: some View {
    let tint: Color? = switch load {
    case .warning?: SpectrumPalette.warning
    case .critical?: SpectrumPalette.critical
    default: nil
    }
    HStack(spacing: 2) {
      if let tint {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(tint)
      }
      Text(text ?? "--")
        .foregroundStyle(tint ?? (text == nil ? .secondary : .primary))
    }
  }
}

extension SpectrumLevel {
  /// The class as VoiceOver says it after a reading.
  var spokenName: String {
    switch self {
    case .noise: L10n.Tools.Tools.Spectrum.Device.Level.noise
    case .signal: L10n.Tools.Tools.Spectrum.Device.Level.signal
    case .strong: L10n.Tools.Tools.Spectrum.Device.Level.strong
    case .veryStrong: L10n.Tools.Tools.Spectrum.Device.Level.veryStrong
    }
  }
}

// MARK: - Overlays

/// The cursor's readout at the trace's top left: a stripe in the column max's level colour, then
/// the longest of the radio's five readout lines that fits.
struct SpectrumReadoutChip: View {
  let history: SpectrumDeviceHistory
  let column: Int

  var body: some View {
    let lines = SpectrumReadout.lines(history.readoutInput(column: column))
    let stripe = history.level(ofColumn: column).map(SpectrumPalette.line) ?? SpectrumPalette.text3
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 1)
        .fill(stripe)
        .frame(width: 3)
      ViewThatFits(in: .horizontal) {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
          if index < lines.count - 1 {
            Text(line).fixedSize()
          } else {
            Text(line).truncationMode(.tail)
          }
        }
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.primary)
      .lineLimit(1)
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 2)
    .fixedSize(horizontal: false, vertical: true)
    .background(SpectrumPalette.card, in: .rect(cornerRadius: 3))
    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SpectrumPalette.border, lineWidth: 1))
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .accessibilityHidden(true)
  }
}

/// Over the trace while the radio sweeps the band: its readings are paused and NOW is stale.
private struct SpectrumSweepBanner: View {
  var body: some View {
    Label(L10n.Tools.Tools.Spectrum.Device.sweepBanner, systemImage: "pause.circle.fill")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(SpectrumPalette.card, in: .capsule)
      .overlay(Capsule().strokeBorder(SpectrumPalette.warning, lineWidth: 1))
      .dynamicTypeSize(...DynamicTypeSize.xxLarge)
  }
}

// MARK: - NF 24h

/// The radio's "NF 24h" row: the label, the day's floor line (at least 4 dB tall, centred, red where
/// the floor sat 10 dB or more over thermal, broken where there was none) and its range.
private struct SpectrumDeviceTrendRow: View {
  let trend: CairnSpectrumTrend?

  var body: some View {
    let scale = trend.flatMap { SpectrumTrendScale(points: $0.points) }
    HStack(spacing: 8) {
      Text(L10n.Tools.Tools.Spectrum.Device.nf24h)
        .lineLimit(1)
        .fixedSize()
      if let trend, let scale {
        SpectrumTrendLine(points: trend.points, thermal: Int(trend.thermal), scale: scale)
          .frame(maxWidth: .infinity)
          .frame(height: 10)
        Text(scale.label)
          .lineLimit(1)
          .fixedSize()
      } else {
        Text(L10n.Tools.Tools.Spectrum.Device.collecting)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.tertiary)
    .frame(minHeight: 16)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Tools.Tools.Spectrum.Device.nf24hSpoken)
    .accessibilityValue(
      scale.map { $0.low == $0.high ? SpectrumFormat.dBm(Double($0.low)) : L10n.Tools.Tools.Spectrum.History.range(String($0.low), String($0.high)) }
        ?? L10n.Tools.Tools.Spectrum.Device.collecting
    )
  }
}

private struct SpectrumTrendLine: View {
  let points: [Int8?]
  let thermal: Int
  let scale: SpectrumTrendScale

  var body: some View {
    let points = points
    let thermal = thermal
    let scale = scale
    Canvas { context, size in
      guard !points.isEmpty else { return }
      let step = size.width / CGFloat(points.count)
      func point(_ index: Int, _ value: Int8) -> CGPoint {
        CGPoint(x: (CGFloat(index) + 0.5) * step, y: scale.y(Int(value), height: size.height))
      }
      func heavy(_ value: Int8) -> Bool {
        thermal != 0 && ChannelCondition(desensitization: Double(Int(value) - thermal)) == .heavyInterference
      }
      var calm = Path()
      var loud = Path()
      for (index, value) in points.enumerated() {
        guard let value else { continue }
        let here = point(index, value)
        let previous = index > 0 ? points[index - 1] : nil
        let next = index + 1 < points.count ? points[index + 1] : nil
        if let previous {
          let start = point(index - 1, previous)
          if heavy(value) {
            loud.move(to: start)
            loud.addLine(to: here)
          } else {
            calm.move(to: start)
            calm.addLine(to: here)
          }
        } else if next == nil {
          // a lone point: a dot rather than nothing
          let dot = Path(ellipseIn: CGRect(x: here.x - 0.75, y: here.y - 0.75, width: 1.5, height: 1.5))
          if heavy(value) { loud.addPath(dot) } else { calm.addPath(dot) }
        }
      }
      let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
      context.stroke(calm, with: .color(SpectrumPalette.noise.opacity(150.0 / 255)), style: style)
      context.stroke(loud, with: .color(SpectrumPalette.critical.opacity(140.0 / 255)), style: style)
    }
  }
}

// MARK: - Packet card

/// The card for a lane mark the RX log has no entry for (heard while the app wasn't connected):
/// what the radio's mark carries, the type, route, age, level, SNR and length, but not who.
struct SpectrumDeviceMarkCallout: View {
  let mark: CairnSpectrumMark
  let date: Date?
  let onClose: () -> Void

  private var kind: SpectrumPacketKind { SpectrumPacketKind(mark.payloadType) }

  private var routeTitle: String {
    let hops = decodePathLen(mark.pathLength)?.hopCount ?? 0
    if mark.routeType == .flood || mark.routeType == .tcFlood {
      return L10n.Tools.Tools.Spectrum.Route.flood(hops)
    }
    return hops > 0 ? L10n.Tools.Tools.Spectrum.Route.directHops(hops) : L10n.Tools.Tools.RxLog.direct
  }

  /// "Flood 2 · 12 sec. ago"
  private var details: String {
    ([routeTitle] + [date.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) }].compactMap(\.self))
      .joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        SpectrumKindPill(kind: kind)
        Text("\(Text(kind.title).foregroundStyle(kind.color))\(Text(verbatim: " · " + details))")
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Localizable.Common.done)
      }
      .lineLimit(2)

      Text([
        SpectrumFormat.dBm(Double(mark.rssi)),
        L10n.Tools.Tools.Spectrum.Detail.snr(SpectrumPacketFormat.snr(mark.snr)),
        L10n.Tools.Tools.Spectrum.Detail.bytes(Int(mark.length)),
      ].joined(separator: " · "))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)

      Text(L10n.Tools.Tools.Spectrum.Device.heardAway)
        .font(.subheadline)
        .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Audio graph

/// The radio's view for VoiceOver's audio graph: each column's min, average and max by age.
private struct SpectrumDeviceChartDescriptor: AXChartDescriptorRepresentable {
  let history: SpectrumDeviceHistory
  let window: SpectrumWindow

  func makeChartDescriptor() -> AXChartDescriptor {
    let xAxis = AXNumericDataAxisDescriptor(
      title: L10n.Tools.Tools.Spectrum.Axis.secondsAgo,
      range: -window.duration...0,
      gridlinePositions: []
    ) { value in
      Duration.seconds(abs(value).rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
    let bottom = Double(history.scaleLo != 0 ? Int(history.scaleLo) : -118)
    let yAxis = AXNumericDataAxisDescriptor(
      title: L10n.Tools.Tools.Spectrum.Axis.dbm,
      range: bottom...(bottom + Double(SpectrumTraceGeometry.span)),
      gridlinePositions: []
    ) { value in
      SpectrumFormat.dBm(value)
    }
    var minimum: [AXDataPoint] = []
    var average: [AXDataPoint] = []
    var maximum: [AXDataPoint] = []
    for (index, column) in history.columns.enumerated() {
      guard let column, column.isData else { continue }
      let x = -Double(history.age(ofColumn: index)) / 1000
      minimum.append(AXDataPoint(x: x, y: Double(column.min)))
      average.append(AXDataPoint(x: x, y: Double(column.avg)))
      maximum.append(AXDataPoint(x: x, y: Double(column.max)))
    }
    return AXChartDescriptor(
      title: L10n.Tools.Tools.Spectrum.Device.Chart.label(window.spokenTitle),
      summary: nil,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: [
        AXDataSeriesDescriptor(name: L10n.Tools.Tools.Spectrum.Device.Series.min, isContinuous: true, dataPoints: minimum),
        AXDataSeriesDescriptor(name: L10n.Tools.Tools.Spectrum.Device.Series.avg, isContinuous: true, dataPoints: average),
        AXDataSeriesDescriptor(name: L10n.Tools.Tools.Spectrum.Device.Series.max, isContinuous: true, dataPoints: maximum),
      ]
    )
  }
}
