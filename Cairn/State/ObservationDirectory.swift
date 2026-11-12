import CairnServices
import CoreLocation
import Foundation
import MeshCore
import Observation

/// What this radio observed on its channel, as the one index every screen resolves packets
/// against: the RX Log list, the Traffic map and the traffic layer on the other maps. A hash
/// names only a node this radio heard on the channel the packet was received on, so the screens
/// can never disagree about which node it is, and none can name a saved contact it never heard.
///
/// The observations come from `NeighbourService` (``NeighbourDirectory/snapshot``'s ledger), which
/// switches channel with the radio. Saved contacts and discovered nodes only label: a nickname for
/// a full key that was observed, and the "not heard on this channel" hints of a detail view
/// (``PacketNodeIndex``). Their pages open from here by exact key; their positions are never used.
@Observable
@MainActor
final class ObservationDirectory {
  /// Channels other than the current one whose index is kept, for RX log rows received there.
  static let otherChannelCapacity = 4
  /// How far the anchor (this radio's stored position, or the phone's fix) moves before the index
  /// is rebuilt for it. It only places this radio on the map and flags unusually long links.
  static let anchorTolerance: CLLocationDistance = 500
  /// How lately the oldest node on the current channel was first heard for the app to still be
  /// learning it: hops show by hash until their nodes' adverts arrive.
  static let learningWindow: TimeInterval = 24 * 60 * 60
  /// How stale the current ledger's time may grow before an otherwise unchanged snapshot is taken
  /// in. `NeighbourService` stamps every snapshot it sends (as often as once a second) with the
  /// time; only this coarse refresh is needed to keep the 7-day active window current.
  static let ledgerRefreshInterval: TimeInterval = 15 * 60

  /// The current channel's index; cold (every hash unknown) until the radio has reported its
  /// channel.
  private(set) var nodeIndex = PacketNodeIndex.empty
  /// Bumped whenever an index a row could be resolved against changes: the current ledger, a
  /// label, this radio, the nodes being removed, or another channel's ledger read in.
  private(set) var version = 0
  /// Saved contacts by full key, for a node's page and its pin's avatar only.
  private(set) var contactsByKey: [Data: ContactDTO] = [:]
  /// Discovered nodes by full key, for a node's page only.
  private(set) var discoveredByKey: [Data: DiscoveredNodeDTO] = [:]

  /// Reads another channel's ledger (`NeighbourService.ledgerSnapshot(channelKey:)`); nil while
  /// disconnected.
  @ObservationIgnored var ledgerLoader: (@MainActor (ChannelKey) async -> LedgerSnapshot?)?

  @ObservationIgnored private var ledger = LedgerSnapshot.empty
  @ObservationIgnored private var displayNames: [Data: String] = [:]
  @ObservationIgnored private var unobserved = NeighbourKeyIndex()
  @ObservationIgnored private var selfKey: Data?
  @ObservationIgnored private var selfName: String?
  @ObservationIgnored private var anchor: CLLocationCoordinate2D?
  @ObservationIgnored private var excluding: Set<Data> = []
  /// What rows stored before channels were recorded resolve against: no ledger, so only what a
  /// packet proves itself is named.
  @ObservationIgnored private var unstampedIndex = PacketNodeIndex.empty
  /// Other channels' ledgers and indexes, the most recently used last.
  @ObservationIgnored private var otherLedgers: [ChannelKey: LedgerSnapshot] = [:]
  @ObservationIgnored private var otherIndexes: [ChannelKey: PacketNodeIndex] = [:]
  @ObservationIgnored private var otherOrder: [ChannelKey] = []
  @ObservationIgnored private var loadingKeys: Set<ChannelKey> = []
  /// The contacts version and radio the labels were last read for, and the read in flight.
  @ObservationIgnored private var labelsKey: String?
  /// Since when this radio's saved nodes stand in on a channel, by radio and channel: the last
  /// time it was on another one, or `.distantPast` when it never was.
  @ObservationIgnored private var savedNodesWindow: (radioID: UUID, channel: ChannelKey, since: Date)?
  @ObservationIgnored private var savedNodesWindowKey: String?
  @ObservationIgnored private var labelsGeneration = 0

  init() {}

  // MARK: - Reading

  /// The index `entry` resolves against (R0): the current channel's when it was received there,
  /// another channel's once read in (cold until then, so its hashes show unknown rather than be
  /// named from the wrong channel), and none for an entry stored before channels were recorded.
  func index(for entry: RxLogEntryDTO) -> PacketNodeIndex {
    guard let key = entry.channelKey else { return unstampedIndex }
    if key == nodeIndex.channelKey { return nodeIndex }
    if let index = otherIndexes[key] {
      touch(key)
      return index
    }
    loadLedger(for: key)
    return unstampedIndex
  }

  /// The current ledger's channel; nil while cold.
  var currentChannelKey: ChannelKey? {
    ledger.channelKey
  }

  /// The channel the radio is on, as it reported it; nil until then.
  var currentChannel: RadioChannelConfig? {
    ledger.channel ?? ledger.channelKey.flatMap(RadioChannelConfig.init(key:))
  }

  /// The nodes heard on the current channel within the active window.
  var ledgerNodeCount: Int {
    nodeIndex.activeNodes().count
  }

  /// Whether the app has only lately started hearing the current channel: no node on it, or the
  /// first heard within ``learningWindow``.
  func isLearningChannel(now: Date = .now) -> Bool {
    guard !ledger.isCold else { return false }
    guard let first = ledger.nodes.map(\.firstObservedAt).min() else { return true }
    return now.timeIntervalSince(first) < Self.learningWindow
  }

  func contact(forKey key: Data) -> ContactDTO? {
    contactsByKey[key]
  }

  func discovered(forKey key: Data) -> DiscoveredNodeDTO? {
    discoveredByKey[key]
  }

  // MARK: - Inputs

  /// The current channel's observations, as `NeighbourService` last published them. Another
  /// radio's ledger forgets the other channels read in. A snapshot that resolves exactly as the
  /// current one (same radio, channel, key and version: only its time differs) changes nothing,
  /// so the screens don't re-resolve every row each time the neighbour table ticks.
  func setLedger(_ newLedger: LedgerSnapshot) {
    guard !resolvesAlike(newLedger, ledger) else { return }
    if newLedger.radioID != nil, newLedger.radioID != ledger.radioID {
      otherLedgers = [:]
      otherIndexes = [:]
      otherOrder = []
    }
    ledger = newLedger
    if let key = newLedger.channelKey {
      // The current channel answers from the live ledger now, not a copy read earlier
      otherLedgers[key] = nil
      otherIndexes[key] = nil
      otherOrder.removeAll { $0 == key }
    }
    nodeIndex = makeIndex(newLedger)
    version &+= 1
  }

  /// Saved contacts and discovered nodes: nicknames for observed keys, hints, and pages.
  func setLabels(contacts: [ContactDTO], discovered: [DiscoveredNodeDTO]) {
    contactsByKey = Dictionary(contacts.map { ($0.publicKey, $0) }, uniquingKeysWith: { first, _ in first })
    discoveredByKey = Dictionary(discovered.map { ($0.publicKey, $0) }, uniquingKeysWith: { first, _ in first })
    displayNames = contactsByKey.compactMapValues { contact in
      let name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty ? nil : name
    }
    rebuildUnobserved()
    rebuildAll()
  }

  /// This radio: its key names it, its name names its own channel messages, and `anchor` places
  /// it on the map. An anchor that moved less than ``anchorTolerance`` changes nothing.
  func setRadio(selfKey: Data?, selfName: String?, anchor: CLLocationCoordinate2D?) {
    let movedFar: Bool = switch (self.anchor, anchor) {
    case (nil, nil): false
    case let (old?, new?): RFCalculator.distance(from: old, to: new) > Self.anchorTolerance
    default: true
    }
    guard selfKey != self.selfKey || selfName != self.selfName || movedFar else { return }
    self.selfKey = selfKey
    self.selfName = selfName
    if movedFar { self.anchor = anchor }
    rebuildUnobserved()
    rebuildAll()
  }

  /// The nodes a Remove Nodes run is taking off the radio: never candidates.
  func setExcluding(_ keys: Set<Data>) {
    guard keys != excluding else { return }
    excluding = keys
    rebuildAll()
  }

  /// Reads the labels again when the contacts or the radio changed since the last read; a read
  /// overtaken by a newer one is dropped.
  func reloadLabels(
    key: String,
    load: @escaping @MainActor () async -> (contacts: [ContactDTO], discovered: [DiscoveredNodeDTO])?
  ) {
    guard key != labelsKey else { return }
    labelsKey = key
    labelsGeneration &+= 1
    let generation = labelsGeneration
    Task { [weak self] in
      let labels = await load()
      guard let self, generation == self.labelsGeneration else { return }
      setLabels(contacts: labels?.contacts ?? [], discovered: labels?.discovered ?? [])
    }
  }

  /// Whether `new` resolves every packet as `old` does: only the time differs, by less than
  /// ``ledgerRefreshInterval``.
  private func resolvesAlike(_ new: LedgerSnapshot, _ old: LedgerSnapshot) -> Bool {
    new.radioID == old.radioID && new.channelKey == old.channelKey && new.channel == old.channel
      && new.selfKey == old.selfKey && new.version == old.version
      && abs(new.takenAt.timeIntervalSince(old.takenAt)) < Self.ledgerRefreshInterval
  }

  // MARK: - Building

  private func makeIndex(_ ledger: LedgerSnapshot) -> PacketNodeIndex {
    PacketNodeIndex(
      ledger: ledger,
      selfKey: selfKey,
      selfName: selfName,
      anchorLatitude: anchor?.latitude,
      anchorLongitude: anchor?.longitude,
      displayNames: displayNames,
      unobserved: unobserved,
      excluding: excluding,
      savedNodesHeardSince: savedNodesSince(for: ledger)
    )
  }

  /// The saved nodes stand in only on the channel and radio their window was read for.
  private func savedNodesSince(for ledger: LedgerSnapshot) -> Date? {
    guard let window = savedNodesWindow, window.radioID == ledger.radioID,
          window.channel == ledger.channelKey else { return nil }
    return window.since
  }

  /// Reads again, for this radio on its current channel, since when its saved nodes stand in.
  func reloadSavedNodesWindow(
    radioID: UUID?,
    channel: ChannelKey?,
    load: @escaping @MainActor (UUID, ChannelKey) async -> Date??
  ) {
    let key = "\(radioID?.uuidString ?? "")-\(channel?.rawValue ?? "")"
    guard key != savedNodesWindowKey else { return }
    savedNodesWindowKey = key
    guard let radioID, let channel else {
      if savedNodesWindow != nil {
        savedNodesWindow = nil
        rebuildAll()
      }
      return
    }
    Task { [weak self] in
      // nil: the store couldn't say, so nothing stands in
      let loaded = await load(radioID, channel)
      guard let self, key == self.savedNodesWindowKey else { return }
      savedNodesWindow = loaded.map { (radioID, channel, $0 ?? .distantPast) }
      rebuildAll()
    }
  }

  private func rebuildUnobserved() {
    unobserved = NeighbourKeyIndex(
      selfKey: selfKey,
      entries: contactsByKey.values.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }.map(NeighbourKeyEntry.init)
        + discoveredByKey.values.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }.map(NeighbourKeyEntry.init)
    )
  }

  private func rebuildAll() {
    nodeIndex = makeIndex(ledger)
    unstampedIndex = makeIndex(.empty)
    otherIndexes = otherLedgers.mapValues(makeIndex)
    version &+= 1
  }

  // MARK: - Other channels

  private func touch(_ key: ChannelKey) {
    otherOrder.removeAll { $0 == key }
    otherOrder.append(key)
  }

  /// Reads `key`'s ledger once, then keeps it among the ``otherChannelCapacity`` most recently
  /// used.
  private func loadLedger(for key: ChannelKey) {
    guard let ledgerLoader, !loadingKeys.contains(key) else { return }
    loadingKeys.insert(key)
    Task { [weak self] in
      let loaded = await ledgerLoader(key)
      guard let self else { return }
      loadingKeys.remove(key)
      guard let loaded, key != nodeIndex.channelKey else { return }
      store(loaded, for: key)
    }
  }

  /// Keeps `ledger` as `key`'s, dropping the least recently used past the capacity.
  func store(_ ledger: LedgerSnapshot, for key: ChannelKey) {
    otherLedgers[key] = ledger
    otherIndexes[key] = makeIndex(ledger)
    touch(key)
    while otherOrder.count > Self.otherChannelCapacity {
      let dropped = otherOrder.removeFirst()
      otherLedgers[dropped] = nil
      otherIndexes[dropped] = nil
    }
    version &+= 1
  }

  /// How many other channels' indexes are kept.
  var otherChannelCount: Int {
    otherIndexes.count
  }
}

// MARK: - App wiring

extension AppState {
  /// Keeps ``observationDirectory`` on what it reads: the neighbour directory's ledger, this radio
  /// and where it is, the nodes being removed, and the saved and discovered nodes as they change.
  func followObservations() {
    observationDirectory.ledgerLoader = { [weak self] key in
      await self?.services?.neighbourService.ledgerSnapshot(channelKey: key)
    }
    trackObservationInputs()
  }

  /// Applies the inputs as they stand, and again on their next change.
  private func trackObservationInputs() {
    withObservationTracking {
      applyObservationInputs()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.trackObservationInputs() }
    }
  }

  private func applyObservationInputs() {
    let directory = observationDirectory
    directory.setLedger(neighbourDirectory.snapshot?.ledger ?? .empty)
    let device = connectedDevice
    let anchor = PacketNodeIndex.anchor(device: device, phone: bestAvailableLocation?.coordinate)
    directory.setRadio(
      selfKey: device?.publicKey,
      selfName: device?.nodeName,
      anchor: anchor.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    )
    directory.setExcluding(nodeRemoval.removingKeys)
    let radioID = currentRadioID
    directory.reloadLabels(key: "\(contactsVersion)-\(radioID?.uuidString ?? "")") { [weak self] in
      guard let self, let radioID, let store = services?.dataStore ?? offlineDataStore else { return nil }
      let contacts = (try? await store.fetchContacts(radioID: radioID)) ?? []
      let discovered = (try? await store.fetchDiscoveredNodes(radioID: radioID)) ?? []
      return (contacts, discovered)
    }
    // A saved node doesn't say which channel it was heard on: only what this radio heard since it
    // was last on another channel stands in for its observations here.
    directory.reloadSavedNodesWindow(radioID: radioID, channel: directory.currentChannelKey) { [weak self] radioID, channel in
      guard let self, let store = services?.dataStore ?? offlineDataStore else { return nil }
      do {
        return .some(try await store.fetchLatestObservation(radioID: radioID, otherThan: channel))
      } catch {
        return nil
      }
    }
  }
}
