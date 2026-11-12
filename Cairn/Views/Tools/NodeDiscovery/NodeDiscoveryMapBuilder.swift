import CoreLocation
import MapKit
import CairnServices
import MeshCore
import SwiftUI

/// Builds the pins, SNR lines, and camera region for the discovery map from the rows the list
/// shows (the current scan's, and faded, the earlier ones Show Older adds). Every row is a direct
/// neighbour of this radio, so each located node is linked to where this radio was when it heard
/// the node best (`NodeDiscoveryResult.heardFrom`), with a line colored by that reception's SNR. A
/// node heard with no fresh fix is pinned without a line: lines show only what was measured,
/// never the phone's position now in place of where the node was heard. A relay hash that no
/// single node could be pinned on is never placed: it is counted with the nodes without a location.
enum NodeDiscoveryMapBuilder {
  struct Plotted {
    let points: [MapPoint]
    let lines: [MapLine]
    /// Tight bounds of the traces (where each was heard from, and every plotted node) with a
    /// minimum span, for the padded camera fit.
    let fitRegion: MKCoordinateRegion?
    /// Rows the map's Favorites / Discovered filter keeps off the map.
    let hiddenByFilterCount: Int
    /// Rows with no position to draw: no record places the node, or no single node is known.
    let unplacedCount: Int
    /// Node pin id → row key, for resolving taps back to a row.
    let keysByPointID: [UUID: Data]
    /// Where each plotted node sits, by row key, for centering on a selected result.
    let coordinatesByKey: [Data: CLLocationCoordinate2D]

    /// The pin drawn for `key`, if it is plotted.
    func pointID(for key: Data?) -> UUID? {
      guard let key, coordinatesByKey[key] != nil else { return nil }
      return NeighborSNRMapBuilder.stableID(role: .neighbor, key: key)
    }
  }

  /// Opacity of the traces, badges and pins of the nodes that are not selected, so the selected
  /// node's link reads at a glance without hiding where the others are.
  static let unselectedLineOpacity = 0.3
  static let unselectedPinOpacity = 0.55
  /// Opacity of a node heard only before the current scan (Show Older), as its card is faded.
  static let earlierLineOpacity = 0.25
  static let earlierPinOpacity = 0.4
  /// A node pinned at its saved contact's stored position, not one it advertised: a little faint.
  static let storedPinOpacity = 0.72

  /// - Parameters:
  ///   - contacts: Stored contacts by public key, for the favourite filter and the pin's avatar
  ///     (exact key only); never a position.
  ///   - discovered: Stored discovered-node records by public key; never a position.
  ///   - filter: The same Favorites / Discovered filter the Map tab offers.
  ///   - overridesFilter: Show every row whatever `filter` says (the "Show all" pill).
  ///   - selectedKey: The row open in the panel; the other nodes' traces are dimmed.
  static func build(
    results: [NodeDiscoveryResult],
    contacts: [Data: ContactDTO],
    discovered: [Data: DiscoveredNodeDTO],
    filter: MapFilterState,
    overridesFilter: Bool = false,
    selectedKey: Data? = nil
  ) -> Plotted {
    let filter = filter.sanitized(for: .nodeDiscovery)
    var points: [MapPoint] = []
    var keysByPointID: [UUID: Data] = [:]
    var coordinatesByKey: [Data: CLLocationCoordinate2D] = [:]
    var lines: [MapLine] = []
    var plottedCoordinates: [CLLocationCoordinate2D] = []
    var hiddenByFilterCount = 0
    var unplacedCount = 0

    for result in results {
      // An ambiguous or unknown relay could be any of several nodes, or none known: never pinned.
      guard result.isResolved, let publicKey = result.publicKey else {
        unplacedCount += 1
        continue
      }
      let contact = contacts[publicKey]
      if !overridesFilter {
        let isHidden = (filter.favoritesOnly && contact?.isFavorite != true)
          || (contact == nil && !filter.effectiveShowDiscovered)
        if isHidden {
          hiddenByFilterCount += 1
          continue
        }
      }

      guard let coordinate = coordinate(for: result) else {
        unplacedCount += 1
        continue
      }

      let key = result.key
      let isDimmed = selectedKey != nil && selectedKey != key
      // An earlier node stays faded unless it is the one picked
      let isEarlier = result.isEarlier && selectedKey != key
      let pinOpacity = isEarlier ? earlierPinOpacity : isDimmed ? unselectedPinOpacity
        : result.isStoredPosition ? storedPinOpacity : 1
      let lineOpacity = isEarlier ? earlierLineOpacity : isDimmed ? unselectedLineOpacity : 1
      let pointID = NeighborSNRMapBuilder.stableID(role: .neighbor, key: key)
      keysByPointID[pointID] = key
      coordinatesByKey[key] = coordinate
      points.append(MapPoint(
        id: pointID,
        coordinate: coordinate,
        pinStyle: pinStyle(for: result.nodeType),
        label: result.name,
        isClusterable: true,
        hopIndex: nil,
        badgeText: nil,
        opacity: pinOpacity,
        // The SNR of the reception its line is drawn from, so the pin, line and badge agree; the
        // smoothed SNR when no reception was placed.
        detail: MapLabelBadge.snrDetail(result.heardFrom?.snr ?? result.snr),
        isFavorite: contact?.isFavorite == true,
        avatar: contact.map(MapPinAvatar.init(contact:)) ?? MapPinAvatar(name: result.name)
      ))
      plottedCoordinates.append(coordinate)

      guard let heardFrom = result.heardFrom, heardFrom.coordinate.isValidFix else { continue }
      plottedCoordinates.append(heardFrom.coordinate)

      lines.append(MapLine(
        id: "discovery-\(key.uppercaseHexString())",
        coordinates: [heardFrom.coordinate, coordinate],
        style: .forSNR(heardFrom.snr),
        opacity: lineOpacity,
        pathIndex: nil
      ))
      var badge = MapLine.snrBadge(
        id: NeighborSNRMapBuilder.stableID(role: .badge, key: key),
        from: heardFrom.coordinate,
        to: coordinate,
        snr: heardFrom.snr
      )
      if lineOpacity < 1 { badge.opacity = lineOpacity }
      points.append(badge)
    }

    return Plotted(
      points: points,
      lines: lines,
      fitRegion: TraceCameraFit.region(fitting: plottedCoordinates),
      hiddenByFilterCount: hiddenByFilterCount,
      unplacedCount: unplacedCount,
      keysByPointID: keysByPointID,
      coordinatesByKey: coordinatesByKey
    )
  }

  /// A row's position: the one the node advertised in a packet this radio received
  /// (`NodeDiscoveryResult.coordinate`, from the ledger or the row's own advert), else its saved
  /// contact's stored one (`isStoredPosition`, drawn fainter: it may be stale, typed in or
  /// imported). The Traffic map pins the same key the same way. Nil for a row no single node
  /// could be pinned on.
  static func coordinate(for result: NodeDiscoveryResult) -> CLLocationCoordinate2D? {
    guard result.isResolved, result.publicKey != nil else { return nil }
    return result.coordinate.flatMap { $0.isValidFix ? $0 : nil }
  }

  static func pinStyle(for nodeType: UInt8) -> MapPoint.PinStyle {
    guard let type = ContactType(rawValue: nodeType) else { return .contactChat }
    return type == .repeater ? .repeater : type.pinStyle
  }
}

/// Where the map's camera starts when Scan & Traffic opens on its Nodes (`TrafficMapView`): on the
/// current position at the zoom the location button centers at (`AppState.userLocationSpan`), not
/// on the whole map.
/// The phone's fix comes first, then this radio's own position; with neither, the traces are
/// framed as before (or, with none, the camera is left alone).
enum NodeDiscoveryOpeningCamera {
  /// What the opening camera is on, best first.
  enum Source: Int, Comparable {
    case phone = 2
    case radio = 1
    case traces = 0
    /// Where the camera was when the page was last left, until a position is known.
    case saved = -1

    static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  struct Target {
    let source: Source
    let region: MKCoordinateRegion
  }

  /// - Parameters:
  ///   - phone: The phone's fix, when location is authorised and one is known.
  ///   - radio: The connected radio's own position, when it has one.
  ///   - traces: The region framing the plotted traces (`Plotted.fitRegion`).
  ///   - saved: The camera when the page was last left; with nothing else known, the page opens
  ///     there rather than on the map's whole-world start.
  static func target(
    phone: CLLocationCoordinate2D?,
    radio: CLLocationCoordinate2D?,
    traces: MKCoordinateRegion?,
    saved: MKCoordinateRegion? = nil,
    span: CLLocationDegrees = AppState.userLocationSpan
  ) -> Target? {
    let positionSpan = MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
    if let phone, phone.isValidFix {
      return Target(source: .phone, region: MKCoordinateRegion(center: phone, span: positionSpan))
    }
    if let radio, radio.isValidFix {
      return Target(source: .radio, region: MKCoordinateRegion(center: radio, span: positionSpan))
    }
    if let traces { return Target(source: .traces, region: traces) }
    return saved.map { Target(source: .saved, region: $0) }
  }

  /// Whether a new opening target moves the camera again after it opened: only while nothing has
  /// moved it since (`isAtOpeningCamera`), and only to a better source than the one it is on (no
  /// source counts as the traces), so a phone fix that keeps updating never moves it twice. On the
  /// last camera (or the map's start), the phone's or radio's position landing moves it.
  static func shouldRecenter(isAtOpeningCamera: Bool, current: Source?, new: Source?) -> Bool {
    guard isAtOpeningCamera, let new else { return false }
    return new > (current ?? .traces)
  }

  /// The widest a route fit may frame. Routes that would need more (a far relay on another
  /// continent, a node placed by a bad advert) open on the radio's surroundings instead, never on
  /// the whole world.
  static let maxRouteSpan: CLLocationDegrees = 20

  /// The packets' route fit, when it is worth taking: a region framing them no wider than
  /// `maxRouteSpan`. Nil when there's nothing to fit or it would be too wide.
  static func routeRegion(fitting coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
    let valid = coordinates.filter(\.isValidFix)
    if valid.count == 1 {
      return MKCoordinateRegion(center: valid[0], span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
    }
    guard let region = valid.boundingRegion(paddingMultiplier: 1.6),
          region.span.latitudeDelta <= maxRouteSpan, region.span.longitudeDelta <= maxRouteSpan else { return nil }
    return region
  }
}
