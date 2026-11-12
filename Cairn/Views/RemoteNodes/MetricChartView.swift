import Charts
import CairnServices
import SwiftUI

/// Reusable mini-chart for one or more time-series metrics.
///
/// Single-series charts render exactly as a one-line chart (no legend). Passing
/// more than one series switches to an overlaid multi-series layout with a
/// categorical foreground scale and legend.
struct MetricChartView: View {
  let title: String
  let unit: String
  let series: [Series]
  var yAxisDomain: ClosedRange<Double>?
  /// The plot's height: compact on a page of several charts, taller when a chart is opened alone.
  var height: CGFloat = 160

  /// Held in a reference so a drag reaches only the readout and the rule: the chart's marks
  /// take the same object every pass and so never rebuild while scrubbing.
  @State private var scrub = MetricChartScrub()

  var body: some View {
    let position = ScrubPosition(selectedDate: scrub.selectedDate, series: series)
    VStack(alignment: .leading, spacing: 4) {
      MetricChartHeader(
        title: title, unit: unit, series: series,
        selections: position.selections, scrubDate: position.date
      )

      if !hasEnoughData {
        MetricChartEmptyState(value: emptyStateValue, unit: unit)
      } else {
        MetricChartContent(
          title: title, series: drawnSeries, yAxisDomain: yAxisDomain,
          scrub: scrub, isMultiSeries: isMultiSeries, height: height
        )
        .equatable()
      }
    }
  }

  private var isMultiSeries: Bool {
    series.count > 1
  }

  private var hasEnoughData: Bool {
    series.contains { $0.dataPoints.count >= 2 }
  }

  /// Series that actually carry points. Empty series draw nothing, so dropping
  /// them keeps the categorical scale and legend free of phantom entries.
  private var drawnSeries: [Series] {
    series.filter { !$0.dataPoints.isEmpty }
  }

  /// The single number shown when there are too few points to draw a line, summed
  /// across series so an overlaid Direct/Flood chart reports the total, not just Direct.
  private var emptyStateValue: Double? {
    let firstValues = drawnSeries.compactMap { $0.dataPoints.first?.value }
    return firstValues.isEmpty ? nil : firstValues.reduce(0, +)
  }

  /// Where a scrub lands, worked out once per pass with a binary search in each series.
  struct ScrubPosition {
    /// The scrub position snapped to the nearest plotted point's date, so the readout
    /// and rule line land on real samples rather than arbitrary times between them.
    let date: Date?
    /// The nearest point in each series to the snapped date, or empty when not scrubbing.
    /// The header shows one value per series.
    let selections: [SeriesSelection]

    init(selectedDate: Date?, series: [Series]) {
      guard let selectedDate else {
        date = nil
        selections = []
        return
      }
      let snapped = series.compactMap { $0.dataPoints.nearest(to: selectedDate)?.date }.min {
        abs($0.timeIntervalSince(selectedDate)) < abs($1.timeIntervalSince(selectedDate))
      }
      date = snapped
      selections = snapped.map { snapped in
        series.compactMap { s in
          s.dataPoints.nearest(to: snapped).map { SeriesSelection(series: s, point: $0) }
        }
      } ?? []
    }
  }

  struct DataPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let value: Double
  }

  /// One plotted line in an overlaid chart. `color` drives the direct style for
  /// single-series charts and the categorical scale mapping for multi-series.
  struct Series: Equatable {
    let name: String
    let color: Color
    /// In date order, which the scrub's binary search relies on.
    let dataPoints: [DataPoint]

    init(name: String, color: Color, dataPoints: [DataPoint]) {
      self.name = name
      self.color = color
      // Callers build these from snapshots fetched by timestamp, so this is a linear check.
      let isSorted = zip(dataPoints, dataPoints.dropFirst()).allSatisfy { $0.date <= $1.date }
      self.dataPoints = isSorted ? dataPoints : dataPoints.sorted { $0.date < $1.date }
    }
  }

  /// A series paired with its nearest point to the current scrub position.
  struct SeriesSelection {
    let series: Series
    let point: DataPoint
  }

  /// Single-series convenience initializer wrapping one accent-colored series.
  init(
    title: String,
    unit: String,
    dataPoints: [DataPoint],
    accentColor: Color,
    yAxisDomain: ClosedRange<Double>? = nil,
    height: CGFloat = 160
  ) {
    self.title = title
    self.unit = unit
    self.series = [Series(name: title, color: accentColor, dataPoints: dataPoints)]
    self.yAxisDomain = yAxisDomain
    self.height = height
  }

  /// Multi-series initializer for overlaid charts.
  init(
    title: String,
    unit: String,
    series: [Series],
    yAxisDomain: ClosedRange<Double>? = nil,
    height: CGFloat = 160
  ) {
    self.title = title
    self.unit = unit
    self.series = series
    self.yAxisDomain = yAxisDomain
    self.height = height
  }
}

/// Where the finger is while scrubbing a chart, raw (unsnapped). Only the views that show the
/// scrub read it, so a drag doesn't touch the chart's marks.
@Observable
@MainActor
final class MetricChartScrub {
  var selectedDate: Date?
}

extension [MetricChartView.DataPoint] {
  /// The point nearest `date`, for points in date order; ties go to the earlier point.
  func nearest(to date: Date) -> MetricChartView.DataPoint? {
    guard !isEmpty else { return nil }
    let index = firstIndex(atOrAfter: date, date: \.date)
    if index == endIndex { return self[index - 1] }
    guard index > startIndex else { return self[index] }
    let before = self[index - 1]
    let after = self[index]
    return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
  }
}

/// Header row that shows the title, and selected value(s) + timestamp when scrubbing.
private struct MetricChartHeader: View {
  let title: String
  let unit: String
  let series: [MetricChartView.Series]
  let selections: [MetricChartView.SeriesSelection]
  let scrubDate: Date?

  private var isMultiSeries: Bool {
    series.count > 1
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.subheadline)
        .bold()

      Spacer()

      if isMultiSeries {
        multiSeriesReadout
      } else {
        singleSeriesReadout
      }
    }
    .font(.caption)
    .animation(.none, value: selections.map(\.point.id))
  }

  @ViewBuilder
  private var singleSeriesReadout: some View {
    if let selection = selections.first {
      Text("\(selection.point.value, format: .number) \(unit)")
        .bold()
        .foregroundStyle(selection.series.color)
        + Text("  ")
        + Text(selection.point.date, format: .dateTime.month(.abbreviated).day().hour().minute())
        .foregroundStyle(.secondary)
    }
  }

  /// Each series' nearest value, color-coded, with the shared scrub timestamp.
  @ViewBuilder
  private var multiSeriesReadout: some View {
    if !selections.isEmpty {
      VStack(alignment: .trailing, spacing: 2) {
        ForEach(selections, id: \.series.name) { selection in
          HStack(spacing: 4) {
            Text(selection.series.name)
              .foregroundStyle(.secondary)
            Text("\(selection.point.value, format: .number)")
              .bold()
              .foregroundStyle(selection.series.color)
          }
        }
        if let scrubDate {
          Text(scrubDate, format: .dateTime.month(.abbreviated).day().hour().minute())
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Chart content with line and point marks. Equatable on its data alone, so the scrub (read
/// only by the rule and the gesture inside) never rebuilds the marks.
private struct MetricChartContent: View, Equatable {
  let title: String
  let series: [MetricChartView.Series]
  let yAxisDomain: ClosedRange<Double>?
  let scrub: MetricChartScrub
  let isMultiSeries: Bool
  let height: CGFloat

  @State private var isScrubbing = false

  /// Dots on each sample only while they stay apart; a dense line reads better bare.
  private static let maxDottedPoints = 40

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title
      && lhs.series == rhs.series
      && lhs.yAxisDomain == rhs.yAxisDomain
      && lhs.scrub === rhs.scrub
      && lhs.isMultiSeries == rhs.isMultiSeries
      && lhs.height == rhs.height
  }

  private var foregroundStyleFor: (String) -> Color {
    let lookup = Dictionary(uniqueKeysWithValues: series.map { ($0.name, $0.color) })
    return { (name: String) -> Color in lookup[name] ?? .gray }
  }

  var body: some View {
    chart
      // The rule sits behind the marks, as the RuleMark it replaces did, in its own view.
      .chartBackground { proxy in
        GeometryReader { geo in
          MetricChartScrubRule(
            scrub: scrub,
            series: series,
            proxy: proxy,
            plotFrame: proxy.plotFrame.map { geo[$0] } ?? .zero
          )
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geo in
          let plotOriginX = proxy.plotFrame.map { geo[$0].origin.x } ?? 0
          Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(
              ChartScrubGesture(
                scrub: scrub,
                isScrubbing: $isScrubbing,
                proxy: proxy,
                plotOriginX: plotOriginX
              )
            )
        }
      }
      .sensoryFeedback(.impact, trigger: isScrubbing) { old, new in !old && new }
      .preference(key: ChartScrubbingPreferenceKey.self, value: isScrubbing)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
          AxisValueLabel()
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
          AxisValueLabel(format: xAxisFormat)
        }
      }
      .accessibilityLabel(title)
      .frame(height: height)
  }

  /// Times of day across a day or two of samples, dates across longer spans.
  private var xAxisFormat: Date.FormatStyle {
    let dates = series.flatMap { [$0.dataPoints.first?.date, $0.dataPoints.last?.date] }.compactMap(\.self)
    guard let first = dates.min(), let last = dates.max() else { return .dateTime.month(.abbreviated).day() }
    return last.timeIntervalSince(first) < 36 * 3600
      ? .dateTime.hour().minute()
      : .dateTime.month(.abbreviated).day()
  }

  private var showsPoints: Bool {
    (series.map(\.dataPoints.count).max() ?? 0) <= Self.maxDottedPoints
  }

  /// The floor the single-series fill rises from: the Y range's bottom, so it never drags the
  /// axis down to zero.
  private var fillBaseline: Double {
    if let yAxisDomain { return yAxisDomain.lowerBound }
    return series.flatMap(\.dataPoints).map(\.value).min() ?? 0
  }

  @ViewBuilder
  private var chart: some View {
    let base = Chart {
      ForEach(series, id: \.name) { s in
        ForEach(s.dataPoints) { point in
          if isMultiSeries {
            LineMark(
              x: .value("Time", point.date),
              y: .value(title, point.value)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(by: .value("Series", s.name))
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if showsPoints {
              PointMark(
                x: .value("Time", point.date),
                y: .value(title, point.value)
              )
              .foregroundStyle(by: .value("Series", s.name))
              .symbolSize(16)
            }
          } else {
            AreaMark(
              x: .value("Time", point.date),
              yStart: .value("Base", fillBaseline),
              yEnd: .value(title, point.value)
            )
            .foregroundStyle(
              LinearGradient(colors: [s.color.opacity(0.25), s.color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
            )

            LineMark(
              x: .value("Time", point.date),
              y: .value(title, point.value)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(s.color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if showsPoints {
              PointMark(
                x: .value("Time", point.date),
                y: .value(title, point.value)
              )
              .foregroundStyle(s.color)
              .symbolSize(16)
            }
          }
        }
      }
    }

    if isMultiSeries {
      if let yAxisDomain {
        base.chartYScale(domain: yAxisDomain)
          .chartForegroundStyleScale(mapping: foregroundStyleFor)
          .chartLegend(.visible)
      } else {
        base.chartForegroundStyleScale(mapping: foregroundStyleFor)
          .chartLegend(.visible)
      }
    } else if let yAxisDomain {
      base.chartYScale(domain: yAxisDomain)
    } else {
      // The fill would otherwise pull the axis to zero (an RSSI of -100 drawn from 0).
      base.chartYScale(domain: .automatic(includesZero: false))
    }
  }
}

/// The dashed line at the snapped scrub date, drawn over the plot area from the chart's proxy.
private struct MetricChartScrubRule: View {
  let scrub: MetricChartScrub
  let series: [MetricChartView.Series]
  let proxy: ChartProxy
  let plotFrame: CGRect

  var body: some View {
    let position = MetricChartView.ScrubPosition(selectedDate: scrub.selectedDate, series: series)
    if let date = position.date, let x = proxy.position(forX: date) {
      Path { path in
        path.move(to: CGPoint(x: plotFrame.minX + x, y: plotFrame.minY))
        path.addLine(to: CGPoint(x: plotFrame.minX + x, y: plotFrame.maxY))
      }
      .stroke(.secondary.opacity(0.3), style: StrokeStyle(dash: [4, 4]))
      .allowsHitTesting(false)
    }
  }
}

// MARK: - Shared Packet-Count Domain

extension [MetricChartView.DataPoint] {
  /// Returns a common Y-axis domain spanning `0 ... max * 1.05` across all given arrays,
  /// or `nil` when there is no positive max (empty or all-zero data).
  static func sharedDomain(for arrays: [[MetricChartView.DataPoint]]) -> ClosedRange<Double>? {
    let maxVal = arrays.flatMap(\.self).map(\.value).max()
    guard let maxVal, maxVal > 0 else { return nil }
    return 0...maxVal * 1.05
  }
}

// MARK: - OCV Chart Domain

extension [Int] {
  /// Computes a chart Y-axis domain in volts from millivolt OCV values, with a ±buffer.
  /// Unions the OCV range with actual data points so outliers are never clipped.
  func voltageChartDomain(
    dataPoints: [MetricChartView.DataPoint] = [],
    bufferMV: Int = 500
  ) -> ClosedRange<Double>? {
    guard let ocvMin = self.min(), let ocvMax = self.max() else { return nil }
    var lo = Double(ocvMin) / 1000.0
    var hi = Double(ocvMax) / 1000.0
    let values = dataPoints.map(\.value)
    if let dataMin = values.min() { lo = Swift.min(lo, dataMin) }
    if let dataMax = values.max() { hi = Swift.max(hi, dataMax) }
    let buffer = Double(bufferMV) / 1000.0
    return Swift.max(0, lo - buffer)...hi + buffer
  }
}

// MARK: - Chart Scrubbing Scroll Lock

private struct ChartScrubbingPreferenceKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

extension View {
  /// Apply to a `List` or `ScrollView` containing `MetricChartView`s to disable
  /// scrolling while the user is long-press scrubbing a chart.
  func chartScrubbingScrollLock() -> some View {
    modifier(ChartScrubbingScrollLockModifier())
  }
}

private struct ChartScrubbingScrollLockModifier: ViewModifier {
  @State private var isScrubbing = false

  func body(content: Content) -> some View {
    content
      .onPreferenceChange(ChartScrubbingPreferenceKey.self) { isScrubbing = $0 }
      .scrollDisabled(isScrubbing)
  }
}

// MARK: - Chart Scrub Gesture

/// UIKit-backed long-press-then-drag gesture for chart scrubbing.
/// Uses `UILongPressGestureRecognizer` because SwiftUI gestures block the parent
/// scroll view's pan recognizer regardless of `.simultaneousGesture` usage.
/// The UIKit recognizer's delegate allows proper simultaneous recognition,
/// and its `.changed` state reports continuous location updates after recognition.
private struct ChartScrubGesture: UIGestureRecognizerRepresentable {
  let scrub: MetricChartScrub
  @Binding var isScrubbing: Bool
  let proxy: ChartProxy
  let plotOriginX: CGFloat

  func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
    let recognizer = UILongPressGestureRecognizer()
    recognizer.minimumPressDuration = 0.25
    recognizer.delegate = context.coordinator
    return recognizer
  }

  func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
    switch recognizer.state {
    case .began:
      isScrubbing = true
      fallthrough
    case .changed:
      let x = context.converter.localLocation.x - plotOriginX
      if let date: Date = proxy.value(atX: x) {
        scrub.selectedDate = date
      }
    case .ended, .cancelled, .failed:
      isScrubbing = false
      scrub.selectedDate = nil
    default:
      break
    }
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }
  }
}

/// Empty state shown when fewer than 2 data points exist.
private struct MetricChartEmptyState: View {
  let value: Double?
  let unit: String

  var body: some View {
    VStack {
      if let value {
        Text("\(value.formatted()) \(unit)")
          .font(.title2)
      }
      Text(L10n.RemoteNodes.RemoteNodes.History.checkBack)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 80)
  }
}
