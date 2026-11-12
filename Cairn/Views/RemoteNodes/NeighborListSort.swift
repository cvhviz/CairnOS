import CairnServices
import Foundation
import MeshCore

/// How the Neighbors page orders its list: the firmware's order is by when each was heard, but
/// for aiming an antenna the strongest first helps, and a long list wants names.
enum NeighborListSort: String, CaseIterable, Identifiable {
  /// Strongest signal first.
  case snr
  /// Most recently heard first (the firmware's order).
  case lastHeard
  case name
  /// Neighbours not in any earlier list first, then by signal.
  case newFirst

  var id: String { rawValue }

  var title: String {
    switch self {
    case .snr: L10n.RemoteNodes.RemoteNodes.Neighbors.Sort.snr
    case .lastHeard: L10n.RemoteNodes.RemoteNodes.Neighbors.Sort.lastHeard
    case .name: L10n.RemoteNodes.RemoteNodes.Neighbors.Sort.name
    case .newFirst: L10n.RemoteNodes.RemoteNodes.Neighbors.Sort.newFirst
    }
  }

  var systemImage: String {
    switch self {
    case .snr: "cellularbars"
    case .lastHeard: "clock"
    case .name: "textformat"
    case .newFirst: "sparkles"
    }
  }

  /// `name` gives each neighbour's shown name; `isNew` whether it's first-seen.
  func sorted(
    _ neighbors: [Neighbour],
    name: (Data) -> String,
    isNew: (Data) -> Bool = { _ in false }
  ) -> [Neighbour] {
    switch self {
    case .snr:
      return neighbors.sorted { lhs, rhs in
        if lhs.snr != rhs.snr { return lhs.snr > rhs.snr }
        return lhs.secondsAgo < rhs.secondsAgo
      }
    case .lastHeard:
      return neighbors.sorted { lhs, rhs in
        if lhs.secondsAgo != rhs.secondsAgo { return lhs.secondsAgo < rhs.secondsAgo }
        return lhs.snr > rhs.snr
      }
    case .name:
      return neighbors.sorted { lhs, rhs in
        let order = name(lhs.publicKeyPrefix).localizedCaseInsensitiveCompare(name(rhs.publicKeyPrefix))
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.snr > rhs.snr
      }
    case .newFirst:
      return neighbors.sorted { lhs, rhs in
        let lhsNew = isNew(lhs.publicKeyPrefix), rhsNew = isNew(rhs.publicKeyPrefix)
        if lhsNew != rhsNew { return lhsNew }
        if lhs.snr != rhs.snr { return lhs.snr > rhs.snr }
        return lhs.secondsAgo < rhs.secondsAgo
      }
    }
  }

  /// The neighbours whose name or key prefix contains `query` (case-insensitive); all of them for
  /// a blank query.
  static func filtered(_ neighbors: [Neighbour], query: String, name: (Data) -> String) -> [Neighbour] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return neighbors }
    return neighbors.filter { neighbor in
      name(neighbor.publicKeyPrefix).localizedCaseInsensitiveContains(trimmed)
        || neighbor.publicKeyPrefix.hexString.localizedCaseInsensitiveContains(trimmed)
    }
  }
}
