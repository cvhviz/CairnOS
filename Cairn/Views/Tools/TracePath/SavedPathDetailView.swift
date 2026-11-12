import Charts
import CairnServices
import SwiftUI

struct SavedPathDetailView: View {
  @Environment(\.appState) private var appState
  @State private var viewModel: SavedPathDetailViewModel
  /// The runs as a CSV, staged for the share sheet.
  @State private var runsExport: ExportedFile?

  init(savedPath: SavedTracePathDTO) {
    _viewModel = State(initialValue: SavedPathDetailViewModel(savedPath: savedPath))
  }

  var body: some View {
    CardForm {
      pathSection
      performanceSection
      historySection
    }
    .navigationDestination(for: TracePathRoute.RunDetail.self) { route in
      RunDetailView(run: route.run)
    }
    .flashingNavigationTitle(viewModel.savedPath.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if let url = runsExport?.url {
          ShareLink(item: url) {
            Label(L10n.Tools.Tools.TracePath.Share.runs, systemImage: "square.and.arrow.up")
          }
          .accessibilityIdentifier("savedPath.shareRuns")
        }
      }
    }
    // The runs CSV is staged once per set of runs, so the share sheet has a file ready.
    .onChange(of: viewModel.savedPath.runs.count, initial: true) { _, count in
      runsExport?.removeTemporaryFile()
      runsExport = count > 0 ? TraceExport.runsExport(for: viewModel.savedPath) : nil
    }
    .onDisappear {
      runsExport?.removeTemporaryFile()
      runsExport = nil
    }
    .task {
      viewModel.configure(dataStore: { appState.services?.dataStore })
    }
    .refreshable {
      await viewModel.refresh()
    }
    .refreshCommand { await viewModel.refresh() }
  }

  // MARK: - Path Section

  private var pathSection: some View {
    CardFormSection(L10n.Contacts.Contacts.PathDetail.path) {
      PathChipsView(pathData: viewModel.savedPath.pathBytes, hashSize: viewModel.hashSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
  }

  // MARK: - Performance Section

  /// The averages as tiles, with the round-trip chart under them once there are at least two
  /// runs to draw a line between.
  private var performanceSection: some View {
    CardFormSection(L10n.Contacts.Contacts.PathDetail.performance) {
      MetricTileGrid {
        MetricTile(
          L10n.Contacts.Contacts.PathDetail.avg,
          systemImage: "timer",
          value: viewModel.averageRoundTrip.map { "\($0) ms" } ?? "—"
        )
        MetricTile(
          L10n.Contacts.Contacts.PathDetail.best,
          systemImage: "hare",
          value: viewModel.bestRoundTrip.map { "\($0) ms" } ?? "—"
        )
        MetricTile(
          L10n.Contacts.Contacts.PathDetail.success,
          systemImage: "checkmark.seal",
          value: viewModel.successRateText
        )
      }
      if viewModel.successfulRuns.count >= 2 {
        performanceChart
          .cardSurface()
      }
    }
  }

  private var performanceChart: some View {
    Chart(viewModel.successfulRuns) { run in
      LineMark(
        x: .value("Date", run.date),
        y: .value("RTT", run.roundTripMs)
      )
      .foregroundStyle(.blue)

      PointMark(
        x: .value("Date", run.date),
        y: .value("RTT", run.roundTripMs)
      )
      .foregroundStyle(.blue)
    }
    .frame(height: 150)
    .chartYAxisLabel(L10n.Contacts.Contacts.PathDetail.roundTripMs)
  }

  // MARK: - History Section

  /// Each run is a card that opens its details.
  @ViewBuilder
  private var historySection: some View {
    if !viewModel.sortedRuns.isEmpty {
      CardFormSection(L10n.Contacts.Contacts.PathDetail.history) {
        LazyVStack(spacing: CardStyle.spacing) {
          ForEach(viewModel.sortedRuns) { run in
            NavigationLink(value: TracePathRoute.RunDetail(run: run)) {
              runRow(run)
                .cardSurface()
                .cardInteractionShape()
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func runRow(_ run: TracePathRunDTO) -> some View {
    HStack {
      VStack(alignment: .leading) {
        Text(run.date.formatted(date: .abbreviated, time: .shortened))
          .foregroundStyle(Color.primary)
        if run.success {
          Text("\(run.roundTripMs) ms")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if !run.success {
        Text(L10n.Contacts.Contacts.PathDetail.failed)
          .font(.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.red.opacity(0.2), in: .capsule)
          .foregroundStyle(.red)
      }

      Image(systemName: "chevron.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Supporting Views

private struct PathChipsView: View {
  let pathData: Data
  let hashSize: Int

  private var hopHexStrings: [String] {
    // An imported backup can carry a zero width; striding by it would trap.
    guard hashSize > 0 else { return [] }
    return stride(from: 0, to: pathData.count, by: hashSize).map { start in
      let end = min(start + hashSize, pathData.count)
      return pathData[start..<end].uppercaseHexString()
    }
  }

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        ForEach(Array(hopHexStrings.enumerated()), id: \.offset) { index, hex in
          if index > 0 {
            Image(systemName: "arrow.right")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          Text(hex)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: .capsule)
        }
      }
    }
    .scrollIndicators(.hidden)
  }
}

private struct RunDetailView: View {
  let run: TracePathRunDTO

  var body: some View {
    CardForm {
      CardFormSection(L10n.Contacts.Contacts.PathDetail.overview) {
        MetricTileGrid {
          MetricTile(
            L10n.Contacts.Contacts.PathDetail.date,
            systemImage: "calendar",
            value: run.date.formatted(date: .abbreviated, time: .omitted),
            caption: run.date.formatted(date: .omitted, time: .shortened)
          )
          MetricTile(
            L10n.Contacts.Contacts.PathDetail.roundTrip,
            systemImage: "timer",
            value: "\(run.roundTripMs) ms"
          )
          // The word carries the outcome; the tint and symbol only reinforce it.
          MetricTile(
            L10n.Contacts.Contacts.PathDetail.status,
            systemImage: "flag",
            value: run.success ? L10n.Contacts.Contacts.PathDetail.success : L10n.Contacts.Contacts.PathDetail.failed,
            valueTint: run.success ? .green : .red,
            statusSymbol: run.success ? "checkmark.circle.fill" : "xmark.circle.fill",
            statusTint: run.success ? .green : .red
          )
        }
      }

      // One card for the hops: an open-ended list reads better as rows than as tiles.
      if run.success, !run.hopsSNR.isEmpty {
        CardFormSection(L10n.Contacts.Contacts.PathDetail.perHopSNR) {
          ContentCard {
            ForEach(Array(run.hopsSNR.enumerated()), id: \.offset) { index, snr in
              if index > 0 {
                Divider()
              }
              LabeledContent(L10n.Contacts.Contacts.PathDetail.hop(index + 1)) {
                Text(snr, format: .number.precision(.fractionLength(2)))
                  + Text(" dB")
              }
            }
          }
        }
      }
    }
    .flashingNavigationTitle(L10n.Contacts.Contacts.PathDetail.runDetails)
    .navigationBarTitleDisplayMode(.inline)
  }
}
