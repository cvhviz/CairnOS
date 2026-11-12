import Foundation
@testable import CairnServices
import MeshCore
import SwiftData
import Testing

@Suite("Observation persistence")
struct ObservationPersistenceTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let key = Data([0xC1, 0xA2, 0x3E] + [UInt8](repeating: 0x21, count: 29))
  private static let otherKey = Data([0x7F, 0x3A] + [UInt8](repeating: 0x42, count: 30))
  private static let channelKey = StockCompanionFrames.channel.key
  private static let otherChannelKey = StockCompanionFrames.otherChannel.key

  private static func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  /// A node with every field set.
  private static func fullNode() -> ObservedNode {
    ObservedNode(
      identity: .fullKey(key),
      name: "Claremont",
      nodeTypeRaw: 2,
      latitude: 34.0967,
      longitude: -117.7198,
      positionAt: t0.addingTimeInterval(30),
      firstObservedAt: t0,
      lastObservedAt: t0.addingTimeInterval(90),
      lastDirectAt: t0.addingTimeInterval(60),
      lastDirectSNR: 7.25,
      lastDirectRSSI: -88,
      minHops: 0,
      lastHops: 2,
      kinds: [
        .advertDirect: KindStat(count: 3, lastAt: t0.addingTimeInterval(60)),
        .advertRelayed: KindStat(count: 5, lastAt: t0.addingTimeInterval(90)),
        .radioDecryptedReply: KindStat(count: 1, lastAt: t0.addingTimeInterval(10))
      ]
    )
  }

  private static func node(_ identity: ObservedIdentity, lastObservedAt: Date) -> ObservedNode {
    ObservedNode(
      identity: identity,
      firstObservedAt: lastObservedAt,
      lastObservedAt: lastObservedAt,
      kinds: [.advertRelayed: KindStat(count: 1, lastAt: lastObservedAt)]
    )
  }

  @Test
  func `every field round-trips`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let prefixNode = Self.node(.keyPrefix(Data(Self.otherKey.prefix(6))), lastObservedAt: Self.t0)
    try await store.saveObservedNodes(
      radioID: radioID,
      channelKey: Self.channelKey,
      upserting: [Self.fullNode(), prefixNode],
      removing: []
    )

    let fetched = try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey)
    #expect(fetched == [Self.fullNode(), prefixNode])
  }

  @Test
  func `an upsert replaces the row and a removal deletes it`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [Self.fullNode()], removing: [])

    var updated = Self.fullNode()
    updated.name = "Claremont Peak"
    let other = Self.node(.fullKey(Self.otherKey), lastObservedAt: Self.t0)
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [updated, other], removing: [])
    var fetched = try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey)
    #expect(fetched.map(\.name) == ["Claremont Peak", nil])

    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [], removing: [.fullKey(Self.key)])
    fetched = try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey)
    #expect(fetched.map(\.identity) == [.fullKey(Self.otherKey)])
  }

  @Test
  func `rows are kept apart by channel and by radio`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let otherRadio = UUID()
    let here = Self.node(.fullKey(Self.key), lastObservedAt: Self.t0)
    let there = Self.node(.fullKey(Self.otherKey), lastObservedAt: Self.t0)
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [here], removing: [])
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey, upserting: [there], removing: [])
    try await store.saveObservedNodes(radioID: otherRadio, channelKey: Self.channelKey, upserting: [there], removing: [])
    // The same node on two channels is two rows
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey, upserting: [here], removing: [])

    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey).map(\.identity) == [.fullKey(Self.key)])
    #expect(try await Set(store.fetchObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey).map(\.identity))
      == [.fullKey(Self.key), .fullKey(Self.otherKey)])
    #expect(try await store.fetchObservedNodes(radioID: otherRadio, channelKey: Self.channelKey).map(\.identity) == [.fullKey(Self.otherKey)])

    // Removing on one channel leaves the other alone
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey, upserting: [], removing: [.fullKey(Self.key)])
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey).count == 1)
  }

  @Test
  func `prune deletes old rows on every channel and clear deletes a radio's rows`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let otherRadio = UUID()
    let old = Self.node(.fullKey(Self.key), lastObservedAt: Self.t0)
    let recent = Self.node(.fullKey(Self.otherKey), lastObservedAt: Self.t0.addingTimeInterval(3600))
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [old, recent], removing: [])
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey, upserting: [old], removing: [])
    try await store.saveObservedNodes(radioID: otherRadio, channelKey: Self.channelKey, upserting: [old], removing: [])

    let pruned = try await store.pruneObservedNodes(radioID: radioID, notObservedSince: Self.t0.addingTimeInterval(60))
    #expect(pruned == 2)
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey).map(\.identity) == [.fullKey(Self.otherKey)])
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey).isEmpty)
    #expect(try await store.fetchObservedNodes(radioID: otherRadio, channelKey: Self.channelKey).count == 1)

    try await store.clearObservedNodes(radioID: radioID)
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey).isEmpty)
    #expect(try await store.fetchObservedNodes(radioID: otherRadio, channelKey: Self.channelKey).count == 1)
  }

  @Test
  func `deleting a device deletes its observed nodes`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    try await store.saveDevice(DeviceDTO.testDevice(id: radioID))
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [Self.fullNode()], removing: [])

    try await store.deleteDeviceAndData(id: radioID)
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey).isEmpty)
  }

  @Test
  func `a ledger reloaded from the store matches the one that saved it`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let channel = StockCompanionFrames.channel
    var ledger = ObservationLedger(radioID: radioID, channel: channel, selfKey: StockCompanionFrames.selfKey)
    ledger.ingest(NodeObservation(
      identity: .fullKey(Self.key), kind: .advertDirect, channelKey: channel.key, at: Self.t0,
      hops: 0, snr: 6.5, rssi: -90, name: "Claremont", nodeTypeRaw: 2, latitude: 34.1, longitude: -117.7
    ))
    ledger.ingest(NodeObservation(
      identity: .keyPrefix(Data(Self.otherKey.prefix(6))), kind: .radioDecryptedReply, channelKey: channel.key,
      at: Self.t0.addingTimeInterval(5), hops: nil
    ))
    let changes = ledger.takeChanges()
    try await store.saveObservedNodes(radioID: radioID, channelKey: channel.key, upserting: changes.upserted, removing: changes.removed)

    let reloaded = try ObservationLedger(
      radioID: radioID,
      channel: channel,
      selfKey: StockCompanionFrames.selfKey,
      nodes: await store.fetchObservedNodes(radioID: radioID, channelKey: channel.key)
    )
    #expect(reloaded.snapshot(takenAt: Self.t0).nodes == ledger.snapshot(takenAt: Self.t0).nodes)
    #expect(!reloaded.hasChanges)
  }

  @Test
  func `the mock store keeps rows apart by radio and channel`() async throws {
    let store = MockPersistenceStore()
    let radioID = UUID()
    try await store.saveObservedNodes(radioID: radioID, channelKey: Self.channelKey, upserting: [Self.fullNode()], removing: [])
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.channelKey) == [Self.fullNode()])
    #expect(try await store.fetchObservedNodes(radioID: radioID, channelKey: Self.otherChannelKey).isEmpty)
    #expect(await store.observedNodeSaveCount == 1)
    #expect(try await store.pruneObservedNodes(radioID: radioID, notObservedSince: Self.t0.addingTimeInterval(3600)) == 1)
  }
}
