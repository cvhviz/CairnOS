import CryptoKit
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Node heard readings")
struct NodeHeardReadingsTests {
  private static let key = Data((0..<32).map { UInt8($0 + 0x40) })
  private static let otherKey = Data(repeating: 0x99, count: 32)

  private static func entry(
    type: PayloadType,
    route: RouteType = .flood,
    payload: [UInt8],
    path: [UInt8] = [],
    date: Date = .now,
    decryptedBy peer: Data? = nil
  ) -> RxLogEntryDTO {
    let parsed = ParsedRxLogData(
      snr: 6.25,
      rssi: -97,
      rawPayload: Data(payload + path + [0, 0]),
      routeType: route,
      payloadType: type,
      payloadVersion: 0,
      payloadTypeBits: type.rawValue,
      transportCode: nil,
      pathLength: UInt8(path.count),
      pathNodes: path,
      packetPayload: Data(payload)
    )
    return RxLogEntryDTO(
      radioID: UUID(),
      receivedAt: date,
      from: parsed,
      decryptStatus: peer == nil ? .notApplicable : .success,
      peerPublicKey: peer
    )
  }

  private typealias World = TrafficClaremontFixtures

  /// An advert the node with `signer` signed itself.
  private static func signedAdvert(
    _ signer: Curve25519.Signing.PrivateKey = World.claremontSigner,
    date: Date = .now
  ) -> RxLogEntryDTO {
    entry(
      type: .advert,
      payload: World.advertPayload(signer: signer, type: ContactType.repeater.rawValue, name: "Claremont"),
      date: date
    )
  }

  private static var signedKey: Data {
    World.claremontSigner.publicKey.rawRepresentation
  }

  @Test
  func `an advert the node signed matches; one only carrying its key does not`() {
    let advert = Self.signedAdvert()
    let other = Self.signedAdvert(World.pomonaHillSigner)
    #expect(NodeHeardSignal.isFromNode(advert, publicKey: Self.signedKey))
    #expect(!NodeHeardSignal.isFromNode(other, publicKey: Self.signedKey))
    // Anyone can put the node's key in an advert; signed by another key it is not the node's
    let forged = Self.entry(type: .advert, payload: World.forgedAdvertPayload(claimedKey: Self.signedKey, name: "Claremont"))
    #expect(!NodeHeardSignal.isFromNode(forged, publicKey: Self.signedKey))
    let unsigned = Self.entry(type: .advert, payload: Array(Self.key) + [UInt8](repeating: 0, count: 68))
    #expect(!NodeHeardSignal.isFromNode(unsigned, publicKey: Self.key))
  }

  @Test
  func `a direct message counts only when the node's key decrypted it from the node`() {
    // Payload: [recipient prefix][sender prefix]…
    let decrypted = Self.entry(type: .textMessage, payload: [0x01, 0x40, 0, 0], decryptedBy: Self.key)
    // The prefix alone is shared by too many nodes
    let undecrypted = Self.entry(type: .textMessage, payload: [0x01, 0x40, 0, 0])
    // Decrypted with the node's key, but sent by the other side: our own message to it
    let toTheNode = Self.entry(type: .textMessage, payload: [0x40, 0x01, 0, 0], decryptedBy: Self.key)
    let otherNode = Self.entry(type: .textMessage, payload: [0x01, 0x99, 0, 0], decryptedBy: Self.otherKey)
    #expect(NodeHeardSignal.isFromNode(decrypted, publicKey: Self.key))
    #expect(!NodeHeardSignal.isFromNode(undecrypted, publicKey: Self.key))
    #expect(!NodeHeardSignal.isFromNode(toTheNode, publicKey: Self.key))
    #expect(!NodeHeardSignal.isFromNode(otherNode, publicKey: Self.key))
  }

  @Test
  func `a direct message is not the node's when its first key byte is ours too`() {
    // The node's key and this radio's both start 0x40: [0x40][0x40] is its message to us or an
    // echo of ours to it, so it never counts as heard from the node
    let selfKey = Data([0x40] + [UInt8](repeating: 0x03, count: 31))
    let either = Self.entry(type: .textMessage, payload: [0x40, 0x40, 0, 0], decryptedBy: Self.key)
    #expect(!NodeHeardSignal.isFromNode(either, publicKey: Self.key, selfKey: selfKey))
    let fromNode = Self.entry(type: .textMessage, payload: [0x01, 0x40, 0, 0], decryptedBy: Self.key)
    #expect(NodeHeardSignal.isFromNode(fromNode, publicKey: Self.key, selfKey: Data([0x01] + [UInt8](repeating: 0x03, count: 31))))
  }

  @Test
  func `the newest matching packet wins`() {
    let older = Self.signedAdvert(date: .now.addingTimeInterval(-600))
    let newer = Self.signedAdvert(date: .now.addingTimeInterval(-60))
    let latest = NodeHeardSignal.latest(in: [older, newer], publicKey: Self.signedKey)
    #expect(latest?.id == newer.id)
    #expect(NodeHeardSignal.latest(in: [], publicKey: Self.signedKey) == nil)
  }

  @Test
  func `a flood path lists every relay, first to last`() {
    let relayed = Self.entry(type: .advert, payload: Array(Self.key), path: [0xA3, 0x7F])
    let direct = Self.entry(type: .advert, payload: Array(Self.key))
    let routed = Self.entry(type: .advert, route: .direct, payload: Array(Self.key), path: [0xA3])
    #expect(NodeHeardSignal.relayHashes(of: relayed) == [Data([0xA3]), Data([0x7F])])
    #expect(NodeHeardSignal.relayHashes(of: direct) == [])
    #expect(NodeHeardSignal.wasHeardDirectly(direct))
    #expect(NodeHeardSignal.relayHashes(of: routed) == nil)
    #expect(!NodeHeardSignal.wasHeardDirectly(routed))
  }

  @Test
  func `a zero-hop advert was heard directly, a finished direct message was not`() {
    // sendZeroHop: route DIRECT, empty path, straight from the sender.
    let zeroHop = Self.entry(type: .advert, route: .direct, payload: Array(Self.key))
    #expect(NodeHeardSignal.wasHeardDirectly(zeroHop))
    #expect(NodeHeardSignal.relayHashes(of: zeroHop) == [])
    #expect(NodeHeardSignal.heardPath(of: zeroHop) { _ in nil } == L10n.Contacts.Contacts.Route.direct)
    // A direct message arrives with an empty path once its stored route is used up.
    let routedMessage = Self.entry(type: .textMessage, route: .direct, payload: [0x01, 0x40, 0, 0])
    #expect(!NodeHeardSignal.wasHeardDirectly(routedMessage))
    #expect(NodeHeardSignal.relayHashes(of: routedMessage) == nil)
  }

  @Test
  func `the heard path names known relays and shortens a long one`() {
    let names = [Data([0xA3]): "Hilltop", Data([0x12]): "Ridge"]
    let name = { (hash: Data) in names[hash] }
    let relayed = Self.entry(type: .advert, payload: Array(Self.key), path: [0xA3, 0x7F, 0x12])
    #expect(NodeHeardSignal.heardPath(of: relayed, name: name) == "Hilltop \u{2192} 7F \u{2192} Ridge")
    let long = Self.entry(type: .advert, payload: Array(Self.key), path: [0xA3, 0x7F, 0x55, 0x12])
    #expect(NodeHeardSignal.heardPath(of: long, name: name)
      == "Hilltop \u{2192} \u{2026} \u{2192} Ridge (\(NodeRouteFormat.hopCount(4)))")
    let direct = Self.entry(type: .advert, payload: Array(Self.key))
    #expect(NodeHeardSignal.heardPath(of: direct, name: name) == L10n.Contacts.Contacts.Route.direct)
    let routed = Self.entry(type: .advert, route: .direct, payload: Array(Self.key), path: [0xA3])
    #expect(NodeHeardSignal.heardPath(of: routed, name: name) == nil)
  }

  @Test
  func `the heard path names relays only from what this radio heard on the channel`() {
    // Kona Hill (7F…) is a saved contact in Hawaii, never heard here; Mt Baldy was heard. The
    // advert came through an unknown local relay 7F, then Mt Baldy: 7F stays a hash.
    let hawaii = TrafficHawaiiTests.hawaiiNodes()
    let index = World.index(observed: [World.mtBaldyObserved], contacts: hawaii.contacts, discovered: hawaii.discovered)
    let advert = World.entry(
      World.frame(
        .advert,
        pathLength: 0x02,
        path: [0x7F, World.mtBaldyKey[0]],
        payload: World.advertPayload(signer: World.claremontSigner, type: ContactType.repeater.rawValue, name: "Claremont")
      ),
      firmware: .stock
    )
    let path = NodeHeardSignal.heardPath(of: advert, in: index)
    #expect(path == "7F \u{2192} Mt Baldy")
    #expect(path?.contains("Kona Hill") == false)
  }

  @Test @MainActor
  func `stored readings say how old they are`() {
    let now = Date.now
    let caption = StoredReadingFormat.asOf(now.addingTimeInterval(-3 * 3600), now: now)
    #expect(caption == L10n.Contacts.Contacts.Detail.asOf(
      RelativeTimestampText.format(date: now.addingTimeInterval(-3 * 3600), relativeTo: now)
    ))
  }

  @Test
  func `the public key shortens to its ends`() {
    #expect(ContactShareContent.shortPublicKeyHex(Self.key) == "40414243\u{2026}5C5D5E5F")
    #expect(ContactShareContent.shortPublicKeyHex(Data([0xAB, 0xCD])) == "ABCD")
  }

  @Test
  func `battery curve falls back to Li-ion and keeps a complete custom curve`() {
    #expect(NodeStatusViewModel.batteryCurve(presetName: nil, customString: nil).preset == .liIon)
    let custom = (0..<11).map { String(3000 + $0 * 100) }.joined(separator: ",")
    let curve = NodeStatusViewModel.batteryCurve(presetName: OCVPreset.custom.rawValue, customString: custom)
    #expect(curve.preset == .custom)
    #expect(curve.values.count == 11)
  }
}
