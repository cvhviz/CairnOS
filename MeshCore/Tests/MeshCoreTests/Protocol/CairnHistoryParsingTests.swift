import Foundation
@testable import MeshCore
import Testing

/// The frames as the firmware builds them (its `net/HistSyncFrames.h`, test_l2_histsync).
@Suite("Cairn chat history parsing")
struct CairnHistoryParsingTests {
  @Test
  func `QUERY and PAGE commands`() {
    #expect(PacketBuilder.cairnHistoryQuery() == Data([0xC0, 0x05]))
    #expect(PacketBuilder.cairnHistoryPage(sinceSeq: 0x0102_0304, max: 16) == Data([0xC0, 0x05, 0x04, 0x03, 0x02, 0x01, 16]))
  }

  @Test
  func `page reply parses store id, total and page`() {
    let frame = Data([0xC0, 0x05, 0x00, 0x78, 0x56, 0x34, 0x12, 0x2C, 0x01, 16])
    guard case let .cairnHistoryPageReply(reply) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnHistoryPageReply")
      return
    }
    #expect(reply.status == .ok)
    #expect(reply.storeID == 0x1234_5678)
    #expect(reply.total == 300)
    #expect(reply.page == 16)
  }

  @Test
  func `BUSY is a reply, not a failure`() {
    guard case let .cairnHistoryPageReply(reply) = PacketParser.parse(Data([0xC0, 0x05, 0x01, 1, 0, 0, 0, 5, 0, 0])) else {
      Issue.record("Expected cairnHistoryPageReply")
      return
    }
    #expect(reply.status == .busy)
    #expect(reply.page == 0)
  }

  @Test
  func `short reply is a parse failure`() {
    guard case .parseFailure = PacketParser.parse(Data([0xC0, 0x05, 0x00, 1, 2])) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `record first frame parses every field`() {
    let frame = recordFrame(flags: 0x08 | 0x04, seq: 42, key: [1, 2, 3, 4, 5, 6], channel: -1, pathLen: 2,
                            stored: 1_792_220_000, sent: 1_792_219_990, snr: -5, rssi: -90, text: "hello")
    guard case let .cairnHistoryRecord(r) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnHistoryRecord")
      return
    }
    #expect(r.seq == 42)
    #expect(r.key == Data([1, 2, 3, 4, 5, 6]))
    #expect(r.channelIndex == nil)
    #expect(r.pathLength == 2)
    #expect(r.storedAt == 1_792_220_000)
    #expect(r.sentAt == 1_792_219_990)
    #expect(r.snrX4 == -5)
    #expect(r.rssi == -90)
    #expect(r.flags.contains(.hasSentTimestamp))
    #expect(r.flags.contains(.read))
    #expect(!r.flags.contains(.more))
    #expect(r.string == "hello")
  }

  @Test
  func `channel record carries its slot`() {
    let frame = recordFrame(flags: 0x20, seq: 7, key: [9, 9, 9, 9, 9, 9], channel: 3, pathLen: 0xFF,
                            stored: 1, sent: 0, snr: 0, rssi: 0, text: "x")
    guard case let .cairnHistoryRecord(r) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnHistoryRecord")
      return
    }
    #expect(r.channelIndex == 3)
    #expect(r.flags.contains(.channel))
  }

  @Test
  func `continuation joins its head`() {
    let head = String(repeating: "a", count: 147), tail = "the rest"
    guard case let .cairnHistoryRecord(first) = PacketParser.parse(recordFrame(
      flags: 0x80, seq: 9, key: [1, 1, 1, 1, 1, 1], channel: -1, pathLen: 0, stored: 1, sent: 0, snr: 0, rssi: 0, text: head)),
      case let .cairnHistoryRecord(cont) = PacketParser.parse(Data([0xC4, 0x40, 9, 0, 0, 0]) + Data(tail.utf8)) else {
      Issue.record("Expected two cairnHistoryRecord frames")
      return
    }
    #expect(first.flags.contains(.more))
    #expect(cont.flags.contains(.continuation))
    #expect(cont.seq == 9)
    let whole = first.appending(cont)
    #expect(whole.string == head + tail)
    #expect(!whole.flags.contains(.more))
  }

  @Test
  func `end parses the cursor`() {
    guard case let .cairnHistoryEnd(end) = PacketParser.parse(Data([0xC5, 0x00, 58, 0, 0, 0, 12, 0, 0x78, 0x56, 0x34, 0x12])) else {
      Issue.record("Expected cairnHistoryEnd")
      return
    }
    #expect(!end.aborted)
    #expect(end.lastSeq == 58)
    #expect(end.remaining == 12)
    #expect(end.storeID == 0x1234_5678)
  }

  @Test
  func `STATUS feature bit 1 is history`() {
    let s = CairnFirmwareStatus(protocolVersion: 1, realm: "r", build: "b", wifiRaw: 0, ipAddress: nil, updaterRaw: 0,
                                largestFreeHeapKB: 0, features: 0x03)
    #expect(s.supportsHistory)
    #expect(s.supportsSyncSent)
  }
}

/// `[0xC4][flags][seq u32][key 6][channel i8][path_len][stored u32][sent u32][snr i8][rssi i16][text]`
func recordFrame(flags: UInt8, seq: UInt32, key: [UInt8], channel: Int8, pathLen: UInt8, stored: UInt32, sent: UInt32,
                 snr: Int8, rssi: Int16, text: String) -> Data {
  var d = Data([0xC4, flags])
  d.appendLittleEndian(seq)
  d.append(contentsOf: key)
  d.append(UInt8(bitPattern: channel))
  d.append(pathLen)
  d.appendLittleEndian(stored)
  d.appendLittleEndian(sent)
  d.append(UInt8(bitPattern: snr))
  let r = UInt16(bitPattern: rssi)
  d.append(UInt8(r & 0xFF))
  d.append(UInt8(r >> 8))
  d.append(Data(text.utf8))
  return d
}
