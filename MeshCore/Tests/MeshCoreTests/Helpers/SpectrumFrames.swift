import Foundation

/// Spectrum frames laid out byte by byte from the firmware's `net/SPEC_SYNC.md` (offsets count
/// the code byte, as the document does).
enum SpectrumFrames {
  /// The golden DATA column: mn -112, mx -96, avg -109, nf -118, busy 8, rows 2 and 3 with occ 31 and 12.
  static let dataColumn: [UInt8] = [0x01, 0x90, 0xA0, 0x93, 0x8A, 0x08, 0x0C, 0x00, 0x00, 0x00, 0x1F, 0x0C]
  static let gapColumn: [UInt8] = [0x00]
  static let txColumn: [UInt8] = [0x02]
  /// The golden mark: back 5, w 2, ADV flood, path_len 2, rssi -91, snr_x4 29, len 101, rx_ms 123456.
  static let mark: [UInt8] = [0x05, 0x02, 0x11, 0x02, 0xA5, 0x1D, 0x65, 0x40, 0xE2, 0x01, 0x00]

  /// The 37-byte STATS block (frame offsets 4...40) for a 1 min window.
  static func statsBlock(
    flags: UInt8 = 0x05, epoch: UInt16 = 3, nowMs: UInt32 = 200_000, window: UInt8 = 1,
    now: Int8 = -91, floor: Int8 = -112, thermal: Int8 = -120, busy: UInt8 = 7,
    pktX10: UInt16 = 60, air: UInt16 = 36, rx: UInt16 = 31, tx: UInt16 = 5, pkts: UInt16 = 6,
    covered: UInt16 = 60, span: UInt16 = 60, peak: Int8 = -84
  ) -> [UInt8] {
    var bytes: [UInt8] = [flags]
    bytes += u16(epoch) + u32(nowMs) + u32(869_525) + u32(250_000)
    bytes += [11, 5, window, UInt8(bitPattern: now), UInt8(bitPattern: floor), UInt8(bitPattern: thermal), busy]
    bytes += u16(pktX10) + u16(air) + u16(rx) + u16(tx) + u16(pkts) + u16(covered) + u16(span)
    bytes.append(UInt8(bitPattern: peak))
    return bytes
  }

  static func statsReply(_ block: [UInt8] = statsBlock()) -> Data {
    Data([0xC0, 0x06, 0x00, 0x00] + block)
  }

  /// A 60-byte HISTORY reply.
  static func historyReply(
    block: [UInt8] = statsBlock(), xfer: UInt8 = 9, vflags: UInt8 = 0x03, ncols: UInt8 = 180,
    nowSlot: UInt32 = 400, count: UInt8 = 6, scaleLo: Int8 = -120, refFloor: Int8 = -112,
    peakBack: UInt8 = 2, marks: UInt8 = 1, marksMore: UInt16 = 0, frames: UInt8 = 3,
    markCursor: UInt32 = 123_456
  ) -> Data {
    var bytes: [UInt8] = [0xC0, 0x06, 0x00, 0x01] + block
    bytes += [xfer, vflags, ncols] + u32(nowSlot)
    bytes += [count, UInt8(bitPattern: scaleLo), UInt8(bitPattern: refFloor), peakBack, marks]
    bytes += u16(marksMore) + [frames] + u32(markCursor)
    return Data(bytes)
  }

  static func columnsPush(xfer: UInt8, back: UInt8, columns: [[UInt8]]) -> Data {
    Data([0xC6, xfer, 0x00, back, UInt8(columns.count)] + columns.flatMap { $0 })
  }

  static func marksPush(xfer: UInt8, marks: [[UInt8]]) -> Data {
    Data([0xC6, xfer, 0x01, UInt8(marks.count)] + marks.flatMap { $0 })
  }

  static func end(xfer: UInt8, aborted: Bool = false) -> Data {
    Data([0xC7, xfer, aborted ? 1 : 0])
  }

  static func u16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8)]
  }

  static func u32(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
  }
}
