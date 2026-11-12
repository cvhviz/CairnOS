import Foundation

/// Orders the records of a Cairn radio's receive journal (firmware's `net/RX_SYNC.md`) so each
/// packet reaches the app exactly once, and keeps track of the ones still owed.
///
/// The radio numbers every packet it receives with a `seq` that grows by one within an epoch
/// (random at each boot). Records come live in order, or again for a FETCH (backfill) in any
/// order. The sequencer keeps the next `seq` it expects, the ranges it skipped (to fetch), and the
/// last ``dedupCapacity`` numbers it delivered, so a repeat is told apart from a late arrival.
///
/// Pure value type: ``MeshCoreSession`` runs one per connection and does the I/O.
public struct RxSequencer: Sendable, Equatable {
  /// What to do with a record.
  public enum Outcome: Sendable, Equatable {
    /// Deliver it: the first time this `seq` arrived, in order or ahead of a gap.
    case deliver
    /// Deliver it: it fills a gap the app was missing.
    case recover
    /// Already delivered: drop it.
    case duplicate
  }

  /// How many delivered numbers the sequencer remembers for spotting repeats.
  public static let dedupCapacity = 4096

  /// FETCHes of one missing run before the sequencer gives up on it.
  public static let maxFetchAttempts = 3

  /// The journal the records belong to; `nil` until the radio has named it.
  public private(set) var epoch: UInt32?

  /// The `seq` the next live record should carry; `nil` before the first record or cursor.
  public private(set) var nextSeq: UInt32?

  /// The first record of this epoch's delivery: anything older was never owed (the app had it
  /// from before, or the journal held it before this link subscribed).
  public private(set) var firstSeq: UInt32?

  /// The records skipped so far and not given up on, oldest first, disjoint.
  public private(set) var missing: [ClosedRange<UInt32>] = []

  /// Records delivered (each `seq` once), since the sequencer was made.
  public private(set) var delivered = 0
  /// Of ``delivered``, the records that filled a gap.
  public private(set) var recovered = 0
  /// Repeats dropped.
  public private(set) var duplicates = 0
  /// Records the radio overwrote before this link was sent them (a GAP flag, a FETCH that found
  /// them gone, a resume the journal could no longer serve).
  public private(set) var lostAtRadio = 0
  /// Missing records given up on after ``maxFetchAttempts`` FETCHes brought none of them.
  public private(set) var unrecovered = 0

  /// The last delivered numbers, oldest overwritten first, and the same as a set for lookups.
  private var ring: [UInt32] = []
  private var ringNext = 0
  private var seen: Set<UInt32> = []
  /// FETCHes so far of the missing run starting at each key.
  private var attempts: [UInt32: Int] = [:]

  public init() {}

  /// Records still missing.
  public var missingCount: Int {
    missing.reduce(0) { $0 + $1.count }
  }

  /// The newest record with none still missing at or before it: every earlier one was delivered,
  /// counted lost at the radio or given up on. A resume cursor can stand here without skipping a
  /// record a FETCH may still bring. `nil` before the first record or cursor.
  public var contiguousSeq: UInt32? {
    guard let nextSeq else { return nil }
    let floor = missing.map(\.lowerBound).min() ?? nextSeq
    return floor > 0 ? floor - 1 : nil
  }

  /// Starts delivery at `cursor` (the first record the radio will push) in journal `epoch`.
  ///
  /// A different epoch means the radio rebooted: what was owed in the old journal is dropped
  /// (the counters keep running). In the same epoch, records the radio skips past (a resume the
  /// journal capped) are counted lost, and runs already missing below `cursor` stay to be fetched.
  ///
  /// Records taken before any epoch was named came from this journal: the radio opted the link in
  /// behind a SUBSCRIBE reply that was lost. They stay delivered, their gaps stay to be fetched,
  /// and the records the radio skips past from the next one expected to `cursor` (a retry that
  /// started live) are owed too, not lost: a FETCH counts the ones the journal no longer holds.
  ///
  /// - Parameters:
  ///   - epoch: The journal's epoch, from the radio's SUBSCRIBE reply.
  ///   - cursor: The first record the radio will push.
  ///   - resumeSeq: The last record the app already had, when it asked to resume after it: the
  ///     ones between it and `cursor` count as lost. `nil` when the app had nothing to resume.
  ///   - lastSeq: The newest record the journal holds, from the same reply: records taken before
  ///     any epoch was named that are numbered past it came from an older journal (the radio
  ///     rebooted since) and are dropped. `nil` keeps them.
  public mutating func begin(
    epoch: UInt32, cursor: UInt32, after resumeSeq: UInt32? = nil, newest lastSeq: UInt32? = nil
  ) {
    let early = self.epoch == nil && nextSeq.map { next in
      lastSeq.map { UInt64(next) <= UInt64($0) + 1 } ?? true
    } == true
    if self.epoch != epoch {
      self.epoch = epoch
      if !early {
        nextSeq = nil
        firstSeq = nil
        missing = []
        ring = []
        ringNext = 0
        seen = []
        attempts = [:]
      }
    }
    if early, let current = nextSeq, cursor > current {
      // every run already missing ends before `current`, so this one goes last
      missing.append(current...(cursor - 1))
      nextSeq = cursor
      return
    }
    let expected = nextSeq ?? resumeSeq.map { $0 &+ 1 }
    if let expected, cursor > expected {
      lostAtRadio += Int(cursor - expected)
    }
    if let current = nextSeq, current > cursor { return }
    nextSeq = cursor
    if firstSeq == nil { firstSeq = cursor }
  }

  /// Owes the records after `afterSeq` through `throughSeq` that a live start skipped although the
  /// app never had them, so they are fetched like any other missing run and arrive as backfill.
  ///
  /// Only records before the first one of delivery are owed (live ones after it are ordered as
  /// usual). At most `limit` of the newest are owed: older ones count lost at the radio, as a resume
  /// the journal capped would have counted them. Call it after ``begin(epoch:cursor:after:newest:)``.
  ///
  /// - Parameters:
  ///   - afterSeq: The last record the app had.
  ///   - throughSeq: The newest record the app never received.
  ///   - limit: The most records to owe.
  public mutating func owe(after afterSeq: UInt32, through throughSeq: UInt32, limit: Int) {
    guard epoch != nil, let start = firstSeq, start > 0 else { return }
    let upper = min(throughSeq, start - 1)
    guard afterSeq < upper else { return }
    let first = afterSeq + 1
    let owed = UInt64(max(0, limit))
    let span = UInt64(upper - afterSeq)
    let lower = span > owed ? UInt32(UInt64(upper) + 1 - owed) : first
    lostAtRadio += Int(UInt64(lower) - UInt64(first))
    guard owed > 0 else { return }
    // every run already missing starts at or after `start`, so this one goes first
    missing.insert(lower...upper, at: 0)
    firstSeq = lower
  }

  /// Takes the record numbered `seq`.
  ///
  /// - Parameters:
  ///   - seq: The record's number.
  ///   - gap: The radio flagged that records before this one were overwritten undelivered: any
  ///     run this record skips is counted lost instead of fetched.
  /// - Returns: Whether to deliver it.
  public mutating func accept(seq: UInt32, gap: Bool = false) -> Outcome {
    guard let expected = nextSeq else {
      nextSeq = seq &+ 1
      firstSeq = seq
      remember(seq)
      delivered += 1
      return .deliver
    }
    if seen.contains(seq) {
      duplicates += 1
      return .duplicate
    }
    if seq >= expected {
      if seq > expected {
        let skipped = expected...(seq - 1)
        if gap {
          lostAtRadio += skipped.count
        } else {
          missing.append(skipped)
        }
      }
      nextSeq = seq &+ 1
      remember(seq)
      delivered += 1
      return .deliver
    }
    if removeMissing(seq) {
      remember(seq)
      delivered += 1
      recovered += 1
      return .recover
    }
    // Below the start of delivery nothing was owed, and below the remembered window nothing
    // tells a repeat from a late arrival: drop it.
    if seq < (firstSeq ?? 0) || expected - seq > UInt32(Self.dedupCapacity) {
      duplicates += 1
      return .duplicate
    }
    // Not delivered and no longer owed (lost or given up on): it came after all.
    remember(seq)
    delivered += 1
    return .deliver
  }

  /// Counts the missing records below `firstSeq` lost: the journal no longer holds them.
  ///
  /// - Parameter firstSeq: The oldest record the journal holds (a SUBSCRIBE or FETCH reply, or
  ///   FETCH_END).
  public mutating func markLost(below firstSeq: UInt32) {
    var kept: [ClosedRange<UInt32>] = []
    for range in missing {
      if range.upperBound < firstSeq {
        lostAtRadio += range.count
      } else if range.lowerBound < firstSeq {
        lostAtRadio += Int(firstSeq - range.lowerBound)
        kept.append(firstSeq...range.upperBound)
      } else {
        kept.append(range)
      }
    }
    missing = kept
  }

  /// The next run to FETCH: the oldest missing records, at most `limit` of them.
  public func nextFetch(limit: Int) -> ClosedRange<UInt32>? {
    guard let first = missing.first, limit > 0 else { return nil }
    let upper = first.lowerBound &+ UInt32(min(limit, first.count) - 1)
    return first.lowerBound...upper
  }

  /// Notes that a FETCH of `range` has ended (its FETCH_END arrived, or it failed).
  ///
  /// A run still missing after ``maxFetchAttempts`` FETCHes is given up on and counted in
  /// ``unrecovered``. Records that arrive later are still delivered.
  public mutating func fetchEnded(_ range: ClosedRange<UInt32>) {
    let stillMissing = missing.contains { $0.overlaps(range) }
    guard stillMissing else {
      attempts[range.lowerBound] = nil
      return
    }
    let tries = (attempts[range.lowerBound] ?? 0) + 1
    guard tries >= Self.maxFetchAttempts else {
      attempts[range.lowerBound] = tries
      return
    }
    attempts[range.lowerBound] = nil
    var kept: [ClosedRange<UInt32>] = []
    for owed in missing {
      guard owed.overlaps(range) else {
        kept.append(owed)
        continue
      }
      let lower = max(owed.lowerBound, range.lowerBound)
      let upper = min(owed.upperBound, range.upperBound)
      unrecovered += Int(upper - lower) + 1
      if owed.lowerBound < lower { kept.append(owed.lowerBound...(lower - 1)) }
      if owed.upperBound > upper { kept.append((upper + 1)...owed.upperBound) }
    }
    missing = kept
  }

  // MARK: - Private

  private mutating func remember(_ seq: UInt32) {
    if ring.count < Self.dedupCapacity {
      ring.append(seq)
    } else {
      seen.remove(ring[ringNext])
      ring[ringNext] = seq
      ringNext = (ringNext + 1) % Self.dedupCapacity
    }
    seen.insert(seq)
  }

  /// Takes `seq` out of the missing runs; `false` when it wasn't missing.
  private mutating func removeMissing(_ seq: UInt32) -> Bool {
    guard let index = missing.firstIndex(where: { $0.contains(seq) }) else { return false }
    let range = missing[index]
    var parts: [ClosedRange<UInt32>] = []
    if range.lowerBound < seq { parts.append(range.lowerBound...(seq - 1)) }
    if range.upperBound > seq { parts.append((seq + 1)...range.upperBound) }
    missing.replaceSubrange(index...index, with: parts)
    return true
  }
}
