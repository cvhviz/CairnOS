import Foundation
import CairnServices

/// Sort order for the Add Hop picker's node sections. Recent stays in recency
/// order regardless; this orders the Favorites, Contacts, Discovered and Rooms sections.
enum HopPickerSortOrder: String, CaseIterable {
  case name
  case lastHeard

  var localizedTitle: String {
    switch self {
    case .name: L10n.Contacts.Contacts.Sort.name
    case .lastHeard: L10n.Contacts.Contacts.Sort.lastHeard
    }
  }

  /// Sorts picker nodes. Last Heard puts the most recently heard first and breaks
  /// ties by name, so nodes never heard still list alphabetically at the bottom.
  func sorted(_ nodes: [PickerNode]) -> [PickerNode] {
    switch self {
    case .name:
      nodes.sorted(by: Self.nameAscending)
    case .lastHeard:
      nodes.sorted { lhs, rhs in
        if lhs.lastHeardEpoch != rhs.lastHeardEpoch { return lhs.lastHeardEpoch > rhs.lastHeardEpoch }
        return Self.nameAscending(lhs, rhs)
      }
    }
  }

  private static func nameAscending(_ lhs: PickerNode, _ rhs: PickerNode) -> Bool {
    lhs.sortName.localizedCaseInsensitiveCompare(rhs.sortName) == .orderedAscending
  }
}

extension PickerNode {
  /// Name the picker lists the node under; discovered nodes sort by their resolvable name.
  var sortName: String {
    switch self {
    case let .contact(contact): contact.displayName
    case let .discovered(node): node.resolvableName
    }
  }

  /// When the node was last heard, in epoch seconds; 0 when never.
  var lastHeardEpoch: TimeInterval {
    switch self {
    case let .contact(contact): TimeInterval(contact.recencyTimestamp)
    case let .discovered(node): node.lastHeard.timeIntervalSince1970
    }
  }
}
