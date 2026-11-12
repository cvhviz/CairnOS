import MapKit
import CairnServices
import SwiftUI

/// ViewModel for map contact and discovered-node locations
@Observable
@MainActor
final class MapViewModel {
  // MARK: - Properties

  /// Unfiltered located contacts (all types / favorites). Display pins apply filter.
  private(set) var allLocatedContacts: [ContactDTO] = []

  /// Unfiltered plottable discovered (valid fix, not already contacts).
  private(set) var allLocatedDiscovered: [DiscoveredNodeDTO] = []

  /// Filter-visible contacts shown as pins (callout lookup + Center All).
  private(set) var visibleContacts: [ContactDTO] = []

  /// Filter-visible discovered nodes shown as pins.
  private(set) var visibleDiscovered: [DiscoveredNodeDTO] = []

  /// Public keys the user hid from this map. Hidden nodes stay in the unfiltered caches, so
  /// showing one again needs no fetch.
  private(set) var hiddenKeys: Set<Data> = []
  /// Nodes a Remove Nodes run is taking off the radio (`NodeRemovalModel.removingKeys`): off the
  /// map from the moment it starts. Not hidden nodes: they never join the Hidden Nodes list.
  private(set) var removingKeys: Set<Data> = []

  /// Located nodes left off the map because they are hidden, for the Hidden Nodes list.
  private(set) var hiddenNodes: [HiddenMapNode] = []

  /// Clock for the discovered-node recency window and fade; injectable for tests.
  var now: () -> Date = Date.init

  /// Map points derived from visible contacts and discovered nodes — stored to avoid reallocation on every body eval.
  private(set) var mapPoints: [MapPoint] = []
  /// Bumped whenever `mapPoints` changes, so a reader can key derived work on a number rather
  /// than comparing the whole array (the GPS page's map preview memoizes its nearby nodes on it).
  private(set) var mapPointsVersion = 0

  /// A user-dropped pin from a chat coordinate tap. Folded into `mapPoints` so it
  /// survives contact refreshes. Exactly one exists at a time (single-pin invariant).
  private(set) var focusedPin: MapPoint?

  /// Loading state
  var isLoading = false

  /// Error message if any
  var errorMessage: String?

  /// Camera region for map centering
  var cameraRegion: MKCoordinateRegion?

  /// Version counter for the camera region, incremented to signal a new camera target
  private(set) var cameraRegionVersion = 0

  var hasPinsForCenterAll: Bool {
    !visibleContacts.isEmpty || !visibleDiscovered.isEmpty
  }

  // MARK: - Dependencies

  private var dataStoreProvider: @MainActor () -> PersistenceStore? = { nil }
  private var radioIDProvider: @MainActor () -> UUID? = { nil }
  /// The connected radio's own public key. The map draws the radio as its own pin, so a stored
  /// record under that key is left out rather than drawn twice.
  private var radioKeyProvider: @MainActor () -> Data? = { nil }

  private var dataStore: PersistenceStore? {
    dataStoreProvider()
  }

  private var radioID: UUID? {
    radioIDProvider()
  }

  private static let reloadDebounce: Duration = .milliseconds(50)
  private var reloadTask: Task<Void, Never>?
  /// Latest filter requested while a coalesced reload is pending.
  private var pendingFilter = MapFilterState()
  /// Bumped so an older in-flight load cannot overwrite a newer one.
  private var loadGeneration = 0
  private var currentFilter = MapFilterState()
  /// After the first successful (or empty) load, type toggles re-filter without a full fetch.
  private(set) var hasCompletedInitialLoad = false
  /// Unit-test seam: next `loadMapData` throws after filter latches so the error path is covered.
  var simulateLoadFailureForTesting = false
  /// Unit-test seam: read `loadGeneration` so concurrent-load tests can wait until a load has entered.
  var loadGenerationForTesting: Int {
    loadGeneration
  }

  // MARK: - Initialization

  /// Stable id so the dropped pin does not churn across rebuilds and `onPointTap` can identify it.
  static let focusedPinID = UUID()

  /// Span for "exactly here" framing (about 1 km across).
  private static let focusSpan = 0.01

  init() {}

  /// Configure with the data store and radio this view model uses; a provider returning nil mirrors a disconnected state.
  func configure(
    dataStore: @escaping @MainActor () -> PersistenceStore?,
    radioID: @escaping @MainActor () -> UUID?,
    selfPublicKey: @escaping @MainActor () -> Data? = { nil }
  ) {
    dataStoreProvider = dataStore
    radioIDProvider = radioID
    radioKeyProvider = selfPublicKey
  }

  // MARK: - Load Map Data

  /// Load unfiltered located contacts and discovered rows, then apply `filter` for display pins.
  /// - Parameter showsLoadingChrome: true for first paint / user refresh only.
  ///   Coalesced live reloads pass false so the overlay and refresh spinner stay quiet.
  ///
  /// Loading chrome is owned by the current generation: start sets
  /// `isLoading = showsLoadingChrome`, stale early returns leave it alone, and only
  /// the current generation clears it on exit.
  func loadMapData(filter: MapFilterState, showsLoadingChrome: Bool = true) async {
    loadGeneration += 1
    let generation = loadGeneration
    let sanitized = filter.sanitized(for: .mainMap)
    // Latch so a later warm filter flip during this load wins at rebuild.
    pendingFilter = sanitized
    currentFilter = sanitized

    guard let dataStore, let radioID else {
      errorMessage = nil
      isLoading = false
      clearMapPinData()
      return
    }
    // Silent loads clear a spinner left by a superseded chrome load.
    isLoading = showsLoadingChrome
    errorMessage = nil
    do {
      if simulateLoadFailureForTesting {
        simulateLoadFailureForTesting = false
        throw MapLoadSimulationError()
      }
      let allContacts = try await dataStore.fetchContacts(radioID: radioID)
      guard generation == loadGeneration else { return }

      let radioKey = radioKeyProvider()
      let locatedContacts = allContacts.filter { $0.hasLocation && $0.publicKey != radioKey }

      // Always load discovered into the unfiltered cache so type/favorites re-filter is free.
      let allDiscovered = try await dataStore.fetchDiscoveredNodes(radioID: radioID)
      guard generation == loadGeneration else { return }
      let contactKeys = Set(allContacts.map(\.publicKey))
      let locatedDiscovered = allDiscovered.filter { node in
        node.coordinate.isValidFix && !contactKeys.contains(node.publicKey) && node.publicKey != radioKey
      }

      guard generation == loadGeneration else { return }
      allLocatedContacts = locatedContacts
      allLocatedDiscovered = locatedDiscovered
      hasCompletedInitialLoad = true
      currentFilter = pendingFilter
      rebuildDisplayPins()
    } catch {
      guard generation == loadGeneration else { return }
      currentFilter = pendingFilter
      rebuildDisplayPins()
      errorMessage = error.userFacingMessage
    }
    if generation == loadGeneration {
      isLoading = false
    }
  }

  /// Re-filter unfiltered caches without a SwiftData fetch.
  func applyFilter(_ filter: MapFilterState) {
    let sanitized = filter.sanitized(for: .mainMap)
    pendingFilter = sanitized
    currentFilter = sanitized
    rebuildDisplayPins()
  }

  /// Re-filter when caches are warm; full load when the first fetch has not completed.
  /// Always latches `pendingFilter` so a coalesced reload cannot overwrite a newer selection.
  func scheduleFilterChange(_ filter: MapFilterState) {
    let sanitized = filter.sanitized(for: .mainMap)
    pendingFilter = sanitized
    if !hasCompletedInitialLoad {
      scheduleCoalescedReload(filter: sanitized)
      return
    }
    applyFilter(sanitized)
  }

  /// Schedules a debounced full reload so bursts of version bumps trigger one load.
  /// Records the latest filter so a multi-dimension flip during the debounce
  /// window is not dropped.
  func scheduleCoalescedReload(filter: MapFilterState, showsLoadingChrome: Bool = false) {
    pendingFilter = filter.sanitized(for: .mainMap)
    guard reloadTask == nil else { return }
    reloadTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.reloadDebounce)
      guard let self, !Task.isCancelled else { return }
      self.reloadTask = nil
      let next = self.pendingFilter
      await self.loadMapData(
        filter: next,
        showsLoadingChrome: showsLoadingChrome
      )
    }
  }

  /// Cancels any pending coalesced reload (e.g. before a user-driven refresh).
  func cancelPendingReload() {
    reloadTask?.cancel()
    reloadTask = nil
    loadGeneration += 1
  }

  /// Re-filter for a changed set of hidden nodes without a SwiftData fetch.
  func setHiddenKeys(_ keys: Set<Data>) {
    guard keys != hiddenKeys else { return }
    hiddenKeys = keys
    rebuildDisplayPins()
  }

  /// Re-filter for the nodes a Remove Nodes run is taking off the radio, without a fetch.
  func setRemovingKeys(_ keys: Set<Data>) {
    guard keys != removingKeys else { return }
    removingKeys = keys
    rebuildDisplayPins()
  }

  private func clearMapPinData() {
    allLocatedContacts = []
    allLocatedDiscovered = []
    visibleContacts = []
    visibleDiscovered = []
    hiddenNodes = []
    hasCompletedInitialLoad = false
    rebuildMapPoints()
  }

  // MARK: - Display pin algebra

  /// Located contacts the filter shows. A hidden node is left out whatever the filter says,
  /// Favorites included.
  static func visibleContactPins(
    located: [ContactDTO],
    filter: MapFilterState,
    hiddenKeys: Set<Data>
  ) -> [ContactDTO] {
    located.filter { contact in
      guard !hiddenKeys.contains(contact.publicKey) else { return false }
      return filter.favoritesOnly ? contact.isFavorite : filter.allowsContactType(contact.type)
    }
  }

  /// Located discovered nodes the filter shows, leaving out the hidden ones.
  static func visibleDiscoveredPins(
    located: [DiscoveredNodeDTO],
    filter: MapFilterState,
    hiddenKeys: Set<Data>,
    now: Date
  ) -> [DiscoveredNodeDTO] {
    guard filter.effectiveShowDiscovered else { return [] }
    return located.filter { node in
      !hiddenKeys.contains(node.publicKey)
        && filter.allowsContactType(node.nodeType)
        && filter.heardWithin.includes(lastHeard: node.lastHeard, now: now)
    }
  }

  /// The hidden nodes among the located records, by name. The filter plays no part: a hidden
  /// node is listed even while its type or the discovered layer is switched off.
  static func resolvedHiddenNodes(
    contacts: [ContactDTO],
    discovered: [DiscoveredNodeDTO],
    hiddenKeys: Set<Data>
  ) -> [HiddenMapNode] {
    guard !hiddenKeys.isEmpty else { return [] }
    var nodes = contacts.filter { hiddenKeys.contains($0.publicKey) }.map {
      HiddenMapNode(publicKey: $0.publicKey, name: $0.displayName, type: $0.type, isDiscovered: false)
    }
    let contactKeys = Set(nodes.map(\.publicKey))
    nodes += discovered.filter {
      hiddenKeys.contains($0.publicKey) && !contactKeys.contains($0.publicKey)
    }.map {
      HiddenMapNode(publicKey: $0.publicKey, name: $0.name, type: $0.nodeType, isDiscovered: true)
    }
    return nodes.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      // Same-named nodes keep a fixed order, so rows do not swap between reloads.
      return order == .orderedSame
        ? $0.publicKey.lexicographicallyPrecedes($1.publicKey)
        : order == .orderedAscending
    }
  }

  private func rebuildDisplayPins() {
    let filter = currentFilter

    // Hidden nodes and nodes being removed alike stay off the map; only the hidden ones are
    // listed as hidden (below).
    let offMapKeys = hiddenKeys.union(removingKeys)
    visibleContacts = Self.visibleContactPins(
      located: allLocatedContacts,
      filter: filter,
      hiddenKeys: offMapKeys
    )
    visibleDiscovered = Self.visibleDiscoveredPins(
      located: allLocatedDiscovered,
      filter: filter,
      hiddenKeys: offMapKeys,
      now: now()
    )
    let hidden = Self.resolvedHiddenNodes(
      contacts: allLocatedContacts,
      discovered: allLocatedDiscovered,
      hiddenKeys: hiddenKeys
    )
    // Avoid force-assign when equal so the filter menu and list are not invalidated by reloads.
    if hidden != hiddenNodes {
      hiddenNodes = hidden
    }
    rebuildMapPoints()
  }

  // MARK: - Map Points

  private func rebuildMapPoints() {
    let now = now()
    var points: [MapPoint] = visibleContacts.map { contact in
      let lastHeard = (contact.lastHeardTimestamp ?? 0) > 0
        ? Date(timeIntervalSince1970: TimeInterval(contact.lastHeardTimestamp ?? 0))
        : nil
      return MapPoint(
        id: contact.id,
        coordinate: contact.coordinate,
        pinStyle: contact.type.pinStyle,
        label: contact.displayName,
        isClusterable: true,
        hopIndex: nil,
        badgeText: nil,
        detail: MapLabelBadge.ageDetail(lastHeard: lastHeard, now: now),
        isFavorite: contact.isFavorite,
        avatar: MapPinAvatar(contact: contact)
      )
    }
    let window = currentFilter.heardWithin
    points += visibleDiscovered.map { node in
      MapPoint(
        id: node.id,
        coordinate: node.coordinate,
        pinStyle: node.nodeType.discoveredPinStyle,
        label: node.name,
        isClusterable: true,
        hopIndex: nil,
        badgeText: nil,
        opacity: window.pinOpacity(lastHeard: node.lastHeard, now: now),
        detail: MapLabelBadge.ageDetail(lastHeard: node.lastHeard, now: now),
        avatar: MapPinAvatar(name: node.name)
      )
    }
    if let focusedPin {
      points.append(focusedPin)
    }
    // Avoid force-assign when equal so MapLibre can skip O(n) GeoJSON rebuild.
    if points != mapPoints {
      mapPoints = points
      mapPointsVersion &+= 1
    }
  }

  // MARK: - Lookup

  func contact(forPointID id: UUID) -> ContactDTO? {
    visibleContacts.first { $0.id == id }
  }

  func discovered(forPointID id: UUID) -> DiscoveredNodeDTO? {
    visibleDiscovered.first { $0.id == id }
  }

  /// The pin drawn for the node with this key: its contact's, else its discovered record's. Nil
  /// while it isn't on the map (filtered out, hidden, or without a location).
  func pointID(forPublicKey publicKey: Data) -> UUID? {
    visibleContacts.first { $0.publicKey == publicKey }?.id
      ?? visibleDiscovered.first { $0.publicKey == publicKey }?.id
  }

  // MARK: - Map Interaction

  func setCameraRegion(_ region: MKCoordinateRegion?) {
    cameraRegion = region
    cameraRegionVersion += 1
  }

  /// Zooms the camera one step in or out around its current center (the + and −
  /// map buttons). No-op until the map has reported a region.
  func zoom(_ direction: MapZoomStep.Direction) {
    guard let region = cameraRegion else { return }
    setCameraRegion(MapZoomStep.region(from: region, direction: direction))
  }

  /// Drop a distinct pin at `coordinate`, fold it into `mapPoints`, and center the camera on it.
  func focusOnCoordinate(_ coordinate: CLLocationCoordinate2D) {
    dropPin(at: coordinate)
    let span = MKCoordinateSpan(latitudeDelta: Self.focusSpan, longitudeDelta: Self.focusSpan)
    setCameraRegion(MKCoordinateRegion(center: coordinate, span: span))
  }

  /// Drop the pin at `coordinate` where the map is, without moving the camera: a long press on
  /// the map, which is already looking there. There is one dropped pin; this moves it.
  func dropPin(at coordinate: CLLocationCoordinate2D) {
    focusedPin = MapPoint(
      id: Self.focusedPinID,
      coordinate: coordinate,
      pinStyle: .droppedPin,
      label: nil,
      isClusterable: false,
      hopIndex: nil,
      badgeText: nil
    )
    rebuildMapPoints()
  }

  /// Center on a node that already has its own pin, at the same zoom a dropped pin gets.
  func focusOnNode(at coordinate: CLLocationCoordinate2D) {
    let span = MKCoordinateSpan(latitudeDelta: Self.focusSpan, longitudeDelta: Self.focusSpan)
    setCameraRegion(MKCoordinateRegion(center: coordinate, span: span))
  }

  /// Remove the dropped pin.
  func clearFocusedPin() {
    focusedPin = nil
    rebuildMapPoints()
  }

  func centerOnAllContacts() {
    var coordinates = visibleContacts.map(\.coordinate)
    coordinates += visibleDiscovered.map(\.coordinate)
    guard !coordinates.isEmpty else {
      cameraRegion = nil
      return
    }
    setCameraRegion(coordinates.boundingRegion())
  }

  /// On entering the map, restore the user's saved camera if present, otherwise frame all
  /// contacts. A focus or dropped-pin target sets `cameraRegion` synchronously before this
  /// runs, so a non-nil region or an existing pin means a target already owns the framing.
  func applyInitialCamera(saved: MKCoordinateRegion?, hasPendingFocus: Bool) {
    guard !hasPendingFocus, focusedPin == nil, cameraRegion == nil else { return }
    if let saved {
      setCameraRegion(saved)
    } else {
      centerOnAllContacts()
    }
  }
}

/// A node hidden from the Map tab, resolved to the stored record that names it.
struct HiddenMapNode: Identifiable, Equatable {
  let publicKey: Data
  let name: String
  let type: ContactType
  /// Heard on the mesh but not on the radio's node list.
  let isDiscovered: Bool

  var id: Data {
    publicKey
  }
}

/// Thrown only when `simulateLoadFailureForTesting` is set (unit tests).
private struct MapLoadSimulationError: Error, LocalizedError {
  var errorDescription: String? {
    "Simulated map load failure"
  }
}
