import Foundation
@testable import Cairn
import Testing

@Suite("SpectrumDeviceSlotClock")
struct SpectrumDeviceSlotClockTests {
  /// 1 min over 180 columns: slots of 333⅓ ms.
  private static let window: TimeInterval = 60
  private static let ncols = 180
  private static let slotSeconds = window / Double(ncols)
  /// The phone's time at the radio's millis() 0.
  private static let boot = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private static func slot(_ ms: UInt32) -> UInt32 { UInt32(UInt64(ms) * UInt64(ncols) / 60_000) }

  private func observe(_ clock: inout SpectrumDeviceSlotClock, ms: UInt32, delay: TimeInterval) {
    clock.observe(
      nowSlot: Self.slot(ms), nowMs: ms, epoch: 1, isRaw: true, window: Self.window, ncols: Self.ncols,
      receivedAt: Self.boot.addingTimeInterval(Double(ms) / 1000 + delay)
    )
  }

  @Test
  func `the raw grid places a reply inside its slot exactly`() {
    // slot 300 starts at ms 100000; slot 301 at 100334 (the first ms past 100333⅓)
    #expect(SpectrumDeviceSlotClock.secondsIntoSlot(nowSlot: 300, nowMs: 100_200, window: 60, ncols: 180, isRaw: true) == 0.2)
    #expect(SpectrumDeviceSlotClock.secondsIntoSlot(nowSlot: 301, nowMs: 100_334, window: 60, ncols: 180, isRaw: true) == 0)
    // a slot length that isn't whole milliseconds doesn't drift: slot 3000 starts at ms 1000000
    #expect(SpectrumDeviceSlotClock.secondsIntoSlot(nowSlot: 3000, nowMs: 1_000_100, window: 60, ncols: 180, isRaw: true) == 0.1)
    // the tiers' seconds aren't on millis(); a mismatched slot isn't trusted either
    #expect(SpectrumDeviceSlotClock.secondsIntoSlot(nowSlot: 300, nowMs: 100_200, window: 600, ncols: 180, isRaw: false) == 0)
    #expect(SpectrumDeviceSlotClock.secondsIntoSlot(nowSlot: 7, nowMs: 100_200, window: 60, ncols: 180, isRaw: true) == 0)
  }

  @Test
  func `the link's delay doesn't move the grid`() throws {
    var clock = SpectrumDeviceSlotClock()
    let delays: [TimeInterval] = [0.12, 0.04, 0.31, 0.05, 0.22, 0.04, 0.6, 0.09]
    var placements: [Date] = []
    for (index, delay) in delays.enumerated() {
      let ms = UInt32(200_000 + index * 1000 + index * 37)
      observe(&clock, ms: ms, delay: delay)
      placements.append(try #require(clock.date(ofSlot: 1000, slotSeconds: Self.slotSeconds)))
    }
    // slot 1000 began at ms 333334, with the least delay seen (40 ms) on top
    let truth = Self.boot.addingTimeInterval(333.334 + 0.04)
    let settled = placements.dropFirst(2)
    for placement in settled {
      #expect(abs(placement.timeIntervalSince(truth)) < 0.02)
    }
    // and from one reply to the next it barely moves
    for (a, b) in zip(settled, settled.dropFirst()) {
      #expect(abs(b.timeIntervalSince(a)) < 0.01)
    }
  }

  @Test
  func `a clock that jumps on follows after a few replies`() throws {
    var clock = SpectrumDeviceSlotClock()
    observe(&clock, ms: 200_000, delay: 0.05)
    let before = try #require(clock.origin)
    observe(&clock, ms: 201_000, delay: 30)
    observe(&clock, ms: 202_000, delay: 30)
    #expect(clock.origin.map { abs($0 - before) < 0.01 } == true)
    observe(&clock, ms: 203_000, delay: 30)
    #expect(clock.origin.map { abs($0 - before - 29.95) < 0.01 } == true)
  }

  @Test
  func `another grid starts over`() throws {
    var clock = SpectrumDeviceSlotClock()
    observe(&clock, ms: 200_000, delay: 0.05)
    clock.observe(
      nowSlot: 90, nowMs: 205_000, epoch: 1, isRaw: false, window: 600, ncols: 180,
      receivedAt: Self.boot.addingTimeInterval(400)
    )
    #expect(clock.origin == Self.boot.addingTimeInterval(400 - 90 * (600.0 / 180)).timeIntervalSinceReferenceDate)
  }
}
