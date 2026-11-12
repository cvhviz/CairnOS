import CairnServices
import MeshCore
import SwiftUI

/// Min/avg/max telemetry summary (the firmware's MMA request) for a remote node.
///
/// Loads only when expanded: firmware answers this request only on nodes that log sensor
/// history (sensor firmware), so it is opt-in rather than fetched on every open. Sent straight
/// through the session rather than `BinaryProtocolService`, whose timeout recovery resets the
/// contact's path to flood; an unsupported node always times out and must not cost the route.
struct NodeTelemetrySummarySection: View {
  @Environment(\.appState) private var appState

  let publicKey: Data

  @State private var isExpanded = false
  @State private var range: TelemetrySummaryRange = .day
  @State private var rows: [TelemetrySummaryRow] = []
  @State private var loadedRange: TelemetrySummaryRange?
  @State private var isLoading = false
  @State private var errorMessage: String?

  private var isReady: Bool { appState.connectionState == .ready }

  var body: some View {
    NodeDisclosureCard(
      L10n.RemoteNodes.RemoteNodes.Summary.title,
      systemImage: "chart.bar.xaxis",
      color: .purple,
      isExpanded: $isExpanded
    ) {
      InfoButton(L10n.RemoteNodes.RemoteNodes.Summary.footer, title: L10n.RemoteNodes.RemoteNodes.Summary.title)
      SectionReloadButton(
        isLoading: isLoading,
        isLoaded: loadedRange != nil,
        hasError: errorMessage != nil,
        isDisabled: !isReady,
        accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Summary.reload,
        onReload: { await load() }
      )
    } content: {
      Picker(L10n.RemoteNodes.RemoteNodes.Summary.range, selection: $range) {
        ForEach(TelemetrySummaryRange.allCases) { range in
          Text(range.label).tag(range)
        }
      }
      .pickerStyle(.segmented)
      .disabled(isLoading)

      if isLoading {
        NodeCardStatusLine(kind: .loading)
      } else if let errorMessage {
        NodeCardStatusLine(kind: .error(errorMessage))
      } else if loadedRange != nil, rows.isEmpty {
        NodeCardStatusLine(kind: .note(L10n.RemoteNodes.RemoteNodes.Summary.noData))
      } else if !isReady, loadedRange == nil {
        NodeCardStatusLine(kind: .note(L10n.RemoteNodes.RemoteNodes.Summary.disconnected))
      }
    }
    .onChange(of: isExpanded) { _, expanded in
      if expanded, loadedRange == nil, !isLoading, isReady {
        Task { await load() }
      }
    }
    .onChange(of: range) { _, newRange in
      if newRange == loadedRange {
        // Back on the range whose rows are still held; a failure for another range no longer applies.
        errorMessage = nil
      } else if isExpanded, isReady {
        Task { await load() }
      }
    }

    // The tiles follow the card rather than sitting on it as cards on a card.
    if isExpanded, !isLoading, errorMessage == nil, !rows.isEmpty {
      MetricTileGrid {
        ForEach(rows) { row in
          MetricTile(
            row.label,
            systemImage: row.sensorType?.remoteNodeTileSymbol ?? "sensor.fill",
            value: row.avg,
            caption: L10n.RemoteNodes.RemoteNodes.Summary.tileCaption(row.min, row.max)
          )
        }
      }
    }
  }

  private func load() async {
    guard !isLoading else { return }
    guard let session = appState.services?.session else {
      errorMessage = L10n.RemoteNodes.RemoteNodes.Summary.disconnected
      return
    }
    let requestedRange = range
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    let end = Date()
    do {
      let response = try await session.requestMMA(
        from: publicKey,
        start: end.addingTimeInterval(-requestedRange.duration),
        end: end
      )
      rows = TelemetrySummaryFormatter.rows(from: response.data)
      loadedRange = requestedRange
    } catch is CancellationError {
      return
    } catch MeshCoreError.timeout {
      errorMessage = L10n.RemoteNodes.RemoteNodes.Summary.timedOut
    } catch {
      errorMessage = error.userFacingMessage
    }
  }
}
