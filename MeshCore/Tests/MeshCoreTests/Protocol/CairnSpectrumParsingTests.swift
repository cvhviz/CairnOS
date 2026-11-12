import Foundation
@testable import MeshCore
import Testing

/// The frames as the firmware's `net/SPEC_SYNC.md` lays them out, with its golden vectors
/// (shared with the firmware's test_l2_specsync).
@Suite("Cairn spectrum parsing")
struct CairnSpectrumParsingTests {
  // MARK: - Requests

  @Test
  func `STATS request is the golden vector`() {
    #expect(PacketBuilder.cairnSpectrumStats(window: 1) == Data([0xC0, 0x06, 0x00, 0x01]))
  }

  @Test
  func `full HISTORY request is the golden vector`() {
    let request = CairnSpectrumHistoryRequest(window: 1, columns: 180, epoch: 3)
    #expect(PacketBuilder.cairnSpectrumHistory(request) == Data([
      0xC0, 0x06, 0x01, 0x01, 0xB4, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]))
  }

  @Test
  func `incremental HISTORY request places every field`() {
    let request = CairnSpectrumHistoryRequest(
      window: 3, columns: 240, epoch: 0x1234, sinceSlot: 0x0A0B_0C0D, scaleLo: -120, markSince: 0x0102_0304
    )
    let frame = PacketBuilder.cairnSpectrumHistory(request)
    #expect(frame.count == 16)
    #expect(frame == Data([
      0xC0, 0x06, 0x01, 0x03, 0xF0, 0x34, 0x12, 0x0D, 0x0C, 0x0B, 0x0A, 0x88, 0x04, 0x03, 0x02, 0x01,
    ]))
  }

  @Test
  func `TREND request`() {
    #expect(PacketBuilder.cairnSpectrumTrend() == Data([0xC0, 0x06, 0x02, 0xA0]))
    #expect(PacketBuilder.cairnSpectrumTrend(points: 40) == Data([0xC0, 0x06, 0x02, 40]))
  }

  // MARK: - Replies

  @Test
  func `STATS reply parses every field`() throws {
    let frame = SpectrumFrames.statsReply()
    #expect(frame.count == 41)
    guard case let .cairnSpectrumStats(reply) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumStats")
      return
    }
    #expect(reply.status == .ok)
    let stats = try #require(reply.stats)
    #expect(stats.floorCalibrated)
    #expect(!stats.sweeping)
    #expect(stats.fast)
    #expect(stats.epoch == 3)
    #expect(stats.nowMs == 200_000)
    #expect(stats.frequencyKHz == 869_525)
    #expect(stats.bandwidthHz == 250_000)
    #expect(stats.spreadingFactor == 11)
    #expect(stats.codingRate == 5)
    #expect(stats.window == 1)
    #expect(stats.nowRSSI == -91)
    #expect(stats.floor == -112)
    #expect(stats.thermal == -120)
    #expect(stats.busyPercent == 7)
    #expect(stats.packetsPerMinuteX10 == 60)
    #expect(stats.airX10 == 36)
    #expect(stats.rxAirX10 == 31)
    #expect(stats.txAirX10 == 5)
    #expect(stats.packets == 6)
    #expect(stats.coveredSeconds == 60)
    #expect(stats.statsSeconds == 60)
    #expect(stats.peak == -84)
  }

  @Test
  func `STATS sentinels become nil`() throws {
    let block = SpectrumFrames.statsBlock(
      flags: 0x02, now: 0, floor: 0, busy: 0xFF, pktX10: 0xFFFF, air: 0xFFFF, rx: 0xFFFF, tx: 0xFFFF, peak: 0
    )
    guard case let .cairnSpectrumStats(reply) = PacketParser.parse(SpectrumFrames.statsReply(block)) else {
      Issue.record("Expected cairnSpectrumStats")
      return
    }
    let stats = try #require(reply.stats)
    #expect(stats.sweeping)
    #expect(!stats.floorCalibrated)
    #expect(stats.nowRSSI == nil)
    #expect(stats.floor == nil)
    #expect(stats.busyPercent == nil)
    #expect(stats.packetsPerMinuteX10 == nil)
    #expect(stats.airX10 == nil)
    #expect(stats.rxAirX10 == nil)
    #expect(stats.txAirX10 == nil)
    #expect(stats.peak == nil)
  }

  @Test
  func `a non-OK reply is the four-byte head with no stats`() {
    guard case let .cairnSpectrumStats(stats) = PacketParser.parse(Data([0xC0, 0x06, 0x03, 0x00])) else {
      Issue.record("Expected cairnSpectrumStats")
      return
    }
    #expect(stats.status == .tooSoon)
    #expect(stats.stats == nil)
    guard case let .cairnSpectrumHistoryReply(history) = PacketParser.parse(Data([0xC0, 0x06, 0x01, 0x01])) else {
      Issue.record("Expected cairnSpectrumHistoryReply")
      return
    }
    #expect(history.status == .busy)
    #expect(history.stats == nil)
    guard case let .cairnSpectrumTrend(trend) = PacketParser.parse(Data([0xC0, 0x06, 0x02, 0x02])) else {
      Issue.record("Expected cairnSpectrumTrend")
      return
    }
    #expect(trend.status == .unavailable)
    #expect(trend.trend == nil)
    guard case let .cairnSpectrumHistoryReply(other) = PacketParser.parse(Data([0xC0, 0x06, 0x09, 0x01])) else {
      Issue.record("Expected cairnSpectrumHistoryReply")
      return
    }
    #expect(other.status == .other(9))
  }

  @Test
  func `HISTORY reply parses the transfer fields`() throws {
    let frame = SpectrumFrames.historyReply(
      vflags: 0x07, nowSlot: 0x0001_0203, count: 180, peakBack: 0xFF, marks: 45, marksMore: 300, frames: 19,
      markCursor: 0xDEAD_BEEF
    )
    #expect(frame.count == 60)
    guard case let .cairnSpectrumHistoryReply(reply) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumHistoryReply")
      return
    }
    #expect(reply.status == .ok)
    #expect(try #require(reply.stats).epoch == 3)
    #expect(reply.xfer == 9)
    #expect(reply.isFull)
    #expect(reply.isRaw)
    #expect(reply.marksReset)
    #expect(reply.columns == 180)
    #expect(reply.nowSlot == 0x0001_0203)
    #expect(reply.count == 180)
    #expect(reply.scaleLo == -120)
    #expect(reply.refFloor == -112)
    #expect(reply.peakBack == nil)
    #expect(reply.marks == 45)
    #expect(reply.marksMore == 300)
    #expect(reply.frames == 19)
    #expect(reply.markCursor == 0xDEAD_BEEF)
  }

  @Test
  func `HISTORY reply flags and floor sentinels`() {
    guard case let .cairnSpectrumHistoryReply(reply) = PacketParser.parse(
      SpectrumFrames.historyReply(vflags: 0x00, refFloor: 0, peakBack: 4)
    ) else {
      Issue.record("Expected cairnSpectrumHistoryReply")
      return
    }
    #expect(!reply.isFull)
    #expect(!reply.isRaw)
    #expect(!reply.marksReset)
    #expect(reply.refFloor == nil)
    #expect(reply.peakBack == 4)
  }

  @Test
  func `TREND reply maps empty points to nil`() throws {
    let frame = Data([0xC0, 0x06, 0x00, 0x02, 0x03, 0x00, 0x88, 0x01, 4, 0x8D, 0x00, 0x8E, 0x93])
    guard case let .cairnSpectrumTrend(reply) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumTrend")
      return
    }
    let trend = try #require(reply.trend)
    #expect(trend.epoch == 3)
    #expect(trend.thermal == -120)
    #expect(trend.have == 1)
    #expect(trend.points == [-115, nil, -114, -109])
  }

  @Test
  func `a 160-point TREND fits one frame`() throws {
    let frame = Data([0xC0, 0x06, 0x00, 0x02, 0x01, 0x00, 0x88, 0x01, 160] + [UInt8](repeating: 0x90, count: 160))
    #expect(frame.count == 169)
    guard case let .cairnSpectrumTrend(reply) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumTrend")
      return
    }
    #expect(try #require(reply.trend).points.count == 160)
  }

  @Test
  func `short replies are parse failures`() {
    let statsShort = Data(SpectrumFrames.statsReply().prefix(40))
    let historyShort = Data(SpectrumFrames.historyReply().prefix(59))
    let trendShort = Data([0xC0, 0x06, 0x00, 0x02, 0x03, 0x00, 0x88, 0x01, 4, 0x8D])
    for frame in [statsShort, historyShort, trendShort, Data([0xC0, 0x06, 0x00])] {
      guard case .parseFailure = PacketParser.parse(frame) else {
        Issue.record("Expected parseFailure for \(frame.count) bytes")
        continue
      }
    }
  }

  @Test
  func `an unknown op is a parse failure`() {
    guard case .parseFailure = PacketParser.parse(Data([0xC0, 0x06, 0x00, 0x07])) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `bytes a later protocol appends are ignored`() throws {
    var frame = SpectrumFrames.historyReply()
    frame.append(contentsOf: [0xAA, 0xBB])
    guard case let .cairnSpectrumHistoryReply(reply) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumHistoryReply")
      return
    }
    #expect(reply.markCursor == 123_456)
    var stats = SpectrumFrames.statsReply()
    stats.append(0xCC)
    guard case let .cairnSpectrumStats(statsReply) = PacketParser.parse(stats) else {
      Issue.record("Expected cairnSpectrumStats")
      return
    }
    #expect(try #require(statsReply.stats).peak == -84)
  }

  // MARK: - Pushes

  @Test
  func `the golden DATA column`() throws {
    var offset = 0
    let column = try #require(Parsers.CairnSpectrum.parseColumn(Data(SpectrumFrames.dataColumn), at: &offset))
    #expect(offset == 12)
    #expect(column.isData)
    #expect(!column.isTX)
    #expect(column.min == -112)
    #expect(column.max == -96)
    #expect(column.avg == -109)
    #expect(column.nf == -118)
    #expect(column.busy == 8)
    var rows = [UInt8](repeating: 0, count: 28)
    rows[2] = 31
    rows[3] = 12
    #expect(column.occupancy == rows)
  }

  @Test
  func `gap and TX-only columns are one byte`() throws {
    var offset = 0
    let gap = try #require(Parsers.CairnSpectrum.parseColumn(Data(SpectrumFrames.gapColumn), at: &offset))
    #expect(offset == 1)
    #expect(gap == .gap)
    offset = 0
    let tx = try #require(Parsers.CairnSpectrum.parseColumn(Data(SpectrumFrames.txColumn), at: &offset))
    #expect(!tx.isData)
    #expect(tx.isTX)
    #expect(tx.occupancy.count == 28)
  }

  @Test
  func `a column's sentinels and a full density`() throws {
    // every row filled: 10 + 28 = 38 bytes, the largest column
    let bytes: [UInt8] = [0x03, 0x90, 0xA0, 0x93, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F] + (8...35).map { UInt8($0 % 24 + 8) }
    #expect(bytes.count == 38)
    var offset = 0
    let column = try #require(Parsers.CairnSpectrum.parseColumn(Data(bytes), at: &offset))
    #expect(offset == 38)
    #expect(column.isTX)
    #expect(column.nf == nil)
    #expect(column.busy == nil)
    #expect(column.occupancy == Array(bytes[10...]))
  }

  @Test
  func `a density mask past row 27 is malformed`() {
    var offset = 0
    let bytes: [UInt8] = [0x01, 0x90, 0xA0, 0x93, 0x8A, 0x08, 0x00, 0x00, 0x00, 0x10, 0x1F]
    #expect(Parsers.CairnSpectrum.parseColumn(Data(bytes), at: &offset) == nil)
  }

  @Test
  func `a COLUMNS push holds its columns in order`() {
    let frame = SpectrumFrames.columnsPush(
      xfer: 9, back: 5, columns: [SpectrumFrames.dataColumn, SpectrumFrames.gapColumn, SpectrumFrames.txColumn, SpectrumFrames.dataColumn]
    )
    guard case let .cairnSpectrumColumns(push) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumColumns")
      return
    }
    #expect(push.xfer == 9)
    #expect(push.back == 5)
    #expect(push.columns.map(\.isData) == [true, false, false, true])
    #expect(push.columns[2].isTX)
  }

  @Test
  func `a COLUMNS push cut inside a column is a parse failure`() {
    let whole = SpectrumFrames.columnsPush(xfer: 9, back: 1, columns: [SpectrumFrames.gapColumn, SpectrumFrames.dataColumn])
    guard case .parseFailure = PacketParser.parse(Data(whole.prefix(whole.count - 1))) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `the golden mark`() throws {
    let frame = SpectrumFrames.marksPush(xfer: 9, marks: [SpectrumFrames.mark])
    guard case let .cairnSpectrumMarks(push) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumMarks")
      return
    }
    #expect(push.xfer == 9)
    let mark = try #require(push.marks.first)
    #expect(mark.back == 5)
    #expect(mark.width == 2)
    #expect(mark.payloadTypeBits == 4)
    #expect(mark.payloadType == .advert)
    #expect(mark.routeType == .flood)
    #expect(mark.pathLength == 2)
    #expect(mark.rssi == -91)
    #expect(mark.snrX4 == 29)
    #expect(mark.snr == 7.25)
    #expect(mark.length == 101)
    #expect(mark.rxMs == 123_456)
  }

  @Test
  func `fifteen marks fit one frame, and a short one fails`() {
    let frame = SpectrumFrames.marksPush(xfer: 1, marks: Array(repeating: SpectrumFrames.mark, count: 15))
    #expect(frame.count == 169)
    guard case let .cairnSpectrumMarks(push) = PacketParser.parse(frame) else {
      Issue.record("Expected cairnSpectrumMarks")
      return
    }
    #expect(push.marks.count == 15)
    guard case .parseFailure = PacketParser.parse(Data(frame.prefix(168))) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `an unknown push kind is a parse failure`() {
    guard case .parseFailure = PacketParser.parse(Data([0xC6, 0x01, 0x05, 0x00])) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `END and ABORTED END`() {
    guard case let .cairnSpectrumEnd(end) = PacketParser.parse(SpectrumFrames.end(xfer: 0x2A)) else {
      Issue.record("Expected cairnSpectrumEnd")
      return
    }
    #expect(end == CairnSpectrumEnd(xfer: 0x2A, aborted: false))
    guard case let .cairnSpectrumEnd(aborted) = PacketParser.parse(SpectrumFrames.end(xfer: 3, aborted: true)) else {
      Issue.record("Expected cairnSpectrumEnd")
      return
    }
    #expect(aborted.aborted)
    guard case .parseFailure = PacketParser.parse(Data([0xC7, 0x01])) else {
      Issue.record("Expected parseFailure")
      return
    }
  }

  @Test
  func `STATUS feature bit 2 is the spectrum hint`() {
    let base = CairnFirmwareStatus(
      protocolVersion: 1, realm: "MeshCore L2", build: "Cairn dev", wifiRaw: 0, ipAddress: nil,
      updaterRaw: 0, largestFreeHeapKB: 40, features: 0x07
    )
    #expect(base.supportsSpectrum)
    #expect(base.supportsHistory)
    let old = CairnFirmwareStatus(
      protocolVersion: 1, realm: "MeshCore L2", build: "Cairn 118", wifiRaw: 0, ipAddress: nil,
      updaterRaw: 0, largestFreeHeapKB: 40, features: 0x03
    )
    #expect(!old.supportsSpectrum)
  }
}
