import Foundation
@testable import MeshCore
import Testing

/// Frames built byte for byte the way official MeshCore companion firmware (v1.7 to v1.18) builds
/// them (``StockFirmwareFrames``), fed through the app's parsers.
@Suite("Stock firmware vectors")
struct StockFirmwareVectorTests {
  private func capabilities(_ frame: Data) throws -> DeviceCapabilities {
    guard case let .deviceInfo(caps) = PacketParser.parse(frame) else {
      Issue.record("Expected .deviceInfo for \(frame.hexString)")
      throw MeshCoreError.parseError("not deviceInfo")
    }
    return caps
  }

  // MARK: - Device info

  @Test(arguments: [
    (StockFirmwareFrames.v1_7_0DeviceInfo, UInt8(5), "v1.7.0", false, UInt8(0)),
    (StockFirmwareFrames.v1_10_0DeviceInfo, UInt8(8), "v1.10.0", false, UInt8(0)),
    (StockFirmwareFrames.v1_11_0DeviceInfo, UInt8(8), "v1.11.0", false, UInt8(0)),
    (StockFirmwareFrames.v1_12_0DeviceInfo, UInt8(8), "v1.12.0", false, UInt8(0)),
    (StockFirmwareFrames.v1_13_0DeviceInfo, UInt8(9), "v1.13.0", true, UInt8(0)),
    (StockFirmwareFrames.v1_16_0DeviceInfo, UInt8(13), "v1.16.0", false, UInt8(1)),
    (StockFirmwareFrames.v1_18_0DeviceInfo, UInt8(14), "v1.18.0", true, UInt8(2))
  ])
  func `official device info parses with no Cairn build`(
    frame: Data, verCode: UInt8, version: String, clientRepeat: Bool, pathHashMode: UInt8
  ) throws {
    let caps = try capabilities(frame)
    #expect(caps.firmwareVersion == verCode)
    #expect(caps.version == version)
    #expect(caps.model == "Heltec V3")
    #expect(caps.maxContacts == 350)
    #expect(caps.clientRepeat == clientRepeat)
    #expect(caps.pathHashMode == pathHashMode)
    #expect(caps.cairnBuild == nil)
    #expect(caps.isCairnFirmware == false)
  }

  @Test
  func `the Cairn fork's marker gives its build`() throws {
    let caps = try capabilities(StockFirmwareFrames.cairnForkDeviceInfo(build: 112))
    #expect(caps.firmwareVersion == 14)
    #expect(caps.pathHashMode == 1)
    #expect(caps.cairnBuild == 112)
  }

  @Test(arguments: [[UInt8](repeating: 0x07, count: 1), [0x01, 0x43, 0x52]])
  func `fields upstream appends before the fork's marker don't hide it`(extra: [UInt8]) throws {
    let caps = try capabilities(StockFirmwareFrames.cairnForkDeviceInfo(build: 0x0203, upstreamExtra: extra))
    #expect(caps.cairnBuild == 0x0203)
    #expect(caps.pathHashMode == 1, "path_hash_mode is still read at its own offset")
  }

  @Test
  func `a truncated marker is not Cairn`() throws {
    let frame = StockFirmwareFrames.deviceInfo(
      verCode: 14, version: "v1.18.0", clientRepeat: 0, pathHashMode: 1, trailer: Array("CRN".utf8) + [7]
    )
    #expect(try capabilities(frame).cairnBuild == nil)
  }

  @Test
  func `a future upstream field that isn't the marker is not Cairn`() throws {
    // Five trailing bytes, the letters not where the fork puts them (last five, in order).
    let frame = StockFirmwareFrames.deviceInfo(
      verCode: 14, version: "v1.18.0", clientRepeat: 0, pathHashMode: 1,
      trailer: Array("CRN".utf8) + [7, 0, 0x55]
    )
    #expect(try capabilities(frame).cairnBuild == nil)
  }

  @Test
  func `a pre-v10 frame never carries a Cairn build`() throws {
    let frame = StockFirmwareFrames.deviceInfo(verCode: 9, version: "v1.13.0", clientRepeat: 0, trailer: Array("CRN".utf8) + [1, 0])
    #expect(try capabilities(frame).cairnBuild == nil)
  }

  // MARK: - Errors and stats

  @Test
  func `unsupported command error parses as code 1`() {
    guard case let .error(code) = PacketParser.parse(StockFirmwareFrames.unsupported) else {
      Issue.record("Expected .error")
      return
    }
    #expect(code == 1)
    #expect(MeshCoreError.deviceError(code: code ?? 0).deviceErrorCode == .unsupportedCommand)
  }

  @Test
  func `v1.11 packet stats (24 bytes) parse without a frame count`() {
    guard case let .statsPackets(stats) = PacketParser.parse(StockFirmwareFrames.statsPackets24(received: 1000)) else {
      Issue.record("Expected .statsPackets")
      return
    }
    #expect(stats.received == 1000)
    #expect(stats.sent == 10)
    #expect(stats.receiveErrors == 0)
    #expect(stats.appRxLogFrames == nil, "only a session stamps the 0x88 count")
  }

  @Test
  func `v1.13+ packet stats (28 bytes) carry receive errors`() {
    guard case let .statsPackets(stats) = PacketParser.parse(StockFirmwareFrames.statsPackets28(received: 77, receiveErrors: 9)) else {
      Issue.record("Expected .statsPackets")
      return
    }
    #expect(stats.received == 77)
    #expect(stats.receiveErrors == 9)
    #expect(stats.stamped(appRxLogFrames: 70).appRxLogFrames == 70)
    #expect(stats.stamped(appRxLogFrames: 70).received == 77)
  }

  // MARK: - Received packets

  private func rxLog(_ frame: Data) throws -> ParsedRxLogData {
    guard case let .rxLogData(parsed) = PacketParser.parse(frame) else {
      Issue.record("Expected .rxLogData for \(frame.hexString)")
      throw MeshCoreError.parseError("not rxLogData")
    }
    return parsed
  }

  @Test
  func `a 4-byte plain ACK yields its code`() throws {
    let parsed = try rxLog(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket(code: [1, 2, 3, 4])))
    #expect(parsed.payloadType == .ack)
    #expect(parsed.snr == 6.5)
    #expect(parsed.rssi == -90)
    #expect(ExpectedAckTracker.ackCode(in: parsed) == Data([1, 2, 3, 4]))
  }

  @Test
  func `a v1.16+ 6-byte plain ACK yields its first four bytes`() throws {
    let parsed = try rxLog(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.ackPacket6(code: [9, 8, 7, 6], attempt: 2)))
    #expect(parsed.packetPayload.count == 6)
    #expect(ExpectedAckTracker.ackCode(in: parsed) == Data([9, 8, 7, 6]))
  }

  @Test
  func `a multipart ACK yields the code after its type byte`() throws {
    let parsed = try rxLog(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.multipartAckPacket(code: [5, 6, 7, 8, 1, 2])))
    #expect(parsed.payloadType == .multipart)
    #expect(ExpectedAckTracker.ackCode(in: parsed) == Data([5, 6, 7, 8]))
  }

  @Test
  func `packets that carry no readable ACK yield none`() throws {
    // A multipart of another kind (low nibble not ACK), a short ACK, and a discover reply.
    let otherMultipart = StockFirmwareFrames.packet(payloadType: 0x0A, route: 2, path: [1], payload: [0x12, 1, 2, 3, 4])
    let shortAck = StockFirmwareFrames.packet(payloadType: 0x03, route: 2, path: [1], payload: [1, 2, 3])
    let reply = StockFirmwareFrames.discoverReplyPacket(key: Array(repeating: 0xA0, count: 32))
    for raw in [otherMultipart, shortAck, reply] {
      #expect(ExpectedAckTracker.ackCode(in: try rxLog(StockFirmwareFrames.logRx(raw: raw))) == nil)
    }
  }

  @Test
  func `the longest frame v1.16+ forwards (173 raw bytes) parses`() throws {
    // A flood group text relayed over 8 one-byte hashes: 1 + 1 + 8 + 163 = 173 bytes raw.
    let raw = StockFirmwareFrames.packet(
      payloadType: 0x05, route: StockFirmwareFrames.routeFlood,
      path: Array(1...8), payload: [UInt8](repeating: 0x3C, count: 163)
    )
    let frame = StockFirmwareFrames.logRx(raw: raw)
    #expect(raw.count == 173)
    #expect(frame.count == 176, "MAX_FRAME_SIZE from companion v1.16.0")
    let parsed = try rxLog(frame)
    #expect(parsed.payloadType == .groupText)
    #expect(parsed.pathNodes.count == 8)
    #expect(parsed.packetPayload.count == 163)
  }

  @Test
  func `a discover reply's 0x88 and 0x8E copies parse to the same reply`() throws {
    let key = (0..<32).map { UInt8(0xA0 &+ $0) }
    let parsed = try rxLog(StockFirmwareFrames.logRx(raw: StockFirmwareFrames.discoverReplyPacket(key: key)))
    let evidence = NeighbourEvidence.extract(RxPacketFields(parsed), selfHash: nil)
    #expect(evidence.first?.source == .discoverReply)
    #expect(evidence.first?.identity == .fullKey(Data(key)))
    guard case let .discoverResponse(response) = PacketParser.parse(StockFirmwareFrames.controlData(key: key)) else {
      Issue.record("Expected .discoverResponse")
      return
    }
    #expect(response.publicKey == Data(key))
    #expect(NeighbourEvidence.extract(response, selfHash: nil).first?.packetHash == evidence.first?.packetHash)
  }

  // MARK: - Messaging

  @Test
  func `RESP_CODE_SENT carries the expected ACK and timeout`() {
    guard case let .messageSent(info) = PacketParser.parse(StockFirmwareFrames.messageSent(ack: [1, 2, 3, 4], flood: true, timeoutMs: 9000)) else {
      Issue.record("Expected .messageSent")
      return
    }
    #expect(info.route == 1)
    #expect(info.expectedAck == Data([1, 2, 3, 4]))
    #expect(info.suggestedTimeoutMs == 9000)
  }

  @Test
  func `PUSH_CODE_SEND_CONFIRMED carries the code and trip time`() {
    guard case let .acknowledgement(code, tripTime) = PacketParser.parse(StockFirmwareFrames.sendConfirmed(ack: [1, 2, 3, 4], tripMs: 812)) else {
      Issue.record("Expected .acknowledgement")
      return
    }
    #expect(code == Data([1, 2, 3, 4]))
    #expect(tripTime == 812)
  }

  @Test
  func `message queue frames parse and answer a fetch`() {
    guard case let .contactMessageReceived(message) = PacketParser.parse(StockFirmwareFrames.contactMsgV3(text: "hello")) else {
      Issue.record("Expected .contactMessageReceived")
      return
    }
    #expect(message.text == "hello")
    #expect(MeshCoreSession.answersMessageFetch(0x10))
    guard case .noMoreMessages = PacketParser.parse(StockFirmwareFrames.noMoreMessages) else {
      Issue.record("Expected .noMoreMessages")
      return
    }
    #expect(MeshCoreSession.answersMessageFetch(0x0A))
    guard case .messagesWaiting = PacketParser.parse(StockFirmwareFrames.msgWaiting) else {
      Issue.record("Expected .messagesWaiting")
      return
    }
    #expect(MeshCoreSession.answersMessageFetch(0x83) == false)
  }
}
