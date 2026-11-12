import CairnServices
import SwiftUI

struct NeighborSNRChartView: View {
  let name: String
  let neighborPrefix: Data
  let fetchSnapshots: @Sendable () async -> [NodeStatusSnapshotDTO]

  @State private var allDataPoints: [MetricChartView.DataPoint] = []
  @State private var timeRange: HistoryTimeRange = .default

  private var filteredDataPoints: [MetricChartView.DataPoint] {
    guard let start = timeRange.startDate else { return allDataPoints }
    return allDataPoints.filter { $0.date >= start }
  }

  var body: some View {
    CardForm {
      HistoryTimeRangePicker(selection: $timeRange)

      MetricChartView(
        title: name,
        unit: "dB",
        dataPoints: filteredDataPoints,
        accentColor: .blue
      )
      .cardSurface(padding: 12)
    }
    .chartScrubbingScrollLock()
    .flashingNavigationTitle(name)
    .navigationBarTitleDisplayMode(.inline)
    .liquidGlassToolbarBackground()
    .task {
      let snapshots = await fetchSnapshots()
      allDataPoints = snapshots.compactMap { snapshot in
        guard let neighbors = snapshot.neighborSnapshots,
              let match = neighbors.first(where: { $0.publicKeyPrefix == neighborPrefix })
        else { return nil }
        return MetricChartView.DataPoint(id: snapshot.id, date: snapshot.timestamp, value: match.snr)
      }
    }
  }
}
