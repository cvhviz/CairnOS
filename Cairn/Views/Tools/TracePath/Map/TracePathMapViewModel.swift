import CoreLocation
import MapKit
import CairnServices
import os.log
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "TracePathMap")

/// View model for map-specific state in trace path map view
@Observable
@MainActor
final class TracePathMapViewModel {
  // MARK: - Map State

  var cameraRegion: MKCoordinateRegion?
  /// Incremented when code intentionally moves the camera (not from user gesture sync)
  private(set) var cameraRegionVersion = 0
  var showLabels: Bool = true {
    didSet { rebuildMapPoints() }
  }

  /// Tracks whether initial centering on repeaters has been performed
  private(set) var hasInitiallyCenteredOnRepeaters = false

  // MARK: - Path Overlays

  private(set) var mapLines: [MapLine] = []
  private(set) var badgePoints: [MapPoint] = []
  private(set) var mapPoints: [MapPoint] = []

  /// Discovered repeater pins currently plotted (for tap routing).
  private(set) var visibleDiscovered: [DiscoveredNodeDTO] = []

  /// Per-host filter snapshot; defaults seed Trace Path Discovered on.
  private(set) var currentFilter = MapFilterState.seed(for: .tracePath)

  // MARK: - Dependencies

  private weak var traceViewModel: TracePathViewModel?
  private var userLocation: CLLocation?
  private var lastRebuildLocation: CLLocation?

  // MARK: - Path State

  struct RepeaterPathInfo {
    let inPath: Bool
    let hopIndex: Int?
    let isLastHop: Bool
  }

  /// Path membership for contact candidates and in-path discovered nodes, keyed by pin ID.
  /// Stored to avoid reallocation on every body eval. Rebuilt via `rebuildPathState()`.
  private(set) var pathState: [UUID: RepeaterPathInfo] = [:]

  // MARK: - Computed Properties

  /// Repeaters and rooms to display on map
  var repeatersWithLocation: [ContactDTO] {
    traceViewModel?.availableNodes.filter(\.hasLocation) ?? []
  }

  /// Whether a path has been built (at least one hop)
  var hasPath: Bool {
    !(traceViewModel?.outboundPath.isEmpty ?? true)
  }

  /// Whether trace can be run (when connected)
  var canRunTrace: Bool {
    traceViewModel?.canRunTraceWhenConnected ?? false
  }

  /// Whether trace is currently running
  var isRunning: Bool {
    traceViewModel?.isRunning ?? false
  }

  /// Whether a successful result exists that can be saved
  var canSave: Bool {
    traceViewModel?.canSavePath ?? false
  }

  /// Current trace result
  var result: TraceResult? {
    traceViewModel?.result
  }

  // MARK: - Configuration

  func configure(traceViewModel: TracePathViewModel, userLocation: CLLocation?) {
    self.traceViewModel = traceViewModel
    self.userLocation = userLocation
  }

  func updateUserLocation(_ location: CLLocation?) {
    userLocation = location

    // Only rebuild if the path is non-empty and user moved meaningfully
    guard traceViewModel?.outboundPath.isEmpty == false else { return }
    if let location, let last = lastRebuildLocation, location.distance(from: last) < 10 { return }
    lastRebuildLocation = location
    rebuildOverlays()
  }

  // MARK: - Path State Rebuild

  /// Rebuilds stored `pathState` and `mapPoints`. Call when path, available nodes, or user location changes.
  func rebuildPathState() {
    let repeaters = repeatersWithLocation
    let discovered = traceViewModel?.discoveredRepeaters ?? []

    var pathLookup: [UUID: (index: Int, isLast: Bool)] = [:]
    let located = locatedOutboundPath()
    for (index, node) in located.enumerated() {
      if let node {
        pathLookup[node.id] = (index: index + 1, isLast: index == located.count - 1)
      }
    }

    var state: [UUID: RepeaterPathInfo] = [:]
    state.reserveCapacity(repeaters.count + discovered.count)
    for repeater in repeaters {
      if let info = pathLookup[repeater.id] {
        state[repeater.id] = RepeaterPathInfo(inPath: true, hopIndex: info.index, isLastHop: info.isLast)
      } else {
        state[repeater.id] = RepeaterPathInfo(inPath: false, hopIndex: nil, isLastHop: false)
      }
    }
    for node in discovered {
      if let info = pathLookup[node.id] {
        state[node.id] = RepeaterPathInfo(inPath: true, hopIndex: info.index, isLastHop: info.isLast)
      }
    }
    pathState = state
    rebuildMapPoints(repeaters: repeaters)
  }

  /// Rebuild annotations from the current path tables; does not reload contacts.
  func applyFilter(_ filter: MapFilterState) {
    currentFilter = filter.sanitized(for: .tracePath)
    rebuildMapPoints()
  }

  /// Contact candidates after Favorites / path-member rules.
  static func visibleContactPins(
    candidates: [ContactDTO],
    pathMemberIDs: Set<UUID>,
    filter: MapFilterState
  ) -> [ContactDTO] {
    if filter.favoritesOnly {
      return candidates.filter { $0.isFavorite || pathMemberIDs.contains($0.id) }
    }
    return candidates
  }

  /// Located discovered repeaters not already contacts, plus path-member hops that must stay visible.
  static func visibleDiscoveredPins(
    discovered: [DiscoveredNodeDTO],
    contactKeys: Set<Data>,
    pathMemberIDs: Set<UUID>,
    filter: MapFilterState
  ) -> [DiscoveredNodeDTO] {
    let pathMembers = discovered.filter {
      pathMemberIDs.contains($0.id) && $0.coordinate.isValidFix
    }
    // Favorites: only path-member discovered pins (never hide hops on the path).
    if filter.favoritesOnly {
      return pathMembers
    }
    guard filter.effectiveShowDiscovered else {
      // Discovered layer off: still keep path members so overlay/tap state stays complete.
      return pathMembers
    }
    var byID: [UUID: DiscoveredNodeDTO] = [:]
    for node in discovered where node.nodeType == .repeater
      && node.coordinate.isValidFix
      && !contactKeys.contains(node.publicKey) {
      byID[node.id] = node
    }
    for member in pathMembers {
      byID[member.id] = member
    }
    return Array(byID.values)
  }

  private var pathMemberIDs: Set<UUID> {
    Set(pathState.compactMap { $0.value.inPath ? $0.key : nil })
  }

  private func rebuildMapPoints(repeaters: [ContactDTO]? = nil) {
    let candidates = repeaters ?? repeatersWithLocation
    let nodes = Self.visibleContactPins(
      candidates: candidates,
      pathMemberIDs: pathMemberIDs,
      filter: currentFilter
    )
    var points: [MapPoint] = []
    for repeater in nodes {
      let info = pathState[repeater.id]
      let inPath = info?.inPath ?? false
      points.append(MapPoint(
        id: repeater.id,
        coordinate: repeater.coordinate,
        pinStyle: inPath ? .repeaterRingWhite : .repeater,
        label: showLabels ? repeater.displayName : nil,
        isClusterable: true,
        hopIndex: info?.hopIndex,
        badgeText: nil
      ))
    }

    let contactKeys = Set((traceViewModel?.availableNodes ?? []).map(\.publicKey))
    let discovered = Self.visibleDiscoveredPins(
      discovered: traceViewModel?.discoveredRepeaters ?? [],
      contactKeys: contactKeys,
      pathMemberIDs: pathMemberIDs,
      filter: currentFilter
    )
    visibleDiscovered = discovered
    for node in discovered {
      let info = pathState[node.id]
      let inPath = info?.inPath ?? false
      points.append(MapPoint(
        id: node.id,
        coordinate: node.coordinate,
        pinStyle: inPath ? .repeaterRingWhite : .repeater,
        label: showLabels ? node.name : nil,
        isClusterable: true,
        hopIndex: info?.hopIndex,
        badgeText: nil
      ))
    }

    points.append(contentsOf: badgePoints)
    mapPoints = points
  }

  // MARK: - Path Building

  /// Located contact or discovered node resolved for a path hop.
  private struct LocatedPathNode {
    let id: UUID
    let latitude: Double
    let longitude: Double
  }

  /// Where the trace leaves from and returns to: the connected radio, else the phone.
  private var startLocation: CLLocation? {
    traceViewModel?.radioLocation ?? userLocation
  }

  /// The outbound hops placed in order, each ranked near the one before it from this radio
  /// (`RouteChain`, as the Traffic map does); nil for a hop that can't be placed.
  private func locatedOutboundPath() -> [LocatedPathNode?] {
    let path = traceViewModel?.outboundPath ?? []
    var index = 0
    return RouteChain.place(
      path.map(\.hashBytes),
      from: startLocation?.coordinate,
      locate: { _, anchor in
        defer { index += 1 }
        return findLocatedPathNode(for: path[index], near: anchor?.location)
      },
      position: { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    ).map(\.stop)
  }

  /// Exact full-key across contacts and discovered first, then hash/proximity fallback
  /// (contacts still win over discovered on prefix-only matches; repeaters before rooms).
  /// When the hop carries a full key that matches a known identity, never fall through to
  /// hash-prefix matching — that would attach the hop to a different node on prefix collision.
  /// Nodes sharing a hash rank by distance to `anchor`, the hop before it.
  private func findLocatedPathNode(for hop: PathHop, near anchor: CLLocation?) -> LocatedPathNode? {
    let contacts = traceViewModel?.availableNodes ?? []
    let discovered = traceViewModel?.discoveredRepeaters ?? []

    if let key = hop.publicKey {
      let exactContact = contacts.first(where: { $0.publicKey == key })
      let exactDiscovered = discovered.first(where: { $0.publicKey == key })
      if exactContact != nil || exactDiscovered != nil {
        if let contact = exactContact, contact.hasLocation {
          return LocatedPathNode(
            id: contact.id,
            latitude: contact.latitude,
            longitude: contact.longitude
          )
        }
        if let node = exactDiscovered, node.coordinate.isValidFix {
          return LocatedPathNode(
            id: node.id,
            latitude: node.latitude,
            longitude: node.longitude
          )
        }
        return nil
      }
    }

    let repeaters = traceViewModel?.availableRepeaters ?? []
    let rooms = traceViewModel?.availableRooms ?? []
    let repeaterContact = RepeaterResolver.bestMatch(for: hop.hashBytes, in: repeaters, userLocation: anchor)
    let discoveredNode = RepeaterResolver.bestMatch(for: hop.hashBytes, in: discovered, userLocation: anchor)
    // A room server relays only when its repeat is on, so it takes a hash no repeater has.
    let roomContact = repeaterContact == nil && discoveredNode == nil
      ? RepeaterResolver.bestMatch(for: hop.hashBytes, in: rooms, userLocation: anchor)
      : nil
    if let contact = repeaterContact ?? roomContact, contact.hasLocation {
      return LocatedPathNode(id: contact.id, latitude: contact.latitude, longitude: contact.longitude)
    }
    if let node = discoveredNode, node.coordinate.isValidFix {
      return LocatedPathNode(id: node.id, latitude: node.latitude, longitude: node.longitude)
    }
    return nil
  }

  enum PathPinTapResult: Equatable {
    case added
    case removed
    case rejectedMiddleHop
    /// The trace is at its hop cap, so the pin was not added.
    case rejectedPathFull
    case ignored
  }

  /// Shared last-hop remove / middle reject / add for contact and discovered pins.
  private func handlePathPinTap(
    pointID: UUID,
    add: (TracePathViewModel) -> Void
  ) -> PathPinTapResult {
    guard let traceViewModel else { return .ignored }

    let info = pathState[pointID]
    let result: PathPinTapResult
    if info?.isLastHop == true {
      if let lastIndex = traceViewModel.outboundPath.indices.last {
        traceViewModel.removeRepeater(at: lastIndex)
      }
      result = .removed
    } else if info?.inPath != true {
      if traceViewModel.isPathFull {
        result = .rejectedPathFull
      } else {
        add(traceViewModel)
        result = .added
      }
    } else {
      result = .rejectedMiddleHop
    }

    rebuildOverlays()
    return result
  }

  @discardableResult
  func handleRepeaterTap(_ repeater: ContactDTO) -> PathPinTapResult {
    handlePathPinTap(pointID: repeater.id) { $0.addNode(repeater) }
  }

  /// Route a map pin tap to contact path edit or discovered add/remove hop.
  @discardableResult
  func handleMapPointTap(pointID: UUID) -> PathPinTapResult {
    let visibleContacts = Self.visibleContactPins(
      candidates: repeatersWithLocation,
      pathMemberIDs: pathMemberIDs,
      filter: currentFilter
    )
    if let contact = visibleContacts.first(where: { $0.id == pointID }) {
      return handleRepeaterTap(contact)
    }
    if let node = visibleDiscovered.first(where: { $0.id == pointID }) {
      return handlePathPinTap(pointID: node.id) { $0.addNode(node) }
    }
    return .ignored
  }

  /// Clear the path
  func clearPath() {
    traceViewModel?.clearPath()
    clearOverlays()
    rebuildPathState()
  }

  // MARK: - Trace Execution

  func runTrace() async {
    centerOnPath()
    traceViewModel?.batchEnabled = false
    await traceViewModel?.runTrace()
  }

  func savePath(name: String) async -> Bool {
    await traceViewModel?.savePath(name: name) ?? false
  }

  func generatePathName() -> String {
    traceViewModel?.generatePathName() ?? L10n.Contacts.Contacts.Trace.Map.defaultPathName
  }

  // MARK: - Overlay Management

  /// Contacts or discovered table changed: rebuild lines/pins and re-apply successful trace styles.
  func handleNodeTablesChanged() {
    rebuildOverlays()
    if !hasInitiallyCenteredOnRepeaters, !mapPoints.isEmpty {
      performInitialCentering()
    }
  }

  /// Rebuild map lines based on current path, then restore SNR styles/badges when a result exists.
  func rebuildOverlays() {
    clearOverlays()
    rebuildPathState()

    guard let traceViewModel,
          !traceViewModel.outboundPath.isEmpty else { return }

    // The whole round trip: out through each hop, back along the mirror when auto-return is
    // on, and home to this radio, which hears the last hop. Leg `i` ends at the node that
    // measured result hop `i + 1`'s SNR.
    let start = startLocation?.coordinate
    let outbound = locatedOutboundPath().map { node in
      node.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
    let route = outbound + (traceViewModel.autoReturnPath ? Array(outbound.reversed().dropFirst()) : []) + [start]

    var previousCoordinate = start
    var skippedHop = false
    for (leg, stop) in route.enumerated() {
      guard let coordinate = stop, CLLocationCoordinate2DIsValid(coordinate) else {
        skippedHop = true
        continue
      }
      if let previous = previousCoordinate, CLLocationCoordinate2DIsValid(previous),
         previous.latitude != coordinate.latitude || previous.longitude != coordinate.longitude {
        mapLines.append(MapLine(
          id: "trace-\(leg)",
          coordinates: [previous, coordinate],
          style: .traceUntraced,
          opacity: 1.0,
          // A line across a hop that couldn't be placed is no one link, so it never takes
          // the SNR the next hop measured.
          pathIndex: skippedHop ? nil : leg
        ))
      }
      previousCoordinate = coordinate
      skippedHop = false
    }

    // Late table loads and location rebuilds must not wipe SNR colors after a successful trace.
    updateOverlaysWithResults()
  }

  /// Update lines with trace results and add badge points at segment midpoints
  func updateOverlaysWithResults() {
    guard let result = traceViewModel?.result, result.success else { return }

    badgePoints.removeAll()

    // A link crossed both ways shows each reading toward the node that measured it.
    let segments = Set(mapLines.filter { $0.pathIndex != nil }.map { Self.segmentKey(of: $0) })
    var updatedLines: [MapLine] = []
    for line in mapLines {
      guard let pathIndex = line.pathIndex else {
        updatedLines.append(line)
        continue
      }
      let hopIndex = pathIndex + 1
      if hopIndex < result.hops.count {
        let hop = result.hops[hopIndex]
        let style = MapLine.LineStyle.forSNR(hop.snr)

        updatedLines.append(MapLine(
          id: line.id,
          coordinates: line.coordinates,
          style: style,
          opacity: 1.0,
          pathIndex: pathIndex
        ))

        // Badge at midpoint
        if line.coordinates.count >= 2 {
          badgePoints.append(MapLine.snrBadge(
            id: UUID(hopIndex: hopIndex),
            from: line.coordinates[0],
            to: line.coordinates[1],
            snr: hop.snr,
            towardReceiver: segments.contains(Self.segmentKey(of: line, reversed: true))
          ))
        }
      } else {
        updatedLines.append(line)
      }
    }

    mapLines = updatedLines
    rebuildMapPoints()
  }

  /// A line's ends as a comparable key, optionally swapped to find the leg back.
  private static func segmentKey(of line: MapLine, reversed: Bool = false) -> [Double] {
    let ends = reversed ? line.coordinates.reversed() : line.coordinates
    return ends.flatMap { [$0.latitude, $0.longitude] }
  }

  /// Clear all overlays
  func clearOverlays() {
    mapLines.removeAll()
    badgePoints.removeAll()
  }

  // MARK: - Camera

  /// Center map on all path points
  func centerOnPath() {
    var coordinates: [CLLocationCoordinate2D] = []

    if let startLocation {
      coordinates.append(startLocation.coordinate)
    }

    for line in mapLines {
      coordinates.append(contentsOf: line.coordinates)
    }

    setCameraRegion(fitting: coordinates)
  }

  /// Center map on the same filter-visible pin set as `rebuildMapPoints`: with this radio (or
  /// the phone) placed, on it and the repeaters nearest it (`nearbyFit`), else on all of them.
  func centerOnAllRepeaters() {
    var coordinates: [CLLocationCoordinate2D] = []

    let contacts = Self.visibleContactPins(
      candidates: repeatersWithLocation,
      pathMemberIDs: pathMemberIDs,
      filter: currentFilter
    )
    coordinates.append(contentsOf: contacts.map(\.coordinate))
    coordinates.append(contentsOf: visibleDiscovered.map(\.coordinate))

    if let start = startLocation?.coordinate, CLLocationCoordinate2DIsValid(start) {
      setCameraRegion(fitting: Self.nearbyFit(from: start, candidates: coordinates))
      hasInitiallyCenteredOnRepeaters = true
      return
    }

    guard !coordinates.isEmpty else {
      cameraRegion = nil
      return
    }

    setCameraRegion(fitting: coordinates)
    hasInitiallyCenteredOnRepeaters = true
  }

  /// How many of the nearest repeaters the opening view frames around this radio.
  static let nearbyCount = 6
  /// Repeaters past this far from this radio are left out of the opening view, unless none is
  /// nearer (then the closest one still is, so the view shows where the next hop would go).
  static let nearbyRadiusMeters: CLLocationDistance = 40000

  /// The opening view with no path yet: this radio and its neighbouring repeaters (the nearest
  /// `nearbyCount` within `nearbyRadiusMeters`, or the single nearest when none is that close),
  /// not every repeater on record, which can span a country.
  static func nearbyFit(
    from start: CLLocationCoordinate2D,
    candidates: [CLLocationCoordinate2D]
  ) -> [CLLocationCoordinate2D] {
    let here = CLLocation(latitude: start.latitude, longitude: start.longitude)
    let ranked = candidates
      .filter { CLLocationCoordinate2DIsValid($0) }
      .map { ($0, here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
      .sorted { $0.1 < $1.1 }
    var picked = ranked.prefix(nearbyCount).filter { $0.1 <= nearbyRadiusMeters }.map(\.0)
    if picked.isEmpty, let nearest = ranked.first { picked = [nearest.0] }
    return [start] + picked
  }

  /// Perform initial centering based on current state
  /// Centers on path if one exists, otherwise centers on all repeaters
  func performInitialCentering() {
    if hasPath {
      centerOnPathRepeaters()
    } else {
      centerOnAllRepeaters()
    }
  }

  /// Center map on path repeaters directly (doesn't depend on overlays)
  private func centerOnPathRepeaters() {
    guard traceViewModel != nil else {
      centerOnAllRepeaters()
      return
    }

    var coordinates: [CLLocationCoordinate2D] = []

    if let startLocation {
      coordinates.append(startLocation.coordinate)
    }

    for node in locatedOutboundPath() {
      guard let node else { continue }

      let coord = CLLocationCoordinate2D(
        latitude: node.latitude,
        longitude: node.longitude
      )
      if CLLocationCoordinate2DIsValid(coord) {
        coordinates.append(coord)
      }
    }

    guard !coordinates.isEmpty else {
      centerOnAllRepeaters()
      return
    }

    setCameraRegion(fitting: coordinates)
    hasInitiallyCenteredOnRepeaters = true
  }

  func setCameraRegion(_ region: MKCoordinateRegion) {
    cameraRegion = region
    cameraRegionVersion += 1
  }

  private func setCameraRegion(fitting coordinates: [CLLocationCoordinate2D]) {
    guard let region = coordinates.boundingRegion() else { return }
    setCameraRegion(region)
  }
}

private extension UUID {
  /// Deterministic UUID for badge points keyed by hop index.
  init(hopIndex: Int) {
    let hex = String(hopIndex, radix: 16)
    let padded = String(repeating: "0", count: max(0, 12 - hex.count)) + hex
    self = UUID(uuidString: "00000000-0000-0000-0000-\(padded)") ?? UUID()
  }
}
