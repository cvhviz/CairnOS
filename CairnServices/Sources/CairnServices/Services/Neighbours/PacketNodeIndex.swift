import CoreLocation
import Foundation
import MeshCore

// MARK: - Unobserved Sharer

/// A node that shares a hash's prefix but is not a candidate for it: a saved contact or discovered
/// node this radio never observed on the channel, or a ledger node not observed lately. Only ever
/// a hint in a detail view ("Not heard on this channel: Kona Hill shares this prefix"), never a
/// name in a list row, a stop or a pin.
public struct UnobservedSharer: Sendable, Equatable {
  public enum Reason: Sendable, Equatable {
    /// Saved or discovered, but never observed by this radio on this channel.
    case notHeard
    /// Observed on this channel, last at this time: longer ago than the active window.
    case stale(lastObservedAt: Date)
  }

  public let entry: NeighbourKeyEntry
  public let reason: Reason

  public init(entry: NeighbourKeyEntry, reason: Reason) {
    self.entry = entry
    self.reason = reason
  }
}

// MARK: - Packet Node Index

/// What a received packet's hashes, keys and names can resolve to, for ``PacketNodeResolver``: the
/// one value the RX Log list, the Traffic map, Scan for Nodes and Home all resolve against, so
/// they can never disagree about which node a hash is.
///
/// Its candidates are the nodes of one ``LedgerSnapshot``: what this radio observed on one channel
/// (signed adverts it received, discover replies, decrypted messages, the radio's own
/// decrypt pushes, its own traces). Beside them, a saved contact or discovered node this radio
/// heard from within the active window stands in at the position it advertised until the ledger
/// holds it (``vouchedSavedNodes(_:ledger:observed:removed:since:)``). Older saved nodes, imported and
/// shared ones, and nodes heard on another channel are never candidates and never positions. They
/// only supply a nickname for a full key that was observed (`displayNames`) and the "not heard on
/// this channel" hints (`unobserved`, ``unobservedSharers(of:at:)``).
///
/// Everything it reads is in a stock `PUSH_CODE_LOG_RX_DATA` (0x88) frame, a stock push or the
/// app's own store, so it works the same on stock MeshCore and Cairn firmware.
public struct PacketNodeIndex: Sendable {
  /// A stored radio position this far from the phone's fix is stale (the radio was set up
  /// elsewhere), so the phone's fix anchors instead. A BLE companion is within metres of it.
  public static let staleRadioPositionDistance: CLLocationDistance = 50_000

  /// An index with no ledger: every short hash is unknown.
  public static let empty = PacketNodeIndex()

  /// The observations the candidates come from.
  public let ledger: LedgerSnapshot
  /// The ledger's nodes, active or stale, labelled (``NeighbourKeyEntry/init(_:displayName:)``),
  /// without the nodes being removed. Only the active ones are candidates.
  public let keys: NeighbourKeyIndex
  /// Ledger key prefixes held under a saved node's full key instead
  /// (``vouchedSavedNodes(_:ledger:observed:removed:since:)``).
  private let promotedKeys: [Data: Data]
  /// The saved nodes standing in for observations (``vouchedSavedNodes(_:ledger:observed:removed:since:)``'s
  /// `added`), by key.
  private let savedStandInKeys: [Data]
  /// Saved contacts and discovered nodes, for labels of keys a packet proves and for hints; only
  /// those heard lately are candidates too (``vouchedSavedNodes(_:ledger:observed:removed:since:)``).
  public let unobserved: NeighbourKeyIndex
  /// This radio's own key: a hash it starts names this radio. Never in ``keys``.
  public let selfKey: Data?
  /// This radio's advertised name, so its own channel messages read as this radio.
  public let selfName: String?
  /// Where this radio is (``anchor(device:phone:)``), for drawing and the unusually-long-link
  /// flag only; nil when neither the radio nor the phone has a position. Never decides identity.
  public let anchorLatitude: Double?
  public let anchorLongitude: Double?
  /// The full keys being removed (a Remove Nodes run): never candidates.
  public let excluded: Set<Data>
  /// Saved contacts' nicknames by full key.
  private let displayNames: [Data: String]

  /// - Parameters:
  ///   - ledger: The observations of the channel being resolved.
  ///   - selfKey: This radio's key when the ledger doesn't carry one (a cold ledger).
  ///   - selfName: This radio's advertised name.
  ///   - anchorLatitude: Where this radio is, for drawing only.
  ///   - displayNames: Saved contacts' nicknames by full key: a nickname replaces an observed
  ///     node's advertised name only for exactly its key.
  ///   - unobserved: Saved contacts and discovered nodes, for labels and hints.
  ///   - removed: Full keys being removed, never candidates.
  ///   - savedNodesHeardSince: When given, the saved and discovered nodes heard since then and
  ///     within the active window are candidates too (``vouchedSavedNodes(_:ledger:observed:removed:since:)``):
  ///     the last time this radio was on another channel, or `.distantPast` when it never was.
  public init(
    ledger: LedgerSnapshot = .empty,
    selfKey: Data? = nil,
    selfName: String? = nil,
    anchorLatitude: Double? = nil,
    anchorLongitude: Double? = nil,
    displayNames: [Data: String] = [:],
    unobserved: NeighbourKeyIndex = NeighbourKeyIndex(),
    excluding removed: Set<Data> = [],
    savedNodesHeardSince: Date? = nil
  ) {
    self.ledger = ledger
    let ownKey = (ledger.selfKey ?? selfKey).flatMap { $0.isEmpty ? nil : $0 }
    self.selfKey = ownKey
    let trimmedName = selfName?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.selfName = trimmedName?.isEmpty == false ? trimmedName : nil
    let hasAnchor = anchorLatitude.flatMap { lat in
      anchorLongitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0).isValidFix }
    } == true
    self.anchorLatitude = hasAnchor ? anchorLatitude : nil
    self.anchorLongitude = hasAnchor ? anchorLongitude : nil
    self.displayNames = displayNames.filter { !removed.contains($0.key) }
    excluded = removed
    self.unobserved = unobserved
    var observed = ledger.nodes
      .filter { !Self.isRemoved($0.identity.bytes, removed) }
      .map { NeighbourKeyEntry($0, displayName: displayNames[$0.identity.bytes]) }
    var promoted: [Data: Data] = [:]
    var standIns: [Data] = []
    if let savedNodesHeardSince {
      let vouched = Self.vouchedSavedNodes(
        unobserved, ledger: ledger, observed: NeighbourKeyIndex(selfKey: ownKey, entries: observed),
        removed: removed, since: savedNodesHeardSince
      )
      for (prefix, full) in vouched.promoted {
        guard let index = observed.firstIndex(where: { $0.publicKey == prefix }) else { continue }
        observed[index] = full
        promoted[prefix] = full.publicKey
      }
      observed += vouched.added
      standIns = vouched.added.map(\.publicKey)
    }
    promotedKeys = promoted
    savedStandInKeys = standIns
    keys = NeighbourKeyIndex(selfKey: ownKey, entries: observed)
  }

  /// The saved contacts and discovered nodes this radio heard from within the active window and
  /// since `since`, at the position they advertised, as candidates beside the ledger's: the radio
  /// keeps the adverts it hears while the app isn't connected in its contacts, so a radio new to
  /// the app, or back after a while, places the relays it knows before it has heard them again.
  /// A contact doesn't say which channel it was heard on, so `since` is the last time this radio
  /// was on another one: what it heard before that may be another mesh's. Only on a known channel
  /// and never one being removed.
  ///
  /// A node the ledger holds under its full key stands as observed. One it holds only under a key
  /// prefix (a reply that names 6 bytes of it) is the saved node with that key: `promoted` gives
  /// that observation the saved node's full key, filling a name, type or position it lacks, so it
  /// is placed as the node it is. The `added` ones are not among ``observedNodes``: nothing is
  /// pinned for them alone, only where a packet names them.
  static func vouchedSavedNodes(
    _ saved: NeighbourKeyIndex,
    ledger: LedgerSnapshot,
    observed: NeighbourKeyIndex,
    removed: Set<Data>,
    since: Date
  ) -> (added: [NeighbourKeyEntry], promoted: [Data: NeighbourKeyEntry]) {
    guard !ledger.isCold else { return ([], [:]) }
    let cutoff = max(ledger.takenAt.addingTimeInterval(-ObservationLedger.activeWindow), since)
    var added: [NeighbourKeyEntry] = []
    var promoted: [Data: NeighbourKeyEntry] = [:]
    for entry in saved.allEntries {
      // A repeater that never advertised a position still names its hops (the user, 2026-11-08);
      // it just isn't placed: every map skips an entry without a valid fix.
      guard let heard = entry.lastHeard, heard >= cutoff,
            !isRemoved(entry.publicKey, removed),
            entry.publicKey.count >= ObservedIdentity.minimumPrefixSize else { continue }
      let overlapping = observed.entries(overlapping: entry.publicKey)
      if overlapping.isEmpty {
        var vouched = entry
        vouched.isObserved = true
        added.append(vouched)
      } else if overlapping.count == 1, let prefix = overlapping.first,
                prefix.publicKey.count < entry.publicKey.count, entry.publicKey.starts(with: prefix.publicKey),
                promoted[prefix.publicKey] == nil {
        var full = prefix
        full.publicKey = entry.publicKey
        promoted[prefix.publicKey] = full.filling(from: entry)
      }
    }
    return (added, promoted)
  }

  /// The channel whose observations this index holds; nil when cold.
  public var channelKey: ChannelKey? {
    ledger.channelKey
  }

  /// The ledger's version: a change means results resolved against an older index may differ.
  public var version: Int {
    ledger.version
  }

  /// Whether no channel is known, so no hash can resolve.
  public var isCold: Bool {
    ledger.isCold
  }

  /// The anchor as a coordinate.
  public var anchor: CLLocationCoordinate2D? {
    guard let anchorLatitude, let anchorLongitude else { return nil }
    return CLLocationCoordinate2D(latitude: anchorLatitude, longitude: anchorLongitude)
  }

  // MARK: Observed nodes

  /// Every node observed on the channel, active or stale, labelled, most recently observed first.
  public var observedNodes: [NeighbourKeyEntry] {
    ledger.nodes.compactMap { keys.entry(for: promotedKeys[$0.identity.bytes] ?? $0.identity.bytes) }
  }

  /// The saved nodes standing in for observations, as candidates are: heard lately, at the
  /// position they advertised. Not in ``observedNodes``; a map that pins every node it knows on
  /// the channel (the Traffic map's quiet nodes) adds them.
  public var savedStandIns: [NeighbourKeyEntry] {
    savedStandInKeys.compactMap { keys.entry(for: $0) }
  }

  /// The observed nodes that are candidates for a packet received at `date` (nil: when the
  /// ledger was taken), most recently observed first.
  public func activeNodes(at date: Date? = nil) -> [NeighbourKeyEntry] {
    let date = date ?? ledger.takenAt
    return observedNodes.filter { isActive($0, at: date) }
  }

  /// Whether `entry` was observed within the ledger's active window before `date`.
  public func isActive(_ entry: NeighbourKeyEntry, at date: Date) -> Bool {
    guard entry.isObserved, let lastHeard = entry.lastHeard else { return false }
    return lastHeard >= date.addingTimeInterval(-ObservationLedger.activeWindow)
  }

  /// The active observed nodes whose key starts with `hash`, in key order.
  public func candidates(matching hash: Data, at date: Date) -> [NeighbourKeyEntry] {
    keys.candidates(matching: hash).filter { isActive($0, at: date) }
  }

  /// The active observed nodes that can be the node `key` names: keys starting with it, and
  /// shorter observed prefixes it starts with. In key order.
  public func candidates(overlapping key: Data, at date: Date) -> [NeighbourKeyEntry] {
    keys.entries(overlapping: key).filter { isActive($0, at: date) }
  }

  /// The active observed nodes that advertised exactly `name`. Nicknames are never matched.
  public func candidates(named name: String, at date: Date) -> [NeighbourKeyEntry] {
    keys.entries(named: name).filter { isActive($0, at: date) }
  }

  // MARK: Labels and hints

  /// A saved contact's nickname for exactly the full key `key`.
  public func displayName(forKey key: Data) -> String? {
    displayNames[key]
  }

  /// A label for a key a packet itself proves but no active observed node holds: a nickname for
  /// exactly that full key, else the name of the one saved or discovered node whose key starts
  /// with it, for a prefix of at least ``ObservedIdentity/minimumPrefixSize`` bytes (48 bits names
  /// one node). Never a position.
  public func label(forKey key: Data) -> String? {
    guard key.count >= ObservedIdentity.minimumPrefixSize else { return nil }
    if let nickname = displayNames[key] { return nickname }
    let sharers = unobserved.candidates(matching: key).filter { !Self.isRemoved($0.publicKey, excluded) }
    return sharers.count == 1 ? sharers[0].name : nil
  }

  /// The nodes sharing `hash` that are not candidates for a packet received at `date` (nil: when
  /// the ledger was taken): observed nodes not heard within the active window, most recently
  /// observed first, then saved and discovered nodes never observed here, in key order. Hints
  /// for a detail view only.
  public func unobservedSharers(of hash: Data, at date: Date? = nil) -> [UnobservedSharer] {
    guard !hash.isEmpty else { return [] }
    let date = date ?? ledger.takenAt
    let held = keys.candidates(matching: hash)
    let stale = held
      .filter { !isActive($0, at: date) }
      .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
      .map { UnobservedSharer(entry: $0, reason: .stale(lastObservedAt: $0.lastHeard ?? .distantPast)) }
    let heldKeys = Set(held.map(\.publicKey))
    let notHeard = unobserved.candidates(matching: hash)
      .filter { !heldKeys.contains($0.publicKey) && !Self.isRemoved($0.publicKey, excluded) }
      .filter { candidate in !keys.entries(overlapping: candidate.publicKey).contains { isActive($0, at: date) } }
      .map { UnobservedSharer(entry: $0, reason: .notHeard) }
    return stale + notHeard
  }

  /// Key prefixes (1, 2 and 3 bytes) to the name of the one active observed node each identifies;
  /// a prefix two nodes share is left out. For exports that carry one name per hash.
  public func uniqueNames() -> [Data: String] {
    var map: [Data: String] = [:]
    let entries = activeNodes()
    for size in NeighbourKeyIndex.bucketedPrefixSizes {
      var seen: [Data: (name: String?, count: Int)] = [:]
      for entry in entries where entry.publicKey.count >= size {
        let prefix = Data(entry.publicKey.prefix(size))
        seen[prefix] = (seen[prefix]?.name ?? entry.name, (seen[prefix]?.count ?? 0) + 1)
      }
      for (prefix, match) in seen where match.count == 1 {
        if let name = match.name { map[prefix] = name }
      }
    }
    return map
  }

  // MARK: Anchor

  /// Where this radio is, for drawing: its stored position, unless the phone has a fix more than
  /// ``staleRadioPositionDistance`` from it; with no stored position, the phone's fix.
  public static func anchor(
    device: DeviceDTO?,
    phone: CLLocationCoordinate2D?
  ) -> (latitude: Double, longitude: Double)? {
    let stored = device.flatMap { $0.hasLocation ? CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) : nil }
    return anchor(radio: stored, phone: phone)
  }

  /// ``anchor(device:phone:)`` from the radio's position as SELF_INFO or the store reports it.
  public static func anchor(
    radio: CLLocationCoordinate2D?,
    phone: CLLocationCoordinate2D?
  ) -> (latitude: Double, longitude: Double)? {
    let phoneFix = phone.flatMap { $0.isValidFix ? $0 : nil }
    if let stored = radio, stored.isValidFix {
      if let phoneFix, RFCalculator.distance(from: stored, to: phoneFix) > staleRadioPositionDistance {
        return (phoneFix.latitude, phoneFix.longitude)
      }
      return (stored.latitude, stored.longitude)
    }
    return phoneFix.map { ($0.latitude, $0.longitude) }
  }

  /// Whether `key` is being removed: it is one of `removed`, or the prefix of one.
  private static func isRemoved(_ key: Data, _ removed: Set<Data>) -> Bool {
    guard !removed.isEmpty else { return false }
    if removed.contains(key) { return true }
    return key.count < ObservedIdentity.publicKeySize && removed.contains { $0.starts(with: key) }
  }
}
