import CairnServices
import CoreLocation
import Foundation
import MeshCore

/// The current radio's direct neighbours as the app shows them: Scan for Nodes, CarPlay's scan
/// template, Home's "Nearby now" and Region discovery's fallback all read this one directory.
///
/// Each snapshot holds the neighbours of the channel the radio is on, resolved against what this
/// radio observed on that channel (``ledger``), the same observations the RX Log list and the
/// Traffic map resolve against (`ObservationDirectory`). A saved contact never names a row: it
/// labels only a row resolved to exactly its key.
///
/// It follows `NeighbourService.updates()` of whichever service is wired, re-binding when the
/// connection is rebuilt. The last snapshot outlives a disconnect, flagged stale, so the list
/// still shows what was heard; after a reconnect to the same radio it stays until the new service
/// has read its stored rows back in, so the list never flashes empty. A different radio's
/// neighbours are never shown: binding to another radio drops the snapshot at once.
@Observable
@MainActor
final class NeighbourDirectory {
  /// The newest snapshot of the bound radio's neighbours, or the last one heard before a
  /// disconnect (see ``isStale``). Nil until a service has sent one.
  private(set) var snapshot: NeighbourSnapshot?
  /// True while ``snapshot`` is what was heard before the radio disconnected, or before the
  /// connection was rebuilt and the new service has warmed up.
  private(set) var isStale = false

  /// Every snapshot the bound service sends, including the cold ones that don't replace a stale
  /// ``snapshot``: the probe coordinator watches them for replies to its probe.
  @ObservationIgnored var onSnapshot: (@MainActor (NeighbourSnapshot) -> Void)?

  @ObservationIgnored private let now: () -> Date
  /// Identity of the service whose updates are followed, so re-wiring the same container doesn't
  /// re-subscribe.
  @ObservationIgnored private var boundSourceID: ObjectIdentifier?
  /// The radio the snapshot belongs to; kept across a disconnect, so a reconnect to the same
  /// radio keeps showing it.
  @ObservationIgnored private var boundRadioID: UUID?
  @ObservationIgnored private var updatesTask: Task<Void, Never>?

  /// - Parameter now: The clock freshness is measured against; tests inject a fake one.
  init(now: @escaping () -> Date = { Date() }) {
    self.now = now
  }

  isolated deinit {
    updatesTask?.cancel()
  }

  // MARK: - Binding

  /// Follows `service`'s updates for `radioID`. Binding the service already followed does nothing.
  func bind(to service: NeighbourService, radioID: UUID) {
    bind(sourceID: ObjectIdentifier(service), radioID: radioID) { await service.updates() }
  }

  /// Follows the snapshots `updates` streams for `radioID`, from the source `sourceID` names.
  func bind(
    sourceID: ObjectIdentifier,
    radioID: UUID,
    updates: @escaping @Sendable () async -> AsyncStream<NeighbourSnapshot>
  ) {
    guard sourceID != boundSourceID else { return }
    updatesTask?.cancel()
    boundSourceID = sourceID
    if boundRadioID != radioID || snapshot?.radioID != radioID {
      snapshot = nil
      isStale = false
    } else if snapshot != nil {
      // The new service starts cold; the old snapshot stands in until it has warmed up
      isStale = true
    }
    boundRadioID = radioID
    updatesTask = Task { [weak self] in
      let stream = await updates()
      for await snapshot in stream {
        guard !Task.isCancelled else { return }
        self?.apply(snapshot)
      }
    }
  }

  /// The radio disconnected: stops following its service and keeps the last snapshot, stale.
  func markDisconnected() {
    updatesTask?.cancel()
    updatesTask = nil
    boundSourceID = nil
    isStale = snapshot != nil
  }

  /// Takes one snapshot: from the bound service, or a made-up one (the UI-test demo, tests).
  /// A snapshot for another radio than the bound one is ignored. While a stale snapshot stands in,
  /// a cold one (the new service hasn't read its stored rows yet) doesn't replace it, unless the
  /// radio is now on another channel: the stale rows were heard on the old one.
  func apply(_ snapshot: NeighbourSnapshot) {
    if let boundRadioID, snapshot.radioID != boundRadioID { return }
    onSnapshot?(snapshot)
    if isStale, !snapshot.isWarm, self.snapshot?.radioID == snapshot.radioID, !isRetune(to: snapshot) { return }
    self.snapshot = snapshot
    isStale = boundSourceID == nil && boundRadioID != nil
  }

  /// Whether `snapshot` is of another channel than the one shown: the radio reported a channel,
  /// and it is not the shown snapshot's.
  private func isRetune(to snapshot: NeighbourSnapshot) -> Bool {
    guard let key = snapshot.channelKey else { return false }
    return key != self.snapshot?.channelKey
  }

  // MARK: - Reading

  /// When the shown snapshot was taken, for "updated %@" and, when stale, "showing what was heard
  /// until %@".
  var updatedAt: Date? {
    snapshot?.takenAt
  }

  /// What this radio observed on the channel the shown neighbours were heard on; cold with no
  /// snapshot, or while the radio hasn't reported its channel.
  var ledger: LedgerSnapshot {
    snapshot?.ledger ?? .empty
  }

  /// The shown ledger's version: it changes whenever the rows could resolve differently.
  var ledgerVersion: Int {
    ledger.version
  }

  /// Confirmed neighbours heard in the last 10 minutes, or nil with no snapshot (Home hides the
  /// line then). Measured against `now`, so a stale snapshot counts down to zero.
  func nearbyNowCount(now date: Date? = nil) -> Int? {
    guard let snapshot else { return nil }
    let date = date ?? now()
    return snapshot.neighbours.count { $0.record.isConfirmed && $0.record.freshness(now: date) == .live }
  }

  /// ``nearbyNowCount(now:)`` against the directory's clock.
  var nearbyNowCount: Int? {
    nearbyNowCount()
  }

  /// The neighbours of one kind worth listing now, most recently heard first.
  /// - Parameter includeOlder: Also the rows last heard 2 to 24 hours ago ("Show older").
  func neighbours(_ filter: NodeDiscoveryFilter, includeOlder: Bool = false, now date: Date? = nil) -> [ResolvedNeighbour] {
    Self.filtered(snapshot?.neighbours ?? [], filter: filter, includeOlder: includeOlder, now: date ?? now())
  }

  /// The neighbour resolved to exactly `publicKey` that Scan & Traffic would list (heard in the
  /// last 24 hours, with Show Older), whatever its kind; nil when the radio hasn't heard it directly
  /// lately, or only as a relay hash it can't be pinned on.
  func neighbour(publicKey: Data, now date: Date? = nil) -> ResolvedNeighbour? {
    let date = date ?? now()
    return snapshot?.neighbours.first { neighbour in
      guard neighbour.resolution.entry?.publicKey == publicKey else { return false }
      return switch neighbour.record.freshness(now: date) {
      case .live, .recent, .older: true
      case .stale: false
      }
    }
  }

  /// One scan's list of one kind (``scanList(_:filter:since:includeEarlier:now:)``) from the shown
  /// snapshot.
  func scanList(
    _ filter: NodeDiscoveryFilter,
    since scanStart: Date?,
    includeEarlier: Bool = false,
    now date: Date? = nil
  ) -> ScanList {
    Self.scanList(
      snapshot?.neighbours ?? [],
      filter: filter,
      since: scanStart,
      includeEarlier: includeEarlier,
      now: date ?? now()
    )
  }

  /// The most repeaters Region discovery's fallback asks: each request is airtime, retried along
  /// its stored path.
  static let regionFallbackLimit = 8

  /// Full public keys of the confirmed repeaters and rooms heard in the last 10 minutes (or, when
  /// none was, in the last 2 hours), strongest first, at most ``regionFallbackLimit``: the nodes
  /// Region discovery asks when the gate refuses a probe. A repeater heard hours ago, often
  /// somewhere else on a drive, is unlikely to answer now.
  func nearbyRepeaterKeys(now date: Date? = nil) -> Set<Data> {
    let date = date ?? now()
    let candidates = Self.filtered(snapshot?.neighbours ?? [], filter: .repeaters, includeOlder: false, now: date)
      .filter { $0.record.isConfirmed && $0.isRepeaterType }
      .filter { ($0.resolution.entry?.publicKey.count ?? 0) == ProtocolLimits.publicKeySize }
    let live = candidates.filter { $0.record.freshness(now: date) == .live }
    let keys = (live.isEmpty ? candidates : live)
      .sorted { ($0.signal ?? -.infinity) > ($1.signal ?? -.infinity) }
      .prefix(Self.regionFallbackLimit)
      .compactMap { $0.resolution.entry?.publicKey }
    return Set(keys)
  }

  // MARK: - Filtering and Sorting

  /// Scan for Nodes' list for one scan: a time cut over the neighbour table at the moment the scan
  /// started, nothing stored apart from it.
  struct ScanList: Equatable {
    /// Heard since the scan started: answers to it, and anything else the radio received meanwhile
    /// and after, until the next scan.
    var current: [ResolvedNeighbour]
    /// With Show Older, the rest heard in the last 24 hours, before the scan started (all of them
    /// before the first scan); otherwise none.
    var earlier: [ResolvedNeighbour]
  }

  /// The rows of one kind cut at `scanStart`, each list most recently heard first.
  ///
  /// A row is this scan's when one of its receptions (``NeighbourRecord/wasHeard(since:)``) came
  /// at or after `scanStart`: every reception is stamped when the radio heard it, so a backlog
  /// frame heard before the scan stays before it, however late it reached the app. A row the
  /// resolver built from several table rows is this scan's when any of them was heard since; an
  /// older member only adds its history, never a later time. An answer to the scan always counts:
  /// it is stamped after the request went out, which is after the scan started. Before the first
  /// scan (`scanStart` nil) nothing is current.
  ///
  /// - Parameter includeEarlier: Also list the rows heard only before the scan, in the last 24
  ///   hours ("Show older"); never the expired.
  static func scanList(
    _ neighbours: [ResolvedNeighbour],
    filter: NodeDiscoveryFilter,
    since scanStart: Date?,
    includeEarlier: Bool,
    now: Date
  ) -> ScanList {
    var list = ScanList(current: [], earlier: [])
    for neighbour in neighbours where neighbour.isListed(as: filter) {
      let record = neighbour.record
      if let scanStart, record.wasHeard(since: scanStart) {
        list.current.append(neighbour)
      } else if includeEarlier,
                record.freshness(now: now) != .stale,
                scanStart.map({ (record.lastReceivedAt ?? record.lastHeard) < $0 }) ?? true {
        // A row with no reception yet (a hears-you proof that outran its frame) waits for it
        list.earlier.append(neighbour)
      }
    }
    return list
  }

  /// The rows of one kind in the freshness bands shown: live and recent, plus older ones when
  /// asked; never the expired. Repeaters are repeater and room nodes, a relay whose node didn't
  /// say its type, and relays no key could be pinned on. Sensors are nodes an advert or reply said
  /// were sensors.
  static func filtered(
    _ neighbours: [ResolvedNeighbour],
    filter: NodeDiscoveryFilter,
    includeOlder: Bool,
    now: Date
  ) -> [ResolvedNeighbour] {
    neighbours.filter { neighbour in
      switch neighbour.record.freshness(now: now) {
      case .live, .recent: break
      case .older: guard includeOlder else { return false }
      case .stale: return false
      }
      return neighbour.isListed(as: filter)
    }
  }

  /// `neighbours` in `order`. Distance runs from `origin` (the radio's position); rows without a
  /// position, a signal or a name go last. Ties go to the most recently heard.
  static func sorted(
    _ neighbours: [ResolvedNeighbour],
    by order: NodeDiscoverySortOrder,
    from origin: CLLocationCoordinate2D? = nil
  ) -> [ResolvedNeighbour] {
    let originLocation = origin.flatMap { $0.isValidFix ? CLLocation(latitude: $0.latitude, longitude: $0.longitude) : nil }
    func distance(_ neighbour: ResolvedNeighbour) -> CLLocationDistance? {
      guard let originLocation, let coordinate = neighbour.coordinate else { return nil }
      return originLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
    return neighbours.sorted { lhs, rhs in
      switch order {
      case .snr:
        if let ordered = descendingNilsLast(lhs.signal, rhs.signal) { return ordered }
      case .distance:
        if let ordered = ascendingNilsLast(distance(lhs), distance(rhs)) { return ordered }
      case .name:
        switch (lhs.displayName, rhs.displayName) {
        case let (l?, r?):
          let comparison = l.localizedCaseInsensitiveCompare(r)
          if comparison != .orderedSame { return comparison == .orderedAscending }
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): break
        }
      }
      if lhs.record.lastHeard != rhs.record.lastHeard { return lhs.record.lastHeard > rhs.record.lastHeard }
      return lhs.record.identity.bytes.lexicographicallyPrecedes(rhs.record.identity.bytes)
    }
  }

  /// Whether `lhs` goes before `rhs` with the larger value first and missing values last; nil on a tie.
  private static func descendingNilsLast<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
    switch (lhs, rhs) {
    case let (l?, r?): l == r ? nil : l > r
    case (.some, nil): true
    case (nil, .some): false
    case (nil, nil): nil
    }
  }

  /// Whether `lhs` goes before `rhs` with the smaller value first and missing values last; nil on a tie.
  private static func ascendingNilsLast<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
    switch (lhs, rhs) {
    case let (l?, r?): l == r ? nil : l < r
    case (.some, nil): true
    case (nil, .some): false
    case (nil, nil): nil
    }
  }

  /// MeshCore's ADV_TYPE_SENSOR; `ContactType` has no case for it.
  nonisolated static let sensorType: UInt8 = 4
}

// MARK: - Row Details

extension ResolvedNeighbour {
  /// The node type: what the resolved key's records say, else what an advert or reply in the row
  /// said; 0 when nothing did.
  var nodeTypeRaw: UInt8 {
    if let type = resolution.entry?.nodeTypeRaw, type != 0 { return type }
    return record.nodeTypeRaw ?? 0
  }

  /// A repeater or room by type.
  var isRepeaterType: Bool {
    nodeTypeRaw == ContactType.repeater.rawValue || nodeTypeRaw == ContactType.room.rawValue
  }

  /// Listed under `filter`: Repeaters lists ``isListedAsRepeater``, Sensors the nodes an advert or
  /// reply said were sensors.
  func isListed(as filter: NodeDiscoveryFilter) -> Bool {
    switch filter {
    case .repeaters: isListedAsRepeater
    case .sensors: nodeTypeRaw == NeighbourDirectory.sensorType
    }
  }

  /// Listed under Repeaters: a repeater or room, a relay whose node didn't say its type, or a
  /// relay no single key could be pinned on.
  var isListedAsRepeater: Bool {
    if isRepeaterType { return true }
    guard record.sources[.relay] != nil else { return false }
    return !resolution.isResolved || nodeTypeRaw == 0
  }

  /// The node's name, as it advertised it or as its own reply or advert in the row said; nil when
  /// unnamed. Nil for a row that names no single node.
  var displayName: String? {
    let name = resolution.entry?.name ?? record.name
    guard let name, !name.isEmpty else { return nil }
    return name
  }

  /// ``displayName``, with a saved name for exactly the resolved key winning: `nicknames` holds
  /// names by whole key. A saved name never names a hash row that resolves to no node, or to one
  /// of several (R5).
  func displayName(nicknames: [Data: String]) -> String? {
    if let key = resolution.entry?.publicKey, let nickname = nicknames[key], !nickname.isEmpty {
      return nickname
    }
    return displayName
  }

  /// The title of a row nothing names, in the words Scan for Nodes and CarPlay share: "Unknown
  /// (A1B2C3D4)" for a node known by its key, "Unidentified relay 3A7F21" for a relay hash no node
  /// observed on this channel starts with, and "Ridge? · could be 3 nodes" for a hash several
  /// observed nodes share: the likeliest one's name with a "?", and how many there are.
  func placeholderName(nicknames: [Data: String] = [:]) -> String {
    switch resolution {
    case let .resolved(entry):
      return Self.unknownNodeName(for: entry.publicKey)
    case let .unknown(hash):
      return L10n.Tools.Tools.NodeDiscovery.unidentifiedRelay(hash.uppercaseHexString())
    case let .ambiguous(candidates, total):
      let guess = candidates.first.map { "\(Self.name(of: $0, nicknames: nicknames))?" }
      return L10n.Tools.Tools.NodeDiscovery.ambiguous(guess ?? record.identity.bytes.uppercaseHexString(), total)
    }
  }

  /// "Unknown (A1B2C3D4)": a node known by its key alone.
  static func unknownNodeName(for publicKey: Data) -> String {
    "\(L10n.Tools.Tools.NodeDiscovery.unknownNode) (\(publicKey.prefix(4).uppercaseHexString()))"
  }

  /// An observed node's name as the RX Log list gives it: a saved name for exactly its key, the
  /// name it advertised, else its key's first 3 bytes in hex.
  static func name(of entry: NeighbourKeyEntry, nicknames: [Data: String]) -> String {
    if let nickname = nicknames[entry.publicKey], !nickname.isEmpty { return nickname }
    return entry.name ?? Data(entry.publicKey.prefix(3)).uppercaseHexString()
  }

  /// The node's advertised position, when it has a real one.
  var coordinate: CLLocationCoordinate2D? {
    let entry = resolution.entry
    guard let latitude = entry?.latitude ?? record.latitude,
          let longitude = entry?.longitude ?? record.longitude else { return nil }
    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    return coordinate.isValidFix ? coordinate : nil
  }

  /// The signal to sort and show by: the smoothed SNR, else the last one.
  var signal: Double? {
    record.snrEWMA ?? record.lastSNR
  }
}

// MARK: - Receptions

extension NeighbourRecord {
  /// When this radio last received the node itself, by any kind of reception; nil for a row with
  /// none yet (a hears-you proof that outran its frame). Unlike ``lastHeard``, never moved by
  /// anything but a reception.
  var lastReceivedAt: Date? {
    sources.values.map(\.lastHeard).max()
  }

  /// Whether the radio received the node at or after `date`, by any kind of reception.
  func wasHeard(since date: Date) -> Bool {
    sources.values.contains { $0.lastHeard >= date }
  }

  /// The kinds of reception heard at or after `date`: the evidence one scan has for the node.
  func sourceKinds(heardSince date: Date) -> Set<NeighbourSourceKind> {
    Set(sources.filter { $0.value.lastHeard >= date }.keys)
  }
}
