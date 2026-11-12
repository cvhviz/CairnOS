@testable import CairnServices
import CryptoKit
import Foundation
import MeshCore
import Testing

// MARK: - Fixtures

/// This radio, the contact it talks to, and RX log entries built from stock 0x88 frames.
enum OwnTransmissionFixtures {
  /// This radio's signing key; its public key starts 0x?? (whatever CryptoKit derives), so tests
  /// read the hash bytes from `radioKey` rather than assume them.
  static let radioSigner = Curve25519.Signing.PrivateKey()
  static var radioKey: Data { radioSigner.publicKey.rawRepresentation }
  static var radioHash: UInt8 { radioKey[0] }

  /// The contact we send to: a whole key whose first byte differs from ours.
  static var peerKey: Data {
    var key = Data(repeating: 0x01, count: 32)
    key[0] = radioHash == 0x5E ? 0x5F : 0x5E
    return key
  }

  static var peerHash: UInt8 { peerKey[0] }

  static let base = Date(timeIntervalSince1970: 1_800_000_000)

  /// The RX log copy (0x88) of a packet, as the session dispatches it.
  static func parsed(payloadType: PayloadType, route: UInt8 = StockCompanionFrames.routeFlood, path: [UInt8] = [0xAA], payload: [UInt8]) -> ParsedRxLogData {
    let frame = StockCompanionFrames.logRx(raw: StockCompanionFrames.packet(
      payloadType: payloadType.rawValue, route: route, path: path, payload: payload
    ))
    guard case let .rxLogData(parsed) = PacketParser.parse(frame) else {
      preconditionFailure("not an RX log frame")
    }
    return parsed
  }

  // swiftlint:disable:next function_parameter_count
  static func entry(
    _ payloadType: PayloadType,
    route: UInt8 = StockCompanionFrames.routeFlood,
    path: [UInt8] = [0xAA],
    payload: [UInt8],
    at date: Date = base.addingTimeInterval(5),
    decryptStatus: DecryptStatus = .notApplicable,
    channelIndex: UInt8? = nil,
    senderTimestamp: UInt32? = nil,
    decodedText: String? = nil,
    peerPublicKey: Data? = nil
  ) -> RxLogEntryDTO {
    RxLogEntryDTO(
      radioID: UUID(),
      receivedAt: date,
      from: parsed(payloadType: payloadType, route: route, path: path, payload: payload),
      channelIndex: channelIndex,
      decryptStatus: decryptStatus,
      senderTimestamp: senderTimestamp,
      decodedText: decodedText,
      peerPublicKey: peerPublicKey
    )
  }

  /// A decrypted channel text (the ciphertext bytes differ by `variant`, as each copy's would not;
  /// a different variant stands for a different packet).
  static func channelEcho(text: String, timestamp: UInt32, channel: UInt8 = 1, path: [UInt8] = [0xAA], variant: UInt8 = 0, at date: Date = base.addingTimeInterval(5)) -> RxLogEntryDTO {
    entry(
      .groupText, path: path, payload: [0x11, 0x22, 0x33, variant] + [UInt8](repeating: 0x5C, count: 16), at: date,
      decryptStatus: .success, channelIndex: channel, senderTimestamp: timestamp, decodedText: "Base: \(text)"
    )
  }

  /// A direct message payload: destination hash, source hash, MAC (2), ciphertext.
  static func dmPayload(to destination: UInt8, from source: UInt8, variant: UInt8 = 0) -> [UInt8] {
    [destination, source, 0xC0, variant] + [UInt8](repeating: 0x7E, count: 16)
  }

  /// Mesh::createAdvert: public_key(32), timestamp(4), signature(64) over
  /// `public_key | timestamp | app_data`, then app_data (a chat node named "Base").
  static func advertPayload(signer: Curve25519.Signing.PrivateKey, forged: Bool = false) throws -> [UInt8] {
    let key = Array(signer.publicKey.rawRepresentation)
    let time = withUnsafeBytes(of: UInt32(1_800_000_000).littleEndian) { Array($0) }
    let appData: [UInt8] = [0x81] + Array("Base".utf8)
    var signature = try Array(signer.signature(for: Data(key + time + appData)))
    if forged { signature[0] ^= 0xFF }
    return key + time + signature + appData
  }

  static func send(
    _ kind: OwnTransmission.Kind,
    id: UInt64 = 1,
    payloadType: PayloadType = .textMessage,
    at date: Date = base,
    destination: Data? = nil,
    channelIndex: UInt8? = nil,
    timestamp: UInt32? = nil,
    text: String? = nil,
    isPlainText: Bool = false,
    tag: UInt32? = nil,
    outcome: TransmissionOutcome? = nil
  ) -> OwnTransmission {
    OwnTransmission(
      id: id, kind: kind, payloadType: payloadType, writtenAt: date, destination: destination,
      channelIndex: channelIndex, timestamp: timestamp, text: text, isPlainText: isPlainText, tag: tag, outcome: outcome
    )
  }
}

// MARK: - Reading commands

@Suite("This radio's own transmissions")
struct OwnTransmissionTests {}

extension OwnTransmissionTests {
  @Suite("What the app's commands send")
  struct Parse {
    private typealias F = OwnTransmissionFixtures

    @Test
    func `the commands the app writes are read for what they send`() throws {
      let dm = try #require(OwnTransmission.parse(
        command: PacketBuilder.sendMessage(to: F.peerKey, text: "yo", timestamp: Date(timeIntervalSince1970: 100), attempt: 2),
        id: 1, at: F.base
      ))
      #expect(dm.kind == .directMessage && dm.payloadType == .textMessage)
      #expect(dm.destination == F.peerKey.prefix(6))
      #expect(dm.timestamp == 100 && dm.text == "yo" && dm.attempt == 2 && dm.isPlainText)
      #expect(dm.id == 1 && dm.writtenAt == F.base && dm.outcome == nil)

      let channel = try #require(OwnTransmission.parse(
        command: PacketBuilder.sendChannelMessage(channel: 3, text: "all", timestamp: Date(timeIntervalSince1970: 200)), id: 2, at: F.base
      ))
      #expect(channel.kind == .channelMessage && channel.channelIndex == 3 && channel.timestamp == 200 && channel.text == "all")
      #expect(channel.payloadType == .groupText)

      let login = try #require(OwnTransmission.parse(command: PacketBuilder.sendLogin(to: F.peerKey, password: "secret"), id: 3, at: F.base))
      #expect(login.kind == .anonRequest && login.destination == F.peerKey)
      #expect(login.text == nil, "A login's password isn't kept")

      let trace = try #require(OwnTransmission.parse(
        command: PacketBuilder.sendTrace(tag: 77, authCode: 0, flags: 0, path: Data([0xAA])), id: 4, at: F.base
      ))
      #expect(trace.kind == .trace && trace.tag == 77)

      let discovery = try #require(OwnTransmission.parse(command: PacketBuilder.sendPathDiscovery(to: F.peerKey), id: 5, at: F.base))
      #expect(discovery.kind == .request && discovery.destination == F.peerKey)

      #expect(OwnTransmission.parse(command: PacketBuilder.sendLogout(to: F.peerKey), id: 6, at: F.base) == nil)
    }

    @Test
    func `requests, adverts, discoveries, channel data and raw packets are read too`() throws {
      let status = try #require(OwnTransmission.parse(command: PacketBuilder.sendStatusRequest(to: F.peerKey), id: 1, at: F.base))
      #expect(status.kind == .request && status.destination == F.peerKey)

      let advert = try #require(OwnTransmission.parse(command: PacketBuilder.sendAdvertisement(flood: true), id: 2, at: F.base))
      #expect(advert.kind == .advert && advert.payloadType == .advert)
      let share = try #require(OwnTransmission.parse(command: PacketBuilder.shareContact(publicKey: F.peerKey), id: 3, at: F.base))
      #expect(share.kind == .advert)

      let discover = try #require(OwnTransmission.parse(
        command: PacketBuilder.sendNodeDiscoverRequest(filter: 0x04, tag: 0xDEAD_BEEF), id: 4, at: F.base
      ))
      #expect(discover.kind == .control && discover.tag == 0xDEAD_BEEF)
      let otherControl = try #require(OwnTransmission.parse(
        command: PacketBuilder.sendControlData(type: 0x20, payload: Data([1, 2, 3, 4, 5])), id: 5, at: F.base
      ))
      #expect(otherControl.kind == .control && otherControl.tag == nil, "Only a node discovery carries a tag")

      let data = try #require(OwnTransmission.parse(
        command: PacketBuilder.sendChannelData(channelIndex: 2, dataType: 0xFF00, payload: Data([1, 2, 3])), id: 6, at: F.base
      ))
      #expect(data.kind == .channelData && data.channelIndex == 2)

      let raw = try #require(OwnTransmission.parse(command: PacketBuilder.sendRawData(path: Data(), payload: Data([1])), id: 7, at: F.base))
      #expect(raw.kind == .other)

      let cli = try #require(OwnTransmission.parse(command: PacketBuilder.sendCommand(to: F.peerKey, command: "discover.neighbors"), id: 8, at: F.base))
      #expect(cli.kind == .directMessage && !cli.isPlainText && cli.isNeighbourScan)

      #expect(OwnTransmission.parse(command: Data(), id: 9, at: F.base) == nil)
      #expect(OwnTransmission.parse(command: Data([CommandCode.sendMessage.rawValue, 0, 0]), id: 10, at: F.base) == nil, "Too short")
    }

    @Test
    func `a message sent from the radio's own UI is ours too`() throws {
      let dm = try #require(OwnTransmission(radioSent: RadioSentMessage(
        isLive: true, kind: .direct, destination: Data(F.peerKey.prefix(6)),
        timestamp: 1_700_000_000, ackCode: 0x0403_0201, isDelivered: false, text: "omw"
      ), id: 1, at: F.base))
      #expect(dm.kind == .directMessage && dm.isPlainText && dm.isFromRadioUI)
      #expect(dm.radioExpectedAck == Data([1, 2, 3, 4]))

      let channel = try #require(OwnTransmission(radioSent: RadioSentMessage(
        isLive: true, kind: .channel, destination: Data([1, 0, 0, 0, 0, 0]),
        timestamp: 1_700_000_000, ackCode: 0, isDelivered: false, text: "hello all"
      ), id: 2, at: F.base))
      #expect(channel.kind == .channelMessage && channel.channelIndex == 1 && channel.text == "hello all")

      let update = RadioSentMessage(
        isLive: true, kind: .statusUpdate, destination: Data(repeating: 0, count: 6),
        timestamp: 1, ackCode: 0, isDelivered: true, text: ""
      )
      #expect(OwnTransmission(radioSent: update, id: 3, at: F.base) == nil)
    }

    @Test
    func `a direct message's ack is the hash of its timestamp, attempt, text and sender key`() {
      var send = F.send(.directMessage, destination: Data(repeating: 1, count: 6), timestamp: 0x0102_0304, text: "Hi", isPlainText: true)
      send.attempt = 5
      var hashed = Data([0x04, 0x03, 0x02, 0x01, 0x01]) + Data("Hi".utf8)
      hashed += F.radioKey
      #expect(send.expectedAck(senderKey: F.radioKey) == Data(SHA256.hash(data: hashed).prefix(4)))
      var command = send
      command.isPlainText = false
      #expect(command.expectedAck(senderKey: F.radioKey) == nil, "A CLI command expects no ack")
    }

    @Test
    func `the radio's answer says how the packet went out`() {
      var send = F.send(.directMessage, destination: Data(F.peerKey.prefix(6)), timestamp: 1, text: "hi", isPlainText: true)
      send.apply(.sent(MessageSentInfo(route: 1, expectedAck: Data([9, 8, 7, 6]), suggestedTimeoutMs: 5000)))
      #expect(send.route == .flood && send.radioExpectedAck == Data([9, 8, 7, 6]) && !send.isRejected)
      send.apply(.sent(MessageSentInfo(route: 0, expectedAck: Data([1, 1, 1, 1]), suggestedTimeoutMs: 5000)))
      #expect(send.route == .direct)
      send.apply(.rejected(code: 2))
      #expect(send.isRejected)
    }

    @Test
    func `a path discovery's answer splits each route by its hash size`() {
      #expect(OwnPathDiscovery.hops(Data([1, 2, 3, 4]), pathLength: 0x42) == [Data([1, 2]), Data([3, 4])])
      #expect(OwnPathDiscovery.hops(Data([1, 2, 3]), pathLength: 0x81) == [Data([1, 2, 3])])
      #expect(OwnPathDiscovery.hops(Data(), pathLength: 0xFF).isEmpty, "A flood contact has no path")
    }
  }
}

// MARK: - Matching echoes

extension OwnTransmissionTests {
  @Suite("Which received packets are this radio's own")
  struct Matcher {
    private typealias F = OwnTransmissionFixtures

    private func match(_ entry: RxLogEntryDTO, _ sends: [OwnTransmission], selfKey: Data? = F.radioKey) -> EchoMatch? {
      OwnTransmissionMatcher.match(entry, in: sends, selfKey: selfKey)
    }

    @Test
    func `an echo of our own channel message is exact`() {
      let send = F.send(.channelMessage, id: 7, payloadType: .groupText, channelIndex: 1, timestamp: 1_700_000_000, text: "hello all")
      let echo = F.channelEcho(text: "hello all", timestamp: 1_700_000_000)
      #expect(match(echo, [send]) == EchoMatch(sendID: 7, confidence: .exact, relation: .echo))
      // Someone else's message: another text, another second, another channel.
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_001), [send]) == nil)
      #expect(match(F.channelEcho(text: "hello", timestamp: 1_700_000_000), [send]) == nil)
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000, channel: 2), [send]) == nil)
    }

    @Test
    func `an echo of our direct message, decrypted with its recipient's key, is exact`() {
      let send = F.send(.directMessage, id: 3, destination: Data(F.peerKey.prefix(6)), timestamp: 1_800_000_000, text: "hi there", isPlainText: true)
      let echo = F.entry(
        .textMessage, payload: F.dmPayload(to: F.peerHash, from: F.radioHash),
        decryptStatus: .success, senderTimestamp: 1_800_000_000, decodedText: "hi there", peerPublicKey: F.peerKey
      )
      #expect(match(echo, [send]) == EchoMatch(sendID: 3, confidence: .exact, relation: .echo))
      // Another timestamp is another message.
      let later = F.entry(
        .textMessage, payload: F.dmPayload(to: F.peerHash, from: F.radioHash),
        decryptStatus: .success, senderTimestamp: 1_800_000_009, decodedText: "hi there", peerPublicKey: F.peerKey
      )
      #expect(match(later, [send]) == nil)
    }

    @Test
    func `a direct message from that peer to us is not ours`() {
      let send = F.send(.directMessage, destination: Data(F.peerKey.prefix(6)), timestamp: 1_800_000_000, text: "hi there", isPlainText: true)
      // The peer answering with the very same words: its source byte is the peer's.
      let reply = F.entry(
        .textMessage, payload: F.dmPayload(to: F.radioHash, from: F.peerHash),
        decryptStatus: .success, senderTimestamp: 1_800_000_000, decodedText: "hi there", peerPublicKey: F.peerKey
      )
      #expect(match(reply, [send]) == nil)
    }

    @Test
    func `an undecrypted direct message from our byte to the recipient's is only probable`() {
      let send = F.send(.directMessage, id: 4, destination: Data(F.peerKey.prefix(6)), timestamp: 1, text: "hi", isPlainText: true)
      let echo = F.entry(.textMessage, payload: F.dmPayload(to: F.peerHash, from: F.radioHash), decryptStatus: .dmNoMatchingKey)
      #expect(match(echo, [send]) == EchoMatch(sendID: 4, confidence: .probable, relation: .echo))
      let request = F.send(.request, id: 5, payloadType: .request, destination: F.peerKey)
      #expect(match(echo, [request]) == nil, "A request isn't a message")
      let requestEcho = F.entry(.request, payload: F.dmPayload(to: F.peerHash, from: F.radioHash))
      #expect(match(requestEcho, [request]) == EchoMatch(sendID: 5, confidence: .probable, relation: .echo))
    }

    @Test
    func `our own advert is exact, a forged one is nothing`() throws {
      let send = F.send(.advert, id: 9, payloadType: .advert)
      let advert = F.entry(.advert, path: [0xAA, 0xBB], payload: try F.advertPayload(signer: F.radioSigner))
      #expect(match(advert, [send]) == EchoMatch(sendID: 9, confidence: .exact, relation: .echo))
      let forged = F.entry(.advert, path: [0xAA], payload: try F.advertPayload(signer: F.radioSigner, forged: true))
      #expect(match(forged, [send]) == nil)
      // Someone else's advert.
      let other = F.entry(.advert, payload: try F.advertPayload(signer: Curve25519.Signing.PrivateKey()))
      #expect(match(other, [send]) == nil)
    }

    @Test
    func `a login carrying our key is probable`() {
      let send = F.send(.anonRequest, id: 2, payloadType: .anonRequest, destination: F.peerKey)
      let login = F.entry(.anonRequest, payload: [F.peerHash] + Array(F.radioKey) + [UInt8](repeating: 0, count: 16))
      #expect(match(login, [send]) == EchoMatch(sendID: 2, confidence: .probable, relation: .echo))
      // Another node's login to the same repeater.
      let stranger = F.entry(.anonRequest, payload: [F.peerHash] + [UInt8](repeating: 0x33, count: 32) + [UInt8](repeating: 0, count: 16))
      #expect(match(stranger, [send]) == nil)
    }

    @Test
    func `a send the radio refused never matches`() {
      let refused = F.send(
        .channelMessage, payloadType: .groupText, channelIndex: 1, timestamp: 1_700_000_000, text: "hello all",
        outcome: .rejected(code: 1)
      )
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000), [refused]) == nil)
      var unconfirmed = refused
      unconfirmed.outcome = .unconfirmed
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000), [unconfirmed]) != nil, "The radio may have sent it")
    }

    @Test
    func `after one exact match a copy by another path matches by its hash`() {
      var send = F.send(.directMessage, id: 6, destination: Data(F.peerKey.prefix(6)), timestamp: 1_800_000_000, text: "hi", isPlainText: true)
      let first = F.entry(
        .textMessage, path: [0xAA], payload: F.dmPayload(to: F.peerHash, from: F.radioHash),
        decryptStatus: .success, senderTimestamp: 1_800_000_000, decodedText: "hi", peerPublicKey: F.peerKey
      )
      #expect(match(first, [send])?.confidence == .exact)
      send.provenPacketHashes.insert(first.packetHash)
      // The same packet through other repeaters, which this copy couldn't decrypt.
      let copy = F.entry(.textMessage, path: [0xCC, 0xDD], payload: F.dmPayload(to: F.peerHash, from: F.radioHash), decryptStatus: .dmNoMatchingKey)
      #expect(copy.packetHash == first.packetHash, "The hash covers the payload, not the path")
      #expect(match(copy, [send]) == EchoMatch(sendID: 6, confidence: .exact, relation: .echo))
    }

    @Test
    func `our trace and node discovery are known by their tags`() {
      let trace = F.send(.trace, id: 1, payloadType: .trace, tag: 9)
      var payload = withUnsafeBytes(of: UInt32(9).littleEndian) { Array($0) }
      payload += [0, 0, 0, 0, 0x00, 0xAA, 0xBB]
      let traceEntry = F.entry(.trace, route: StockCompanionFrames.routeDirect, path: [0x10, 0xF6], payload: payload)
      #expect(match(traceEntry, [trace]) == EchoMatch(sendID: 1, confidence: .exact, relation: .echo))

      let discover = F.send(.control, id: 2, payloadType: .control, tag: 5)
      var answer: [UInt8] = [0x92, 0x1C]
      answer += withUnsafeBytes(of: UInt32(5).littleEndian) { Array($0) }
      answer += Array(F.peerKey.prefix(8))
      let answerEntry = F.entry(.control, route: StockCompanionFrames.routeDirect, path: [], payload: answer)
      #expect(match(answerEntry, [discover]) == EchoMatch(sendID: 2, confidence: .exact, relation: .answer))
      var stranger = answer
      stranger[2] = 6
      #expect(match(F.entry(.control, route: StockCompanionFrames.routeDirect, path: [], payload: stranger), [discover]) == nil)
    }

    @Test
    func `the ack our message expects answers it`() throws {
      var send = F.send(.directMessage, id: 8, destination: Data(F.peerKey.prefix(6)), timestamp: 1_800_000_000, text: "hi", isPlainText: true)
      let computed = try #require(send.expectedAck(senderKey: F.radioKey))
      let ack = F.entry(.ack, payload: Array(computed) + [0, 7])
      #expect(match(ack, [send]) == EchoMatch(sendID: 8, confidence: .exact, relation: .answer))
      // The radio's own expected ack is taken too.
      send.apply(.sent(MessageSentInfo(route: 1, expectedAck: Data([1, 2, 3, 4]), suggestedTimeoutMs: 1000)))
      #expect(match(F.entry(.ack, payload: [1, 2, 3, 4]), [send])?.relation == .answer)
      #expect(match(F.entry(.ack, payload: [4, 3, 2, 1]), [send]) == nil, "Someone else's ack")
    }

    @Test
    func `channel data is probable and only moments after`() {
      let send = F.send(.channelData, id: 1, payloadType: .groupData, channelIndex: 2)
      func echo(channel: UInt8, after seconds: TimeInterval = 5) -> RxLogEntryDTO {
        F.entry(.groupData, payload: [0x11, 0x22, 0x33] + [UInt8](repeating: 0, count: 16), at: F.base.addingTimeInterval(seconds), decryptStatus: .success, channelIndex: channel)
      }
      #expect(match(echo(channel: 2), [send])?.confidence == .probable)
      #expect(match(echo(channel: 3), [send]) == nil, "Another channel's data")
      #expect(match(echo(channel: 2, after: 60), [send]) == nil, "Data sent a minute ago")
    }

    @Test
    func `an echo is looked for only within the window after its send`() {
      let send = F.send(.channelMessage, payloadType: .groupText, channelIndex: 1, timestamp: 1_700_000_000, text: "hello all")
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000, at: F.base.addingTimeInterval(100)), [send]) != nil)
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000, at: F.base.addingTimeInterval(200)), [send]) == nil)
      #expect(match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000, at: F.base.addingTimeInterval(-10)), [send]) == nil, "Heard before it was sent")
    }

    @Test
    func `a repeater's own discovery just after we asked it to scan names it`() throws {
      var scan = F.send(.directMessage, destination: Data(F.peerKey.prefix(6)), timestamp: 1, text: "discover.neighbors")
      var payload: [UInt8] = [0x81, 0x02]
      payload += withUnsafeBytes(of: UInt32(0x1234).littleEndian) { Array($0) }
      payload += [0, 0, 0, 0]
      let request = F.entry(.control, route: StockCompanionFrames.routeDirect, path: [], payload: payload, at: F.base.addingTimeInterval(3))
      let requester = try #require(OwnTransmissionMatcher.discoverRequester(for: request, in: [scan]))
      #expect(requester.tag == 0x1234 && requester.repeater == F.peerKey.prefix(6))
      scan.text = "ver"
      #expect(OwnTransmissionMatcher.discoverRequester(for: request, in: [scan]) == nil, "Any other command isn't a scan")
    }

    @Test
    func `a path packet to us from the node a discovery was for carries its answer`() {
      let discovery = OwnPathDiscovery(
        contactPrefix: Data(F.peerKey.prefix(6)), outHops: [Data([0xAA])], inHops: [Data([0xAA])], at: F.base.addingTimeInterval(4)
      )
      let path = F.entry(.path, path: [0xAA], payload: F.dmPayload(to: F.radioHash, from: F.peerHash))
      #expect(OwnTransmissionMatcher.pathDiscovery(for: path, in: [discovery], selfKey: F.radioKey) == discovery)
      let late = F.entry(.path, path: [0xAA], payload: F.dmPayload(to: F.radioHash, from: F.peerHash), at: F.base.addingTimeInterval(60))
      #expect(OwnTransmissionMatcher.pathDiscovery(for: late, in: [discovery], selfKey: F.radioKey) == nil)
    }
  }
}
