import Foundation
import MeshCore

// MARK: - Source Kind

/// Where a neighbour record's receptions came from, kept per kind so the list can show its badges.
public enum NeighbourSourceKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// It re-sent a flood we heard (R1).
  case relay
  /// We heard its 0-hop advert (R2, R3).
  case advert
  /// It answered one of our own discover requests.
  case replyToUs
  /// It answered someone else's discover request.
  case replyToOthers
  /// It answered our 1-hop trace (R6).
  case trace
  /// We heard another 0-hop flood it sent, which only strengthens a row that already exists.
  case origin
}

/// The receptions of one kind for one neighbour.
public struct NeighbourSourceStats: Sendable, Equatable, Codable {
  public var count: Int
  public var firstHeard: Date
  public var lastHeard: Date

  public init(count: Int, firstHeard: Date, lastHeard: Date) {
    self.count = count
    self.firstHeard = firstHeard
    self.lastHeard = lastHeard
  }

  func merged(with other: NeighbourSourceStats) -> NeighbourSourceStats {
    NeighbourSourceStats(
      count: count + other.count,
      firstHeard: min(firstHeard, other.firstHeard),
      lastHeard: max(lastHeard, other.lastHeard)
    )
  }
}

// MARK: - Heard From

/// A phone fix taken when evidence arrived.
public struct NeighbourFix: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double
  /// Metres.
  public let horizontalAccuracy: Double
  public let timestamp: Date

  public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracy = horizontalAccuracy
    self.timestamp = timestamp
  }
}

/// The spot a neighbour was heard from, and the SNR it was heard at there.
public struct NeighbourHeardFrom: Sendable, Equatable {
  public let fix: NeighbourFix
  public let snr: Double
  /// When the reception happened; nil when not known (a row read back from storage). The fix
  /// can be a little older (up to `NeighbourService.maximumFixAge`).
  public let heardAt: Date?

  public init(fix: NeighbourFix, snr: Double, heardAt: Date? = nil) {
    self.fix = fix
    self.snr = snr
    self.heardAt = heardAt
  }

  /// When it was heard: the reception's own time, else (unknown) the fix's.
  public var receivedAt: Date {
    heardAt ?? fix.timestamp
  }

  /// The better of two: a new reception replaces the stored one only when it was heard better (a
  /// tie keeps the first), and a reception without a fix never removes one (the rule of
  /// NodeDiscoveryReception.best).
  public static func best(stored: NeighbourHeardFrom?, reply: NeighbourHeardFrom?) -> NeighbourHeardFrom? {
    guard let reply else { return stored }
    guard let stored else { return reply }
    return reply.snr > stored.snr ? reply : stored
  }

  /// The later of two receptions with a fix (a tie keeps the stored one); a reception without a
  /// fix never removes one.
  public static func latest(stored: NeighbourHeardFrom?, reply: NeighbourHeardFrom?) -> NeighbourHeardFrom? {
    guard let reply else { return stored }
    guard let stored else { return reply }
    return reply.receivedAt > stored.receivedAt ? reply : stored
  }
}

// MARK: - Freshness

/// How recently a neighbour was heard. The list shows live and recent rows, older rows behind
/// "Show older", and never stale ones.
public enum NeighbourFreshness: Sendable, Equatable, Comparable {
  /// Heard in the last 10 minutes.
  case live
  /// Heard in the last 2 hours.
  case recent
  /// Heard in the last 24 hours.
  case older
  /// Not heard for over 24 hours; pruned after 7 days.
  case stale

  public static let liveAge: TimeInterval = 10 * 60
  public static let recentAge: TimeInterval = 2 * 60 * 60
  public static let olderAge: TimeInterval = 24 * 60 * 60

  public init(lastHeard: Date, now: Date) {
    let age = now.timeIntervalSince(lastHeard)
    switch age {
    case ...Self.liveAge: self = .live
    case ...Self.recentAge: self = .recent
    case ...Self.olderAge: self = .older
    default: self = .stale
    }
  }
}

// MARK: - Record

/// Everything heard from one direct neighbour, keyed by how precisely it is known.
///
/// Every inbound source measures the same link (the neighbour's transmission at this radio), so
/// SNR and RSSI are merged across sources. Uplink SNR (how it hears us) is separate: only a reply
/// to our own probe or a trace measures it.
public struct NeighbourRecord: Sendable, Equatable {
  /// A full key, an 8-byte reply prefix, or a path hash of 1-4 bytes. Resolution to a key is
  /// never stored here: the resolver recomputes it, so a key learned later corrects it.
  public internal(set) var identity: NeighbourIdentity
  public var firstHeard: Date
  public var lastHeard: Date
  public var heardCount: Int
  public var lastSNR: Double?
  public var bestSNR: Double?
  /// Exponentially weighted SNR, alpha ``NeighbourTable/snrSmoothing``.
  public var snrEWMA: Double?
  public var lastRSSI: Int?
  /// How the neighbour heard us, from a reply to our own probe or a trace.
  public var uplinkSNR: Double?
  public var uplinkAt: Date?
  /// Last time the neighbour proved it hears this radio.
  public var hearsYouAt: Date?
  public var sources: [NeighbourSourceKind: NeighbourSourceStats]
  /// The node type an advert or reply stated (1 chat, 2 repeater, 3 room, 4 sensor; 0 = not said).
  public var nodeTypeRaw: UInt8?
  public var name: String?
  /// The advertised position, in degrees.
  public var latitude: Double?
  public var longitude: Double?
  /// Where it was heard best from, of every reception with a fix.
  public var heardFrom: NeighbourHeardFrom?
  /// Where it was last heard from: the latest reception with a fix, so a view of what was heard
  /// since some moment (a scan's start) can place a reception from then on even when the best one
  /// is older. Kept in memory only: a row read back from storage has none until heard again.
  public var latestHeardFrom: NeighbourHeardFrom?

  public init(
    identity: NeighbourIdentity,
    firstHeard: Date,
    lastHeard: Date,
    heardCount: Int = 0,
    lastSNR: Double? = nil,
    bestSNR: Double? = nil,
    snrEWMA: Double? = nil,
    lastRSSI: Int? = nil,
    uplinkSNR: Double? = nil,
    uplinkAt: Date? = nil,
    hearsYouAt: Date? = nil,
    sources: [NeighbourSourceKind: NeighbourSourceStats] = [:],
    nodeTypeRaw: UInt8? = nil,
    name: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    heardFrom: NeighbourHeardFrom? = nil,
    latestHeardFrom: NeighbourHeardFrom? = nil
  ) {
    self.identity = identity
    self.firstHeard = firstHeard
    self.lastHeard = lastHeard
    self.heardCount = heardCount
    self.lastSNR = lastSNR
    self.bestSNR = bestSNR
    self.snrEWMA = snrEWMA
    self.lastRSSI = lastRSSI
    self.uplinkSNR = uplinkSNR
    self.uplinkAt = uplinkAt
    self.hearsYouAt = hearsYouAt
    self.sources = sources
    self.nodeTypeRaw = nodeTypeRaw
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.heardFrom = heardFrom
    self.latestHeardFrom = latestHeardFrom
  }

  /// A confirmed neighbour: named by a full key, answered a discover request or a trace, or heard
  /// relaying at least twice, at least 5 s apart. Anything else is "Heard once" and shown dimmed.
  public var isConfirmed: Bool {
    if sources[.advert] != nil || hasReply || sources[.trace] != nil { return true }
    guard let relay = sources[.relay], relay.count >= 2 else { return false }
    return relay.lastHeard.timeIntervalSince(relay.firstHeard) >= NeighbourTable.relayConfirmSpacing
  }

  /// Named by a full key and proven by an advert, a reply or a trace in the last 24 hours: the
  /// only kind of candidate a 1-byte hash may resolve to.
  public func isFullKeyConfirmed(now: Date) -> Bool {
    directlyHeardAt.map { $0 >= now.addingTimeInterval(-NeighbourTable.fullKeyConfirmAge) } ?? false
  }

  /// When this radio last heard the node itself, by its full key: the latest advert, reply or
  /// trace. Nil for a hash or prefix row, whose node is only the resolver's guess (so a guess can
  /// never prove itself), and for a row heard only relaying or by weak origin evidence.
  public var directlyHeardAt: Date? {
    guard identity.isFullKey else { return nil }
    return [NeighbourSourceKind.advert, .replyToUs, .replyToOthers, .trace]
      .compactMap { sources[$0]?.lastHeard }
      .max()
  }

  public func freshness(now: Date) -> NeighbourFreshness {
    NeighbourFreshness(lastHeard: lastHeard, now: now)
  }

  public func hearsYou(within age: TimeInterval = NeighbourFreshness.olderAge, now: Date) -> Bool {
    hearsYouAt.map { now.timeIntervalSince($0) <= age } ?? false
  }

  private var hasReply: Bool {
    sources[.replyToUs] != nil || sources[.replyToOthers] != nil
  }

  /// This record and `other` as one: counts summed, the earliest first and latest last heard,
  /// the best SNR, and the latest of each "last" value. What `self` states about the node wins.
  public func merged(with other: NeighbourRecord) -> NeighbourRecord {
    var merged = self
    let otherIsNewer = other.lastHeard > lastHeard
    merged.firstHeard = min(firstHeard, other.firstHeard)
    merged.lastHeard = max(lastHeard, other.lastHeard)
    merged.heardCount = heardCount + other.heardCount
    if otherIsNewer || merged.lastSNR == nil { merged.lastSNR = other.lastSNR ?? lastSNR }
    if otherIsNewer || merged.lastRSSI == nil { merged.lastRSSI = other.lastRSSI ?? lastRSSI }
    merged.bestSNR = [bestSNR, other.bestSNR].compactMap(\.self).max()
    merged.snrEWMA = Self.weightedSNR(self, other)
    if let otherAt = other.uplinkAt, uplinkAt.map({ otherAt > $0 }) ?? true {
      merged.uplinkSNR = other.uplinkSNR
      merged.uplinkAt = otherAt
    }
    merged.hearsYouAt = [hearsYouAt, other.hearsYouAt].compactMap(\.self).max()
    merged.sources = sources.merging(other.sources) { $0.merged(with: $1) }
    if merged.nodeTypeRaw == nil || merged.nodeTypeRaw == 0 {
      merged.nodeTypeRaw = other.nodeTypeRaw ?? merged.nodeTypeRaw
    }
    if merged.name == nil { merged.name = other.name }
    if merged.latitude == nil || merged.longitude == nil {
      merged.latitude = other.latitude
      merged.longitude = other.longitude
    }
    merged.heardFrom = NeighbourHeardFrom.best(stored: heardFrom, reply: other.heardFrom)
    merged.latestHeardFrom = NeighbourHeardFrom.latest(stored: latestHeardFrom, reply: other.latestHeardFrom)
    return merged
  }

  /// The two smoothed SNRs averaged by how many receptions each stands for.
  private static func weightedSNR(_ a: NeighbourRecord, _ b: NeighbourRecord) -> Double? {
    switch (a.snrEWMA, b.snrEWMA) {
    case let (x?, y?):
      let total = max(a.heardCount + b.heardCount, 1)
      return (x * Double(a.heardCount) + y * Double(b.heardCount)) / Double(total)
    case let (x, y):
      return x ?? y
    }
  }
}

// MARK: - Table

/// The direct neighbours of one radio, aggregated from neighbour evidence. Pure: no storage, no
/// actor, and every time comes from the caller.
///
/// - The same reception arriving twice (a discover reply as both 0x8E and 0x88, or a replayed
///   entry) counts once: replies and traces by (key, tag), everything else by packet hash plus
///   identity, each within ``dedupWindow``.
/// - A full key folds any 8-byte prefix row it starts with into its own row. Path-hash rows stay
///   separate: which key a hash names is the resolver's call, made fresh for every snapshot.
/// - ``takeChanges()`` hands the storage layer the rows changed or removed since the last call,
///   so it can write them in one batch.
public struct NeighbourTable: Sendable {
  /// Smoothing of ``NeighbourRecord/snrEWMA``.
  public static let snrSmoothing = 0.25
  /// Repeat receptions closer than this count once.
  public static let dedupWindow: TimeInterval = 3
  /// Two relay receptions at least this far apart confirm a neighbour.
  public static let relayConfirmSpacing: TimeInterval = 5
  /// How long an advert, reply or trace keeps a key confirmed for 1-byte resolution.
  public static let fullKeyConfirmAge: TimeInterval = 24 * 60 * 60
  /// Rows not heard for this long are pruned.
  public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
  /// A prefix row heard only once is pruned after this long, so a corrupted path byte can't leave
  /// a ghost neighbour.
  public static let singleSightingAge: TimeInterval = 2 * 60 * 60
  /// Rows kept per radio; the least recently heard go first.
  public static let maximumRows = 512
  /// How long a probe's tag marks replies as answers to us. Replies keep arriving for a while
  /// after the listen window (at most 15 s) closes.
  public static let probeTagLifetime: TimeInterval = 10 * 60
  static let maximumProbeTags = 16

  /// What one piece of evidence did to the table.
  public enum IngestOutcome: Sendable, Equatable {
    /// Added to the row with this identity.
    case recorded(NeighbourIdentity)
    /// Already counted within the dedup window.
    case duplicate
    /// Weak origin evidence with no row to strengthen.
    case ignored
  }

  /// The rows changed and removed since the last ``takeChanges()``.
  public struct Changes: Sendable, Equatable {
    public var upserted: [NeighbourRecord]
    public var removed: [NeighbourIdentity]

    public var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }
  }

  private enum DedupKey: Hashable {
    case tagged(Data, UInt32)
    case packet(String, NeighbourIdentity)
  }

  public private(set) var records: [NeighbourIdentity: NeighbourRecord] = [:]
  private var dedupSeen: [DedupKey: Date] = [:]
  private var dedupOrder: [(key: DedupKey, at: Date)] = []
  private var probeTags: [(tag: UInt32, at: Date)] = []
  private var dirty: Set<NeighbourIdentity> = []
  private var removed: Set<NeighbourIdentity> = []

  /// Starts from rows loaded from storage, which count as already saved.
  public init(records: [NeighbourRecord] = []) {
    for record in records {
      self.records[record.identity] = record
    }
  }

  public var count: Int { records.count }

  public subscript(identity: NeighbourIdentity) -> NeighbourRecord? {
    records[identity]
  }

  // MARK: Probes

  /// Remembers our own discover request, so replies carrying its tag count as answers to us and
  /// measure how the neighbour hears us.
  public mutating func noteProbe(tag: UInt32, at now: Date) {
    probeTags.removeAll { $0.tag == tag || now.timeIntervalSince($0.at) > Self.probeTagLifetime }
    probeTags.append((tag, now))
    if probeTags.count > Self.maximumProbeTags {
      probeTags.removeFirst(probeTags.count - Self.maximumProbeTags)
    }
  }

  public func isOwnProbe(tag: UInt32) -> Bool {
    probeTags.contains { $0.tag == tag }
  }

  // MARK: Ingest

  /// Adds one piece of evidence received at `now`.
  ///
  /// - Parameter fix: The phone's fix when it arrived, if fresh; the row keeps the best-SNR one
  ///   and the latest one.
  @discardableResult
  public mutating func ingest(
    _ evidence: NeighbourEvidence,
    at now: Date,
    fix: NeighbourFix? = nil
  ) -> IngestOutcome {
    guard admit(evidence, at: now) else { return .duplicate }
    guard let identity = rowIdentity(for: evidence) else { return .ignored }

    let kind = sourceKind(for: evidence)
    var record = records[identity] ?? NeighbourRecord(identity: identity, firstHeard: now, lastHeard: now)
    let isLatest = now >= record.lastHeard || record.heardCount == 0
    record.firstHeard = min(record.firstHeard, now)
    record.lastHeard = max(record.lastHeard, now)
    record.heardCount += 1

    if let snr = evidence.snr {
      if isLatest { record.lastSNR = snr }
      record.bestSNR = max(record.bestSNR ?? snr, snr)
      record.snrEWMA = record.snrEWMA.map { $0 + Self.snrSmoothing * (snr - $0) } ?? snr
      let reception = fix.map { NeighbourHeardFrom(fix: $0, snr: snr, heardAt: now) }
      record.heardFrom = NeighbourHeardFrom.best(stored: record.heardFrom, reply: reception)
      record.latestHeardFrom = NeighbourHeardFrom.latest(stored: record.latestHeardFrom, reply: reception)
    }
    if let rssi = evidence.rssi, isLatest || record.lastRSSI == nil { record.lastRSSI = rssi }

    let stats = record.sources[kind]
    record.sources[kind] = NeighbourSourceStats(
      count: (stats?.count ?? 0) + 1,
      firstHeard: min(stats?.firstHeard ?? now, now),
      lastHeard: max(stats?.lastHeard ?? now, now)
    )

    // Only our own probe's replies and traces say how the neighbour hears us
    let measuresUplink = kind == .replyToUs || kind == .trace
    if measuresUplink, let uplink = evidence.uplinkSNR, record.uplinkAt.map({ now >= $0 }) ?? true {
      record.uplinkSNR = uplink
      record.uplinkAt = now
    }
    if evidence.hearsYou || kind == .replyToUs {
      record.hearsYouAt = max(record.hearsYouAt ?? now, now)
    }

    if let type = evidence.nodeTypeRaw, type != 0 { record.nodeTypeRaw = type }
    if let name = evidence.name { record.name = name }
    if let latitude = evidence.latitude, let longitude = evidence.longitude {
      record.latitude = latitude
      record.longitude = longitude
    }

    store(record)
    if case let .fullKey(key) = identity {
      foldPrefixRows(into: key)
    }
    return .recorded(identity)
  }

  /// Records that the relay with path hash `relayHash` heard this radio at `date`: it passed on,
  /// as a flood's only hop, a packet this radio was proven to have sent (R8). Sets the row's
  /// ``NeighbourRecord/hearsYouAt`` without counting the frame again, which its relay evidence
  /// already did. A row not there yet (the proof outran the frame) starts with no receptions,
  /// for the frame to count.
  /// - Returns: Whether the row changed.
  @discardableResult
  public mutating func noteHearsYou(relayHash: Data, at date: Date) -> Bool {
    guard !relayHash.isEmpty else { return false }
    let identity = NeighbourIdentity.hash(relayHash)
    var record = records[identity] ?? NeighbourRecord(identity: identity, firstHeard: date, lastHeard: date)
    guard record.hearsYouAt.map({ date > $0 }) ?? true else { return false }
    record.hearsYouAt = date
    store(record)
    return true
  }

  /// Folds the row `source` into the row for the full key `key`, creating it if needed: counts
  /// summed, earliest first and latest last heard, best SNR kept. The source row is removed.
  public mutating func merge(_ source: NeighbourIdentity, into key: Data) {
    let target = NeighbourIdentity.fullKey(key)
    guard source != target, let row = records[source] else { return }
    var merged: NeighbourRecord
    if let existing = records[target] {
      merged = existing.merged(with: row)
    } else {
      merged = row
      merged.identity = target
    }
    records[source] = nil
    dirty.remove(source)
    removed.insert(source)
    store(merged)
  }

  // MARK: Prune

  /// Drops rows not heard for 7 days, prefix rows heard only once more than 2 hours ago, and then
  /// the least recently heard rows beyond ``maximumRows``.
  public mutating func prune(now: Date) {
    let expiry = now.addingTimeInterval(-Self.maximumAge)
    let singleExpiry = now.addingTimeInterval(-Self.singleSightingAge)
    for (identity, record) in records {
      let isSingleSighting = !identity.isFullKey && record.heardCount <= 1
      if record.lastHeard < expiry || (isSingleSighting && record.lastHeard < singleExpiry) {
        drop(identity)
      }
    }
    if records.count > Self.maximumRows {
      let excess = records.values
        .sorted { $0.lastHeard < $1.lastHeard }
        .prefix(records.count - Self.maximumRows)
      for record in excess {
        drop(record.identity)
      }
    }
    pruneDedup(now: now)
  }

  // MARK: Changes

  /// The rows changed and removed since the last call, for one batched write.
  public mutating func takeChanges() -> Changes {
    let changes = Changes(
      upserted: dirty.compactMap { records[$0] },
      removed: Array(removed)
    )
    dirty.removeAll()
    removed.removeAll()
    return changes
  }

  public var hasChanges: Bool { !dirty.isEmpty || !removed.isEmpty }

  // MARK: Private

  /// Whether this reception is new, recording it when it is.
  private mutating func admit(_ evidence: NeighbourEvidence, at now: Date) -> Bool {
    let key: DedupKey
    switch (evidence.source, evidence.tag, evidence.packetHash) {
    case let (.discoverReply, tag?, _), let (.traceConfirm, tag?, _):
      key = .tagged(evidence.identity.bytes, tag)
    case let (_, _, hash?):
      key = .packet(hash, evidence.identity)
    default:
      return true
    }
    pruneDedup(now: now)
    if let seen = dedupSeen[key], abs(now.timeIntervalSince(seen)) < Self.dedupWindow {
      return false
    }
    dedupSeen[key] = now
    dedupOrder.append((key, now))
    return true
  }

  private mutating func pruneDedup(now: Date) {
    let cutoff = now.addingTimeInterval(-Self.dedupWindow)
    var dropCount = 0
    for entry in dedupOrder {
      guard entry.at < cutoff else { break }
      if dedupSeen[entry.key] == entry.at { dedupSeen[entry.key] = nil }
      dropCount += 1
    }
    if dropCount > 0 { dedupOrder.removeFirst(dropCount) }
  }

  private func sourceKind(for evidence: NeighbourEvidence) -> NeighbourSourceKind {
    switch evidence.source {
    case .relay: .relay
    case .advert: .advert
    case .discoverReply: evidence.tag.map(isOwnProbe(tag:)) == true ? .replyToUs : .replyToOthers
    case .traceConfirm: .trace
    case .weakOrigin: .origin
    }
  }

  /// The row the evidence belongs to. A full key's own row; an 8-byte prefix goes to the one key
  /// row it starts with; a hash to its own row. Weak origin evidence only joins a row that exists.
  private func rowIdentity(for evidence: NeighbourEvidence) -> NeighbourIdentity? {
    var identity = evidence.identity
    if case let .keyPrefix(prefix) = identity {
      let keyRows = records.keys.filter { $0.isFullKey && $0.bytes.starts(with: prefix) }
      if keyRows.count == 1, let only = keyRows.first { identity = only }
    }
    if evidence.source == .weakOrigin, records[identity] == nil { return nil }
    return identity
  }

  /// Folds every 8-byte prefix row that `key` starts with into its row.
  private mutating func foldPrefixRows(into key: Data) {
    let prefixRows = records.keys.filter {
      if case let .keyPrefix(prefix) = $0 { key.starts(with: prefix) } else { false }
    }
    for row in prefixRows {
      merge(row, into: key)
    }
  }

  private mutating func store(_ record: NeighbourRecord) {
    records[record.identity] = record
    dirty.insert(record.identity)
    removed.remove(record.identity)
  }

  private mutating func drop(_ identity: NeighbourIdentity) {
    guard records.removeValue(forKey: identity) != nil else { return }
    dirty.remove(identity)
    removed.insert(identity)
  }
}
