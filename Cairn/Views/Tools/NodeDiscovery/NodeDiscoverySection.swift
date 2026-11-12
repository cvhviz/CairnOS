import Foundation

/// The two lists under Scan & Traffic's live strip: the neighbours the current scan heard, or every
/// packet the radio hears (the Traffic list, with its filters). The map's camera follows the one
/// shown: the neighbours around the radio, or the routes the packets took.
enum NodeDiscoverySection: String, Hashable, CaseIterable {
  case nodes
  case packets
}

/// Where the map's camera goes when the page opens on, or switches to, a section. Kept pure so the
/// tests can pin the choice; the map works out the region for it.
enum NodeDiscoverySectionCamera: Equatable {
  /// The picked neighbour, at the current zoom, as Scan centers a card's node.
  case centerOnSelection
  /// Every neighbour's line and pin, as Scan frames them as replies land.
  case fitNeighbours
  /// Scan's opening camera: the phone, else this radio (`NodeDiscoveryOpeningCamera`).
  case opening
  /// The routes the packets took, as the Traffic map frames them.
  case fitRoutes

  /// - Parameters:
  ///   - hasSelection: A neighbour is picked and placed on the map.
  ///   - hasNeighbours: Some neighbour is placed on the map.
  static func target(for section: NodeDiscoverySection, hasSelection: Bool, hasNeighbours: Bool) -> Self {
    switch section {
    case .packets:
      .fitRoutes
    case .nodes:
      if hasSelection {
        .centerOnSelection
      } else if hasNeighbours {
        .fitNeighbours
      } else {
        .opening
      }
    }
  }
}

/// How many filters a section's Filter button shows on its badge: what differs from how the list
/// opens. Kept pure so the tests can pin the count.
enum NodeDiscoveryFilterBadge {
  /// The nodes: asking for sensors rather than repeaters, and a New / Contacts pick while those
  /// choices are offered.
  static func nodes(
    kind: NodeDiscoveryFilter,
    listFilter: NodeDiscoveryListFilter,
    chipsVisible: Bool,
    sortOrder: NodeDiscoverySortOrder = .snr
  ) -> Int {
    (kind == .repeaters ? 0 : 1) + (chipsVisible && listFilter != .all ? 1 : 0) + (sortOrder == .snr ? 0 : 1)
  }

  /// The packets: a route filter, a decrypt filter, a type filter, a sender, and Group Duplicates.
  static func packets(
    route: RxLogViewModel.RouteFilter,
    decrypt: RxLogViewModel.DecryptFilter,
    groupsDuplicates: Bool,
    type: RxLogViewModel.TypeFilter = .all,
    hasSender: Bool = false
  ) -> Int {
    (route == .all ? 0 : 1) + (decrypt == .all ? 0 : 1) + (groupsDuplicates ? 1 : 0) + (type == .all ? 0 : 1) + (hasSender ? 1 : 0)
  }
}

/// Where a phone's results sheet rests: covering the map (the list), sharing the screen with it,
/// or lowered to its header so the map has the screen.
enum NodeDiscoverySheetState: Equatable {
  case list
  case split
  case lowered
}

/// Where the sheet settles once a drag ends. Kept pure so the tests can pin it: the drag's
/// predicted end (its speed carries a flick on) picks the nearest resting place.
enum NodeDiscoverySheetSnap {
  /// The sheet's top, from the top of the space the map and sheet share.
  /// - Parameters:
  ///   - splitFraction: The map's share of the height when the two share the screen.
  ///   - loweredHeight: The lowered sheet's height (its header).
  static func top(of state: NodeDiscoverySheetState, height: CGFloat, splitFraction: CGFloat, loweredHeight: CGFloat) -> CGFloat {
    switch state {
    case .list: 0
    case .split: min(height * splitFraction, lowestTop(height: height, loweredHeight: loweredHeight))
    case .lowered: lowestTop(height: height, loweredHeight: loweredHeight)
    }
  }

  /// As low as the sheet goes: its header still showing.
  static func lowestTop(height: CGFloat, loweredHeight: CGFloat) -> CGFloat {
    max(0, height - loweredHeight)
  }

  /// How far the sheet follows a finger that moved `translation` from `state`: clamped between the
  /// list's top and the lowered sheet's.
  static func offset(
    from state: NodeDiscoverySheetState,
    translation: CGFloat,
    height: CGFloat,
    splitFraction: CGFloat,
    loweredHeight: CGFloat
  ) -> CGFloat {
    let start = top(of: state, height: height, splitFraction: splitFraction, loweredHeight: loweredHeight)
    let end = min(max(start + translation, 0), lowestTop(height: height, loweredHeight: loweredHeight))
    return end - start
  }

  /// The resting place nearest where the drag would have carried the sheet.
  static func target(
    from state: NodeDiscoverySheetState,
    predictedTranslation: CGFloat,
    height: CGFloat,
    splitFraction: CGFloat,
    loweredHeight: CGFloat
  ) -> NodeDiscoverySheetState {
    let start = top(of: state, height: height, splitFraction: splitFraction, loweredHeight: loweredHeight)
    let projected = start + predictedTranslation
    let places: [NodeDiscoverySheetState] = [.list, .split, .lowered]
    return places.min { lhs, rhs in
      abs(top(of: lhs, height: height, splitFraction: splitFraction, loweredHeight: loweredHeight) - projected)
        < abs(top(of: rhs, height: height, splitFraction: splitFraction, loweredHeight: loweredHeight) - projected)
    } ?? state
  }
}
