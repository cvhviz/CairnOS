@testable import CairnServices
import Foundation
import MeshCore
import Testing

/// A saved contact this radio heard from lately stands in for an observation when the app asks
/// (`savedNodesHeardSince`): a radio new to the app places the relays it knows before it has
/// heard their adverts again.
@Suite("Saved node fallback")
struct SavedNodeFallbackTests {
  private typealias World = ClaremontStockFixtures

  private static let hopKey = World.key([0x4B, 0x44, 0xFE], fill: 0x5C)

  private static func repeater(heardAgo seconds: TimeInterval, latitude: Double = 28.9464, longitude: Double = -82.4559) -> ContactDTO {
    let heard = UInt32(World.receivedAt.addingTimeInterval(-seconds).timeIntervalSince1970)
    return .testContact(
      radioID: World.radioID, publicKey: hopKey, name: "FL-YAGI-RP-4B44",
      typeRawValue: ContactType.repeater.rawValue, latitude: latitude, longitude: longitude,
      lastModified: heard, lastHeardTimestamp: heard
    )
  }

  private static func index(_ contacts: [ContactDTO], since: Date?, observed: [NodeObservation] = World.observedWorld) -> PacketNodeIndex {
    PacketNodeIndex(
      ledger: World.ledger(observed),
      selfKey: World.radioKey,
      unobserved: NeighbourKeyIndex(selfKey: World.radioKey, entries: contacts.map(NeighbourKeyEntry.init)),
      savedNodesHeardSince: since
    )
  }

  @Test
  func `a repeater heard lately is a candidate at its advertised position`() throws {
    let index = Self.index([Self.repeater(heardAgo: 3600)], since: .distantPast)
    let match = PacketNodeResolver.resolveHash(Data([0x4B, 0x44, 0xFE]), role: .relay, in: index)
    guard case let .resolved(entry) = match else {
      Issue.record("expected the saved repeater, got \(match)")
      return
    }
    #expect(entry.publicKey == Self.hopKey)
    #expect(entry.latitude == 28.9464)
    // a shorter hash names it too
    #expect(index.candidates(matching: Data([0x4B, 0x44]), at: World.receivedAt).map(\.publicKey) == [Self.hopKey])
    // not among the observed nodes, but offered to a map that pins every node it knows
    #expect(!index.activeNodes().contains { $0.publicKey == Self.hopKey })
    #expect(index.savedStandIns.map(\.publicKey) == [Self.hopKey])
  }

  @Test
  func `nothing stands in unless the app asks`() {
    let index = Self.index([Self.repeater(heardAgo: 3600)], since: nil)
    #expect(index.keys.entry(for: Self.hopKey) == nil)
    #expect(index.savedStandIns.isEmpty)
  }

  @Test
  func `one heard before the active window, or before the radio was last elsewhere, doesn't`() {
    let old = Self.index([Self.repeater(heardAgo: 8 * 24 * 3600)], since: .distantPast)
    #expect(old.keys.entry(for: Self.hopKey) == nil)
    let elsewhere = Self.index([Self.repeater(heardAgo: 3 * 3600)], since: World.receivedAt.addingTimeInterval(-3600))
    #expect(elsewhere.keys.entry(for: Self.hopKey) == nil)
  }

  @Test
  func `one without a position names its hops, unplaced`() throws {
    let unplaced = Self.index([Self.repeater(heardAgo: 3600, latitude: 0, longitude: 0)], since: .distantPast)
    let match = PacketNodeResolver.resolveHash(Data([0x4B, 0x44, 0xFE]), role: .relay, in: unplaced)
    guard case let .resolved(entry) = match else {
      Issue.record("expected the saved repeater, got \(match)")
      return
    }
    #expect(entry.publicKey == Self.hopKey)
    #expect(entry.name == "FL-YAGI-RP-4B44")
    #expect(entry.coordinate == nil)
  }

  @Test
  func `the ledger's own node keeps its observed position`() {
    // Claremont is observed: its observation stands, not the contact's stored position
    let moved = World.claremont(latitude: 19.6, longitude: -155.9)
    let observed = Self.index([moved], since: .distantPast)
    #expect(observed.keys.entry(for: World.claremontKey)?.latitude == World.claremontPosition.latitude)
  }

  @Test
  func `a cold ledger takes none`() {
    let index = PacketNodeIndex(
      unobserved: NeighbourKeyIndex(entries: [NeighbourKeyEntry(Self.repeater(heardAgo: 60))]),
      savedNodesHeardSince: .distantPast
    )
    #expect(index.keys.count == 0)
  }

  @Test
  func `a node the ledger holds only by a key prefix takes the saved node's key and position`() throws {
    // A 6-byte reply named it, without a name or position (Mustang Repeater's 25F39DC4391B)
    let prefix = Data(Self.hopKey.prefix(6))
    let reply = NodeObservation(
      identity: try #require(ObservedIdentity(bytes: prefix)),
      kind: .discoverReply,
      channelKey: World.channel.key,
      at: World.receivedAt.addingTimeInterval(-600),
      hops: 0,
      snr: 6,
      rssi: -90,
      nodeTypeRaw: ContactType.repeater.rawValue
    )
    let index = Self.index([Self.repeater(heardAgo: 3600)], since: .distantPast, observed: World.observedWorld + [reply])
    #expect(index.keys.entry(for: prefix) == nil)
    let entry = try #require(index.keys.entry(for: Self.hopKey))
    #expect(entry.latitude == 28.9464)
    #expect(entry.name == "FL-YAGI-RP-4B44")
    // still the radio's observation: pinned with the rest, and one candidate for its hash
    #expect(index.activeNodes().contains { $0.publicKey == Self.hopKey })
    #expect(index.candidates(matching: Data([0x4B, 0x44]), at: World.receivedAt).map(\.publicKey) == [Self.hopKey])

    // without the fallback the prefix stands as it was
    let strict = Self.index([Self.repeater(heardAgo: 3600)], since: nil, observed: World.observedWorld + [reply])
    #expect(strict.keys.entry(for: prefix) != nil)
  }
}
