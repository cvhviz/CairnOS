import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn sent-message echo parsing")
struct SentEchoParsingTests {
  // MARK: - Codes and builder

  @Test
  func `echo codes route as a fetch answer and a push`() {
    #expect(ResponseCode.sentEcho.rawValue == 0xC2)
    #expect(ResponseCode.sentEcho.category == .message)
    #expect(ResponseCode.sentEchoPush.rawValue == 0xC3)
    #expect(ResponseCode.sentEchoPush.category == .push)
  }

  @Test
  func `SYNC_SENT command carries the on byte`() {
    #expect(PacketBuilder.cairnFirmware(.syncSent, on: true) == Data([0xC0, 0x04, 0x01]))
    #expect(PacketBuilder.cairnFirmware(.syncSent, on: false) == Data([0xC0, 0x04, 0x00]))
  }

  // MARK: - SYNC_SENT reply

  @Test
  func `SYNC_SENT reply parses on and queued`() {
    guard case let .cairnSyncSentState(state) = PacketParser.parse(Data([0xC0, 0x04, 0x00, 0x01, 0x07])) else {
      Issue.record("Expected cairnSyncSentState")
      return
    }
    #expect(state == CairnSyncSentState(isOn: true, queued: 7))
  }

  @Test
  func `SYNC_SENT reply too short or failed is a parse failure`() {
    guard case .parseFailure = PacketParser.parse(Data([0xC0, 0x04, 0x00, 0x01])) else {
      Issue.record("Expected parseFailure for a short reply")
      return
    }
    guard case .parseFailure = PacketParser.parse(Data([0xC0, 0x04, 0x01, 0x00, 0x00])) else {
      Issue.record("Expected parseFailure for a non-zero status")
      return
    }
  }

  @Test
  func `STATUS features byte reports SYNC_SENT support`() {
    var frame = Data([0xC0, 0x01, 0x00, 0x01, 2])
    frame.append(Data("L2".utf8))
    frame.append(4)
    frame.append(Data("C112".utf8))
    frame.append(contentsOf: [3, 10, 0, 0, 1, 0, 50, 0])
    guard case let .cairnFirmwareStatus(old) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStatus")
      return
    }
    #expect(old.features == nil)
    #expect(!old.supportsSyncSent)

    frame.append(0x01)
    guard case let .cairnFirmwareStatus(new) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnFirmwareStatus")
      return
    }
    #expect(new.features == 0x01)
    #expect(new.supportsSyncSent)
  }

  // MARK: - Echo frames

  @Test
  func `queued DM echo parses every field`() {
    let frame = echo(code: 0xC2, flags: 0x00, dest: [1, 2, 3, 4, 5, 6], timestamp: 1_760_000_000,
                     ack: 0xA1B2_C3D4, text: "hello there")
    guard case let .radioSentMessage(msg) = PacketParser.parse(frame) else {
      Issue.record("Expected radioSentMessage")
      return
    }
    #expect(!msg.isLive)
    #expect(msg.kind == .direct)
    #expect(msg.destination == Data([1, 2, 3, 4, 5, 6]))
    #expect(msg.channelIndex == nil)
    #expect(msg.timestamp == 1_760_000_000)
    #expect(msg.ackCode == 0xA1B2_C3D4)
    #expect(!msg.isDelivered)
    #expect(msg.text == "hello there")
    #expect(msg.deliveryStatus == nil)
  }

  @Test
  func `live channel echo has its slot and the delivered bit`() {
    let frame = echo(code: 0xC3, flags: 0x81, dest: [3, 0, 0, 0, 0, 0], timestamp: 42, ack: 0, text: "héllo 🌲")
    guard case let .radioSentMessage(msg) = PacketParser.parse(frame) else {
      Issue.record("Expected radioSentMessage")
      return
    }
    #expect(msg.isLive)
    #expect(msg.kind == .channel)
    #expect(msg.channelIndex == 3)
    #expect(msg.isDelivered)
    #expect(msg.text == "héllo 🌲")
  }

  @Test
  func `echo with empty text and reserved bits still parses`() {
    let frame = echo(code: 0xC2, flags: 0x7C, dest: [9, 9, 9, 9, 9, 9], timestamp: 1, ack: 2, text: "")
    guard case let .radioSentMessage(msg) = PacketParser.parse(frame) else {
      Issue.record("Expected radioSentMessage")
      return
    }
    #expect(msg.kind == .direct)
    #expect(!msg.isDelivered)
    #expect(msg.text.isEmpty)
  }

  @Test
  func `delivered status update carries the round trip`() {
    var frame = echo(code: 0xC3, flags: 0x02, dest: [1, 2, 3, 4, 5, 6], timestamp: 100, ack: 0x0102_0304, text: "")
    frame.append(1)
    frame.append(contentsOf: [0xE8, 0x03, 0, 0])
    guard case let .radioSentMessage(msg) = PacketParser.parse(frame) else {
      Issue.record("Expected radioSentMessage")
      return
    }
    #expect(msg.kind == .statusUpdate)
    #expect(msg.deliveryStatus == .delivered)
    #expect(msg.isDelivered)
    #expect(msg.roundTripTime == 1000)
    #expect(msg.ackCode == 0x0102_0304)
  }

  @Test
  func `failed status update has no round trip`() {
    var frame = echo(code: 0xC2, flags: 0x02, dest: [1, 2, 3, 4, 5, 6], timestamp: 100, ack: 5, text: "")
    frame.append(2)
    frame.append(contentsOf: [0, 0, 0, 0])
    guard case let .radioSentMessage(msg) = PacketParser.parse(frame) else {
      Issue.record("Expected radioSentMessage")
      return
    }
    #expect(msg.deliveryStatus == .failed)
    #expect(!msg.isDelivered)
    #expect(msg.roundTripTime == nil)
  }

  @Test
  func `short frames are parse failures`() {
    // 15 bytes total: one short of the 16-byte header.
    let short = Data([0xC2, 0x00, 1, 2, 3, 4, 5, 6, 0, 0, 0, 0, 0, 0, 0])
    guard case .parseFailure = PacketParser.parse(short) else {
      Issue.record("Expected parseFailure for a short echo")
      return
    }
    // Kind 2 needs 21 bytes.
    var status = echo(code: 0xC3, flags: 0x02, dest: [1, 2, 3, 4, 5, 6], timestamp: 1, ack: 1, text: "")
    status.append(contentsOf: [1, 0, 0, 0])
    guard case .parseFailure = PacketParser.parse(status) else {
      Issue.record("Expected parseFailure for a short status update")
      return
    }
  }

  @Test
  func `unknown kind is a parse failure`() {
    let frame = echo(code: 0xC2, flags: 0x03, dest: [1, 2, 3, 4, 5, 6], timestamp: 1, ack: 1, text: "x")
    guard case .parseFailure = PacketParser.parse(frame) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `a 160-byte text fills the frame exactly`() {
    let text = String(repeating: "a", count: 160)
    let frame = echo(code: 0xC2, flags: 0x00, dest: [1, 2, 3, 4, 5, 6], timestamp: 1, ack: 1, text: text)
    #expect(frame.count == 176)
    guard case let .radioSentMessage(msg) = PacketParser.parse(frame) else {
      Issue.record("Expected radioSentMessage")
      return
    }
    #expect(msg.text == text)
  }
}

/// `[code][flags][dest 6][timestamp u32][ack u32][text]`.
func echo(code: UInt8, flags: UInt8, dest: [UInt8], timestamp: UInt32, ack: UInt32, text: String) -> Data {
  var data = Data([code, flags])
  data.append(contentsOf: dest)
  data.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })
  data.append(contentsOf: withUnsafeBytes(of: ack.littleEndian) { Array($0) })
  data.append(Data(text.utf8))
  return data
}
