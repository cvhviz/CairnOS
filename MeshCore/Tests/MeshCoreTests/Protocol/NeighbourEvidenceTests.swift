import Foundation
@testable import MeshCore
import Testing

@Suite("NeighbourEvidence")
struct NeighbourEvidenceTests {
  // MARK: - Fixtures

  private static let repeaterKey = Data((0..<32).map { UInt8(0xA0 &+ $0) })
  private static let ourKey = Data([0x22, 0x33, 0x44] + [UInt8](repeating: 0x55, count: 29))

  private enum Route: UInt8 {
    case tcFlood = 0, flood = 1, direct = 2, tcDirect = 3
  }

  /// A received packet, built as raw bytes and parsed like the RX log does.
  private func packet(
    _ route: Route,
    _ type: PayloadType,
    transportCode: [UInt8] = [],
    pathLength: UInt8 = 0,
    path: [UInt8] = [],
    payload: [UInt8],
    snr: Double = 6.5,
    rssi: Int = -92
  ) throws -> RxPacketFields {
    let header = route.rawValue | type.rawValue << 2
    let raw = Data([header] + transportCode + [pathLength] + path + payload)
    let parsed = try #require(RxLogParser.parse(snr: snr, rssi: rssi, payload: raw))
    return RxPacketFields(parsed)
  }

  private func advertPayload(key: Data, flags: UInt8, lat: Int32? = nil, lon: Int32? = nil, name: String? = nil) -> [UInt8] {
    var bytes = [UInt8](key) + [UInt8](repeating: 0x01, count: 4) + [UInt8](repeating: 0x5A, count: 64) + [flags]
    if let lat, let lon {
      for value in [lat, lon] {
        let bits = UInt32(bitPattern: value)
        bytes += [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
      }
    }
    if let name { bytes += Array(name.utf8) }
    return bytes
  }

  /// `0x90|type | inbound SNR x4 | tag LE | key`, as simple_repeater sends it.
  private func discoverReplyPayload(nodeType: UInt8 = 2, snrInQuarterDB: Int8, tag: UInt32, key: Data) -> [UInt8] {
    [0x90 | nodeType, UInt8(bitPattern: snrInQuarterDB),
     UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF), UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24)] + [UInt8](key)
  }

  // MARK: - R1 Relay

  @Test
  func `1-byte flood gives a 1-byte last-hop relay`() throws {
    let p = try packet(.flood, .groupText, pathLength: 0x02, path: [0x11, 0x3A], payload: [0xDE, 0xAD])
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)

    #expect(evidence.count == 1)
    #expect(evidence.first?.identity == .hash(Data([0x3A])))
    #expect(evidence.first?.source == .relay)
    #expect(evidence.first?.snr == 6.5)
    #expect(evidence.first?.rssi == -92)
    #expect(evidence.first?.packetHash == p.packetHash)
    #expect(evidence.first?.hearsYou == false)
  }

  @Test
  func `2-byte flood gives a 2-byte last-hop relay`() throws {
    let p = try packet(.flood, .textMessage, pathLength: 0x42, path: [0x11, 0x12, 0x3A, 0x7F], payload: [0x01, 0x02, 0x03])
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.hash(Data([0x3A, 0x7F]))])
  }

  @Test
  func `3-byte flood gives a 3-byte last-hop relay`() throws {
    let p = try packet(.flood, .advert, pathLength: 0x81, path: [0x3A, 0x7F, 0x21],
                       payload: advertPayload(key: Self.repeaterKey, flags: 0x82, name: "Far"))
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    // A relayed advert names its relay, not its far-away origin
    #expect(evidence.map(\.identity) == [.hash(Data([0x3A, 0x7F, 0x21]))])
    #expect(evidence.first?.source == .relay)
    #expect(evidence.first?.name == nil)
  }

  @Test
  func `transport flood with transport codes gives its last-hop relay`() throws {
    let p = try packet(.tcFlood, .groupText, transportCode: [0x01, 0x02, 0x03, 0x04],
                       pathLength: 0x41, path: [0xBE, 0xEF], payload: [0xAA])
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.hash(Data([0xBE, 0xEF]))])
    #expect(evidence.first?.source == .relay)
  }

  @Test
  func `a last hop equal to our own hash is dropped`() throws {
    let oneByte = try packet(.flood, .groupText, pathLength: 0x02, path: [0x11, 0x22], payload: [0xAA])
    #expect(NeighbourEvidence.extract(oneByte, selfHash: Self.ourKey).isEmpty)

    let twoByte = try packet(.flood, .groupText, pathLength: 0x41, path: [0x22, 0x33], payload: [0xAA])
    #expect(NeighbourEvidence.extract(twoByte, selfHash: Self.ourKey).isEmpty)

    // Sharing only the first byte at 2-byte size is another node
    let other = try packet(.flood, .groupText, pathLength: 0x41, path: [0x22, 0x99], payload: [0xAA])
    #expect(NeighbourEvidence.extract(other, selfHash: Self.ourKey).map(\.identity) == [.hash(Data([0x22, 0x99]))])
  }

  @Test
  func `a hash longer than the self hash given is kept`() throws {
    let p = try packet(.flood, .groupText, pathLength: 0x41, path: [0x22, 0x33], payload: [0xAA])
    #expect(NeighbourEvidence.extract(p, selfHash: Data([0x22])).count == 1)
  }

  // MARK: - R8 Own Echo

  @Test
  func `a 1-hop relay of our own packet hears us`() throws {
    let p = try packet(.flood, .groupText, pathLength: 0x01, path: [0x3A], payload: [0xCA, 0xFE])
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey, ownPacketHashes: [p.packetHash])
    #expect(evidence.first?.hearsYou == true)
    #expect(evidence.first?.source == .relay)

    let farther = try packet(.flood, .groupText, pathLength: 0x02, path: [0x11, 0x3A], payload: [0xCA, 0xFE])
    let fartherEvidence = NeighbourEvidence.extract(farther, selfHash: Self.ourKey, ownPacketHashes: [farther.packetHash])
    #expect(fartherEvidence.first?.hearsYou == false)
  }

  // MARK: - R2, R3 Adverts and Origins

  @Test
  func `hop-0 flood advert gives full key, type, name and position`() throws {
    let p = try packet(.flood, .advert, payload: advertPayload(
      key: Self.repeaterKey, flags: 0x92, lat: 37_774_900, lon: -122_419_400, name: "Ridge RPT"
    ))
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)

    #expect(evidence.count == 1)
    let advert = try #require(evidence.first)
    #expect(advert.identity == .fullKey(Self.repeaterKey))
    #expect(advert.source == .advert)
    #expect(advert.nodeTypeRaw == 2)
    #expect(advert.name == "Ridge RPT")
    #expect(advert.latitude == 37.7749)
    #expect(advert.longitude == -122.4194)
    #expect(advert.snr == 6.5)
  }

  @Test
  func `direct zero-hop advert gives full key`() throws {
    let p = try packet(.direct, .advert, payload: advertPayload(key: Self.repeaterKey, flags: 0x83, name: "Room"))
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.fullKey(Self.repeaterKey)])
    #expect(evidence.first?.source == .advert)
    #expect(evidence.first?.nodeTypeRaw == 3)
    #expect(evidence.first?.latitude == nil)
  }

  @Test
  func `our own advert is dropped`() throws {
    let p = try packet(.flood, .advert, payload: advertPayload(key: Self.ourKey, flags: 0x81, name: "Me"))
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
  }

  @Test
  func `truncated advert gives nothing`() throws {
    let p = try packet(.flood, .advert, payload: [UInt8](Self.repeaterKey) + [0x01, 0x02])
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
  }

  @Test
  func `hop-0 flood message gives a weak 1-byte origin`() throws {
    let p = try packet(.flood, .textMessage, payload: [0x22, 0x5C, 0x01, 0x02, 0x03])
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.hash(Data([0x5C]))])
    #expect(evidence.first?.source == .weakOrigin)
  }

  @Test
  func `hop-0 flood anonymous request gives a weak full-key origin`() throws {
    let p = try packet(.flood, .anonRequest, payload: [0x22] + [UInt8](Self.repeaterKey) + [0x01, 0x02])
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.fullKey(Self.repeaterKey)])
    #expect(evidence.first?.source == .weakOrigin)
  }

  @Test
  func `hop-0 flood group text names no origin`() throws {
    let p = try packet(.flood, .groupText, payload: [0x11, 0x22, 0x33])
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
  }

  // MARK: - R4 Discover Replies

  @Test
  func `discover reply with full key gives key, type, uplink SNR and tag`() throws {
    let p = try packet(.direct, .control, payload: discoverReplyPayload(
      snrInQuarterDB: -26, tag: 0xDEAD_BEEF, key: Self.repeaterKey
    ))
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)

    #expect(evidence.count == 1)
    let reply = try #require(evidence.first)
    #expect(reply.identity == .fullKey(Self.repeaterKey))
    #expect(reply.source == .discoverReply)
    #expect(reply.nodeTypeRaw == 2)
    #expect(reply.uplinkSNR == -6.5)
    #expect(reply.tag == 0xDEAD_BEEF)
    #expect(reply.snr == 6.5)
    #expect(reply.rssi == -92)
    #expect(reply.hearsYou == false)
  }

  @Test
  func `prefix-only discover reply gives an 8-byte key prefix`() throws {
    let prefix = Self.repeaterKey.prefix(8)
    let p = try packet(.direct, .control, payload: discoverReplyPayload(
      nodeType: 4, snrInQuarterDB: 40, tag: 7, key: Data(prefix)
    ))
    let evidence = NeighbourEvidence.extract(p, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.keyPrefix(Data(prefix))])
    #expect(evidence.first?.uplinkSNR == 10)
    #expect(evidence.first?.tag == 7)
    #expect(evidence.first?.nodeTypeRaw == 4)
  }

  @Test
  func `transport-direct discover reply is read too`() throws {
    let p = try packet(.tcDirect, .control, transportCode: [0x01, 0x02, 0x03, 0x04],
                       payload: discoverReplyPayload(snrInQuarterDB: 0, tag: 1, key: Self.repeaterKey))
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).first?.source == .discoverReply)
  }

  @Test
  func `CONTROL_DATA push gives the same evidence as the RX log frame`() throws {
    let replyPayload = discoverReplyPayload(snrInQuarterDB: -26, tag: 0x0102_0304, key: Self.repeaterKey)
    let rxLog = try packet(.direct, .control, payload: replyPayload, snr: 6.5, rssi: -92)

    // 0x8E body: snr x4, rssi, path_len, then the packet payload
    let push = Data([26, UInt8(bitPattern: -92), 0x00] + replyPayload)
    guard case let .discoverResponse(response) = Parsers.ControlData.parse(push) else {
      Issue.record("Expected .discoverResponse")
      return
    }

    let fromPush = NeighbourEvidence.extract(response, selfHash: Self.ourKey)
    #expect(fromPush == NeighbourEvidence.extract(rxLog, selfHash: Self.ourKey))
    #expect(fromPush.first?.packetHash == rxLog.packetHash)
  }

  @Test
  func `prefix-only CONTROL_DATA push gives a key prefix`() {
    let response = DiscoverResponse(
      nodeType: 2, snrIn: 1.25, snr: 3, rssi: -100, pathLength: 0,
      tag: Data([0x01, 0x00, 0x00, 0x00]), publicKey: Data(Self.repeaterKey.prefix(8))
    )
    let evidence = NeighbourEvidence.extract(response, selfHash: Self.ourKey)
    #expect(evidence.map(\.identity) == [.keyPrefix(Data(Self.repeaterKey.prefix(8)))])
    #expect(evidence.first?.tag == 1)
    #expect(evidence.first?.uplinkSNR == 1.25)
  }

  @Test
  func `malformed CONTROL_DATA push key gives nothing`() {
    let response = DiscoverResponse(
      nodeType: 2, snrIn: 0, snr: 0, rssi: -100, pathLength: 0,
      tag: Data([0x01, 0x00, 0x00, 0x00]), publicKey: Data([0x01, 0x02, 0x03])
    )
    #expect(NeighbourEvidence.extract(response, selfHash: Self.ourKey).isEmpty)
  }

  // MARK: - R5 Overheard Requests

  @Test
  func `overheard discover request is a limiter spend, not an identity`() throws {
    let p = try packet(.direct, .control, payload: [0x81, 0x04, 0x78, 0x56, 0x34, 0x12, 0x10, 0x00, 0x00, 0x00])

    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
    let request = try #require(NeighbourEvidence.overheardDiscoverRequest(in: p))
    #expect(request.filter == 0x04)
    #expect(request.tag == 0x1234_5678)
    #expect(request.prefixOnly)
    #expect(request.since == 16)
    #expect(request.packetHash == p.packetHash)
  }

  @Test
  func `discover request without since and replies are told apart`() throws {
    let request = try packet(.direct, .control, payload: [0x80, 0x10, 0x01, 0x00, 0x00, 0x00])
    #expect(NeighbourEvidence.overheardDiscoverRequest(in: request)?.since == nil)
    #expect(NeighbourEvidence.overheardDiscoverRequest(in: request)?.prefixOnly == false)

    let reply = try packet(.direct, .control, payload: discoverReplyPayload(snrInQuarterDB: 0, tag: 1, key: Self.repeaterKey))
    #expect(NeighbourEvidence.overheardDiscoverRequest(in: reply) == nil)
  }

  // MARK: - R6, R7 and Path Mode

  @Test
  func `direct packet with hops gives nothing`() throws {
    let message = try packet(.direct, .textMessage, pathLength: 0x02, path: [0x11, 0x3A], payload: [0x01, 0x02, 0x03])
    #expect(NeighbourEvidence.extract(message, selfHash: Self.ourKey).isEmpty)

    let reply = try packet(.direct, .control, pathLength: 0x01, path: [0x11],
                           payload: discoverReplyPayload(snrInQuarterDB: 0, tag: 1, key: Self.repeaterKey))
    #expect(NeighbourEvidence.extract(reply, selfHash: Self.ourKey).isEmpty)
  }

  @Test
  func `zero-hop direct message names nobody`() throws {
    let p = try packet(.direct, .textMessage, payload: [0x22, 0x5C, 0x01])
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
  }

  @Test
  func `trace in the RX log gives nothing`() throws {
    // tag(4) auth(4) flags(1) hash; the path holds SNR bytes, not hashes
    let p = try packet(.direct, .trace, pathLength: 0x01, path: [0x18],
                       payload: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3A])
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
  }

  @Test
  func `1-hop trace push gives a trace confirm both ways`() {
    let trace = TraceInfo(tag: 42, authCode: 0, flags: 1, pathLength: 2, path: [
      TraceNode(hashBytes: Data([0x3A, 0x7F]), snr: 4.25),
      TraceNode(hashBytes: nil, snr: -2.5)
    ])
    let evidence = NeighbourEvidence.extract(trace, isOwn: true)

    #expect(evidence.count == 1)
    #expect(evidence.first?.identity == .hash(Data([0x3A, 0x7F])))
    #expect(evidence.first?.source == .traceConfirm)
    #expect(evidence.first?.snr == -2.5)
    #expect(evidence.first?.uplinkSNR == 4.25)
    #expect(evidence.first?.tag == 42)
    #expect(evidence.first?.hearsYou == true)
    #expect(evidence.first?.rssi == nil)
  }

  @Test
  func `someone else's 1-hop trace is only a relay reception of the node`() {
    // the radio pushes every trace whose last retransmission it hears, whoever sent it
    let trace = TraceInfo(tag: 42, authCode: 0, flags: 1, pathLength: 2, path: [
      TraceNode(hashBytes: Data([0x3A, 0x7F]), snr: 4.25),
      TraceNode(hashBytes: nil, snr: -2.5)
    ])
    let evidence = NeighbourEvidence.extract(trace, isOwn: false)

    #expect(evidence.count == 1)
    #expect(evidence.first?.identity == .hash(Data([0x3A, 0x7F])))
    #expect(evidence.first?.source == .relay)
    #expect(evidence.first?.snr == -2.5)
    #expect(evidence.first?.uplinkSNR == nil)
    #expect(evidence.first?.tag == nil)
    #expect(evidence.first?.hearsYou == false)
  }

  @Test
  func `an advert with hops still names its advertiser for the key index`() throws {
    var payload = [UInt8](Self.repeaterKey) + [UInt8](repeating: 0, count: 4 + 64)
    payload += [0x80 | 0x02] + Array("Hilltop".utf8)
    let p = try packet(.flood, .advert, pathLength: 0x02, path: [0xAA, 0xBB], payload: payload)

    // relayed twice, so only the last relay is a neighbour
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).map(\.source) == [.relay])
    let advertiser = try #require(NeighbourEvidence.advertiser(in: p, selfHash: Self.ourKey))
    #expect(advertiser.identity == .fullKey(Self.repeaterKey))
    #expect(advertiser.nodeTypeRaw == 2)
    #expect(advertiser.name == "Hilltop")
    #expect(NeighbourEvidence.advertiser(in: p, selfHash: Self.repeaterKey) == nil)
  }

  @Test
  func `multi-hop trace push gives nothing`() {
    let trace = TraceInfo(tag: 42, authCode: 0, flags: 0, pathLength: 2, path: [
      TraceNode(hashBytes: Data([0x3A]), snr: 4),
      TraceNode(hashBytes: Data([0x7F]), snr: 3),
      TraceNode(hashBytes: nil, snr: -2.5)
    ])
    #expect(NeighbourEvidence.extract(trace, isOwn: true).isEmpty)
  }

  @Test
  func `8-byte trace hash gives a key prefix`() {
    let hash = Data(Self.repeaterKey.prefix(8))
    let trace = TraceInfo(tag: 1, authCode: 0, flags: 3, pathLength: 8, path: [
      TraceNode(hashBytes: hash, snr: 1),
      TraceNode(hashBytes: nil, snr: 2)
    ])
    #expect(NeighbourEvidence.extract(trace, isOwn: true).map(\.identity) == [.keyPrefix(hash)])
  }

  @Test
  func `path mode 3 gives nothing`() {
    let p = RxPacketFields(
      routeType: .flood, payloadType: .groupText, pathLength: 0xC1, pathNodes: Data([0x3A]),
      packetPayload: Data([0xAA]), packetHash: "00", snr: 5, rssi: -90
    )
    #expect(NeighbourEvidence.extract(p, selfHash: Self.ourKey).isEmpty)
  }

  // MARK: - Identity

  @Test
  func `identity matches keys that start with its bytes`() {
    #expect(NeighbourIdentity.hash(Data([0xA0, 0xA1])).matches(publicKey: Self.repeaterKey))
    #expect(!NeighbourIdentity.hash(Data([0xA1])).matches(publicKey: Self.repeaterKey))
    #expect(!NeighbourIdentity.hash(Data()).matches(publicKey: Self.repeaterKey))
    #expect(NeighbourIdentity.fullKey(Self.repeaterKey).isFullKey)
    #expect(!NeighbourIdentity.keyPrefix(Data(Self.repeaterKey.prefix(8))).isFullKey)
  }
}
