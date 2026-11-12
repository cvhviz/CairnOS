import CairnServices
import SwiftUI

/// What Scan & Traffic's header reads: the packets since the scan began, or with no scan the
/// last while's, newest first, with their figures.
struct NodeDiscoveryTrafficStats: Equatable {
  /// With no scan to count from, how far back the section looks.
  static let recentWindow: TimeInterval = 10 * 60

  let count: Int
  /// Nil until there's been a few seconds to measure over.
  let perMinute: Double?
  let bestSNR: Double?

  /// Where the section starts counting.
  static func start(scanStartedAt: Date?, now: Date) -> Date {
    scanStartedAt ?? now.addingTimeInterval(-recentWindow)
  }

  /// The entries from `start` on, newest first. `entries` is oldest first, as the log keeps them.
  static func entries(_ entries: some BidirectionalCollection<RxLogEntryDTO>, since start: Date) -> [RxLogEntryDTO] {
    var result: [RxLogEntryDTO] = []
    for entry in entries.reversed() {
      guard entry.receivedAt >= start else { break }
      result.append(entry)
    }
    return result
  }

  /// - Parameter entries: Newest first, from `start` on.
  init(entries: [RxLogEntryDTO], start: Date, now: Date) {
    count = entries.count
    let elapsed = now.timeIntervalSince(start)
    perMinute = elapsed >= 5 ? Double(entries.count) / elapsed * 60 : nil
    bestSNR = entries.compactMap(\.snr).max()
  }
}

/// The top of Scan & Traffic's sheet, pinned while the list scrolls, and all the sheet shows when
/// it's lowered: one line saying what the scan is doing and how busy the channel is, with the (i)
/// on how scanning works; under it Scan and Wardrive side by side; then the radios' mini spectrum
/// of the last minute as a slim strip. A tap on the line or the strip opens what the scan found so
/// far (the packets heard, the best signal and the farthest node, which select their node), what
/// the last probe said, and how the packets reach the app; another closes it. Every reading keeps
/// its place, so nothing above the list moves as they change.
struct NodeDiscoveryHeader: View {
  let viewModel: NodeDiscoveryViewModel
  /// The radio's packets (oldest first, as the log keeps them) and how they reach the app.
  let traffic: RxLogViewModel
  /// What the current scan's list holds; nil while it's empty.
  let summary: NodeDiscoverySummary?
  @Binding var isExpanded: Bool
  let onSelect: (Data) -> Void

  @Environment(\.appState) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Ticks once a second, so the bars move along and the counts stay honest.
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let start = NodeDiscoveryTrafficStats.start(scanStartedAt: viewModel.scanStartedAt, now: context.date)
      let stats = NodeDiscoveryTrafficStats(
        entries: NodeDiscoveryTrafficStats.entries(traffic.entries, since: start),
        start: start,
        now: context.date
      )
      let status = viewModel.scanStatus
      let line = status.headerLine(now: context.date, packetsPerMinute: stats.perMinute)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Button(action: toggleExpanded) {
            HStack(spacing: 4) {
              Text(line)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
              Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityHint(L10n.Tools.Tools.NodeDiscovery.Header.expandHint)
          .accessibilityAddTraits(isExpanded ? .isSelected : [])
          .accessibilityIdentifier("nodeDiscovery.status")
          InfoButton(
            [
              L10n.Tools.Tools.NodeDiscovery.listenInfo,
              L10n.Tools.Tools.NodeDiscovery.scanInfo,
              L10n.Tools.Tools.NodeDiscovery.Cooldown.explainer,
              viewModel.namesInfo,
              L10n.Tools.Tools.NodeDiscovery.wardriveInfo,
            ]
            .joined(separator: "\n\n"),
            title: L10n.Tools.Tools.nodeDiscovery
          )
        }
        NodeDiscoveryScanButtons(viewModel: viewModel)
        // A tap on the strip opens or closes the same details as a tap on the line above it. A
        // Button, not a tap gesture: the sheet's drag on the header has priority over gestures
        // under it, but a button's tap still lands.
        Button(action: toggleExpanded) {
          MiniSpectrumView(
            frame: appState.spectrumFeed.frame(barCount: SpectrumFeed.barCount(horizontalSizeClass), now: context.date),
            showsDetail: false
          )
          .frame(height: 30)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line)
        .accessibilityHint(L10n.Tools.Tools.NodeDiscovery.Header.expandHint)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityIdentifier("nodeDiscovery.activity")
        if isExpanded {
          // A tap anywhere on the details closes them again; the highlights' own buttons still
          // pick their node.
          Button(action: toggleExpanded) {
            VStack(alignment: .leading, spacing: 8) {
              if let detail = status.detail(now: context.date) {
                Text(detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              NodeDiscoveryHighlights(stats: stats, summary: summary, onSelect: onSelect)
              // How the packets reach the app ("All traffic received", what was lost), and while
              // the channel is still being learned, that relays show by hash: here rather than
              // over the Packets list.
              if appState.services?.rxLogService != nil {
                VStack(alignment: .leading, spacing: 2) {
                  RxLogDeliveryNotes(viewModel: traffic, isConnected: true)
                }
                .accessibilityElement(children: .combine)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("nodeDiscovery.details")
          .transition(.opacity)
        }
      }
    }
    // A tap on a waiting scan button says why in the header: open it to show the reason.
    .onChange(of: viewModel.scanStatus.showsCooldownReason) { _, shows in
      if shows { withAnimation(reduceMotion ? nil : .snappy) { isExpanded = true } }
    }
  }

  /// Opens or closes what the scan found so far.
  private func toggleExpanded() {
    withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
  }
}

/// What the scan found so far, in the open header: the packets heard and their rate, the best
/// signal and the farthest node, which select their node. Every figure keeps its place.
struct NodeDiscoveryHighlights: View {
  let stats: NodeDiscoveryTrafficStats
  /// What the current scan's list holds; nil while it's empty.
  let summary: NodeDiscoverySummary?
  let onSelect: (Data) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ScanSummaryStat(
        title: L10n.Tools.Tools.Spectrum.Meter.packets,
        systemImage: "waveform",
        value: stats.count.formatted(),
        caption: stats.perMinute.map {
          L10n.Tools.Tools.Spectrum.Figure.perMinute($0.formatted(.number.precision(.fractionLength(1))))
        } ?? " "
      )
      highlight(
        summary?.bestSignal,
        title: L10n.Tools.Tools.NodeDiscovery.Summary.bestSignal,
        systemImage: "cellularbars",
        // With no node to name, the best the radio has heard of anything.
        value: (summary?.bestSignal?.value ?? stats.bestSNR).map { NodeDiscoveryFormat.snr($0) },
        identifier: "nodeDiscovery.summary.bestSignal"
      )
      highlight(
        summary?.farthest,
        title: L10n.Tools.Tools.NodeDiscovery.Summary.farthest,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        value: summary?.farthest.map { NodeDiscoveryFormat.distance($0.value) },
        identifier: "nodeDiscovery.summary.farthest"
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func highlight(
    _ highlight: NodeDiscoverySummary.Highlight?,
    title: String,
    systemImage: String,
    value: String?,
    identifier: String
  ) -> some View {
    let stat = ScanSummaryStat(title: title, systemImage: systemImage, value: value ?? "—", caption: highlight?.name ?? " ")
    if let highlight {
      Button {
        onSelect(highlight.key)
      } label: {
        stat
      }
      .buttonStyle(.plain)
      .accessibilityHint(L10n.Tools.Tools.NodeDiscovery.cardHint)
      .accessibilityIdentifier(identifier)
    } else {
      stat
    }
  }
}
