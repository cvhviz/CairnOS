import Foundation
@testable import MeshCore
import Testing

/// The frames as the firmware builds them (its `net/TripSyncFrames.h`, test_l2_triplog).
@Suite("Cairn trip log parsing")
struct CairnTripsParsingTests {
  private static let name = "TRIP_20261109_142205.trk"

  @Test
  func `commands`() {
    #expect(PacketBuilder.cairnTripState() == Data([0xC0, 0x09, 0x00]))
    #expect(PacketBuilder.cairnTripStart() == Data([0xC0, 0x09, 0x01]))
    #expect(PacketBuilder.cairnTripStop() == Data([0xC0, 0x09, 0x02]))
    #expect(PacketBuilder.cairnTripList(from: 0x0102, max: 3) == Data([0xC0, 0x09, 0x03, 0x02, 0x01, 3]))
    let points = PacketBuilder.cairnTripPoints(name: "ab.trk", from: 18, max: 9)
    #expect(points == Data([0xC0, 0x09, 0x04, 18, 0, 0, 0, 9, 6]) + Data("ab.trk".utf8))
    #expect(PacketBuilder.cairnTripDelete(name: "ab.trk") == Data([0xC0, 0x09, 0x05, 6]) + Data("ab.trk".utf8))
  }

  @Test
  func `STATE reply while recording`() {
    var frame = Data([0xC0, 0x09, 0x01, 0x00, 0x0F, 7, 0, 0x2C, 0x01, 0, 0])
    frame.appendLittleEndian(UInt32(1_794_234_125))
    frame.append(UInt8(Self.name.utf8.count))
    frame.append(contentsOf: Self.name.utf8)
    guard case let .cairnTripReply(.state(op, status, state)) = PacketParser.parse(frame) else {
      Issue.record("Expected a trip state")
      return
    }
    #expect(op == .start)
    #expect(status == .ok)
    #expect(state.isRecording && state.hasCard && state.hasFix && state.isGPSOn)
    #expect(state.logCount == 7)
    #expect(state.points == 300)
    #expect(state.startedAt == Date(timeIntervalSince1970: 1_794_234_125))
    #expect(state.name == Self.name)
  }

  @Test
  func `refused START carries its reason`() {
    let frame = Data([0xC0, 0x09, 0x01, 0x04, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    guard case let .cairnTripReply(.state(_, status, state)) = PacketParser.parse(frame) else {
      Issue.record("Expected a trip state")
      return
    }
    #expect(status == .gpsOff)
    #expect(!state.isRecording)
    #expect(state.startedAt == nil)
    #expect(state.name.isEmpty)
  }

  @Test
  func `LIST reply entries`() {
    var frame = Data([0xC0, 0x09, 0x03, 0x00, 4, 0, 3, 0, 1])
    frame.append(UInt8(Self.name.utf8.count))
    frame.append(contentsOf: Self.name.utf8)
    frame.appendLittleEndian(UInt32(1000))   // start
    frame.appendLittleEndian(UInt32(4600))   // end
    frame.appendLittleEndian(UInt32(412))    // points
    frame.appendLittleEndian(UInt32(5230))   // metres
    frame.appendLittleEndian(UInt32(3000))   // moving
    frame.append(contentsOf: [0x40, 0x01, 0x20, 0x01])   // climb 320, descent 288
    frame.append(0x01)
    guard case let .cairnTripReply(.list(status, total, from, entries)) = PacketParser.parse(frame) else {
      Issue.record("Expected a trip list")
      return
    }
    #expect(status == .ok)
    #expect(total == 4)
    #expect(from == 3)
    #expect(entries.count == 1)
    let entry = entries[0]
    #expect(entry.name == Self.name)
    #expect(entry.startedAt == Date(timeIntervalSince1970: 1000))
    #expect(entry.endedAt == Date(timeIntervalSince1970: 4600))
    #expect(entry.points == 412)
    #expect(entry.distance == 5230)
    #expect(entry.movingTime == 3000)
    #expect(entry.climb == 320)
    #expect(entry.descent == 288)
    #expect(entry.isRecording)
  }

  @Test
  func `LIST refused without a card`() {
    let frame = Data([0xC0, 0x09, 0x03, 0x01, 0, 0, 0, 0, 0])
    guard case let .cairnTripReply(.list(status, total, _, entries)) = PacketParser.parse(frame) else {
      Issue.record("Expected a trip list")
      return
    }
    #expect(status == .noCard)
    #expect(total == 0)
    #expect(entries.isEmpty)
  }

  @Test
  func `POINTS reply`() {
    var frame = Data([0xC0, 0x09, 0x04, 0x00])
    frame.appendLittleEndian(UInt32(1000))
    frame.appendLittleEndian(UInt32(18))
    frame.append(2)
    frame.appendLittleEndian(UInt32(1_794_234_125))
    frame.appendLittleEndian(Int32(-33_856_900))
    frame.appendLittleEndian(Int32(151_215_300))
    frame.appendLittleEndian(Int32(-123))
    frame.appendLittleEndian(UInt32(1_794_234_135))
    frame.appendLittleEndian(Int32(1))
    frame.appendLittleEndian(Int32(2))
    frame.appendLittleEndian(Int32.min)
    guard case let .cairnTripReply(.points(status, total, from, points)) = PacketParser.parse(frame) else {
      Issue.record("Expected trip points")
      return
    }
    #expect(status == .ok)
    #expect(total == 1000)
    #expect(from == 18)
    #expect(points.count == 2)
    #expect(points[0].latitude == -33.8569)
    #expect(points[0].longitude == 151.2153)
    #expect(points[0].altitude == -12.3)
    #expect(points[1].altitude == nil)
    #expect(points[1].time == Date(timeIntervalSince1970: 1_794_234_135))
  }

  @Test
  func `cut POINTS reply is a parse failure`() {
    var frame = Data([0xC0, 0x09, 0x04, 0x00])
    frame.appendLittleEndian(UInt32(10))
    frame.appendLittleEndian(UInt32(0))
    frame.append(1)
    frame.append(contentsOf: [1, 2, 3])
    guard case .parseFailure = PacketParser.parse(frame) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `DELETE reply`() {
    guard case let .cairnTripReply(.deleted(status)) = PacketParser.parse(Data([0xC0, 0x09, 0x05, 0x06])) else {
      Issue.record("Expected a delete reply")
      return
    }
    #expect(status == .recording)
  }
}
