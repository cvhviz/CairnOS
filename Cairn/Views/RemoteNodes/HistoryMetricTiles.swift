import Charts
import CairnServices
import SwiftUI

/// One charted reading on the history page: what it is, its series, and how its values read.
/// The page shows each as a small card (latest value, a trend line, its range); a tap opens the
/// full chart with its lowest, average and highest values.
struct HistoryMetric: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let tint: Color
  let unit: String
  /// In date order; a Direct/Flood packet chart carries two.
  let series: [MetricChartView.Series]
  /// The full chart's Y range (the battery's charge curve), nil for the data's own.
  var yAxisDomain: ClosedRange<Double>?

  init(
    id: String,
    title: String,
    systemImage: String,
    tint: Color,
    unit: String,
    series: [MetricChartView.Series],
    yAxisDomain: ClosedRange<Double>? = nil
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.unit = unit
    self.series = series.filter { !$0.dataPoints.isEmpty }
    self.yAxisDomain = yAxisDomain
  }

  /// A single-series metric, coloured by its tint.
  init(
    id: String,
    title: String,
    systemImage: String,
    tint: Color,
    unit: String,
    dataPoints: [MetricChartView.DataPoint],
    yAxisDomain: ClosedRange<Double>? = nil
  ) {
    self.init(
      id: id, title: title, systemImage: systemImage, tint: tint, unit: unit,
      series: [.init(name: title, color: tint, dataPoints: dataPoints)],
      yAxisDomain: yAxisDomain
    )
  }

  var isEmpty: Bool {
    series.isEmpty
  }

  var isMultiSeries: Bool {
    series.count > 1
  }

  /// The newest reading: summed across series, so Sent reads Direct plus Flood.
  var latestValue: Double? {
    let values = series.compactMap { $0.dataPoints.last?.value }
    return values.isEmpty ? nil : values.reduce(0, +)
  }

  var latestDate: Date? {
    series.compactMap { $0.dataPoints.last?.date }.max()
  }

  var firstDate: Date? {
    series.compactMap { $0.dataPoints.first?.date }.min()
  }

  var readingCount: Int {
    series.map(\.dataPoints.count).max() ?? 0
  }

  var canDrawTrend: Bool {
    series.contains { $0.dataPoints.count >= 2 }
  }

  /// "3.92 V", "-7.5 dB", "1,204".
  func formatted(_ value: Double) -> String {
    let number = value.formatted(.number.precision(.fractionLength(0...2)))
    return unit.isEmpty ? number : "\(number) \(unit)"
  }

  /// Lowest, average and highest of one series.
  static func stats(of points: [MetricChartView.DataPoint]) -> (min: Double, avg: Double, max: Double)? {
    let values = points.map(\.value)
    guard let low = values.min(), let high = values.max() else { return nil }
    return (low, values.reduce(0, +) / Double(values.count), high)
  }

  /// The card's context line: its range for one series ("3.71 – 4.10 V"), or each series' latest
  /// for an overlaid chart ("Direct 120 · Flood 450").
  var contextParts: [String] {
    if isMultiSeries {
      return series.compactMap { s in
        s.dataPoints.last.map { "\(s.name) \($0.value.formatted(.number.precision(.fractionLength(0...2))))" }
      }
    }
    guard let points = series.first?.dataPoints, points.count >= 2,
          let stats = Self.stats(of: points) else { return [] }
    if stats.min == stats.max { return [formatted(stats.min)] }
    let low = stats.min.formatted(.number.precision(.fractionLength(0...2)))
    return ["\(low) – \(formatted(stats.max))"]
  }
}

// MARK: - Building the page's metrics

extension HistoryMetric {
  /// Battery, signal and uptime, in that order; readings with no data are left out.
  static func radio(from snapshots: [NodeStatusSnapshotDTO], ocvArray: [Int]) -> [HistoryMetric] {
    let battery = snapshots.compactMap { s in
      s.batteryMillivolts.map { MetricChartView.DataPoint(id: s.id, date: s.timestamp, value: Double($0) / 1000.0) }
    }
    return [
      HistoryMetric(
        id: "battery", title: L10n.RemoteNodes.RemoteNodes.History.battery,
        systemImage: "battery.75percent", tint: .mint, unit: "V",
        dataPoints: battery, yAxisDomain: ocvArray.voltageChartDomain(dataPoints: battery)
      ),
      HistoryMetric(
        id: "snr", title: L10n.RemoteNodes.RemoteNodes.History.snr,
        systemImage: "waveform", tint: .blue, unit: "dB",
        dataPoints: snapshots.compactMap { s in s.lastSNR.map { .init(id: s.id, date: s.timestamp, value: $0) } }
      ),
      HistoryMetric(
        id: "rssi", title: L10n.RemoteNodes.RemoteNodes.History.rssi,
        systemImage: "cellularbars", tint: .purple, unit: "dBm",
        dataPoints: snapshots.compactMap { s in s.lastRSSI.map { .init(id: s.id, date: s.timestamp, value: Double($0)) } }
      ),
      HistoryMetric(
        id: "noise", title: L10n.RemoteNodes.RemoteNodes.History.noiseFloor,
        systemImage: "waveform.path.ecg", tint: .indigo, unit: "dBm",
        dataPoints: snapshots.compactMap { s in s.noiseFloor.map { .init(id: s.id, date: s.timestamp, value: Double($0)) } }
      ),
      // In hours, so a restart shows as the line dropping to zero.
      HistoryMetric(
        id: "uptime", title: L10n.RemoteNodes.RemoteNodes.Status.uptime,
        systemImage: "clock", tint: .gray, unit: "h",
        dataPoints: snapshots.compactMap { s in s.uptimeSeconds.map { .init(id: s.id, date: s.timestamp, value: Double($0) / 3600) } }
      ),
    ].filter { !$0.isEmpty }
  }

  /// The packet counters (Direct and Flood overlaid) and a room's post counters.
  static func packets(from snapshots: [NodeStatusSnapshotDTO]) -> [HistoryMetric] {
    func points(_ keyPath: KeyPath<NodeStatusSnapshotDTO, UInt32?>) -> [MetricChartView.DataPoint] {
      snapshots.compactMap { s in
        s[keyPath: keyPath].map { MetricChartView.DataPoint(id: s.id, date: s.timestamp, value: Double($0)) }
      }
    }
    func directFlood(
      id: String, title: String, systemImage: String, tint: Color,
      direct: KeyPath<NodeStatusSnapshotDTO, UInt32?>, flood: KeyPath<NodeStatusSnapshotDTO, UInt32?>
    ) -> HistoryMetric {
      HistoryMetric(
        id: id, title: title, systemImage: systemImage, tint: tint, unit: "",
        series: [
          .init(name: L10n.RemoteNodes.RemoteNodes.History.direct, color: .blue, dataPoints: points(direct)),
          .init(name: L10n.RemoteNodes.RemoteNodes.History.flood, color: .orange, dataPoints: points(flood)),
        ]
      )
    }
    let posted = snapshots.compactMap { s in
      s.postedCount.map { MetricChartView.DataPoint(id: s.id, date: s.timestamp, value: Double($0)) }
    }
    let pushed = snapshots.compactMap { s in
      s.postPushCount.map { MetricChartView.DataPoint(id: s.id, date: s.timestamp, value: Double($0)) }
    }
    return [
      directFlood(
        id: "sent", title: L10n.RemoteNodes.RemoteNodes.History.packetsSent,
        systemImage: "arrow.up.circle.fill", tint: .blue, direct: \.sentDirect, flood: \.sentFlood
      ),
      directFlood(
        id: "received", title: L10n.RemoteNodes.RemoteNodes.History.packetsReceived,
        systemImage: "arrow.down.circle.fill", tint: .green, direct: \.receivedDirect, flood: \.receivedFlood
      ),
      directFlood(
        id: "duplicates", title: L10n.RemoteNodes.RemoteNodes.History.duplicates,
        systemImage: "square.on.square", tint: .orange, direct: \.directDuplicates, flood: \.floodDuplicates
      ),
      HistoryMetric(
        id: "errors", title: L10n.RemoteNodes.RemoteNodes.History.receiveErrors,
        systemImage: "exclamationmark.triangle.fill", tint: .red, unit: "", dataPoints: points(\.receiveErrors)
      ),
      HistoryMetric(
        id: "posted", title: L10n.RemoteNodes.RemoteNodes.RoomStatus.postsReceived,
        systemImage: "tray.and.arrow.down.fill", tint: .purple, unit: "", dataPoints: posted
      ),
      HistoryMetric(
        id: "pushed", title: L10n.RemoteNodes.RemoteNodes.RoomStatus.postsPushed,
        systemImage: "paperplane.fill", tint: .cyan, unit: "", dataPoints: pushed
      ),
    ].filter { !$0.isEmpty }
  }

  /// One channel's sensor charts.
  static func sensors(in group: ChannelGroup) -> [HistoryMetric] {
    group.charts.map { chart in
      HistoryMetric(
        id: "sensor-\(chart.key)",
        title: chart.title,
        systemImage: chart.sensorType?.remoteNodeTileSymbol ?? "sensor.fill",
        tint: chart.sensorType?.chartColor ?? .cyan,
        unit: chart.sensorType?.localizedUnitSymbol ?? "",
        dataPoints: chart.dataPoints
      )
    }
  }
}

// MARK: - Card

/// A metric as one of Home's cards: its latest value, a small trend line, and its range.
struct HistoryMetricCard: View {
  let metric: HistoryMetric

  var body: some View {
    HomeCard(
      title: metric.title,
      systemImage: metric.systemImage,
      tint: metric.tint,
      accessibilityValue: accessibilityValue,
      hint: ""
    ) {
      HomeCardValue(value: metric.latestValue.map(metric.formatted) ?? "—")
      if metric.canDrawTrend {
        MetricSparkline(series: metric.series)
          .frame(height: 34)
          .padding(.vertical, 2)
      }
      let parts = metric.contextParts
      if !parts.isEmpty {
        HomeCardDetail(parts: parts)
      } else if let latestDate = metric.latestDate {
        HomeCardDetail(latestDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
      }
    }
  }

  private var accessibilityValue: String {
    ([metric.latestValue.map(metric.formatted)].compactMap(\.self) + metric.contextParts)
      .joined(separator: ", ")
  }
}

/// A trend line with no axes, sized for a card: each series' line over a soft fill (one series),
/// thinned to at most `maxPoints` so a year of snapshots draws as fast as a week.
struct MetricSparkline: View {
  let series: [MetricChartView.Series]
  var maxPoints = 90

  var body: some View {
    let drawn = series.map { s in
      MetricChartView.Series(name: s.name, color: s.color, dataPoints: s.dataPoints.thinned(to: maxPoints))
    }
    let values = drawn.flatMap(\.dataPoints).map(\.value)
    let low = values.min() ?? 0
    let high = values.max() ?? 1
    // A flat line sits in the middle rather than on the floor.
    let pad = high > low ? (high - low) * 0.08 : max(abs(high) * 0.05, 1)
    let domain = (low - pad)...(high + pad)
    let fills = drawn.count == 1

    Chart {
      ForEach(drawn, id: \.name) { s in
        ForEach(s.dataPoints) { point in
          if fills {
            AreaMark(
              x: .value("Time", point.date),
              yStart: .value("Base", domain.lowerBound),
              yEnd: .value("Value", point.value)
            )
            .foregroundStyle(
              LinearGradient(colors: [s.color.opacity(0.28), s.color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
            )
          }
          LineMark(
            x: .value("Time", point.date),
            y: .value("Value", point.value),
            series: .value("Series", s.name)
          )
          .foregroundStyle(s.color)
          .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .chartYScale(domain: domain)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

extension [MetricChartView.DataPoint] {
  /// At most `limit` points, evenly picked, keeping the first and the last.
  func thinned(to limit: Int) -> [MetricChartView.DataPoint] {
    guard count > limit, limit >= 2 else { return self }
    let step = Double(count - 1) / Double(limit - 1)
    return (0..<limit).map { self[Int((Double($0) * step).rounded())] }
  }
}

// MARK: - Grid

/// A run of metric cards in Home's grid, each opening its full chart.
struct HistoryMetricGrid: View {
  let metrics: [HistoryMetric]
  @Binding var selection: String?

  var body: some View {
    MetricTileGrid {
      ForEach(metrics) { metric in
        Button { selection = metric.id } label: {
          HistoryMetricCard(metric: metric)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history.card.\(metric.id)")
      }
    }
  }
}

// MARK: - Full chart

/// A metric opened: its latest value large, the chart at a readable height with the time range
/// above it, and the lowest, average and highest values under it.
struct HistoryMetricSheet: View {
  let metric: HistoryMetric
  @Binding var timeRange: HistoryTimeRange
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      CardForm {
        NodeCardSheetHeader(item: headerItem)
          .padding(.horizontal, 4)

        HistoryTimeRangePicker(selection: $timeRange)

        VStack(alignment: .leading, spacing: 8) {
          MetricChartView(
            title: metric.title,
            unit: metric.unit,
            series: metric.series,
            yAxisDomain: metric.yAxisDomain,
            height: 240
          )
          Text(L10n.RemoteNodes.RemoteNodes.History.scrubHint)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .cardSurface(padding: 12)

        statsCard
      }
      .chartScrubbingScrollLock()
      .flashingNavigationTitle(metric.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  private var headerItem: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: metric.id,
      title: metric.title,
      systemImage: metric.systemImage,
      tint: metric.tint,
      value: metric.latestValue.map(metric.formatted) ?? "—",
      note: metric.latestDate.map {
        "\(L10n.RemoteNodes.RemoteNodes.History.latest) · \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
      },
      destination: .none
    )
  }

  /// Min, Avg and Max: one row for a single reading, a row per series for an overlaid chart, and
  /// how many readings over what span.
  private var statsCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          if metric.isMultiSeries { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
          statHeader(L10n.RemoteNodes.RemoteNodes.Summary.min)
          statHeader(L10n.RemoteNodes.RemoteNodes.Summary.avg)
          statHeader(L10n.RemoteNodes.RemoteNodes.Summary.max)
        }
        ForEach(metric.series, id: \.name) { s in
          if let stats = HistoryMetric.stats(of: s.dataPoints) {
            GridRow {
              if metric.isMultiSeries {
                HStack(spacing: 6) {
                  Circle().fill(s.color).frame(width: 8, height: 8)
                  Text(s.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
              }
              statValue(stats.min)
              statValue(stats.avg)
              statValue(stats.max)
            }
            .accessibilityElement(children: .combine)
          }
        }
      }

      Divider()

      HStack {
        Text(L10n.RemoteNodes.RemoteNodes.History.readings)
          .foregroundStyle(.secondary)
        Text(metric.readingCount, format: .number)
          .monospacedDigit()
        Spacer(minLength: 8)
        if let first = metric.firstDate, let last = metric.latestDate, first < last {
          Text((first..<last).formatted(.interval.month(.abbreviated).day()))
            .foregroundStyle(.secondary)
        }
      }
      .font(.subheadline)
      .accessibilityElement(children: .combine)
    }
    .cardSurface(padding: 12)
  }

  private func statHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .textCase(.uppercase)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func statValue(_ value: Double) -> some View {
    Text(metric.formatted(value))
      .font(.title3.weight(.semibold).monospacedDigit())
      .fontDesign(.rounded)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
