import Foundation
@testable import Cairn
import MeshCore
import Testing

// MARK: - Fixtures

private func stats(
  window: UInt8 = 1, epoch: UInt16 = 3, floor: Int8? = -112, now: Int8? = -91, nowMs: UInt32 = 200_000
) -> CairnSpectrumStats {
  CairnSpectrumStats(
    floorCalibrated: floor != nil, sweeping: false, fast: true, epoch: epoch, nowMs: nowMs,
    frequencyKHz: 869_525, bandwidthHz: 250_000, spreadingFactor: 11, codingRate: 5, window: window,
    nowRSSI: now, floor: floor, thermal: -120, busyPercent: 7, packetsPerMinuteX10: 60, airX10: 36,
    rxAirX10: 31, txAirX10: 5, packets: 6, coveredSeconds: 60, statsSeconds: 60, peak: -84
  )
}

/// A column whose max tells it apart.
private func column(_ max: Int8) -> CairnSpectrumColumn {
  CairnSpectrumColumn(isData: true, isTX: false, min: -115, max: max, avg: -110, nf: -118, busy: 8)
}

private func mark(back: UInt8, width: UInt8 = 2, rxMs: UInt32) -> CairnSpectrumMark {
  CairnSpectrumMark(back: back, width: width, header: 0x11, pathLength: 2, rssi: -91, snrX4: 29, length: 101, rxMs: rxMs)
}

private func history(
  window: UInt8 = 1, ncols: UInt8 = 180, epoch: UInt16 = 3, full: Bool, marksReset: Bool = false,
  nowSlot: UInt32, columns: [CairnSpectrumColumn], marks: [CairnSpectrumMark] = [], marksMore: UInt16 = 0,
  scaleLo: Int8 = -120, markCursor: UInt32 = 0, completed: Bool = true, now: Int8? = -91,
  nowMs: UInt32 = 200_000, receivedAt: Date = Date()
) -> CairnSpectrumHistory {
  let reply = CairnSpectrumHistoryReply(
    status: .ok, stats: stats(window: window, epoch: epoch, now: now, nowMs: nowMs), xfer: 1, isFull: full, isRaw: true,
    marksReset: marksReset, columns: ncols, nowSlot: nowSlot, count: UInt8(columns.count), scaleLo: scaleLo,
    refFloor: -112, peakBack: 3, marks: UInt8(marks.count), marksMore: marksMore, frames: 1,
    markCursor: markCursor
  )
  return CairnSpectrumHistory(
    reply: reply, columns: columns, marks: marks, completed: completed, receivedAt: receivedAt
  )
}

/// A FULL of 180 columns, column i's max = -100 + i % 50, ending at `nowSlot`.
private func fullHistory(nowSlot: UInt32 = 1000, epoch: UInt16 = 3, scaleLo: Int8 = -120) -> CairnSpectrumHistory {
  history(epoch: epoch, full: true, nowSlot: nowSlot, columns: (0..<180).map { column(Int8(-100 + $0 % 50)) }, scaleLo: scaleLo)
}

// MARK: - Tests

@Suite("Spectrum device history")
struct SpectrumDeviceHistoryTests {
  @Test
  func `a new view asks for everything`() {
    let model = SpectrumDeviceHistory(window: 1, ncols: 180)
    #expect(model.nextRequest() == CairnSpectrumHistoryRequest(window: 1, columns: 180))
    #expect(!model.isValid)
    #expect(!model.hasData)
  }

  @Test
  func `a FULL replaces every column and seeds the next request`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(fullHistory())
    #expect(model.isValid)
    #expect(model.columns.allSatisfy { $0 != nil })
    #expect(model.columns.first??.max == -100)
    #expect(model.nowSlot == 1000)
    #expect(model.peakColumn == 176)
    let next = model.nextRequest()
    #expect(next.sinceSlot == 1000)
    #expect(next.epoch == 3)
    #expect(next.scaleLo == -120)
  }

  @Test
  func `an incremental reply slides the grid and overwrites its columns`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(fullHistory())
    let before = model.columns
    // since 1000, now 1002: slots 1000...1002, the old newest (partial) column sent again
    model.apply(history(full: false, nowSlot: 1002, columns: [column(-60), column(-61), column(-62)]))
    #expect(model.nowSlot == 1002)
    #expect(Array(model.columns.prefix(177)) == Array(before.dropFirst(2).prefix(177)))
    #expect(model.columns.suffix(3).map { $0?.max } == [-60, -61, -62])
    #expect(model.isValid)
  }

  @Test
  func `an incomplete transfer keeps the grid but asks for everything next`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(fullHistory())
    let before = model.columns
    let outcome = model.apply(history(
      epoch: 4, full: false, nowSlot: 1001, columns: [column(-60), column(-61)], completed: false, now: -70,
      nowMs: 201_000
    ))
    #expect(!outcome.applied)
    #expect(!outcome.epochChanged)
    #expect(!model.isValid)
    #expect(model.columns == before)
    #expect(model.nowSlot == 1000)
    // its readings stay out too, so NOW, the peak and the columns are still one moment
    #expect(model.stats?.nowRSSI == -91)
    #expect(model.stats?.nowMs == 200_000)
    #expect(model.epoch == 3)
    #expect(model.peakColumn == 176)
    #expect(model.nextRequest().sinceSlot == 0)
    model.apply(fullHistory(nowSlot: 1005))
    #expect(model.isValid)
    #expect(model.nowSlot == 1005)
  }

  @Test
  func `an incremental reply that doesn't line up invalidates the copy`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(fullHistory())
    // a jump past the whole grid (the radio would have sent a FULL)
    #expect(!model.apply(history(full: false, nowSlot: 1300, columns: [column(-60)], now: -70)).applied)
    #expect(!model.isValid)
    #expect(model.stats?.nowRSSI == -91)
    model.apply(fullHistory())
    // backwards (the millis wrap; the radio sends a FULL for it)
    model.apply(history(full: false, nowSlot: 10, columns: [column(-60)]))
    #expect(!model.isValid)
  }

  @Test
  func `a FULL after a scale change carries the new bottom`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(fullHistory(scaleLo: -120))
    model.apply(fullHistory(nowSlot: 1001, scaleLo: -114))
    #expect(model.scaleLo == -114)
    #expect(model.nextRequest().scaleLo == -114)
    #expect(model.nextRequest().sinceSlot == 1001)
  }

  @Test
  func `a reply for another window or width is passed by`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(history(window: 2, full: true, nowSlot: 50, columns: (0..<180).map { _ in column(-90) }))
    #expect(!model.isValid)
    #expect(model.stats == nil)
    model.apply(history(ncols: 240, full: true, nowSlot: 50, columns: (0..<240).map { _ in column(-90) }))
    #expect(!model.isValid)
  }

  @Test
  func `a window or width change starts over from slot zero`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 3, rxMs: 500)], markCursor: 500))
    #expect(model.nextRequest().markSince == 500)
    model.reset(window: 3, ncols: 240)
    #expect(model.nextRequest() == CairnSpectrumHistoryRequest(window: 3, columns: 240))
    #expect(model.marks.isEmpty)
    #expect(model.columns.count == 240)
  }

  @Test
  func `marks are placed by slot, kept once and dropped off the left edge`() throws {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 175, width: 3, rxMs: 100), mark(back: 5, rxMs: 900)], markCursor: 900))
    #expect(model.marks.map(\.endSlot) == [825, 995])
    let first = try #require(model.marks.first)
    #expect(model.columnRange(of: first) == 2..<5)
    #expect(model.markCursor == 900)
    // the same mark again (an overlap) and a new one; the grid moves on 10 slots
    model.apply(history(full: false, nowSlot: 1010, columns: (0..<11).map { _ in column(-90) },
                        marks: [mark(back: 15, rxMs: 900), mark(back: 1, rxMs: 1500)], markCursor: 1500))
    #expect(model.marks.map(\.mark.rxMs) == [900, 1500])   // 825 + 3 is off a grid starting at 831
    #expect(model.marks.map(\.endSlot) == [995, 1009])
    #expect(model.nextRequest().markSince == 1500)
  }

  @Test
  func `a mark covers at least two columns, as on the radio`() throws {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 10, width: 0, rxMs: 100), mark(back: 5, width: 1, rxMs: 200)]))
    let ranges = model.marks.compactMap { model.columnRange(of: $0) }
    #expect(ranges == [168..<170, 173..<175])
    // a tap a column left of the narrow mark's drawn span still reaches it
    #expect(model.nearestMark(toColumn: 173, within: 0)?.mark.rxMs == 200)
    #expect(model.nearestMark(toColumn: 172, within: 0) == nil)
  }

  @Test
  func `MARKS_RESET and an epoch change drop the cached marks`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 5, rxMs: 900)]))
    model.apply(history(full: true, marksReset: true, nowSlot: 1001, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 1, rxMs: 950)]))
    #expect(model.marks.map(\.mark.rxMs) == [950])
    let outcome = model.apply(history(epoch: 4, full: true, marksReset: true, nowSlot: 7,
                                      columns: (0..<180).map { _ in column(-80) }))
    #expect(outcome.epochChanged)
    #expect(model.marks.isEmpty)
    #expect(model.epoch == 4)
    #expect(model.nextRequest().epoch == 4)
  }

  @Test
  func `a FULL after the radio's millis wrapped drops the marks ahead of the grid`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    model.apply(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 5, rxMs: 900)], markCursor: 900))
    #expect(model.marks.map(\.endSlot) == [995])
    // millis() wrapped: the radio's slots start over and it sends a FULL (since_slot > now_slot)
    model.apply(history(full: true, nowSlot: 20, columns: (0..<180).map { _ in column(-90) },
                        marks: [mark(back: 2, rxMs: 40)], markCursor: 40))
    #expect(model.marks.map(\.mark.rxMs) == [40])
    #expect(model.marks.map(\.endSlot) == [18])
  }

  @Test
  func `skipping the mark backlog asks from the radio's last snapshot`() {
    var model = SpectrumDeviceHistory(window: 1, ncols: 180)
    // no snapshot yet: nothing to skip to
    #expect(model.nextRequest(skippingMarkBacklog: true).markSince == 0)
    model.apply(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                        marksMore: 300, markCursor: 900))
    #expect(model.nextRequest().markSince == 900)
    #expect(model.nextRequest(skippingMarkBacklog: true).markSince == 200_000)   // the stats' nowMs
    // a cursor already past the snapshot (wrap-safe) is kept
    model.apply(history(full: false, nowSlot: 1001, columns: [column(-90), column(-90)],
                        markCursor: 200_500))
    #expect(model.nextRequest(skippingMarkBacklog: true).markSince == 200_500)
  }

  @Test
  func `windows map to the radio's index and cadence`() {
    #expect(SpectrumWindow.allCases.map(\.deviceIndex) == [0, 1, 2, 3])
    #expect(SpectrumWindow.tenSeconds.deviceCadence == .milliseconds(500))
    #expect(SpectrumWindow.oneHour.deviceCadence == .milliseconds(1000))
  }
}

@Suite("Spectrum device feed")
@MainActor
struct SpectrumDeviceFeedTests {
  @Test
  func `polls at the minimum interval while marks are still coming`() {
    let model = SpectrumViewModel()
    model.deviceWindow = .oneHour
    let full = history(window: 3, full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) }, marksMore: 300)
    #expect(model.applyDevice(full) == SpectrumDeviceFeed.minimumInterval)
    let done = history(window: 3, full: false, nowSlot: 1001, columns: [column(-90), column(-90)])
    #expect(model.applyDevice(done) == .milliseconds(1000))
  }

  @Test
  func `slows to one second after incomplete transfers`() {
    let model = SpectrumViewModel()
    model.deviceWindow = .tenSeconds
    let broken = history(window: 0, full: true, nowSlot: 10, columns: [], completed: false)
    #expect(model.applyDevice(broken) == .milliseconds(500))
    #expect(model.applyDevice(broken) == .seconds(1))
    let whole = history(window: 0, full: true, nowSlot: 10, columns: (0..<180).map { _ in column(-90) })
    #expect(model.applyDevice(whole) == .milliseconds(500))
  }

  @Test
  func `skips the mark backlog only after transfers keep failing`() {
    let model = SpectrumViewModel()
    model.deviceWindow = .oneMinute
    model.applyDevice(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                              marksMore: 300, markCursor: 900))
    #expect(model.nextDeviceRequest.markSince == 900)
    let broken = history(full: true, nowSlot: 1001, columns: [], completed: false)
    model.applyDevice(broken)
    #expect(model.nextDeviceRequest.markSince == 900)
    model.applyDevice(broken)
    #expect(model.nextDeviceRequest.markSince == 200_000)
    #expect(model.nextDeviceRequest.sinceSlot == 0)
  }

  @Test
  func `the marks are dated from when the reply arrived, and only with its columns`() {
    let model = SpectrumViewModel()
    model.deviceWindow = .oneMinute
    let arrived = Date(timeIntervalSince1970: 1_800_000_000)
    model.applyDevice(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                              receivedAt: arrived))
    #expect(model.deviceStatsDate == arrived)
    let broken = history(full: false, nowSlot: 1001, columns: [], completed: false, now: -70,
                         nowMs: 201_000, receivedAt: arrived.addingTimeInterval(1))
    model.applyDevice(broken)
    #expect(model.deviceStatsDate == arrived)
    #expect(model.deviceHistory.stats?.nowMs == 200_000)
    #expect(model.deviceHistory.stats?.nowRSSI == -91)
  }

  @Test
  func `a window change starts the radio's view over with a FULL`() {
    let model = SpectrumViewModel()
    model.deviceWindow = .oneMinute
    model.applyDevice(history(full: true, nowSlot: 1000, columns: (0..<180).map { _ in column(-90) },
                              markCursor: 900))
    #expect(model.nextDeviceRequest.sinceSlot == 1000)
    model.deviceWindow = .tenMinutes
    #expect(model.nextDeviceRequest == CairnSpectrumHistoryRequest(window: 2, columns: 180))
    #expect(!model.deviceHistory.hasData)
  }

  @Test
  func `the poll stops when the link goes and starts again when it's back`() {
    let up = SpectrumPollKey(servicesVersion: 3, services: ObjectIdentifier(NSObject.self), isConnected: true, isActive: true)
    #expect(up.polls)
    let gone = SpectrumPollKey(servicesVersion: 3, services: nil, isConnected: false, isActive: true)
    #expect(gone != up)
    #expect(!gone.polls)
    // the services can outlive the link for a moment: a link that isn't up still stops the poll
    let dropping = SpectrumPollKey(servicesVersion: 3, services: up.services, isConnected: false, isActive: true)
    #expect(dropping != up)
    #expect(!dropping.polls)
    let back = SpectrumPollKey(servicesVersion: 4, services: ObjectIdentifier(NSString.self), isConnected: true, isActive: true)
    #expect(back != gone)
    #expect(back.polls)
    let background = SpectrumPollKey(servicesVersion: 3, services: up.services, isConnected: true, isActive: false)
    #expect(!background.polls)
  }

  @Test
  func `the trend becomes a day of floor samples`() {
    let end = Date(timeIntervalSince1970: 1_800_000_000)
    let trend = CairnSpectrumTrend(epoch: 3, thermal: -120, have: 1, points: [-115, nil, -110, -109])
    let samples = SpectrumViewModel.samples(of: trend, endingAt: end)
    #expect(samples.map(\.dBm) == [-115, -110, -109])
    #expect(samples.first?.date == end.addingTimeInterval(-86_400 + 10_800))
    #expect(samples.last?.date == end.addingTimeInterval(-10_800))
  }
}
