import Foundation
import MeshCore

/// An RX log entry this radio's own send explains.
public struct EchoMatch: Sendable, Equatable {
  /// How sure the match is.
  public enum Confidence: Sendable, Equatable {
    /// The packet's content proves it: a decrypted text that matches what we sent, our own signed
    /// advert, our trace or node discovery tag, the ack our message expects, or the hash of a
    /// packet already proven ours.
    case exact
    /// Only the source and destination bytes and the timing say so (requests, logins, an
    /// undecrypted direct message, channel data).
    case probable
  }

  /// What the entry is to the send.
  public enum Relation: Sendable, Equatable {
    /// Our own packet, passed back by a repeater: its first relay heard this radio.
    case echo
    /// A reply the send's recipient made to it (an ack, an answer to our node discovery): proof
    /// the send arrived, not that a repeater passed on our own packet.
    case answer
  }

  public let sendID: UInt64
  public let confidence: Confidence
  public let relation: Relation

  public init(sendID: UInt64, confidence: Confidence, relation: Relation) {
    self.sendID = sendID
    self.confidence = confidence
    self.relation = relation
  }
}

/// Matches RX log entries to what this radio sent lately (``OwnTransmission``). Pure: the same
/// entry and sends always give the same answer, so the RX Log list, the Traffic map and Scan for
/// Nodes' "hears you" agree.
public enum OwnTransmissionMatcher {
  /// How long after a send its echoes are taken for ours: repeats come within seconds, a slow
  /// flood's within a minute, and a message retried by the app is sent again (a new command).
  public static let echoWindow: TimeInterval = 120
  /// How far an entry may seem to arrive before its send was written (the two clocks are read
  /// on different queues).
  public static let earlyTolerance: TimeInterval = 2
  /// How soon after we send channel data its repeats come back. A channel's data carries no
  /// timestamp or text to tell ours from another node's, so the window is kept short.
  public static let channelDataWindow: TimeInterval = 30
  /// How far apart a path discovery's answer and its RX log entry may arrive.
  public static let discoveryWindow: TimeInterval = 15
  /// How soon after we ask a repeater to scan for neighbours its own node discovery goes out.
  public static let neighbourScanWindow: TimeInterval = 10

  /// The send `entry` is an echo of, or a reply to; nil when nothing this radio sent explains it.
  ///
  /// - Parameters:
  ///   - sends: What this radio sent lately, oldest first. A send the radio refused never matches.
  ///   - selfKey: This radio's public key (32 bytes), when known.
  ///   - window: How long after a send its echoes are looked for. A trace's or node discovery's
  ///     tag, and a hash already proven ours, match across every send held: each is proof alone.
  public static func match(
    _ entry: RxLogEntryDTO,
    in sends: [OwnTransmission],
    selfKey: Data?,
    window: TimeInterval = echoWindow
  ) -> EchoMatch? {
    let live = sends.filter { !$0.isRejected }
    guard !live.isEmpty else { return nil }

    if let proven = live.last(where: { $0.provenPacketHashes.contains(entry.packetHash) }) {
      return EchoMatch(sendID: proven.id, confidence: .exact, relation: relation(of: entry))
    }

    let recent = Array(live.reversed().lazy.filter {
      let age = entry.receivedAt.timeIntervalSince($0.writtenAt)
      return age >= -earlyTolerance && age <= window
    })
    let own = selfKey.flatMap { $0.isEmpty ? nil : $0 }
    let bytes = [UInt8](entry.packetPayload)

    func exact(_ send: OwnTransmission?, _ relation: EchoMatch.Relation = .echo) -> EchoMatch? {
      send.map { EchoMatch(sendID: $0.id, confidence: .exact, relation: relation) }
    }
    func probable(_ send: OwnTransmission?) -> EchoMatch? {
      send.map { EchoMatch(sendID: $0.id, confidence: .probable, relation: .echo) }
    }

    switch entry.payloadType {
    case .groupText:
      // Our channel message by its channel, timestamp and text, as Heard Repeats matches them.
      guard entry.decryptStatus == .success, let channel = entry.channelIndex,
            let timestamp = entry.senderTimestamp, let decoded = entry.decodedText,
            let (_, text) = ChannelMessageFormat.parse(decoded) else { return nil }
      return exact(recent.first {
        $0.kind == .channelMessage && $0.channelIndex == channel && $0.timestamp == timestamp
          && $0.text?.trimmingCharacters(in: .whitespaces) == text
      })

    case .textMessage:
      if entry.decryptStatus == .success {
        return exact(ownDirectMessage(entry, in: recent, selfKey: own))
      }
      // Undecrypted: the sender byte alone is shared by about one node in 256; with the
      // recipient's and a send to it moments ago, a stranger's packet is all but ruled out.
      return probable(byteMatch(entry, kind: .directMessage, in: recent, selfKey: own))

    case .request:
      return probable(byteMatch(entry, kind: .request, in: recent, selfKey: own))

    case .anonRequest:
      // A one-byte recipient hash, then the sender's whole key: ours, to a node just sent a login.
      guard bytes.count >= 33, let own, Data(bytes[1..<33]).prefix(own.count) == own else { return nil }
      return probable(recent.first { $0.kind == .anonRequest && $0.destination?.first == bytes[0] })

    case .groupData:
      guard entry.decryptStatus == .success, let channel = entry.channelIndex else { return nil }
      return probable(recent.first {
        $0.kind == .channelData && $0.channelIndex == channel
          && entry.receivedAt.timeIntervalSince($0.writtenAt) <= channelDataWindow
      })

    case .advert:
      // Our own advert, signed with our key: no one else can sign it.
      guard let own, own.count == AdvertPushRecovery.SignedAdvert.publicKeySize,
            let advert = AdvertPushRecovery.SignedAdvert(payload: entry.packetPayload),
            advert.publicKey == own, advert.isSignatureValid else { return nil }
      return exact(recent.first { $0.kind == .advert })

    case .trace:
      guard bytes.count >= 4 else { return nil }
      let tag = uint32(bytes, at: 0)
      return exact(live.last { $0.kind == .trace && $0.tag == tag })

    case .control:
      // A node discovery: type, filter or SNR, tag (4), ...
      guard bytes.count >= 6 else { return nil }
      let tag = uint32(bytes, at: 2)
      let send = live.last { $0.kind == .control && $0.tag == tag }
      switch bytes[0] & 0xF0 {
      case OwnTransmission.discoverRequest:
        return exact(send)
      case OwnTransmission.discoverResponse:
        return exact(send, .answer)
      default:
        return nil
      }

    case .ack, .multipart:
      guard let ack = ackBytes(of: entry) else { return nil }
      let key = own.flatMap { $0.count == 32 ? $0 : nil }
      return exact(recent.first { $0.isAnswered(by: ack, senderKey: key) }, .answer)

    default:
      return nil
    }
  }

  /// What `entry` is to a send it matches by hash: an ack or a discovery answer replies to it,
  /// anything else is the send itself passed back.
  public static func relation(of entry: RxLogEntryDTO) -> EchoMatch.Relation {
    switch entry.payloadType {
    case .ack, .multipart:
      return .answer
    case .control:
      return entry.packetPayload.first.map { $0 & 0xF0 == OwnTransmission.discoverResponse } == true ? .answer : .echo
    default:
      return .echo
    }
  }

  // MARK: - Direct messages

  /// The direct message we sent that a decrypted one is: the contact whose key decrypted it is
  /// the one we sent to, its source byte is ours and its destination byte the contact's, and its
  /// text (and, for a plain message, its timestamp) is what we sent. A CLI command's timestamp
  /// is the radio's own clock, so only its text is compared.
  private static func ownDirectMessage(
    _ entry: RxLogEntryDTO,
    in sends: [OwnTransmission],
    selfKey: Data?
  ) -> OwnTransmission? {
    guard let peer = entry.peerPublicKey, !peer.isEmpty, let own = selfKey,
          let (recipient, sender) = peerHashes(of: entry),
          own.prefix(sender.count) == sender, peer.prefix(recipient.count) == recipient,
          let text = entry.decodedText.map(normalized) else { return nil }
    return sends.first { send in
      guard send.kind == .directMessage, let destination = send.destination, !destination.isEmpty,
            peer.prefix(destination.count) == destination,
            send.text.map(normalized) == text else { return false }
      return !send.isPlainText || send.timestamp == entry.senderTimestamp
    }
  }

  private static func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
  }

  /// A send of `kind` to the node whose key starts with the packet's recipient byte, from this
  /// radio by its sender byte.
  private static func byteMatch(
    _ entry: RxLogEntryDTO,
    kind: OwnTransmission.Kind,
    in sends: [OwnTransmission],
    selfKey: Data?
  ) -> OwnTransmission? {
    guard let (recipient, sender) = peerHashes(of: entry), let own = selfKey,
          own.prefix(sender.count) == sender else { return nil }
    return sends.first {
      $0.kind == kind && $0.destination.map { $0.prefix(recipient.count) == recipient } == true
    }
  }

  // MARK: - Replies

  /// The repeater that sent a node discovery this radio overheard, and the discovery's tag: one
  /// we asked moments before to scan for its neighbours (``OwnTransmission/isNeighbourScan``).
  /// The request itself names no sender, and isn't passed on, so it came straight from a
  /// neighbour.
  public static func discoverRequester(
    for entry: RxLogEntryDTO,
    in sends: [OwnTransmission]
  ) -> (tag: UInt32, repeater: Data)? {
    // Type, filter, tag (4), since.
    let bytes = [UInt8](entry.packetPayload)
    guard entry.payloadType == .control, !entry.isFlood, entry.pathNodes.isEmpty,
          bytes.count >= 6, bytes[0] & 0xF0 == OwnTransmission.discoverRequest else { return nil }
    guard let scan = sends.last(where: {
      !$0.isRejected && $0.isNeighbourScan
        && (-earlyTolerance...neighbourScanWindow).contains(entry.receivedAt.timeIntervalSince($0.writtenAt))
    }), let repeater = scan.destination else { return nil }
    return (uint32(bytes, at: 2), repeater)
  }

  /// The path discovery answer a PATH packet to this radio carries, when the radio has passed
  /// the answer on: from the node the discovery was for, at about the same moment.
  public static func pathDiscovery(
    for entry: RxLogEntryDTO,
    in discoveries: [OwnPathDiscovery],
    selfKey: Data?
  ) -> OwnPathDiscovery? {
    guard entry.payloadType == .path, let (recipient, sender) = peerHashes(of: entry),
          let own = selfKey, !own.isEmpty, own.prefix(recipient.count) == recipient else { return nil }
    return discoveries.last {
      $0.contactPrefix.prefix(sender.count) == sender
        && abs(entry.receivedAt.timeIntervalSince($0.at)) <= discoveryWindow
    }
  }

  // MARK: - Bytes

  /// The recipient and sender hashes a peer packet (types 0, 1, 2, 8) starts with.
  public static func peerHashes(of entry: RxLogEntryDTO) -> (recipient: Data, sender: Data)? {
    let hashSize = 1
    let payload = entry.packetPayload
    guard payload.count >= hashSize * 2 else { return nil }
    let start = payload.startIndex
    return (
      Data(payload[start..<start + hashSize]),
      Data(payload[(start + hashSize)..<(start + hashSize * 2)])
    )
  }

  /// The four ack bytes an ack carries, or a multipart ack after its type byte.
  static func ackBytes(of entry: RxLogEntryDTO) -> Data? {
    let bytes = [UInt8](entry.packetPayload)
    switch entry.payloadType {
    case .ack where bytes.count >= 4:
      return Data(bytes[0..<4])
    case .multipart where bytes.count >= 5 && bytes[0] & 0x0F == PayloadType.ack.rawValue:
      return Data(bytes[1..<5])
    default:
      return nil
    }
  }

  private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
    UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
  }
}
