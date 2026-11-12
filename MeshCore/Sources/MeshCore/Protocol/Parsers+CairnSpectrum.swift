import Foundation

extension Parsers {
  // MARK: - CairnSpectrum

  /// Parser for a Cairn touch board's Spectrum Channel feed (firmware's
  /// `examples/companion_radio/ui-l2/net/SPEC_SYNC.md`).
  ///
  /// Integers are little-endian. Each frame kind only ever appends fields, so bytes past the
  /// known layout are ignored. Offsets below are counted in the payload after the code byte (one
  /// less than the firmware document's, which counts the code).
  enum CairnSpectrum {
    /// Parses a ``CairnFirmwareSubcommand/spectrum`` reply (the payload after the 0xC0 code).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): Sub-command, 0x06
    /// - Offset 1 (1 byte): Status (``CairnSpectrumStatus``); a non-OK reply ends here plus the op
    /// - Offset 2 (1 byte): Op (``CairnSpectrumOp``)
    /// - STATS: offset 3, the 37-byte stats block
    /// - HISTORY: the stats block, then offset 40 xfer, 41 vflags, 42 ncols, 43 now_slot u32,
    ///   47 count, 48 scale_lo i8, 49 ref_floor i8, 50 peak_back, 51 marks, 52 marks_more u16,
    ///   54 frames, 55 mark_cursor u32
    /// - TREND: offset 3 epoch u16, 5 thermal i8, 6 have, 7 npts, 8 the points (i8 each)
    static func parseReply(_ data: Data) -> MeshEvent {
      guard data.count >= PacketSize.cairnSpectrumShortReply - 1 else {
        return .parseFailure(data: data, reason: "Spectrum reply too short: \(data.count)")
      }
      let status = CairnSpectrumStatus(rawValue: data[1])
      switch CairnSpectrumOp(rawValue: data[2]) {
      case .stats:
        guard status == .ok else {
          return .cairnSpectrumStats(CairnSpectrumStatsReply(status: status, stats: nil))
        }
        guard data.count >= PacketSize.cairnSpectrumStats - 1 else {
          return .parseFailure(data: data, reason: "Spectrum STATS reply too short: \(data.count)")
        }
        return .cairnSpectrumStats(CairnSpectrumStatsReply(status: .ok, stats: statsBlock(data)))
      case .history:
        guard status == .ok else {
          return .cairnSpectrumHistoryReply(CairnSpectrumHistoryReply(status: status, stats: nil))
        }
        guard data.count >= PacketSize.cairnSpectrumHistoryReply - 1 else {
          return .parseFailure(data: data, reason: "Spectrum HISTORY reply too short: \(data.count)")
        }
        let vflags = data[41]
        let refFloor = Int8(bitPattern: data[49])
        return .cairnSpectrumHistoryReply(CairnSpectrumHistoryReply(
          status: .ok,
          stats: statsBlock(data),
          xfer: data[40],
          isFull: vflags & 0x01 != 0,
          isRaw: vflags & 0x02 != 0,
          marksReset: vflags & 0x04 != 0,
          columns: data[42],
          nowSlot: data.readUInt32LE(at: 43),
          count: data[47],
          scaleLo: Int8(bitPattern: data[48]),
          refFloor: refFloor == 0 ? nil : refFloor,
          peakBack: data[50] == 0xFF ? nil : data[50],
          marks: data[51],
          marksMore: data.readUInt16LE(at: 52),
          frames: data[54],
          markCursor: data.readUInt32LE(at: 55)
        ))
      case .trend:
        guard status == .ok else {
          return .cairnSpectrumTrend(CairnSpectrumTrendReply(status: status, trend: nil))
        }
        let header = PacketSize.cairnSpectrumTrendHeader - 1
        guard data.count >= header else {
          return .parseFailure(data: data, reason: "Spectrum TREND reply too short: \(data.count)")
        }
        let count = Int(data[7])
        guard data.count >= header + count else {
          return .parseFailure(
            data: data, reason: "Spectrum TREND reply too short for \(count) points: \(data.count)"
          )
        }
        let points: [Int8?] = data[header..<(header + count)].map {
          let dBm = Int8(bitPattern: $0)
          return dBm == 0 ? nil : dBm
        }
        return .cairnSpectrumTrend(CairnSpectrumTrendReply(status: .ok, trend: CairnSpectrumTrend(
          epoch: data.readUInt16LE(at: 3),
          thermal: Int8(bitPattern: data[5]),
          have: data[6],
          points: points
        )))
      case nil:
        return .parseFailure(data: data, reason: "Unknown Spectrum op: \(data[2])")
      }
    }

    /// Parses a ``ResponseCode/spectrumData`` push (the payload after 0xC6).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): xfer
    /// - Offset 1 (1 byte): Kind: 0x00 COLUMNS, 0x01 MARKS
    /// - COLUMNS: offset 2 back, 3 n, then n columns (``parseColumn(_:at:)``)
    /// - MARKS: offset 2 n (1...15), then n × 11-byte marks
    static func parseData(_ data: Data) -> MeshEvent {
      guard data.count >= 3 else {
        return .parseFailure(data: data, reason: "Spectrum data push too short: \(data.count)")
      }
      let xfer = data[0]
      switch data[1] {
      case 0x00:
        guard data.count >= 4 else {
          return .parseFailure(data: data, reason: "Spectrum columns push too short: \(data.count)")
        }
        let count = Int(data[3])
        var offset = 4
        var columns: [CairnSpectrumColumn] = []
        columns.reserveCapacity(count)
        for index in 0..<count {
          guard let column = parseColumn(data, at: &offset) else {
            return .parseFailure(data: data, reason: "Spectrum column \(index) of \(count) malformed")
          }
          columns.append(column)
        }
        return .cairnSpectrumColumns(CairnSpectrumColumnsFrame(xfer: xfer, back: data[2], columns: columns))
      case 0x01:
        let count = Int(data[2])
        let size = PacketSize.cairnSpectrumMark
        guard data.count >= 3 + count * size else {
          return .parseFailure(data: data, reason: "Spectrum marks push too short for \(count): \(data.count)")
        }
        let marks = (0..<count).map { parseMark(data, at: 3 + $0 * size) }
        return .cairnSpectrumMarks(CairnSpectrumMarksFrame(xfer: xfer, marks: marks))
      default:
        return .parseFailure(data: data, reason: "Unknown Spectrum push kind: \(data[1])")
      }
    }

    /// Parses a ``ResponseCode/spectrumEnd`` push (the payload after 0xC7): `[xfer][status]`.
    static func parseEnd(_ data: Data) -> MeshEvent {
      guard data.count >= 2 else {
        return .parseFailure(data: data, reason: "Spectrum end too short: \(data.count)")
      }
      return .cairnSpectrumEnd(CairnSpectrumEnd(xfer: data[0], aborted: data[1] != 0))
    }

    /// One column: `[cf]`, and with cf's DATA bit `[mn i8][mx i8][avg i8][nf i8][busy u8]`
    /// `[dmask u32][occ u8 × popcount(dmask)]`. cf bit 0 = DATA, bit 1 = TX. Nil when the data
    /// ends first, or the mask names a row past the 28th.
    static func parseColumn(_ data: Data, at offset: inout Int) -> CairnSpectrumColumn? {
      guard data.count > offset else { return nil }
      let flags = data[offset]
      let isTX = flags & 0x02 != 0
      guard flags & 0x01 != 0 else {
        offset += 1
        return CairnSpectrumColumn(isData: false, isTX: isTX)
      }
      let fixed = 10
      guard data.count >= offset + fixed else { return nil }
      let mask = data.readUInt32LE(at: offset + 6)
      let rows = CairnSpectrumColumn.rows
      guard mask >> UInt32(rows) == 0 else { return nil }
      let used = mask.nonzeroBitCount
      guard data.count >= offset + fixed + used else { return nil }
      var occupancy = [UInt8](repeating: 0, count: rows)
      var next = offset + fixed
      for row in 0..<rows where mask & (1 << UInt32(row)) != 0 {
        occupancy[row] = data[next]
        next += 1
      }
      let nf = Int8(bitPattern: data[offset + 4])
      let busy = data[offset + 5]
      let column = CairnSpectrumColumn(
        isData: true,
        isTX: isTX,
        min: Int8(bitPattern: data[offset + 1]),
        max: Int8(bitPattern: data[offset + 2]),
        avg: Int8(bitPattern: data[offset + 3]),
        nf: nf == 0 ? nil : nf,
        busy: busy == 0xFF ? nil : busy,
        occupancy: occupancy
      )
      offset = next
      return column
    }

    /// One mark: `[back][w][header][path_len][rssi i8][snr_x4 i8][len][rx_ms u32]`.
    static func parseMark(_ data: Data, at offset: Int) -> CairnSpectrumMark {
      CairnSpectrumMark(
        back: data[offset],
        width: data[offset + 1],
        header: data[offset + 2],
        pathLength: data[offset + 3],
        rssi: Int8(bitPattern: data[offset + 4]),
        snrX4: Int8(bitPattern: data[offset + 5]),
        length: data[offset + 6],
        rxMs: data.readUInt32LE(at: offset + 7)
      )
    }

    /// The STATS block shared by STATS and HISTORY replies, at payload offsets 3...39.
    private static func statsBlock(_ data: Data) -> CairnSpectrumStats {
      let flags = data[3]
      func dBm(_ offset: Int) -> Int8? {
        let value = Int8(bitPattern: data[offset])
        return value == 0 ? nil : value
      }
      func x10(_ offset: Int) -> UInt16? {
        let value = data.readUInt16LE(at: offset)
        return value == 0xFFFF ? nil : value
      }
      return CairnSpectrumStats(
        floorCalibrated: flags & 0x01 != 0,
        sweeping: flags & 0x02 != 0,
        fast: flags & 0x04 != 0,
        epoch: data.readUInt16LE(at: 4),
        nowMs: data.readUInt32LE(at: 6),
        frequencyKHz: data.readUInt32LE(at: 10),
        bandwidthHz: data.readUInt32LE(at: 14),
        spreadingFactor: data[18],
        codingRate: data[19],
        window: data[20],
        nowRSSI: dBm(21),
        floor: dBm(22),
        thermal: Int8(bitPattern: data[23]),
        busyPercent: data[24] == 0xFF ? nil : data[24],
        packetsPerMinuteX10: x10(25),
        airX10: x10(27),
        rxAirX10: x10(29),
        txAirX10: x10(31),
        packets: data.readUInt16LE(at: 33),
        coveredSeconds: data.readUInt16LE(at: 35),
        statsSeconds: data.readUInt16LE(at: 37),
        peak: dBm(39)
      )
    }
  }
}
