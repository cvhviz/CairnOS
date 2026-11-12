import Foundation

// MARK: - Identity

/// Who a piece of neighbour evidence names, as precisely as the packet allows.
public enum NeighbourIdentity: Sendable, Hashable {
  /// A full 32-byte public key (an advert, a full discover reply, a 0-hop anonymous request).
  case fullKey(Data)
  /// The 8-byte key prefix of a prefix-only discover reply, or an 8-byte trace hash.
  case keyPrefix(Data)
  /// A path or trace hash of 1, 2, 3 or 4 bytes, which several keys can share.
  case hash(Data)

  /// The identifying bytes: the key, the prefix or the hash.
  public var bytes: Data {
    switch self {
    case let .fullKey(data), let .keyPrefix(data), let .hash(data): data
    }
  }

  /// Whether this names exactly one node.
  public var isFullKey: Bool {
    if case .fullKey = self { true } else { false }
  }

  /// Whether `publicKey` is (or starts with) these bytes. Empty bytes never match.
  public func matches(publicKey: Data) -> Bool {
    let bytes = bytes
    return !bytes.isEmpty && publicKey.starts(with: bytes)
  }
}

// MARK: - Source

/// What kind of reception a piece of neighbour evidence came from.
public enum NeighbourEvidenceSource: String, Sendable, Hashable, CaseIterable {
  /// The last hop of a received flood: the repeater that just re-sent it (R1).
  case relay
  /// A 0-hop advert, flood or direct, heard straight from its sender (R2, R3).
  case advert
  /// The source hash or key of another 0-hop flood: it only strengthens an existing match and
  /// never creates a neighbour on its own (R2).
  case weakOrigin
  /// A discover reply, to our request or to anyone's (R4).
  case discoverReply
  /// A 1-hop trace that came back, which measures the link both ways (R6).
  case traceConfirm
}

// MARK: - Evidence

/// One reception that shows a node is a direct neighbour of this radio: heard at `snr` and
/// `rssi` straight from that node's own transmission.
///
/// Built only by the extractors below, which implement rules R1-R8 of the neighbour model. They
/// are pure: the caller stamps the time it received the packet and aggregates the evidence.
public struct NeighbourEvidence: Sendable, Equatable {
  public let identity: NeighbourIdentity
  public let source: NeighbourEvidenceSource
  /// SNR of the neighbour's transmission at this radio, in dB.
  public let snr: Double?
  /// RSSI of the neighbour's transmission at this radio, in dBm. Nil for a trace.
  public let rssi: Int?
  /// The node type the packet states (1 chat, 2 repeater, 3 room, 4 sensor; 0 = not said).
  public let nodeTypeRaw: UInt8?
  /// The advert's name, if it carries one.
  public let name: String?
  /// The advert's position in degrees, if it carries one (0,0 means none and gives nil).
  public let latitude: Double?
  public let longitude: Double?
  /// How the neighbour heard the request it answered, in dB: payload[1] / 4 of a discover reply,
  /// or the trace's SNR there. Only a reply to our own probe says how it hears us.
  public let uplinkSNR: Double?
  /// The discover reply's or trace's correlation tag.
  public let tag: UInt32?
  /// The packet itself proves the neighbour heard this radio: a trace that came back, or a
  /// 1-hop relay of a packet we sent (R8). A discover reply's tag is matched by the caller.
  public let hearsYou: Bool
  /// The packet's correlation hash, nil for a trace (the push doesn't carry the packet).
  public let packetHash: String?

  public init(
    identity: NeighbourIdentity,
    source: NeighbourEvidenceSource,
    snr: Double?,
    rssi: Int?,
    nodeTypeRaw: UInt8? = nil,
    name: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    uplinkSNR: Double? = nil,
    tag: UInt32? = nil,
    hearsYou: Bool = false,
    packetHash: String?
  ) {
    self.identity = identity
    self.source = source
    self.snr = snr
    self.rssi = rssi
    self.nodeTypeRaw = nodeTypeRaw
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.uplinkSNR = uplinkSNR
    self.tag = tag
    self.hearsYou = hearsYou
    self.packetHash = packetHash
  }
}

// MARK: - Overheard Discover Request

/// A NODE_DISCOVER_REQ heard on the air (R5). It names no sender: it is a spend of the
/// repeaters' shared discover limiter, which the request gate must count.
public struct OverheardDiscoverRequest: Sendable, Equatable {
  /// The node-type bit mask the request asks for (bit 2 repeater, bit 4 sensor).
  public let filter: UInt8
  public let tag: UInt32
  /// The request asked for 8-byte key prefixes instead of full keys.
  public let prefixOnly: Bool
  /// The optional `since` field (only nodes changed at or after this time answer).
  public let since: UInt32?
  public let packetHash: String
}

// MARK: - Extraction

public extension NeighbourEvidence {
  /// The neighbour evidence in one received packet.
  ///
  /// - Parameters:
  ///   - packet: The received packet.
  ///   - selfHash: This radio's public key. A hop or key it starts with is our own echo and is
  ///     dropped; a hash longer than `selfHash` is never treated as ours.
  ///   - ownPacketHashes: Correlation hashes of packets this radio sent recently. A 1-hop flood
  ///     with one of them was relayed straight from us, so its relay heard us (R8).
  /// - Returns: The evidence, empty when the packet names no direct neighbour.
  static func extract(
    _ packet: RxPacketFields,
    selfHash: Data?,
    ownPacketHashes: Set<String> = []
  ) -> [NeighbourEvidence] {
    // R7 needs no code: a direct packet's path is the route still ahead, so only its 0-hop
    // advert and discover reply name the transmitter. Mode 3 or a malformed path gives nothing
    guard let hops = PathHops.split(pathNodes: packet.pathNodes, pathLength: packet.pathLength) else {
      return []
    }
    // R6: a trace's path holds SNR bytes, not hashes; only the .traceData push is used
    guard packet.payloadType != .trace else { return [] }

    if packet.routeType.isFlood {
      if let lastHop = hops.last {
        return relayEvidence(packet, lastHop: lastHop, hopCount: hops.count, selfHash: selfHash,
                             ownPacketHashes: ownPacketHashes)
      }
      return originEvidence(packet, selfHash: selfHash)
    }

    guard hops.isEmpty else { return [] }
    switch packet.payloadType {
    case .advert:
      return advertEvidence(packet, selfHash: selfHash).map { [$0] } ?? []
    case .control:
      return discoverReplyEvidence(packet, selfHash: selfHash).map { [$0] } ?? []
    default:
      return []
    }
  }

  /// The evidence in a CONTROL_DATA discover reply push (0x8E). It is the same reply the RX log
  /// frame carries, so the packet hash is rebuilt from it and both frames give equal evidence.
  static func extract(_ response: DiscoverResponse, selfHash: Data?) -> [NeighbourEvidence] {
    guard response.tag.count == 4, let identity = keyIdentity(response.publicKey),
          !isSelf(identity.bytes, selfHash: selfHash) else { return [] }
    let snrInByte = UInt8(bitPattern: Int8(clamping: Int((response.snrIn * 4).rounded())))
    var payload = Data([discoverResponseType | (response.nodeType & 0x0F), snrInByte])
    payload.append(response.tag)
    payload.append(response.publicKey)
    return [NeighbourEvidence(
      identity: identity,
      source: .discoverReply,
      snr: response.snr,
      rssi: response.rssi,
      nodeTypeRaw: response.nodeType & 0x0F,
      uplinkSNR: response.snrIn,
      tag: response.tag.readUInt32LE(at: 0),
      packetHash: ParsedRxLogData.computePacketHash(from: payload)
    )]
  }

  /// The evidence in a trace that came back (R6). Only a 1-hop trace names a neighbour: its
  /// one hash answered, and the final SNR is how we heard it.
  ///
  /// The radio pushes the result of every trace whose last retransmission it hears, someone
  /// else's too. Only our own trace says how the neighbour heard us (its SNR there) and that it
  /// hears us at all; another's is just a reception of the neighbour re-sending it, a relay.
  ///
  /// - Parameter isOwn: This radio sent the trace (its tag is one of ours).
  static func extract(_ trace: TraceInfo, isOwn: Bool) -> [NeighbourEvidence] {
    guard trace.path.count == 2, trace.path[1].hashBytes == nil,
          let hash = trace.path[0].hashBytes, !hash.isEmpty else { return [] }
    let identity: NeighbourIdentity = hash.count == 8 ? .keyPrefix(Data(hash)) : .hash(Data(hash))
    guard isOwn else {
      return [NeighbourEvidence(identity: identity, source: .relay, snr: trace.path[1].snr, rssi: nil, packetHash: nil)]
    }
    return [NeighbourEvidence(
      identity: identity,
      source: .traceConfirm,
      snr: trace.path[1].snr,
      rssi: nil,
      uplinkSNR: trace.path[0].snr,
      tag: trace.tag,
      hearsYou: true,
      packetHash: nil
    )]
  }

  /// The node an advert announces, whatever path it came by: its full key, type, name and
  /// position, for resolving path hashes. Only a 0-hop advert also shows the advertiser is a
  /// neighbour (``extract(_:selfHash:ownPacketHashes:)``); this one is for a key index alone.
  static func advertiser(in packet: RxPacketFields, selfHash: Data?) -> NeighbourEvidence? {
    guard packet.payloadType == .advert else { return nil }
    return advertEvidence(packet, selfHash: selfHash)
  }

  /// The discover request in a received packet, if it is one (R5): a 0-hop direct CONTROL
  /// packet whose type nibble is 0x80, at least type + filter + tag long.
  static func overheardDiscoverRequest(in packet: RxPacketFields) -> OverheardDiscoverRequest? {
    let p = [UInt8](packet.packetPayload)
    guard !packet.routeType.isFlood, packet.payloadType == .control,
          decodePathLen(packet.pathLength)?.hopCount == 0,
          p.count >= 6, p[0] & 0xF0 == discoverRequestType else { return nil }
    return OverheardDiscoverRequest(
      filter: p[1],
      tag: uint32LE(p, at: 2),
      prefixOnly: p[0] & 0x01 != 0,
      since: p.count >= 10 ? uint32LE(p, at: 6) : nil,
      packetHash: packet.packetHash
    )
  }
}

// MARK: - Rules

private extension NeighbourEvidence {
  /// Control payload types (upper nibble of payload[0]); simple_repeater/MyMesh.cpp.
  static let discoverRequestType: UInt8 = 0x80
  static let discoverResponseType: UInt8 = 0x90
  /// type(1) + inbound SNR(1) + tag(4) + 8-byte key prefix.
  static let discoverReplyMinimumLength = 6 + 8
  static let publicKeySize = 32
  /// public_key(32) + timestamp(4) + signature(64), then the app data.
  static let advertAppDataOffset = 32 + 4 + 64

  /// R1 and R8: a repeater appends its own hash, at the packet's hash size, before re-sending a
  /// flood (src/Mesh.cpp routeRecvPacket), so the last hop is the node we just heard.
  static func relayEvidence(
    _ packet: RxPacketFields,
    lastHop: Data,
    hopCount: Int,
    selfHash: Data?,
    ownPacketHashes: Set<String>
  ) -> [NeighbourEvidence] {
    guard !isSelf(lastHop, selfHash: selfHash) else { return [] }
    return [NeighbourEvidence(
      identity: .hash(lastHop),
      source: .relay,
      snr: packet.snr,
      rssi: packet.rssi,
      hearsYou: hopCount == 1 && ownPacketHashes.contains(packet.packetHash),
      packetHash: packet.packetHash
    )]
  }

  /// R2: a 0-hop flood was sent by the node we heard. An advert names it by full key; other
  /// types name only their 1-byte source hash (an anonymous request its sender's key), which
  /// is weak evidence.
  static func originEvidence(_ packet: RxPacketFields, selfHash: Data?) -> [NeighbourEvidence] {
    let p = packet.packetPayload
    let identity: NeighbourIdentity
    switch packet.payloadType {
    case .advert:
      return advertEvidence(packet, selfHash: selfHash).map { [$0] } ?? []
    case .textMessage, .request, .response, .path:
      // dest hash(1) | src hash(1) | ...; payload hashes are always 1 byte
      guard p.count >= 2 else { return [] }
      identity = .hash(Data([p[p.startIndex + 1]]))
    case .anonRequest:
      // dest hash(1) | sender public key(32) | ...
      guard p.count >= 1 + publicKeySize else { return [] }
      identity = .fullKey(Data(p.dropFirst().prefix(publicKeySize)))
    default:
      return []
    }
    guard !isSelf(identity.bytes, selfHash: selfHash) else { return [] }
    return [NeighbourEvidence(
      identity: identity,
      source: .weakOrigin,
      snr: packet.snr,
      rssi: packet.rssi,
      packetHash: packet.packetHash
    )]
  }

  /// R2 and R3: `public_key(32) | timestamp(4) | signature(64) | app_data`, app_data being a
  /// flags byte (bits 0-3 node type), the position if 0x10, a feature word each for 0x20 and
  /// 0x40, and the name to the end if 0x80.
  static func advertEvidence(_ packet: RxPacketFields, selfHash: Data?) -> NeighbourEvidence? {
    let p = [UInt8](packet.packetPayload)
    guard p.count > advertAppDataOffset else { return nil }
    let key = Data(p[0..<publicKeySize])
    guard !isSelf(key, selfHash: selfHash) else { return nil }
    let flags = p[advertAppDataOffset]
    var i = advertAppDataOffset + 1
    var latitude: Double?
    var longitude: Double?
    if flags & 0x10 != 0 {
      guard p.count >= i + 8 else { return nil }
      latitude = Double(Int32(bitPattern: uint32LE(p, at: i))) / 1e6
      longitude = Double(Int32(bitPattern: uint32LE(p, at: i + 4))) / 1e6
      i += 8
    }
    if flags & 0x20 != 0 { i += 2 }
    if flags & 0x40 != 0 { i += 2 }
    var name: String?
    if flags & 0x80 != 0, i < p.count {
      let decoded = String(decoding: p[i...].prefix { $0 != 0 }, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      name = decoded.isEmpty ? nil : decoded
    }
    // 0,0 is "no position" in MeshCore adverts
    if latitude == 0, longitude == 0 { latitude = nil; longitude = nil }
    return NeighbourEvidence(
      identity: .fullKey(key),
      source: .advert,
      snr: packet.snr,
      rssi: packet.rssi,
      nodeTypeRaw: flags & 0x0F,
      name: name,
      latitude: latitude,
      longitude: longitude,
      packetHash: packet.packetHash
    )
  }

  /// R4: `type|node type (1) | inbound SNR x4 (1) | tag (4) | key (8 or 32)`, sent 0-hop
  /// direct (simple_repeater/MyMesh.cpp onControlDataRecv).
  static func discoverReplyEvidence(_ packet: RxPacketFields, selfHash: Data?) -> NeighbourEvidence? {
    let p = [UInt8](packet.packetPayload)
    guard p.count >= discoverReplyMinimumLength, p[0] & 0xF0 == discoverResponseType else { return nil }
    let keyLength = p.count >= 6 + publicKeySize ? publicKeySize : 8
    guard let identity = keyIdentity(Data(p[6..<6 + keyLength])),
          !isSelf(identity.bytes, selfHash: selfHash) else { return nil }
    return NeighbourEvidence(
      identity: identity,
      source: .discoverReply,
      snr: packet.snr,
      rssi: packet.rssi,
      nodeTypeRaw: p[0] & 0x0F,
      uplinkSNR: Double(Int8(bitPattern: p[1])) / 4.0,
      tag: uint32LE(p, at: 2),
      packetHash: packet.packetHash
    )
  }

  /// A full key for 32 bytes, a prefix for 8; anything else is malformed.
  static func keyIdentity(_ key: Data) -> NeighbourIdentity? {
    switch key.count {
    case publicKeySize: .fullKey(Data(key))
    case 8: .keyPrefix(Data(key))
    default: nil
    }
  }

  /// Whether `bytes` are this radio's own: `selfHash` starts with them. A hash longer than
  /// `selfHash` can't be judged and is kept.
  static func isSelf(_ bytes: Data, selfHash: Data?) -> Bool {
    guard let selfHash, !bytes.isEmpty, selfHash.count >= bytes.count else { return false }
    return selfHash.starts(with: bytes)
  }

  static func uint32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }
}
