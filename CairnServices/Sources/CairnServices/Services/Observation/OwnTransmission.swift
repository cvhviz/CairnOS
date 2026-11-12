import CryptoKit
import Foundation
import MeshCore

// What this radio sent lately. The radio reports nothing it transmits (its RX log is
// receive-only), so the commands the app writes to it, the radio's answer to each write, and
// the messages its own UI reports sending are all there is to recognise a repeater's echo of our
// own packet by.

/// One packet this radio was asked to send, as far as its command (or the radio's own report of a
/// message sent from its UI) says, with the radio's answer to it.
public struct OwnTransmission: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// A direct message, or a CLI command (`isPlainText` false), to `destination`.
    case directMessage
    case channelMessage
    /// Binary data on a channel (`sendChannelData`).
    case channelData
    /// A request (status, telemetry, a binary request, a path discovery) to `destination`.
    case request
    /// A login or anonymous request: the packet carries this radio's whole key.
    case anonRequest
    case trace
    case advert
    case control
    case other
  }

  /// How the radio said it sent the packet (`RESP_CODE_SENT`'s route flag).
  public enum Route: Sendable, Equatable {
    case flood
    case direct
  }

  /// Unique within the ``OwnTransmissionService`` that holds it (not the session's write id,
  /// which starts again on each connection).
  public let id: UInt64
  public let kind: Kind
  /// The packet type the send goes out as on air.
  public let payloadType: PayloadType
  /// When the command was written to the radio (or the radio reported sending it).
  public let writtenAt: Date
  /// The recipient's key as far as the command carries it: 6 bytes for a message, 32 otherwise.
  public var destination: Data?
  public var channelIndex: UInt8?
  /// The sender's timestamp a message carries (the app's, for a plain message).
  public var timestamp: UInt32?
  public var text: String?
  public var attempt: UInt8 = 0
  public var isPlainText = false
  /// A trace's tag, or a node discovery's.
  public var tag: UInt32?
  /// The radio's answer to the write; nil until it answers (and for a message its UI sent).
  public var outcome: TransmissionOutcome?
  /// Flood or direct, from the radio's `RESP_CODE_SENT`.
  public var route: Route?
  /// The four ack bytes the radio said it expects back (`RESP_CODE_SENT`, or the ack a message
  /// sent from its own UI expects), as the ack packet carries them.
  public var radioExpectedAck: Data?
  /// Packet hashes of RX log entries proven to be this send (``EchoMatch/Confidence/exact``), so
  /// copies of it passed on by other repeaters match by hash.
  public var provenPacketHashes: Set<String> = []
  /// Sent from the radio's own UI (Cairn 0xC2/0xC3), not written by the app.
  public var isFromRadioUI = false

  public init(
    id: UInt64,
    kind: Kind,
    payloadType: PayloadType,
    writtenAt: Date,
    destination: Data? = nil,
    channelIndex: UInt8? = nil,
    timestamp: UInt32? = nil,
    text: String? = nil,
    attempt: UInt8 = 0,
    isPlainText: Bool = false,
    tag: UInt32? = nil,
    outcome: TransmissionOutcome? = nil,
    route: Route? = nil,
    radioExpectedAck: Data? = nil,
    provenPacketHashes: Set<String> = [],
    isFromRadioUI: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.payloadType = payloadType
    self.writtenAt = writtenAt
    self.destination = destination
    self.channelIndex = channelIndex
    self.timestamp = timestamp
    self.text = text
    self.attempt = attempt
    self.isPlainText = isPlainText
    self.tag = tag
    self.outcome = outcome
    self.route = route
    self.radioExpectedAck = radioExpectedAck
    self.provenPacketHashes = provenPacketHashes
    self.isFromRadioUI = isFromRadioUI
  }

  // MARK: - Reading commands

  /// The control type of a node discovery request (`CTL_TYPE_NODE_DISCOVER_REQ`, high nibble).
  public static let discoverRequest: UInt8 = 0x80
  /// The control type of a node discovery answer (`CTL_TYPE_NODE_DISCOVER_RESP`, high nibble).
  public static let discoverResponse: UInt8 = 0x90

  /// Reads a command written to the radio; nil for one that sends nothing over the air.
  /// Keeps no password: a login's is left in the command.
  public static func parse(command: Data, id: UInt64, at date: Date) -> OwnTransmission? {
    let bytes = [UInt8](command)
    guard let code = bytes.first.flatMap(CommandCode.init(rawValue:)) else { return nil }
    func key(_ range: Range<Int>) -> Data? {
      bytes.count >= range.upperBound ? Data(bytes[range]) : nil
    }
    func uint32(at index: Int) -> UInt32? {
      guard bytes.count >= index + 4 else { return nil }
      return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
        | UInt32(bytes[index + 3]) << 24
    }
    switch code {
    case .sendMessage:
      // type, attempt, timestamp (4), recipient prefix (6), text
      guard bytes.count >= 13 else { return nil }
      return OwnTransmission(
        id: id, kind: .directMessage, payloadType: .textMessage, writtenAt: date,
        destination: key(7..<13),
        timestamp: uint32(at: 3),
        text: String(decoding: bytes[13...].prefix { $0 != 0 }, as: UTF8.self),
        attempt: bytes[2],
        isPlainText: bytes[1] == 0
      )
    case .sendChannelMessage:
      // type, channel, timestamp (4), text
      guard bytes.count >= 7 else { return nil }
      return OwnTransmission(
        id: id, kind: .channelMessage, payloadType: .groupText, writtenAt: date,
        channelIndex: bytes[2],
        timestamp: uint32(at: 3),
        text: String(decoding: bytes[7...], as: UTF8.self)
      )
    case .sendStatusRequest, .binaryRequest:
      guard let destination = key(1..<33) else { return nil }
      return OwnTransmission(id: id, kind: .request, payloadType: .request, writtenAt: date, destination: destination)
    case .pathDiscovery:
      // A flood request (for basic telemetry) whose answer carries the route both ways.
      guard let destination = key(2..<34) else { return nil }
      return OwnTransmission(id: id, kind: .request, payloadType: .request, writtenAt: date, destination: destination)
    case .getSelfTelemetry:
      guard let destination = key(4..<36) else { return nil }
      return OwnTransmission(id: id, kind: .request, payloadType: .request, writtenAt: date, destination: destination)
    case .sendLogin, .sendAnonReq:
      guard let destination = key(1..<33) else { return nil }
      return OwnTransmission(id: id, kind: .anonRequest, payloadType: .anonRequest, writtenAt: date, destination: destination)
    case .sendTrace:
      guard let tag = uint32(at: 1) else { return nil }
      return OwnTransmission(id: id, kind: .trace, payloadType: .trace, writtenAt: date, tag: tag)
    case .sendAdvertisement, .shareContact:
      return OwnTransmission(id: id, kind: .advert, payloadType: .advert, writtenAt: date)
    case .sendControlData:
      // type (0x80: node discovery), filter, tag (4), since
      let isDiscover = bytes.count >= 7 && bytes[1] & 0xF0 == discoverRequest
      return OwnTransmission(
        id: id, kind: .control, payloadType: .control, writtenAt: date, tag: isDiscover ? uint32(at: 3) : nil
      )
    case .sendChannelData:
      // channel, path length, then the data
      guard bytes.count >= 2 else { return nil }
      return OwnTransmission(id: id, kind: .channelData, payloadType: .groupData, writtenAt: date, channelIndex: bytes[1])
    case .sendRawData, .sendRawPacket:
      return OwnTransmission(id: id, kind: .other, payloadType: .rawCustom, writtenAt: date)
    default:
      // A logout only ends the session on the radio.
      return nil
    }
  }

  /// A message composed on the radio's own UI, as its echo reports it (Cairn 0xC2/0xC3): a direct
  /// message (with the ack it expects) or a channel message. Nil for a delivery update.
  public init?(radioSent message: RadioSentMessage, id: UInt64, at date: Date) {
    switch message.kind {
    case .direct:
      self.init(
        id: id, kind: .directMessage, payloadType: .textMessage, writtenAt: date,
        destination: message.destination.prefix(6),
        timestamp: message.timestamp,
        text: message.text,
        isPlainText: true,
        radioExpectedAck: message.ackCode != 0 ? Self.ackBytes(message.ackCode) : nil,
        isFromRadioUI: true
      )
    case .channel:
      self.init(
        id: id, kind: .channelMessage, payloadType: .groupText, writtenAt: date,
        channelIndex: message.channelIndex,
        timestamp: message.timestamp,
        text: message.text,
        isFromRadioUI: true
      )
    case .statusUpdate:
      return nil
    }
  }

  // MARK: - The radio's answer

  /// The radio refused the command, so nothing went out.
  public var isRejected: Bool {
    if case .rejected = outcome { return true }
    return false
  }

  /// This send with the radio's answer to its write applied: a `RESP_CODE_SENT` says how it went
  /// out and the ack it expects back.
  public mutating func apply(_ outcome: TransmissionOutcome) {
    self.outcome = outcome
    guard case let .sent(info) = outcome else { return }
    route = info.route == 0 ? .direct : .flood
    if info.expectedAck.count >= 4 {
      radioExpectedAck = Data(info.expectedAck.prefix(4))
    }
  }

  // MARK: - Acks

  /// Whether `ack` (four bytes as the ack packet carries them) answers this direct message: the
  /// ack the radio said it expects, else the one its recipient computes.
  public func isAnswered(by ack: Data, senderKey: Data?) -> Bool {
    guard kind == .directMessage else { return false }
    if let radioExpectedAck, radioExpectedAck == ack { return true }
    return senderKey.flatMap { expectedAck(senderKey: $0) } == ack
  }

  /// The ack the recipient of this plain direct message sends back: the first four bytes of
  /// SHA-256 over the timestamp, the attempt (low two bits), the text and the sender's whole key
  /// (`BaseChatMesh::composeMsgPacket`).
  public func expectedAck(senderKey: Data) -> Data? {
    guard kind == .directMessage, isPlainText, let timestamp, let text, senderKey.count == 32 else { return nil }
    var data = Data()
    withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
    data.append(attempt & 0x03)
    data.append(contentsOf: Array(text.utf8))
    data.append(senderKey)
    return Data(SHA256.hash(data: data).prefix(4))
  }

  static func ackBytes(_ code: UInt32) -> Data {
    withUnsafeBytes(of: code.littleEndian) { Data($0) }
  }

  // MARK: - Neighbour scans

  /// The CLI command that has a repeater look for its neighbours: it sends a zero-hop node
  /// discovery of its own, which this radio may overhear.
  public static let neighbourScanCommand = "discover.neighbors"

  public var isNeighbourScan: Bool {
    kind == .directMessage && !isPlainText
      && text?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.neighbourScanCommand
  }
}

/// A path discovery's answer as the radio passes it on (`PUSH_CODE_PATH_DISCOVERY_RESPONSE`
/// 0x8D): the route our request took out to the node and the one its reply took back, each
/// oldest hop first.
public struct OwnPathDiscovery: Sendable, Equatable {
  public let contactPrefix: Data
  public let outHops: [Data]
  public let inHops: [Data]
  public let at: Date

  public init(contactPrefix: Data, outHops: [Data], inHops: [Data], at: Date) {
    self.contactPrefix = contactPrefix
    self.outHops = outHops
    self.inHops = inHops
    self.at = at
  }

  public init(_ info: PathInfo, at: Date) {
    self.init(
      contactPrefix: info.publicKeyPrefix,
      outHops: Self.hops(info.outPath, pathLength: info.outPathLength),
      inHops: Self.hops(info.inPath, pathLength: info.inPathLength),
      at: at
    )
  }

  /// A path's hops, oldest first, split by the hash size its encoded length gives.
  public static func hops(_ path: Data, pathLength: UInt8) -> [Data] {
    guard let decoded = decodePathLen(pathLength), decoded.byteLength > 0 else { return [] }
    let bytes = [UInt8](path.prefix(decoded.byteLength))
    return stride(from: 0, to: bytes.count - decoded.hashSize + 1, by: decoded.hashSize).map {
      Data(bytes[$0..<($0 + decoded.hashSize)])
    }
  }
}
