import Foundation
import MeshCore

// MARK: - Identity

/// A node this radio proved it heard: by its full public key, or by a key prefix of at least
/// ``minimumPrefixSize`` bytes, which is long enough to name one node.
///
/// A 1-3 byte relay hash is never an identity: many keys share one, and a packet's path is only
/// what the packet claims.
public enum ObservedIdentity: Sendable, Hashable {
  /// A full 32-byte public key.
  case fullKey(Data)
  /// The first 6 to 31 bytes of a public key: the 6-byte prefix the radio's own login, status,
  /// telemetry and path-discovery replies carry, or the 8-byte key of a prefix-only discover reply
  /// or trace hash.
  case keyPrefix(Data)

  public static let publicKeySize = 32
  /// 48 bits: the shortest prefix the radio's replies carry, and long enough that two keys sharing
  /// one by chance is negligible.
  public static let minimumPrefixSize = 6

  /// The identity `bytes` name: a full key for 32 bytes, a prefix for 6 to 31; nil for anything
  /// shorter or longer.
  public init?(bytes: Data) {
    switch bytes.count {
    case Self.publicKeySize: self = .fullKey(Data(bytes))
    case Self.minimumPrefixSize..<Self.publicKeySize: self = .keyPrefix(Data(bytes))
    default: return nil
    }
  }

  /// The key or the prefix.
  public var bytes: Data {
    switch self {
    case let .fullKey(data), let .keyPrefix(data): data
    }
  }

  public var isPrefix: Bool {
    if case .keyPrefix = self { true } else { false }
  }

  /// Whether this identity starts with `hash`, a path or packet hash of any length. Empty bytes
  /// never match.
  public func hasPrefix(_ hash: Data) -> Bool {
    !hash.isEmpty && hash.count <= bytes.count && bytes.starts(with: hash)
  }

  /// Whether this identity and `other` can name the same node: one's bytes start with the other's.
  public func overlaps(_ other: ObservedIdentity) -> Bool {
    let mine = bytes
    let theirs = other.bytes
    return mine.count <= theirs.count ? theirs.starts(with: mine) : mine.starts(with: theirs)
  }

  /// Whether this identity names this radio itself: `selfKey` starts with it.
  public func isSelf(_ selfKey: Data?) -> Bool {
    guard let selfKey, selfKey.count >= bytes.count else { return false }
    return selfKey.starts(with: bytes)
  }

  /// The bytes as lowercase hex.
  public var hex: String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Kind

/// How this radio observed a node. Raw values are stored: never renumber.
public enum ObservationKind: Int, Sendable, Hashable, CaseIterable, Codable {
  /// A signed advert received straight from the node (0 hops); the app checked the signature.
  case advertDirect = 0
  /// A signed advert received over one or more relays; the app checked the signature.
  case advertRelayed = 1
  /// A 0-hop discover reply carrying the node's 8- or 32-byte key.
  case discoverReply = 2
  /// A direct message this app decrypted with that contact's shared secret, sent by the contact.
  case decryptedMessage = 3
  /// The radio's own live advert push (0x80) or new-contact push (0x8A). No longer recorded: the
  /// firmware pushes these for an imported contact too, never heard over the air. Kept so rows
  /// stored by earlier builds decode; a row observed only this way is dropped on load
  /// (``ObservedNode/isOnlyAdvertPush``).
  case radioVerifiedAdvert = 4
  /// A reply the radio decrypted from the node: path update (0x81), login (0x85), status (0x87),
  /// telemetry (0x8B) or path discovery (0x8D).
  case radioDecryptedReply = 5
  /// An 8-byte hash answering in a trace this session sent.
  case ownTraceHop = 6

  /// How much an observation of this kind says about the node, highest first: heard directly
  /// with its key, then its signed identity, then what the radio vouched for, then a trace hash.
  public var strength: Int {
    switch self {
    case .advertDirect: 6
    case .discoverReply: 5
    case .advertRelayed: 4
    case .radioVerifiedAdvert: 3
    case .decryptedMessage: 2
    case .radioDecryptedReply: 1
    case .ownTraceHop: 0
    }
  }
}

/// How often, and when last, a node was observed one way.
public struct KindStat: Sendable, Equatable, Codable {
  /// Observations newer than the previous one of the same kind. Replaying an observation, or an
  /// older one arriving late, does not count again, so this is a lower bound.
  public var count: Int
  public var lastAt: Date

  public init(count: Int, lastAt: Date) {
    self.count = count
    self.lastAt = lastAt
  }
}

// MARK: - Observation

/// One proof that this radio heard a node on one channel, as ``ObservationExtractor`` reads it
/// from a received packet or a radio push.
public struct NodeObservation: Sendable, Equatable {
  public let identity: ObservedIdentity
  public let kind: ObservationKind
  /// The channel the radio was on when it received the proof.
  public let channelKey: ChannelKey
  /// When the radio received it.
  public let at: Date
  /// How many relays the proof crossed: 0 when the node itself transmitted the frame this radio
  /// received, nil when the packet doesn't say.
  public let hops: Int?
  /// The frame's SNR and RSSI at this radio. Set only when ``hops`` is 0, since only then was the
  /// node the transmitter.
  public let snr: Double?
  public let rssi: Int?
  public let name: String?
  /// 1 chat, 2 repeater, 3 room, 4 sensor; nil when not said.
  public let nodeTypeRaw: UInt8?
  /// The position the node advertised itself, in degrees: only from its own signed advert.
  /// Both or neither; 0,0 means none.
  public let latitude: Double?
  public let longitude: Double?
  /// The RX log entry the proof came from, when it came from one.
  public let entryID: UUID?

  public init(
    identity: ObservedIdentity,
    kind: ObservationKind,
    channelKey: ChannelKey,
    at: Date,
    hops: Int?,
    snr: Double? = nil,
    rssi: Int? = nil,
    name: String? = nil,
    nodeTypeRaw: UInt8? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    entryID: UUID? = nil
  ) {
    self.identity = identity
    self.kind = kind
    self.channelKey = channelKey
    self.at = at
    self.hops = hops
    let isDirect = hops == 0
    self.snr = isDirect ? snr : nil
    self.rssi = isDirect ? rssi : nil
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.name = trimmed?.isEmpty == false ? trimmed : nil
    self.nodeTypeRaw = nodeTypeRaw
    if let latitude, let longitude, latitude.isFinite, longitude.isFinite, latitude != 0 || longitude != 0 {
      self.latitude = latitude
      self.longitude = longitude
    } else {
      self.latitude = nil
      self.longitude = nil
    }
    self.entryID = entryID
  }

  /// This observation under another identity: a prefix folded into the full key it belongs to.
  func with(identity: ObservedIdentity) -> NodeObservation {
    NodeObservation(
      identity: identity,
      kind: kind,
      channelKey: channelKey,
      at: at,
      hops: hops,
      snr: snr,
      rssi: rssi,
      name: name,
      nodeTypeRaw: nodeTypeRaw,
      latitude: latitude,
      longitude: longitude,
      entryID: entryID
    )
  }
}

// MARK: - Observed Node

/// Everything this radio observed of one node on one channel.
///
/// Merging keeps the newest name, type and position, never lets a missing value erase a stored
/// one, and changes nothing when the same observation arrives again.
public struct ObservedNode: Sendable, Equatable {
  public internal(set) var identity: ObservedIdentity
  public internal(set) var name: String?
  public internal(set) var nodeTypeRaw: UInt8?
  /// The position the node last advertised, and when this radio received it.
  public internal(set) var latitude: Double?
  public internal(set) var longitude: Double?
  public internal(set) var positionAt: Date?
  public internal(set) var firstObservedAt: Date
  public internal(set) var lastObservedAt: Date
  /// The newest time the node itself transmitted a frame this radio received (0 hops).
  public internal(set) var lastDirectAt: Date?
  /// The SNR and RSSI of the newest direct reception that carried them.
  public internal(set) var lastDirectSNR: Double?
  public internal(set) var lastDirectRSSI: Int?
  /// The fewest hops any observation crossed, and the hops of the newest one that said.
  public internal(set) var minHops: Int?
  public internal(set) var lastHops: Int?
  public internal(set) var kinds: [ObservationKind: KindStat]

  public init(
    identity: ObservedIdentity,
    name: String? = nil,
    nodeTypeRaw: UInt8? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    positionAt: Date? = nil,
    firstObservedAt: Date,
    lastObservedAt: Date,
    lastDirectAt: Date? = nil,
    lastDirectSNR: Double? = nil,
    lastDirectRSSI: Int? = nil,
    minHops: Int? = nil,
    lastHops: Int? = nil,
    kinds: [ObservationKind: KindStat] = [:]
  ) {
    self.identity = identity
    self.name = name
    self.nodeTypeRaw = nodeTypeRaw
    self.latitude = latitude
    self.longitude = longitude
    self.positionAt = positionAt
    self.firstObservedAt = firstObservedAt
    self.lastObservedAt = lastObservedAt
    self.lastDirectAt = lastDirectAt
    self.lastDirectSNR = lastDirectSNR
    self.lastDirectRSSI = lastDirectRSSI
    self.minHops = minHops
    self.lastHops = lastHops
    self.kinds = kinds
  }

  /// A node seen once, by `observation`.
  public init(observation: NodeObservation) {
    self.init(identity: observation.identity, firstObservedAt: observation.at, lastObservedAt: observation.at)
    merge(observation, isFirst: true)
  }

  /// The strongest way the node was observed (``ObservationKind/strength``).
  public var strongestKind: ObservationKind? {
    kinds.keys.max { $0.strength < $1.strength }
  }

  /// Whether the node was observed only by the radio's advert pushes, stored by earlier builds:
  /// no proof it was ever heard (an imported contact gets the same pushes).
  public var isOnlyAdvertPush: Bool {
    !kinds.isEmpty && kinds.keys.allSatisfy { $0 == .radioVerifiedAdvert }
  }

  /// Whether the node has an advertised position.
  public var hasPosition: Bool {
    latitude != nil && longitude != nil
  }

  /// Folds `observation` in.
  /// - Returns: Whether anything changed.
  @discardableResult
  public mutating func merge(_ observation: NodeObservation) -> Bool {
    let before = self
    merge(observation, isFirst: false)
    return self != before
  }

  private mutating func merge(_ observation: NodeObservation, isFirst: Bool) {
    let at = observation.at
    let isNewest = isFirst || at > lastObservedAt

    if let name = observation.name, isNewest || self.name == nil {
      self.name = name
    }
    if let type = observation.nodeTypeRaw, type != 0, isNewest || nodeTypeRaw == nil {
      nodeTypeRaw = type
    }
    if let latitude = observation.latitude, let longitude = observation.longitude,
       positionAt.map({ at > $0 }) ?? true {
      self.latitude = latitude
      self.longitude = longitude
      positionAt = at
    }
    if let hops = observation.hops {
      minHops = min(minHops ?? hops, hops)
      if isNewest || lastHops == nil {
        lastHops = hops
      }
      if hops == 0, lastDirectAt.map({ at > $0 }) ?? true {
        lastDirectAt = at
        if let snr = observation.snr { lastDirectSNR = snr }
        if let rssi = observation.rssi { lastDirectRSSI = rssi }
      }
    }
    if let stat = kinds[observation.kind] {
      if at > stat.lastAt {
        kinds[observation.kind] = KindStat(count: stat.count + 1, lastAt: at)
      }
    } else {
      kinds[observation.kind] = KindStat(count: 1, lastAt: at)
    }
    firstObservedAt = min(firstObservedAt, at)
    lastObservedAt = max(lastObservedAt, at)
  }

  /// Folds in everything `other` holds: a prefix row joining the full key it belongs to.
  mutating func absorb(_ other: ObservedNode) {
    let otherIsNewer = other.lastObservedAt > lastObservedAt
    if let otherName = other.name, otherIsNewer || name == nil { name = otherName }
    if let otherType = other.nodeTypeRaw, otherIsNewer || nodeTypeRaw == nil { nodeTypeRaw = otherType }
    if let otherAt = other.positionAt, positionAt.map({ otherAt > $0 }) ?? true {
      latitude = other.latitude
      longitude = other.longitude
      positionAt = otherAt
    }
    if let otherDirect = other.lastDirectAt, lastDirectAt.map({ otherDirect > $0 }) ?? true {
      lastDirectAt = otherDirect
      if let snr = other.lastDirectSNR { lastDirectSNR = snr }
      if let rssi = other.lastDirectRSSI { lastDirectRSSI = rssi }
    }
    if let otherMin = other.minHops { minHops = min(minHops ?? otherMin, otherMin) }
    if let otherLast = other.lastHops, otherIsNewer || lastHops == nil { lastHops = otherLast }
    for (kind, stat) in other.kinds {
      if let mine = kinds[kind] {
        kinds[kind] = KindStat(count: mine.count + stat.count, lastAt: max(mine.lastAt, stat.lastAt))
      } else {
        kinds[kind] = stat
      }
    }
    firstObservedAt = min(firstObservedAt, other.firstObservedAt)
    lastObservedAt = max(lastObservedAt, other.lastObservedAt)
  }
}

// MARK: - Ledger

/// The nodes one radio has observed on one channel (``ChannelKey``), and nothing else.
///
/// Saved contacts, imported or shared nodes and nodes heard on another channel never enter: only
/// ``NodeObservation``s do, which ``ObservationExtractor`` reads from packets this radio received
/// on this channel and from the radio's own live replies. A prefix identity folds into the full
/// key it belongs to once that key is observed. Pure: the caller supplies the time, persists
/// ``takeChanges()`` and publishes ``snapshot(takenAt:version:)``.
public struct ObservationLedger: Sendable {
  /// A node is active while its newest observation is at most this old, measured from the time of
  /// the packet being resolved: the same window as the neighbour table.
  public static let activeWindow: TimeInterval = 7 * 24 * 3600
  /// Rows not observed for this long are deleted.
  public static let retention: TimeInterval = 30 * 24 * 3600
  /// The most rows one channel keeps; the least recently observed go first.
  public static let capacity = 4096

  public let radioID: UUID
  public let channelKey: ChannelKey
  /// The channel as the radio reported it (with its coding rate), when known.
  public let channel: RadioChannelConfig?
  /// This radio's own key, which is never a node in its ledger.
  public let selfKey: Data?
  /// Bumped by every change, so a consumer can tell a snapshot is newer.
  public private(set) var version = 0

  private var nodes: [ObservedIdentity: ObservedNode] = [:]
  /// The prefix rows, kept apart so a full key's fold scans only them.
  private var prefixIdentities: Set<ObservedIdentity> = []
  private var upserted: Set<ObservedIdentity> = []
  private var removed: Set<ObservedIdentity> = []
  private let capacity: Int

  /// A ledger holding `nodes`, as loaded from the store. Loading changes nothing to persist,
  /// unless two stored rows name the same node and fold into one, or a row was observed only by
  /// the radio's advert pushes (``ObservedNode/isOnlyAdvertPush``), which is deleted.
  public init(
    radioID: UUID,
    channelKey: ChannelKey,
    channel: RadioChannelConfig? = nil,
    selfKey: Data?,
    nodes: [ObservedNode] = [],
    capacity: Int = ObservationLedger.capacity
  ) {
    self.radioID = radioID
    self.channelKey = channelKey
    self.channel = channel
    self.selfKey = selfKey
    self.capacity = max(1, capacity)
    for node in nodes where !node.identity.isSelf(selfKey) {
      guard !node.isOnlyAdvertPush else {
        removed.insert(node.identity)
        continue
      }
      load(node)
    }
  }

  /// A ledger for the channel the radio reported.
  public init(radioID: UUID, channel: RadioChannelConfig, selfKey: Data?, nodes: [ObservedNode] = []) {
    self.init(radioID: radioID, channelKey: channel.key, channel: channel, selfKey: selfKey, nodes: nodes)
  }

  /// How many nodes the ledger holds, active or stale.
  public var count: Int {
    nodes.count
  }

  /// Every node held, active or stale.
  public var allNodes: [ObservedNode] {
    Array(nodes.values)
  }

  /// The node held under exactly `identity`.
  public func node(for identity: ObservedIdentity) -> ObservedNode? {
    nodes[identity]
  }

  /// Whether `node` was observed within ``activeWindow`` before `date`.
  public static func isActive(_ node: ObservedNode, at date: Date) -> Bool {
    node.lastObservedAt >= date.addingTimeInterval(-activeWindow)
  }

  /// Whether the node held under `identity` was observed within ``activeWindow`` before `date`.
  public func isActive(_ identity: ObservedIdentity, at date: Date) -> Bool {
    nodes[identity].map { Self.isActive($0, at: date) } ?? false
  }

  /// Folds in one observation. One made on another channel, or of this radio itself, is ignored.
  /// - Returns: Whether the ledger changed.
  @discardableResult
  public mutating func ingest(_ observation: NodeObservation) -> Bool {
    guard observation.channelKey == channelKey, !observation.identity.isSelf(selfKey) else { return false }
    let target = foldTarget(for: observation.identity)
    var changed = false
    if var node = nodes[target] {
      changed = node.merge(observation.with(identity: target))
      nodes[target] = node
    } else {
      nodes[target] = ObservedNode(observation: observation.with(identity: target))
      if target.isPrefix { prefixIdentities.insert(target) }
      changed = true
    }
    changed = absorbOverlaps(into: target) || changed
    guard changed else { return false }
    noteUpsert(target)
    enforceCapacity()
    version += 1
    return true
  }

  /// Folds in several observations.
  /// - Returns: Whether the ledger changed.
  @discardableResult
  public mutating func ingest(_ observations: [NodeObservation]) -> Bool {
    var changed = false
    for observation in observations {
      changed = ingest(observation) || changed
    }
    return changed
  }

  /// Deletes rows not observed within ``retention`` before `now`, then the least recently observed
  /// past ``capacity``.
  /// - Returns: Whether any row was deleted.
  @discardableResult
  public mutating func prune(now: Date) -> Bool {
    let cutoff = now.addingTimeInterval(-Self.retention)
    let expired = nodes.values.filter { $0.lastObservedAt < cutoff }.map(\.identity)
    for identity in expired {
      remove(identity)
    }
    let evicted = enforceCapacity()
    guard !expired.isEmpty || evicted else { return false }
    version += 1
    return true
  }

  /// The rows changed and deleted since the last call, for the store. Clears both.
  public mutating func takeChanges() -> (upserted: [ObservedNode], removed: [ObservedIdentity]) {
    let rows = upserted.compactMap { nodes[$0] }
    let gone = Array(removed)
    upserted = []
    removed = []
    return (rows, gone)
  }

  /// Whether ``takeChanges()`` has anything to return.
  public var hasChanges: Bool {
    !upserted.isEmpty || !removed.isEmpty
  }

  /// A read-only copy for consumers, stamped with ``version`` unless the caller gives its own.
  public func snapshot(takenAt: Date, version: Int? = nil) -> LedgerSnapshot {
    LedgerSnapshot(
      radioID: radioID,
      channelKey: channelKey,
      channel: channel,
      selfKey: selfKey,
      takenAt: takenAt,
      version: version ?? self.version,
      nodes: Array(nodes.values)
    )
  }

  // MARK: - Folding

  /// The row an observation of `identity` belongs to: the one full key a prefix names, or the
  /// longest prefix row consistent with it; otherwise `identity` itself.
  private func foldTarget(for identity: ObservedIdentity) -> ObservedIdentity {
    guard identity.isPrefix else { return identity }
    let fullKeys = nodes.keys.filter { !$0.isPrefix && $0.hasPrefix(identity.bytes) }
    if fullKeys.count == 1, let key = fullKeys.first {
      return key
    }
    guard fullKeys.isEmpty else { return identity }
    let related = prefixIdentities.filter { $0.overlaps(identity) } + [identity]
    guard let longest = related.max(by: { $0.bytes.count < $1.bytes.count }),
          related.allSatisfy({ longest.hasPrefix($0.bytes) }) else { return identity }
    return longest
  }

  /// Moves every prefix row that names `target` into it.
  /// - Returns: Whether any row moved.
  private mutating func absorbOverlaps(into target: ObservedIdentity) -> Bool {
    let shorter = prefixIdentities.filter { $0 != target && target.hasPrefix($0.bytes) }
    guard !shorter.isEmpty, var node = nodes[target] else { return false }
    // A prefix several full keys start with stays apart: it can't say which of them it was.
    let movable = shorter.filter { prefix in
      nodes.keys.filter { !$0.isPrefix && $0.hasPrefix(prefix.bytes) }.count <= 1
    }
    guard !movable.isEmpty else { return false }
    for prefix in movable {
      if let row = nodes[prefix] {
        node.absorb(row)
      }
      remove(prefix)
    }
    nodes[target] = node
    return true
  }

  private mutating func load(_ node: ObservedNode) {
    let target = foldTarget(for: node.identity)
    if var existing = nodes[target] {
      existing.absorb(node)
      nodes[target] = existing
      noteUpsert(target)
      if target != node.identity { removed.insert(node.identity) }
    } else {
      var row = node
      row.identity = target
      nodes[target] = row
      if target.isPrefix { prefixIdentities.insert(target) }
      if target != node.identity {
        noteUpsert(target)
        removed.insert(node.identity)
      }
    }
    if absorbOverlaps(into: target) {
      noteUpsert(target)
    }
  }

  private mutating func noteUpsert(_ identity: ObservedIdentity) {
    upserted.insert(identity)
    removed.remove(identity)
  }

  private mutating func remove(_ identity: ObservedIdentity) {
    guard nodes.removeValue(forKey: identity) != nil else { return }
    prefixIdentities.remove(identity)
    upserted.remove(identity)
    removed.insert(identity)
  }

  /// Evicts the least recently observed rows past ``capacity``.
  /// - Returns: Whether any row was evicted.
  @discardableResult
  private mutating func enforceCapacity() -> Bool {
    let excess = nodes.count - capacity
    guard excess > 0 else { return false }
    let oldest = nodes.values
      .sorted { lhs, rhs in
        lhs.lastObservedAt != rhs.lastObservedAt
          ? lhs.lastObservedAt < rhs.lastObservedAt
          : lhs.identity.bytes.lexicographicallyPrecedes(rhs.identity.bytes)
      }
      .prefix(excess)
    for node in oldest {
      remove(node.identity)
    }
    return true
  }
}
