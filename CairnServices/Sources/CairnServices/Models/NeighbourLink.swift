import Foundation
import MeshCore
import SwiftData

/// One direct neighbour of one radio on one channel, as `NeighbourService` last flushed it: a
/// ``NeighbourRecord`` flattened to scalar fields. No relationships, so adding it is a lightweight
/// migration.
///
/// Rows are written in one batch every few seconds and on stop, never once per packet. Which key
/// a hash row names is not stored: the resolver works it out again for every snapshot.
@Model
final class NeighbourLink {
  #Index<NeighbourLink>(
    [\.radioID],
    [\.radioID, \.lastHeard],
    [\.radioID, \.channelKey]
  )

  @Attribute(.unique)
  var id: UUID

  /// Parent device ID
  var radioID: UUID

  /// The channel the neighbour was heard on (`ChannelKey` raw value): each channel has its own
  /// table. Nil only for a row written before channels were recorded, which is deleted unread.
  var channelKey: String?

  /// ``NeighbourLink/IdentityKind`` raw value: how precisely `identityBytes` name the node.
  var identityKindRaw: Int

  /// The full key, the 8-byte reply prefix, or the 1-4 byte path hash.
  var identityBytes: Data

  var firstHeard: Date
  var lastHeard: Date
  var heardCount: Int
  var lastSNR: Double?
  var bestSNR: Double?
  var snrEWMA: Double?
  var lastRSSI: Int?

  /// How the neighbour heard us, from a reply to our own probe or a trace.
  var uplinkSNR: Double?
  var uplinkAt: Date?
  var hearsYouAt: Date?

  /// The per-source counts and times, packed by ``NeighbourLink/packSources(_:)``.
  var sourceStats: Data

  /// Stored as Int so a value out of UInt8 range can't fail the fetch; nil = not said.
  var nodeTypeRaw: Int?
  var name: String?
  var latitude: Double?
  var longitude: Double?

  /// Where the neighbour was heard best from: the phone fix and the SNR there.
  var heardFromLatitude: Double?
  var heardFromLongitude: Double?
  var heardFromAccuracy: Double?
  var heardFromAt: Date?
  var heardFromSNR: Double?

  init(id: UUID = UUID(), radioID: UUID, channelKey: ChannelKey, record: NeighbourRecord) {
    self.id = id
    self.radioID = radioID
    self.channelKey = channelKey.rawValue
    let (kind, bytes) = Self.encode(record.identity)
    identityKindRaw = kind.rawValue
    identityBytes = bytes
    firstHeard = record.firstHeard
    lastHeard = record.lastHeard
    heardCount = record.heardCount
    lastSNR = record.lastSNR
    bestSNR = record.bestSNR
    snrEWMA = record.snrEWMA
    lastRSSI = record.lastRSSI
    uplinkSNR = record.uplinkSNR
    uplinkAt = record.uplinkAt
    hearsYouAt = record.hearsYouAt
    sourceStats = Self.packSources(record.sources)
    nodeTypeRaw = record.nodeTypeRaw.map(Int.init)
    name = record.name
    latitude = record.latitude
    longitude = record.longitude
    heardFromLatitude = record.heardFrom?.fix.latitude
    heardFromLongitude = record.heardFrom?.fix.longitude
    heardFromAccuracy = record.heardFrom?.fix.horizontalAccuracy
    heardFromAt = record.heardFrom?.fix.timestamp
    heardFromSNR = record.heardFrom?.snr
  }

  /// Copies every field of `record` but its identity.
  func update(from record: NeighbourRecord) {
    firstHeard = record.firstHeard
    lastHeard = record.lastHeard
    heardCount = record.heardCount
    lastSNR = record.lastSNR
    bestSNR = record.bestSNR
    snrEWMA = record.snrEWMA
    lastRSSI = record.lastRSSI
    uplinkSNR = record.uplinkSNR
    uplinkAt = record.uplinkAt
    hearsYouAt = record.hearsYouAt
    sourceStats = Self.packSources(record.sources)
    nodeTypeRaw = record.nodeTypeRaw.map(Int.init)
    name = record.name
    latitude = record.latitude
    longitude = record.longitude
    heardFromLatitude = record.heardFrom?.fix.latitude
    heardFromLongitude = record.heardFrom?.fix.longitude
    heardFromAccuracy = record.heardFrom?.fix.horizontalAccuracy
    heardFromAt = record.heardFrom?.fix.timestamp
    heardFromSNR = record.heardFrom?.snr
  }

  /// The record this row holds, or nil when its identity is malformed.
  var record: NeighbourRecord? {
    guard let identity else { return nil }
    var heardFrom: NeighbourHeardFrom?
    if let heardFromLatitude, let heardFromLongitude, let heardFromAt, let heardFromSNR {
      let fix = NeighbourFix(
        latitude: heardFromLatitude,
        longitude: heardFromLongitude,
        horizontalAccuracy: heardFromAccuracy ?? 0,
        timestamp: heardFromAt
      )
      heardFrom = NeighbourHeardFrom(fix: fix, snr: heardFromSNR)
    }
    return NeighbourRecord(
      identity: identity,
      firstHeard: firstHeard,
      lastHeard: lastHeard,
      heardCount: heardCount,
      lastSNR: lastSNR,
      bestSNR: bestSNR,
      snrEWMA: snrEWMA,
      lastRSSI: lastRSSI,
      uplinkSNR: uplinkSNR,
      uplinkAt: uplinkAt,
      hearsYouAt: hearsYouAt,
      sources: Self.unpackSources(sourceStats),
      nodeTypeRaw: nodeTypeRaw.flatMap { UInt8(exactly: $0) },
      name: name,
      latitude: latitude,
      longitude: longitude,
      heardFrom: heardFrom
    )
  }

  var identity: NeighbourIdentity? {
    guard let kind = IdentityKind(rawValue: identityKindRaw), !identityBytes.isEmpty else { return nil }
    return switch kind {
    case .fullKey: .fullKey(identityBytes)
    case .keyPrefix: .keyPrefix(identityBytes)
    case .hash: .hash(identityBytes)
    }
  }
}

// MARK: - Encoding

extension NeighbourLink {
  /// How precisely a row names its node. Raw values are stored: never renumber.
  enum IdentityKind: Int {
    case fullKey = 0
    case keyPrefix = 1
    case hash = 2
  }

  static func encode(_ identity: NeighbourIdentity) -> (IdentityKind, Data) {
    switch identity {
    case let .fullKey(key): (.fullKey, key)
    case let .keyPrefix(prefix): (.keyPrefix, prefix)
    case let .hash(hash): (.hash, hash)
    }
  }

  /// One source's stats as stored. Short keys keep the blob small.
  private struct PackedSource: Codable {
    let k: String
    let n: Int
    let f: Date
    let l: Date
  }

  /// The per-source stats as one JSON value, in a fixed order so equal stats give equal bytes.
  static func packSources(_ sources: [NeighbourSourceKind: NeighbourSourceStats]) -> Data {
    let packed = NeighbourSourceKind.allCases.compactMap { kind in
      sources[kind].map { PackedSource(k: kind.rawValue, n: $0.count, f: $0.firstHeard, l: $0.lastHeard) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(packed)) ?? Data()
  }

  /// The stats ``packSources(_:)`` stored. A source kind this build doesn't know is skipped, and
  /// an unreadable value gives none, so the row still loads.
  static func unpackSources(_ data: Data) -> [NeighbourSourceKind: NeighbourSourceStats] {
    guard !data.isEmpty, let packed = try? JSONDecoder().decode([PackedSource].self, from: data) else { return [:] }
    var sources: [NeighbourSourceKind: NeighbourSourceStats] = [:]
    for entry in packed {
      guard let kind = NeighbourSourceKind(rawValue: entry.k) else { continue }
      sources[kind] = NeighbourSourceStats(count: entry.n, firstHeard: entry.f, lastHeard: entry.l)
    }
    return sources
  }
}
