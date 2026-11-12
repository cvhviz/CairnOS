@testable import CairnServices
import CoreLocation
import Foundation
import MeshCore
import Testing

@Suite("PacketNodeIndex")
struct PacketNodeIndexTests {
  private typealias World = ClaremontStockFixtures

  // MARK: - Contents

  @Test
  func `only observed nodes are indexed as candidates; contacts and heard rows only label and hint`() {
    let index = World.index()
    #expect(index.keys.count == World.observedWorld.count)
    #expect(index.keys.entry(for: World.pomonaHillKey) == nil, "a discovered row never heard on this channel")
    #expect(index.unobserved.entry(for: World.pomonaHillKey) != nil)
    #expect(index.keys.entry(for: World.radioKey) == nil)
    #expect(index.keys.allEntries.allSatisfy { $0.isObserved })
    #expect(index.unobserved.allEntries.allSatisfy { !$0.isObserved })
    #expect(index.channelKey == World.channel.key)
  }

  @Test
  func `an observed node keeps the position it advertised, never a contact's stored one`() {
    let moved = World.claremont(latitude: 19.6, longitude: -155.9)
    let index = World.index(contacts: [moved, World.mtBaldy, World.alex()])
    let entry = index.keys.entry(for: World.claremontKey)
    #expect(entry?.latitude == World.claremontPosition.latitude)
    #expect(entry?.longitude == World.claremontPosition.longitude)
    // An observed node with no advertised position has none
    #expect(index.keys.entry(for: World.alexKey)?.latitude == nil)
  }

  @Test
  func `a nickname labels exactly the observed key it belongs to`() {
    let nicknamed = ContactDTO.testContact(radioID: World.radioID, publicKey: World.mtBaldyKey, name: "Mt Baldy", nickname: "Baldy")
    let index = World.index(contacts: [nicknamed])
    let entry = index.keys.entry(for: World.mtBaldyKey)
    #expect(entry?.name == "Baldy")
    #expect(entry?.advertisedName == "Mt Baldy")
    #expect(index.displayName(forKey: World.mtBaldyKey) == "Baldy")
    #expect(index.displayName(forKey: Data(World.mtBaldyKey.prefix(3))) == nil)
  }

  @Test
  func `nodes being removed are left out`() {
    let index = PacketNodeIndex(
      ledger: World.ledger(World.observedWorld + [World.pomonaHillObserved]),
      excluding: [World.claremontKey, World.pomonaHillKey]
    )
    #expect(index.keys.count == World.observedWorld.count - 1)
    #expect(index.candidates(matching: Data([0xC1]), at: World.receivedAt).isEmpty)
  }

  @Test
  func `a cold ledger resolves nothing`() {
    let index = PacketNodeIndex(selfKey: World.radioKey)
    #expect(index.isCold)
    #expect(index.selfKey == World.radioKey)
    #expect(PacketNodeResolver.resolveHash(Data([0xB4]), role: .relay, in: index) == .unknown(Data([0xB4])))
  }

  // MARK: - Activity

  @Test
  func `a node is a candidate within the active window of the packet's time`() {
    let index = World.index()
    let packetAt = World.receivedAt
    #expect(index.candidates(matching: Data([0xB4]), at: packetAt).count == 1)
    #expect(index.candidates(matching: Data([0xB4]), at: packetAt.addingTimeInterval(8 * 24 * 3600)).isEmpty)
    #expect(index.activeNodes(at: packetAt).count == World.observedWorld.count)
  }

  // MARK: - Hints

  @Test
  func `hints list stale observed nodes first, then saved and heard rows never observed`() {
    let stale = World.observation(World.pomonaHillKey, name: "Pomona Hill", at: World.receivedAt.addingTimeInterval(-9 * 24 * 3600))
    let index = World.index(observed: [stale, World.mtBaldyObserved])
    let sharers = index.unobservedSharers(of: Data([0xC1]), at: World.receivedAt)
    #expect(sharers.map(\.entry.publicKey) == [World.pomonaHillKey, World.claremontKey])
    #expect(sharers.map(\.reason) == [.stale(lastObservedAt: World.receivedAt.addingTimeInterval(-9 * 24 * 3600)), .notHeard])
    // An active observed node is a candidate, never a hint
    #expect(index.unobservedSharers(of: Data([0xB4]), at: World.receivedAt).isEmpty)
  }

  @Test
  func `a label for a key the packet proves comes from a contact only at 48 bits or more`() {
    let index = World.index(observed: [])
    #expect(index.label(forKey: World.alexKey) == "Alex")
    #expect(index.label(forKey: Data(World.alexKey.prefix(8))) == "Alex")
    #expect(index.label(forKey: Data(World.alexKey.prefix(3))) == nil)
  }

  // MARK: - Names

  @Test
  func `an advertised name finds its node exactly, and follows a rename`() {
    var keys = NeighbourKeyIndex(entries: [NeighbourKeyEntry(publicKey: World.claremontKey, nodeTypeRaw: 2, advertisedName: "Claremont")])
    #expect(keys.entries(named: "Claremont").map(\.publicKey) == [World.claremontKey])
    #expect(keys.entries(named: " Claremont ").map(\.publicKey) == [World.claremontKey])
    #expect(keys.entries(named: "claremont").isEmpty)
    #expect(keys.entries(named: "Clare").isEmpty)

    keys.remove(publicKey: World.claremontKey)
    keys.upsert(NeighbourKeyEntry(publicKey: World.claremontKey, nodeTypeRaw: 2, advertisedName: "Claremont Peak"))
    #expect(keys.entries(named: "Claremont").isEmpty)
    #expect(keys.entries(named: "Claremont Peak").map(\.publicKey) == [World.claremontKey])

    // A nameless update keeps the name
    keys.upsert(NeighbourKeyEntry(publicKey: World.claremontKey, nodeTypeRaw: 2))
    #expect(keys.entries(named: "Claremont Peak").count == 1)

    keys.upsert(NeighbourKeyEntry(publicKey: World.mtBaldyKey, nodeTypeRaw: 2, advertisedName: "Claremont Peak"))
    #expect(keys.entries(named: "Claremont Peak").map(\.publicKey) == [World.mtBaldyKey, World.claremontKey])

    keys.remove(publicKey: World.claremontKey)
    #expect(keys.entries(named: "Claremont Peak").map(\.publicKey) == [World.mtBaldyKey])
  }

  @Test
  func `the key index finds keys by 1-, 2- and 3-byte prefixes, and overlapping prefixes, never our own key`() {
    let prefix = Data(World.claremontKey.prefix(6))
    let keys = NeighbourKeyIndex(selfKey: World.radioKey, entries: [
      NeighbourKeyEntry(publicKey: World.claremontKey, nodeTypeRaw: 2),
      NeighbourKeyEntry(publicKey: World.pomonaHillKey, nodeTypeRaw: 2),
      NeighbourKeyEntry(publicKey: World.radioKey, nodeTypeRaw: 1),
      NeighbourKeyEntry(publicKey: Data(World.mtBaldyKey.prefix(6)), nodeTypeRaw: 2),
    ])
    #expect(keys.count == 3)
    #expect(keys.candidates(matching: Data([0xC1])).count == 2)
    #expect(keys.candidates(matching: Data([0xC1, 0xA2])).map(\.publicKey) == [World.claremontKey])
    #expect(keys.candidates(matching: Data([0xC1, 0xA2, 0x3E, 0x11])).map(\.publicKey) == [World.claremontKey])
    #expect(keys.candidates(matching: prefix).map(\.publicKey) == [World.claremontKey])
    #expect(keys.candidates(matching: Data([0xAA])).isEmpty)
    // A full key finds the 6-byte prefix it starts with
    #expect(keys.entries(overlapping: World.mtBaldyKey).map(\.publicKey) == [Data(World.mtBaldyKey.prefix(6))])
  }

  @Test
  func `unique names keep only the prefixes one active observed node has`() {
    let names = World.index(observed: World.observedWorld + [World.pomonaHillObserved]).uniqueNames()
    #expect(names[Data([0xC1])] == nil)
    #expect(names[Data([0xC1, 0xA2])] == "Claremont")
    #expect(names[Data([0xC1, 0x77, 0x20])] == "Pomona Hill")
    #expect(names[Data([0xB4])] == "Mt Baldy")
    #expect(names[Data([0x5A, 0x33])] == "Alex")
    #expect(names[Data([0xAA])] == nil)
    // A contact never observed names nothing
    #expect(World.index(observed: []).uniqueNames().isEmpty)
  }

  // MARK: - Anchor

  @Test
  func `the anchor is the radio's position unless the phone is far from it`() throws {
    let upland = DeviceDTO.testDevice().copy {
      $0.latitude = World.radio.latitude
      $0.longitude = World.radio.longitude
    }
    let florida = upland.copy {
      $0.latitude = 28.95
      $0.longitude = -82.46
    }
    let nearby = CLLocationCoordinate2D(latitude: 34.11, longitude: -117.70)

    let stale = try #require(PacketNodeIndex.anchor(device: florida, phone: nearby))
    #expect(stale.latitude == nearby.latitude)
    let fresh = try #require(PacketNodeIndex.anchor(device: upland, phone: nearby))
    #expect(fresh.latitude == World.radio.latitude)
    #expect(PacketNodeIndex.anchor(device: florida, phone: nil)?.latitude == 28.95)
    #expect(PacketNodeIndex.anchor(device: nil, phone: nearby)?.longitude == nearby.longitude)
    #expect(PacketNodeIndex.anchor(device: DeviceDTO.testDevice(), phone: nil) == nil)
    #expect(PacketNodeIndex.anchor(device: nil, phone: CLLocationCoordinate2D(latitude: 0, longitude: 0)) == nil)
  }
}
