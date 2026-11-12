@testable import CairnServices
import CoreLocation
import Foundation
import MeshCore
import Testing

@Suite("PacketNodeResolver")
struct PacketNodeResolverTests {
  private typealias World = ClaremontStockFixtures
  typealias Firmware = ClaremontStockFixtures.Firmware

  /// The entry's nodes, checked to be the same whichever firmware delivered it.
  private func resolve(
    _ scenario: (Firmware) -> RxLogEntryDTO,
    _ firmware: Firmware,
    in index: PacketNodeIndex = World.index()
  ) -> PacketNodes {
    let nodes = PacketNodeResolver.resolve(scenario(firmware), in: index)
    let other: Firmware = firmware == .stock ? .cairn : .stock
    #expect(PacketNodeResolver.resolve(scenario(other), in: index) == nodes)
    return nodes
  }

  /// An observation of `key` on the world's channel, an hour before the packets.
  private func node(
    _ key: Data,
    type: UInt8 = ContactType.repeater.rawValue,
    name: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    hops: Int = 2,
    at date: Date = World.receivedAt.addingTimeInterval(-3600)
  ) -> NodeObservation {
    World.observation(key, name: name, type: type, latitude: latitude, longitude: longitude, hops: hops, at: date)
  }

  /// An index of what `observations` observed and nothing else.
  private func index(_ observations: [NodeObservation], anchor: (latitude: Double, longitude: Double)? = World.radio) -> PacketNodeIndex {
    World.index(observed: observations, contacts: [], discovered: [], anchor: anchor)
  }

  private func resolveHash(_ hash: [UInt8], role: PacketNodeResolver.Role = .relay, radioNeighbour: Bool = false, in index: PacketNodeIndex) -> PacketNodeMatch {
    PacketNodeResolver.resolveHash(Data(hash), role: role, isRadioNeighbour: radioNeighbour, at: World.receivedAt, in: index)
  }

  // MARK: - Claremont Scenarios

  @Test(arguments: Firmware.allCases)
  func `C1 an observed hop with no position is still named, and listed off the map`(firmware: Firmware) {
    let unplaced = World.observation(World.claremontKey, name: "Claremont")
    let nodes = resolve(World.c1, firmware, in: World.index(observed: [unplaced, World.mtBaldyObserved]))

    #expect(nodes.hops.map(\.displayName) == ["Mt Baldy", "Claremont"])
    #expect(nodes.hops[0].key == World.mtBaldyKey)
    #expect(nodes.hops[0].hasPosition)
    #expect(nodes.hops[1].match?.entry?.publicKey == World.claremontKey)
    #expect(nodes.hops[1].match?.isUncertain == false)
    #expect(!nodes.hops[1].hasPosition)
    #expect(nodes.hops.allSatisfy { $0.isReached && $0.isObserved })
    #expect(nodes.sender == nil)
    #expect(!nodes.isRouteAhead)
    #expect(nodes.named.map(\.key) == [World.mtBaldyKey, World.claremontKey])
    #expect(nodes.offMap.map(\.displayName) == ["Claremont"])
    #expect(nodes.transmitter == .hop(index: 1, isReached: true))
  }

  @Test(arguments: Firmware.allCases)
  func `C1 before anything was heard every hop is unknown by its hash`(firmware: Firmware) {
    let nodes = resolve(World.c1, firmware, in: World.index(observed: []))
    #expect(nodes.hops.map(\.displayName) == ["B45D01", "C1A23E"])
    #expect(nodes.hops.allSatisfy { !$0.isNamed })
    // The saved contacts sharing the hashes are hints, never names
    #expect(nodes.hops.map(\.unobservedHint?.entry.name) == ["Mt Baldy", "Claremont"])
    #expect(nodes.hops.map(\.unobservedHint?.reason) == [.notHeard, .notHeard])
    #expect(nodes.named.isEmpty)
  }

  @Test(arguments: Firmware.allCases)
  func `C2 a relay beyond an unknown hop is still named`(firmware: Firmware) {
    let nodes = resolve({ World.c2($0) }, firmware)

    #expect(nodes.hops.map(\.displayName) == ["Claremont", "7F7F7F", "Mt Baldy"])
    #expect(nodes.hops[0].key == World.claremontKey)
    #expect(nodes.hops[0].hasPosition)
    #expect(nodes.hops[1].match == .unknown(Data(World.unknownHop)))
    #expect(!nodes.hops[1].isNamed)
    #expect(nodes.hops[1].unobservedHint == nil)
    #expect(nodes.named.map(\.key) == [World.claremontKey, World.mtBaldyKey])
    #expect(nodes.offMap.isEmpty)
  }

  @Test(arguments: Firmware.allCases)
  func `C3 a 1-byte hash two observed repeaters share is ambiguous, the one heard directly first`(firmware: Firmware) throws {
    let index = World.index(observed: World.observedWorld + [World.pomonaHillObserved])
    let nodes = resolve(World.c3, firmware, in: index)
    let hop = try #require(nodes.hops.first)

    guard case let .ambiguous(best, candidates, total) = hop.match else {
      Issue.record("Expected an ambiguous 1-byte hop, got \(String(describing: hop.match))")
      return
    }
    #expect(best.publicKey == World.pomonaHillKey)
    #expect(total == 2)
    #expect(candidates.map(\.publicKey) == [World.pomonaHillKey, World.claremontKey])
    #expect(hop.displayName == "Pomona Hill?")
    #expect(hop.isUncertain)
    #expect(nodes.named.map(\.key) == [World.pomonaHillKey])
  }

  @Test(arguments: Firmware.allCases)
  func `C3b a 1-byte hash only one observed node has resolves, a contact sharing it is no candidate`(firmware: Firmware) {
    // Pomona Hill is only a discovered row: never heard on this channel
    let nodes = resolve(World.c3, firmware)
    #expect(nodes.hops.first?.key == World.claremontKey)
    #expect(nodes.hops.first?.displayName == "Claremont")
    #expect(nodes.hops.first?.basis?.minHops == 2)
    #expect(nodes.hops.first?.basis?.strongestKind == .advertRelayed)
  }

  @Test(arguments: Firmware.allCases)
  func `C4 an observed client-repeat companion that is the only match is a relay`(firmware: Firmware) {
    let companion = World.observation(World.claremontKey, name: "Claremont", type: ContactType.chat.rawValue)
    let nodes = resolve(World.c4, firmware, in: World.index(observed: [companion, World.mtBaldyObserved]))
    #expect(nodes.hops.first?.key == World.claremontKey)
    #expect(nodes.hops.first?.match?.isUncertain == false)
    #expect(nodes.hops.first?.displayName == "Claremont")
  }

  @Test(arguments: Firmware.allCases)
  func `C5 an advert whose signature fails names no sender and places nothing`(firmware: Firmware) throws {
    let nodes = resolve(World.c5, firmware, in: World.index(observed: [World.mtBaldyObserved]))
    let sender = try #require(nodes.sender)

    #expect(sender.role == .sender(.fullKey))
    #expect(sender.isUnverified)
    #expect(sender.match == .unknown(Data([0xC1, 0xA2, 0x3E])))
    #expect(sender.displayName == "C1A23E")
    #expect(!sender.hasPosition)
    #expect(nodes.hops.map(\.displayName) == ["7F7F7F"])
    #expect(nodes.named.isEmpty)
  }

  @Test(arguments: Firmware.allCases)
  func `C5b a verified flood advert names its sender through an unknown hop, placed by the advert`(firmware: Firmware) throws {
    let nodes = resolve({ World.signedClaremontAdvert(path: [0x7F], firmware: $0) }, firmware, in: World.index(observed: []))
    let sender = try #require(nodes.sender)

    #expect(sender.role == .sender(.fullKey))
    #expect(!sender.isUnverified)
    #expect(sender.key == World.localC1Key)
    #expect(sender.displayName == "Claremont")
    #expect(sender.nodeTypeRaw == ContactType.repeater.rawValue)
    #expect(try abs(#require(sender.latitude) - World.claremontPosition.latitude) < 1e-5)
    #expect(sender.isObserved)
    #expect(nodes.hops.map(\.displayName) == ["7F"])
    #expect(nodes.named.map(\.key) == [World.localC1Key])
    #expect(nodes.transmitter == .hop(index: 0, isReached: true))
  }

  @Test(arguments: Firmware.allCases)
  func `C8 a zero-hop request between observed nodes names its sender, the transmitter`(firmware: Firmware) throws {
    let nodes = resolve(World.c8, firmware)
    let sender = try #require(nodes.sender)

    #expect(sender.role == .sender(.peerHash))
    #expect(sender.key == World.alexKey)
    #expect(sender.displayName == "Alex")
    #expect(!sender.hasPosition)
    #expect(nodes.offMap.map(\.key) == [World.alexKey])
    #expect(nodes.recipient?.entry?.publicKey == World.mtBaldyKey)
    #expect(nodes.transmitter == .sender(.peerHash))
    #expect(nodes.transmitterNode == sender)
  }

  @Test(arguments: Firmware.allCases)
  func `C9 a channel sender is named by a unique advertised name, always uncertain`(firmware: Firmware) throws {
    let nodes = resolve({ World.c9($0) }, firmware)
    let sender = try #require(nodes.sender)

    #expect(sender.role == .sender(.channelName))
    #expect(sender.key == World.claremontOpsKey)
    #expect(sender.displayName == "Claremont Ops")
    #expect(sender.isUncertain)
    #expect(sender.hasPosition)
    #expect(nodes.hops.map(\.displayName) == ["Mt Baldy"])
    #expect(nodes.named.count == 2)
  }

  @Test(arguments: Firmware.allCases)
  func `C9b a channel name no observed node advertised still names the sender, off the map`(firmware: Firmware) throws {
    // Claremont Ops is a saved contact, never heard on this channel
    let index = World.index(observed: [World.mtBaldyObserved], contacts: World.savedContacts + [World.claremontOps])
    let nodes = resolve({ World.c9($0) }, firmware, in: index)
    let sender = try #require(nodes.sender)

    #expect(sender.match == nil)
    #expect(sender.channelName == "Claremont Ops")
    #expect(sender.isNamed)
    #expect(sender.isUncertain)
    #expect(nodes.offMap.map(\.displayName) == ["Claremont Ops"])
  }

  @Test(arguments: Firmware.allCases)
  func `a channel name two observed nodes share is named but not keyed`(firmware: Firmware) {
    let twin = World.observation(World.key([0x0D], fill: 0x01), name: "Claremont Ops", type: ContactType.chat.rawValue)
    let sender = resolve({ World.c9($0) }, firmware, in: World.index(observed: World.observedWorld + [twin])).sender
    #expect(sender?.match == nil)
    #expect(sender?.displayName == "Claremont Ops")
  }

  @Test(arguments: Firmware.allCases)
  func `a channel name matches what a node advertised, never a nickname`(firmware: Firmware) {
    let nicknamed = ContactDTO.testContact(
      radioID: World.radioID,
      publicKey: World.mtBaldyKey,
      name: "Mt Baldy",
      nickname: "Claremont Ops"
    )
    let index = World.index(observed: [World.mtBaldyObserved], contacts: [nicknamed])
    let sender = resolve({ World.c9($0) }, firmware, in: index).sender
    #expect(sender?.match == nil)
    // The nickname still names the observed node it belongs to
    #expect(resolve({ World.c9($0) }, firmware, in: index).hops.map(\.displayName) == ["Claremont Ops"])
  }

  @Test(arguments: Firmware.allCases)
  func `this radio's own channel message reads as this radio`(firmware: Firmware) {
    let sender = resolve({ World.c9($0, text: "Base: test") }, firmware).sender
    #expect(sender?.match == .radio)
    #expect(sender?.isNamed == false)
    #expect(sender?.displayName == nil)
  }

  // MARK: - Hash Rules

  @Test
  func `a sole observed candidate resolves at any hash size and wherever it is`() {
    let far = World.key([0x3A, 0x7F, 0x21], fill: 0x10)
    let index = index([node(far, name: "Tampa", latitude: 27.95, longitude: -82.46)])
    #expect(resolveHash([0x3A, 0x7F, 0x21], in: index).entry?.name == "Tampa")
    #expect(resolveHash([0x3A], in: index).entry?.name == "Tampa")
  }

  @Test
  func `distance never removes a candidate`() {
    let near = World.key([0x3A, 0x01], fill: 0x10)
    let far = World.key([0x3A, 0x02], fill: 0x10)
    let index = index([
      node(near, name: "Near", latitude: 34.1, longitude: -117.7),
      node(far, name: "Far", latitude: 27.95, longitude: -82.46),
    ])
    let match = resolveHash([0x3A], in: index)
    guard case let .ambiguous(_, candidates, total) = match else {
      Issue.record("Expected an ambiguous match, got \(match)")
      return
    }
    #expect(total == 2)
    #expect(Set(candidates.compactMap(\.name)) == ["Near", "Far"])
  }

  @Test
  func `a node of unknown type or a companion is the relay when it is the only match`() {
    let untyped = World.key([0x44, 0x01], fill: 0x10)
    let companion = World.key([0x55, 0x01], fill: 0x10)
    let index = index([node(untyped, type: 0, name: "Untyped"), node(companion, type: 1, name: "Companion")])

    #expect(resolveHash([0x44, 0x01], in: index).entry?.name == "Untyped")
    #expect(resolveHash([0x55], in: index).entry?.name == "Companion")
  }

  @Test
  func `role ranks a repeater first for a hop and a companion first for a sender, keeping both`() {
    let repeater = World.key([0x66, 0x01], fill: 0x10)
    let companion = World.key([0x66, 0x02], fill: 0x10)
    let index = index([node(repeater, name: "Repeater"), node(companion, type: 1, name: "Companion")])

    let relay = resolveHash([0x66], in: index)
    #expect(relay.entry?.name == "Repeater")
    #expect(relay.isUncertain)
    let sender = resolveHash([0x66], role: .originator(.textMessage), in: index)
    #expect(sender.entry?.name == "Companion")
    #expect(sender.isUncertain)
  }

  @Test
  func `ranking: heard directly for the hop this radio heard, then type, then fewer hops, then recency`() {
    let t = World.receivedAt
    let direct = World.key([0x3C, 0x01], fill: 0x10)
    let near = World.key([0x3C, 0x02], fill: 0x10)
    let recent = World.key([0x3C, 0x03], fill: 0x10)
    let chat = World.key([0x3C, 0x04], fill: 0x10)
    let index = index([
      node(direct, name: "Direct", hops: 0, at: t.addingTimeInterval(-7200)),
      node(near, name: "Near", hops: 1, at: t.addingTimeInterval(-7200)),
      node(recent, name: "Recent", hops: 3, at: t.addingTimeInterval(-60)),
      node(chat, type: 1, name: "Chat", hops: 0, at: t.addingTimeInterval(-30)),
    ])

    guard case let .ambiguous(_, heard, total) = resolveHash([0x3C], radioNeighbour: true, in: index) else {
      Issue.record("Expected an ambiguous match")
      return
    }
    #expect(total == 4)
    // Heard directly lately ranks first for the hop this radio heard, the expected type next
    #expect(heard.compactMap(\.name) == ["Direct", "Chat", "Near", "Recent"])

    guard case let .ambiguous(_, relayed, _) = resolveHash([0x3C], in: index) else {
      Issue.record("Expected an ambiguous match")
      return
    }
    // Further along the path: type, then fewer hops, then recency
    #expect(relayed.compactMap(\.name) == ["Direct", "Near", "Recent", "Chat"])
  }

  @Test
  func `this radio's own hash is this radio only when nothing else has it, ranked last`() {
    #expect(resolveHash([0xAA], in: index([])) == .radio)

    let relay = World.key([0xAA, 0x77], fill: 0x10)
    let match = resolveHash([0xAA], in: index([node(relay, name: "Shared")]))
    guard case let .ambiguous(best, candidates, total) = match else {
      Issue.record("Expected an ambiguous match, got \(match)")
      return
    }
    #expect(best.name == "Shared")
    #expect(candidates.map(\.name) == ["Shared"])
    #expect(total == 2)
  }

  @Test
  func `an ambiguous hash lists at most four candidates`() {
    let crowd = (1...6).map { World.key([0x3C, UInt8($0)], fill: 0x10) }
    let index = index(crowd.enumerated().map { offset, key in node(key, name: "Crowd \(offset)", hops: offset + 1) })
    guard case let .ambiguous(best, candidates, total) = resolveHash([0x3C], in: index) else {
      Issue.record("Expected an ambiguous 1-byte hash")
      return
    }
    #expect(total == 6)
    #expect(candidates.count == PacketNodeResolver.maximumListedCandidates)
    #expect(candidates.first == best)
    #expect(best.name == "Crowd 0")
  }

  @Test
  func `each hop of a path is judged on its own`() {
    let nearBase = World.key([0x3D, 0x01], fill: 0x10)
    let nearFar = World.key([0x3D, 0x02], fill: 0x10)
    let farHop = World.key([0x5E, 0x01], fill: 0x10)
    let index = index([
      node(nearBase, name: "Near Base", latitude: 34.1, longitude: -117.65, hops: 1),
      node(nearFar, name: "Near Far", latitude: 35.9, longitude: -117.1, hops: 4),
      node(farHop, name: "Far Hop", latitude: 35.8, longitude: -117.2),
    ])
    let matches = PacketNodeResolver.resolvePath([Data([0x3D]), Data([0x5E])], newestFirst: true, at: World.receivedAt, in: index)
    // No position walks from one hop to the next: fewer hops ranks first
    #expect(matches.map(\.entry?.name) == ["Near Base", "Far Hop"])
    #expect(matches[0].isUncertain)
  }

  @Test
  func `a node not observed within the active window is no candidate, only a hint`() {
    let stale = World.key([0x4B, 0x01], fill: 0x10)
    let index = index([node(stale, name: "Old", at: World.receivedAt.addingTimeInterval(-10 * 24 * 3600))])
    #expect(resolveHash([0x4B], in: index) == .unknown(Data([0x4B])))
    #expect(index.unobservedSharers(of: Data([0x4B]), at: World.receivedAt).map(\.reason)
      == [.stale(lastObservedAt: World.receivedAt.addingTimeInterval(-10 * 24 * 3600))])
    // A packet from back then still resolves against it
    let then = PacketNodeResolver.resolveHash(Data([0x4B]), role: .relay, at: World.receivedAt.addingTimeInterval(-9 * 24 * 3600), in: index)
    #expect(then.entry?.name == "Old")
  }

  // MARK: - Packets

  @Test(arguments: Firmware.allCases)
  func `a direct packet's route ahead resolves, unreached, with no transmitter`(firmware: Firmware) {
    let scenario: (Firmware) -> RxLogEntryDTO = {
      World.entry(
        World.frame(.textMessage, route: .direct, pathLength: 0x82, path: [0xC1, 0xA2, 0x3E, 0xB4, 0x5D, 0x01],
                    payload: World.peerPayload(destination: 0x5A, source: 0xB4)),
        firmware: $0
      )
    }
    let nodes = resolve(scenario, firmware)
    #expect(nodes.isRouteAhead)
    #expect(nodes.hops.map(\.displayName) == ["Claremont", "Mt Baldy"])
    #expect(nodes.hops.allSatisfy { !$0.isReached })
    #expect(nodes.recipient?.entry?.publicKey == World.alexKey)
    #expect(nodes.transmitter == nil)
  }

  @Test(arguments: Firmware.allCases)
  func `a trace names the targets it reached and its last reached hop transmitted`(firmware: Firmware) {
    // tag(4) auth(4) flags(1: 1-byte hashes) then targets; one SNR in the path so far.
    let payload: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 0x00, 0xB4, 0xC1]
    let scenario: (Firmware) -> RxLogEntryDTO = {
      World.entry(World.frame(.trace, route: .direct, pathLength: 0x01, path: [0x18], payload: payload), firmware: $0)
    }
    let nodes = resolve(scenario, firmware)
    #expect(nodes.hops.count == 2)
    #expect(nodes.hops[0].displayName == "Mt Baldy")
    #expect(nodes.hops[0].isReached)
    #expect(nodes.hops[1].match == nil)
    #expect(nodes.hops[1].displayName == "C1")
    #expect(!nodes.hops[1].isNamed)
    #expect(!nodes.isRouteAhead)
    #expect(nodes.transmitter == .hop(index: 0, isReached: true))
  }

  @Test(arguments: Firmware.allCases)
  func `a decrypted direct message names its contact and this radio`(firmware: Firmware) {
    let toRadio: (Firmware) -> RxLogEntryDTO = {
      World.entry(
        World.frame(.textMessage, pathLength: 0x00, path: [], payload: World.peerPayload(destination: 0xAA, source: 0x5A)),
        firmware: $0,
        decryptStatus: .success,
        decodedText: "hi",
        peerPublicKey: World.alexKey
      )
    }
    let received = resolve(toRadio, firmware)
    #expect(received.sender?.role == .sender(.decryptedPeer))
    #expect(received.sender?.key == World.alexKey)
    #expect(received.recipient == .radio)

    let fromRadio: (Firmware) -> RxLogEntryDTO = {
      World.entry(
        World.frame(.textMessage, pathLength: 0x81, path: [0xB4, 0x5D, 0x01], payload: World.peerPayload(destination: 0x5A, source: 0xAA)),
        firmware: $0,
        decryptStatus: .success,
        decodedText: "hi",
        peerPublicKey: World.alexKey
      )
    }
    let sent = resolve(fromRadio, firmware)
    #expect(sent.sender?.match == .radio)
    #expect(sent.recipient?.entry?.publicKey == World.alexKey)
    #expect(sent.named.map(\.key) == [World.mtBaldyKey])

    // A contact never heard here is still the proven sender: named by its nickname, never placed
    let unheard = resolve(toRadio, firmware, in: World.index(observed: [], contacts: [World.alex(latitude: 34.1, longitude: -117.6)]))
    #expect(unheard.sender?.displayName == "Alex")
    #expect(unheard.sender?.hasPosition == false)
    #expect(unheard.sender?.isObserved == false)
  }

  @Test(arguments: Firmware.allCases)
  func `an anonymous request's key names its sender only when observed`(firmware: Firmware) {
    let login: (Firmware) -> RxLogEntryDTO = {
      World.entry(
        World.frame(.anonRequest, pathLength: 0x00, path: [], payload: [0xB4] + [UInt8](World.alexKey) + [UInt8](repeating: 0x42, count: 16)),
        firmware: $0
      )
    }
    let request = resolve(login, firmware)
    #expect(request.sender?.role == .sender(.fullKey))
    #expect(request.sender?.displayName == "Alex")
    #expect(request.sender?.claimedKey == nil)
    #expect(request.recipient?.entry?.publicKey == World.mtBaldyKey)

    let unheard = resolve(login, firmware, in: World.index(observed: [World.mtBaldyObserved])).sender
    #expect(unheard?.match == .unknown(Data(World.alexKey.prefix(3))))
    #expect(unheard?.claimedKey == World.alexKey)
    #expect(unheard?.isNamed == false)
  }

  @Test(arguments: Firmware.allCases)
  func `a discover reply's key names its sender, which transmitted the frame`(firmware: Firmware) {
    let answer: (Firmware) -> RxLogEntryDTO = {
      World.entry(
        World.frame(.control, route: .direct, pathLength: 0x00, path: [],
                    payload: [0x92, 0x18, 9, 9, 9, 9] + [UInt8](World.claremontKey.prefix(8))),
        firmware: $0
      )
    }
    let discovered = resolve(answer, firmware)
    #expect(discovered.sender?.role == .sender(.keyPrefix))
    #expect(discovered.sender?.key == World.claremontKey)
    #expect(discovered.transmitter == .sender(.keyPrefix))

    // A prefix no observed node has is the node itself, typed from the answer
    let strangerKey = World.key([0xEE, 0x01], fill: 0x77)
    let stranger: (Firmware) -> RxLogEntryDTO = {
      World.entry(World.frame(.control, route: .direct, pathLength: 0x00, path: [], payload: [0x92, 0x18, 9, 9, 9, 9] + [UInt8](strangerKey.prefix(8))), firmware: $0)
    }
    let unknown = resolve(stranger, firmware).sender
    #expect(unknown?.key == Data(strangerKey.prefix(8)))
    #expect(unknown?.nodeTypeRaw == ContactType.repeater.rawValue)
    #expect(unknown?.displayName == "EE0177")
    #expect(unknown?.hasPosition == false)
  }

  @Test(arguments: Firmware.allCases)
  func `this radio's own verified advert names this radio, not a node`(firmware: Firmware) {
    let index = World.index(selfKey: World.localC1Key)
    let nodes = resolve({ World.signedClaremontAdvert(path: [0xB4], firmware: $0) }, firmware, in: index)
    #expect(nodes.sender?.match == .radio)
    #expect(nodes.named.compactMap(\.key) == [World.mtBaldyKey])
  }

  @Test(arguments: Firmware.allCases)
  func `packets that name no sender have none`(firmware: Firmware) {
    let ack: (Firmware) -> RxLogEntryDTO = {
      World.entry(World.frame(.ack, pathLength: 0x81, path: [0xB4, 0x5D, 0x01], payload: [1, 2, 3, 4]), firmware: $0)
    }
    let nodes = resolve(ack, firmware)
    #expect(nodes.sender == nil)
    #expect(nodes.recipient == nil)
    #expect(nodes.hops.map(\.displayName) == ["Mt Baldy"])
  }

  @Test(arguments: Firmware.allCases)
  func `a path whose bytes don't match its length has no hops`(firmware: Firmware) {
    // 0x82 promises 6 bytes; the parser takes them, so cut the stored path short instead.
    let entry = World.c1(firmware)
    var parsed = ParsedRxLogData(
      snr: entry.snr, rssi: entry.rssi, rawPayload: entry.rawPayload, routeType: entry.routeType,
      payloadType: entry.payloadType, payloadVersion: entry.payloadVersion, payloadTypeBits: entry.payloadTypeBits,
      transportCode: nil, pathLength: entry.pathLength, pathNodes: [0xB4, 0x5D], packetPayload: entry.packetPayload
    )
    parsed.channel = World.channel
    let bad = RxLogEntryDTO(radioID: entry.radioID, receivedAt: entry.receivedAt, from: parsed)
    #expect(PacketNodeResolver.resolve(bad, in: World.index()).hops.isEmpty)
  }
}
