import Foundation
import MeshCore

// MARK: - Resolution

/// Which node a neighbour row names.
public enum NeighbourResolution: Sendable, Equatable {
  /// Exactly one node. A row known only by an 8-byte reply prefix resolves to that prefix until
  /// its full key is observed.
  case resolved(NeighbourKeyEntry)
  /// More than one observed node could have sent it. `candidates` holds the likeliest (at most
  /// ``NeighbourResolver/maximumListedCandidates``), `total` how many there are.
  case ambiguous(candidates: [NeighbourKeyEntry], total: Int)
  /// No node observed on this channel starts with this hash.
  case unknown(Data)

  public var entry: NeighbourKeyEntry? {
    if case let .resolved(entry) = self { entry } else { nil }
  }

  public var isResolved: Bool { entry != nil }
}

/// One row of a neighbour snapshot: a table row resolved against the observed nodes, with any
/// other rows that resolve to the same node merged in.
public struct ResolvedNeighbour: Sendable, Equatable {
  public let record: NeighbourRecord
  public let resolution: NeighbourResolution
  /// The table rows folded into `record`, its own first.
  public let identities: [NeighbourIdentity]

  public init(record: NeighbourRecord, resolution: NeighbourResolution, identities: [NeighbourIdentity]) {
    self.record = record
    self.resolution = resolution
    self.identities = identities
  }
}

// MARK: - Resolver

/// Decides which node a neighbour row names, by the same rules the RX Log list and the Traffic
/// map use (``PacketNodeResolver``), against the same observations (``PacketNodeIndex``). Pure,
/// and run again for every snapshot: the result is never stored, so a node observed later
/// corrects earlier evidence.
///
/// - A full-key row names its key: the observed node, else the bare key filled from the row.
/// - A key-prefix row (an 8-byte discover reply or trace hash) resolves as a key prefix: the one
///   observed node it can be, else itself.
/// - A hash row resolves as the hop this radio heard (``PacketNodeResolver/resolveHash(_:role:isRadioNeighbour:at:in:)``)
///   at the time it was last heard: only nodes observed on the channel are candidates.
///
/// Saved contacts are never candidates. No distance rule applies.
public enum NeighbourResolver {
  /// Candidates an ambiguous row lists.
  public static let maximumListedCandidates = 4

  /// Every row of `table`, resolved against `index`, with the rows that name the same node merged
  /// into one: a hash row that resolves to a key joins that key's row. Unresolved rows stay on
  /// their own.
  public static func resolveAll(_ table: NeighbourTable, index: PacketNodeIndex, now: Date) -> [ResolvedNeighbour] {
    var groups: [Data: [(NeighbourRecord, NeighbourKeyEntry)]] = [:]
    var unresolved: [ResolvedNeighbour] = []
    for record in table.records.values {
      let resolution = resolve(record, index: index)
      if let entry = resolution.entry {
        groups[entry.publicKey, default: []].append((record, entry))
      } else {
        unresolved.append(ResolvedNeighbour(record: record, resolution: resolution, identities: [record.identity]))
      }
    }
    let resolved = groups.values.map { members -> ResolvedNeighbour in
      // The full-key row leads, then the most specific hash, then the most heard
      let ordered = members.sorted { lhs, rhs in
        let (l, r) = (lhs.0.identity, rhs.0.identity)
        if l.isFullKey != r.isFullKey { return l.isFullKey }
        if l.bytes.count != r.bytes.count { return l.bytes.count > r.bytes.count }
        return lhs.0.heardCount > rhs.0.heardCount
      }
      let lead = ordered[0]
      let record = ordered.dropFirst().reduce(lead.0) { $0.merged(with: $1.0) }
      return ResolvedNeighbour(
        record: record,
        resolution: .resolved(lead.1),
        identities: ordered.map(\.0.identity)
      )
    }
    return (resolved + unresolved).sorted { $0.record.lastHeard > $1.record.lastHeard }
  }

  /// Which node `record` names, judged at the time it was last heard.
  public static func resolve(_ record: NeighbourRecord, index: PacketNodeIndex) -> NeighbourResolution {
    let fromRow = entry(from: record)
    switch record.identity {
    case let .fullKey(key):
      let observed = index.keys.entry(for: key)
      return .resolved(observed.map { $0.filling(from: fromRow) } ?? fromRow)
    case let .keyPrefix(prefix):
      let match = PacketNodeResolver.resolveKeyPrefix(
        prefix,
        nodeTypeRaw: record.nodeTypeRaw ?? 0,
        at: record.lastHeard,
        in: index
      )
      return resolution(of: match, hash: prefix, fillingFrom: fromRow)
    case let .hash(hash):
      let match = PacketNodeResolver.resolveHash(
        hash,
        role: .relay,
        isRadioNeighbour: true,
        at: record.lastHeard,
        in: index
      )
      return resolution(of: match, hash: hash, fillingFrom: nil)
    }
  }

  private static func resolution(
    of match: PacketNodeMatch,
    hash: Data,
    fillingFrom row: NeighbourKeyEntry?
  ) -> NeighbourResolution {
    switch match {
    case let .resolved(entry):
      return .resolved(row.map { entry.filling(from: $0) } ?? entry)
    case let .ambiguous(_, candidates, total):
      return .ambiguous(candidates: candidates, total: total)
    case .unknown, .radio:
      // This radio is never its own neighbour: a hash only it has names no neighbour
      return .unknown(hash)
    }
  }

  /// What the row itself states about its node (from its verified advert or discover reply):
  /// fills the gaps of an observed node, never a candidate for a hash.
  private static func entry(from record: NeighbourRecord) -> NeighbourKeyEntry {
    NeighbourKeyEntry(
      publicKey: record.identity.bytes,
      nodeTypeRaw: record.nodeTypeRaw ?? 0,
      name: record.name,
      advertisedName: record.name,
      latitude: record.latitude,
      longitude: record.longitude,
      lastHeard: record.lastHeard,
      lastDirectAt: record.directlyHeardAt
    )
  }
}
