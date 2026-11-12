import CairnServices
import SwiftUI

/// One card on a repeater's or room's Dashboard, in Home's card style: what it is, its reading, a
/// line or two of context, and where a tap goes (the page or sheet that shows more or edits it).
struct NodeDashboardCardItem: Identifiable {
  enum Destination {
    case action(() -> Void)
    case route(NodeStatusRoute)
    /// Pushes this page, built in place: for a page reached from a page that wasn't value-pushed.
    case page(AnyView)
    /// A reading with nothing behind it: no chevron, not a button.
    case none
    /// The reading in full, on a page of its own (`NodeReadingPage`): each fact labelled and what
    /// it means. For a reading with nothing to chart, or a node with no saved history.
    case details(NodeReadingDetail)
    /// The settings the card sums up, in a small sheet over the page: the card's figure on top,
    /// the controls (switches with what they do, a choice, a link to a list) under it.
    case controls(AnyView)
    /// The reading's history, pushed straight from the card: its charts, each opening the full
    /// graph (the user, 2026-11-08: no sheet of facts in between).
    case history(NodeHistoryTarget)

    /// The reading's history scoped to it when the node keeps one, else its facts in a sheet
    /// (nothing when there are none).
    static func history(
      _ target: NodeHistoryTarget?,
      scope: HistoryScope,
      orFacts facts: [NodeReadingDetail.Fact],
      footnote: String? = nil
    ) -> Destination {
      if let target { return .history(target.scoped(scope)) }
      return facts.isEmpty ? .none : .details(.init(facts: facts, footnote: footnote, history: nil))
    }
  }

  let id: String
  let title: String
  let systemImage: String
  let tint: Color
  let value: String
  var valueTint: Color = .primary
  var note: String?
  var noteTint: Color = .secondary
  var details: [String] = []
  let destination: Destination
  /// The value's fraction and unit a size down (a frequency: "910" large, ".525 MHz" smaller).
  var shrinksFraction = false
  /// Its reading is still on its way (showing nothing, or the last visit's value): dimmed, not
  /// tappable, with a small spinner, until the fresh reading lands.
  var isPending = false
  /// The reading's recent history as a trend line under the figure, as Home's Battery tile draws it
  /// (`MetricSparkline`); nil, or fewer than two points, draws none.
  var trend: [MetricChartView.Series]?

  var isReadOnly: Bool {
    if case .none = destination { return true }
    return false
  }
}

/// What a reading card's sheet shows: the card's figures one to a line, labelled, a note on what
/// they mean, and where its history is kept.
struct NodeReadingDetail {
  struct Fact: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    var tint: Color?
  }

  var facts: [Fact]
  var footnote: String?
  /// The node whose stored snapshots chart this reading; nil when there's no history to show.
  var history: NodeHistoryTarget?
}

/// The node behind a History link: `TelemetryHistoryOverviewView`'s inputs.
struct NodeHistoryTarget: Hashable {
  let publicKey: Data
  let radioID: UUID
  let showNeighbors: Bool
  /// Which readings the page charts.
  var scope: HistoryScope = .all

  /// The same node's history, charting only `scope`.
  func scoped(_ scope: HistoryScope) -> Self {
    var target = self
    target.scope = scope
    return target
  }

  /// The target of a `.history` route; nil for any other route.
  init?(_ route: NodeStatusRoute?) {
    guard case let .history(publicKey, radioID, showNeighbors) = route else { return nil }
    self.init(publicKey: publicKey, radioID: radioID, showNeighbors: showNeighbors)
  }

  init(publicKey: Data, radioID: UUID, showNeighbors: Bool) {
    self.publicKey = publicKey
    self.radioID = radioID
    self.showNeighbors = showNeighbors
  }
}

/// The Dashboard's readings as Home's two-column card grid, each card opening what it sums up.
///
/// Inside Settings (`isInSettings`) the same items draw as the iPhone's Settings rows instead: icon,
/// name, the reading on the right, its context under the name, and a chevron; a card's controls are
/// pushed as a page of their own rather than shown in a small sheet (a reading's sheet stays).
struct NodeDashboardCardGrid: View {
  let items: [NodeDashboardCardItem]
  @Environment(\.isInSettings) private var isInSettings
  /// The card whose sheet is open, by id: the sheet reads the card from `items` on every update,
  /// so a switch flipped in it shows its new state at once.
  @State private var presentedID: String?

  var body: some View {
    Group {
      if isInSettings {
        settingsRows
      } else {
        grid
      }
    }
      .sheet(isPresented: Binding(get: { presentedID != nil }, set: { if !$0 { presentedID = nil } })) {
        if let item = items.first(where: { $0.id == presentedID }) {
          switch item.destination {
          case let .controls(content):
            NodeControlsSheet(item: item, content: content)
          default:
            EmptyView()
          }
        }
      }
  }

  private var grid: some View {
    MetricTileGrid {
      ForEach(items) { item in
        switch item.destination {
        case let .details(detail):
          NavigationLink { NodeReadingPage(item: item, detail: detail) } label: { card(item) }
            .buttonStyle(.plain)
            .disabled(item.isPending)
            .accessibilityIdentifier("node.card.\(item.id)")
        case .controls:
          Button { presentedID = item.id } label: { card(item) }
            .buttonStyle(.plain)
            .disabled(item.isPending)
            .accessibilityIdentifier("node.card.\(item.id)")
        case let .action(action):
          Button(action: action) { card(item) }
            .buttonStyle(.plain)
            .disabled(item.isPending)
            .accessibilityIdentifier("node.card.\(item.id)")
        case let .route(route):
          NavigationLink(value: route) { card(item) }
            .buttonStyle(.plain)
            .disabled(item.isPending)
            .accessibilityIdentifier("node.card.\(item.id)")
        case let .history(target):
          NavigationLink { TelemetryHistoryOverviewView(target, title: item.title) } label: { card(item) }
            .buttonStyle(.plain)
            .disabled(item.isPending)
            .accessibilityIdentifier("node.card.\(item.id)")
        case let .page(page):
          NavigationLink { page } label: { card(item) }
            .buttonStyle(.plain)
            .disabled(item.isPending)
            .accessibilityIdentifier("node.card.\(item.id)")
        case .none:
          card(item)
            .accessibilityIdentifier("node.card.\(item.id)")
        }
      }
    }
  }

  // MARK: - Settings rows

  /// The items as one group of Settings rows, beside (not inside) the section around the grid.
  private var settingsRows: some View {
    CardFormSection {
      ForEach(items) { item in
        settingsRow(item)
          .disabled(item.isPending)
          .accessibilityIdentifier("node.card.\(item.id)")
      }
    }
    .settingsStandalone()
  }

  @ViewBuilder
  private func settingsRow(_ item: NodeDashboardCardItem) -> some View {
    switch item.destination {
    case let .details(detail):
      NavigationLink { NodeReadingPage(item: item, detail: detail) } label: { rowLabel(item) }
        .buttonStyle(.plain)
    case let .controls(content):
      NavigationLink {
        CardForm { content }
          .flashingNavigationTitle(item.title)
          .navigationBarTitleDisplayMode(.inline)
          // Pushed pages in the iPad split view's column don't inherit it from the stack.
          .environment(\.isInSettings, true)
      } label: {
        rowLabel(item)
      }
      .buttonStyle(.plain)
    case let .action(action):
      Button(action: action) { rowLabel(item) }
        .buttonStyle(.plain)
    case let .route(route):
      NavigationLink(value: route) { rowLabel(item) }
        .buttonStyle(.plain)
    case let .history(target):
      NavigationLink { TelemetryHistoryOverviewView(target, title: item.title) } label: { rowLabel(item) }
        .buttonStyle(.plain)
    case let .page(page):
      NavigationLink { page } label: { rowLabel(item) }
        .buttonStyle(.plain)
    case .none:
      rowLabel(item)
    }
  }

  private func rowLabel(_ item: NodeDashboardCardItem) -> some View {
    let context = ([item.note].compactMap(\.self) + item.details).joined(separator: " · ")
    return HStack(spacing: 12) {
      IconTile(systemImage: item.systemImage, color: item.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.body)
          .foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        if !context.isEmpty {
          Text(context)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if item.isPending {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
      }
      if !item.value.isEmpty {
        Text(item.value)
          .foregroundStyle(item.valueTint == .primary ? Color.secondary : item.valueTint)
          .lineLimit(1)
      }
      if !item.isReadOnly {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }
    }
    .opacity(item.isPending ? 0.45 : 1)
    .cardSurface(padding: 12)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(item.isReadOnly ? [] : .isButton)
    .animation(.easeOut(duration: 0.2), value: item.isPending)
  }

  // MARK: - Cards

  private func card(_ item: NodeDashboardCardItem) -> some View {
    HomeCard(
      title: item.title,
      systemImage: item.systemImage,
      tint: item.tint,
      accessibilityValue: ([item.value, item.note].compactMap(\.self) + item.details).joined(separator: ", "),
      hint: "",
      opensPage: !item.isReadOnly
    ) {
      HomeCardValue(
        value: item.value,
        valueTint: item.valueTint,
        note: item.note,
        noteTint: item.noteTint,
        shrinksFraction: item.shrinksFraction
      )
      if let trend = item.trend, trend.contains(where: { $0.dataPoints.count >= 2 }) {
        MetricSparkline(series: trend)
          .frame(height: 34)
          .padding(.vertical, 2)
      }
      // By position: two lines can read the same (a sensor reporting a value twice).
      ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
        HomeCardDetail(detail)
      }
    }
    .opacity(item.isPending ? 0.45 : 1)
    .overlay(alignment: .topTrailing) {
      if item.isPending {
        ProgressView()
          .controlSize(.mini)
          .padding(10)
          .accessibilityHidden(true)
      }
    }
    .animation(.easeOut(duration: 0.2), value: item.isPending)
  }
}

/// A reading card opened, for a reading with nothing to chart (Last Heard) or a node with no saved
/// history: its figure large on a card, every fact behind it on a card of its own, label over
/// value so a long one (a path) wraps, and what the figures mean. Pushed, in the pages' card style
/// (the user, 2026-11-08), where it was a List in a sheet.
struct NodeReadingPage: View {
  let item: NodeDashboardCardItem
  let detail: NodeReadingDetail

  var body: some View {
    CardForm {
      NodeCardSheetHeader(item: item)
        .cardSurface(padding: 14)

      if !detail.facts.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(detail.facts.enumerated()), id: \.element.id) { index, fact in
            if index > 0 {
              Divider()
            }
            FactRow(fact: fact)
              .padding(.vertical, 10)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .cardSurface(padding: 0)
      }

      if let footnote = detail.footnote {
        Text(footnote)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }

      if let history = detail.history {
        NavigationLink {
          TelemetryHistoryOverviewView(history, title: item.title)
        } label: {
          NavigationTile(L10n.Contacts.Contacts.Detail.savedHistory, systemImage: "chart.xyaxis.line", color: item.tint)
        }
        .buttonStyle(.plain)
      }
    }
    .flashingNavigationTitle(item.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  /// One fact: its label as a caption, the value under it at reading size in full colour, so a
  /// long value (a path) wraps instead of squeezing beside its label.
  private struct FactRow: View {
    let fact: NodeReadingDetail.Fact

    var body: some View {
      VStack(alignment: .leading, spacing: 3) {
        Text(fact.title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if !fact.value.isEmpty {
          Text(fact.value)
            .font(.body.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(fact.tint ?? .primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    }
  }
}

/// A card's sheet header: its glyph on a tile of its colour, beside its figure at title size and
/// the note under it. Shared by the reading page and the controls sheet.
struct NodeCardSheetHeader: View {
  let item: NodeDashboardCardItem

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: item.systemImage)
        .font(.title2.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.value)
          .font(.largeTitle.weight(.bold))
          .fontDesign(.rounded)
          .monospacedDigit()
          .foregroundStyle(item.valueTint)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        if let note = item.note {
          Text(note)
            .font(.headline)
            .foregroundStyle(item.noteTint == .secondary ? Color.primary.opacity(0.75) : item.noteTint)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A settings card opened: its figure on top and the controls behind it, at half height so the
/// page it came from stays in view. In a stack of its own, so a control can push a list (the
/// trusted contacts) inside the sheet.
struct NodeControlsSheet: View {
  let item: NodeDashboardCardItem
  let content: AnyView
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      CardForm {
        NodeCardSheetHeader(item: item)
          .padding(.horizontal, 4)
        content
      }
      .flashingNavigationTitle(item.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

@MainActor
extension NodeDashboardCardItem {
  /// The status readings both kinds of node report, from their latest status reply.
  /// Battery with the node's sensors folded in: the charge, its voltage, the temperature, and how
  /// many other readings the sensors page holds. Until the sensors are read this visit (their page
  /// reads them), `cached` gives the last visit's temperature and count.
  static func battery(
    _ helper: NodeStatusViewModel,
    cached: NodeCardCache.Entry? = nil,
    trend: [MetricChartView.DataPoint] = [],
    open: @escaping () -> Void
  ) -> Self {
    let level = helper.batteryLevel
    let warns = level.map { $0 != .good } ?? false
    let sensors = sensorSummary(helper)
    let temperature = sensors.map(\.temperature) ?? cached?.temperature
    let others = sensors.map(\.others) ?? cached?.otherSensorCount ?? 0
    var details: [String] = []
    if helper.status != nil {
      details.append(NodeRouteFormat.joined([helper.batteryVoltageDisplay, temperature]))
      // the uptime rides here (the user, 2026-11-09: a card of its own for one figure)
      details.append("\(L10n.RemoteNodes.RemoteNodes.Status.uptime) \(helper.uptimeDisplay)")
    } else if let temperature {
      details.append(temperature)
    }
    if others > 0 { details.append(L10n.RemoteNodes.RemoteNodes.Status.Tile.sensorCount(others)) }
    // The sensor line from the last visit says so until this one reads it.
    if sensors == nil, cached?.temperature != nil || (cached?.otherSensorCount ?? 0) > 0 {
      details.append(L10n.RemoteNodes.RemoteNodes.Status.fromLastVisit)
    }
    return NodeDashboardCardItem(
      id: "battery",
      title: L10n.RemoteNodes.RemoteNodes.Status.battery,
      systemImage: BatteryLevel.symbol(for: helper.batteryPercent),
      tint: level?.tint ?? .green,
      value: helper.status == nil ? NodeStatusViewModel.emDash : BatteryLevel.formattedPercent(helper.batteryPercent),
      // The charge in its level's colour: green, orange when low, red when critical.
      valueTint: level?.tint ?? .secondary,
      note: level?.title,
      noteTint: warns ? (level?.tint ?? .secondary) : .secondary,
      details: details,
      destination: .action(open),
      trend: NodeBatteryTrend.series(trend, tint: level?.tint ?? .green)
    )
  }

  /// The Battery card's sensor line from this visit's telemetry: the temperature as shown and how
  /// many other readings there are (coordinates and the battery voltage left out). Nil until read.
  static func sensorSummary(_ helper: NodeStatusViewModel) -> (temperature: String?, others: Int)? {
    guard helper.telemetryLoaded else { return nil }
    let readings = helper.cachedDataPoints.filter { !$0.isCoordinate && $0.type != .voltage }
    let temperature = readings.first { $0.type == .temperature }
    return (temperature?.formattedValue, readings.count - (temperature == nil ? 0 : 1))
  }

  /// The node's own last SNR and RSSI and its noise floor, from the status reply; and, for a node
  /// this radio heard directly, how well each side hears the other (``NodeLinkSignal``), as Scan &
  /// Traffic lists it.
  static func signal(_ helper: NodeStatusViewModel, history: NodeStatusRoute?, link: NodeLinkSignal? = nil) -> Self {
    let statusFacts: [NodeReadingDetail.Fact] = helper.status == nil ? [] : [
      .init(title: L10n.RemoteNodes.RemoteNodes.Status.lastSnr, value: helper.lastSNRDisplay),
      .init(title: L10n.RemoteNodes.RemoteNodes.Status.lastRssi, value: helper.lastRSSIDisplay),
      .init(title: L10n.RemoteNodes.RemoteNodes.Status.noiseFloor, value: helper.noiseFloorDisplay),
    ]
    let facts = statusFacts + (link?.facts(now: .now) ?? [])
    let statusDetails = helper.status == nil ? [] : [
      "\(L10n.RemoteNodes.RemoteNodes.Status.lastRssi) \(helper.lastRSSIDisplay)",
      "\(L10n.RemoteNodes.RemoteNodes.Status.noiseFloor) \(helper.noiseFloorDisplay)",
    ]
    return NodeDashboardCardItem(
      id: "signal",
      title: L10n.RemoteNodes.RemoteNodes.Status.signal,
      systemImage: "cellularbars",
      tint: .blue,
      value: helper.lastSNRDisplay,
      // The SNR in its quality's colour: green, orange when fair, red when poor.
      valueTint: helper.status.map { SNRQuality(snr: Double($0.lastSNR)).textColor } ?? .secondary,
      details: (link?.detailLines ?? []) + statusDetails,
      destination: .history(
        NodeHistoryTarget(history),
        scope: .signal,
        orFacts: facts,
        footnote: L10n.RemoteNodes.RemoteNodes.Status.signalInfo
      )
    )
  }

  static func packets(_ helper: NodeStatusViewModel, history: NodeStatusRoute?) -> Self {
    NodeDashboardCardItem(
      id: "packets",
      title: L10n.RemoteNodes.RemoteNodes.Status.packets,
      systemImage: "arrow.up.arrow.down",
      tint: .purple,
      value: "↓ \(helper.packetsReceivedDisplay)",
      note: "↑ \(helper.packetsSentDisplay)",
      details: helper.status == nil ? [] : [
        "\(L10n.RemoteNodes.RemoteNodes.Status.airtime) \(helper.txAirtimeDisplay)",
      ] + (helper.channelUseDisplay.map { ["\(L10n.RemoteNodes.RemoteNodes.Status.channelUse) \($0)"] } ?? []),
      destination: {
        let detail = packetsDetail(helper)
        return .history(NodeHistoryTarget(history), scope: .packets, orFacts: detail.facts, footnote: detail.footnote)
      }()
    )
  }

  /// Every count the status reply carries, split by route, then the airtime each way.
  private static func packetsDetail(_ helper: NodeStatusViewModel) -> NodeReadingDetail {
    let status = L10n.RemoteNodes.RemoteNodes.Status.self
    let facts: [NodeReadingDetail.Fact] = helper.status == nil ? [] : [
      .init(title: status.packetsReceived, value: helper.packetsReceivedDisplay),
      .init(title: status.receivedDirect, value: helper.receivedDirectDisplay),
      .init(title: status.receivedFlood, value: helper.receivedFloodDisplay),
      .init(title: status.packetsSent, value: helper.packetsSentDisplay),
      .init(title: status.sentDirect, value: helper.sentDirectDisplay),
      .init(title: status.sentFlood, value: helper.sentFloodDisplay),
      .init(title: status.txAirtime, value: NodeRouteFormat.joined([helper.txAirtimeDisplay, helper.txAirtimePercentDisplay])),
      .init(title: status.rxAirtime, value: NodeRouteFormat.joined([helper.rxAirtimeDisplay, helper.rxAirtimePercentDisplay])),
    ] + (helper.channelUseDisplay.map { [.init(title: status.channelUse, value: $0)] } ?? [])
    return .init(facts: facts, footnote: status.airtimeInfo, history: nil)
  }

  /// Packets the node heard twice and dropped, with the direct/flood split, receive errors and
  /// the transmit queue: the mesh health figures the other cards don't carry. Opens its figures in
  /// full, as Signal and Packets do.
  static func duplicates(
    _ helper: NodeStatusViewModel,
    receiveErrors: String?,
    showsTxQueue: Bool,
    history: NodeStatusRoute?
  ) -> Self {
    var details: [String] = []
    if helper.status != nil {
      details.append(L10n.RemoteNodes.RemoteNodes.Status.directFlood(
        helper.directDuplicatesDisplay, helper.floodDuplicatesDisplay
      ))
      if let receiveErrors {
        details.append("\(L10n.RemoteNodes.RemoteNodes.Status.receiveErrors) \(receiveErrors)")
      }
      if showsTxQueue {
        details.append(L10n.RemoteNodes.RemoteNodes.Status.txQueue(helper.txQueueDisplay))
      }
    }
    return NodeDashboardCardItem(
      id: "duplicates",
      title: L10n.RemoteNodes.RemoteNodes.Status.duplicates,
      systemImage: "square.on.square",
      tint: .teal,
      value: helper.duplicatesDisplay,
      valueTint: helper.status == nil ? .secondary : .primary,
      note: showsTxQueue && helper.isTxQueueBacklogged ? L10n.Tools.Tools.Spectrum.warning : nil,
      noteTint: .orange,
      details: details,
      destination: .history(
        NodeHistoryTarget(history),
        scope: .duplicates,
        orFacts: helper.status == nil ? [] : [
          .init(title: L10n.RemoteNodes.RemoteNodes.Status.total, value: helper.duplicatesDisplay),
          .init(title: L10n.Contacts.Contacts.Route.direct, value: helper.directDuplicatesDisplay),
          .init(title: L10n.Contacts.Contacts.Route.flood, value: helper.floodDuplicatesDisplay),
        ] + (receiveErrors.map { [.init(title: L10n.RemoteNodes.RemoteNodes.Status.receiveErrors, value: $0)] } ?? [])
          // "TX queue 3" reads as its own label; a backlog says so beside it.
          + (showsTxQueue ? [.init(
            title: L10n.RemoteNodes.RemoteNodes.Status.txQueue(helper.txQueueDisplay),
            value: helper.isTxQueueBacklogged ? L10n.Tools.Tools.Spectrum.warning : "",
            tint: .orange
          )] : [])
      )
    )
  }

  /// The sensor readings: temperature first, then voltage, as Cairn's Sensors card.
  static func sensors(_ helper: NodeStatusViewModel, open: @escaping () -> Void) -> Self {
    let readings = helper.cachedDataPoints.filter { !$0.isCoordinate }
    let temperature = readings.first { $0.type == .temperature }?.formattedValue
    let voltage = readings.first { $0.type == .voltage }?.formattedValue
    let value = temperature ?? voltage ?? readings.first?.formattedValue
    var details: [String] = []
    if temperature != nil, let voltage { details.append(voltage) }
    if readings.count > 2 { details.append(L10n.RemoteNodes.RemoteNodes.Status.Tile.sensorCount(readings.count)) }
    return NodeDashboardCardItem(
      id: "sensors",
      title: NodeSectionPage.telemetry.title,
      systemImage: NodeSectionPage.telemetry.systemImage,
      tint: NodeSectionPage.telemetry.color,
      value: value ?? (helper.isLoadingTelemetry ? L10n.RemoteNodes.RemoteNodes.Settings.loading : NodeStatusViewModel.emDash),
      valueTint: value == nil ? .secondary : .primary,
      details: details,
      destination: .action(open)
    )
  }
}

@MainActor
extension NodeSettingsViewModel {
  /// The admin Dashboard's Radio card: the frequency, then SF · bandwidth · coding rate. Until the node
  /// answers (its sheet reads it), `cached` (the last visit's values, `NodeCardCache`) shows in grey
  /// instead of nothing; the card waits, dimmed, only while a read is on its way.
  func radioCard(cached: NodeCardCache.Entry? = nil, open: @escaping () -> Void) -> NodeDashboardCardItem {
    let fresh = frequency != nil
    let freq = frequency ?? cached?.frequency
    let sf = fresh ? spreadingFactor : cached?.spreadingFactor
    let bw = fresh ? bandwidth : cached?.bandwidth
    let cr = fresh ? codingRate : cached?.codingRate
    let tx = originalTxPower ?? (fresh ? nil : cached?.txPower)
    return NodeDashboardCardItem(
      id: "radio",
      title: L10n.Settings.Radio.header,
      systemImage: "waveform",
      tint: .orange,
      value: freq.map { "\($0.formatted(.number.precision(.fractionLength(3)))) MHz" }
        ?? (isLoadingRadio ? L10n.RemoteNodes.RemoteNodes.Settings.loading : NodeStatusViewModel.emDash),
      valueTint: fresh ? .primary : .secondary,
      details: [
        NodeRouteFormat.joined([
          sf.map { "SF\($0)" },
          bw.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kHz" },
          cr.map { "CR\($0)" },
        ]),
        // The applied value: an edit not yet applied stays in its sheet. The power at the antenna
        // leads when the node reports it (`txa=`), else the value is labelled the radio setting.
        tx.map { TxPowerText.remoteDetail(setting: $0, antenna: $0 == originalTxPower ? txAntennaPower : nil) } ?? "",
        // Cached values are the last visit's, and say so.
        !fresh && freq != nil ? L10n.RemoteNodes.RemoteNodes.Status.fromLastVisit : "",
      ].filter { !$0.isEmpty },
      destination: .action(open),
      shrinksFraction: freq != nil,
      isPending: !fresh && isLoadingRadio
    )
  }

  /// The admin Dashboard's Clock card: the node's time now (the phone's clock plus the drift read
  /// at login) and how far it is from this phone; a tap sets it from the phone (`syncTime`). Before
  /// a read it says so; the login's automatic step reads it, and sets it when it is off by more
  /// than `automaticSyncTolerance`.
  func clockCard(now: Date = .now, onSync: @escaping () -> Void) -> NodeDashboardCardItem {
    let strings = L10n.Settings.Clock.self
    let nodeTime = clockDrift.map { now.addingTimeInterval($0) }
    let drift: String? = clockDrift.map { drift in
      if abs(drift) <= Self.automaticSyncTolerance { return strings.Drift.inSync }
      let amount = Duration.seconds(abs(drift).rounded())
        .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
      return drift > 0 ? strings.Drift.ahead(amount) : strings.Drift.behind(amount)
    }
    return NodeDashboardCardItem(
      id: "clock",
      title: strings.header,
      systemImage: "clock",
      tint: .teal,
      value: nodeTime.map { $0.formatted(date: .omitted, time: .shortened) }
        ?? (isLoadingDeviceInfo ? L10n.RemoteNodes.RemoteNodes.Settings.loading : NodeStatusViewModel.emDash),
      valueTint: nodeTime == nil ? .secondary : .primary,
      note: isApplying ? strings.setting : strings.tapToSync,
      details: [
        nodeTime.map { $0.formatted(date: .abbreviated, time: .omitted) },
        drift,
      ].compactMap(\.self),
      destination: .action(onSync),
      isPending: isApplying
    )
  }

  /// The admin Dashboard's Device card: firmware, how long it's been up, and its clock (once its sheet
  /// has read it). With the latest release's build known (`latestBuild`, from `LatestFirmwareBuildCache`)
  /// a Cairn build behind it says "Update available"; an ESP32 board adds that the update goes
  /// through the web flasher rather than over Bluetooth.
  func deviceCard(
    uptime: String,
    cached: NodeCardCache.Entry? = nil,
    latestBuild: Int? = nil,
    showsVersion: Bool = true,
    showsUptime: Bool = true,
    open: @escaping () -> Void
  ) -> NodeDashboardCardItem {
    let version = firmwareVersion ?? cached?.firmwareVersion
    let updateAvailable = FirmwareUpdateCheck.updateAvailable(installed: version, latestBuild: latestBuild) == true
    // Without the version (a repeater's header shows it, and its clock), the card leads with the uptime.
    var details = showsVersion ? [
      showsUptime ? "\(L10n.RemoteNodes.RemoteNodes.Status.uptime) \(uptime)" : nil,
      deviceTime.map { "\(L10n.RemoteNodes.RemoteNodes.Settings.deviceTime) \($0)" },
    ].compactMap(\.self) : []
    if updateAvailable, isESP32CairnBoard {
      details.append(L10n.RemoteNodes.RemoteNodes.Settings.updateViaWebFlasher)
    }
    if showsVersion, firmwareVersion == nil, cached?.firmwareVersion != nil {
      details.append(L10n.RemoteNodes.RemoteNodes.Status.fromLastVisit)
    }
    return NodeDashboardCardItem(
      id: "device",
      title: L10n.RemoteNodes.RemoteNodes.Settings.deviceInfo,
      systemImage: "cpu",
      tint: .gray,
      value: showsVersion
        ? version ?? (isLoadingDeviceInfo ? L10n.RemoteNodes.RemoteNodes.Settings.loading : NodeStatusViewModel.emDash)
        : uptime,
      valueTint: showsVersion && firmwareVersion == nil ? .secondary : .primary,
      // without the version, "Uptime" beside the figure says what it is
      note: updateAvailable ? L10n.RemoteNodes.RemoteNodes.Settings.updateAvailable
        : (showsVersion ? nil : L10n.RemoteNodes.RemoteNodes.Status.uptime),
      noteTint: updateAvailable ? .orange : .secondary,
      details: details,
      destination: .action(open),
      isPending: !deviceInfoLoaded && isLoadingDeviceInfo
    )
  }
}

/// A node's battery over the last week, from its stored status snapshots, for the Battery card's trend
/// line (the user, 2026-11-09: every Battery card drawn as Home's is). A repeater's history grows with
/// each visit, so a week rather than Home's day.
enum NodeBatteryTrend {
  static let window: TimeInterval = 7 * 24 * 60 * 60

  /// The battery readings (volts) in the window, oldest first; none at 0 mV (no battery to measure).
  static func points(from snapshots: [NodeStatusSnapshotDTO], now: Date = .now) -> [MetricChartView.DataPoint] {
    snapshots
      .filter { now.timeIntervalSince($0.timestamp) <= window }
      .compactMap { s in
        s.batteryMillivolts.flatMap { $0 > 0 ? MetricChartView.DataPoint(id: s.id, date: s.timestamp, value: Double($0) / 1000) : nil }
      }
  }

  static func series(_ points: [MetricChartView.DataPoint], tint: Color) -> [MetricChartView.Series]? {
    points.count >= 2 ? [.init(name: L10n.RemoteNodes.RemoteNodes.Status.battery, color: tint, dataPoints: points)] : nil
  }

  /// Reads the node's snapshots and returns its trend points.
  @MainActor
  static func load(publicKey: Data, appState: AppState) async -> [MetricChartView.DataPoint] {
    guard let service = appState.services?.nodeSnapshotService else { return [] }
    let since = Date.now.addingTimeInterval(-window)
    return points(from: await service.fetchSnapshots(for: publicKey, since: since))
  }
}
