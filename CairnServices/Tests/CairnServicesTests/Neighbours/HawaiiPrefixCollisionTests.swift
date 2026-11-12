@testable import CairnServices
import Foundation
import MeshCore
import Testing

/// The radio is in California with two Hawaii repeaters saved as contacts. A local relay nobody
/// heard advertise shares Kona Hill's first byte, another shares Hilo Ridge's. A flood relayed by
/// those two must show two unknown hops by their hashes, never Hawaii, and no distance rule may be
/// what decides it: moving the Hawaii positions next to the radio, or taking the radio's position
/// away, changes nothing.
@Suite("Hawaii prefix collisions")
struct HawaiiPrefixCollisionTests {
  private typealias World = ClaremontStockFixtures
  typealias Firmware = ClaremontStockFixtures.Firmware

  // MARK: - Fixtures

  static let konaHillKey = World.key([0x7F, 0x3A, 0x10], fill: 0x71)
  static let hiloRidgeKey = World.key([0xC1, 0x9B, 0x20], fill: 0x72)
  static let kona = (latitude: 19.64, longitude: -155.99)
  static let hilo = (latitude: 19.72, longitude: -155.09)

  /// The Hawaii repeaters, saved as contacts and listed as discovered nodes, placed at `kona` and
  /// `hilo`.
  static func hawaii(
    kona: (latitude: Double, longitude: Double) = kona,
    hilo: (latitude: Double, longitude: Double) = hilo
  ) -> (contacts: [ContactDTO], discovered: [DiscoveredNodeDTO]) {
    let contacts: [ContactDTO] = [
      .testContact(radioID: World.radioID, publicKey: konaHillKey, name: "Kona Hill", typeRawValue: 2, latitude: kona.latitude, longitude: kona.longitude),
      .testContact(radioID: World.radioID, publicKey: hiloRidgeKey, name: "Hilo Ridge", typeRawValue: 2, latitude: hilo.latitude, longitude: hilo.longitude),
    ]
    let discovered = [
      World.discovered(konaHillKey, name: "Kona Hill", type: 2, latitude: kona.latitude, longitude: kona.longitude),
      World.discovered(hiloRidgeKey, name: "Hilo Ridge", type: 2, latitude: hilo.latitude, longitude: hilo.longitude),
    ]
    return (contacts, discovered)
  }

  /// What this radio observed in SoCal: Mt Baldy and Glendora Room, neither sharing 0x7F or 0xC1.
  static var soCal: [NodeObservation] {
    [World.mtBaldyObserved, World.glendoraRoomObserved]
  }

  /// A flood channel message relayed by two local relays with 1-byte hashes 7F then C1, stamped
  /// with the California channel.
  static func flood(_ firmware: Firmware) -> RxLogEntryDTO {
    World.entry(World.frame(.groupText, pathLength: 0x02, path: [0x7F, 0xC1], payload: World.groupTextPayload), firmware: firmware)
  }

  static func index(
    observed: [NodeObservation] = soCal,
    hawaii: (contacts: [ContactDTO], discovered: [DiscoveredNodeDTO]) = hawaii(),
    anchor: (latitude: Double, longitude: Double)? = World.radio,
    channel: RadioChannelConfig = World.channel
  ) -> PacketNodeIndex {
    World.index(observed: observed, channel: channel, contacts: hawaii.contacts, discovered: hawaii.discovered, anchor: anchor)
  }

  // MARK: - Tests

  @Test(arguments: Firmware.allCases)
  func `hops only Hawaii contacts share are unknown by their hashes, with a hint`(firmware: Firmware) {
    let nodes = PacketNodeResolver.resolve(Self.flood(firmware), in: Self.index())

    #expect(nodes.hops.map(\.match) == [.unknown(Data([0x7F])), .unknown(Data([0xC1]))])
    #expect(nodes.hops.map(\.displayName) == ["7F", "C1"])
    #expect(nodes.hops.allSatisfy { !$0.isNamed && !$0.hasPosition })
    #expect(nodes.named.isEmpty)
    #expect(nodes.offMap.isEmpty)
    // Only the detail view's hint names Hawaii
    #expect(nodes.hops.map(\.unobservedHint?.entry.name) == ["Kona Hill", "Hilo Ridge"])
    #expect(nodes.hops.map(\.unobservedHint?.reason) == [.notHeard, .notHeard])
    #expect(nodes.transmitter == .hop(index: 1, isReached: true))
  }

  @Test(arguments: Firmware.allCases)
  func `no distance rule decides it: the same with Hawaii next to the radio, or no radio position`(firmware: Firmware) {
    let entry = Self.flood(firmware)
    let inHawaii = PacketNodeResolver.resolve(entry, in: Self.index())
    let nextDoor = PacketNodeResolver.resolve(entry, in: Self.index(hawaii: Self.hawaii(
      kona: (World.radio.latitude + 0.01, World.radio.longitude),
      hilo: (World.radio.latitude, World.radio.longitude + 0.01)
    )))
    let unanchored = PacketNodeResolver.resolve(entry, in: Self.index(anchor: nil))

    #expect(nextDoor.hops.map(\.match) == inHawaii.hops.map(\.match))
    #expect(unanchored.hops.map(\.match) == inHawaii.hops.map(\.match))
    #expect(nextDoor.hops.map(\.displayName) == ["7F", "C1"])
    #expect(unanchored.hops.map(\.displayName) == ["7F", "C1"])
  }

  @Test(arguments: Firmware.allCases)
  func `Kona Hill heard on another channel is never a candidate for California packets`(firmware: Firmware) {
    let heardInHawaii = World.observation(
      Self.konaHillKey, name: "Kona Hill", latitude: Self.kona.latitude, longitude: Self.kona.longitude,
      hops: 0, channel: World.otherChannel
    )
    // The California ledger never takes it
    let california = Self.index(observed: Self.soCal + [heardInHawaii])
    #expect(california.keys.entry(for: Self.konaHillKey) == nil)
    #expect(PacketNodeResolver.resolve(Self.flood(firmware), in: california).hops.first?.match == .unknown(Data([0x7F])))

    // Hawaii's own ledger holds it, but a California packet gets no ledger there (R0)
    let hawaiiLedger = Self.index(observed: [heardInHawaii], channel: World.otherChannel)
    #expect(hawaiiLedger.keys.entry(for: Self.konaHillKey) != nil)
    let resolved = PacketNodeResolver.resolve(Self.flood(firmware), in: hawaiiLedger)
    #expect(resolved.hops.map(\.displayName) == ["7F", "C1"])
    #expect(resolved.hops.allSatisfy { !$0.isNamed })
  }

  @Test(arguments: Firmware.allCases)
  func `an imported node never heard is never a candidate`(firmware: Firmware) {
    let imported = World.discovered(World.key([0x7F, 0x01], fill: 0x73), name: "Imported Peak", type: 2, latitude: 34.1, longitude: -117.7)
    let index = Self.index(hawaii: ([], [imported]))
    let hop = PacketNodeResolver.resolve(Self.flood(firmware), in: index).hops.first
    #expect(hop?.match == .unknown(Data([0x7F])))
    #expect(hop?.unobservedHint?.entry.name == "Imported Peak")
  }

  @Test(arguments: Firmware.allCases)
  func `a local relay observed on this channel resolves where Hawaii never could`(firmware: Firmware) {
    let local = World.observation(World.key([0x7F, 0x55], fill: 0x74), name: "Upland Relay", latitude: 34.10, longitude: -117.64, hops: 0)
    let nodes = PacketNodeResolver.resolve(Self.flood(firmware), in: Self.index(observed: Self.soCal + [local]))
    #expect(nodes.hops.map(\.displayName) == ["Upland Relay", "C1"])
    #expect(nodes.hops[0].isObserved)
    #expect(nodes.hops[1].unobservedHint?.entry.name == "Hilo Ridge")
  }

  @Test
  func `a far observed position is only flagged, never re-resolved`() {
    // A node this radio really observed on this channel, advertising a Hawaii position
    let farAway = World.observation(Self.hiloRidgeKey, name: "Hilo Ridge", latitude: Self.hilo.latitude, longitude: Self.hilo.longitude, hops: 0)
    let nodes = PacketNodeResolver.resolve(Self.flood(.stock), in: Self.index(observed: Self.soCal + [farAway]))
    #expect(nodes.hops[1].displayName == "Hilo Ridge")
    #expect(nodes.hops[1].isSuspicious)
    #expect(nodes.hops[0].match == .unknown(Data([0x7F])))
  }
}
