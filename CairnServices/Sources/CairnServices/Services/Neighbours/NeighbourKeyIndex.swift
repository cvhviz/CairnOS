import CoreLocation
import Foundation
import MeshCore

// MARK: - Key Entry

/// A node a path hash, key or name can be named with, and what is known about it.
///
/// An observed entry (``init(_:displayName:)``) is a node this radio observed on the channel
/// (``ObservedNode``): the only kind a hash resolves to. A saved contact or a discovered node
/// (the `ContactDTO` and `DiscoveredNodeDTO` initialisers) only labels or hints: it names a key the packet
/// itself proved, or says "not heard on this channel: Kona Hill shares this prefix". It is never
/// a candidate and never a position.
public struct NeighbourKeyEntry: Sendable, Equatable {
  /// The full 32-byte key, or the 6-31 byte prefix the node was observed by (a reply prefix, an
  /// 8-byte discover reply or trace hash) when no full key is known for it.
  public var publicKey: Data
  /// 1 chat, 2 repeater, 3 room, 4 sensor; 0 = not said.
  public var nodeTypeRaw: UInt8
  /// The name to show: a saved contact's nickname for exactly this key, else the name the node
  /// advertised.
  public var name: String?
  /// The name the node itself advertised on this channel, which a channel message's typed sender
  /// name is matched against. Never a nickname.
  public var advertisedName: String?
  /// The position the node itself advertised in a packet this radio received, in degrees; nil
  /// when it has none (0,0 is none). Never a contact's stored position for an observed entry.
  public var latitude: Double?
  public var longitude: Double?
  /// When the node was last observed (an observed entry), or its contact last changed (a hint).
  public var lastHeard: Date?
  /// When this radio last received a frame the node itself transmitted (0 hops). Nil when never.
  public var lastDirectAt: Date?
  /// The fewest relays any observation of the node crossed; nil when unknown.
  public var minHops: Int?
  /// The strongest way the node was observed (``ObservationKind/strength``); nil for a hint.
  public var strongestKind: ObservationKind?
  /// Observed by this radio on the channel being resolved. False for a contact or discovered
  /// node used only as a label or hint, and for a key a packet names that the ledger doesn't hold.
  public var isObserved: Bool

  public init(
    publicKey: Data,
    nodeTypeRaw: UInt8,
    name: String? = nil,
    advertisedName: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    lastHeard: Date? = nil,
    lastDirectAt: Date? = nil,
    minHops: Int? = nil,
    strongestKind: ObservationKind? = nil,
    isObserved: Bool = false
  ) {
    self.publicKey = publicKey
    self.nodeTypeRaw = nodeTypeRaw
    self.name = Self.trimmed(name)
    self.advertisedName = Self.trimmed(advertisedName)
    self.lastHeard = lastHeard
    self.lastDirectAt = lastDirectAt
    self.minHops = minHops
    self.strongestKind = strongestKind
    self.isObserved = isObserved
    let coordinate = latitude.flatMap { lat in
      longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
    }
    let hasFix = coordinate?.isValidFix == true
    self.latitude = hasFix ? latitude : nil
    self.longitude = hasFix ? longitude : nil
  }

  /// A node this radio observed, shown as `displayName` (a saved contact's nickname for exactly
  /// its key) when given, else by the name it advertised.
  public init(_ node: ObservedNode, displayName: String? = nil) {
    self.init(
      publicKey: node.identity.bytes,
      nodeTypeRaw: node.nodeTypeRaw ?? 0,
      name: Self.trimmed(displayName) ?? node.name,
      advertisedName: node.name,
      latitude: node.latitude,
      longitude: node.longitude,
      lastHeard: node.lastObservedAt,
      lastDirectAt: node.lastDirectAt,
      minHops: node.minHops,
      strongestKind: node.strongestKind,
      isObserved: true
    )
  }

  /// A saved contact, as a label or a hint only: never observed, never a candidate.
  public init(_ contact: ContactDTO) {
    self.init(
      publicKey: contact.publicKey,
      nodeTypeRaw: contact.typeRawValue,
      name: contact.displayName,
      latitude: contact.latitude,
      longitude: contact.longitude,
      lastHeard: contact.recencyDate
    )
  }

  /// A discovered node, as a label or a hint only: never observed, never a candidate.
  public init(_ node: DiscoveredNodeDTO) {
    self.init(
      publicKey: node.publicKey,
      nodeTypeRaw: node.typeRawValue,
      name: node.name,
      latitude: node.latitude,
      longitude: node.longitude,
      lastHeard: node.lastHeard
    )
  }

  /// A repeater, a room, or a node that didn't say: anything that can re-send a flood without
  /// client repeat.
  public var isRelayCapable: Bool {
    NeighbourKeyEntry.isRelayCapable(nodeTypeRaw)
  }

  static func isRelayCapable(_ nodeTypeRaw: UInt8) -> Bool {
    nodeTypeRaw != ContactType.chat.rawValue && nodeTypeRaw != sensorType
  }

  /// MeshCore's ADV_TYPE_SENSOR; `ContactType` has no case for it.
  static let sensorType: UInt8 = 4

  /// The node's position, when it has one.
  public var coordinate: CLLocationCoordinate2D? {
    guard let latitude, let longitude else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  /// This entry with the gaps filled from `other`: a name, type or position `self` doesn't have.
  /// The later of the two last-heard and direct times; observed if either is.
  func filling(from other: NeighbourKeyEntry) -> NeighbourKeyEntry {
    var merged = self
    if merged.nodeTypeRaw == 0 { merged.nodeTypeRaw = other.nodeTypeRaw }
    if merged.name == nil { merged.name = other.name }
    if merged.advertisedName == nil { merged.advertisedName = other.advertisedName }
    if merged.latitude == nil || merged.longitude == nil {
      merged.latitude = other.latitude
      merged.longitude = other.longitude
    }
    merged.lastHeard = [merged.lastHeard, other.lastHeard].compactMap(\.self).max()
    merged.lastDirectAt = [merged.lastDirectAt, other.lastDirectAt].compactMap(\.self).max()
    merged.minHops = [merged.minHops, other.minHops].compactMap(\.self).min()
    if let kind = other.strongestKind, merged.strongestKind.map({ kind.strength > $0.strength }) ?? true {
      merged.strongestKind = kind
    }
    merged.isObserved = merged.isObserved || other.isObserved
    return merged
  }

  private static func trimmed(_ name: String?) -> String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }
}

// MARK: - Key Index

/// Keys bucketed by their 1-, 2- and 3-byte prefixes so a hash of any size finds the keys that
/// start with it without a scan, and by advertised name so a channel message's sender name finds
/// its node.
///
/// ``PacketNodeIndex`` keeps two: the nodes observed on the channel (the only candidates) and the
/// saved and discovered nodes that only label keys and give "not heard on this channel" hints.
/// The radio's own key is never indexed: a hash it matches is our own echo.
public struct NeighbourKeyIndex: Sendable {
  /// The longest prefix kept as a bucket; a longer hash filters the 3-byte bucket.
  static let bucketedPrefixSizes = 1...3

  private var entries: [Data: NeighbourKeyEntry] = [:]
  private var buckets: [Data: Set<Data>] = [:]
  private var names: [String: Set<Data>] = [:]
  private let selfKey: Data?

  public init(selfKey: Data? = nil, entries: [NeighbourKeyEntry] = []) {
    self.selfKey = selfKey
    for entry in entries {
      upsert(entry)
    }
  }

  public var count: Int { entries.count }

  /// Adds a key, or fills the gaps in a known one from `entry`: what is stored wins, so the
  /// first entry given for a key (a contact before a discovered row) keeps its name.
  public mutating func upsert(_ entry: NeighbourKeyEntry) {
    let key = entry.publicKey
    guard !key.isEmpty, !isSelf(key) else { return }
    if let stored = entries[key] {
      let merged = stored.filling(from: entry)
      entries[key] = merged
      if Self.nameKey(stored.advertisedName) != Self.nameKey(merged.advertisedName) {
        removeName(stored.advertisedName, for: key)
        insertName(merged.advertisedName, for: key)
      }
      return
    }
    entries[key] = entry
    for size in Self.bucketedPrefixSizes where key.count >= size {
      buckets[Data(key.prefix(size)), default: []].insert(key)
    }
    insertName(entry.advertisedName, for: key)
  }

  public mutating func remove(publicKey key: Data) {
    guard let removed = entries.removeValue(forKey: key) else { return }
    for size in Self.bucketedPrefixSizes where key.count >= size {
      let prefix = Data(key.prefix(size))
      buckets[prefix]?.remove(key)
      if buckets[prefix]?.isEmpty == true { buckets[prefix] = nil }
    }
    removeName(removed.advertisedName, for: key)
  }

  public func entry(for publicKey: Data) -> NeighbourKeyEntry? {
    entries[publicKey]
  }

  /// Every indexed key, in key order.
  public var allEntries: [NeighbourKeyEntry] {
    entries.keys
      .sorted { $0.lexicographicallyPrecedes($1) }
      .compactMap { entries[$0] }
  }

  /// The keys whose advertised name is exactly `name` (trimmed, case-sensitive), in key order.
  public func entries(named name: String) -> [NeighbourKeyEntry] {
    guard let nameKey = Self.nameKey(name), let keys = names[nameKey] else { return [] }
    return keys
      .sorted { $0.lexicographicallyPrecedes($1) }
      .compactMap { entries[$0] }
  }

  /// The keys that start with `hash`, in key order so ties break the same way every time.
  public func candidates(matching hash: Data) -> [NeighbourKeyEntry] {
    guard !hash.isEmpty else { return [] }
    let bucketSize = min(hash.count, Self.bucketedPrefixSizes.upperBound)
    let keys = buckets[Data(hash.prefix(bucketSize))] ?? []
    return keys
      .filter { $0.starts(with: hash) }
      .sorted { $0.lexicographicallyPrecedes($1) }
      .compactMap { entries[$0] }
  }

  /// The keys that can name the same node as `key`: those starting with it, and the shorter
  /// prefixes it starts with (a 6-byte reply prefix for a full key). In key order.
  public func entries(overlapping key: Data) -> [NeighbourKeyEntry] {
    guard !key.isEmpty else { return [] }
    var found = Dictionary(uniqueKeysWithValues: candidates(matching: key).map { ($0.publicKey, $0) })
    let bucketSize = min(key.count, Self.bucketedPrefixSizes.upperBound)
    for stored in buckets[Data(key.prefix(bucketSize))] ?? [] where stored.count < key.count && key.starts(with: stored) {
      found[stored] = entries[stored]
    }
    return found.keys
      .sorted { $0.lexicographicallyPrecedes($1) }
      .compactMap { found[$0] }
  }

  private mutating func insertName(_ name: String?, for key: Data) {
    guard let nameKey = Self.nameKey(name) else { return }
    names[nameKey, default: []].insert(key)
  }

  private mutating func removeName(_ name: String?, for key: Data) {
    guard let nameKey = Self.nameKey(name) else { return }
    names[nameKey]?.remove(key)
    if names[nameKey]?.isEmpty == true { names[nameKey] = nil }
  }

  /// The form a name is bucketed under: trimmed, nil when empty.
  private static func nameKey(_ name: String?) -> String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private func isSelf(_ key: Data) -> Bool {
    guard let selfKey, !selfKey.isEmpty else { return false }
    return key.starts(with: selfKey) || selfKey.starts(with: key)
  }
}
