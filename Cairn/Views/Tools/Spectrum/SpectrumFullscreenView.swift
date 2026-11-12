import CairnServices
import SwiftUI

/// The Radio Screen's history for the page's style, from the radio's own view when it sends one
/// and from the app's readings otherwise: the same look on every radio.
@MainActor
enum SpectrumRadioScreenSource {
  static func history(
    viewModel: SpectrumViewModel, window: SpectrumWindow, columns: Int, now: Date, channel: LoRaChannelMath?
  ) -> SpectrumDeviceHistory {
    if viewModel.source == .device { return viewModel.deviceHistory }
    let since = now.addingTimeInterval(-max(window.duration, window.statsDuration))
    // The readings from a floor's hold before the window too: the last one before it stands
    // into its first columns, so the line runs off the left edge rather than ending at the
    // first reading inside and dropping a stretch at a time as each leaves.
    let noiseSince = since.addingTimeInterval(-MiniSpectrumFrame.floorHold)
    return SpectrumDeviceHistory.readings(SpectrumDeviceHistory.ReadingsInput(
      noise: viewModel.noise.elements.filter { $0.date >= noiseSince },
      packets: viewModel.packets.elements.filter { $0.date >= since && $0.date <= now },
      airtime: viewModel.airtime.elements,
      window: window,
      ncols: columns,
      now: now,
      channel: channel,
      nowRSSI: viewModel.nowRSSI,
      packetsObservedSince: viewModel.packetsObservedSince
    ))
  }

  /// The 24 h floor line: the radio's own trend, else the app's minute averages on the same grid.
  static func trend(viewModel: SpectrumViewModel, channel: LoRaChannelMath?, now: Date) -> CairnSpectrumTrend? {
    if viewModel.source == .device { return viewModel.deviceTrend }
    let thermal = channel.map { Int8(clamping: Int($0.thermalNoiseFloor.rounded())) } ?? 0
    return SpectrumDeviceHistory.trend(samples: viewModel.floorTrend, thermal: thermal, now: now)
  }

  /// When the readings behind the history were taken: the reply's arrival on a Cairn radio, now
  /// otherwise (the app stamps its own readings with `now`).
  static func statsDate(viewModel: SpectrumViewModel, now: Date) -> Date? {
    viewModel.source == .device ? viewModel.deviceStatsDate : now
  }

  /// How the history's grid slides by the clock: on the radio's slot clock for its own view, on
  /// the app's slot grid (`SpectrumDeviceHistory.readings`) otherwise.
  static func motion(viewModel: SpectrumViewModel, window: SpectrumWindow, history: SpectrumDeviceHistory) -> SpectrumDeviceMotion {
    let slotSeconds = window.duration / Double(max(history.ncols, 1))
    let start: Date? = viewModel.source == .device
      ? viewModel.deviceSlotClock.date(ofSlot: Int64(history.nowSlot), slotSeconds: slotSeconds) ?? viewModel.deviceStatsDate
      : Date(timeIntervalSinceReferenceDate: Double(history.nowSlot) * slotSeconds)
    return SpectrumDeviceMotion(
      newestSlotStart: start,
      slotSeconds: slotSeconds,
      lag: SpectrumDeviceMotion.lag(window: window.duration, slotSeconds: slotSeconds)
    )
  }
}

/// The Spectrum tab's channel over the whole screen, edge to edge: the chosen chart style with
/// nothing around it but a close button, the readings along the top and the time axis along the
/// bottom, both laid over the plot. The status bar and the home indicator go too. Rotating the
/// phone gives the plot the long side.
struct SpectrumFullscreenView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  let channel: LoRaChannelMath?

  /// The chart style, the page's setting: a swipe here changes it for the page too.
  @AppStorage(AppStorageKey.spectrumChartStyle.rawValue) private var chartStyleRaw = 0
  private var style: SpectrumChartStyle { .stored(chartStyleRaw) }
  /// The style's name for a moment after a swipe.
  @State private var styleNamedAt: Date?

  @State private var selectedMark: UInt32?
  /// The Radio Screen's cursor: the radio's slot tapped, so it rides with the columns.
  @State private var cursorSlot: Int64?
  /// The other styles' marker: the moment tapped on their plot, which it rides with.
  @State private var markerDate: Date?
  /// The readings row's and the axis strip's heights, so the plot sits between them rather than
  /// running under them with its top and bottom hidden.
  @State private var topChromeHeight: CGFloat = 0
  @State private var bottomChromeHeight: CGFloat = 0
  /// The Advert cell: sending, and how the last one went, shown in the cell for a moment.
  @State private var isSendingAdvert = false
  @State private var advertResult: (sent: Bool, at: Date)?
  @State private var advertSucceeded = false
  @State private var advertFailed = false
  private static let chromeGap: CGFloat = 6

  private var viewModel: SpectrumViewModel { appState.spectrumFeed.model }
  private var window: SpectrumWindow { appState.spectrumFeed.window }

  var body: some View {
    GeometryReader { geometry in
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let now = viewModel.displayNow(max(context.date, Date()))
        // The plot between the readings row and the axis strip, edge to edge sideways.
        let topInset = topChromeHeight + Self.chromeGap
        let bottomInset = bottomChromeHeight + Self.chromeGap
        // A point in from the screen's sides, so the plot's edges don't sit on the glass.
        let plotSize = CGSize(width: max(geometry.size.width - 2, 10), height: max(geometry.size.height - topInset - bottomInset, 120))
        ZStack(alignment: .topTrailing) {
          SpectrumPersistenceRamp.panel.ignoresSafeArea()
          plot(now: now, size: plotSize)
            .frame(width: plotSize.width, height: plotSize.height)
            .padding(.horizontal, 1)
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          // The readings, the close button and the axis stay up: a tap on the plot is the
          // cursor's, on every style.
          chrome(now: now)
          if let styleNamedAt, now.timeIntervalSince(styleNamedAt) < 1.5 {
            Text(style.title)
              .font(.headline.monospaced())
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(.black.opacity(0.6), in: Capsule())
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
              .allowsHitTesting(false)
              .transition(.opacity)
          }
        }
      }
    }
    // A swipe sideways moves to the next or previous style, as the Chart Style setting lists them;
    // a swipe down closes the screen, as the header's tap does.
    .gesture(DragGesture(minimumDistance: 40).onEnded { value in
      if value.translation.height > 120, value.translation.height > abs(value.translation.width) * 1.5 {
        dismiss()
        return
      }
      guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
      stepStyle(value.translation.width < 0 ? 1 : -1)
    })
    // Escape (a keyboard on an iPad or a Mac) closes it too.
    .background {
      Button("") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .hidden()
    }
    .background(SpectrumPersistenceRamp.panel)
    .cairnFeedback(.success, trigger: advertSucceeded)
    .cairnFeedback(.error, trigger: advertFailed)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .environment(\.colorScheme, .dark)
    .accessibilityIdentifier("spectrum.fullscreen")
  }

  @ViewBuilder
  private func plot(now: Date, size: CGSize) -> some View {
    switch style {
    case .radioScreen:
      let columns = SpectrumFeed.deviceColumns(horizontalSizeClass)
      let history = SpectrumRadioScreenSource.history(
        viewModel: viewModel, window: window, columns: columns, now: now, channel: channel
      )
      // The trace and the density share the screen's height as they share the card's, 5 to 4.
      let plotHeight = max(size.height - SpectrumDeviceLayout.laneHeight - SpectrumDeviceLayout.gap, 100)
      let layout = SpectrumDeviceLayout(traceHeight: (plotHeight * 5 / 9).rounded(), densityHeight: (plotHeight * 4 / 9).rounded())
      let motion = SpectrumRadioScreenSource.motion(viewModel: viewModel, window: window, history: history)
      let cursor = history.column(ofSlot: cursorSlot)
      SpectrumDeviceCanvas(
        history: history,
        layout: layout,
        cursor: cursor,
        selectedMark: selectedMark,
        showsKeys: cursor == nil,
        motion: motion,
        heldAt: viewModel.pausedAt
      )
      .frame(width: size.width, height: size.height)
      .contentShape(.rect)
      // A tap on the plot puts the cursor on that column (as on the card); one near it clears it.
      .gesture(SpatialTapGesture().onEnded { value in
        guard value.location.y >= SpectrumDeviceLayout.laneHeight else { return }
        let column = motion.columns(history: history, width: size.width, at: reduceMotion ? nil : viewModel.displayNow(.now))
          .column(at: value.location.x)
        if let cursor, abs(column - cursor) <= 3 {
          cursorSlot = nil
        } else {
          cursorSlot = history.slot(ofColumn: column)
        }
      })
      .overlay(alignment: .topLeading) {
        if let cursor {
          SpectrumReadoutChip(history: history, column: cursor)
            .padding(.top, SpectrumDeviceLayout.laneHeight + SpectrumDeviceLayout.traceInset + 2)
            .padding(.leading, 4)
            .allowsHitTesting(false)
        }
      }
    case .lineChart:
      if let channel {
        SpectrumChannelChart(
          channel: channel,
          viewModel: viewModel,
          packets: viewModel.packets.elements,
          window: window,
          now: now,
          selectedPacketID: .constant(nil)
        )
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height)
      } else {
        styledPlot(.modern, now: now, size: size)
      }
    case .modern, .analyzer, .waterfall:
      styledPlot(style, now: now, size: size)
    }
  }

  private func styledPlot(_ style: SpectrumChartStyle, now: Date, size: CGSize) -> some View {
    let frame = appState.spectrumFeed.frame(barCount: style.barCount(horizontalSizeClass), now: now)
    return StyledSpectrumPlot(
      style: style,
      frame: frame,
      channelHz: channel?.frequencyHz,
      bandwidthHz: channel?.bandwidthHz,
      laneHeight: 24,
      heldAt: viewModel.pausedAt,
      onCursorChange: { markerDate = $0.map { frame.newestDate.addingTimeInterval(-$0) } }
    )
    .frame(width: size.width, height: size.height)
  }

  // MARK: - The panel

  /// The instrument's front: along the top the radio and its channel (frequency, bandwidth,
  /// spreading factor and coding rate, transmit power) with the window chips, Pause and the close
  /// button; under it the boxed readouts (NOW, FLOOR, PEAK, AIR, PKT/MIN, PKTS); along the bottom
  /// the time axis and the latest packet. All of it in the instrument's mono lettering on dark
  /// chips over the plot.
  private func chrome(now: Date) -> some View {
    // The readouts as equal cells on two strips, the first half under the channel line, the
    // second along the bottom under the plot; both strips the same number of columns, so every
    // cell is the same size. The Advert button is a cell too, always the bottom strip's last: the
    // bottom right, the slot an odd count used to leave empty.
    let cells = readouts(now: now)
    let half = max((cells.count + 2) / 2, 1)
    return VStack(spacing: 6) {
      VStack(spacing: 6) {
        titleRow(now: now)
        readoutStrip(cells.prefix(half), columns: half)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topChromeHeight = $0 + 12 }
      Spacer()
      VStack(spacing: 6) {
        bottomRow(now: now)
        readoutStrip(cells.dropFirst(half), columns: half, trailing: advertCell(now: now))
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomChromeHeight = $0 + 12 }
    }
    .padding(12)
    .foregroundStyle(.white)
    .transition(.opacity)
  }

  private var device: DeviceDTO? { appState.connectedDevice }

  /// The style `step` places along the list (wrapping), named on screen for a moment.
  private func stepStyle(_ step: Int) {
    let all = SpectrumChartStyle.allCases
    guard let index = all.firstIndex(of: style) else { return }
    let next = all[(index + step + all.count) % all.count]
    withAnimation(.easeOut(duration: 0.2)) {
      chartStyleRaw = next.rawValue
      cursorSlot = nil
      markerDate = nil
      styleNamedAt = .now
    }
  }

  /// "Heltec V3 · 910.525 MHz · 250k · SF11 CR5 · 22 dBm" over the instrument's settings line,
  /// across the whole width. A tap on it closes the screen (no close button, so the header has the
  /// width; the user, 2026-11-07), as a swipe down does. The window and Pause are the page's: the
  /// panel shows the channel as the page has it set.
  private func titleRow(now: Date) -> some View {
    Button {
      dismiss()
    } label: {
      channelLine(now: now)
        .contentShape(.rect(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Localizable.Common.done)
    .accessibilityHint(L10n.Tools.Tools.Spectrum.Fullscreen.closeHint)
    .accessibilityIdentifier("spectrum.fullscreen.close")
  }

  private func channelLine(now: Date) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(device?.nodeName ?? L10n.Localizable.Home.noRadio)
          .font(.subheadline.weight(.bold))
          .lineLimit(1)
        if let channel {
          Text(Self.channelText(channel, txPower: txPower))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
        }
      }
      statusLine(now: now)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.black.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
  }

  /// The instrument's settings, as an analyzer's status line: the window (SPAN), a column's span
  /// (RES), how often the readings come (RATE), whose view it is (SRC: the radio's own, or the
  /// app's readings), RUN or HOLD, and the clock.
  private func statusLine(now: Date) -> some View {
    let columns = style == .radioScreen ? SpectrumFeed.deviceColumns(horizontalSizeClass) : style.barCount(horizontalSizeClass)
    let resolution = window.duration / Double(max(columns, 1))
    let rate: TimeInterval
    if viewModel.source == .device {
      let cadence = window.deviceCadence.components
      rate = Double(cadence.seconds) + Double(cadence.attoseconds) / 1e18
    } else {
      rate = viewModel.readingInterval
    }
    let dim = Color.white.opacity(0.5)
    let running = viewModel.isPaused
      ? Text("HOLD").foregroundStyle(Color.orange)
      : Text("RUN").foregroundStyle(SpectrumPalette.good)
    return HStack(spacing: 0) {
      Text("SPAN ").foregroundStyle(dim) + Text(window.shortTitle)
      Text("  RES ").foregroundStyle(dim) + Text(Self.seconds(resolution))
      Text("  RATE ").foregroundStyle(dim) + Text(Self.seconds(rate))
      Text("  SRC ").foregroundStyle(dim) + Text(viewModel.source == .device ? "RADIO" : "APP")
      Text("  ").foregroundStyle(dim) + running
      Text("  ").foregroundStyle(dim) + Text(now.formatted(date: .omitted, time: .standard))
    }
    .font(.system(size: 10, weight: .semibold, design: .monospaced))
    .foregroundStyle(.white.opacity(0.9))
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }

  /// "333 ms", "1 s", "2.5 s".
  private static func seconds(_ value: TimeInterval) -> String {
    value < 1
      ? "\(Int((value * 1000).rounded())) ms"
      : value.formatted(.number.precision(.fractionLength(0...1))) + " s"
  }

  /// "910.525 MHz · 250k · SF11 CR5 · 22 dBm"
  private static func channelText(_ channel: LoRaChannelMath, txPower: Int?) -> String {
    var parts = [
      SpectrumFormat.megahertz(channel.frequencyHz),
      SpectrumFormat.kilohertz(channel.bandwidthHz),
      "SF\(channel.spreadingFactor) CR\(channel.codingRate)",
    ]
    if let txPower { parts.append("\(txPower) dBm") }
    return parts.joined(separator: " · ")
  }

  private var txPower: Int? {
    guard let device else { return nil }
    return RadioAmplifier.effectiveTxPower(reported: Int(device.txPower), model: device.manufacturerName)
  }

  /// What the marker stands on: the loudest reading there, the floor it stood against and how
  /// long ago; nil with no marker set or none where it is.
  private struct MarkerReadout {
    var dBm: Double?
    var floor: Double
    var age: TimeInterval
    var isTX = false
  }

  private func markerReadout(now: Date) -> MarkerReadout? {
    if style == .radioScreen {
      guard cursorSlot != nil else { return nil }
      let history = SpectrumRadioScreenSource.history(
        viewModel: viewModel, window: window, columns: SpectrumFeed.deviceColumns(horizontalSizeClass), now: now, channel: channel
      )
      guard let cursor = history.column(ofSlot: cursorSlot) else { return nil }
      let column = history.columns[cursor]
      return MarkerReadout(
        dBm: column?.isData == true ? column.map { Double($0.max) } : nil,
        floor: Double(history.floorReference),
        age: Double(history.age(ofColumn: cursor)) / 1000,
        isTX: column?.isTX == true
      )
    }
    guard let markerDate else { return nil }
    let frame = appState.spectrumFeed.frame(barCount: style.barCount(horizontalSizeClass), now: now)
    let marker = frame.newestDate.timeIntervalSince(markerDate)
    guard let index = frame.barIndex(secondsBeforeNewest: marker) else { return nil }
    let bar = frame.bars[index]
    return MarkerReadout(dBm: bar.dBm, floor: bar.floor ?? frame.floor, age: marker, isTX: bar.isTX)
  }

  /// "-12.3 s", or the readout's longer ages.
  private static func ago(_ age: TimeInterval) -> String {
    age < 100 ? "-" + age.formatted(.number.precision(.fractionLength(1))) + " s" : SpectrumReadout.age(milliseconds: UInt32(clamping: Int(age * 1000)))
  }

  /// The boxed readouts: NOW in its level colour, FLOOR, PEAK over the window and how far it
  /// stands over the floor, AIR (receive and transmit share) and its split, PKT/MIN, the packets
  /// heard in the window, the latest packet's SNR, the radio's BUSY share, and the marker: its
  /// level, its height over the floor and its age.
  private struct Readout: Identifiable {
    let id: Int
    let caption: String
    let value: String
    let tint: Color?
  }

  /// One strip of readout cells on a grid of `columns` equal columns. `trailing` takes the strip's
  /// last column, with empty slots before it when the readouts run short.
  private func readoutStrip(_ cells: ArraySlice<Readout>, columns: Int) -> some View {
    readoutStrip(cells, columns: columns, trailing: Optional<EmptyView>.none)
  }

  private func readoutStrip<Trailing: View>(_ cells: ArraySlice<Readout>, columns: Int, trailing: Trailing?) -> some View {
    let gaps = trailing == nil ? 0 : max(columns - 1 - cells.count, 0)
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
      ForEach(cells) { readout in
        cell(readout.caption, readout.value, tint: readout.tint)
      }
      ForEach(0..<gaps, id: \.self) { _ in
        Color.clear.frame(height: 1)
      }
      if let trailing { trailing }
    }
  }

  /// ADVERT, boxed as the readouts are: a tap asks zero hop or flood, as Radio Settings' Advert
  /// does. The figure says SEND, then SENT or FAIL for a moment after one goes.
  private func advertCell(now: Date) -> some View {
    let recent = advertResult.flatMap { now.timeIntervalSince($0.at) < 3 ? $0.sent : nil }
    let value = isSendingAdvert ? "···" : recent.map { $0 ? "SENT" : "FAIL" } ?? "SEND"
    let tint: Color = recent.map { $0 ? SpectrumPalette.good : .red } ?? .cyan
    return Menu {
      Button {
        sendAdvert(flood: false)
      } label: {
        Label(L10n.Settings.BleStatus.sendZeroHopAdvert, systemImage: "dot.radiowaves.right")
      }
      .accessibilityHint(L10n.Settings.BleStatus.SendZeroHopAdvert.hint)
      Button {
        sendAdvert(flood: true)
      } label: {
        Label(L10n.Settings.BleStatus.sendFloodAdvert, systemImage: "dot.radiowaves.left.and.right")
      }
      .accessibilityHint(L10n.Settings.BleStatus.SendFloodAdvert.hint)
    } label: {
      cell("ADVERT", value, tint: tint)
        .contentShape(.rect(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isSendingAdvert || appState.connectionState != .ready)
    .opacity(appState.connectionState == .ready ? 1 : 0.5)
    .accessibilityLabel(L10n.Localizable.CarPlay.Action.advert)
    .accessibilityIdentifier("spectrum.fullscreen.advert")
  }

  /// The same advert Radio Settings and Home send, with the same haptics.
  private func sendAdvert(flood: Bool) {
    guard !isSendingAdvert else { return }
    isSendingAdvert = true
    Task {
      do {
        try await appState.sendSelfAdvert(flood: flood)
        advertResult = (true, .now)
        advertSucceeded.toggle()
      } catch {
        advertResult = (false, .now)
        advertFailed.toggle()
      }
      isSendingAdvert = false
    }
  }

  private func readouts(now: Date) -> [Readout] {
    var cells: [Readout] = []
    func cell(_ caption: String, _ value: String, tint: Color?) {
      cells.append(Readout(id: cells.count, caption: caption, value: value, tint: tint))
    }
    let packets = viewModel.packets.elements
    let span = window.statsDuration
    let start = now.addingTimeInterval(-span)
    let counted = packets.count - packets.firstIndex(atOrAfter: start, date: \.date)
    let rate = SpectrumStats.packetsPerMinute(count: counted, window: span, observedSince: viewModel.packetsObservedSince, now: now)
    let air = SpectrumStats.airtimeShare(viewModel.airtime.elements, window: span, now: now)
    let floor = viewModel.currentNoiseFloor
    let peak = SpectrumStats.peak(packets, since: now.addingTimeInterval(-window.duration))
    let nowRSSI = viewModel.nowRSSI
    let nowLevel = nowRSSI.map { SpectrumLevel(rssi: $0, floor: floor) }
    let peakLevel = peak.map { SpectrumLevel(rssi: $0, floor: floor) }
    cell(L10n.Tools.Tools.Spectrum.Meter.now, dBm(nowRSSI), tint: nowLevel?.color)
        cell(L10n.Tools.Tools.Spectrum.Meter.floor, dBm(floor), tint: nil)
        cell(L10n.Tools.Tools.Spectrum.Meter.peak, dBm(peak), tint: peakLevel?.color)
        cell("PK-NF", peak.flatMap { pk in floor.map { "+" + String(Int((pk - $0).rounded())) + " dB" } } ?? "--", tint: nil)
        cell("AIR", air.map { (($0.rx + $0.tx) * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "--", tint: nil)
        cell("RX/TX", air.map { Self.percent($0.rx) + "/" + Self.percent($0.tx) + "%" } ?? "--", tint: nil)
        cell("PKT/MIN", rate.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--", tint: nil)
        cell("PKTS", counted.formatted(), tint: nil)
        cell("SNR", viewModel.latestPacket?.snr.map { SpectrumPacketFormat.snr($0) + " dB" } ?? "--", tint: nil)
        if viewModel.source == .device, let busy = viewModel.deviceHistory.stats?.busyPercent {
          cell("BUSY", "\(busy)%", tint: nil)
        }
        if let marker = markerReadout(now: now) {
          let level = marker.dBm.map { SpectrumLevel(dBAboveFloor: $0 - marker.floor) }
          cell("MKR", marker.dBm.map { dBm($0) } ?? (marker.isTX ? "TX" : "--"), tint: level.map(SpectrumPalette.line) ?? .white)
          cell("MKR-NF", marker.dBm.map { "+" + String(Int(($0 - marker.floor).rounded())) + " dB" } ?? "--", tint: nil)
          cell("MKR T", Self.ago(marker.age), tint: nil)
        }
        if viewModel.isPaused {
          cell(L10n.Tools.Tools.Spectrum.pause.uppercased(), "||", tint: .orange)
        }
    return cells
  }

  private static func percent(_ share: Double) -> String {
    (share * 100).formatted(.number.precision(.fractionLength(1)))
  }

  private func dBm(_ value: Double?) -> String {
    value.map { String(Int($0.rounded())) } ?? "--"
  }

  /// One boxed readout: the caption small over the figure, mono, in `tint` when it carries a level.
  private func cell(_ caption: String, _ value: String, tint: Color?) -> some View {
    VStack(spacing: 1) {
      Text(caption)
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
      Text(value)
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .foregroundStyle(tint ?? .white)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .background(.black.opacity(0.5), in: .rect(cornerRadius: 6, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    .accessibilityElement(children: .combine)
  }

  /// The time axis and the latest packet: its kind, who it came from or its route, its signal and
  /// how long ago.
  private func bottomRow(now: Date) -> some View {
    VStack(spacing: 4) {
      if let packet = viewModel.latestPacket {
        HStack(spacing: 8) {
          SpectrumKindPill(kind: packet.kind, showsName: true)
          Text(packet.routeTitle)
            .font(.caption.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 4)
          Text(
            [
              packet.rssi.map { SpectrumFormat.dBm($0) },
              packet.snr.map { L10n.Tools.Tools.Spectrum.Detail.snr(SpectrumPacketFormat.snr($0)) },
              SpectrumPacketFormat.age(now.timeIntervalSince(packet.date)),
            ].compactMap(\.self).joined(separator: " · ")
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.75))
          .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
      }
      if style.showsTimeAxis {
        MiniSpectrumTimeAxis(window: window)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(.black.opacity(0.45), in: .rect(cornerRadius: 6, style: .continuous))
      }
    }
  }
}
