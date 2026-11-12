import CoreLocation
import CairnServices
import MeshCore
import OSLog
import SwiftUI

// MARK: - Filter & Sort

enum NodeDiscoveryFilter: String, CaseIterable {
  case repeaters
  case sensors

  var filterValue: UInt8 {
    switch self {
    case .repeaters: 0x04
    case .sensors: 0x10
    }
  }

  var localizedTitle: String {
    switch self {
    case .repeaters: L10n.Tools.Tools.NodeDiscovery.repeaters
    case .sensors: L10n.Tools.Tools.NodeDiscovery.sensors
    }
  }
}

enum NodeDiscoverySortOrder: String, CaseIterable {
  case snr
  case distance
  case name

  var localizedTitle: String {
    switch self {
    case .snr: L10n.Tools.Tools.NodeDiscovery.sortSignal
    case .distance: L10n.Tools.Tools.NodeDiscovery.sortDistance
    case .name: L10n.Tools.Tools.NodeDiscovery.sortName
    }
  }

  var systemImage: String {
    switch self {
    case .snr: "cellularbars"
    case .distance: "location.north.line"
    case .name: "textformat"
    }
  }
}

// MARK: - Result

/// One direct neighbour as Scan for Nodes lists it: a row of the radio's neighbour table, resolved
/// against the nodes this radio observed on its channel, named as the RX Log list names it.
struct NodeDiscoveryResult: Identifiable {
  /// The neighbour row: a full key, an 8-byte reply prefix, or a path hash.
  let id: NeighbourIdentity
  var name: String
  /// False while `name` is a placeholder ("Unknown (hex)", "Unidentified relay 3A7F21"): nothing
  /// names this node yet.
  var isNamed: Bool
  /// The node's key when the row names exactly one node: its full key, or the 8-byte prefix of a
  /// prefix-only reply until the full key is heard. Nil for a relay hash that could be several
  /// nodes or none known.
  let publicKey: Data?
  /// 1 chat, 2 repeater, 3 room, 4 sensor.
  let nodeType: UInt8
  /// This radio's smoothed SNR for the node's transmissions, every source merged.
  let snr: Double
  let rssi: Int
  let scanFilter: NodeDiscoveryFilter
  /// When the node was last heard, by any source.
  let receivedAt: Date
  /// Where this radio was when the node was heard best, with that reception's SNR. Nil when it was
  /// never heard with a fresh fix: the node is still listed and pinned, but gets no line.
  var heardFrom: NodeDiscoveryHeardFrom?
  /// The node's advertised position, from its stored records or its own advert.
  var coordinate: CLLocationCoordinate2D?
  /// Which node the row names: one, one of several, or none known.
  let resolution: NeighbourResolution
  /// Where its receptions came from, for the card's badges.
  let sources: Set<NeighbourSourceKind>
  /// False for a relay heard only once ("Heard once"), shown dimmed.
  let isConfirmed: Bool
  let freshness: NeighbourFreshness
  /// How well the node hears this radio, from a reply to our own scan or a link check; nil until
  /// one measured it.
  let uplinkSNR: Double?
  /// The node proved it hears this radio (answered our scan or a link check) in the last 24 hours.
  let hearsYou: Bool
  /// For a row no single observed node could be pinned on: the saved or discovered nodes sharing
  /// its hash that were never heard on this channel, and the ones not heard lately. The card's
  /// "Not heard on this channel: Kona Hill shares this prefix" lines; never the row's name.
  var unobservedSharers: [UnobservedSharer]
  /// Heard only before the current scan started (listed with Show Older, apart and faded); false
  /// for the scan's own rows.
  let isEarlier: Bool
  /// The position is the saved contact's stored one, not one the node advertised in a packet this
  /// radio received: drawn fainter, since a stored position can be stale, typed in or imported.
  let isStoredPosition: Bool

  init(
    id: NeighbourIdentity? = nil,
    name: String,
    isNamed: Bool = true,
    publicKey: Data?,
    nodeType: UInt8,
    snr: Double,
    rssi: Int,
    scanFilter: NodeDiscoveryFilter,
    receivedAt: Date,
    heardFrom: NodeDiscoveryHeardFrom? = nil,
    coordinate: CLLocationCoordinate2D? = nil,
    resolution: NeighbourResolution? = nil,
    sources: Set<NeighbourSourceKind> = [],
    isConfirmed: Bool = true,
    freshness: NeighbourFreshness = .live,
    uplinkSNR: Double? = nil,
    hearsYou: Bool = false,
    unobservedSharers: [UnobservedSharer] = [],
    isEarlier: Bool = false,
    isStoredPosition: Bool = false
  ) {
    // A row built from a key alone (tests, previews) names that node.
    self.id = id ?? .fullKey(publicKey ?? Data())
    self.name = name
    self.isNamed = isNamed
    self.publicKey = publicKey
    self.nodeType = nodeType
    self.snr = snr
    self.rssi = rssi
    self.scanFilter = scanFilter
    self.receivedAt = receivedAt
    self.heardFrom = heardFrom
    self.coordinate = coordinate
    if let resolution {
      self.resolution = resolution
    } else if let publicKey {
      self.resolution = .resolved(NeighbourKeyEntry(publicKey: publicKey, nodeTypeRaw: nodeType))
    } else {
      self.resolution = .unknown(id?.bytes ?? Data())
    }
    self.sources = sources
    self.isConfirmed = isConfirmed
    self.freshness = freshness
    self.uplinkSNR = uplinkSNR
    self.hearsYou = hearsYou
    self.unobservedSharers = unobservedSharers
    self.isEarlier = isEarlier
    self.isStoredPosition = isStoredPosition
  }

  /// The row's stable key, for selection, map pins and list identity: the node's key when the row
  /// names one, else the hash. It survives the row's evidence growing (a hash row joined by the
  /// node's advert keeps its key).
  var key: Data {
    publicKey ?? id.bytes
  }

  /// The row names one node.
  var isResolved: Bool {
    resolution.isResolved
  }

  /// The row names one node by its whole key: the only kind that can be added, named or stored.
  var hasFullKey: Bool {
    publicKey?.count == ProtocolLimits.publicKeySize
  }

  /// The nodes an ambiguous relay could be, likeliest first, and how many there are in all.
  var candidates: (entries: [NeighbourKeyEntry], total: Int)? {
    if case let .ambiguous(entries, total) = resolution { (entries, total) } else { nil }
  }
}

// MARK: - View Model

extension NodeDiscoveryViewModel.Dependencies {
  /// Reads everything from the app's current connection and its shared neighbour directory and
  /// probe coordinator.
  @MainActor
  static func live(appState: AppState) -> Self {
    Self(
      directory: { [appState] in
        #if DEBUG && targetEnvironment(simulator)
          if NodeDiscoveryViewModel.isDemo { return NodeDiscoveryViewModel.demoDirectory }
        #endif
        return appState.neighbourDirectory
      },
      coordinator: { [appState] in appState.probeCoordinator },
      currentScan: { [appState] in
        #if DEBUG && targetEnvironment(simulator)
          if NodeDiscoveryViewModel.isDemo { return NodeDiscoveryViewModel.demo.scan }
        #endif
        return appState.probeCoordinator.currentScan
      },
      observations: { [appState] in
        #if DEBUG && targetEnvironment(simulator)
          if NodeDiscoveryViewModel.isDemo { return nil }
        #endif
        return appState.observationDirectory
      },
      isConnected: { [appState] in appState.services?.session != nil },
      dataStore: { [appState] in appState.offlineDataStore },
      radioID: { [appState] in appState.connectedDevice?.radioID },
      contactService: { [appState] in appState.services?.contactService },
      maxContacts: { [appState] in appState.connectedDevice?.maxContacts },
      nameResolver: { [appState] in
        #if DEBUG && targetEnvironment(simulator)
          if NodeDiscoveryViewModel.isDemo {
            return NodeNameResolver(dependencies: .simulated)
          }
        #endif
        guard let session = appState.services?.session else { return nil }
        let radioAddsTemporaryContact = appState.connectedDevice?.supportsAdHocRepeaterRequest ?? false
        return NodeNameResolver(dependencies: .live(
          session: session,
          radioAddsTemporaryContact: radioAddsTemporaryContact
        ))
      },
      supportsNameRequests: { [appState] in
        #if DEBUG && targetEnvironment(simulator)
          if NodeDiscoveryViewModel.isDemo { return true }
        #endif
        return NodeDiscoveryViewModel.supportsNameRequests(device: appState.connectedDevice)
      },
      traceHashSize: { [appState] in appState.connectedDevice?.traceHashSize },
      onNodesChanged: { [appState] in appState.noteDiscoveredNodesChanged() },
      isLocationDenied: { [appState] in appState.locationService.isLocationDenied },
      batteryPercent: {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        guard device.batteryLevel >= 0 else { return nil }
        return Int((device.batteryLevel * 100).rounded())
      },
      isLowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled },
      hasSeenWardriveNote: { UserDefaults.standard.bool(forKey: AppStorageKey.hasSeenWardriveNote.rawValue) },
      markWardriveNoteSeen: { UserDefaults.standard.set(true, forKey: AppStorageKey.hasSeenWardriveNote.rawValue) }
    )
  }
}

/// What to say before Wardrive starts, in the order asked: that location is refused (the nodes
/// won't be placed on the map), the first-run note (the screen stays on, GPS runs in the
/// background), a low battery, Low Power Mode. Pure, so the tests can pin the order.
enum WardrivePrompt: Hashable {
  case locationDenied
  case firstRun
  case lowBattery(percent: Int)
  case lowPowerMode

  /// Below this the battery is worth a word before the screen and GPS stay on.
  static let lowBatteryPercent = 20

  /// The first prompt due that isn't in `acknowledged`; nil when Wardrive may start.
  static func next(
    locationDenied: Bool,
    hasSeenNote: Bool,
    batteryPercent: Int?,
    lowPowerMode: Bool,
    acknowledged: Set<WardrivePrompt>
  ) -> WardrivePrompt? {
    var due: [WardrivePrompt] = []
    if locationDenied { due.append(.locationDenied) }
    if !hasSeenNote { due.append(.firstRun) }
    if let batteryPercent, batteryPercent < lowBatteryPercent { due.append(.lowBattery(percent: batteryPercent)) }
    if lowPowerMode { due.append(.lowPowerMode) }
    return due.first { !acknowledged.contains($0) }
  }
}

/// Scan for Nodes as a projection of the radio's neighbour table: the rows `NeighbourDirectory`
/// holds, resolved against what this radio observed on its channel and labelled by the stored
/// records for exactly their keys, and the probe state `DiscoveryProbeCoordinator` runs.
///
/// The list is the current scan's (`DiscoveryProbeCoordinator.currentScan`): a time cut over the
/// table at the moment the scan started (`NeighbourDirectory.scanList`). A scan empties it, and it
/// fills with what the radio hears from then on, answers to the scan and any other traffic, until
/// the next scan starts. Show Older adds the rows heard before it in the last 24 hours, apart and
/// faded. Before the first scan nothing is listed but those. Probes and Wardrive belong to the
/// coordinator, so leaving the screen or switching the list's kind ends neither, and the list
/// shown on coming back is still the last scan's.
@Observable
@MainActor
final class NodeDiscoveryViewModel {
  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodeDiscoveryViewModel")
  /// How long after a probe goes out before names are requested over the air. Replies to the probe
  /// arrive spread over the first few seconds, and a request sent among them collides on air.
  static let nameRequestDelay: TimeInterval = 5
  /// Most name requests one probe sends. Each is a round trip on a shared channel, and a node
  /// named once is stored, so later probes only ask for newcomers.
  static let maxNameRequestsPerScan = 8
  /// How often the name loop looks for a row to name when there was nothing to do.
  static let namePollInterval: Duration = .milliseconds(500)

  // MARK: - Published state

  var errorMessage: String?
  var filter: NodeDiscoveryFilter = .repeaters
  var sortOrder: NodeDiscoverySortOrder = .snr
  /// Also list the rows heard before the current scan started, in the last 24 hours.
  var showsOlder = false
  /// The row open in the panel and highlighted on the map, by its key (`NodeDiscoveryResult.key`).
  /// The map and the results panel both read and set it, so a tap on either side selects on the
  /// other.
  var selectedKey: Data?
  /// The cooldown's explainer is open, after a tap on the waiting scan button.
  var showsCooldownReason = false

  var scanStartHapticTrigger = 0

  /// Nodes whose name is being looked up right now.
  private(set) var resolvingNameKeys: Set<Data> = []

  var addedPublicKeys: Set<Data> = []
  var addingPublicKey: Data?
  var addSuccessHapticTrigger = 0
  var addErrorHapticTrigger = 0

  // MARK: - Dependencies

  struct Dependencies {
    /// The neighbour rows to list; nil lists nothing.
    var directory: @MainActor () -> NeighbourDirectory?
    /// Runs probes and Wardrive; nil can't probe.
    var coordinator: @MainActor () -> DiscoveryProbeCoordinator? = { nil }
    /// The scan whose list is shown; nil before the first scan.
    var currentScan: @MainActor () -> DiscoveryProbeCoordinator.Scan? = { nil }
    /// What this radio observed on its channel, for the "not heard on this channel" lines of a
    /// row no observed node could be pinned on; nil gives none.
    var observations: @MainActor () -> ObservationDirectory? = { nil }
    var isConnected: @MainActor () -> Bool = { false }
    var dataStore: @MainActor () -> PersistenceStore?
    var radioID: @MainActor () -> UUID?
    var contactService: @MainActor () -> ContactService?
    var maxContacts: @MainActor () -> UInt16?
    var nameResolver: @MainActor () -> NodeNameResolver? = { nil }
    /// Whether the radio can send a name request to a node that is not one of its contacts
    /// (``NodeDiscoveryViewModel/supportsNameRequests(device:)``).
    var supportsNameRequests: @MainActor () -> Bool = { false }
    /// How many bytes of a key the radio's trace paths carry; nil while disconnected.
    var traceHashSize: @MainActor () -> Int? = { nil }
    /// A name was stored as a discovered node: Home and Contacts > Heard reload.
    var onNodesChanged: @MainActor () -> Void = {}
    /// The clock freshness is measured against; tests inject a fake one.
    var now: @MainActor () -> Date = { Date() }
    /// Location is refused or restricted: Wardrive says so before it starts.
    var isLocationDenied: @MainActor () -> Bool = { false }
    /// The phone's battery, 0 to 100; nil when unknown.
    var batteryPercent: @MainActor () -> Int? = { nil }
    var isLowPowerMode: @MainActor () -> Bool = { false }
    /// The first-run note on what Wardrive does to the screen and GPS has been shown.
    var hasSeenWardriveNote: @MainActor () -> Bool = { true }
    var markWardriveNoteSeen: @MainActor () -> Void = {}
  }

  /// What Wardrive has to say before it starts; the page shows it as an alert.
  var wardrivePrompt: WardrivePrompt?
  /// The prompts answered since Start was tapped, so each is asked once per start.
  private var acknowledgedWardrivePrompts: Set<WardrivePrompt> = []

  /// The Wardrive running, or the last one until it is dismissed.
  var wardriveSession: DiscoveryProbeCoordinator.WardriveSession? {
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo { return Self.demo.session }
    #endif
    return coordinator?.wardriveSession
  }

  /// Takes a finished Wardrive's figures off the screen.
  func dismissWardriveSummary() {
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo {
        if !Self.demo.isWardriving { Self.demo.session = nil }
        return
      }
    #endif
    coordinator?.dismissWardriveSession()
  }

  /// How many contacts the radio holds at most; nil while disconnected.
  var contactSlotLimit: Int? {
    maxContacts.map(Int.init)
  }

  /// How many contacts the radio holds now, as far as the stored records say.
  var contactCount: Int {
    contactsByKey.count
  }

  /// Reloads stored contacts and discovered nodes, e.g. after a node is added elsewhere.
  func refreshStoredRecords() async {
    guard let radioID else { return }
    await loadNameResolutionData(radioID: radioID)
  }

  /// Whether unnamed nodes can be asked for their name over the air.
  var canRequestNames: Bool {
    deps.supportsNameRequests() && deps.nameResolver() != nil
  }

  /// Whether `device` can ask a node for its name: the request goes out as an anonymous request
  /// (`CMD_SEND_ANON_REQ`), which official companion firmware has from v1.12. Older radios answer
  /// it unsupported, so nothing is asked. False while disconnected.
  static func supportsNameRequests(device: DeviceDTO?) -> Bool {
    device?.supportsAnonymousRequests ?? false
  }

  /// Where names come from, for the scan's info text: stored adverts, and a request to the node
  /// where the radio can send one, else the firmware that needs, or a connected radio.
  var namesInfo: String {
    if !isConnected { return L10n.Tools.Tools.NodeDiscovery.namesFooterDisconnected }
    return canRequestNames
      ? L10n.Tools.Tools.NodeDiscovery.namesFooter
      : L10n.Tools.Tools.NodeDiscovery.namesFooterNeedsFirmware
  }

  /// Asks one node for its name now, outside a probe (the row's Request Name button). Does nothing
  /// where the radio can't ask.
  func requestName(for publicKey: Data) {
    guard canRequestNames, !resolvingNameKeys.contains(publicKey), let resolver = deps.nameResolver(), let radioID else { return }
    attemptedNameKeys.insert(publicKey)
    Task { [weak self] in
      await self?.resolveName(for: publicKey, with: resolver, overTheAir: true, radioID: radioID)
    }
  }

  private var deps = Dependencies(
    directory: { nil },
    dataStore: { nil },
    radioID: { nil },
    contactService: { nil },
    maxContacts: { nil }
  )

  private var directory: NeighbourDirectory? {
    deps.directory()
  }

  var coordinator: DiscoveryProbeCoordinator? {
    deps.coordinator()
  }

  var isConnected: Bool {
    deps.isConnected()
  }

  private var dataStore: PersistenceStore? {
    deps.dataStore()
  }

  private var radioID: UUID? {
    deps.radioID()
  }

  private var contactService: ContactService? {
    deps.contactService()
  }

  private var maxContacts: UInt16? {
    deps.maxContacts()
  }

  /// How many bytes of a key the radio's trace paths carry, for Check Link.
  var traceHashSize: Int? {
    deps.traceHashSize()
  }

  // MARK: - Tasks

  private var nameTask: Task<Void, Never>?
  /// The radio the caches below belong to.
  private var resultsRadioID: UUID?
  /// Nodes already looked up in the radio's contact table, so each is asked once.
  private var lookedUpNameKeys: Set<Data> = []
  /// Nodes already asked over the air, so a later probe does not ask a silent node again.
  private var attemptedNameKeys: Set<Data> = []
  /// When the probe the name requests below belong to went out.
  private var nameProbeSentAt: Date?
  /// Name requests sent for that probe.
  private var nameRequestsThisProbe = 0

  /// A view model dropped while Wardrive keeps the screen on gives the screen back: Wardrive runs
  /// on in the coordinator, but nothing here can let the screen sleep after it stops.
  isolated deinit {
    nameTask?.cancel()
    if deps.coordinator()?.isWardriving == true {
      UIApplication.shared.isIdleTimerDisabled = false
    }
  }

  // MARK: - Name resolution cache

  /// Stored names by whole key: a contact's, a discovered node's, or one a name request returned.
  /// A name labels only a row resolved to exactly its key.
  private var namesByKey: [Data: String] = [:]
  /// Stored contacts and discovered nodes by full public key, for map placement and callouts.
  private(set) var contactsByKey: [Data: ContactDTO] = [:]

  /// Saved contacts' stored positions by full key, where they have a real one: a heard node
  /// that advertised no position is pinned at its saved one (`NodeDiscoveryResult.isStoredPosition`).
  var storedPositionsByKey: [Data: CLLocationCoordinate2D] {
    contactsByKey.compactMapValues { contact in
      guard contact.hasLocation else { return nil }
      let coordinate = CLLocationCoordinate2D(latitude: contact.latitude, longitude: contact.longitude)
      return coordinate.isValidFix ? coordinate : nil
    }
  }
  private(set) var discoveredByKey: [Data: DiscoveredNodeDTO] = [:]

  // MARK: - Configuration

  /// Configure with the directory, coordinator, store, and services this view model uses; a
  /// provider returning nil mirrors a disconnected state.
  func configure(dependencies: Dependencies) {
    deps = dependencies
    resetIfRadioChanged()
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo, let radioID { seedDemoIfNeeded(radioID: radioID) }
    #endif
    if let radioID {
      Task { [weak self] in await self?.loadNameResolutionData(radioID: radioID) }
    }
    startNameResolution()
  }

  /// Drops everything learned from another radio: its neighbours are not this radio's.
  private func resetIfRadioChanged() {
    guard let radioID, radioID != resultsRadioID else { return }
    resultsRadioID = radioID
    selectedKey = nil
    lookedUpNameKeys.removeAll()
    attemptedNameKeys.removeAll()
    nameProbeSentAt = nil
    namesByKey.removeAll()
    contactsByKey.removeAll()
    discoveredByKey.removeAll()
    addedPublicKeys.removeAll()
  }

  // MARK: - Results

  /// The scan whose list is shown, when it belongs to the radio whose neighbours are shown; nil
  /// before the first scan.
  var currentScan: DiscoveryProbeCoordinator.Scan? {
    guard let scan = deps.currentScan() else { return nil }
    if let shown = directory?.snapshot?.radioID, shown != scan.radioID { return nil }
    return scan
  }

  /// When the scan whose list is shown started; nil before the first scan.
  var scanStartedAt: Date? {
    currentScan?.startedAt
  }

  /// The rows of the kind being listed: the current scan's (heard since it started), most recently
  /// heard first, then with ``showsOlder`` the ones heard only before it in the last 24 hours,
  /// flagged ``NodeDiscoveryResult/isEarlier``.
  var results: [NodeDiscoveryResult] {
    guard let directory else { return [] }
    let now = deps.now()
    let scanStart = scanStartedAt
    let list = directory.scanList(filter, since: scanStart, includeEarlier: showsOlder, now: now)
    let hints = deps.observations()?.nodeIndex
    let stored = storedPositionsByKey
    return Self.makeResults(list.current, filter: filter, storedNames: namesByKey, hints: hints, scanStart: scanStart, storedPositions: stored, now: now)
      + Self.makeResults(list.earlier, filter: filter, storedNames: namesByKey, hints: hints, isEarlier: true, storedPositions: stored, now: now)
  }

  /// How many rows of the kind listed were heard only before the current scan, in the last 24
  /// hours: what ``showsOlder`` adds, counted for the row that offers them.
  var olderCount: Int {
    guard let directory else { return 0 }
    return directory.scanList(filter, since: scanStartedAt, includeEarlier: true, now: deps.now()).earlier.count
  }

  /// The current scan's own rows: ``results`` without the earlier ones.
  var currentResults: [NodeDiscoveryResult] {
    results.filter { !$0.isEarlier }
  }

  /// ``results`` in ``sortOrder``, the current scan's first, rows no single node could be pinned
  /// on last within each.
  var sortedResults: [NodeDiscoveryResult] {
    Self.sorted(results, by: sortOrder)
  }

  /// Nothing of the kind is listed.
  var isEmpty: Bool {
    results.isEmpty
  }

  /// The listed rows built from the directory's neighbours. A stored name (a contact's wins over a
  /// discovered node's) goes before what the node advertised, but only for a row resolved to
  /// exactly its key: a hash row no observed node could be pinned on shows its hash, one several
  /// could be the likeliest's name with a "?", never a saved node sharing the hash. `hints`, the
  /// current channel's index, lists those saved nodes for the row's card.
  ///
  /// - Parameters:
  ///   - scanStart: When the current scan started: a row of that scan shows only the evidence it
  ///     heard since (badges, "Hears you", the uplink reading, and the spot it was heard from, so
  ///     its map line and distance), so "Answered your scan" means this scan. Nil shows all of it.
  ///   - isEarlier: The rows were heard only before the current scan (Show Older).
  ///   - storedPositions: Saved contacts' stored positions by full key, for a node that advertised
  ///     none in a packet this radio received: it is pinned there, marked as stored.
  static func makeResults(
    _ neighbours: [ResolvedNeighbour],
    filter: NodeDiscoveryFilter,
    storedNames: [Data: String],
    hints: PacketNodeIndex? = nil,
    scanStart: Date? = nil,
    isEarlier: Bool = false,
    storedPositions: [Data: CLLocationCoordinate2D] = [:],
    now: Date
  ) -> [NodeDiscoveryResult] {
    neighbours.map { neighbour in
      let record = neighbour.record
      let key = neighbour.resolution.entry?.publicKey
      let name = neighbour.displayName(nicknames: storedNames)
      let stored = key.flatMap { storedPositions[$0] }
      // A relay that never said its type is listed as a repeater, and added as one.
      let fallbackType = filter == .sensors ? NeighbourDirectory.sensorType : ContactType.repeater.rawValue
      return NodeDiscoveryResult(
        id: record.identity,
        name: name ?? neighbour.placeholderName(nicknames: storedNames),
        isNamed: name != nil,
        publicKey: key,
        nodeType: neighbour.nodeTypeRaw == 0 ? fallbackType : neighbour.nodeTypeRaw,
        snr: neighbour.signal ?? 0,
        rssi: record.lastRSSI ?? 0,
        scanFilter: filter,
        receivedAt: record.lastHeard,
        heardFrom: heardFrom(of: record, since: scanStart).map { NodeDiscoveryHeardFrom($0) },
        coordinate: neighbour.coordinate ?? stored,
        resolution: labelled(neighbour.resolution, storedNames: storedNames),
        sources: scanStart.map { record.sourceKinds(heardSince: $0) } ?? Set(record.sources.keys),
        isConfirmed: record.isConfirmed,
        freshness: record.freshness(now: now),
        uplinkSNR: measuredInScan(record.uplinkAt, since: scanStart) ? record.uplinkSNR : nil,
        hearsYou: record.hearsYou(now: now) && measuredInScan(record.hearsYouAt, since: scanStart),
        unobservedSharers: unobservedSharers(of: neighbour, in: hints),
        isEarlier: isEarlier,
        isStoredPosition: neighbour.coordinate == nil && stored != nil
      )
    }
  }

  /// A reading taken at `date` belongs to the scan that started at `scanStart`; any does without
  /// a scan (nil), none taken at an unknown time does with one.
  private static func measuredInScan(_ date: Date?, since scanStart: Date?) -> Bool {
    guard let scanStart else { return true }
    return date.map { $0 >= scanStart } ?? false
  }

  /// Where `record` was heard from, for its map line and distance: the best-heard spot, or, for a
  /// row of the scan that started at `scanStart`, a spot this scan heard it from: the best-heard
  /// one when this scan heard it (then it is this scan's best too), else the latest reception
  /// with a fix since the scan started. Nil when the scan heard it only without a fix, so no line
  /// is drawn from where it was heard before the scan.
  static func heardFrom(of record: NeighbourRecord, since scanStart: Date?) -> NeighbourHeardFrom? {
    guard let scanStart else { return record.heardFrom }
    return [record.heardFrom, record.latestHeardFrom]
      .compactMap(\.self)
      .first { $0.receivedAt >= scanStart }
  }

  /// `resolution` with each node shown by the stored name for exactly its key, when there is
  /// one, as the RX Log list shows it.
  private static func labelled(_ resolution: NeighbourResolution, storedNames: [Data: String]) -> NeighbourResolution {
    func label(_ entry: NeighbourKeyEntry) -> NeighbourKeyEntry {
      guard let name = storedNames[entry.publicKey], !name.isEmpty else { return entry }
      var named = entry
      named.name = name
      return named
    }
    switch resolution {
    case let .resolved(entry):
      return .resolved(label(entry))
    case let .ambiguous(candidates, total):
      return .ambiguous(candidates: candidates.map(label), total: total)
    case .unknown:
      return resolution
    }
  }

  /// The nodes sharing the hash of a row no single observed node could be pinned on that are not
  /// candidates for it, at most as many as an ambiguous row lists; none for a resolved row or
  /// without an index.
  private static func unobservedSharers(of neighbour: ResolvedNeighbour, in index: PacketNodeIndex?) -> [UnobservedSharer] {
    guard let index, !neighbour.resolution.isResolved else { return [] }
    let hash = neighbour.record.identity.bytes
    return Array(index.unobservedSharers(of: hash, at: neighbour.record.lastHeard).prefix(NeighbourResolver.maximumListedCandidates))
  }

  /// `results` in `order`: signal strongest first, name alphabetical; distance needs this radio's
  /// position, which the results panel adds (`NodeDiscoveryEntries`), so here it falls back to
  /// signal. The current scan's rows go before the earlier ones, and rows no single node could be
  /// pinned on go last in every order; ties go to the most recently heard, then the key, so rows
  /// never swap places while evidence arrives.
  static func sorted(_ results: [NodeDiscoveryResult], by order: NodeDiscoverySortOrder) -> [NodeDiscoveryResult] {
    results.sorted { lhs, rhs in
      if lhs.isEarlier != rhs.isEarlier { return !lhs.isEarlier }
      if lhs.isResolved != rhs.isResolved { return lhs.isResolved }
      switch order {
      case .snr, .distance:
        if lhs.snr != rhs.snr { return lhs.snr > rhs.snr }
      case .name:
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
      }
      if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
      return lhs.key.lexicographicallyPrecedes(rhs.key)
    }
  }

  // MARK: - Probe

  /// The coordinator's probe state, idle without one. A radio whose firmware can't send a scan
  /// is never cooling down here: its scans only listen, so the gate never holds them back, and
  /// Scan Now always starts a new list.
  var probeState: DiscoveryProbeCoordinator.State {
    #if DEBUG && targetEnvironment(simulator)
      // The demo's scans don't go through the coordinator, so its gate never holds them back
      if Self.isDemo { return .idle }
    #endif
    guard let coordinator else { return .idle }
    if case .coolingDown = coordinator.state, !coordinator.isDiscoverSupported { return .idle }
    return coordinator.state
  }

  var isProbing: Bool {
    coordinator?.isProbing ?? false
  }

  var isWardriving: Bool {
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo, Self.demo.isWardriving { return true }
    #endif
    return coordinator?.isWardriving ?? false
  }

  /// What the scan card and the full-screen bar say, at this moment. Its counts are the list's:
  /// the current scan's rows of the listed kind, and how many of them answered it.
  var scanStatus: NodeDiscoveryScanStatus {
    let directory = directory
    let coordinator = coordinator
    let scan = currentScan
    var counts: NodeDiscoveryScanStatus.ScanCounts?
    if directory?.snapshot != nil {
      let current = currentResults
      counts = NodeDiscoveryScanStatus.ScanCounts(
        listed: current.count,
        answered: current.count { $0.sources.contains(.replyToUs) }
      )
    }
    var status = NodeDiscoveryScanStatus(
      state: probeState,
      filter: filter,
      isConnected: isConnected,
      nearbyCount: counts?.listed,
      updatedAt: directory?.updatedAt,
      summary: coordinator?.lastSummary,
      showsCooldownReason: showsCooldownReason,
      isWardriving: coordinator?.isWardriving ?? false,
      wardriveProbeCount: coordinator?.wardriveProbeCount ?? 0,
      nextWardriveProbeAt: coordinator?.nextWardriveProbeAt,
      isScanSupported: coordinator?.isDiscoverSupported ?? true,
      scan: scan,
      scanCounts: counts
    )
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo {
        status.isScanSupported = true
        status.isWardriving = Self.demo.isWardriving
        status.wardriveProbeCount = Self.demo.wardriveProbeCount
        status.nextWardriveProbeAt = Self.demo.nextWardriveProbeAt
      }
    #endif
    return status
  }

  /// Starts a new scan for the listed kind: the list empties, and fills with what the radio hears
  /// from now on, answers first. On a radio that can send one, nearby nodes are asked to answer
  /// once, if the coordinator lets the request go on air: a refusal shows its countdown instead
  /// (and the list stays the last scan's), and a request while a probe listens joins it. A radio
  /// whose firmware can't send one (official companion firmware before v1.10) runs a scan that only
  /// listens.
  func requestProbe() {
    errorMessage = nil
    showsCooldownReason = false
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo {
        scanStartHapticTrigger += 1
        Task { [weak self] in await self?.simulateResponses() }
        return
      }
    #endif
    guard let coordinator, isConnected else {
      errorMessage = L10n.Tools.Tools.NodeDiscovery.notConnectedDescription(filter.localizedTitle)
      return
    }
    let filter = filter
    if !coordinator.isDiscoverSupported {
      switch coordinator.requestListen(filter: filter, origin: .phone) {
      case .started, .attached:
        scanStartHapticTrigger += 1
      case .notConnected:
        errorMessage = L10n.Tools.Tools.NodeDiscovery.notConnectedDescription(filter.localizedTitle)
      case .coolingDown, .unsupported:
        break
      }
      return
    }
    Task { [weak self] in
      let outcome = await coordinator.requestProbe(filter: filter, origin: .phone)
      guard let self else { return }
      switch outcome {
      case .started, .attached:
        scanStartHapticTrigger += 1
      case .coolingDown, .unsupported:
        // The scan card says why: the countdown, or the firmware a scan needs.
        break
      case .notConnected:
        errorMessage = L10n.Tools.Tools.NodeDiscovery.notConnectedDescription(filter.localizedTitle)
      }
    }
  }

  /// Ends the running probe's listening window now.
  func stopProbe() {
    coordinator?.stopProbe()
  }

  /// Probes for the listed kind each time the gate allows, until stopped or disconnected. Runs on
  /// in the coordinator when the screen is left. Before it starts, anything worth saying
  /// (`WardrivePrompt`) is asked first; ``confirmWardrivePrompt()`` carries on from there.
  func startWardrive() {
    #if DEBUG && targetEnvironment(simulator)
      // The demo's drive (screenshot runs) starts at once; the simulator's location says nothing.
      if Self.isDemo {
        startDemoWardrive()
        scanStartHapticTrigger += 1
        return
      }
    #endif
    if let prompt = WardrivePrompt.next(
      locationDenied: deps.isLocationDenied(),
      hasSeenNote: deps.hasSeenWardriveNote(),
      batteryPercent: deps.batteryPercent(),
      lowPowerMode: deps.isLowPowerMode(),
      acknowledged: acknowledgedWardrivePrompts
    ) {
      wardrivePrompt = prompt
      return
    }
    acknowledgedWardrivePrompts.removeAll()
    guard let coordinator, isConnected else {
      errorMessage = L10n.Tools.Tools.NodeDiscovery.notConnectedDescription(filter.localizedTitle)
      return
    }
    // The scan card says the firmware a scan needs.
    guard coordinator.isDiscoverSupported else { return }
    coordinator.startWardrive(filter: filter)
    scanStartHapticTrigger += 1
  }

  /// The prompt was read and Wardrive should go on: the next prompt due, or the start.
  func confirmWardrivePrompt() {
    guard let prompt = wardrivePrompt else { return }
    wardrivePrompt = nil
    if prompt == .firstRun { deps.markWardriveNoteSeen() }
    acknowledgedWardrivePrompts.insert(prompt)
    startWardrive()
  }

  /// The prompt was read and Wardrive should not start.
  func cancelWardrivePrompt() {
    wardrivePrompt = nil
    acknowledgedWardrivePrompts.removeAll()
  }

  func stopWardrive() {
    #if DEBUG && targetEnvironment(simulator)
      if Self.isDemo { stopDemoWardrive() }
    #endif
    coordinator?.stopWardrive()
  }

  /// Stops Wardrive or the probe when either runs; during a cooldown opens or closes why it has to
  /// wait; else probes once.
  func toggleScan() {
    if isWardriving {
      stopWardrive()
      return
    }
    switch probeState {
    case .probing, .interrupted:
      stopProbe()
    case .coolingDown:
      showsCooldownReason.toggle()
    case .idle:
      requestProbe()
    }
  }

  /// Re-reads the gate when the screen opens: a cooldown another screen's probe started shows.
  func refreshCooldown() async {
    await coordinator?.refreshCooldown()
  }

  // MARK: - Private

  private func loadNameResolutionData(radioID: UUID) async {
    guard let dataStore else { return }
    do {
      // Load discovered nodes first, then contacts — contacts take priority
      let nodes = try await dataStore.fetchDiscoveredNodes(radioID: radioID)
      var names = Dictionary(
        nodes.map { ($0.publicKey, $0.name) },
        uniquingKeysWith: { first, _ in first }
      )
      let discovered = Dictionary(nodes.map { ($0.publicKey, $0) }, uniquingKeysWith: { first, _ in first })
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      for contact in contacts {
        names[contact.publicKey] = contact.name
      }
      guard radioID == resultsRadioID else { return }
      // A name resolved while this load ran is kept; what the store says wins otherwise.
      namesByKey = names.merging(namesByKey) { stored, _ in stored }
      discoveredByKey = discovered
      contactsByKey = Dictionary(contacts.map { ($0.publicKey, $0) }, uniquingKeysWith: { first, _ in first })
      addedPublicKeys = Set(contacts.map(\.publicKey))
    } catch {
      Self.logger.error("Failed to load name resolution data: \(error.localizedDescription)")
    }
  }

  /// "Unknown (A1B2C3D4)": a node known by its key alone.
  static func placeholderName(for publicKey: Data) -> String {
    ResolvedNeighbour.unknownNodeName(for: publicKey)
  }

  // MARK: - Name Resolution

  private enum NameStep {
    /// Look the node up in the radio's contact table: no airtime.
    case lookUp(Data, NodeNameResolver, UUID)
    /// Ask the node itself, over the air.
    case request(Data, NodeNameResolver, UUID)
    case wait
  }

  /// Names the listed rows that are confirmed, carry a whole key and have no stored name: each is
  /// looked up in the radio's contact table once, as it appears. Once a probe has gone out and its
  /// replies have had `nameRequestDelay` to land, up to `maxNameRequestsPerScan` of the scan's own
  /// rows are asked over the air, strongest signal first, until the next probe.
  private func startNameResolution() {
    nameTask?.cancel()
    // `self` is held only within each step, never across a wait, so a view model whose screen
    // went away is freed and the loop ends with it.
    nameTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let step = self?.nextNameStep() else { return }
        switch step {
        case let .lookUp(key, resolver, radioID):
          await self?.resolveName(for: key, with: resolver, overTheAir: false, radioID: radioID)
        case let .request(key, resolver, radioID):
          await self?.resolveName(for: key, with: resolver, overTheAir: true, radioID: radioID)
        case .wait:
          try? await Task.sleep(for: Self.namePollInterval)
        }
      }
    }
  }

  private func nextNameStep() -> NameStep {
    guard let resolver = deps.nameResolver(), let radioID, radioID == resultsRadioID else { return .wait }
    if let key = nextUnnamedKey(in: results, excluding: lookedUpNameKeys) {
      lookedUpNameKeys.insert(key)
      return .lookUp(key, resolver, radioID)
    }
    // A scan that only listened asked nobody, so it brings no name requests either
    if let probe = coordinator?.activeProbe, !probe.listensOnly, let sentAt = probe.sentAt, sentAt != nameProbeSentAt {
      nameProbeSentAt = sentAt
      nameRequestsThisProbe = 0
    }
    guard let sentAt = nameProbeSentAt,
          deps.supportsNameRequests(),
          nameRequestsThisProbe < Self.maxNameRequestsPerScan,
          deps.now() >= sentAt.addingTimeInterval(Self.nameRequestDelay),
          let key = nextUnnamedKey(in: currentResults, excluding: attemptedNameKeys) else { return .wait }
    attemptedNameKeys.insert(key)
    nameRequestsThisProbe += 1
    return .request(key, resolver, radioID)
  }

  /// The strongest unnamed, confirmed, whole-key row of `rows` that is not in `excluded`. Every
  /// listed row is looked up in the radio's contact table (no airtime); only the current scan's
  /// are asked over the air.
  private func nextUnnamedKey(in rows: [NodeDiscoveryResult], excluding excluded: Set<Data>) -> Data? {
    rows
      .filter { !$0.isNamed && $0.isConfirmed && $0.hasFullKey }
      .filter { !excluded.contains($0.key) && !resolvingNameKeys.contains($0.key) }
      .max { $0.snr < $1.snr }?
      .publicKey
  }

  private func resolveName(
    for publicKey: Data,
    with resolver: NodeNameResolver,
    overTheAir: Bool,
    radioID: UUID
  ) async {
    resolvingNameKeys.insert(publicKey)
    defer { resolvingNameKeys.remove(publicKey) }

    // A name that arrives after the probe ended is still kept: the airtime is already spent.
    // Not once the app has switched radios, though: the node is the old radio's neighbour.
    guard let resolved = await resolver.resolve(publicKey: publicKey, overTheAir: overTheAir),
          radioID == resultsRadioID else { return }
    namesByKey[resolved.publicKey] = resolved.name
    await store(resolved, radioID: radioID)
  }

  /// Keeps the name as a discovered node, so the next scan names this node without asking, and
  /// tells the app: Home and Contacts > Heard list it under its name.
  private func store(_ resolved: ResolvedNodeName, radioID: UUID) async {
    guard let dataStore, contactsByKey[resolved.publicKey] == nil else { return }
    // The node may have left the list (a new scan) while its name was on its way
    let nodeType = directory?.snapshot?.neighbours
      .first { $0.resolution.entry?.publicKey == resolved.publicKey }
      .map(\.nodeTypeRaw)
      .flatMap { $0 == 0 ? nil : $0 }
    let typeRawValue = resolved.typeRawValue.flatMap { $0 == 0 ? nil : $0 } ?? nodeType ?? ContactType.repeater.rawValue
    let frame = ContactFrame(
      publicKey: resolved.publicKey,
      type: ContactType(rawValue: typeRawValue) ?? .repeater,
      typeRawValue: typeRawValue,
      flags: 0,
      // Only direct neighbours are named here.
      outPathLength: 0,
      outPath: Data(),
      name: resolved.name,
      lastAdvertTimestamp: 0,
      latitude: resolved.latitude,
      longitude: resolved.longitude,
      lastModified: 0
    )
    do {
      let (node, _) = try await dataStore.upsertDiscoveredNode(radioID: radioID, from: frame)
      discoveredByKey[resolved.publicKey] = node
      deps.onNodesChanged()
    } catch {
      Self.logger.error("Failed to store resolved node name: \(error.localizedDescription)")
    }
  }

  #if DEBUG && targetEnvironment(simulator)
    /// UI tests and screenshot tours pass `-uiTestDiscoveryDemo YES`: the simulator's mock radio
    /// hears nothing, so the list comes from a made-up snapshot instead.
    static var isDemo: Bool {
      ProcessInfo.processInfo.launchArgument("uiTestDiscoveryDemo") == "YES"
    }

    /// The demo's own directory, so the mock radio's (empty) neighbour updates never replace it.
    static let demoDirectory = NeighbourDirectory()

    /// The demo's scans, observed as the coordinator's are: the scan whose list shows, the rows
    /// heard so far (a table the scans add to, as the radio's does), and its Wardrive.
    @Observable
    @MainActor
    final class DemoScans {
      var scan: DiscoveryProbeCoordinator.Scan?
      /// Scans run so far: odd and even ones are answered by different strangers.
      var count = 0
      var isWardriving = false
      var wardriveProbeCount = 0
      var nextWardriveProbeAt: Date?
      var session: DiscoveryProbeCoordinator.WardriveSession?
      @ObservationIgnored var records: [NeighbourIdentity: NeighbourRecord] = [:]
      @ObservationIgnored var wardriveTask: Task<Void, Never>?
    }

    static let demo = DemoScans()

    /// The stranger that answers odd scans, and is named by its name request.
    static let demoNamedStranger = Data(repeating: 0xA7, count: 32)
    /// The stranger that answers even scans and stays unnamed.
    static let demoQuietStranger = Data(repeating: 0x3C, count: 32)
    /// How long a demo scan's request takes to bring its first answer.
    static let demoFirstReplyDelay: Duration = .seconds(2)
    /// How long demo Wardrive waits between its scans.
    static let demoWardriveSpacing: TimeInterval = 8

    /// Two repeaters heard before the demo's first scan (40 minutes and 5 hours ago), so Show
    /// Older has something to show; once.
    private func seedDemoIfNeeded(radioID: UUID) {
      let demo = Self.demo
      guard demo.records.isEmpty else { return }
      let now = Date()
      func seeded(_ byte: UInt8, name: String, age: TimeInterval, snr: Double, latitude: Double, longitude: Double) -> NeighbourRecord {
        let heard = now.addingTimeInterval(-age)
        return NeighbourRecord(
          identity: .fullKey(Data(repeating: byte, count: 32)),
          firstHeard: heard.addingTimeInterval(-600),
          lastHeard: heard,
          heardCount: 3,
          lastSNR: snr,
          bestSNR: snr,
          snrEWMA: snr,
          lastRSSI: -95,
          sources: [
            .advert: NeighbourSourceStats(count: 1, firstHeard: heard, lastHeard: heard),
            .relay: NeighbourSourceStats(count: 2, firstHeard: heard.addingTimeInterval(-600), lastHeard: heard.addingTimeInterval(-60)),
          ],
          nodeTypeRaw: ContactType.repeater.rawValue,
          name: name,
          latitude: latitude,
          longitude: longitude
        )
      }
      for record in [
        seeded(0x5A, name: "Hilltop Relay", age: 40 * 60, snr: 2.5, latitude: 37.7952, longitude: -122.4028),
        seeded(0x6B, name: "Canyon Lookout", age: 5 * 3600, snr: -4, latitude: 37.6879, longitude: -122.4702),
      ] {
        demo.records[record.identity] = record
      }
      Self.demoDirectory.apply(Self.simulatedSnapshot(radioID: radioID, records: Array(demo.records.values), probe: nil, now: now))
    }

    /// A demo scan: a new list starts, then every stored repeater "answers", plus a stranger (a key
    /// no stored record names) that alternates between scans, so each scan's list differs from the
    /// last and Show Older has the other one. The odd scans' stranger then "answers" a name
    /// request. Answers arrive one at a time, after the request's trip.
    /// - Parameter startsNewScan: False for demo Wardrive's later scans, which add to the list
    ///   its first scan started, as Wardrive's do.
    private func simulateResponses(startsNewScan: Bool = true) async {
      guard let radioID else { return }
      let demo = Self.demo
      seedDemoIfNeeded(radioID: radioID)
      demo.count += 1
      let isEven = demo.count.isMultiple(of: 2)
      let stranger = isEven ? Self.demoQuietStranger : Self.demoNamedStranger
      let otherStranger = isEven ? Self.demoNamedStranger : Self.demoQuietStranger
      let startedAt = Date()
      if startsNewScan || demo.scan == nil {
        demo.scan = DiscoveryProbeCoordinator.Scan(radioID: radioID, filter: filter, startedAt: startedAt, listensOnly: false)
      }
      let scanStartedAt = demo.scan?.startedAt
      let known = Set(
        contactsByKey.values.filter { $0.type == .repeater }.map(\.publicKey)
          + discoveredByKey.values.filter { $0.nodeType == .repeater }.map(\.publicKey)
      ).subtracting([stranger, otherStranger])
      let keys = known.sorted { $0.lexicographicallyPrecedes($1) } + [stranger]
      nameProbeSentAt = startedAt.addingTimeInterval(-Self.nameRequestDelay)
      nameRequestsThisProbe = 0
      try? await Task.sleep(for: Self.demoFirstReplyDelay)
      for (position, key) in keys.enumerated() {
        if position > 0 { try? await Task.sleep(for: .milliseconds(350)) }
        // A newer scan took over: its own answers fill its list
        guard demo.scan?.startedAt == scanStartedAt else { return }
        let now = Date()
        let snr = 10.5 - Double(position) * 3.25
        let reply = NeighbourRecord(
          identity: .fullKey(key),
          firstHeard: now,
          lastHeard: now,
          heardCount: 1,
          lastSNR: snr,
          bestSNR: snr,
          snrEWMA: snr,
          lastRSSI: -62 - position * 9,
          uplinkSNR: 9 - Double(position) * 2.75,
          uplinkAt: now,
          hearsYouAt: now,
          sources: [.replyToUs: NeighbourSourceStats(count: 1, firstHeard: now, lastHeard: now)],
          nodeTypeRaw: ContactType.repeater.rawValue
        )
        demo.records[reply.identity] = demo.records[reply.identity].map { $0.merged(with: reply) } ?? reply
        Self.demoDirectory.apply(Self.simulatedSnapshot(
          radioID: radioID,
          records: Array(demo.records.values),
          probe: NeighbourProbe(tag: 0, filter: filter.filterValue, sentAt: startedAt),
          now: now
        ))
      }
    }

    /// Demo Wardrive: a demo scan every ``demoWardriveSpacing`` seconds until stopped, each one
    /// starting a new list as Wardrive's scans do.
    private func startDemoWardrive() {
      let demo = Self.demo
      guard !demo.isWardriving else { return }
      demo.isWardriving = true
      demo.wardriveProbeCount = 0
      demo.nextWardriveProbeAt = nil
      demo.scan = nil
      demo.session = DiscoveryProbeCoordinator.WardriveSession(filter: filter, startedAt: Date())
      demo.wardriveTask = Task { [weak self] in
        while Self.demo.isWardriving, !Task.isCancelled {
          Self.demo.nextWardriveProbeAt = nil
          Self.demo.wardriveProbeCount += 1
          Self.demo.session?.probeCount += 1
          // The demo drives a little between scans
          Self.demo.session?.distanceMeters += 420
          await self?.simulateResponses(startsNewScan: Self.demo.wardriveProbeCount == 1)
          guard Self.demo.isWardriving, !Task.isCancelled else { return }
          Self.demo.nextWardriveProbeAt = Date().addingTimeInterval(Self.demoWardriveSpacing)
          try? await Task.sleep(for: .seconds(Self.demoWardriveSpacing))
        }
      }
    }

    private func stopDemoWardrive() {
      let demo = Self.demo
      demo.wardriveTask?.cancel()
      demo.wardriveTask = nil
      if demo.isWardriving { demo.session?.endedAt = Date() }
      demo.isWardriving = false
      demo.nextWardriveProbeAt = nil
    }
  #endif

  /// The channel the demo's made-up replies are heard on.
  static let simulatedChannel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)

  /// The demo's snapshot of `records`, each a whole-key reply to `probe`: as on a radio, each
  /// reply is what this radio observed of its node (a discover reply heard directly), and the rows
  /// resolve against those observations alone. No saved contact is read; the stored names label
  /// the rows as they do any other.
  static func simulatedSnapshot(radioID: UUID, records: [NeighbourRecord], probe: NeighbourProbe?, now: Date) -> NeighbourSnapshot {
    var ledger = ObservationLedger(radioID: radioID, channel: simulatedChannel, selfKey: nil)
    for record in records {
      guard let identity = ObservedIdentity(bytes: record.identity.bytes) else { continue }
      ledger.ingest(NodeObservation(
        identity: identity,
        kind: .discoverReply,
        channelKey: simulatedChannel.key,
        at: record.lastHeard,
        hops: 0,
        snr: record.lastSNR,
        rssi: record.lastRSSI,
        nodeTypeRaw: record.nodeTypeRaw
      ))
    }
    let observed = ledger.snapshot(takenAt: now)
    return NeighbourSnapshot(
      radioID: radioID,
      takenAt: now,
      neighbours: NeighbourResolver.resolveAll(NeighbourTable(records: records), index: PacketNodeIndex(ledger: observed), now: now),
      lastProbe: probe,
      ledger: observed
    )
  }

  // MARK: - Add Node

  func isAdded(publicKey: Data) -> Bool {
    addedPublicKeys.contains(publicKey)
  }

  /// Saves a row's node as a contact. Only a row naming one node by its whole key can be added.
  func addNode(_ result: NodeDiscoveryResult) {
    guard let publicKey = result.publicKey, result.hasFullKey, let contact = contactFrame(for: result) else { return }
    addingPublicKey = publicKey
    Task { [weak self] in
      _ = await self?.add(contact, publicKey: publicKey)
      self?.addingPublicKey = nil
    }
  }

  /// Saves every row of `results` that is not a contact yet, one after another, each as
  /// ``addNode(_:)`` would; stops at the first failure (a full contact table says so once).
  func addAllNew(_ results: [NodeDiscoveryResult]) {
    let pending = results.filter { result in
      guard let key = result.publicKey, result.hasFullKey else { return false }
      return !addedPublicKeys.contains(key) && contactsByKey[key] == nil
    }
    guard !pending.isEmpty, addingPublicKey == nil else { return }
    Task { [weak self] in
      for result in pending {
        guard let self, let publicKey = result.publicKey, let contact = contactFrame(for: result) else { continue }
        addingPublicKey = publicKey
        let added = await add(contact, publicKey: publicKey)
        addingPublicKey = nil
        if !added { break }
      }
    }
  }

  /// The contact a row would be saved as; nil while disconnected or for a row that names no
  /// single node by its whole key.
  private func contactFrame(for result: NodeDiscoveryResult) -> ContactFrame? {
    guard contactService != nil, radioID != nil, let publicKey = result.publicKey, result.hasFullKey else { return nil }
    resetIfRadioChanged()
    // A discovered record carries the node's advertised position and path; keep them.
    return discoveredByKey[publicKey]?.makeContactFrame() ?? ContactFrame(
      publicKey: publicKey,
      type: ContactType(rawValue: result.nodeType) ?? .repeater,
      flags: 0,
      outPathLength: PacketBuilder.floodPathSentinel,
      outPath: Data(),
      // An unnamed result shows a made-up "Unknown (…)" label, which is not the node's name.
      name: result.isNamed ? result.name : "",
      lastAdvertTimestamp: 0,
      latitude: result.coordinate?.latitude ?? 0,
      longitude: result.coordinate?.longitude ?? 0,
      lastModified: 0
    )
  }

  /// Saves `contact` on the radio and reloads the stored records, so the card switches to the
  /// new contact. False when the save failed (the error is shown).
  private func add(_ contact: ContactFrame, publicKey: Data) async -> Bool {
    guard let contactService, let radioID else { return false }
    do {
      try await contactService.addOrUpdateContact(radioID: radioID, contact: contact)
      addedPublicKeys.insert(publicKey)
      addSuccessHapticTrigger += 1
      await loadNameResolutionData(radioID: radioID)
      return true
    } catch ContactServiceError.contactTableFull {
      if let maxContacts {
        errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFull(Int(maxContacts))
      } else {
        errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
      }
      addErrorHapticTrigger += 1
    } catch {
      errorMessage = error.userFacingMessage
      addErrorHapticTrigger += 1
    }
    return false
  }
}

extension NodeDiscoveryHeardFrom {
  /// The neighbour table's best-heard spot, as the map draws it.
  init(_ heardFrom: NeighbourHeardFrom) {
    self.init(
      fix: NodeDiscoveryFix(
        latitude: heardFrom.fix.latitude,
        longitude: heardFrom.fix.longitude,
        horizontalAccuracy: heardFrom.fix.horizontalAccuracy,
        timestamp: heardFrom.fix.timestamp
      ),
      snr: heardFrom.snr
    )
  }
}
