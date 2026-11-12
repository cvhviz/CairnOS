import Charts
import CairnServices
import MeshCore
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "SpectrumView")

/// The Spectrum tab, after Cairn's Radio and Spectrum pages on the L2 Pro, in the Dashboard's card
/// style and packed so the chart sits on the first screen: a slim header band with the channel's
/// condition, preset and cost per packet (the way into Radio settings) and the Advert and RX Log
/// buttons, one strip of four readings (Cairn's NOW / MARGIN, FLOOR with its history, AIR and
/// PKT/MIN), the Channel view (packet lane over the noise floor's band, in a 10 s to 1 h window)
/// and the traffic table. Cairn's Band view isn't here: sweeping the band pauses the mesh on the
/// radio itself, and the companion protocol has no command for it.
///
/// A Cairn radio that sends its own Channel view gets that view instead, drawn as the radio draws
/// it (``SpectrumDeviceCard``); stock MeshCore radios keep the app's own.
struct SpectrumView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  private var viewModel: SpectrumViewModel { appState.spectrumFeed.model }
  /// The traffic column's width beside the chart (iPad, Mac): just enough for its five columns,
  /// growing a little with the text size.
  @ScaledMetric(relativeTo: .subheadline) private var trafficColumnWidth: CGFloat = 330
  @AppStorage(AppStorageKey.spectrumDefaultWindow.rawValue)
  private var defaultWindowRaw = AppStorageKey.defaultSpectrumWindow
  @AppStorage(AppStorageKey.spectrumUpdateRate.rawValue)
  private var rateRaw = AppStorageKey.defaultSpectrumUpdateRate
  /// How many of the newest packets the traffic table lists; See All and the RX Log have the rest.
  @AppStorage(AppStorageKey.spectrumTrafficRows.rawValue)
  private var trafficRows = AppStorageKey.defaultSpectrumTrafficRows
  /// The mini spectrum's design by default, the radio's own, or the Analyzer.
  @AppStorage(AppStorageKey.spectrumChartStyle.rawValue)
  private var chartStyleRaw = 0
  @State private var selectedPacketID: UUID?
  /// The page's height, for the chart's on a wide screen.
  @State private var windowHeight: CGFloat = 0
  @State private var detailPacket: SpectrumPacket?
  /// The lane mark picked on a Cairn radio's own view (its `rxMs`).
  @State private var selectedMark: UInt32?
  /// The radio's view as it stood when Pause was tapped: what the plot shows until Resume, while
  /// the readings keep landing behind it.
  @State private var heldFrame: MiniSpectrumFrame?
  /// The channel over the whole screen (`SpectrumFullscreenView`).
  @State private var showsFullscreen = false
  /// The main column's content height (its header band, readings and chart), which the traffic
  /// column beside it matches on an iPad.
  @State private var mainContentHeight: CGFloat = 0

  private var chartStyle: SpectrumChartStyle { .stored(chartStyleRaw) }

  /// Spectrum Settings' default, or the window picked on the page: the Dashboard follows it too.
  private var window: SpectrumWindow { appState.spectrumFeed.window }

  private var readingInterval: TimeInterval {
    (SpectrumUpdateRate(rawValue: rateRaw) ?? .normal).interval
  }

  private var channel: LoRaChannelMath? {
    guard let device = appState.connectedDevice else { return nil }
    return LoRaChannelMath(
      frequencyHz: Double(device.frequency) * 1000,
      bandwidthHz: Double(device.bandwidth),
      spreadingFactor: Int(device.spreadingFactor),
      codingRate: Int(device.codingRate)
    )
  }

  private var txPower: Int? {
    guard let device = appState.connectedDevice else { return nil }
    return RadioAmplifier.effectiveTxPower(reported: Int(device.txPower), model: device.manufacturerName)
  }

  var body: some View {
    Group {
      if let channel, let device = appState.connectedDevice, appState.services?.session != nil {
        content(channel: channel, device: device)
      } else {
        RadioNotConnectedView(description: L10n.Tools.Tools.Spectrum.notConnected)
      }
    }
    .modifier(SpectrumFeedViewer())
    .toolbar {
      // Holds the chart's window and ages where they are; the readings keep landing behind it.
      ToolbarItem(placement: .topBarTrailing) {
        Button(
          viewModel.isPaused ? L10n.Tools.Tools.Spectrum.resume : L10n.Tools.Tools.Spectrum.pause,
          systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
        ) {
          viewModel.setPaused(!viewModel.isPaused)
        }
        .disabled(appState.services?.session == nil)
        .accessibilityIdentifier("spectrum.pause")
      }
      // The channel edge to edge, top to bottom.
      ToolbarItem(placement: .topBarTrailing) {
        Button(L10n.Tools.Tools.Spectrum.fullscreen, systemImage: "arrow.up.left.and.arrow.down.right") {
          showsFullscreen = true
        }
        .disabled(appState.services?.session == nil)
        .accessibilityIdentifier("spectrum.fullscreen.open")
      }
    }
    .fullScreenCover(isPresented: $showsFullscreen) {
      SpectrumFullscreenView(channel: channel)
        .environment(\.appState, appState)
    }
    .onAppear { viewModel.readingInterval = readingInterval }
    // The poll loop re-reads the interval on each pass: a new rate shortens or lengthens the
    // next wait without restarting the readings or the packet stream.
    .onChange(of: rateRaw) { viewModel.readingInterval = readingInterval }
    // The radio's own view follows the page's window; a change starts it over.
    .onChange(of: window) { viewModel.deviceWindow = window }
    // A new default replaces the page's own pick, so the change is visible straight away.
    .onChange(of: defaultWindowRaw) {
      appState.spectrumFeed.pickedWindow = nil
      selectedPacketID = nil
    }
    .sheet(item: $detailPacket) { packet in
      SpectrumPacketDetailSheet(packet: packet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  /// The traffic sits in a narrow column right of the chart, scrolling on its own (iPad and Mac at
  /// regular width), rather than under it (iPhone, and compact width). Read first by VoiceOver
  /// after the chart, as it sits.
  private var showsTrafficBeside: Bool {
    TabSplitLayout.usesSplit(
      horizontalSizeClass: horizontalSizeClass,
      verticalSizeClass: verticalSizeClass,
      idiom: UIDevice.current.userInterfaceIdiom
    )
  }

  private func content(channel: LoRaChannelMath, device: DeviceDTO) -> some View {
    Group {
      if showsTrafficBeside {
        HStack(alignment: .top, spacing: 0) {
          mainColumn(channel: channel, device: device)
          // The traffic as one card the height of the main column's three sections, its title
          // inside and its rows scrolling within it.
          trafficColumn
            .frame(width: min(trafficColumnWidth, 420))
        }
      } else {
        mainColumn(channel: channel, device: device)
      }
    }
    .cardCanvas(theme)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
    .onChange(of: window) {
      selectedPacketID = nil
      selectedMark = nil
      viewModel.resetTraceScale()
    }
    // A new channel is a new floor: the chart's held scale starts over from it, as a new window's.
    .onChange(of: [channel.frequencyHz, channel.bandwidthHz, Double(channel.spreadingFactor)]) {
      viewModel.resetTraceScale()
    }
  }

  /// The header band and the chart's sections, scrolling together; the traffic table under them
  /// unless it sits beside them.
  /// The chart's height: the phone's on iPhone and compact width; on iPad and Mac, most of the
  /// window's height, so the chart uses the room beside the traffic column.
  private func chartHeight(_ phone: CGFloat) -> CGFloat {
    guard showsTrafficBeside else { return phone }
    return max(phone, windowHeight * 0.45)
  }

  private var trafficColumn: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let packets = viewModel.packets.elements
      let height = min(mainContentHeight, max(windowHeight - CardStyle.pageInset * 2, 200))
      SpectrumTrafficSection(
        packets: Array(packets.suffix(Self.trafficColumnRows).reversed()),
        now: viewModel.displayNow(max(context.date, Date())),
        fillsHeight: true
      ) { detailPacket = $0 }
        .frame(height: mainContentHeight > 0 ? height : nil)
        .padding(.top, CardStyle.pageInset)
        .padding(.trailing, CardStyle.pageInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  /// The packets the iPad's traffic column holds, newest first; See All has the rest.
  private static let trafficColumnRows = 120

  private func mainColumn(channel: LoRaChannelMath, device: DeviceDTO) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: CardStyle.spacing) {
        // Changes with the radio's settings and readings alone, so it sits outside the clock.
        SpectrumHeaderBand(device: device, channel: channel, txPower: txPower, viewModel: viewModel)

        switch viewModel.source {
        case .device:
          deviceSections
        case .probing:
          probingSections
        case .legacy:
          legacySections(channel: channel)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mainContentHeight = $0 }
      .padding(CardStyle.pageInset)
    }
  }

  // MARK: - The radio's own view

  /// A Cairn radio's own Channel view, redrawn only when a reading lands, then the selected packet's
  /// card and the traffic table, which keeps its own clock for the ages.
  @ViewBuilder private var deviceSections: some View {
    if chartStyle == .radioScreen {
      SpectrumDeviceCard(
        viewModel: viewModel,
        window: window,
        onSelectWindow: { appState.spectrumFeed.pickedWindow = $0 },
        selectedMark: $selectedMark
      )
    } else {
      deviceModernCard
    }

    if let mark = selectedDeviceMark {
      let date = viewModel.deviceStatsDate.flatMap { received in
        viewModel.deviceHistory.stats.map {
          SpectrumDeviceMarkMatch.date(of: mark, radioNowMs: $0.nowMs, receivedAt: received)
        }
      }
      Group {
        if let date, let packet = matchingPacket(for: mark, at: date) {
          SpectrumPacketCallout(
            packet: packet,
            onDetails: { detailPacket = packet },
            onClose: { selectedMark = nil }
          )
        } else {
          SpectrumDeviceMarkCallout(mark: mark, date: date) { selectedMark = nil }
        }
      }
      .cardSurface(padding: 12)
      .transition(.opacity)
    }

    if !showsTrafficBeside {
      trafficSection
    }
  }

  /// The radio's own view in the chosen plot style (or the Line Chart from the app's readings):
  /// the readings, the plot and the key.
  private var deviceModernCard: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      // Paused, the plot holds the view it had when Pause was tapped (`heldFrame`).
      let frame = heldFrame ?? appState.spectrumFeed.frame(barCount: chartStyle.barCount(horizontalSizeClass), now: context.date)
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          channelTitle(info: L10n.Tools.Tools.Spectrum.Device.settingsFootnote)
          Spacer(minLength: 12)
          windowPicker
            .fixedSize()
        }
        MiniSpectrumReadings(now: viewModel.nowRSSI, floor: viewModel.currentNoiseFloor, peak: frame.peak)
        if chartStyle == .lineChart, let channel {
          // The same chart the radios without their own view get, from the floor readings the
          // radio's stats carry and the RX log's packets.
          SpectrumChannelChart(
            channel: channel,
            viewModel: viewModel,
            packets: viewModel.packets.elements,
            window: window,
            now: viewModel.displayNow(max(context.date, Date())),
            selectedPacketID: $selectedPacketID
          )
          .frame(height: chartHeight(220))
          .lineChartPanel()
        } else {
          modernPlot(frame)
        }
        SpectrumChartLegend(showsSeries: chartStyle == .lineChart)
      }
      .cardSurface(padding: 12)
    }
    .onChange(of: viewModel.pausedAt, initial: true) { _, pausedAt in
      heldFrame = pausedAt.map { appState.spectrumFeed.frame(barCount: chartStyle.barCount(horizontalSizeClass), now: $0) }
    }
  }

  /// The large spectrum in the chosen style (Modern, Analyzer or Waterfall) and its time axis.
  /// Tapping a packet on its lane picks it.
  private func modernPlot(_ frame: MiniSpectrumFrame) -> some View {
    VStack(spacing: 4) {
      StyledSpectrumPlot(
        style: chartStyle,
        frame: frame,
        channelHz: channel?.frequencyHz,
        bandwidthHz: channel?.bandwidthHz,
        selectedPacketID: selectedPacketID,
        selectedRxMs: selectedMark,
        onSelectMark: { mark in
          selectedPacketID = mark?.packetID
          selectedMark = mark?.rxMs
        },
        heldAt: viewModel.pausedAt
      )
      .frame(height: chartHeight(260))
      if chartStyle.showsTimeAxis {
        MiniSpectrumTimeAxis(window: window)
      }
    }
  }

  /// The selected lane mark, while it is still on the radio's view.
  private var selectedDeviceMark: CairnSpectrumMark? {
    guard let selectedMark else { return nil }
    return viewModel.deviceHistory.marks.last { $0.mark.rxMs == selectedMark }?.mark
  }

  /// The RX log's entry for a lane mark: the same type, within 2 s and 1 dB; the closest in time.
  private func matchingPacket(for mark: CairnSpectrumMark, at date: Date) -> SpectrumPacket? {
    let packets = viewModel.packets.elements
    let gap = SpectrumDeviceMarkMatch.maximumTimeGap
    let start = packets.firstIndex(atOrAfter: date.addingTimeInterval(-gap), date: \.date)
    return packets[start...]
      .prefix { $0.date <= date.addingTimeInterval(gap) }
      .filter {
        SpectrumDeviceMarkMatch.matches(mark: mark, markDate: date, packetKind: $0.kind, packetDate: $0.date, packetRSSI: $0.rssi)
      }
      .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
  }

  /// While the page asks the radio whether it sends its own view: a quiet placeholder, so neither
  /// layout flashes up only to be replaced.
  @ViewBuilder private var probingSections: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(L10n.Tools.Tools.Spectrum.measuring)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 120)
    .cardSurface(padding: 12)

    if !showsTrafficBeside {
      trafficSection
    }
  }

  /// The traffic table on its own clock, for the ages.
  private var trafficSection: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let packets = viewModel.packets.elements
      SpectrumTrafficSection(
        packets: Array(packets.suffix(max(1, trafficRows)).reversed()),
        now: viewModel.displayNow(max(context.date, Date()))
      ) { detailPacket = $0 }
    }
    .padding(.top, 8)
  }

  // MARK: - The app's own view

  /// Stock MeshCore radios, the SF32 port and older Cairn builds: the app's own Channel view from
  /// the radio's statistics and the RX log.
  @ViewBuilder private func legacySections(channel: LoRaChannelMath) -> some View {
    if chartStyle == .radioScreen {
      radioScreenSections(channel: channel)
    } else {
      legacyChartSections(channel: channel)
    }
  }

  /// The Radio Screen on a radio without a Channel view of its own: the same card as a Cairn
  /// radio's, from the app's readings (`SpectrumRadioScreenSource`), then the selected packet's
  /// card and the traffic table.
  private func radioScreenSections(channel: LoRaChannelMath) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      // Paused, the view holds the moment it was paused at (`SpectrumViewModel.pausedAt`).
      let now = viewModel.displayNow(max(context.date, Date()))
      let history = SpectrumRadioScreenSource.history(
        viewModel: viewModel, window: window, columns: SpectrumFeed.deviceColumns(horizontalSizeClass),
        now: now, channel: channel
      )
      let packets = viewModel.packets.elements
      VStack(alignment: .leading, spacing: CardStyle.spacing) {
        SpectrumDeviceCard(
          viewModel: viewModel,
          window: window,
          onSelectWindow: { appState.spectrumFeed.pickedWindow = $0 },
          selectedMark: $selectedMark,
          history: history,
          trend: SpectrumRadioScreenSource.trend(viewModel: viewModel, channel: channel, now: now)
        )

        if let selectedMark, let mark = history.marks.last(where: { $0.mark.rxMs == selectedMark })?.mark {
          let date = SpectrumDeviceMarkMatch.date(of: mark, radioNowMs: history.stats?.nowMs ?? 0, receivedAt: now)
          Group {
            if let packet = matchingPacket(for: mark, at: date) {
              SpectrumPacketCallout(
                packet: packet,
                onDetails: { detailPacket = packet },
                onClose: { self.selectedMark = nil }
              )
            } else {
              SpectrumDeviceMarkCallout(mark: mark, date: date) { self.selectedMark = nil }
            }
          }
          .cardSurface(padding: 12)
          .transition(.opacity)
        }

        if !showsTrafficBeside {
          SpectrumTrafficSection(
            packets: Array(packets.suffix(max(1, trafficRows)).reversed()),
            now: now
          ) { detailPacket = $0 }
            .padding(.top, 8)
        }
      }
    }
  }

  private func legacyChartSections(channel: LoRaChannelMath) -> some View {
    // Only what moves with the clock sits in the timeline: the airtime share and packet
    // rate, the chart's sliding window and the table's ages. NOW and FLOOR are equatable,
    // so a tick passes them by and only a new reading redraws them.
    TimelineView(.periodic(from: .now, by: window.refreshInterval)) { context in
      // A redraw for new data lands between ticks; the present then is the clock, not the
      // last tick, so a packet that just arrived isn't held back off the chart's right edge.
      // Paused, the chart holds the moment it was paused at (`SpectrumViewModel.pausedAt`).
      let now = viewModel.displayNow(max(context.date, Date()))
      // The packet ring laid out once per tick and shared by everything below it.
      let packets = viewModel.packets.elements
      VStack(alignment: .leading, spacing: CardStyle.spacing) {
        SpectrumMetricStrip(
          viewModel: viewModel,
          airtime: airtimeReading(now: now),
          packets: packetsReading(packets: packets, now: now)
        ) { detailPacket = viewModel.latestPacket }

        channelCard(channel: channel, packets: packets, now: now)

        if !showsTrafficBeside {
          SpectrumTrafficSection(
            packets: Array(packets.suffix(max(1, trafficRows)).reversed()),
            now: now
          ) { detailPacket = $0 }
            .padding(.top, 8)
        }
      }
    }
  }

  // MARK: - Clocked readings

  /// Cairn's AIR: the share of the window the radio spent receiving and sending. Cairn's BUSY
  /// (readings above the floor) needs instantaneous RSSI samples the companion protocol doesn't
  /// carry, so airtime stands in for how occupied the channel is.
  private func airtimeReading(now: Date) -> SpectrumAirtimeReading {
    let share = SpectrumStats.airtimeShare(viewModel.airtime.elements, window: window.statsDuration, now: now)
    return SpectrumAirtimeReading(share: share)
  }

  /// Cairn's PKT/MIN and the count behind it, over the same span.
  private func packetsReading(packets: [SpectrumPacket], now: Date) -> SpectrumPacketsReading {
    let start = now.addingTimeInterval(-window.statsDuration)
    let count = packets.count - packets.firstIndex(atOrAfter: start, date: \.date)
    let rate = SpectrumStats.packetsPerMinute(
      count: count,
      window: window.statsDuration,
      observedSince: viewModel.packetsObservedSince,
      now: now
    )
    // Over the chart's window, as the chart's dotted peak line is.
    let peak = SpectrumStats.peak(packets, since: now.addingTimeInterval(-window.duration))
    let level = peak.map { SpectrumLevel(rssi: $0, floor: viewModel.currentNoiseFloor) }
    return SpectrumPacketsReading(count: count, perMinute: rate, peak: peak, peakLevel: level)
  }

  // MARK: - Channel

  private func channelCard(channel: LoRaChannelMath, packets: [SpectrumPacket], now: Date) -> some View {
    let selected = selectedPacketID.flatMap { id in packets.last { $0.id == id } }
    // Formatted once per tick, from the tick's clock, though both layouts below use it.
    let info = footer(now: now)
    return VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack {
          channelTitle(info: info)
          Spacer(minLength: 12)
          windowPicker
            .fixedSize()
        }
        VStack(alignment: .leading, spacing: 8) {
          channelTitle(info: info)
          windowPicker
        }
      }

      if chartStyle == .lineChart {
        SpectrumChannelChart(
          channel: channel,
          viewModel: viewModel,
          packets: packets,
          window: window,
          now: now,
          selectedPacketID: $selectedPacketID
        )
        .frame(height: chartHeight(220))
        .lineChartPanel()
      } else {
        modernPlot(appState.spectrumFeed.frame(barCount: chartStyle.barCount(horizontalSizeClass), now: now))
      }

      if let selected {
        SpectrumPacketCallout(
          packet: selected,
          onDetails: { detailPacket = selected },
          onClose: { selectedPacketID = nil }
        )
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
        .transition(.opacity)
      }

      SpectrumChartLegend(showsSeries: chartStyle == .lineChart)
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selectedPacketID)
    .cardSurface(padding: 12)
  }

  /// The card's title with an "i" that explains how the chart is drawn (and how much of the
  /// window the noise readings cover), instead of a paragraph under the chart.
  /// In Home's card chrome: a tinted glyph beside a small uppercase caption.
  private func channelTitle(info: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "chart.xyaxis.line")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(SpectrumPalette.noise)
        .accessibilityHidden(true)
      Text(L10n.Tools.Tools.Spectrum.Figure.channel)
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)
      InfoButton(info, title: L10n.Tools.Tools.Spectrum.Figure.channel)
    }
  }

  private var windowPicker: some View {
    Picker(
      L10n.Tools.Tools.Spectrum.window,
      selection: Binding(get: { window }, set: { appState.spectrumFeed.pickedWindow = $0 })
    ) {
      ForEach(SpectrumWindow.allCases) { option in
        Text(option.shortTitle)
          .accessibilityLabel(option.spokenTitle)
          .tag(option)
      }
    }
    .pickerStyle(.segmented)
  }

  /// What the chart is drawn from, and, while the app hasn't been reading for the whole
  /// window, how much of it the noise readings cover: they're taken only while this page is
  /// open, unlike the packets, which the RX log records all along.
  private func footer(now: Date) -> String {
    let interval = viewModel.readingInterval
    var parts = [L10n.Tools.Tools.Spectrum.chartFooterRate(Duration.seconds(interval).formatted(.units(width: .wide)))]
    let covered = viewModel.samplingSince.map { now.timeIntervalSince($0) } ?? 0
    if covered < window.duration - 2 * interval {
      let span = Duration.seconds(max(0, covered).rounded())
        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
      parts.append(L10n.Tools.Tools.Spectrum.coverage(span, window.spokenTitle))
    }
    return parts.joined(separator: " ")
  }
}

// MARK: - Header band

/// The page's subject in one slim card: the channel's condition, then the preset and frequency,
/// then "SF7 · 62.5 kHz · CR 4/5", the transmit power and the airtime of a 40 B packet. The text is
/// the way into Radio settings, pushed in place so it works from the Spectrum tab and from the Tools
/// hub alike; Advert and RX Log sit beside it as round buttons. A failed reading is said here too,
/// rather than in a card of its own. The radio's name is the tab's title, so it isn't here.
private struct SpectrumHeaderBand: View {
  let device: DeviceDTO
  let channel: LoRaChannelMath
  let txPower: Int?
  let viewModel: SpectrumViewModel

  @Environment(\.appState) private var appState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    // One layout that changes shape, so the actions keep their state (a send in flight) when
    // the text size crosses into the accessibility sizes.
    let layout = stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
    layout {
      // The radio's channel settings: Settings › Radio, the one home for them.
      Button {
        appState.navigation.navigateToSetting(.radio)
      } label: {
        summary
      }
      .buttonStyle(.plain)
      .accessibilityHint(L10n.Tools.Tools.Spectrum.Hint.radio)

      SpectrumHeaderActions(labelled: stacked)
    }
    .cardSurface(padding: 12)
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        SpectrumConditionLabel(channel: channel, viewModel: viewModel)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }

      // The frequency is the line's key value, so a long preset name gives way to it.
      HStack(spacing: 0) {
        Text(HomeStatusLines.presetName(device, region: appState.regionSelection))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(" · " + SpectrumFormat.megahertz(channel.frequencyHz))
          .lineLimit(1)
          .fixedSize()
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)

      strip

      if let error = viewModel.errorMessage {
        // Firmware without the stats command is a fact about the radio, not a fault.
        Label {
          Text(error)
        } icon: {
          Image(systemName: viewModel.statsUnsupported ? "info.circle" : "exclamationmark.triangle.fill")
            .foregroundStyle(viewModel.statsUnsupported ? Color.secondary : SpectrumPalette.warning)
        }
        .font(.footnote)
        .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .hoverEffect(.highlight)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }

  /// The modulation, the transmit power and a packet's airtime: on one line when the band is
  /// wide enough, else the modulation over the rest, else one item a line, each free to wrap so
  /// a long airtime line in a longer language never runs past the card's edge.
  private var strip: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        modulationLabel.fixedSize()
        powerAndAirtime(fixed: true)
      }
      VStack(alignment: .leading, spacing: 2) {
        modulationLabel.fixedSize()
        HStack(spacing: 10) { powerAndAirtime(fixed: true) }
      }
      VStack(alignment: .leading, spacing: 2) {
        modulationLabel
        powerAndAirtime(fixed: false)
      }
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .labelStyle(SpectrumCompactLabelStyle())
  }

  private var modulationLabel: some View {
    Label(modulation, systemImage: "waveform")
  }

  @ViewBuilder private func powerAndAirtime(fixed: Bool) -> some View {
    if let txPower {
      Label(SpectrumFormat.dBm(Double(txPower)), systemImage: "bolt.fill")
        .fixedSize(horizontal: fixed, vertical: true)
    }
    // The compact form keeps power and airtime on one line beside or under the modulation;
    // VoiceOver reads the full sentence.
    Label(airtime.short, systemImage: "timer")
      .fixedSize(horizontal: fixed, vertical: true)
      .accessibilityLabel(airtime.full)
  }

  /// "SF7 · 62.5 kHz · CR 4/5"
  private var modulation: String {
    [
      L10n.Tools.Tools.Spectrum.Header.spreadingFactor(channel.spreadingFactor),
      SpectrumFormat.kilohertz(channel.bandwidthHz),
      L10n.Tools.Tools.Spectrum.Header.codingRate(channel.codingRate),
    ].joined(separator: " · ")
  }

  /// "~214 ms/pkt" on screen, "~214 ms per 40-byte packet" spoken.
  private var airtime: (short: String, full: String) {
    let milliseconds = (channel.timeOnAir(payloadBytes: LoRaChannelMath.airtimeHintBytes) * 1000).rounded()
    let text = milliseconds.formatted(.number.precision(.fractionLength(0)))
    return (
      L10n.Tools.Tools.Spectrum.Header.airtimeShort(text),
      L10n.Tools.Tools.Spectrum.Header.airtime(text, LoRaChannelMath.airtimeHintBytes)
    )
  }
}

/// A label with a small glyph tight against its text, for the header's strip.
private struct SpectrumCompactLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
        .imageScale(.small)
        .accessibilityHidden(true)
      configuration.title
    }
  }
}

/// The header's first line, on its own so only it redraws with each floor reading; the preset
/// lookup, the strip and the airtime around it change with the radio's settings alone.
/// Icon in the status color, words in ordinary ink: the state never rests on color.
private struct SpectrumConditionLabel: View {
  let channel: LoRaChannelMath
  let viewModel: SpectrumViewModel

  var body: some View {
    if let floor = viewModel.currentNoiseFloor {
      let condition = ChannelCondition(desensitization: channel.desensitization(noiseFloor: floor))
      Label {
        Text(condition.title)
      } icon: {
        Image(systemName: condition.systemImage)
          .foregroundStyle(condition.color)
      }
      .font(.headline)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
    } else if viewModel.statsUnsupported {
      // No floor will ever come: no spinner. The line under the strip says why.
      Text(verbatim: "—")
        .font(.headline)
        .foregroundStyle(.secondary)
    } else {
      // The short word, not the page's calibrating sentence, which a phone-width card cuts off.
      Label {
        Text(viewModel.isCalibrating ? L10n.Tools.Tools.Spectrum.Meter.calibrating : L10n.Tools.Tools.Spectrum.measuring)
          .foregroundStyle(.secondary)
      } icon: {
        ProgressView()
          .controlSize(.small)
      }
      .font(.headline)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
    }
  }
}

// MARK: - Actions

/// The page's primary actions as two round buttons in the header band: an advert (zero-hop or
/// flood, the flood one confirmed as on Home) and the RX Log, which holds every packet the traffic
/// table leaves out. At accessibility text sizes they become labelled capsules under the text.
/// The advert's state lives here so a send doesn't redraw the page around it.
private struct SpectrumHeaderActions: View {
  /// Capsules with their titles, for the accessibility sizes; round glyph buttons otherwise.
  let labelled: Bool

  @Environment(\.appState) private var appState
  @State private var isChoosing = false
  @State private var isSending = false
  @State private var showsSent = false
  /// The last send failed: the button says so for a moment, not only the haptic.
  @State private var showsFailed = false
  @State private var succeeded = false
  @State private var failed = false

  private var advertGlyph: String {
    showsSent ? "checkmark" : (showsFailed ? "exclamationmark.triangle.fill" : "megaphone.fill")
  }

  private var advertTint: Color {
    showsSent ? SpectrumPalette.good : (showsFailed ? SpectrumPalette.warning : .accentColor)
  }

  var body: some View {
    HStack(spacing: 8) {
      Button {
        isChoosing = true
      } label: {
        actionLabel(
          L10n.Tools.Tools.Spectrum.advert,
          systemImage: advertGlyph,
          tint: advertTint,
          isBusy: isSending
        )
      }
      .buttonStyle(.plain)
      .radioDisabled(for: appState.connectionState, or: isSending)
      .accessibilityLabel(L10n.Tools.Tools.advert)
      // The glyph swap is the only visible outcome; say it to VoiceOver too, not only the haptic.
      .accessibilityValue(
        showsSent ? L10n.Chats.Chats.Message.Status.sent : (showsFailed ? L10n.Chats.Chats.Message.Status.failed : "")
      )
      .help(L10n.Tools.Tools.advert)
      .accessibilityIdentifier("spectrum.advert")
      .sheet(isPresented: $isChoosing) {
        AdvertChoiceSheet { flood in send(flood: flood) }
      }
      .sensoryFeedback(.success, trigger: succeeded)
      .sensoryFeedback(.error, trigger: failed)

      NavigationLink {
        RxLogView()
      } label: {
        actionLabel(L10n.Tools.Tools.rxLog, systemImage: "waveform.badge.magnifyingglass", tint: .accentColor, isBusy: false)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Tools.Tools.rxLog)
      .accessibilityHint(L10n.Tools.Tools.Spectrum.Traffic.seeAllHint)
      .help(L10n.Tools.Tools.rxLog)
      .accessibilityIdentifier("spectrum.rxLog")
    }
  }

  @ViewBuilder
  private func actionLabel(_ title: String, systemImage: String, tint: Color, isBusy: Bool) -> some View {
    let glyph = Group {
      if isBusy {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: systemImage)
          .font(.body.weight(.semibold))
          .foregroundStyle(tint)
          .contentTransition(.symbolEffect(.replace))
      }
    }
    if labelled {
      HStack(spacing: 6) {
        glyph
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(.fill.tertiary, in: .capsule)
      .contentShape(.capsule)
      .hoverEffect(.highlight)
    } else {
      glyph
        .frame(width: 40, height: 40)
        .background(.fill.tertiary, in: .circle)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .hoverEffect(.highlight)
    }
  }

  private func send(flood: Bool) {
    guard !isSending else { return }
    isSending = true
    Task {
      do {
        try await appState.sendSelfAdvert(flood: flood)
        succeeded.toggle()
        isSending = false
        showsSent = true
        try? await Task.sleep(for: .seconds(2))
        showsSent = false
      } catch {
        logger.error("Failed to send advert from Spectrum (flood=\(flood)): \(error.localizedDescription)")
        failed.toggle()
        isSending = false
        showsFailed = true
        try? await Task.sleep(for: .seconds(3))
        showsFailed = false
      }
    }
  }
}

// MARK: - Metric strip

/// AIR over the window, worked out once per tick.
private struct SpectrumAirtimeReading: Equatable {
  let rx: Double?
  let tx: Double?

  init(share: (rx: Double, tx: Double)?) {
    rx = share?.rx
    tx = share?.tx
  }

  var total: Double? {
    guard let rx, let tx else { return nil }
    return min(1, rx + tx)
  }

  var load: SpectrumStats.Load? { total.map(SpectrumStats.Load.init(share:)) }
}

/// PKT/MIN, the count behind it and the strongest packet in the window, worked out once per tick.
private struct SpectrumPacketsReading: Equatable {
  let count: Int
  let perMinute: Double?
  let peak: Double?
  /// The peak's level over the floor, for its color.
  let peakLevel: SpectrumLevel?
}

/// The four readings in one card, Cairn's NOW, FLOOR, AIR and PKT/MIN side by side, in place of
/// four tall cards; at large text sizes they fold into two rows of two.
private struct SpectrumMetricStrip: View {
  let viewModel: SpectrumViewModel
  let airtime: SpectrumAirtimeReading
  let packets: SpectrumPacketsReading
  let onOpenLatest: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      // Chosen by text size rather than measured: NOW and FLOOR hold their own state (the
      // floor's history popover), which a measured choice between two copies would split.
      if dynamicTypeSize > .xLarge {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
          GridRow {
            now
            floor
          }
          Divider()
          GridRow {
            air
            rate
          }
        }
      } else {
        HStack(alignment: .top, spacing: 0) {
          now
          divided { floor }
          divided { air }
          divided { rate }
        }
      }
    }
    .cardSurface(padding: 12)
  }

  /// A column after the first, behind a hairline.
  private func divided(@ViewBuilder _ content: () -> some View) -> some View {
    // Top-aligned: the hairline takes the row's full height, and would centre a shorter column.
    HStack(alignment: .top, spacing: 0) {
      Divider()
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
      content()
    }
  }

  private var now: some View {
    SpectrumNowMetric(viewModel: viewModel, onOpen: onOpenLatest)
      .equatable()
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var floor: some View {
    SpectrumFloorMetric(viewModel: viewModel)
      .equatable()
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var air: some View {
    SpectrumAirMetric(reading: airtime, isUnsupported: viewModel.statsUnsupported)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var rate: some View {
    let value = packets.perMinute.map {
      L10n.Tools.Tools.Spectrum.Figure.perMinute($0.formatted(.number.precision(.fractionLength(1))))
    }
    let detail = value == nil ? L10n.Tools.Tools.Spectrum.measuring : L10n.Tools.Tools.RxLog.packetsCount(packets.count)
    // The strongest packet, said to be a packet: the radio's own PEAK is of its live readings.
    let peak = packets.peak.map { L10n.Tools.Tools.Spectrum.Meter.peakPacket(SpectrumFormat.dBm($0)) }
    let peakTint = packets.peakLevel?.color ?? .secondary
    return SpectrumMiniMetric(
      title: L10n.Tools.Tools.Spectrum.Meter.packets,
      systemImage: "tray.and.arrow.down",
      tint: .purple,
      value: value ?? "—",
      valueTint: value == nil ? .secondary : .primary,
      accessibilityValue: [value, detail, peak].compactMap(\.self).joined(separator: ", ")
    ) {
      SpectrumMiniDetail(detail)
      if let peak, let peakValue = packets.peak {
        // "Peak packet −87 dBm", then "Peak −87 dBm", then the bare arrow and figure where a
        // quarter of the card can't hold more; in the peak's level color over the floor.
        ViewThatFits(in: .horizontal) {
          SpectrumMiniDetail(peak, tint: peakTint).fixedSize()
          SpectrumMiniDetail(L10n.Tools.Tools.Spectrum.Meter.peak + " " + SpectrumFormat.dBm(peakValue), tint: peakTint).fixedSize()
          SpectrumMiniDetail("▲" + Int(peakValue.rounded()).formatted(), tint: peakTint)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One reading in the strip, in Home's card chrome shrunk to a column: a tinted glyph beside a
/// small uppercase caption, the value, and up to two short lines under it. One element for
/// VoiceOver, its caption as the label and every fact as the value.
private struct SpectrumMiniMetric<Details: View>: View {
  let title: String
  /// The caption VoiceOver reads, where the strip shows a shortened one.
  var accessibilityTitle: String?
  let systemImage: String
  let tint: Color
  let value: String
  var valueTint: Color = .primary
  let accessibilityValue: String
  @ViewBuilder let details: () -> Details

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 3) {
        Image(systemName: systemImage)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.caption2.weight(.semibold))
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      Text(value)
        .font(.headline.monospacedDigit())
        .foregroundStyle(valueTint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      details()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityTitle ?? title)
    .accessibilityValue(accessibilityValue)
  }
}

/// A line under a strip reading: small, quiet, one line, shrinking a little before it truncates.
private struct SpectrumMiniDetail: View {
  let text: String
  var tint: Color = .secondary
  var lines = 1

  init(_ text: String, tint: Color = .secondary, lines: Int = 1) {
    self.text = text
    self.tint = tint
    self.lines = lines
  }

  var body: some View {
    Text(text)
      .font(.caption2.monospacedDigit())
      .foregroundStyle(tint)
      .lineLimit(lines)
      .minimumScaleFactor(0.8)
  }
}

/// Cairn's NOW and MARGIN in one column: the newest packet's strength, how far it stood above the
/// floor, and where the reading came from (a heard packet and its age, or the radio's own last
/// reading). Titled "Last packet", not "Now": until the radio reports live readings both figures
/// are a packet's, not the channel's at this moment. The strength wears its level color. Opens that packet's detail when there is one. Equal whenever the model is the same,
/// so a tick of the page's clock passes it by; new readings still redraw it through observation.
private struct SpectrumNowMetric: View, Equatable {
  let viewModel: SpectrumViewModel
  let onOpen: () -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.viewModel === rhs.viewModel
  }

  var body: some View {
    // `latestPacket` is the ring's last element, read without laying the ring out.
    if let packet = viewModel.latestPacket, packet.rssi != nil {
      // Only a heard packet has an age to keep current; the clock redraws just this column.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Button(action: onOpen) {
          metric(age: max(context.date, Date()).timeIntervalSince(packet.date))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.Tools.Tools.Spectrum.Hint.latestPacket)
      }
      .accessibilityIdentifier("spectrum.card.signal")
    } else {
      metric(age: nil)
        .accessibilityIdentifier("spectrum.card.signal")
    }
  }

  /// `age` is the heard packet's, or nil when the reading isn't from one.
  private func metric(age: TimeInterval?) -> some View {
    let rssi = viewModel.nowRSSI
    let floor = viewModel.currentNoiseFloor
    let margin = SpectrumStats.margin(packetRSSI: rssi, floor: floor)
    let value = rssi.map(SpectrumFormat.dBm) ?? "—"
    let note = margin.map { (floor == nil ? "≈ " : "") + SpectrumFormat.signedDB($0) }
    let isClear = margin.map { $0 >= SpectrumStats.clearMargin } == true
    // Where the reading came from, chosen by its source: the margin is there whenever a
    // reading is, so it can't tell a heard packet from the radio's own last RSSI.
    let source: String = if let age {
      L10n.Tools.Tools.Spectrum.Meter.nowCaption(SpectrumPacketFormat.age(age))
    } else if rssi != nil {
      L10n.Tools.Tools.Spectrum.Meter.fromRadio
    } else {
      L10n.Tools.Tools.Spectrum.waitingForPacket
    }
    let verdict = margin.map {
      $0 >= SpectrumStats.clearMargin ? L10n.Tools.Tools.Spectrum.Meter.marginClear : L10n.Tools.Tools.Spectrum.Meter.marginLow
    }
    let level = rssi.map { SpectrumLevel(rssi: $0, floor: floor) }
    return SpectrumMiniMetric(
      title: L10n.Tools.Tools.Spectrum.Meter.lastPacket,
      systemImage: "dot.radiowaves.left.and.right",
      tint: SpectrumPalette.link,
      value: value,
      valueTint: level.map { $0.color ?? .primary } ?? .secondary,
      accessibilityValue: [value, note, verdict, source].compactMap(\.self).joined(separator: ", ")
    ) {
      if let note {
        // A glyph keyed to the verdict, so clear or low doesn't rest on the color alone.
        Label(note, systemImage: isClear ? "checkmark.circle" : "exclamationmark.circle")
          .labelStyle(SpectrumCompactLabelStyle())
          .font(.caption2.monospacedDigit())
          .foregroundStyle(isClear ? SpectrumPalette.good : .secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      if let age {
        // The age alone, by a clock: "Last packet, 12s ago" doesn't fit a quarter of the card.
        Label(SpectrumPacketFormat.age(age), systemImage: "clock")
          .labelStyle(SpectrumCompactLabelStyle())
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else {
        SpectrumMiniDetail(source, lines: rssi == nil ? 2 : 1)
      }
    }
  }
}

/// Cairn's FLOOR with its "NF 24h" sparkline: the floor now, which way it's heading, and a tiny
/// line of the floor a minute at a time; a tap opens the history at a readable size, with its range
/// and since when this session has been reading it (the app keeps no floor history between
/// visits). Equal whenever the model is the same, so the page's clock passes it by and the popover
/// stays open across ticks.
private struct SpectrumFloorMetric: View, Equatable {
  let viewModel: SpectrumViewModel

  @State private var showsHistory = false

  /// The inline line draws the last two hours; the popover draws all of it.
  private static let inlineSamples = 120

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.viewModel === rhs.viewModel
  }

  var body: some View {
    let floor = viewModel.currentNoiseFloor
    let trend = viewModel.floorTrend
    let value = floor.map(SpectrumFormat.dBm)
      ?? (viewModel.isCalibrating ? "≈ " + SpectrumFormat.dBm(SpectrumStats.uncalibratedFloor) : "—")
    let direction = floor == nil ? nil : viewModel.noiseTrend
    let history = historyLines(trend: trend, hasFloor: floor != nil)

    Button {
      showsHistory = true
    } label: {
      SpectrumMiniMetric(
        title: L10n.Tools.Tools.Spectrum.Meter.floor,
        systemImage: "waveform.path",
        tint: SpectrumPalette.noise,
        value: value,
        valueTint: floor == nil ? .secondary : .primary,
        accessibilityValue: ([value, direction?.title].compactMap(\.self) + history).joined(separator: ", ")
      ) {
        if let direction {
          Label(direction.title, systemImage: Self.glyph(direction))
            .labelStyle(SpectrumCompactLabelStyle())
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        if trend.count >= 2 {
          SpectrumFloorHistoryPopover.sparkline(Array(trend.suffix(Self.inlineSamples)), lineWidth: 1.5)
            .frame(height: 12)
            .padding(.top, 2)
        } else if let first = history.first {
          SpectrumMiniDetail(first)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Tools.Tools.Spectrum.Hint.floorHistory)
    .accessibilityIdentifier("spectrum.card.floor")
    .popover(isPresented: $showsHistory) {
      SpectrumFloorHistoryPopover(viewModel: viewModel)
        .presentationCompactAdaptation(.popover)
    }
  }

  private static func glyph(_ trend: NoiseTrend) -> String {
    switch trend {
    case .rising: "arrow.up.right"
    case .steady: "arrow.right"
    case .falling: "arrow.down.right"
    }
  }

  private func historyLines(trend: [NoiseSample], hasFloor: Bool) -> [String] {
    SpectrumFloorHistoryPopover.historyLines(viewModel: viewModel, trend: trend, hasFloor: hasFloor)
  }
}

/// The floor's history at a readable size: the line, its range and since when. From a Cairn radio's
/// own view, its 24 h trend and that day's range.
struct SpectrumFloorHistoryPopover: View {
  let viewModel: SpectrumViewModel

  var body: some View {
    let trend = viewModel.floorTrend
    let lines = Self.historyLines(viewModel: viewModel, trend: trend, hasFloor: viewModel.currentNoiseFloor != nil)
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.Tools.Tools.Spectrum.History.title)
        .font(.headline)
      if trend.count >= 2 {
        Self.sparkline(trend, lineWidth: 2)
          .frame(height: 64)
          .accessibilityHidden(true)
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .frame(minWidth: 240, alignment: .leading)
  }

  /// The range and since when, once there's a history; since when alone while the first minute
  /// is still open; or why there's nothing yet. The radio's own trend is its last day, so it gives
  /// the range alone.
  static func historyLines(viewModel: SpectrumViewModel, trend: [NoiseSample], hasFloor: Bool) -> [String] {
    let values = trend.map(\.dBm)
    if viewModel.source == .device {
      if let low = values.min(), let high = values.max() { return [range(low, high)] }
      return [hasFloor ? L10n.Tools.Tools.Spectrum.Device.collecting : L10n.Tools.Tools.Spectrum.Meter.calibrating]
    }
    if trend.count >= 2, let low = values.min(), let high = values.max(), let since = trend.first?.date {
      return [range(low, high), L10n.Tools.Tools.Spectrum.History.caption(since.formatted(date: .omitted, time: .shortened))]
    } else if hasFloor {
      // A floor is in but the minute-by-minute history isn't yet: say since when, not
      // "Measuring…", which would contradict the value above it.
      return trend.first.map { [L10n.Tools.Tools.Spectrum.History.caption($0.date.formatted(date: .omitted, time: .shortened))] } ?? []
    } else if viewModel.statsUnsupported {
      return ["—"]
    } else {
      return [viewModel.isCalibrating ? L10n.Tools.Tools.Spectrum.Meter.calibrating : L10n.Tools.Tools.Spectrum.measuring]
    }
  }

  /// At least a 4 dB span, centred, so a steady floor draws as a flat line mid-box.
  static func sparkline(_ trend: [NoiseSample], lineWidth: CGFloat) -> some View {
    let values = trend.map(\.dBm)
    let low = values.min() ?? 0
    let high = values.max() ?? 0
    let pad = max(0, 4 - (high - low)) / 2 + 1
    return Chart(Array(trend.enumerated()), id: \.offset) { _, sample in
      LineMark(x: .value("Time", sample.date), y: .value("dBm", sample.dBm))
        .foregroundStyle(SpectrumPalette.noise)
        .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.monotone)
    }
    .chartYScale(domain: (low - pad)...(high + pad))
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .accessibilityHidden(true)
  }

  static func range(_ low: Double, _ high: Double) -> String {
    let lowText = Int(low.rounded()).formatted()
    let highText = Int(high.rounded()).formatted()
    return SpectrumFormat.dBm(low.rounded()) == SpectrumFormat.dBm(high.rounded())
      ? SpectrumFormat.dBm(low)
      : L10n.Tools.Tools.Spectrum.History.range(lowText, highText)
  }
}

/// Cairn's AIR in one column: the share of the window on air, its RX/TX split, and Heavy or Very
/// heavy use past 30 % and 60 % (with a warning glyph, so the state never rests on color). Not
/// "Busy": the radio's BUSY is time above the floor, a reading the app doesn't have.
private struct SpectrumAirMetric: View {
  let reading: SpectrumAirtimeReading
  /// The radio's firmware has no stats command, so no airtime will ever come.
  var isUnsupported = false

  private static func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(1)))
  }

  var body: some View {
    let load = reading.load
    let loadTint = load?.color
    let note = load?.title
    let value = reading.total.map(Self.percent)
    let split: String? = if let rx = reading.rx, let tx = reading.tx {
      L10n.Tools.Tools.Spectrum.Meter.airCaption(Self.percent(rx), Self.percent(tx))
    } else {
      nil
    }
    SpectrumMiniMetric(
      // "Air": the full "Airtime" runs past a quarter of the card in several languages.
      title: L10n.Tools.Tools.Spectrum.Meter.air,
      accessibilityTitle: L10n.Tools.Tools.Spectrum.Figure.airtime,
      systemImage: loadTint == nil ? "hourglass" : "exclamationmark.triangle.fill",
      tint: loadTint ?? .secondary,
      value: value ?? "—",
      valueTint: loadTint ?? (value == nil ? .secondary : .primary),
      accessibilityValue: [value, note, split ?? (isUnsupported ? nil : L10n.Tools.Tools.Spectrum.measuring)]
        .compactMap(\.self).joined(separator: ", ")
    ) {
      if let split, let rx = reading.rx, let tx = reading.tx {
        // "RX 1.2% · TX 0.1%", or, where a quarter of the card can't hold it, the arrows the
        // RX log uses for the directions.
        ViewThatFits(in: .horizontal) {
          SpectrumMiniDetail(split).fixedSize()
          SpectrumMiniDetail("↓" + Self.percent(rx) + " ↑" + Self.percent(tx))
        }
      } else if !isUnsupported {
        SpectrumMiniDetail(L10n.Tools.Tools.Spectrum.measuring)
      }
      if let note, let loadTint {
        SpectrumMiniDetail(note, tint: loadTint)
      }
    }
  }
}

#Preview("Not connected") {
  NavigationStack {
    SpectrumView()
  }
  .environment(\.appState, AppState())
}

/// What restarts the Spectrum page's readings: a new connection, the link going away or coming
/// back, or the app coming back to the foreground.
struct SpectrumPollKey: Equatable {
  let servicesVersion: Int
  /// The live services container; nil once the radio disconnects.
  let services: ObjectIdentifier?
  /// The link is up (syncing or ready).
  let isConnected: Bool
  let isActive: Bool

  /// The page polls the radio: there is a live connection and the app is in the foreground.
  var polls: Bool { services != nil && isConnected && isActive }
}

extension View {
  /// The Line Chart on the dark glass the other styles draw on, so the page reads as one
  /// instrument whichever style is picked.
  func lineChartPanel(cornerRadius: CGFloat = 12) -> some View {
    padding(.horizontal, 6)
      .padding(.vertical, 8)
      .background(SpectrumPersistenceRamp.panel, in: .rect(cornerRadius: cornerRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
      .environment(\.colorScheme, .dark)
  }
}
