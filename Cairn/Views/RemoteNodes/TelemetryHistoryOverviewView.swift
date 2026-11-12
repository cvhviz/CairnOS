import CairnServices
import SwiftUI

/// Which of a node's stored readings a history page charts. A reading card opens the page scoped
/// to what it shows, its charts one tap from the full graph (the user, 2026-11-08); `.all` is the
/// whole history, with location and neighbours.
enum HistoryScope: Hashable {
  case all
  /// The battery charge and the node's sensors (voltage, temperature and the rest).
  case battery
  /// SNR, RSSI and the noise floor.
  case signal
  /// Packets sent and received (and a room's posts).
  case packets
  /// Duplicates and receive errors.
  case duplicates
  /// The node's sensors, every channel.
  case sensors
  /// How long the node had been running at each reading: a drop is a restart.
  case uptime

  /// The radio metrics (`HistoryMetric.radio`) this scope charts; nil for all of them.
  fileprivate var radioIDs: Set<String>? {
    switch self {
    case .all: nil
    case .battery: ["battery"]
    case .signal: ["snr", "rssi", "noise"]
    case .uptime: ["uptime"]
    case .packets, .duplicates, .sensors: []
    }
  }

  /// The packet metrics (`HistoryMetric.packets`) this scope charts; nil for all of them.
  fileprivate var packetIDs: Set<String>? {
    switch self {
    case .all: nil
    case .packets: ["sent", "received", "posted", "pushed"]
    case .duplicates: ["duplicates", "errors"]
    case .battery, .signal, .sensors, .uptime: []
    }
  }

  fileprivate var showsSensors: Bool {
    switch self {
    case .all, .battery, .sensors: true
    case .signal, .packets, .duplicates, .uptime: false
    }
  }
}

/// A node's history page, offline-accessible: radio and packet charts, sensor charts, location
/// reports and neighbour SNR from stored snapshots, or the part of them a reading card opened it
/// on (`scope`). Contact Detail, the repeater and room status pages, a contact's telemetry sheet
/// and Network Health all open this page.
struct TelemetryHistoryOverviewView: View {
  let publicKey: Data
  let radioID: UUID
  let showNeighbors: Bool
  /// The page title; callers that reach this page from a list of nodes pass the node's name so the
  /// page says whose history it is. Defaults to the generic history title.
  let title: String?
  /// Which readings the page charts.
  let scope: HistoryScope
  /// What the page carries over its charts (the radio's Battery page's charge and readings).
  let header: AnyView?
  /// What the page carries under its charts (the Battery page's battery curve setting).
  let accessory: AnyView?
  /// Reloads the stored snapshots when it changes: a host that reads the node while the page is
  /// up (the Battery page's sensors) passes its count of snapshots saved.
  let refreshID: Int

  @Environment(\.appState) private var appState
  @State private var viewModel = TelemetryHistoryOverviewViewModel()
  /// Shows a spinner rather than the empty state while the snapshots load.
  @State private var isLoading = true
  /// The metric whose full chart is open, by id: the sheet reads it from the page's metrics on
  /// every pass, so a range picked inside it redraws the chart.
  @State private var openMetricID: String?
  @State private var showsLocationMap = false
  @State private var selectedReportID: UUID?

  init(
    publicKey: Data,
    radioID: UUID,
    showNeighbors: Bool = true,
    title: String? = nil,
    scope: HistoryScope = .all,
    header: AnyView? = nil,
    accessory: AnyView? = nil,
    refreshID: Int = 0
  ) {
    self.title = title
    self.publicKey = publicKey
    self.radioID = radioID
    self.showNeighbors = showNeighbors
    self.scope = scope
    self.header = header
    self.accessory = accessory
    self.refreshID = refreshID
  }

  /// A reading card's target: its node, scoped to the reading, titled with the card's name.
  init(_ target: NodeHistoryTarget, title: String? = nil, accessory: AnyView? = nil, refreshID: Int = 0) {
    self.init(
      publicKey: target.publicKey,
      radioID: target.radioID,
      showNeighbors: target.showNeighbors,
      title: title,
      scope: target.scope,
      accessory: accessory,
      refreshID: refreshID
    )
  }

  var body: some View {
    let filtered = viewModel.filteredSnapshots
    CardForm {
      if let header {
        header
      }
      if isLoading {
        ProgressView()
          .emptyStateFrame(below: accessory == nil && header == nil ? CardStyle.formVerticalInset * 2 : 240)
      } else if !viewModel.hasSnapshots {
        if accessory == nil && header == nil {
          emptyState
        } else {
          // Kept short, so the setting under it stays in view.
          emptyState.frame(minHeight: 240)
        }
      } else {
        HistoryTimeRangePicker(selection: $viewModel.timeRange)
        let sections = metricSections(filtered: filtered)
        ForEach(sections) { section in
          CardFormSection(section.title) {
            HistoryMetricGrid(metrics: section.metrics, selection: $openMetricID)
          }
        }
        if scope == .all || scope == .sensors, !viewModel.hasTelemetryData(in: filtered) {
          notCaptured(L10n.RemoteNodes.RemoteNodes.History.sensorsSection)
        } else if sections.isEmpty, let title {
          notCaptured(title)
        }
        if scope == .all {
          LocationHistorySection(
            snapshots: filtered,
            showsFullPath: true,
            showsMap: $showsLocationMap,
            pendingMapSelection: $selectedReportID
          )
          if showNeighbors {
            neighborsSection(filtered: filtered)
          }
        }
        retentionFooter
      }
      if let accessory {
        accessory
      }
    }
    .sheet(isPresented: Binding(get: { openMetricID != nil }, set: { if !$0 { openMetricID = nil } })) {
      if let metric = allMetrics(filtered: filtered).first(where: { $0.id == openMetricID }) {
        HistoryMetricSheet(metric: metric, timeRange: $viewModel.timeRange)
      } else {
        // The range picked in the sheet holds none of this reading.
        HistoryMetricSheet(
          metric: emptyMetric(id: openMetricID),
          timeRange: $viewModel.timeRange
        )
      }
    }
    .flashingNavigationTitle(title ?? L10n.RemoteNodes.RemoteNodes.History.overviewTitle)
    .navigationBarTitleDisplayMode(.inline)
    .liquidGlassToolbarBackground()
    .locationMapDestination(
      isPresented: $showsLocationMap,
      snapshots: filtered,
      initialSelection: selectedReportID
    )
    .task(id: refreshID) {
      defer { isLoading = false }
      guard let store = appState.offlineDataStore else { return }
      await viewModel.loadData(
        dataStore: store, publicKey: publicKey, radioID: radioID
      )
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    ContentUnavailableView(
      L10n.RemoteNodes.RemoteNodes.History.overviewTitle,
      systemImage: "chart.line.uptrend.xyaxis",
      description: Text(L10n.RemoteNodes.RemoteNodes.History.noSnapshotsMessage)
    )
    .emptyStateFrame(below: CardStyle.formVerticalInset * 2)
  }

  // MARK: - Metric Sections

  /// The page's cards in groups: Radio, Packets, then Sensors (one group per channel when the
  /// node reports several).
  private func metricSections(filtered: [NodeStatusSnapshotDTO]) -> [HistoryMetricSection] {
    var sections: [HistoryMetricSection] = []
    let radio = HistoryMetric.radio(from: filtered, ocvArray: viewModel.ocvArray)
      .filter { scope.radioIDs?.contains($0.id) ?? true }
    if !radio.isEmpty {
      sections.append(.init(id: "radio", title: scope == .all ? L10n.RemoteNodes.RemoteNodes.History.radioSection : (title ?? L10n.RemoteNodes.RemoteNodes.History.radioSection), metrics: radio))
    }
    let packets = HistoryMetric.packets(from: filtered)
      .filter { scope.packetIDs?.contains($0.id) ?? true }
    if !packets.isEmpty {
      sections.append(.init(id: "packets", title: scope == .all ? L10n.RemoteNodes.RemoteNodes.History.packets : (title ?? L10n.RemoteNodes.RemoteNodes.History.packets), metrics: packets))
    }
    guard scope.showsSensors else { return sections }
    let groups = ChannelGroup.groups(from: filtered)
    for group in groups {
      let title = groups.count > 1
        ? NodeRouteFormat.joined([
          L10n.RemoteNodes.RemoteNodes.History.sensorsSection,
          L10n.RemoteNodes.RemoteNodes.Status.channel(group.channel),
        ])
        : L10n.RemoteNodes.RemoteNodes.History.sensorsSection
      sections.append(.init(id: "sensors-\(group.channel)", title: title, metrics: HistoryMetric.sensors(in: group)))
    }
    return sections
  }

  /// Every metric on the page, the neighbours' included, for the open chart's lookup.
  private func allMetrics(filtered: [NodeStatusSnapshotDTO]) -> [HistoryMetric] {
    metricSections(filtered: filtered).flatMap(\.metrics)
      + (showNeighbors ? neighborMetrics(from: filtered) : [])
  }

  /// The open metric with nothing in the picked range, named from the whole history, so its
  /// sheet stays open and says there's nothing to chart.
  private func emptyMetric(id: String?) -> HistoryMetric {
    let named = allMetrics(filtered: viewModel.snapshots).first { $0.id == id }
    return HistoryMetric(
      id: id ?? "",
      title: named?.title ?? L10n.RemoteNodes.RemoteNodes.History.overviewTitle,
      systemImage: named?.systemImage ?? "chart.xyaxis.line",
      tint: named?.tint ?? .secondary,
      unit: named?.unit ?? "",
      series: []
    )
  }

  // MARK: - Neighbors Section

  @ViewBuilder
  private func neighborsSection(filtered: [NodeStatusSnapshotDTO]) -> some View {
    if viewModel.hasNeighborData(in: filtered) {
      CardFormSection(L10n.RemoteNodes.RemoteNodes.History.neighborsSection) {
        HistoryMetricGrid(metrics: neighborMetrics(from: filtered), selection: $openMetricID)
      }
    } else if viewModel.hasSnapshots {
      notCaptured(L10n.RemoteNodes.RemoteNodes.History.neighborsSection)
    }
  }

  private func neighborMetrics(from filtered: [NodeStatusSnapshotDTO]) -> [HistoryMetric] {
    buildNeighborCharts(from: filtered).map { neighbor in
      HistoryMetric(
        id: "neighbor-\(neighbor.prefix.map { String(format: "%02X", $0) }.joined())",
        title: neighbor.name,
        systemImage: "point.3.connected.trianglepath.dotted",
        tint: .orange,
        unit: "dB",
        dataPoints: neighbor.dataPoints
      )
    }
  }

  /// A group the stored snapshots never captured, said on its own card.
  private func notCaptured(_ section: String) -> some View {
    Text(L10n.RemoteNodes.RemoteNodes.History.sectionNotCaptured(section))
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)
  }

  // MARK: - Helpers

  private func buildNeighborCharts(from filtered: [NodeStatusSnapshotDTO]) -> [NeighborChart] {
    var charts: [Data: NeighborChart] = [:]
    for snapshot in filtered {
      for neighbor in snapshot.neighborSnapshots ?? [] {
        let point = MetricChartView.DataPoint(
          id: snapshot.id, date: snapshot.timestamp, value: neighbor.snr
        )
        if charts[neighbor.publicKeyPrefix] != nil {
          charts[neighbor.publicKeyPrefix]!.dataPoints.append(point)
        } else {
          let hexName = neighbor.publicKeyPrefix
            .map { String(format: "%02X", $0) }.joined()
          let resolvedName = viewModel.resolveNeighborName(prefix: neighbor.publicKeyPrefix) ?? hexName
          charts[neighbor.publicKeyPrefix] = NeighborChart(
            prefix: neighbor.publicKeyPrefix,
            name: resolvedName,
            dataPoints: [point]
          )
        }
      }
    }
    return charts.values.sorted { $0.name < $1.name }
  }

  private var retentionFooter: some View {
    Text(L10n.RemoteNodes.RemoteNodes.History.retentionNotice)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 4)
  }
}

// MARK: - Private Types

private struct NeighborChart {
  let prefix: Data
  let name: String
  var dataPoints: [MetricChartView.DataPoint]
}

/// A titled run of metric cards on the history page.
private struct HistoryMetricSection: Identifiable {
  let id: String
  let title: String
  let metrics: [HistoryMetric]
}
