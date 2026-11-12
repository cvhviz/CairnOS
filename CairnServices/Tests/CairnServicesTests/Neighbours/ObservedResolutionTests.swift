@testable import CairnServices
import Foundation
import MeshCore
import Testing

/// Identity comes from observation: a hop names a node only once this radio observed that node
/// on the channel the packet was received on.
@Suite("Observed resolution")
struct ObservedResolutionTests {
  private typealias World = ClaremontStockFixtures
  typealias Firmware = ClaremontStockFixtures.Firmware

  /// A flood channel message relayed by one 1-byte hop, C1.
  private static func viaC1(_ firmware: Firmware, channel: RadioChannelConfig? = World.channel) -> RxLogEntryDTO {
    World.entry(World.frame(.groupText, pathLength: 0x01, path: [0xC1], payload: World.groupTextPayload), firmware: firmware, channel: channel)
  }

  /// The ledger after ingesting `entries` the way NeighbourService does: every observation each
  /// stamped entry carries.
  private static func ledger(after entries: [RxLogEntryDTO], seed: [NodeObservation] = [World.mtBaldyObserved]) -> LedgerSnapshot {
    var ledger = ObservationLedger(radioID: World.radioID, channel: World.channel, selfKey: World.radioKey)
    ledger.ingest(seed)
    for entry in entries {
      ledger.ingest(ObservationExtractor.observations(from: entry, selfKey: World.radioKey))
    }
    return ledger.snapshot(takenAt: World.receivedAt)
  }

  private static func index(_ ledger: LedgerSnapshot, contacts: [ContactDTO] = World.savedContacts) -> PacketNodeIndex {
    PacketNodeIndex(
      ledger: ledger,
      selfName: "Base",
      anchorLatitude: World.radio.latitude,
      anchorLongitude: World.radio.longitude,
      displayNames: Dictionary(contacts.map { ($0.publicKey, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
      unobserved: NeighbourKeyIndex(selfKey: World.radioKey, entries: contacts.map(NeighbourKeyEntry.init))
    )
  }

  // MARK: - Learning by observation

  @Test(arguments: Firmware.allCases)
  func `a local repeater resolves once its signed advert is received, at the advertised position`(firmware: Firmware) throws {
    // A saved Claremont contact, stored somewhere else, is no candidate
    let storedElsewhere = ContactDTO.testContact(
      radioID: World.radioID, publicKey: World.localC1Key, name: "Claremont (old)", typeRawValue: 2, latitude: 36.0, longitude: -119.0
    )
    let before = PacketNodeResolver.resolve(Self.viaC1(firmware), in: Self.index(Self.ledger(after: []), contacts: [storedElsewhere]))
    #expect(before.hops.first?.match == .unknown(Data([0xC1])))

    let advert = World.signedClaremontAdvert(path: [0xB4, 0x9E], firmware: firmware, receivedAt: World.receivedAt.addingTimeInterval(-300))
    let after = PacketNodeResolver.resolve(Self.viaC1(firmware), in: Self.index(Self.ledger(after: [advert]), contacts: []))
    let hop = try #require(after.hops.first)
    #expect(hop.key == World.localC1Key)
    #expect(hop.displayName == "Claremont")
    #expect(try abs(#require(hop.latitude) - World.claremontPosition.latitude) < 1e-5)
    #expect(try abs(#require(hop.longitude) - World.claremontPosition.longitude) < 1e-5)
    #expect(hop.basis?.strongestKind == .advertRelayed)
    #expect(hop.basis?.minHops == 2)
  }

  @Test(arguments: Firmware.allCases)
  func `a tampered signature teaches nothing`(firmware: Firmware) {
    var raw = StockCompanionFrames.signedAdvert(name: "Claremont", key: World.localC1Signer, path: [0xB4])
    // Flip a byte of the signature (after header, path length, path, key and timestamp)
    raw[3 + 32 + 4] ^= 0xFF
    let forged = World.entry(Data(raw), firmware: firmware)
    let ledger = Self.ledger(after: [forged])
    #expect(ledger.node(for: .fullKey(World.localC1Key)) == nil)
    #expect(PacketNodeResolver.resolve(Self.viaC1(firmware), in: Self.index(ledger)).hops.first?.match == .unknown(Data([0xC1])))
    // The forged advert itself names nobody
    let sender = PacketNodeResolver.resolve(forged, in: Self.index(ledger)).sender
    #expect(sender?.isUnverified == true)
    #expect(sender?.isNamed == false)
  }

  @Test
  func `two observed nodes with the byte are ambiguous: heard directly, then type, fewer hops, recency`() throws {
    let t = World.receivedAt
    let direct = World.observation(World.key([0xC1, 0x01], fill: 1), name: "Direct", hops: 0, at: t.addingTimeInterval(-7200))
    let relayed = World.observation(World.key([0xC1, 0x02], fill: 1), name: "Relayed", hops: 1, at: t.addingTimeInterval(-60))
    let index = Self.index(World.ledger([direct, relayed]))
    let match = PacketNodeResolver.resolve(Self.viaC1(.stock), in: index).hops.first?.match
    guard case let .ambiguous(best, candidates, total) = match else {
      Issue.record("Expected ambiguous, got \(String(describing: match))")
      return
    }
    #expect(best.name == "Direct")
    #expect(candidates.map(\.name) == ["Direct", "Relayed"])
    #expect(total == 2)

    // Neither heard directly lately: the expected type, then fewer hops, then the more recent
    let older = World.observation(World.key([0xC1, 0x03], fill: 1), name: "Older", hops: 1, at: t.addingTimeInterval(-3 * 86400))
    let chat = World.observation(World.key([0xC1, 0x04], fill: 1), name: "Chat", type: 1, hops: 1, at: t.addingTimeInterval(-30))
    let far = World.observation(World.key([0xC1, 0x05], fill: 1), name: "Far", hops: 4, at: t.addingTimeInterval(-30))
    let ranked = PacketNodeResolver.resolve(Self.viaC1(.stock), in: Self.index(World.ledger([older, chat, far, relayed]))).hops.first?.match
    guard case let .ambiguous(_, list, _) = ranked else {
      Issue.record("Expected ambiguous")
      return
    }
    #expect(list.map(\.name) == ["Relayed", "Older", "Far", "Chat"])
  }

  @Test(arguments: Firmware.allCases)
  func `an anonymous key not in the ledger is unknown, kept only as a claim`(firmware: Firmware) {
    let login = World.entry(
      World.frame(.anonRequest, pathLength: 0x00, path: [], payload: [0xB4] + [UInt8](World.alexKey) + [UInt8](repeating: 0x42, count: 16)),
      firmware: firmware
    )
    let sender = PacketNodeResolver.resolve(login, in: Self.index(Self.ledger(after: []))).sender
    #expect(sender?.match == .unknown(Data(World.alexKey.prefix(3))))
    #expect(sender?.claimedKey == World.alexKey)
    #expect(sender?.displayName == "5A3301")
    #expect(sender?.hasPosition == false)
  }

  @Test(arguments: Firmware.allCases)
  func `a discover reply with an 8-byte key resolves to the observed node it starts`(firmware: Firmware) {
    let advert = World.signedClaremontAdvert(firmware: firmware, receivedAt: World.receivedAt.addingTimeInterval(-300))
    let reply = World.entry(
      World.frame(.control, route: .direct, pathLength: 0x00, path: [], payload: [0x92, 0x18, 9, 9, 9, 9] + [UInt8](World.localC1Key.prefix(8))),
      firmware: firmware
    )
    let sender = PacketNodeResolver.resolve(reply, in: Self.index(Self.ledger(after: [advert]))).sender
    #expect(sender?.key == World.localC1Key)
    #expect(sender?.displayName == "Claremont")
    #expect(sender?.hasPosition == true)
  }

  @Test
  func `a nickname names an observed node only for exactly its key`() {
    let nicknamed = ContactDTO.testContact(radioID: World.radioID, publicKey: World.mtBaldyKey, name: "Mt Baldy", nickname: "Baldy")
    // A contact whose key shares only the first byte with the observed node
    let lookalike = ContactDTO.testContact(radioID: World.radioID, publicKey: World.key([0xB4, 0x99], fill: 9), name: "Lookalike", nickname: "Not Baldy")
    let index = Self.index(World.ledger([World.mtBaldyObserved]), contacts: [nicknamed, lookalike])
    let hop = PacketNodeResolver.resolveHash(Data([0xB4]), role: .relay, at: World.receivedAt, in: index)
    #expect(hop.entry?.name == "Baldy")

    let withoutNickname = Self.index(World.ledger([World.mtBaldyObserved]), contacts: [lookalike])
    #expect(PacketNodeResolver.resolveHash(Data([0xB4]), role: .relay, at: World.receivedAt, in: withoutNickname).entry?.name == "Mt Baldy")
  }

  @Test(arguments: Firmware.allCases)
  func `a typed channel name matches the ledger only`(firmware: Firmware) {
    // Claremont Ops is saved, but not heard here
    let index = Self.index(World.ledger([World.mtBaldyObserved]), contacts: World.savedContacts + [World.claremontOps])
    #expect(PacketNodeResolver.resolve(World.c9(firmware), in: index).sender?.match == nil)

    let heard = Self.index(World.ledger([World.mtBaldyObserved, World.claremontOpsObserved]))
    #expect(PacketNodeResolver.resolve(World.c9(firmware), in: heard).sender?.key == World.claremontOpsKey)
  }

  // MARK: - Transmitter

  @Test(arguments: Firmware.allCases)
  func `the transmitter is a flood's newest hop, a trace's last reached hop, a 0-hop sender, none for a route ahead`(firmware: Firmware) {
    let index = World.index()
    #expect(PacketNodeResolver.resolve(World.c1(firmware), in: index).transmitter == .hop(index: 1, isReached: true))
    #expect(PacketNodeResolver.resolve(World.c8(firmware), in: index).transmitter == .sender(.peerHash))

    let trace = World.entry(
      World.frame(.trace, route: .direct, pathLength: 0x02, path: [0x18, 0x10], payload: [1, 2, 3, 4, 5, 6, 7, 8, 0x00, 0xB4, 0xC1, 0x9E]),
      firmware: firmware
    )
    #expect(PacketNodeResolver.resolve(trace, in: index).transmitter == .hop(index: 1, isReached: true))

    let ahead = World.entry(
      World.frame(.textMessage, route: .direct, pathLength: 0x81, path: [0xB4, 0x5D, 0x01], payload: World.peerPayload(destination: 0x5A, source: 0x9E)),
      firmware: firmware
    )
    #expect(PacketNodeResolver.resolve(ahead, in: index).transmitter == nil)

    let zeroHopAdvert = World.signedClaremontAdvert(path: [], firmware: firmware)
    let advertNodes = PacketNodeResolver.resolve(zeroHopAdvert, in: index)
    #expect(advertNodes.transmitter == .sender(.fullKey))
    #expect(advertNodes.transmitterNode?.key == World.localC1Key)
  }

  // MARK: - Flags and hints

  @Test
  func `the suspicious flag never changes a match`() {
    let farAway = World.observation(World.mtBaldyKey, name: "Mt Baldy", latitude: 47.6, longitude: -122.3)
    let near = World.index(observed: [World.mtBaldyObserved, World.claremontObserved])
    let far = World.index(observed: [farAway, World.claremontObserved])
    let nearNodes = PacketNodeResolver.resolve(World.c1(.stock), in: near)
    let farNodes = PacketNodeResolver.resolve(World.c1(.stock), in: far)
    #expect(farNodes.hops.map(\.key) == nearNodes.hops.map(\.key))
    #expect(farNodes.hops.map(\.displayName) == nearNodes.hops.map(\.displayName))
    // Seattle to Claremont is a claimed leg far too long; the observed link to the radio is fine
    #expect(farNodes.suspiciousLegs == [1])
    #expect(nearNodes.suspiciousLegs.isEmpty)
    #expect(!farNodes.hops[1].isSuspicious)

    // A transmitter heard from far away is flagged on its own link
    let farTransmitter = World.index(observed: [World.mtBaldyObserved, World.observation(World.claremontKey, name: "Claremont", latitude: 47.6, longitude: -122.3)])
    let flagged = PacketNodeResolver.resolve(World.c1(.stock), in: farTransmitter)
    #expect(flagged.hops[1].isSuspicious)
    #expect(flagged.hops[1].key == World.claremontKey)
  }

  @Test(arguments: Firmware.allCases)
  func `a node not heard within the active window gives a hint, not a resolution`(firmware: Firmware) {
    let stale = World.observation(World.claremontKey, name: "Claremont", at: World.receivedAt.addingTimeInterval(-12 * 86400))
    let hop = PacketNodeResolver.resolve(Self.viaC1(firmware), in: World.index(observed: [World.mtBaldyObserved, stale])).hops.first
    #expect(hop?.match == .unknown(Data([0xC1])))
    #expect(hop?.unobservedHint?.entry.publicKey == World.claremontKey)
    #expect(hop?.unobservedHint?.reason == .stale(lastObservedAt: World.receivedAt.addingTimeInterval(-12 * 86400)))
  }

  @Test(arguments: Firmware.allCases)
  func `an entry not stamped with a channel names only what it proves itself`(firmware: Firmware) {
    let index = World.index()
    let unstamped = PacketNodeResolver.resolve(Self.viaC1(firmware, channel: nil), in: index)
    #expect(!unstamped.isChannelRecorded)
    #expect(unstamped.hops.first?.match == .unknown(Data([0xC1])))
    #expect(unstamped.hops.first?.unobservedHint == nil)

    // A verified advert still names its sender, a decrypted message its contact
    let advert = World.signedClaremontAdvert(path: [0xB4], firmware: firmware)
    let unstampedAdvert = World.entry(Data(StockCompanionFrames.signedAdvert(name: "Claremont", key: World.localC1Signer, path: [0xB4])), firmware: firmware, channel: nil)
    #expect(PacketNodeResolver.resolve(unstampedAdvert, in: index).sender?.displayName == "Claremont")
    #expect(PacketNodeResolver.resolve(unstampedAdvert, in: index).hops.map(\.displayName) == ["B4"])
    #expect(PacketNodeResolver.resolve(advert, in: index).hops.map(\.displayName) == ["Mt Baldy"])

    let message = World.entry(
      World.frame(.textMessage, pathLength: 0x00, path: [], payload: World.peerPayload(destination: 0xAA, source: 0x5A)),
      firmware: firmware, decryptStatus: .success, decodedText: "hi", peerPublicKey: World.alexKey, channel: nil
    )
    #expect(PacketNodeResolver.resolve(message, in: index).sender?.displayName == "Alex")
    #expect(PacketNodeResolver.resolve(message, in: index).sender?.hasPosition == false)

    // Stamped with another channel: no ledger either
    let elsewhere = PacketNodeResolver.resolve(Self.viaC1(firmware, channel: World.otherChannel), in: index)
    #expect(elsewhere.isChannelRecorded)
    #expect(elsewhere.channelKey == World.otherChannel.key)
    #expect(elsewhere.hops.first?.match == .unknown(Data([0xC1])))
  }

  // MARK: - This radio is never the transmitter

  @Test(arguments: Firmware.allCases)
  func `a heard hop sharing this radio's first byte is unknown, never this radio`(firmware: Firmware) throws {
    // This radio starts AA; an unheard local relay AA passes a flood to us. A radio never
    // receives its own transmission, so the frame's transmitter is the hash, not "You".
    let flood = World.entry(World.frame(.groupText, pathLength: 0x02, path: [0xB4, 0xAA], payload: World.groupTextPayload), firmware: firmware)
    let packet = PacketNodeResolver.resolve(flood, in: World.index(observed: [World.mtBaldyObserved]))
    #expect(packet.transmitter == .hop(index: 1, isReached: true))
    #expect(packet.hops.last?.match == .unknown(Data([0xAA])))
    #expect(packet.hops.last?.displayName == "AA")

    // An earlier, claimed hop may be this radio (a companion repeating): it still can be
    let looped = World.entry(World.frame(.groupText, pathLength: 0x02, path: [0xAA, 0xB4], payload: World.groupTextPayload), firmware: firmware)
    #expect(PacketNodeResolver.resolve(looped, in: World.index(observed: [World.mtBaldyObserved])).hops.first?.match == .radio)

    // The sender of a 0-hop flood transmitted the frame too
    let zeroHop = World.entry(World.frame(.response, pathLength: 0x00, path: [], payload: World.peerPayload(destination: 0x5A, source: 0xAA)), firmware: firmware)
    let sender = try #require(PacketNodeResolver.resolve(zeroHop, in: World.index(observed: [World.mtBaldyObserved])).sender)
    #expect(sender.match == .unknown(Data([0xAA])))
  }

  @Test
  func `a heard hop shared by this radio and one observed node names the node, with no doubt`() {
    let local = World.observation(World.key([0xAA, 0x77], fill: 3), name: "Arrow Local", hops: 1)
    let flood = World.entry(World.frame(.groupText, pathLength: 0x01, path: [0xAA], payload: World.groupTextPayload), firmware: .stock)
    let hop = PacketNodeResolver.resolve(flood, in: World.index(observed: [World.mtBaldyObserved, local])).hops.first
    #expect(hop?.displayName == "Arrow Local")
    #expect(hop?.isUncertain == false)
  }

  // MARK: - A contact sharing this radio's first byte

  @Test(arguments: Firmware.allCases)
  func `a decrypted message on a byte this radio and the contact share names neither for certain`(firmware: Firmware) throws {
    // Arrow Peak's key starts AA, as this radio's does: [AA][AA] decrypted with Arrow Peak's key
    // is its message to us or an echo of ours to it
    let peer = World.key([0xAA, 0x77, 0x01], fill: 0x77)
    let message = World.entry(
      World.frame(.textMessage, pathLength: 0x01, path: [0xB4], payload: World.peerPayload(destination: 0xAA, source: 0xAA)),
      firmware: firmware, decryptStatus: .success, decodedText: "hi", peerPublicKey: peer
    )
    let packet = PacketNodeResolver.resolve(message, in: World.index())
    let sender = try #require(packet.sender)
    #expect(sender.role == .sender(.decryptedPeer))
    #expect(sender.isUncertain)
    #expect(sender.isRadio == false)
    guard case let .ambiguous(best, _, total)? = sender.match else {
      Issue.record("Expected ambiguous, got \(String(describing: sender.match))")
      return
    }
    #expect(best.publicKey == peer)
    #expect(total == 2)
    #expect(packet.recipient?.isUncertain == true)
    #expect(packet.recipient != .radio)
    // Nor is it evidence for the ledger
    #expect(ObservationExtractor.observations(from: message, selfKey: World.radioKey).isEmpty)
  }
}
