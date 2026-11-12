import Foundation
@testable import MeshCore
import Testing

@Suite("RX_SYNC record sequencer")
struct RxSequencerTests {
  @Test
  func `records in order are each delivered once`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    #expect((1...5).map { sequencer.accept(seq: $0) } == Array(repeating: .deliver, count: 5))
    #expect(sequencer.nextSeq == 6)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.delivered == 5)
  }

  @Test
  func `a repeat is dropped`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    #expect(sequencer.accept(seq: 1) == .deliver)
    #expect(sequencer.accept(seq: 2) == .deliver)
    #expect(sequencer.accept(seq: 1) == .duplicate)
    #expect(sequencer.accept(seq: 2) == .duplicate)
    #expect(sequencer.duplicates == 2)
    #expect(sequencer.delivered == 2)
  }

  @Test
  func `a jump leaves a missing range to fetch`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 2)
    #expect(sequencer.accept(seq: 5) == .deliver)
    #expect(sequencer.missing == [3...4])
    #expect(sequencer.missingCount == 2)
    #expect(sequencer.nextFetch(limit: 32) == 3...4)
    #expect(sequencer.nextFetch(limit: 1) == 3...3)
  }

  @Test
  func `backfill fills the range and counts as recovered`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 5)
    #expect(sequencer.accept(seq: 2) == .recover)
    #expect(sequencer.accept(seq: 3) == .recover)
    #expect(sequencer.accept(seq: 4) == .recover)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.recovered == 3)
    #expect(sequencer.delivered == 5)
    #expect(sequencer.accept(seq: 5) == .duplicate)
    #expect(sequencer.nextFetch(limit: 32) == nil)
  }

  @Test
  func `out-of-order backfill splits the range and fills it in any order`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 10)
    _ = sequencer.accept(seq: 10)
    _ = sequencer.accept(seq: 20)
    #expect(sequencer.missing == [11...19])
    #expect(sequencer.accept(seq: 15) == .recover)
    #expect(sequencer.missing == [11...14, 16...19])
    #expect(sequencer.accept(seq: 19) == .recover)
    #expect(sequencer.accept(seq: 11) == .recover)
    #expect(sequencer.missing == [12...14, 16...18])
    #expect(sequencer.accept(seq: 15) == .duplicate)
  }

  @Test
  func `a GAP flag counts the skipped records lost at the radio instead of fetching them`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    #expect(sequencer.accept(seq: 10, gap: true) == .deliver)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.lostAtRadio == 8)
  }

  @Test
  func `records the journal no longer holds count lost`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 10)
    sequencer.markLost(below: 6)
    #expect(sequencer.missing == [6...9])
    #expect(sequencer.lostAtRadio == 4)
    sequencer.markLost(below: 20)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.lostAtRadio == 8)
  }

  @Test
  func `a new epoch starts over and keeps the counters`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 5)
    sequencer.begin(epoch: 9, cursor: 3)
    #expect(sequencer.epoch == 9)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.nextSeq == 3)
    // seq 1 was delivered in the old journal; in the new one it was never owed
    #expect(sequencer.accept(seq: 3) == .deliver)
    #expect(sequencer.accept(seq: 1) == .duplicate)
    #expect(sequencer.delivered == 3)
  }

  @Test
  func `resuming in the same epoch keeps what is owed and counts what the radio skipped`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 4)
    // the radio resumes after 4 as asked
    sequencer.begin(epoch: 7, cursor: 5)
    #expect(sequencer.missing == [2...3])
    #expect(sequencer.lostAtRadio == 0)
    // a capped resume skips 5...9
    sequencer.begin(epoch: 7, cursor: 10)
    #expect(sequencer.lostAtRadio == 5)
    #expect(sequencer.nextSeq == 10)
  }

  @Test
  func `a fresh resume the journal capped counts the skipped records lost`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 600, after: 50)
    #expect(sequencer.lostAtRadio == 549)
    #expect(sequencer.accept(seq: 600) == .deliver)
  }

  @Test
  func `a run is given up after three fetches that bring none of it`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 5)
    sequencer.fetchEnded(2...4)
    sequencer.fetchEnded(2...4)
    #expect(sequencer.missing == [2...4])
    sequencer.fetchEnded(2...4)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.unrecovered == 3)
    // it came after all: delivered, once
    #expect(sequencer.accept(seq: 3) == .deliver)
    #expect(sequencer.accept(seq: 3) == .duplicate)
  }

  @Test
  func `fetches never ask for more than the limit`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    _ = sequencer.accept(seq: 1)
    _ = sequencer.accept(seq: 100)
    #expect(sequencer.nextFetch(limit: 32) == 2...33)
  }

  @Test
  func `the dedup window holds the last 4096 records`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1)
    for seq in UInt32(1)...5000 {
      _ = sequencer.accept(seq: seq)
    }
    #expect(sequencer.accept(seq: 5000) == .duplicate)
    #expect(sequencer.accept(seq: 905) == .duplicate)
    // older than the window: still never delivered twice
    #expect(sequencer.accept(seq: 10) == .duplicate)
    #expect(sequencer.delivered == 5000)
  }

  // MARK: - Owed backlog

  @Test
  func `a backlog a live start skipped is owed and fetched before the live records`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 101)
    sequencer.owe(after: 40, through: 90, limit: 512)
    #expect(sequencer.missing == [41...90])
    #expect(sequencer.firstSeq == 41)
    #expect(sequencer.lostAtRadio == 0)
    #expect(sequencer.contiguousSeq == 40, "a resume cursor stays before the backlog")
    #expect(sequencer.accept(seq: 101) == .deliver)
    #expect(sequencer.nextFetch(limit: 32) == 41...72)
    #expect(sequencer.accept(seq: 41) == .recover)
    #expect(sequencer.accept(seq: 41) == .duplicate)
    // between the newest owed and the cursor the app already had them (0x88 frames): not owed
    #expect(sequencer.missing == [42...90])
  }

  @Test
  func `an owed backlog longer than the limit counts its oldest records lost`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 1001)
    sequencer.owe(after: 100, through: 900, limit: 512)
    #expect(sequencer.missing == [389...900])
    #expect(sequencer.lostAtRadio == 288)

    var none = RxSequencer()
    none.begin(epoch: 7, cursor: 1001)
    none.owe(after: 100, through: 900, limit: 0)
    #expect(none.missing.isEmpty)
    #expect(none.lostAtRadio == 800)
  }

  @Test
  func `only records before the start of delivery are owed`() {
    var sequencer = RxSequencer()
    sequencer.begin(epoch: 7, cursor: 50)
    sequencer.owe(after: 40, through: 80, limit: 512)
    #expect(sequencer.missing == [41...49], "live records from the cursor on are ordered as usual")

    var caughtUp = RxSequencer()
    caughtUp.begin(epoch: 7, cursor: 50)
    caughtUp.owe(after: 49, through: 80, limit: 512)
    #expect(caughtUp.missing.isEmpty)

    var unnamed = RxSequencer()
    unnamed.owe(after: 1, through: 9, limit: 512)
    #expect(unnamed.missing.isEmpty, "nothing is owed before the radio names its journal")
  }

  // MARK: - Records behind a lost reply

  @Test
  func `records taken behind a lost reply keep their gaps, and what the retry skipped is owed`() {
    var sequencer = RxSequencer()
    // the radio opted the link in behind a lost reply: 4 was dropped, 6...8 not pushed yet
    _ = sequencer.accept(seq: 3)
    _ = sequencer.accept(seq: 5)
    // the retry started live, past them
    sequencer.begin(epoch: 7, cursor: 9, newest: 8)
    #expect(sequencer.epoch == 7)
    #expect(sequencer.missing == [4...4, 6...8])
    #expect(sequencer.firstSeq == 3)
    #expect(sequencer.nextSeq == 9)
    #expect(sequencer.lostAtRadio == 0)
    #expect(sequencer.contiguousSeq == 3, "a resume cursor stays before the gap")
    #expect(sequencer.nextFetch(limit: 32) == 4...4)
    #expect(sequencer.accept(seq: 5) == .duplicate)
    #expect(sequencer.accept(seq: 4) == .recover)
    #expect(sequencer.accept(seq: 9) == .deliver)
    #expect(sequencer.nextFetch(limit: 32) == 6...8)
  }

  @Test
  func `owed records behind a lost reply the journal no longer holds count lost`() {
    var sequencer = RxSequencer()
    _ = sequencer.accept(seq: 3)
    _ = sequencer.accept(seq: 5)
    sequencer.begin(epoch: 7, cursor: 10, newest: 9)
    // the journal now starts at 7
    sequencer.markLost(below: 7)
    #expect(sequencer.missing == [7...9])
    #expect(sequencer.lostAtRadio == 2)
    #expect(sequencer.contiguousSeq == 6)
  }

  @Test
  func `records behind a lost reply with no gap owe nothing`() {
    var sequencer = RxSequencer()
    _ = sequencer.accept(seq: 3)
    _ = sequencer.accept(seq: 4)
    sequencer.begin(epoch: 7, cursor: 5, newest: 4)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.lostAtRadio == 0)
    #expect(sequencer.firstSeq == 3)
    #expect(sequencer.contiguousSeq == 4)
    #expect(sequencer.accept(seq: 4) == .duplicate)
    #expect(sequencer.accept(seq: 5) == .deliver)
  }

  @Test
  func `a backlog is owed only up to the first record taken behind a lost reply`() {
    var sequencer = RxSequencer()
    _ = sequencer.accept(seq: 5)
    _ = sequencer.accept(seq: 6)
    sequencer.begin(epoch: 7, cursor: 7, newest: 6)
    sequencer.owe(after: 2, through: 6, limit: 512)
    #expect(sequencer.missing == [3...4])
    #expect(sequencer.firstSeq == 3)
  }

  @Test
  func `records numbered past the journal's newest came from an older one and are dropped`() {
    var sequencer = RxSequencer()
    _ = sequencer.accept(seq: 50)
    _ = sequencer.accept(seq: 52)
    // the radio rebooted before it answered: its new journal holds 1...4
    sequencer.begin(epoch: 9, cursor: 5, newest: 4)
    #expect(sequencer.missing.isEmpty)
    #expect(sequencer.nextSeq == 5)
    #expect(sequencer.firstSeq == 5)
    #expect(sequencer.lostAtRadio == 0)
  }
}
