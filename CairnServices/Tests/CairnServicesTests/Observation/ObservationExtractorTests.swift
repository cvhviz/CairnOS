import CryptoKit
import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

@Suite("Observation extractor")
struct ObservationExtractorTests {
  private typealias Frames = StockCompanionFrames

  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let claremont = Frames.signingKey(seed: 0x11)
  private static var claremontKey: Data {
    claremont.publicKey.rawRepresentation
  }

  /// The observations the live 0x88 frame for `raw` gives, stamped with `channel`.
  private static func observations(
    _ raw: [UInt8],
    snr: Double = 6.5,
    rssi: Int8 = -90,
    channel: RadioChannelConfig? = Frames.channel,
    selfKey: Data = Frames.selfKey
  ) -> [NodeObservation] {
    let parsed = Frames.parsed(raw, snr: snr, rssi: rssi, channel: channel)
    return ObservationExtractor.observations(from: .rxLogData(parsed), channel: Frames.channel, at: t0, selfKey: selfKey)
  }

  private static func pushObservations(
    _ event: MeshEvent,
    channel: RadioChannelConfig? = Frames.channel,
    isOwnTrace: (UInt32) -> Bool = { _ in false }
  ) -> [NodeObservation] {
    ObservationExtractor.observations(from: event, channel: channel, at: t0, selfKey: Frames.selfKey, isOwnTrace: isOwnTrace)
  }

  // MARK: - Adverts

  @Test
  func `a signed 0-hop advert is observed directly with the frame's signal, position and type`() throws {
    let raw = Frames.signedAdvert(name: "Claremont", key: Self.claremont, lat: 34.0967, lon: -117.7198)
    let observations = Self.observations(raw, snr: 7.25, rssi: -88)

    let observation = try #require(observations.first)
    #expect(observations.count == 1)
    #expect(observation.identity == .fullKey(Self.claremontKey))
    #expect(observation.kind == .advertDirect)
    #expect(observation.channelKey == Frames.channel.key)
    #expect(observation.at == Self.t0)
    #expect(observation.hops == 0)
    #expect(observation.snr == 7.25)
    #expect(observation.rssi == -88)
    #expect(observation.name == "Claremont")
    #expect(observation.nodeTypeRaw == Frames.advertTypeRepeater)
    #expect(abs(try #require(observation.latitude) - 34.0967) < 1e-6)
    #expect(abs(try #require(observation.longitude) + 117.7198) < 1e-6)
  }

  @Test
  func `a zero-hop direct advert is observed directly too`() throws {
    let raw = Frames.signedAdvert(name: "Claremont", key: Self.claremont, route: Frames.routeDirect)
    let observation = try #require(Self.observations(raw).first)
    #expect(observation.kind == .advertDirect)
    #expect(observation.hops == 0)
    #expect(observation.snr == 6.5)
  }

  @Test
  func `a signed advert relayed over two hops is observed with its hop count and no signal`() throws {
    let raw = Frames.signedAdvert(name: "Claremont", key: Self.claremont, lat: 34.0967, lon: -117.7198, path: [0x3A, 0x7F])
    let observations = Self.observations(raw)

    let observation = try #require(observations.first)
    #expect(observations.count == 1)
    #expect(observation.kind == .advertRelayed)
    #expect(observation.hops == 2)
    #expect(observation.snr == nil)
    #expect(observation.rssi == nil)
    #expect(observation.latitude != nil)
  }

  @Test
  func `a forged advert teaches nothing`() {
    let raw = Frames.forgedAdvert(name: "Kona Hill", claimedKey: Self.claremontKey, lat: 19.6, lon: -155.9)
    #expect(Self.observations(raw).isEmpty)

    let fields = RxPacketFields(Frames.parsed(raw, channel: Frames.channel))
    #expect(ObservationExtractor.advertCheck(in: fields) == .unverified(publicKey: Self.claremontKey))
  }

  @Test
  func `an advert whose payload is shorter than the radio accepts is not checked`() {
    let raw = Frames.packet(payloadType: 0x04, route: Frames.routeFlood, payload: Array(Self.claremontKey) + [0, 0, 0, 0])
    let fields = RxPacketFields(Frames.parsed(raw, channel: Frames.channel))
    #expect(ObservationExtractor.advertCheck(in: fields) == nil)
    #expect(Self.observations(raw).isEmpty)
  }

  // MARK: - Discover replies

  @Test
  func `discover replies with full and prefix keys are observed 0 hops away`() throws {
    let key = Array(Self.claremontKey)
    let full = try #require(Self.observations(Frames.discoverReplyPacket(key: key), snr: 5.5, rssi: -95).first)
    #expect(full.kind == .discoverReply)
    #expect(full.identity == .fullKey(Self.claremontKey))
    #expect(full.hops == 0)
    #expect(full.snr == 5.5)
    #expect(full.rssi == -95)
    #expect(full.nodeTypeRaw == 2)

    let prefix = try #require(Self.observations(Frames.prefixDiscoverReplyPacket(key: key)).first)
    #expect(prefix.kind == .discoverReply)
    #expect(prefix.identity == .keyPrefix(Data(key.prefix(8))))
  }

  @Test
  func `the discover reply push is observed like its RX log copy`() throws {
    let event = PacketParser.parse(Frames.controlData(key: Array(Self.claremontKey)))
    guard case .discoverResponse = event else {
      Issue.record("0x8E did not parse as a discover reply: \(event)")
      return
    }
    let observation = try #require(Self.pushObservations(event).first)
    #expect(observation.kind == .discoverReply)
    #expect(observation.identity == .fullKey(Self.claremontKey))
    #expect(observation.hops == 0)
    #expect(observation.snr == 6.5)
    #expect(observation.rssi == -90)
  }

  // MARK: - Direct messages

  /// The entry RxLogService stores for `raw` once it decrypted it with the fixture contact's key.
  private static func decrypted(_ raw: [UInt8], channel: RadioChannelConfig? = Frames.channel) async throws -> RxLogEntryDTO {
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil
    )
    await service.updatePrivateKey(Frames.DirectMessages.radioPrivateKeyExport)
    let contactKey = Frames.DirectMessages.contactKey
    await service.updateContactPublicKeys([contactKey[0]: [contactKey]])
    let entry = RxLogEntryDTO(
      radioID: UUID(),
      receivedAt: t0,
      from: Frames.parsed(raw, channel: channel),
      decryptStatus: .dmNoMatchingKey
    )
    return await service.decryptEntry(entry)
  }

  @Test
  func `a direct message from a contact proves the contact`() async throws {
    try #require(Frames.DirectMessages.contactKey[0] != Frames.selfKey[0])
    let entry = try await Self.decrypted(Frames.DirectMessages.fromContact(text: "hello"))
    #expect(entry.decodedText == "hello")
    #expect(entry.peerPublicKey == Frames.DirectMessages.contactKey)

    let observations = ObservationExtractor.observations(from: entry, selfKey: Frames.selfKey)
    let observation = try #require(observations.first)
    #expect(observations.count == 1)
    #expect(observation.kind == .decryptedMessage)
    #expect(observation.identity == .fullKey(Frames.DirectMessages.contactKey))
    #expect(observation.hops == 0)
    #expect(observation.snr == 6.5)
    #expect(observation.entryID == entry.id)
  }

  @Test
  func `a relayed direct message from a contact carries its hops and no signal`() async throws {
    let entry = try await Self.decrypted(Frames.DirectMessages.fromContact(path: [0x3A, 0x7F, 0x10]))
    let observation = try #require(ObservationExtractor.observations(from: entry, selfKey: Frames.selfKey).first)
    #expect(observation.hops == 3)
    #expect(observation.snr == nil)
  }

  @Test
  func `an echo of our own direct message proves nothing`() async throws {
    let entry = try await Self.decrypted(Frames.DirectMessages.ownEcho(text: "hi there"))
    #expect(entry.decodedText == "hi there")
    #expect(entry.peerPublicKey == Frames.DirectMessages.contactKey)
    #expect(ObservationExtractor.observations(from: entry, selfKey: Frames.selfKey).isEmpty)
  }

  @Test
  func `an unstamped stored entry proves nothing`() async throws {
    let entry = try await Self.decrypted(Frames.DirectMessages.fromContact(), channel: nil)
    #expect(entry.decryptStatus == .success)
    #expect(ObservationExtractor.observations(from: entry, selfKey: Frames.selfKey).isEmpty)

    let advert = Frames.entry(Frames.signedAdvert(name: "Claremont", key: Self.claremont), channel: nil)
    #expect(ObservationExtractor.observations(from: advert, selfKey: Frames.selfKey).isEmpty)
  }

  @Test
  func `a stamped stored advert gives the same observation as its live frame`() throws {
    let raw = Frames.signedAdvert(name: "Claremont", key: Self.claremont, path: [0x3A])
    let entry = Frames.entry(raw, channel: Frames.channel, receivedAt: Self.t0)
    let stored = try #require(ObservationExtractor.observations(from: entry, selfKey: Frames.selfKey).first)
    let live = try #require(Self.observations(raw).first)
    #expect(stored.identity == live.identity)
    #expect(stored.kind == live.kind)
    #expect(stored.hops == live.hops)
    #expect(stored.at == live.at)
    #expect(stored.entryID == entry.id)
  }

  // MARK: - Claims that prove nothing

  @Test
  func `an anonymous request's key, channel text, an unstamped frame and our own key give nothing`() {
    let anonymous = Frames.packet(
      payloadType: 0x07,
      route: Frames.routeFlood,
      payload: [0x10] + Array(Self.claremontKey) + [UInt8](repeating: 0x33, count: 18)
    )
    #expect(Self.observations(anonymous).isEmpty)
    #expect(Self.observations(Frames.groupTextPacket(index: 1)).isEmpty)

    let advert = Frames.signedAdvert(name: "Claremont", key: Self.claremont)
    #expect(Self.observations(advert, channel: nil).isEmpty)
    #expect(Self.observations(advert, selfKey: Self.claremontKey).isEmpty)
    #expect(Self.observations(Frames.discoverReplyPacket(key: Array(Frames.selfKey))).isEmpty)
  }

  @Test
  func `the radio's contact table and its advert pushes give nothing`() {
    let contact = MeshContact(
      id: "c",
      publicKey: Self.claremontKey,
      type: .repeater,
      flags: ContactFlags(rawValue: 0),
      outPathLength: 0xFF,
      outPath: Data(),
      advertisedName: "Kona Hill",
      lastAdvertisement: Self.t0,
      latitude: 19.6,
      longitude: -155.9,
      lastModified: Self.t0
    )
    #expect(Self.pushObservations(.contact(contact)).isEmpty)
    #expect(Self.pushObservations(.contactsStart(count: 1)).isEmpty)
    #expect(Self.pushObservations(.contactsEnd(lastModified: Self.t0)).isEmpty)

    // The same node pushed as a new advert (0x8A) or a known one's (0x80) is no proof it was
    // heard: CMD_IMPORT_CONTACT loops an imported advert back as if received, with no 0x88, and
    // the radio pushes it the same way. A heard advert comes with its own 0x88 frame.
    #expect(Self.pushObservations(.newContact(contact)).isEmpty)
    #expect(Self.pushObservations(.advertisement(publicKey: Self.claremontKey)).isEmpty)
  }

  // MARK: - Radio pushes

  @Test
  func `a status reply names its sender by a 6-byte prefix`() throws {
    let prefix = Data(Self.claremontKey.prefix(6))
    let event = PacketParser.parse(Frames.statusResponsePush(prefix: prefix))
    guard case .statusResponse = event else {
      Issue.record("0x87 did not parse as a status reply: \(event)")
      return
    }
    let observation = try #require(Self.pushObservations(event).first)
    #expect(observation.kind == .radioDecryptedReply)
    #expect(observation.identity == .keyPrefix(prefix))
    #expect(observation.hops == nil)
    #expect(observation.snr == nil)
  }

  @Test
  func `a path update names the full key`() throws {
    let event = PacketParser.parse(Frames.pathUpdatedPush(key: Self.claremontKey))
    #expect(Self.pushObservations(event).map(\.kind) == [.radioDecryptedReply])
    #expect(Self.pushObservations(event).first?.identity == .fullKey(Self.claremontKey))
  }

  @Test
  func `a push handled with no confirmed channel gives nothing`() {
    #expect(Self.pushObservations(.pathUpdate(publicKey: Self.claremontKey), channel: nil).isEmpty)
  }

  @Test
  func `a reply from this radio itself gives nothing`() {
    let ownPrefix = Data(Frames.selfKey.prefix(6))
    let event = PacketParser.parse(Frames.statusResponsePush(prefix: ownPrefix))
    #expect(Self.pushObservations(event).isEmpty)
    #expect(Self.pushObservations(.pathUpdate(publicKey: Frames.selfKey)).isEmpty)
  }

  // MARK: - Traces

  private static func trace(tag: UInt32, hashes: [Data], finalSNR: Double = 6.25) -> TraceInfo {
    let nodes = hashes.enumerated().map { TraceNode(hashBytes: $1, snr: Double($0) + 1) }
    return TraceInfo(
      tag: tag,
      authCode: 0,
      flags: hashes.first.map { UInt8($0.count.trailingZeroBitCount) } ?? 0,
      pathLength: UInt8(hashes.count),
      path: nodes + [TraceNode(hashBytes: nil, snr: finalSNR)]
    )
  }

  @Test
  func `our own trace's 8-byte hashes are observed; the last one sent the frame we heard`() throws {
    let first = Data(Self.claremontKey.prefix(8))
    let middle = Data([0x51] + [UInt8](repeating: 0x05, count: 7))
    let last = Data([0x62] + [UInt8](repeating: 0x06, count: 7))
    let event = MeshEvent.traceData(Self.trace(tag: 7, hashes: [first, middle, last]))

    let observations = Self.pushObservations(event) { $0 == 7 }
    #expect(observations.map(\.kind) == [.ownTraceHop, .ownTraceHop, .ownTraceHop])
    #expect(observations.map(\.identity) == [.keyPrefix(first), .keyPrefix(middle), .keyPrefix(last)])
    // Only the last hop sent the frame we heard; the first only heard us
    #expect(observations.map(\.hops) == [nil, nil, 0])
    #expect(observations.map(\.snr) == [nil, nil, 6.25])
  }

  @Test
  func `the first hop of a one-way trace only heard us: it is never heard directly`() throws {
    // [A, B]: A heard our trace and passed it on, B sent the frame this radio received
    let first = Data([0xA8] + [UInt8](repeating: 0x0A, count: 7))
    let last = Data([0xB8] + [UInt8](repeating: 0x0B, count: 7))
    let observations = Self.pushObservations(.traceData(Self.trace(tag: 7, hashes: [first, last]))) { $0 == 7 }
    #expect(observations.map(\.hops) == [nil, 0])

    var ledger = ObservationLedger(radioID: UUID(), channel: Frames.channel, selfKey: Frames.selfKey)
    ledger.ingest(observations)
    #expect(ledger.node(for: .keyPrefix(first))?.lastDirectAt == nil)
    #expect(ledger.node(for: .keyPrefix(last))?.lastDirectAt == Self.t0)
  }

  @Test
  func `a round trip trace's first and last hop are one node, heard directly`() throws {
    let node = Data([0xA8] + [UInt8](repeating: 0x0A, count: 7))
    let middle = Data([0xB8] + [UInt8](repeating: 0x0B, count: 7))
    let observations = Self.pushObservations(.traceData(Self.trace(tag: 7, hashes: [node, middle, node]))) { $0 == 7 }
    var ledger = ObservationLedger(radioID: UUID(), channel: Frames.channel, selfKey: Frames.selfKey)
    ledger.ingest(observations)
    #expect(ledger.node(for: .keyPrefix(node))?.lastDirectAt == Self.t0)
    #expect(ledger.node(for: .keyPrefix(middle))?.lastDirectAt == nil)
  }

  @Test
  func `someone else's trace and 1-byte trace hashes give nothing`() {
    let hashes = [Data(Self.claremontKey.prefix(8))]
    #expect(Self.pushObservations(.traceData(Self.trace(tag: 9, hashes: hashes))) { $0 == 7 }.isEmpty)
    let short = MeshEvent.traceData(Self.trace(tag: 7, hashes: [Data([0x3A]), Data([0x7F])]))
    #expect(Self.pushObservations(short) { $0 == 7 }.isEmpty)
  }

  // MARK: - Signature cache

  @Test
  func `an advert's signature is checked once per payload`() throws {
    let cache = AdvertSignatureCache(capacity: 4)
    let payload = Data(Frames.advertPayload(signer: Self.claremont, name: "Claremont"))
    let advert = try #require(AdvertPushRecovery.SignedAdvert(payload: payload))
    #expect(cache.isValid(advert, payload: payload, packetHash: "h1"))
    #expect(cache.isValid(advert, payload: payload, packetHash: "h1"))
    #expect(cache.count == 1)

    // A forged payload that happens to share the hash is checked afresh, not taken from the cache
    let forged = Data(Frames.advertPayload(signer: Frames.signingKey(seed: 0xEE), claimedKey: Self.claremontKey, name: "Claremont"))
    let forgedAdvert = try #require(AdvertPushRecovery.SignedAdvert(payload: forged))
    #expect(!cache.isValid(forgedAdvert, payload: forged, packetHash: "h1"))

    for index in 0..<6 {
      _ = cache.isValid(advert, payload: payload, packetHash: "other-\(index)")
    }
    #expect(cache.count <= 4)
  }
}
