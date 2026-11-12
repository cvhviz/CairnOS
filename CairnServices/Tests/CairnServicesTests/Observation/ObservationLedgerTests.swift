import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("Observation ledger")
struct ObservationLedgerTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let day: TimeInterval = 24 * 3600
  private static let radioID = UUID()
  private static let channel = StockCompanionFrames.channel
  private static let selfKey = StockCompanionFrames.selfKey
  private static let keyA = Data([0xC1, 0xA2, 0x3E] + [UInt8](repeating: 0x01, count: 29))
  private static let keyB = Data([0x7F, 0x3A] + [UInt8](repeating: 0x02, count: 30))

  private static func ledger(capacity: Int = ObservationLedger.capacity) -> ObservationLedger {
    ObservationLedger(radioID: radioID, channelKey: channel.key, channel: channel, selfKey: selfKey, capacity: capacity)
  }

  private static func observation(
    _ identity: ObservedIdentity,
    _ kind: ObservationKind = .advertRelayed,
    at: Date = t0,
    hops: Int? = 2,
    snr: Double? = nil,
    rssi: Int? = nil,
    name: String? = nil,
    type: UInt8? = nil,
    lat: Double? = nil,
    lon: Double? = nil,
    channelKey: ChannelKey = channel.key
  ) -> NodeObservation {
    NodeObservation(
      identity: identity,
      kind: kind,
      channelKey: channelKey,
      at: at,
      hops: hops,
      snr: snr,
      rssi: rssi,
      name: name,
      nodeTypeRaw: type,
      latitude: lat,
      longitude: lon
    )
  }

  // MARK: - Merging

  @Test
  func `the newest name, type and position win`() throws {
    var ledger = Self.ledger()
    ledger.ingest(Self.observation(.fullKey(Self.keyA), name: "Old", type: 1, lat: 34.0, lon: -117.0))
    ledger.ingest(Self.observation(.fullKey(Self.keyA), at: Self.t0 + 60, name: "Claremont", type: 2, lat: 34.1, lon: -117.7))
    // An older advert replayed later never overrides what is newer
    ledger.ingest(Self.observation(.fullKey(Self.keyA), at: Self.t0 - 60, name: "Older", type: 3, lat: 1, lon: 1))

    let node = try #require(ledger.node(for: .fullKey(Self.keyA)))
    #expect(node.name == "Claremont")
    #expect(node.nodeTypeRaw == 2)
    #expect(node.latitude == 34.1)
    #expect(node.longitude == -117.7)
    #expect(node.positionAt == Self.t0 + 60)
    #expect(node.firstObservedAt == Self.t0 - 60)
    #expect(node.lastObservedAt == Self.t0 + 60)
  }

  @Test
  func `a missing value never erases a stored one`() throws {
    var ledger = Self.ledger()
    ledger.ingest(Self.observation(.fullKey(Self.keyA), .advertDirect, hops: 0, snr: 7.5, rssi: -80, name: "Claremont", type: 2, lat: 34.1, lon: -117.7))
    // A newer radio push carries only the key
    ledger.ingest(Self.observation(.fullKey(Self.keyA), .radioVerifiedAdvert, at: Self.t0 + 60, hops: nil))
    // A newer direct reception without signal keeps the stored signal
    ledger.ingest(Self.observation(.fullKey(Self.keyA), .ownTraceHop, at: Self.t0 + 120, hops: 0))

    let node = try #require(ledger.node(for: .fullKey(Self.keyA)))
    #expect(node.name == "Claremont")
    #expect(node.nodeTypeRaw == 2)
    #expect(node.latitude == 34.1)
    #expect(node.lastDirectAt == Self.t0 + 120)
    #expect(node.lastDirectSNR == 7.5)
    #expect(node.lastDirectRSSI == -80)
    #expect(node.minHops == 0)
    #expect(node.lastHops == 0)
    #expect(Set(node.kinds.keys) == [.advertDirect, .radioVerifiedAdvert, .ownTraceHop])
    #expect(node.strongestKind == .advertDirect)
  }

  @Test
  func `signal is kept only for a direct observation`() {
    let relayed = Self.observation(.fullKey(Self.keyA), hops: 3, snr: 9, rssi: -70)
    #expect(relayed.snr == nil)
    #expect(relayed.rssi == nil)
    let unknownHops = Self.observation(.fullKey(Self.keyA), hops: nil, snr: 9, rssi: -70)
    #expect(unknownHops.snr == nil)
  }

  @Test
  func `observations on another channel or of this radio are ignored`() {
    var ledger = Self.ledger()
    let otherChannel = ledger.ingest(Self.observation(.fullKey(Self.keyA), channelKey: StockCompanionFrames.otherChannel.key))
    let ownKey = ledger.ingest(Self.observation(.fullKey(Self.selfKey)))
    let ownPrefix = ledger.ingest(Self.observation(.keyPrefix(Data(Self.selfKey.prefix(6)))))
    #expect(!otherChannel)
    #expect(!ownKey)
    #expect(!ownPrefix)
    #expect(ledger.count == 0)
    #expect(ledger.version == 0)
  }

  // MARK: - Folding

  @Test
  func `a prefix folds into its full key once the key is observed`() throws {
    var ledger = Self.ledger()
    let prefix = ObservedIdentity.keyPrefix(Data(Self.keyA.prefix(6)))
    ledger.ingest(Self.observation(prefix, .radioDecryptedReply, at: Self.t0, hops: nil))
    #expect(ledger.node(for: prefix) != nil)
    _ = ledger.takeChanges()

    ledger.ingest(Self.observation(.fullKey(Self.keyA), .advertDirect, at: Self.t0 + 60, hops: 0, snr: 5, name: "Claremont"))
    #expect(ledger.node(for: prefix) == nil)
    let node = try #require(ledger.node(for: .fullKey(Self.keyA)))
    #expect(node.kinds[.radioDecryptedReply]?.count == 1)
    #expect(node.kinds[.advertDirect]?.count == 1)
    #expect(node.firstObservedAt == Self.t0)
    #expect(ledger.count == 1)

    let changes = ledger.takeChanges()
    #expect(changes.upserted.map(\.identity) == [.fullKey(Self.keyA)])
    #expect(changes.removed == [prefix])

    // A later prefix observation joins the full key directly
    ledger.ingest(Self.observation(.keyPrefix(Data(Self.keyA.prefix(8))), .ownTraceHop, at: Self.t0 + 120, hops: 0))
    #expect(ledger.count == 1)
    #expect(ledger.node(for: .fullKey(Self.keyA))?.kinds[.ownTraceHop]?.count == 1)
  }

  @Test
  func `a shorter prefix joins a longer one that starts with it`() {
    var ledger = Self.ledger()
    ledger.ingest(Self.observation(.keyPrefix(Data(Self.keyA.prefix(8))), .discoverReply, hops: 0))
    ledger.ingest(Self.observation(.keyPrefix(Data(Self.keyA.prefix(6))), .radioDecryptedReply, at: Self.t0 + 1, hops: nil))
    #expect(ledger.count == 1)
    #expect(ledger.node(for: .keyPrefix(Data(Self.keyA.prefix(8))))?.kinds.count == 2)
  }

  @Test
  func `loading rows that name one node folds them`() {
    let prefixRow = ObservedNode(observation: Self.observation(.keyPrefix(Data(Self.keyA.prefix(6))), .radioDecryptedReply, hops: nil))
    let fullRow = ObservedNode(observation: Self.observation(.fullKey(Self.keyA), at: Self.t0 + 5))
    var ledger = ObservationLedger(radioID: Self.radioID, channelKey: Self.channel.key, selfKey: Self.selfKey, nodes: [prefixRow, fullRow])
    #expect(ledger.count == 1)
    let changes = ledger.takeChanges()
    #expect(changes.removed == [prefixRow.identity])
  }

  // MARK: - Ageing

  @Test
  func `rows are active for 7 days, stale until 30, then pruned`() {
    var ledger = Self.ledger()
    ledger.ingest(Self.observation(.fullKey(Self.keyA), at: Self.t0))
    let node = ledger.allNodes[0]

    #expect(ObservationLedger.isActive(node, at: Self.t0 + 7 * Self.day))
    #expect(!ObservationLedger.isActive(node, at: Self.t0 + 7 * Self.day + 1))
    #expect(ledger.isActive(.fullKey(Self.keyA), at: Self.t0))
    // A packet received before the node was observed still resolves to it
    #expect(ObservationLedger.isActive(node, at: Self.t0 - Self.day))

    let prunedAt30Days = ledger.prune(now: Self.t0 + 30 * Self.day)
    #expect(!prunedAt30Days)
    #expect(ledger.count == 1)
    let snapshot = ledger.snapshot(takenAt: Self.t0 + 10 * Self.day)
    #expect(snapshot.nodes.count == 1)
    #expect(snapshot.activeNodes(at: Self.t0 + 10 * Self.day).isEmpty)

    let prunedAfter30Days = ledger.prune(now: Self.t0 + 30 * Self.day + 1)
    #expect(prunedAfter30Days)
    #expect(ledger.count == 0)
    let changes = ledger.takeChanges()
    #expect(changes.removed == [.fullKey(Self.keyA)])
  }

  @Test
  func `the cap evicts the least recently observed`() {
    var ledger = Self.ledger(capacity: 3)
    for index in 0..<4 {
      let key = Data([UInt8(0x10 + index)] + [UInt8](repeating: 0x09, count: 31))
      ledger.ingest(Self.observation(.fullKey(key), at: Self.t0 + Double(index)))
    }
    #expect(ledger.count == 3)
    #expect(ledger.node(for: .fullKey(Data([0x10] + [UInt8](repeating: 0x09, count: 31)))) == nil)
    let changes = ledger.takeChanges()
    #expect(changes.upserted.count == 3)
    #expect(changes.removed.count == 1)
  }

  // MARK: - Versions and replay

  @Test
  func `version bumps only on change and replay is idempotent`() {
    var ledger = Self.ledger()
    let advert = Self.observation(.fullKey(Self.keyA), .advertDirect, hops: 0, snr: 5, rssi: -90, name: "Claremont", lat: 34.1, lon: -117.7)
    let relayed = Self.observation(.fullKey(Self.keyB), at: Self.t0 + 10, hops: 3)
    let firstIngest = ledger.ingest([advert, relayed])
    #expect(firstIngest)
    let version = ledger.version
    #expect(version == 2)
    let snapshot = ledger.snapshot(takenAt: Self.t0)
    _ = ledger.takeChanges()

    // Replaying the same observations (bootstrap from stored entries) changes nothing
    let replayed = ledger.ingest([advert, relayed])
    let replayedOne = ledger.ingest(advert)
    #expect(!replayed)
    #expect(!replayedOne)
    #expect(ledger.version == version)
    #expect(!ledger.hasChanges)
    #expect(ledger.snapshot(takenAt: Self.t0) == snapshot)
    #expect(ledger.node(for: .fullKey(Self.keyA))?.kinds[.advertDirect]?.count == 1)

    let newer = ledger.ingest(Self.observation(.fullKey(Self.keyA), .advertDirect, at: Self.t0 + 60, hops: 0))
    #expect(newer)
    #expect(ledger.version == version + 1)
    #expect(ledger.node(for: .fullKey(Self.keyA))?.kinds[.advertDirect]?.count == 2)
  }

  @Test
  func `a snapshot lists nodes newest first and finds them by prefix`() {
    var ledger = Self.ledger()
    ledger.ingest(Self.observation(.fullKey(Self.keyA), at: Self.t0))
    ledger.ingest(Self.observation(.fullKey(Self.keyB), at: Self.t0 + 5))
    let snapshot = ledger.snapshot(takenAt: Self.t0 + 10, version: 42)
    #expect(snapshot.version == 42)
    #expect(snapshot.channelKey == Self.channel.key)
    #expect(snapshot.selfKey == Self.selfKey)
    #expect(snapshot.nodes.map(\.identity) == [.fullKey(Self.keyB), .fullKey(Self.keyA)])
    #expect(snapshot.nodes(withPrefix: Data([0xC1])).map(\.identity) == [.fullKey(Self.keyA)])
    #expect(snapshot.nodes(withPrefix: Data([0xC1, 0xA2, 0x3E])).count == 1)
    #expect(snapshot.nodes(withPrefix: Data([0x55])).isEmpty)
    #expect(LedgerSnapshot.empty.isCold)
    #expect(!snapshot.isCold)
  }

  @Test
  func `identities parse from their bytes`() {
    #expect(ObservedIdentity(bytes: Self.keyA) == .fullKey(Self.keyA))
    #expect(ObservedIdentity(bytes: Data(Self.keyA.prefix(6))) == .keyPrefix(Data(Self.keyA.prefix(6))))
    #expect(ObservedIdentity(bytes: Data(Self.keyA.prefix(3))) == nil)
    #expect(ObservedIdentity(bytes: Data(count: 33)) == nil)
    #expect(ObservedIdentity.fullKey(Self.keyA).hasPrefix(Data([0xC1])))
    #expect(!ObservedIdentity.fullKey(Self.keyA).hasPrefix(Data()))
  }
}
