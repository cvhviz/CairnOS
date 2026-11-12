import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// The app's one index of what this radio heard on its channel: saved contacts only label and
/// hint, rows resolve against the channel they were received on, and other channels' ledgers are
/// kept, a few at a time.
@Suite("ObservationDirectory")
@MainActor
struct ObservationDirectoryTests {
  typealias World = TrafficClaremontFixtures

  @Test
  func `a contact's nickname names an observed node only for exactly its key`() throws {
    let nicknamed = World.contact(World.mtBaldyKey, name: "Baldy", type: ContactType.repeater.rawValue, nickname: "Old Baldy")
    // Shares Mt Baldy's first three bytes, but not its key.
    let lookalike = World.contact(World.key([0xB4, 0x5D, 0x01], fill: 0xEE), name: "Lookalike", type: ContactType.repeater.rawValue)
    let directory = World.observationDirectory(contacts: [nicknamed, lookalike], discovered: [])
    let entry = directory.nodeIndex.keys.entry(for: World.mtBaldyKey)
    #expect(entry?.name == "Old Baldy")
    #expect(entry?.advertisedName == "Mt Baldy")
    #expect(directory.nodeIndex.keys.entry(for: lookalike.publicKey) == nil)
    #expect(directory.contact(forKey: World.mtBaldyKey)?.nickname == "Old Baldy")
  }

  @Test
  func `contacts never heard here give hints, never candidates`() {
    let kona = World.contact(World.key([0x7F, 0x3A], fill: 0x91), name: "Kona Hill", type: ContactType.repeater.rawValue, latitude: 19.6, longitude: -156)
    let directory = World.observationDirectory(contacts: [kona], discovered: [])
    let index = directory.nodeIndex
    #expect(index.candidates(matching: Data([0x7F]), at: World.receivedAt).isEmpty)
    let hint = index.unobservedSharers(of: Data([0x7F]), at: World.receivedAt).first
    #expect(hint?.entry.name == "Kona Hill")
    #expect(hint?.reason == .notHeard)
  }

  @Test
  func `a snapshot that differs only by when it was taken changes nothing`() {
    let directory = World.observationDirectory()
    let version = directory.version
    let index = directory.nodeIndex
    // NeighbourService stamps each snapshot it sends, as often as once a second
    directory.setLedger(World.ledger(World.observedWorld, takenAt: World.receivedAt.addingTimeInterval(1)))
    directory.setLedger(World.ledger(World.observedWorld, takenAt: World.receivedAt.addingTimeInterval(2)))
    #expect(directory.version == version)
    #expect(directory.nodeIndex.ledger.takenAt == index.ledger.takenAt)

    // A real change is taken in at once, and so is a time far enough on to age the window
    directory.setLedger(World.ledger(World.observedWorld + [World.pomonaHillObserved], takenAt: World.receivedAt.addingTimeInterval(3)))
    #expect(directory.version != version)
    let changed = directory.version
    directory.setLedger(World.ledger(World.observedWorld + [World.pomonaHillObserved], takenAt: World.receivedAt.addingTimeInterval(3 + ObservationDirectory.ledgerRefreshInterval)))
    #expect(directory.version != changed)
  }

  @Test
  func `an entry resolves against the ledger of the channel it was received on`() {
    let directory = World.observationDirectory()
    let here = World.c3(.stock)
    let unstamped = World.entry(World.frame(.groupText, pathLength: 0x01, path: [0xC1], payload: World.groupTextPayload), firmware: .stock, channel: nil)
    let elsewhere = World.entry(World.frame(.groupText, pathLength: 0x01, path: [0xC1], payload: World.groupTextPayload), firmware: .stock, channel: World.otherChannel)
    #expect(directory.index(for: here).channelKey == World.channel.key)
    #expect(directory.index(for: unstamped).isCold)
    // Not read in yet: cold, so its hashes show unknown rather than be named from this channel.
    #expect(directory.index(for: elsewhere).isCold)

    let version = directory.version
    directory.store(World.ledger([World.pomonaHillObserved.on(World.otherChannel)], channel: World.otherChannel), for: World.otherChannel.key)
    #expect(directory.version != version)
    let index = directory.index(for: elsewhere)
    #expect(index.channelKey == World.otherChannel.key)
    let hop = PacketNodeResolver.resolve(elsewhere, in: index).hops.first
    #expect(hop?.entry?.publicKey == World.pomonaHillKey)
  }

  @Test
  func `other channels' ledgers are kept at most four at a time, the least recently used going first`() {
    let directory = World.observationDirectory()
    let channels = (0..<6).map { RadioChannelConfig(frequencyKHz: 902_000 + UInt32($0) * 1000, bandwidthHz: 125_000, spreadingFactor: 9, codingRate: 5) }
    for channel in channels {
      directory.store(World.ledger([], channel: channel), for: channel.key)
    }
    #expect(directory.otherChannelCount == ObservationDirectory.otherChannelCapacity)
    let oldest = World.entry(World.frame(.groupText, pathLength: 0, path: [], payload: World.groupTextPayload), firmware: .stock, channel: channels[0])
    #expect(directory.index(for: oldest).isCold)
    let newest = World.entry(World.frame(.groupText, pathLength: 0, path: [], payload: World.groupTextPayload), firmware: .stock, channel: channels[5])
    #expect(directory.index(for: newest).channelKey == channels[5].key)
  }

  @Test
  func `the version moves with the ledger and the labels, not with a ledger that didn't change`() {
    let directory = World.observationDirectory()
    let version = directory.version
    directory.setLedger(World.ledger())
    #expect(directory.version == version)
    directory.setLabels(contacts: [], discovered: [])
    #expect(directory.version != version)
    let afterLabels = directory.version
    directory.setLedger(World.ledger(World.observedWorld + [World.pomonaHillObserved]))
    #expect(directory.version != afterLabels)
  }

  @Test
  func `a channel first heard lately is still being learned`() {
    let fresh = World.observationDirectory(observed: [World.observation(World.mtBaldyKey, name: "Mt Baldy", at: World.receivedAt.addingTimeInterval(-600))])
    #expect(fresh.isLearningChannel(now: World.receivedAt))
    let settled = World.observationDirectory(observed: [World.observation(World.mtBaldyKey, name: "Mt Baldy", at: World.receivedAt.addingTimeInterval(-3 * 86400))])
    #expect(!settled.isLearningChannel(now: World.receivedAt))
    // No channel yet: nothing to learn.
    #expect(!ObservationDirectory().isLearningChannel(now: World.receivedAt))
  }
}

extension NodeObservation {
  /// This observation as made on `channel`.
  func on(_ channel: RadioChannelConfig) -> NodeObservation {
    NodeObservation(
      identity: identity, kind: kind, channelKey: channel.key, at: at, hops: hops, snr: snr, rssi: rssi,
      name: name, nodeTypeRaw: nodeTypeRaw, latitude: latitude, longitude: longitude, entryID: entryID
    )
  }
}
