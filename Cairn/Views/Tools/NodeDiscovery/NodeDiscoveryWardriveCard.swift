import CairnServices
import SwiftUI

/// The drive in figures, at the top of the nodes while Wardrive runs and after it stops: the nodes
/// found so far, the scans sent, how long it has run and how far it went (from the fixes recorded
/// as it drove). Running, it offers Stop; stopped, its figures stay until dismissed, so the result
/// of a drive isn't lost the moment it ends.
struct NodeDiscoveryWardriveCard: View {
  let session: DiscoveryProbeCoordinator.WardriveSession
  /// The current scan's rows: the nodes the drive has heard.
  let nodeCount: Int
  let onStop: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    // Ticks each second while the drive runs, for its elapsed time; stopped, it holds still.
    TimelineView(.periodic(from: .now, by: session.isRunning ? 1 : 3600)) { context in
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "car.fill")
            .foregroundStyle(ToolSelection.nodeDiscovery.tileColor)
            .accessibilityHidden(true)
          Text(session.isRunning
            ? L10n.Tools.Tools.NodeDiscovery.wardriveRunning
            : L10n.Tools.Tools.NodeDiscovery.Wardrive.Summary.finished)
            .font(.subheadline.weight(.semibold))
          Spacer(minLength: 4)
          if session.isRunning {
            Button(L10n.Tools.Tools.NodeDiscovery.wardriveStop, systemImage: "stop.fill", action: onStop)
              .buttonStyle(.bordered)
              .buttonBorderShape(.capsule)
              .controlSize(.small)
              .tint(.red)
              .accessibilityIdentifier("nodeDiscovery.wardrive.card.stop")
          } else {
            Button(L10n.Tools.Tools.NodeDiscovery.Wardrive.Summary.dismiss, systemImage: "xmark", action: onDismiss)
              .labelStyle(.iconOnly)
              .buttonStyle(.bordered)
              .buttonBorderShape(.circle)
              .controlSize(.small)
              .accessibilityIdentifier("nodeDiscovery.wardrive.card.dismiss")
          }
        }
        HStack(alignment: .top, spacing: 8) {
          ScanSummaryStat(
            title: L10n.Tools.Tools.NodeDiscovery.Wardrive.Summary.nodes,
            systemImage: "antenna.radiowaves.left.and.right",
            value: nodeCount.formatted(),
            caption: nil
          )
          ScanSummaryStat(
            title: L10n.Tools.Tools.NodeDiscovery.Wardrive.Summary.probes,
            systemImage: "dot.radiowaves.left.and.right",
            value: session.probeCount.formatted(),
            caption: nil
          )
          ScanSummaryStat(
            title: L10n.Tools.Tools.NodeDiscovery.Wardrive.Summary.elapsed,
            systemImage: "timer",
            value: Self.elapsedText(session.elapsed(now: context.date)),
            caption: nil
          )
          ScanSummaryStat(
            title: L10n.Tools.Tools.NodeDiscovery.Wardrive.Summary.distance,
            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            value: NodeDiscoveryFormat.distance(session.distanceMeters),
            caption: nil
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("nodeDiscovery.wardrive.card")
    }
  }

  /// "12:34" under an hour, "1:02:03" from one on.
  static func elapsedText(_ elapsed: TimeInterval) -> String {
    let seconds = Int(elapsed.rounded(.down))
    return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
  }
}
