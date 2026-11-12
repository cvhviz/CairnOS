import Foundation

// MARK: - Cairn Spectrum (firmware's net/SPEC_SYNC.md)

/// The status byte of a ``CairnFirmwareSubcommand/spectrum`` reply.
public enum CairnSpectrumStatus: Sendable, Equatable {
  case ok
  /// HISTORY only: another link's transfer is open. Ask again in about 2 s.
  case busy
  /// The board has no Channel history (its memory allocation failed): use the app's own view.
  case unavailable
  /// Asked again under the board's minimum interval for this op.
  case tooSoon
  /// A status this library doesn't know.
  case other(UInt8)

  public init(rawValue: UInt8) {
    switch rawValue {
    case 0: self = .ok
    case 1: self = .busy
    case 2: self = .unavailable
    case 3: self = .tooSoon
    default: self = .other(rawValue)
    }
  }

  public var rawValue: UInt8 {
    switch self {
    case .ok: 0
    case .busy: 1
    case .unavailable: 2
    case .tooSoon: 3
    case let .other(value): value
    }
  }
}

/// The ops of a ``CairnFirmwareSubcommand/spectrum`` request, which its reply repeats.
public enum CairnSpectrumOp: UInt8, Sendable {
  /// The readings alone; no pushes follow.
  case stats = 0x00
  /// The readings plus the window's columns and marks, pushed after the reply (the page's poll).
  case history = 0x01
  /// The noise floor's 24 h trend.
  case trend = 0x02
}

/// The radio's Channel readings over a window: the STATS block a STATS and a HISTORY reply share.
///
/// The sentinels the radio sends for "none" (0 dBm, 0xFF, 0xFFFF) are `nil` here.
public struct CairnSpectrumStats: Sendable, Equatable {
  /// `true` when ``floor`` is a calibrated noise floor.
  public let floorCalibrated: Bool
  /// The radio's Band sweep owns the radio: no samples are taken, and ``nowRSSI`` is stale.
  public let sweeping: Bool
  /// The radio samples at 40 Hz (its own page or the app's lease is open).
  public let fast: Bool
  /// The history's identity: it changes on every reset (a retune) and is never 0.
  public let epoch: UInt16
  /// The radio's `millis()` at the snapshot.
  public let nowMs: UInt32
  public let frequencyKHz: UInt32
  public let bandwidthHz: UInt32
  public let spreadingFactor: UInt8
  public let codingRate: UInt8
  /// The window the request asked for (0 = 10 s, 1 = 1 min, 2 = 10 min, 3 = 1 h).
  public let window: UInt8
  /// The latest reading, dBm.
  public let nowRSSI: Int8?
  /// The noise floor, dBm; nil while the radio is still calibrating.
  public let floor: Int8?
  /// The bandwidth's thermal floor, dBm.
  public let thermal: Int8
  /// The share of the stats span with readings above the floor, 0...100.
  public let busyPercent: UInt8?
  /// Packets per minute ×10.
  public let packetsPerMinuteX10: UInt16?
  /// The radio's AIR: RX plus TX airtime as a share of the span, ‰ (×10 of the percent); nil
  /// while no second of the span has readings (the wire's 0xFFFF).
  public let airX10: UInt16?
  public let rxAirX10: UInt16?
  public let txAirX10: UInt16?
  public let packets: UInt16
  /// Seconds of the stats span the history covers.
  public let coveredSeconds: UInt16
  /// The stats span in seconds: the window, at least 60.
  public let statsSeconds: UInt16
  /// The highest live reading in the window, dBm.
  public let peak: Int8?

  public init(
    floorCalibrated: Bool, sweeping: Bool, fast: Bool, epoch: UInt16, nowMs: UInt32,
    frequencyKHz: UInt32, bandwidthHz: UInt32, spreadingFactor: UInt8, codingRate: UInt8,
    window: UInt8, nowRSSI: Int8?, floor: Int8?, thermal: Int8, busyPercent: UInt8?,
    packetsPerMinuteX10: UInt16?, airX10: UInt16?, rxAirX10: UInt16?, txAirX10: UInt16?,
    packets: UInt16, coveredSeconds: UInt16, statsSeconds: UInt16, peak: Int8?
  ) {
    self.floorCalibrated = floorCalibrated
    self.sweeping = sweeping
    self.fast = fast
    self.epoch = epoch
    self.nowMs = nowMs
    self.frequencyKHz = frequencyKHz
    self.bandwidthHz = bandwidthHz
    self.spreadingFactor = spreadingFactor
    self.codingRate = codingRate
    self.window = window
    self.nowRSSI = nowRSSI
    self.floor = floor
    self.thermal = thermal
    self.busyPercent = busyPercent
    self.packetsPerMinuteX10 = packetsPerMinuteX10
    self.airX10 = airX10
    self.rxAirX10 = rxAirX10
    self.txAirX10 = txAirX10
    self.packets = packets
    self.coveredSeconds = coveredSeconds
    self.statsSeconds = statsSeconds
    self.peak = peak
  }
}

/// The reply to a Spectrum STATS: the status, and the readings when it is ``CairnSpectrumStatus/ok``.
public struct CairnSpectrumStatsReply: Sendable, Equatable {
  public let status: CairnSpectrumStatus
  public let stats: CairnSpectrumStats?

  public init(status: CairnSpectrumStatus, stats: CairnSpectrumStats?) {
    self.status = status
    self.stats = stats
  }
}

/// A Spectrum HISTORY request (the page's poll): `[0xC0][0x06][0x01][window][ncols][epoch u16]`
/// `[since_slot u32][scale_lo i8][mark_since u32]`.
///
/// ``sinceSlot`` means something only for the same window and column count as the previous
/// reply: after changing either, send 0 for it and for ``markSince``.
public struct CairnSpectrumHistoryRequest: Sendable, Equatable {
  /// 0 = 10 s, 1 = 1 min, 2 = 10 min, 3 = 1 h.
  public var window: UInt8
  /// Columns across the window, 32...240.
  public var columns: UInt8
  /// The last epoch the app saw; 0 = none.
  public var epoch: UInt16
  /// The app's last ``CairnSpectrumHistoryReply/nowSlot``; 0 = send everything.
  public var sinceSlot: UInt32
  /// The app's held bottom of the trace, dBm; 0 = none.
  public var scaleLo: Int8
  /// The `rx_ms` of the last mark the app has; 0 = from the window's start.
  public var markSince: UInt32

  public init(
    window: UInt8, columns: UInt8, epoch: UInt16 = 0, sinceSlot: UInt32 = 0, scaleLo: Int8 = 0,
    markSince: UInt32 = 0
  ) {
    self.window = window
    self.columns = columns
    self.epoch = epoch
    self.sinceSlot = sinceSlot
    self.scaleLo = scaleLo
    self.markSince = markSince
  }
}

/// The reply to a Spectrum HISTORY. On ``CairnSpectrumStatus/ok`` the readings are in ``stats``
/// and ``frames`` push frames follow, then one end; any other status is the 4-byte reply alone.
public struct CairnSpectrumHistoryReply: Sendable, Equatable {
  public let status: CairnSpectrumStatus
  public let stats: CairnSpectrumStats?
  /// The transfer's id: every push of it repeats it.
  public let xfer: UInt8
  /// Replace every cached column (otherwise only the newest ``count`` are sent).
  public let isFull: Bool
  /// The columns come from the raw readings (the 10 s and 1 min windows) rather than the 1 s tier.
  public let isRaw: Bool
  /// Drop the cached marks: the history was reset.
  public let marksReset: Bool
  public let columns: UInt8
  /// The newest (partial) column's slot.
  public let nowSlot: UInt32
  /// Columns pushed: slots `nowSlot - count + 1 ... nowSlot`, oldest first.
  public let count: UInt8
  /// The held bottom of the trace and the density rows, dBm.
  public let scaleLo: Int8
  /// The trace's floor rule, dBm.
  public let refFloor: Int8?
  /// The peak column is `nowSlot - peakBack`.
  public let peakBack: UInt8?
  /// Marks pushed.
  public let marks: UInt8
  /// Marks in the window after these: ask again soon for them.
  public let marksMore: UInt16
  /// Data pushes that follow before the end.
  public let frames: UInt8
  /// The app's next `mark_since`.
  public let markCursor: UInt32

  public init(
    status: CairnSpectrumStatus, stats: CairnSpectrumStats?, xfer: UInt8 = 0, isFull: Bool = false,
    isRaw: Bool = false, marksReset: Bool = false, columns: UInt8 = 0, nowSlot: UInt32 = 0,
    count: UInt8 = 0, scaleLo: Int8 = 0, refFloor: Int8? = nil, peakBack: UInt8? = nil,
    marks: UInt8 = 0, marksMore: UInt16 = 0, frames: UInt8 = 0, markCursor: UInt32 = 0
  ) {
    self.status = status
    self.stats = stats
    self.xfer = xfer
    self.isFull = isFull
    self.isRaw = isRaw
    self.marksReset = marksReset
    self.columns = columns
    self.nowSlot = nowSlot
    self.count = count
    self.scaleLo = scaleLo
    self.refFloor = refFloor
    self.peakBack = peakBack
    self.marks = marks
    self.marksMore = marksMore
    self.frames = frames
    self.markCursor = markCursor
  }
}

/// One column of the radio's Channel view: the readings in one time slot.
public struct CairnSpectrumColumn: Sendable, Equatable {
  /// Readings fell in this slot (otherwise a gap, or a transmit alone).
  public let isData: Bool
  /// The radio transmitted in this slot.
  public let isTX: Bool
  public let min: Int8
  public let max: Int8
  public let avg: Int8
  /// The slot's average noise floor, dBm.
  public let nf: Int8?
  /// The share of readings above the floor, 0...100.
  public let busy: UInt8?
  /// The density rows' occupancy index, bottom row first: 0 = empty, else the radio's heat
  /// index 8...31. Always 28 values; row `b` is the 2 dB bin `densBin(scaleLo) + b`.
  public let occupancy: [UInt8]

  public init(
    isData: Bool, isTX: Bool, min: Int8 = 0, max: Int8 = 0, avg: Int8 = 0, nf: Int8? = nil,
    busy: UInt8? = nil, occupancy: [UInt8] = Array(repeating: 0, count: CairnSpectrumColumn.rows)
  ) {
    self.isData = isData
    self.isTX = isTX
    self.min = min
    self.max = max
    self.avg = avg
    self.nf = nf
    self.busy = busy
    self.occupancy = occupancy
  }

  /// Density rows per column.
  public static let rows = 28
  /// An empty slot.
  public static let gap = CairnSpectrumColumn(isData: false, isTX: false)
}

/// A packet the radio heard, as a mark on the Channel view's lane.
public struct CairnSpectrumMark: Sendable, Equatable {
  /// The mark's end column, counted back from the newest: its end slot is `nowSlot - back`.
  public let back: UInt8
  /// Columns the packet's airtime spans, at least 1.
  public let width: UInt8
  /// The packet's header byte.
  public let header: UInt8
  public let pathLength: UInt8
  public let rssi: Int8
  public let snrX4: Int8
  /// The packet's length in bytes.
  public let length: UInt8
  /// The radio's `millis()` when it arrived.
  public let rxMs: UInt32

  /// The header's payload type bits (2...5).
  public var payloadTypeBits: UInt8 { (header >> 2) & 0x0F }
  /// The header's route type (bits 0...1).
  public var routeType: RouteType { RouteType(rawValue: header & 0x03) ?? .flood }
  public var payloadType: PayloadType { PayloadType(fromBits: payloadTypeBits) }
  public var snr: Double { Double(snrX4) / 4 }

  public init(
    back: UInt8, width: UInt8, header: UInt8, pathLength: UInt8, rssi: Int8, snrX4: Int8,
    length: UInt8, rxMs: UInt32
  ) {
    self.back = back
    self.width = width
    self.header = header
    self.pathLength = pathLength
    self.rssi = rssi
    self.snrX4 = snrX4
    self.length = length
    self.rxMs = rxMs
  }
}

/// A COLUMNS push: `[0xC6][xfer][0x00][back][n][n columns]`.
public struct CairnSpectrumColumnsFrame: Sendable, Equatable {
  public let xfer: UInt8
  /// The first column's slot is `nowSlot - back`; the rest follow it in order.
  public let back: UInt8
  public let columns: [CairnSpectrumColumn]

  public init(xfer: UInt8, back: UInt8, columns: [CairnSpectrumColumn]) {
    self.xfer = xfer
    self.back = back
    self.columns = columns
  }
}

/// A MARKS push: `[0xC6][xfer][0x01][n][n × 11 bytes]`, oldest first.
public struct CairnSpectrumMarksFrame: Sendable, Equatable {
  public let xfer: UInt8
  public let marks: [CairnSpectrumMark]

  public init(xfer: UInt8, marks: [CairnSpectrumMark]) {
    self.xfer = xfer
    self.marks = marks
  }
}

/// The end of a Spectrum HISTORY transfer: `[0xC7][xfer][status]`.
public struct CairnSpectrumEnd: Sendable, Equatable {
  public let xfer: UInt8
  /// The same link asked again before this transfer finished.
  public let aborted: Bool

  public init(xfer: UInt8, aborted: Bool) {
    self.xfer = xfer
    self.aborted = aborted
  }
}

/// The radio's 24 h noise-floor trend (Cairn's "NF 24h").
public struct CairnSpectrumTrend: Sendable, Equatable {
  public let epoch: UInt16
  public let thermal: Int8
  /// The radio's `have` byte, as sent.
  public let have: UInt8
  /// Oldest first, each the average floor over its share of the day; nil = no readings.
  public let points: [Int8?]

  public init(epoch: UInt16, thermal: Int8, have: UInt8, points: [Int8?]) {
    self.epoch = epoch
    self.thermal = thermal
    self.have = have
    self.points = points
  }
}

/// The reply to a Spectrum TREND: the status, and the trend when it is ``CairnSpectrumStatus/ok``.
public struct CairnSpectrumTrendReply: Sendable, Equatable {
  public let status: CairnSpectrumStatus
  public let trend: CairnSpectrumTrend?

  public init(status: CairnSpectrumStatus, trend: CairnSpectrumTrend?) {
    self.status = status
    self.trend = trend
  }
}

/// A Spectrum HISTORY as collected: the reply, the columns in slot order and the marks.
///
/// ``completed`` is `true` only when the transfer's end arrived (not aborted) and every frame,
/// column and mark the reply announced came. When it is `false`, what arrived may have holes:
/// treat the cache as invalid and ask for everything again.
public struct CairnSpectrumHistory: Sendable, Equatable {
  public let reply: CairnSpectrumHistoryReply
  /// The pushed columns, slot `reply.nowSlot - reply.count + 1 + i` at index `i`; nil where a
  /// frame went missing.
  public let columns: [CairnSpectrumColumn?]
  public let marks: [CairnSpectrumMark]
  public let completed: Bool
  /// When the reply itself arrived: the radio's `nowMs` in its readings was then, so this, not
  /// the transfer's end, dates its marks.
  public let receivedAt: Date

  public init(
    reply: CairnSpectrumHistoryReply, columns: [CairnSpectrumColumn?], marks: [CairnSpectrumMark],
    completed: Bool, receivedAt: Date = Date()
  ) {
    self.reply = reply
    self.columns = columns
    self.marks = marks
    self.completed = completed
    self.receivedAt = receivedAt
  }
}

public extension CairnFirmwareStatus {
  /// The board can send its Spectrum Channel view (``CairnFirmwareSubcommand/spectrum``). A hint
  /// only: the spectrum reply (or `ERR_CODE_UNSUPPORTED_CMD`) is the authority.
  var supportsSpectrum: Bool {
    (features ?? 0) & 0x04 != 0
  }
}
