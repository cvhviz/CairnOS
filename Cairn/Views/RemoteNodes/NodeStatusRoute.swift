import Foundation
import CairnServices
import SwiftUI

/// History drill-downs pushed from the shared node status sections. Value-based so each
/// push rebuilds the destination instead of reusing stale `@State` from a prior visit.
enum NodeStatusRoute: Hashable {
  /// The node's one history page: radio, sensors, location and neighbours, from stored snapshots.
  case history(publicKey: Data, radioID: UUID, showNeighbors: Bool)
  case neighborChart(name: String, neighborPrefix: Data)
  /// A node at its latest fix. With its key, the GPS map opened on it, as its header map opens;
  /// without, a lone pin drawn as that node's (`pinStyle`, `avatar`).
  case locationMap(
    fix: NodeLocationFix,
    name: String?,
    pinStyle: MapPoint.PinStyle = .locationFixLatest,
    avatar: MapPinAvatar? = nil,
    publicKey: Data? = nil
  )
}

extension View {
  /// Registers the `NodeStatusRoute` destinations on the enclosing navigation stack,
  /// resolving each route against the host's `NodeStatusViewModel`. Apply to the `List`
  /// hosting the shared status sections, not to rows inside it.
  @MainActor
  func nodeStatusDestinations(helper: NodeStatusViewModel) -> some View {
    navigationDestination(for: NodeStatusRoute.self) { route in
      switch route {
      case let .history(publicKey, radioID, showNeighbors):
        TelemetryHistoryOverviewView(publicKey: publicKey, radioID: radioID, showNeighbors: showNeighbors)
      case let .neighborChart(name, neighborPrefix):
        NeighborSNRChartView(
          name: name,
          neighborPrefix: neighborPrefix,
          fetchSnapshots: helper.fetchHistory
        )
      case let .locationMap(fix, name, _, _, publicKey?):
        NodeOnMapView(
          focus: .node(publicKey: publicKey, coordinate: fix.coordinate),
          title: name ?? L10n.RemoteNodes.RemoteNodes.Status.locationMapTitle
        )
      case let .locationMap(fix, name, pinStyle, avatar, nil):
        NodeLocationMapView(
          points: [MapPoint(
            id: UUID(),
            coordinate: fix.coordinate,
            pinStyle: pinStyle,
            label: name,
            isClusterable: false,
            hopIndex: nil,
            badgeText: nil,
            avatar: avatar
          )],
          lines: [],
          reports: [:],
          title: L10n.RemoteNodes.RemoteNodes.Status.locationMapTitle,
          initialSelectionID: nil
        )
      }
    }
  }
}
