// CairnServices/Sources/CairnServices/Models/RxLogEntry.swift
import Foundation
import MeshCore
import SwiftData

/// SwiftData model for persisted RX log packets.
@Model
final class RxLogEntry {
  #Index<RxLogEntry>(
    [\.channelIndex, \.senderTimestamp],
    [\.radioID, \.receivedAt],
    [\.radioID, \.channelKey, \.receivedAt]
  )

  @Attribute(.unique)
  var id: UUID

  var radioID: UUID

  var receivedAt: Date

  // From MeshCore ParsedRxLogData
  var snr: Double?
  var rssi: Int?
  var routeType: Int
  var payloadType: Int
  var payloadVersion: Int
  var transportCode: Data?
  var pathLength: Int
  var pathNodes: Data // Raw bytes, 1 byte per hop
  var packetPayload: Data
  var rawPayload: Data

  /// Correlation key for "heard repeats"
  var packetHash: String

  // App-level decoding
  var channelIndex: Int?
  var channelName: String?
  var decryptStatus: Int
  var fromContactName: String?
  var toContactName: String?

  /// Sender's timestamp from decrypted payload (Unix epoch seconds).
  /// Only available for successfully decrypted channel messages.
  var senderTimestamp: Int?

  /// Confident single flood-region name, or nil when unresolved or ambiguous.
  /// Local-only. Read via `RegionScopeSemantics.coalesce` with matches.
  var regionScope: String?

  /// Sorted multi-match set for this packet. Local-only.
  var regionScopeMatches: [String] = []

  /// Raw 4-bit payload-type nibble from the wire header. Persisted so the
  /// region resolver can replay the exact firmware HMAC input on back-fill,
  /// even for header values that map to `PayloadType.unknown`.
  var payloadTypeBits: Int = 0

  /// The radio journal's epoch and record number when the packet came over Cairn RX_SYNC;
  /// nil for a stock 0x88 frame.
  var radioEpoch: Int?
  var radioSeq: Int?

  /// The channel the radio was on when it received the packet (``ChannelKey``: frequency,
  /// bandwidth and spreading factor), as the session stamped it from the radio's SELF_INFO. Nil
  /// for an entry stored before channels were recorded, or one the session couldn't vouch for
  /// (a retune not yet confirmed, an RX_SYNC record older than the confirmed channel).
  var channelKey: String?
  /// The radio's coding rate on that channel, kept for display; not part of the key.
  var channelCodingRate: Int?

  // Privacy: Never persisted — decrypted on demand
  @Transient
  var decodedText: String?

  init(
    id: UUID = UUID(),
    radioID: UUID,
    receivedAt: Date = Date(),
    snr: Double? = nil,
    rssi: Int? = nil,
    routeType: Int,
    payloadType: Int,
    payloadVersion: Int,
    transportCode: Data? = nil,
    pathLength: Int,
    pathNodes: Data,
    packetPayload: Data,
    rawPayload: Data,
    packetHash: String,
    channelIndex: Int? = nil,
    channelName: String? = nil,
    decryptStatus: Int = DecryptStatus.notApplicable.rawValue,
    fromContactName: String? = nil,
    toContactName: String? = nil,
    senderTimestamp: Int? = nil,
    regionScope: String? = nil,
    regionScopeMatches: [String] = [],
    payloadTypeBits: Int = 0,
    radioEpoch: Int? = nil,
    radioSeq: Int? = nil,
    channelKey: String? = nil,
    channelCodingRate: Int? = nil
  ) {
    self.id = id
    self.radioID = radioID
    self.receivedAt = receivedAt
    self.snr = snr
    self.rssi = rssi
    self.routeType = routeType
    self.payloadType = payloadType
    self.payloadVersion = payloadVersion
    self.transportCode = transportCode
    self.pathLength = pathLength
    self.pathNodes = pathNodes
    self.packetPayload = packetPayload
    self.rawPayload = rawPayload
    self.packetHash = packetHash
    self.channelIndex = channelIndex
    self.channelName = channelName
    self.decryptStatus = decryptStatus
    self.fromContactName = fromContactName
    self.toContactName = toContactName
    self.senderTimestamp = senderTimestamp
    self.regionScope = regionScope
    self.regionScopeMatches = regionScopeMatches
    self.payloadTypeBits = payloadTypeBits
    self.radioEpoch = radioEpoch
    self.radioSeq = radioSeq
    self.channelKey = channelKey
    self.channelCodingRate = channelCodingRate
  }
}

/// Sendable DTO for cross-actor transfer of RxLogEntry data.
public struct RxLogEntryDTO: Sendable, Identifiable, Equatable, Hashable {
  public let id: UUID
  public var radioID: UUID
  public let receivedAt: Date
  public let snr: Double?
  public let rssi: Int?
  public let routeType: RouteType
  public let payloadType: PayloadType
  public let payloadVersion: UInt8
  public let transportCode: Data?
  public let pathLength: UInt8
  public let pathNodes: Data
  public let packetPayload: Data
  public let rawPayload: Data
  public let packetHash: String

  /// Channel attribution. Mutable so re-decryption of older entries can
  /// record which channel's secret matched.
  public var channelIndex: UInt8?
  public var channelName: String?

  /// Mutable so re-decryption with newly available keys can mark success.
  public var decryptStatus: DecryptStatus
  public let fromContactName: String?
  public let toContactName: String?

  /// Sender's timestamp from decrypted payload (Unix epoch seconds).
  /// Only available for successfully decrypted channel messages.
  /// Mutable to allow updating during re-decryption of older entries.
  public var senderTimestamp: UInt32?

  /// Confident single flood-region name, or nil when unresolved or ambiguous.
  /// Local-only. Read via `RegionScopeSemantics.coalesce` with matches.
  public let regionScope: String?

  /// Sorted multi-match set. Local-only.
  public let regionScopeMatches: [String]

  /// Raw 4-bit payload-type nibble from the wire header (matches firmware
  /// HMAC input). Persisted alongside region fields for back-fill replay.
  public let payloadTypeBits: UInt8

  /// The radio journal's epoch when the packet came over Cairn RX_SYNC; nil for a stock 0x88 frame.
  public let radioEpoch: UInt32?

  /// The packet's record number within ``radioEpoch``; nil for a stock 0x88 frame.
  public let radioSeq: UInt32?

  /// The channel the radio was on when it received this packet, as the session stamped it from
  /// SELF_INFO. Nil when not recorded: an entry stored before channels were recorded, or one the
  /// session couldn't vouch for. Such an entry is never evidence of which nodes are on a channel.
  public let channel: RadioChannelConfig?

  /// ``channel``'s key. A stored entry keeps the key and coding rate, so ``channel`` is rebuilt
  /// from them.
  public let channelKey: ChannelKey?

  /// Transient: fetched again after a frame went missing, so it reaches the stream late and
  /// out of order. Never persisted (false for a stored entry).
  public var isBackfill: Bool

  /// Transient - set by UI layer after decryption
  public var decodedText: String?

  /// Transient: the contact whose key decrypted a direct message (its sender, or the recipient
  /// of one this radio sent), as its Ed25519 public key. Set with `decodedText`.
  public var peerPublicKey: Data?

  /// Initialize from SwiftData model.
  init(from model: RxLogEntry) {
    id = model.id
    radioID = model.radioID
    receivedAt = model.receivedAt
    snr = model.snr
    rssi = model.rssi
    // Narrow each stored Int through the failable initializer so a corrupt or
    // out-of-range row falls back instead of trapping inside the ModelActor.
    routeType = UInt8(exactly: model.routeType).flatMap(RouteType.init(rawValue:)) ?? .flood
    payloadType = UInt8(exactly: model.payloadType).flatMap(PayloadType.init(rawValue:)) ?? .unknown
    payloadVersion = UInt8(exactly: model.payloadVersion) ?? 0
    transportCode = model.transportCode
    pathLength = UInt8(exactly: model.pathLength) ?? 0
    pathNodes = model.pathNodes
    packetPayload = model.packetPayload
    rawPayload = model.rawPayload
    packetHash = model.packetHash
    channelIndex = model.channelIndex.flatMap { UInt8(exactly: $0) }
    channelName = model.channelName
    decryptStatus = DecryptStatus(rawValue: model.decryptStatus) ?? .notApplicable
    fromContactName = model.fromContactName
    toContactName = model.toContactName
    senderTimestamp = model.senderTimestamp.flatMap { UInt32(exactly: $0) }
    regionScope = model.regionScope
    regionScopeMatches = model.regionScopeMatches
    payloadTypeBits = UInt8(model.payloadTypeBits & 0x0F)
    radioEpoch = model.radioEpoch.flatMap { UInt32(exactly: $0) }
    radioSeq = model.radioSeq.flatMap { UInt32(exactly: $0) }
    channelKey = model.channelKey.map(ChannelKey.init(rawValue:))
    channel = channelKey.flatMap { key in
      RadioChannelConfig(key: key).map { config in
        RadioChannelConfig(
          frequencyKHz: config.frequencyKHz,
          bandwidthHz: config.bandwidthHz,
          spreadingFactor: config.spreadingFactor,
          codingRate: model.channelCodingRate.flatMap { UInt8(exactly: $0) } ?? 0
        )
      }
    }
    isBackfill = false
    decodedText = model.decodedText
  }

  /// Initialize from ParsedRxLogData (for new entries). The RX_SYNC position (epoch, seq,
  /// backfill) and the channel stamp come from `parsed`; a non-nil `channel` replaces the stamp.
  public init(
    id: UUID = UUID(),
    radioID: UUID,
    receivedAt: Date = Date(),
    from parsed: ParsedRxLogData,
    channelIndex: UInt8? = nil,
    channelName: String? = nil,
    decryptStatus: DecryptStatus = .notApplicable,
    fromContactName: String? = nil,
    toContactName: String? = nil,
    senderTimestamp: UInt32? = nil,
    regionScope: String? = nil,
    regionScopeMatches: [String] = [],
    decodedText: String? = nil,
    peerPublicKey: Data? = nil,
    channel: RadioChannelConfig? = nil
  ) {
    self.id = id
    self.radioID = radioID
    self.receivedAt = receivedAt
    snr = parsed.snr
    rssi = parsed.rssi
    routeType = parsed.routeType
    payloadType = parsed.payloadType
    payloadVersion = parsed.payloadVersion
    transportCode = parsed.transportCode
    pathLength = parsed.pathLength
    pathNodes = Data(parsed.pathNodes)
    packetPayload = parsed.packetPayload
    rawPayload = parsed.rawPayload
    packetHash = parsed.packetHash
    self.channelIndex = channelIndex
    self.channelName = channelName
    self.decryptStatus = decryptStatus
    self.fromContactName = fromContactName
    self.toContactName = toContactName
    self.senderTimestamp = senderTimestamp
    self.regionScope = regionScope
    self.regionScopeMatches = regionScopeMatches
    payloadTypeBits = parsed.payloadTypeBits
    radioEpoch = parsed.epoch
    radioSeq = parsed.seq
    self.channel = channel ?? parsed.channel
    channelKey = self.channel?.key
    isBackfill = parsed.isBackfill
    self.decodedText = decodedText
    self.peerPublicKey = peerPublicKey
  }

  // MARK: - Computed Properties

  /// Hash size per hop in bytes (1, 2, or 3), derived from pathLength upper 2 bits.
  public var pathHashSize: Int {
    decodePathLen(pathLength)?.hashSize ?? 1
  }

  /// Hop count decoded from pathLength.
  public var hopCount: Int {
    decodePathLen(pathLength)?.hopCount ?? 0
  }

  /// Target node hashes extracted from TRACE payload.
  /// Layout: [tag:4][auth:4][flags:1][hashes...], hash size from flags lower 2 bits.
  public var traceTargetHashes: [Data]? {
    guard payloadType == .trace, packetPayload.count > 9 else { return nil }
    let pathSz = Int(packetPayload[8] & 0x03)
    let hashSize = 1 << pathSz
    let hashBytes = packetPayload.dropFirst(9)
    guard !hashBytes.isEmpty, hashBytes.count % hashSize == 0 else { return nil }
    return stride(from: hashBytes.startIndex, to: hashBytes.endIndex, by: hashSize).map { start in
      Data(hashBytes[start..<start + hashSize])
    }
  }

  /// Sender public key prefix for direct text messages (any route type).
  public var senderPrefix: Data? {
    guard payloadType == .textMessage else { return nil }
    let dmPrefixSize = 1
    guard packetPayload.count >= dmPrefixSize * 2 else { return nil }
    return Data(packetPayload[dmPrefixSize..<dmPrefixSize * 2])
  }

  /// Recipient public key prefix for direct text messages (any route type).
  public var recipientPrefix: Data? {
    guard payloadType == .textMessage else { return nil }
    let dmPrefixSize = 1
    guard packetPayload.count >= dmPrefixSize * 2 else { return nil }
    return Data(packetPayload[0..<dmPrefixSize])
  }

  /// Whether this is a flood-type route.
  public var isFlood: Bool {
    routeType == .flood || routeType == .tcFlood
  }

  // MARK: - Signal Quality

  /// Classified signal quality based on SNR thresholds.
  public var snrQuality: SNRQuality {
    SNRQuality(snr: snr)
  }

  /// SNR mapped to 0-1 for SF Symbol cellularbars variableValue.
  public var snrLevel: Double {
    snrQuality.barLevel
  }

  /// Developer-facing English label for logs; UI uses the app target's localized `SNRQuality.localizedLabel`.
  public var snrQualityLabel: String {
    snrQuality.qualityLabel
  }

  /// Formatted SNR string (no label, includes sign for negative).
  public var snrDisplayString: String? {
    guard let snr else { return nil }
    return snr.formatted(.number.precision(.fractionLength(1))) + " dB"
  }

  /// Route type display - "FLOOD" or "DIRECT" (simplified from TC variants).
  public var routeTypeSimple: String {
    isFlood ? "FLOOD" : "DIRECT"
  }

  // MARK: - Hashable

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
