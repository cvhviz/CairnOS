import CairnServices
import CoreLocation
import SwiftUI

/// Trace results: the summary figures (batch success, round trip, total distance) as dashboard
/// tiles, then the per-hop rows and the save action.
struct TraceResultsSectionView: View {
  let result: TraceResult
  @Bindable var viewModel: TracePathViewModel
  @Binding var saveHapticTrigger: Int
  @Binding var showingDistanceInfo: Bool
  /// Opens Line of Sight between two located hops.
  var onCheckLineOfSight: ((CLLocationCoordinate2D, CLLocationCoordinate2D) -> Void)?

  var body: some View {
    if result.success {
      MetricTileGrid {
        if showsBatchStatus {
          batchTile
        }
        roundTripTile
        distanceTile
      }

      // Each hop is its own card, then the saved path's history and the save action.
      VStack(spacing: CardStyle.spacing) {
        ForEach(Array(result.hops.enumerated()), id: \.element.id) { index, hop in
          TraceResultHopRow(
            hop: hop,
            hopIndex: index,
            batchStats: viewModel.batchEnabled ? viewModel.hopStats(at: index) : nil,
            latestSNR: viewModel.batchEnabled ? viewModel.latestHopSNR(at: index) : nil,
            isBatchInProgress: viewModel.isBatchInProgress,
            batchReach: viewModel.batchEnabled ? viewModel.hopReach(at: index) : nil,
            onCheckLineOfSight: lineOfSightAction(at: index)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface()
        }

        // A saved path's recent round trips, with the way into its full history.
        if isComparing, let savedPath = viewModel.activeSavedPath, !savedPath.recentRTTs.isEmpty {
          HStack {
            MiniSparkline(values: savedPath.recentRTTs)
              .frame(height: 20)
              .accessibilityHidden(true)

            Spacer()

            NavigationLink(value: TracePathRoute.savedPathDetail(savedPath)) {
              Text(L10n.Contacts.Contacts.Results.viewRuns(savedPath.runCount))
                .font(.caption)
            }
          }
          .cardSurface()
        }

        // Save path action (only for successful traces when not running a saved path)
        if !viewModel.isRunningSavedPath {
          SavePathRowView(viewModel: viewModel, saveHapticTrigger: $saveHapticTrigger)
            .cardSurface()
        }
      }
    } else if let error = result.errorMessage {
      Label(error, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
  }

  // MARK: - Line of Sight

  /// A weak link (the SNR hop `index` heard hop `index - 1` at, averaged in a batch) between
  /// two placed nodes can be checked for terrain in the way.
  private func lineOfSightAction(at index: Int) -> (() -> Void)? {
    guard index > 0, let onCheckLineOfSight, index < result.hops.count else { return nil }
    let from = result.hops[index - 1]
    let to = result.hops[index]
    let snr = viewModel.batchEnabled ? (viewModel.hopStats(at: index)?.avg ?? to.snr) : to.snr
    guard SNRQuality(snr: snr) == .poor,
          from.hasLocation, to.hasLocation,
          let fromLat = from.latitude, let fromLon = from.longitude,
          let toLat = to.latitude, let toLon = to.longitude else { return nil }
    let origin = CLLocationCoordinate2D(latitude: fromLat, longitude: fromLon)
    let target = CLLocationCoordinate2D(latitude: toLat, longitude: toLon)
    return { onCheckLineOfSight(origin, target) }
  }

  // MARK: - State

  private var showsBatchStatus: Bool {
    viewModel.batchEnabled && (viewModel.isBatchInProgress || viewModel.isBatchComplete)
  }

  /// Batch mode wins over a comparison, as it did when these were rows.
  private var showsBatchRoundTrip: Bool {
    viewModel.batchEnabled && viewModel.successCount > 0
  }

  private var isComparing: Bool {
    !showsBatchRoundTrip && viewModel.isRunningSavedPath && viewModel.previousRun != nil
  }

  // MARK: - Tiles

  /// Progress while the batch runs, then the share of traces that came back.
  private var batchTile: some View {
    let successPercent = viewModel.batchSize > 0
      ? (viewModel.successCount * 100) / viewModel.batchSize
      : 0
    let isComplete = viewModel.isBatchComplete
    return MetricTile(
      L10n.Contacts.Contacts.PathDetail.success,
      systemImage: "checkmark.seal",
      value: isComplete
        ? (Double(successPercent) / 100).formatted(.percent.precision(.fractionLength(0)))
        : "\(viewModel.currentTraceIndex.formatted()) / \(viewModel.batchSize.formatted())",
      caption: isComplete
        ? L10n.Contacts.Contacts.Results.batchSuccess(viewModel.successCount, viewModel.batchSize, successPercent)
        : L10n.Contacts.Contacts.Results.batchProgress(viewModel.currentTraceIndex, viewModel.batchSize),
      statusSymbol: isComplete ? "checkmark.circle.fill" : nil,
      statusTint: .green
    ) {
      if !isComplete, viewModel.batchSize > 0 {
        ProgressView(value: Double(viewModel.currentTraceIndex), total: Double(viewModel.batchSize))
      }
    }
  }

  @ViewBuilder private var roundTripTile: some View {
    if showsBatchRoundTrip {
      MetricTile(
        L10n.Contacts.Contacts.Results.avgRoundTrip,
        systemImage: "timer",
        value: viewModel.averageRTT.map { "\($0) ms" } ?? "—",
        caption: viewModel.minRTT.flatMap { min in viewModel.maxRTT.map { max in "\(min) – \(max) ms" } }
      )
    } else if viewModel.isRunningSavedPath, let previous = viewModel.previousRun {
      comparisonTile(previous: previous)
    } else {
      MetricTile(
        L10n.Contacts.Contacts.PathDetail.roundTrip,
        systemImage: "timer",
        value: "\(result.durationMs) ms"
      )
    }
  }

  /// This run against the saved path's previous one: the change in the caption, in words, with
  /// an arrow that only reinforces it.
  private func comparisonTile(previous: TracePathRunDTO) -> some View {
    let diff = result.durationMs - previous.roundTripMs
    let percentChange = previous.roundTripMs > 0
      ? abs(Double(diff) / Double(previous.roundTripMs))
      : 0
    let versus = L10n.Contacts.Contacts.Results.comparison(
      previous.roundTripMs,
      previous.date.formatted(date: .abbreviated, time: .omitted)
    )
    let change = diff > 0
      ? L10n.Contacts.Contacts.Results.Comparison.increased
      : L10n.Contacts.Contacts.Results.Comparison.decreased
    return MetricTile(
      L10n.Contacts.Contacts.PathDetail.roundTrip,
      systemImage: "timer",
      value: "\(result.durationMs) ms",
      caption: diff == 0
        ? versus
        : "\(change) \(percentChange.formatted(.percent.precision(.fractionLength(0)))) · \(versus)",
      statusSymbol: diff == 0 ? nil : (diff > 0 ? "arrow.up" : "arrow.down"),
      statusTint: diff > 0 ? .red : .green
    )
  }

  /// When the distance is partial or missing, the whole tile opens the explanation.
  @ViewBuilder private var distanceTile: some View {
    let distance = viewModel.totalPathDistance
    let tile = MetricTile(
      L10n.Contacts.Contacts.Results.totalDistance,
      systemImage: "point.topleft.down.to.point.bottomright.curvepath",
      value: distance.map(formatDistance) ?? "—",
      caption: distance == nil
        ? L10n.Contacts.Contacts.Results.unavailable
        : (viewModel.isDistanceUsingFallback ? L10n.Contacts.Contacts.Results.partialDistanceLabel : nil),
      statusSymbol: distance == nil || viewModel.isDistanceUsingFallback ? "info.circle" : nil,
      statusTint: .secondary
    )
    if distance == nil || viewModel.isDistanceUsingFallback {
      Button {
        showingDistanceInfo = true
      } label: {
        tile
      }
      .buttonStyle(.plain)
      .accessibilityHint(distance == nil
        ? L10n.Contacts.Contacts.Results.distanceInfoHint
        : L10n.Contacts.Contacts.Results.partialDistanceHint)
    } else {
      tile
    }
  }

  private func formatDistance(_ meters: Double) -> String {
    let measurement = Measurement(value: meters, unit: UnitLength.meters)
    return measurement.formatted(.measurement(width: .abbreviated, usage: .road).locale(MeasurementPreference.locale()))
  }
}
