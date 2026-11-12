import Foundation
import MeshCore

/// The radio's own Channel view as the app keeps it between polls (firmware's `net/SPEC_SYNC.md`):
/// a fixed grid of `columns` time slots ending at the radio's newest (partial) slot, each column
/// the radio's min/max/avg, floor, busy share and density rows, and the packet marks on its lane.
///
/// Each HISTORY reply either replaces every column (FULL) or slides the grid on to its new newest
/// slot and overwrites the columns it sent, its readings, peak and marks with them. A transfer that
/// didn't complete changes nothing shown, readings included, so the view never mixes two moments;
/// it only marks the copy invalid, so the next request asks for everything again.
struct SpectrumDeviceHistory: Equatable {
  /// A packet mark placed on the slot grid: its end column's absolute slot, so it slides with
  /// the columns between polls.
  struct DeviceMark: Equatable {
    let mark: CairnSpectrumMark
    /// The slot the packet's airtime ended in.
    let endSlot: UInt32

    /// The radio's own floor (`markWidth`): never under 2 columns, for the drawing and the taps.
    var width: Int { max(SpectrumDeviceHistory.minimumMarkColumns, Int(mark.width)) }
  }

  /// What applying a reply changed, for the page to act on.
  struct Outcome: Equatable {
    /// The reply was folded in: its readings, columns, peak and marks are the view's now.
    var applied = false
    /// The radio's history was reset (a retune): its trend is new too.
    var epochChanged = false
  }

  /// A mark covers at least this many columns, as on the radio.
  static let minimumMarkColumns = 2

  /// The radio's window index: 0 = 10 s, 1 = 1 min, 2 = 10 min, 3 = 1 h.
  private(set) var window: UInt8
  private(set) var ncols: Int
  /// The radio's history identity; 0 until the first reply.
  private(set) var epoch: UInt16 = 0
  /// The newest (partial) column's slot.
  private(set) var nowSlot: UInt32 = 0
  /// The held bottom of the trace and the density rows, dBm; 0 until the first reply.
  private(set) var scaleLo: Int8 = 0
  private(set) var refFloor: Int8?
  /// The peak column, counted back from the newest.
  private(set) var peakBack: UInt8?
  /// The readings of the last reply folded in, from the same moment as the columns.
  private(set) var stats: CairnSpectrumStats?
  /// `ncols` columns, index 0 the oldest; nil where the radio sent nothing yet.
  private(set) var columns: [CairnSpectrumColumn?]
  /// Oldest first.
  private(set) var marks: [DeviceMark] = []
  /// The app's next `mark_since`.
  private(set) var markCursor: UInt32 = 0
  /// Marks the radio still holds past the cursor (the first 1 h load comes in pieces).
  private(set) var marksMore: UInt16 = 0
  /// The columns are the raw readings (10 s, 1 min) rather than the 1 s tier.
  private(set) var isRaw = false
  /// The columns are a whole, current copy: the next request can ask for the new ones alone.
  private(set) var isValid = false

  init(window: UInt8, ncols: Int) {
    self.window = window
    self.ncols = ncols
    columns = Array(repeating: nil, count: ncols)
  }

  /// A view the app put together from its own readings (`SpectrumDeviceHistory+Readings`), for
  /// the Radio Screen on a radio that doesn't send one. Complete and current as built.
  init(
    window: UInt8, ncols: Int, nowSlot: UInt32, stats: CairnSpectrumStats?, columns: [CairnSpectrumColumn?],
    marks: [DeviceMark], scaleLo: Int8, refFloor: Int8?, peakBack: UInt8?
  ) {
    self.window = window
    self.ncols = ncols
    self.nowSlot = nowSlot
    self.stats = stats
    self.columns = columns
    self.marks = marks
    self.scaleLo = scaleLo
    self.refFloor = refFloor
    self.peakBack = peakBack
    epoch = 1
    isRaw = true
    isValid = true
  }

  /// The highest live reading in the window.
  var peak: Int8? { stats?.peak }

  /// The peak column's index, when it is on the grid.
  var peakColumn: Int? {
    guard let peakBack, Int(peakBack) < ncols else { return nil }
    return ncols - 1 - Int(peakBack)
  }

  /// Any column holds readings.
  var hasData: Bool { columns.contains { $0?.isData == true } }

  /// Starts over for a new window or column count: the radio's slot grid differs, so nothing kept
  /// still lines up.
  mutating func reset(window: UInt8, ncols: Int) {
    self = SpectrumDeviceHistory(window: window, ncols: ncols)
  }

  /// The next HISTORY poll: only the slots since the last one while the copy is valid, else
  /// everything.
  ///
  /// - Parameter skippingMarkBacklog: Ask only for the marks heard since the radio's last
  ///   snapshot, not the ones still waiting behind the cursor. The page sets it after transfers
  ///   keep failing on a crowded link, so the next ones are smaller (SPEC_SYNC's mitigation);
  ///   the skipped marks stay off the lane.
  func nextRequest(skippingMarkBacklog: Bool = false) -> CairnSpectrumHistoryRequest {
    CairnSpectrumHistoryRequest(
      window: window,
      columns: UInt8(clamping: ncols),
      epoch: epoch,
      sinceSlot: isValid ? nowSlot : 0,
      scaleLo: scaleLo,
      markSince: skippingMarkBacklog ? backlogSkippingCursor : markCursor
    )
  }

  /// The radio's last snapshot time as a mark cursor, when it is past ``markCursor`` (compared as
  /// the radio does, wrap-safe); otherwise the cursor itself.
  private var backlogSkippingCursor: UInt32 {
    guard let snapshot = stats?.nowMs, snapshot != 0 else { return markCursor }
    if markCursor == 0 || Int32(bitPattern: snapshot &- markCursor) > 0 { return snapshot }
    return markCursor
  }

  /// The grid index of an absolute slot, when it is on the grid.
  func columnIndex(slot: UInt32) -> Int? {
    guard slot <= nowSlot else { return nil }
    let back = Int(nowSlot - slot)
    guard back < ncols else { return nil }
    return ncols - 1 - back
  }

  /// The columns a mark covers, `[end + 1 - width, end + 1)`, clipped to the grid; nil when off it.
  func columnRange(of mark: DeviceMark) -> Range<Int>? {
    guard mark.endSlot <= nowSlot else { return nil }
    let end = ncols - 1 - Int(nowSlot - mark.endSlot)
    let lower = max(0, end + 1 - mark.width)
    let upper = min(ncols, end + 1)
    return lower < upper ? lower..<upper : nil
  }

  /// Folds one fetched HISTORY in. A reply for another window or column count (one asked for
  /// before a change) is passed by; one whose transfer didn't complete, or that doesn't line up,
  /// only marks the copy invalid.
  @discardableResult
  mutating func apply(_ history: CairnSpectrumHistory) -> Outcome {
    let reply = history.reply
    guard reply.status == .ok, let stats = reply.stats,
          stats.window == window, Int(reply.columns) == ncols else { return Outcome() }
    // the readings, the columns and the peak go in together or not at all
    guard history.completed, history.columns.count == Int(reply.count), Int(reply.count) <= ncols else {
      isValid = false
      return Outcome()
    }
    var outcome = Outcome(applied: true)
    outcome.epochChanged = epoch != 0 && stats.epoch != epoch
    if reply.isFull || outcome.epochChanged {
      columns = Array(repeating: nil, count: ncols)
    } else {
      // the grid slides on to the new newest slot; the radio would have sent a FULL for a jump
      // past the grid or backwards, so either one here means the copy no longer lines up
      guard isValid, reply.nowSlot >= nowSlot, Int(reply.nowSlot - nowSlot) < ncols else {
        isValid = false
        return Outcome()
      }
      let shift = Int(reply.nowSlot - nowSlot)
      if shift > 0 {
        columns.removeFirst(shift)
        columns.append(contentsOf: repeatElement(nil, count: shift))
      }
    }
    let first = ncols - Int(reply.count)
    for (offset, column) in history.columns.enumerated() {
      columns[first + offset] = column
    }

    if reply.marksReset || outcome.epochChanged {
      marks.removeAll()
    }
    var known = Set(marks.map(\.mark.rxMs))
    for mark in history.marks where UInt32(mark.back) <= reply.nowSlot && known.insert(mark.rxMs).inserted {
      marks.append(DeviceMark(mark: mark, endSlot: reply.nowSlot - UInt32(mark.back)))
    }
    // drop the marks that slid off the grid's left edge, and any past its right one: a FULL
    // after the radio's millis() wrapped starts the slots over, so older marks sit "ahead"
    let oldest = Int64(reply.nowSlot) - Int64(ncols) + 1
    marks.removeAll { Int64($0.endSlot) < oldest - Int64($0.width) || $0.endSlot > reply.nowSlot }

    self.stats = stats
    epoch = stats.epoch
    nowSlot = reply.nowSlot
    scaleLo = reply.scaleLo
    refFloor = reply.refFloor
    peakBack = reply.peakBack
    markCursor = reply.markCursor
    marksMore = reply.marksMore
    isRaw = reply.isRaw
    isValid = true
    return outcome
  }
}

extension SpectrumWindow {
  /// The radio's window index (`SpecChannelView`'s 10 s, 1 min, 10 min, 1 h).
  var deviceIndex: UInt8 {
    switch self {
    case .tenSeconds: 0
    case .oneMinute: 1
    case .tenMinutes: 2
    case .oneHour: 3
    }
  }

  /// How often the page polls the radio's view (SPEC_SYNC's app cadence).
  var deviceCadence: Duration {
    self == .tenSeconds ? .milliseconds(500) : .milliseconds(1000)
  }
}

/// SPEC_SYNC's app-side timings and sizes.
enum SpectrumDeviceFeed {
  /// Columns across the window at compact and regular width.
  static let compactColumns = 180
  static let regularColumns = 240
  /// The radio's minimum gap between HISTORY replies: the next poll while marks are still coming.
  static let minimumInterval: Duration = .milliseconds(400)
  /// After BUSY (another app's transfer) and TOO_SOON.
  static let busyBackoff: Duration = .seconds(2)
  static let tooSoonBackoff: Duration = .milliseconds(500)
  static let trendInterval: Duration = .seconds(10)
  /// The radio's minimum gap between TREND replies.
  static let trendMinimum: Duration = .seconds(2)
  /// Incomplete transfers in a row after which the page slows to the 1 s cadence and stops
  /// asking for the marks still waiting behind its cursor.
  static let slowAfterFailures = 2
  static let trendPoints: UInt8 = 160
}

/// Where the radio's slot grid falls on the phone's clock, steady from reply to reply, so a plot
/// that scrolls by the clock between replies doesn't jump each time one lands.
///
/// Each reply says which slot the radio was in and its `millis()` then. On the raw windows (10 s,
/// 1 min) that places it inside its slot exactly (`slot(t) = floor(t × ncols / window)`); on the
/// tiers (10 min, 1 h) the slots run on the radio's own seconds, whose phase it doesn't send, so
/// the reply is taken as at its slot's start. Either way a reply can only put the grid later than
/// it is, by the link's delay and on the tiers by how far into its slot it came, never earlier, so
/// the earliest placement seen is kept. It may creep later slowly, for the two clocks' drift.
struct SpectrumDeviceSlotClock: Equatable {
  /// How fast the placement may creep later, seconds per second: far past any crystal's drift.
  static let drift = 0.002
  /// Replies this much later than the placement in a row move it there: the phone's clock jumped on.
  static let jumpReplies = 3

  /// The phone's time, since the reference date, at which slot 0 began, on a grid of even slots.
  private(set) var origin: TimeInterval?
  private var grid: Grid?
  private var observedAt: TimeInterval = 0
  private var lastSlot: UInt32 = 0
  private var lateReplies = 0

  private struct Grid: Equatable {
    let window: TimeInterval
    let ncols: Int
    let epoch: UInt16
    let isRaw: Bool
  }

  mutating func reset() {
    self = SpectrumDeviceSlotClock()
  }

  /// The phone's time at which `slot` begins, nil before the first reply.
  func date(ofSlot slot: Int64, slotSeconds: TimeInterval) -> Date? {
    origin.map { Date(timeIntervalSinceReferenceDate: $0 + Double(slot) * slotSeconds) }
  }

  /// How far into its slot `nowMs` is, seconds: exact on the raw grid, 0 where it can't be told.
  static func secondsIntoSlot(nowSlot: UInt32, nowMs: UInt32, window: TimeInterval, ncols: Int, isRaw: Bool) -> TimeInterval {
    let windowMs = Int64((window * 1000).rounded())
    let columns = Int64(ncols)
    guard isRaw, windowMs > 0, columns > 0, Int64(nowMs) * columns / windowMs == Int64(nowSlot) else { return 0 }
    // the slot's first millisecond: the least t with floor(t × ncols / window) = nowSlot
    let start = (Int64(nowSlot) * windowMs + columns - 1) / columns
    return Double(Int64(nowMs) - start) / 1000
  }

  /// One reply's place on the grid.
  mutating func observe(
    nowSlot: UInt32, nowMs: UInt32, epoch: UInt16, isRaw: Bool,
    window: TimeInterval, ncols: Int, receivedAt: Date
  ) {
    let slotSeconds = window / Double(max(ncols, 1))
    let into = Self.secondsIntoSlot(nowSlot: nowSlot, nowMs: nowMs, window: window, ncols: ncols, isRaw: isRaw)
    let at = receivedAt.timeIntervalSinceReferenceDate
    let sample = at - into - Double(nowSlot) * slotSeconds
    let grid = Grid(window: window, ncols: ncols, epoch: epoch, isRaw: isRaw)
    defer {
      observedAt = at
      lastSlot = nowSlot
    }
    // another grid, a restarted history, or a slot count that went back (the millis wrap)
    guard let origin, self.grid == grid, nowSlot >= lastSlot else {
      self.grid = grid
      origin = sample
      lateReplies = 0
      return
    }
    let crept = origin + Self.drift * max(at - observedAt, 0)
    // later than a slow link or a reply deep in its slot could make it
    if sample > crept + slotSeconds + 2 {
      lateReplies += 1
      if lateReplies >= Self.jumpReplies {
        self.origin = sample
        lateReplies = 0
      }
      return
    }
    lateReplies = 0
    self.origin = min(sample, crept)
  }
}

// MARK: - Anchoring a cursor

extension SpectrumDeviceHistory {

  /// The radio's slot under `column` (index 0 the oldest, the last one `nowSlot`): what a cursor
  /// keeps, so it travels with the columns as new ones arrive.
  func slot(ofColumn column: Int) -> Int64 {
    Int64(nowSlot) - Int64(ncols - 1 - column)
  }

  /// The column now holding `slot`; nil once it has scrolled out of the window (or for no slot).
  func column(ofSlot slot: Int64?) -> Int? {
    guard let slot, ncols > 0 else { return nil }
    let column = ncols - 1 - Int(Int64(nowSlot) - slot)
    return (0..<ncols).contains(column) ? column : nil
  }
}
