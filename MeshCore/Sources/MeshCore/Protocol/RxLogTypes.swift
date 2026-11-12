import CryptoKit
import Foundation

/// Route type extracted from header byte bits 0-1.
/// All 4 possible 2-bit values are valid (cannot be unknown).
public enum RouteType: UInt8, Sendable, Codable, CaseIterable {
  case tcFlood = 0
  case flood = 1
  case direct = 2
  case tcDirect = 3

  /// Whether this route type includes a 4-byte transport code.
  public var hasTransportCode: Bool {
    self == .tcFlood || self == .tcDirect
  }

  /// Whether the packet was flood-routed, accumulating each relay's hash into its path.
  /// Direct-routed packets carry the remaining route instead, so their path length is not
  /// a count of hops traversed.
  public var isFlood: Bool {
    self == .flood || self == .tcFlood
  }

  /// Human-readable display name.
  public var displayName: String {
    switch self {
    case .tcFlood: "TC_FLOOD"
    case .flood: "FLOOD"
    case .direct: "DIRECT"
    case .tcDirect: "TC_DIRECT"
    }
  }
}

/// Payload type extracted from header byte bits 2-5.
/// Values 0-11 are defined; 12-15 map to .unknown.
public enum PayloadType: UInt8, Sendable, CaseIterable {
  case request = 0
  case response = 1
  case textMessage = 2
  case ack = 3
  case advert = 4
  case groupText = 5
  case groupData = 6
  case anonRequest = 7
  case path = 8
  case trace = 9
  case multipart = 10
  case control = 11
  case rawCustom = 15
  case unknown = 255

  /// Initialize from raw 4-bit value (0-15). Values 12-14 (reserved) return .unknown; 15 returns .rawCustom.
  public init(fromBits bits: UInt8) {
    self = PayloadType(rawValue: bits) ?? .unknown
  }

  /// Human-readable display name.
  public var displayName: String {
    switch self {
    case .request: "REQUEST"
    case .response: "RESPONSE"
    case .textMessage: "TEXT_MSG"
    case .ack: "ACK"
    case .advert: "ADVERT"
    case .groupText: "GROUP_TEXT"
    case .groupData: "GROUP_DATA"
    case .anonRequest: "ANON_REQ"
    case .path: "PATH"
    case .trace: "TRACE"
    case .multipart: "MULTIPART"
    case .control: "CONTROL"
    case .rawCustom: "RAW_CUSTOM"
    case .unknown: "UNKNOWN"
    }
  }
}

/// Parsed RF packet data from rxLogData events.
public struct ParsedRxLogData: Sendable, Equatable {
  // Always available (raw)
  public let snr: Double?
  public let rssi: Int?
  public let rawPayload: Data

  // Always available (parsed)
  public let routeType: RouteType
  public let payloadType: PayloadType
  public let payloadVersion: UInt8

  /// Raw 4-bit payload-type bits from the header, before mapping to `PayloadType`.
  /// Required by `TransportCodeRegionResolver`, which must hash the wire-format
  /// nibble (firmware bits 12-14 currently map to `PayloadType.unknown = 255`,
  /// which would corrupt the HMAC input).
  public let payloadTypeBits: UInt8

  /// Conditional on route type
  public let transportCode: Data?

  // Path information (empty if malformed)
  public let pathLength: UInt8
  public let pathNodes: [UInt8]

  /// Message payload (after header/path extraction)
  public let packetPayload: Data

  /// 1-byte sender pubkey hash for direct messages (nil for channel/other types).
  public let senderPubkeyPrefix: Data?

  /// 1-byte recipient pubkey hash for direct messages (nil for channel/other types).
  public let recipientPubkeyPrefix: Data?

  /// Correlation hash for "heard repeats" detection
  public let packetHash: String

  // RX_SYNC delivery (Cairn firmware's `net/RX_SYNC.md`); nil/false for a stock 0x88 frame.

  /// The radio journal's number for this packet, unique within ``epoch``.
  public let seq: UInt32?
  /// The radio journal's identity (random at each boot) that ``seq`` counts within.
  public let epoch: UInt32?
  /// How long before the radio wrote the frame it received the packet; subtract it from the
  /// arrival time for the receive time.
  public let radioAge: Duration?
  /// The packet was sent again (a FETCH or a replay), not live: it may arrive out of order.
  public let isBackfill: Bool

  /// The channel the radio was on when it received this packet, as its last `SELF_INFO`
  /// reported it; set by ``MeshCoreSession`` when the frame arrives. `nil` when the session could
  /// not vouch for it: no `SELF_INFO` yet, a retune not yet confirmed, or an RX_SYNC record
  /// received before the radio's current channel was confirmed.
  public var channel: RadioChannelConfig?

  public init(
    snr: Double?,
    rssi: Int?,
    rawPayload: Data,
    routeType: RouteType,
    payloadType: PayloadType,
    payloadVersion: UInt8,
    payloadTypeBits: UInt8,
    transportCode: Data?,
    pathLength: UInt8,
    pathNodes: [UInt8],
    packetPayload: Data,
    senderPubkeyPrefix: Data? = nil,
    recipientPubkeyPrefix: Data? = nil,
    seq: UInt32? = nil,
    epoch: UInt32? = nil,
    radioAge: Duration? = nil,
    isBackfill: Bool = false,
    channel: RadioChannelConfig? = nil
  ) {
    self.snr = snr
    self.rssi = rssi
    self.rawPayload = rawPayload
    self.routeType = routeType
    self.payloadType = payloadType
    self.payloadVersion = payloadVersion
    self.payloadTypeBits = payloadTypeBits
    self.transportCode = transportCode
    self.pathLength = pathLength
    self.pathNodes = pathNodes
    self.packetPayload = packetPayload
    self.senderPubkeyPrefix = senderPubkeyPrefix
    self.recipientPubkeyPrefix = recipientPubkeyPrefix
    self.seq = seq
    self.epoch = epoch
    self.radioAge = radioAge
    self.isBackfill = isBackfill
    self.channel = channel
    packetHash = Self.computePacketHash(from: packetPayload)
  }

  /// This packet with its RX_SYNC position set (every other field unchanged).
  public func withRxSync(seq: UInt32, epoch: UInt32, radioAge: Duration?, isBackfill: Bool) -> ParsedRxLogData {
    ParsedRxLogData(
      snr: snr,
      rssi: rssi,
      rawPayload: rawPayload,
      routeType: routeType,
      payloadType: payloadType,
      payloadVersion: payloadVersion,
      payloadTypeBits: payloadTypeBits,
      transportCode: transportCode,
      pathLength: pathLength,
      pathNodes: pathNodes,
      packetPayload: packetPayload,
      senderPubkeyPrefix: senderPubkeyPrefix,
      recipientPubkeyPrefix: recipientPubkeyPrefix,
      seq: seq,
      epoch: epoch,
      radioAge: radioAge,
      isBackfill: isBackfill,
      channel: channel
    )
  }

  /// Compute SHA256 hash of packetPayload, return first 8 bytes as hex.
  public static func computePacketHash(from packetPayload: Data) -> String {
    let hash = SHA256.hash(data: packetPayload)
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}
