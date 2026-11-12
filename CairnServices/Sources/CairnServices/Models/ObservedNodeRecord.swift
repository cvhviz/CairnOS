import Foundation
import MeshCore
import SwiftData

/// One node one radio observed on one channel, as `NeighbourService` last flushed its
/// ``ObservationLedger``: an ``ObservedNode`` flattened to scalar fields. No relationships, so
/// adding it is a lightweight migration.
///
/// Rows are written in one batch with the neighbour table, never once per packet. They describe
/// what one radio heard at one time, so they are left out of backups.
@Model
final class ObservedNodeRecord {
  #Index<ObservedNodeRecord>(
    [\.radioID, \.channelKey],
    [\.radioID, \.channelKey, \.lastObservedAt]
  )

  /// `radioID|channelKey|identityHex` (``rowID(radioID:channelKey:identity:)``).
  @Attribute(.unique)
  var id: String

  var radioID: UUID
  /// The ``ChannelKey`` raw value.
  var channelKey: String
  /// The full key, or the 6-31 byte key prefix when ``isPrefix``.
  var identity: Data
  var isPrefix: Bool

  /// Stored as Int so a value out of UInt8 range can't fail the fetch; nil = not said.
  var nodeTypeRaw: Int?
  var name: String?
  var latitude: Double?
  var longitude: Double?
  var positionAt: Date?
  var firstObservedAt: Date
  var lastObservedAt: Date
  var lastDirectAt: Date?
  var lastDirectSNR: Double?
  var lastDirectRSSI: Int?
  var minHops: Int?
  var lastHops: Int?
  /// The per-kind counts and times, packed by ``packKinds(_:)``.
  var kindStats: Data

  init(radioID: UUID, channelKey: ChannelKey, node: ObservedNode) {
    id = Self.rowID(radioID: radioID, channelKey: channelKey, identity: node.identity)
    self.radioID = radioID
    self.channelKey = channelKey.rawValue
    identity = node.identity.bytes
    isPrefix = node.identity.isPrefix
    firstObservedAt = node.firstObservedAt
    lastObservedAt = node.lastObservedAt
    kindStats = Data()
    update(from: node)
  }

  /// Copies every field of `node` but its identity.
  func update(from node: ObservedNode) {
    nodeTypeRaw = node.nodeTypeRaw.map(Int.init)
    name = node.name
    latitude = node.latitude
    longitude = node.longitude
    positionAt = node.positionAt
    firstObservedAt = node.firstObservedAt
    lastObservedAt = node.lastObservedAt
    lastDirectAt = node.lastDirectAt
    lastDirectSNR = node.lastDirectSNR
    lastDirectRSSI = node.lastDirectRSSI
    minHops = node.minHops
    lastHops = node.lastHops
    kindStats = Self.packKinds(node.kinds)
  }

  /// The node this row holds, or nil when its identity is malformed.
  var node: ObservedNode? {
    guard let observedIdentity else { return nil }
    return ObservedNode(
      identity: observedIdentity,
      name: name,
      nodeTypeRaw: nodeTypeRaw.flatMap { UInt8(exactly: $0) },
      latitude: latitude,
      longitude: longitude,
      positionAt: positionAt,
      firstObservedAt: firstObservedAt,
      lastObservedAt: lastObservedAt,
      lastDirectAt: lastDirectAt,
      lastDirectSNR: lastDirectSNR,
      lastDirectRSSI: lastDirectRSSI,
      minHops: minHops,
      lastHops: lastHops,
      kinds: Self.unpackKinds(kindStats)
    )
  }

  var observedIdentity: ObservedIdentity? {
    guard let parsed = ObservedIdentity(bytes: identity), parsed.isPrefix == isPrefix else { return nil }
    return parsed
  }

  static func rowID(radioID: UUID, channelKey: ChannelKey, identity: ObservedIdentity) -> String {
    "\(radioID.uuidString)|\(channelKey.rawValue)|\(identity.hex)"
  }
}

// MARK: - Encoding

extension ObservedNodeRecord {
  /// One kind's stats as stored. Short keys keep the blob small.
  private struct PackedKind: Codable {
    let k: Int
    let n: Int
    let l: Date
  }

  /// The per-kind stats as one JSON value, in a fixed order so equal stats give equal bytes.
  static func packKinds(_ kinds: [ObservationKind: KindStat]) -> Data {
    let packed = ObservationKind.allCases.compactMap { kind in
      kinds[kind].map { PackedKind(k: kind.rawValue, n: $0.count, l: $0.lastAt) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(packed)) ?? Data()
  }

  /// The stats ``packKinds(_:)`` stored. A kind this build doesn't know is skipped, and an
  /// unreadable value gives none, so the row still loads.
  static func unpackKinds(_ data: Data) -> [ObservationKind: KindStat] {
    guard !data.isEmpty, let packed = try? JSONDecoder().decode([PackedKind].self, from: data) else { return [:] }
    var kinds: [ObservationKind: KindStat] = [:]
    for entry in packed {
      guard let kind = ObservationKind(rawValue: entry.k) else { continue }
      kinds[kind] = KindStat(count: entry.n, lastAt: entry.l)
    }
    return kinds
  }
}
