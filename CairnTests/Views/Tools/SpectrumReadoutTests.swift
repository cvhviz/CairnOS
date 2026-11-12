@testable import Cairn
import Foundation
import MeshCore
import Testing

/// The cursor readout against the firmware's own `L2SpecReadout` vectors (test_l2_spectrum), so the
/// app and the radio print the same line.
@Suite("Spectrum readout")
struct SpectrumReadoutTests {
  private static let dot = " \u{00B7} "

  private func full() -> SpectrumReadout.Input {
    SpectrumReadout.Input(
      when: "-42 s", hasData: true, isTX: false, min: -112, avg: -109, max: -96, nf: -118, snrX4: 25, busy: 8
    )
  }

  @Test
  func `ages read as the radio's`() {
    #expect(SpectrumReadout.age(milliseconds: 0) == "now")
    #expect(SpectrumReadout.age(milliseconds: 499) == "now")
    #expect(SpectrumReadout.age(milliseconds: 500) == "-1 s")
    #expect(SpectrumReadout.age(milliseconds: 42000) == "-42 s")
    #expect(SpectrumReadout.age(milliseconds: 150_000) == "-2.5 m")
    #expect(SpectrumReadout.age(milliseconds: 840_000) == "-14 m")
  }

  @Test
  func `minutes under ten keep a cut tenth`() {
    // 99.5 s rounds to 100 s: 1 min 40 s, tenths cut (40 / 6 = 6)
    #expect(SpectrumReadout.age(milliseconds: 99_500) == "-1.6 m")
    #expect(SpectrumReadout.age(milliseconds: 599_000) == "-9.9 m")
    #expect(SpectrumReadout.age(milliseconds: 600_000) == "-10 m")
  }

  @Test
  func `each level drops one part in the radio's order`() {
    let input = full()
    let d = Self.dot
    #expect(SpectrumReadout.line(input, level: 0) == "-42 s\(d)min -112 avg -109 max -96\(d)NF -118\(d)SNR 6.25\(d)busy 8%")
    #expect(SpectrumReadout.line(input, level: 1) == "-42 s\(d)avg -109 max -96\(d)NF -118\(d)SNR 6.25\(d)busy 8%")
    #expect(SpectrumReadout.line(input, level: 2) == "-42 s\(d)avg -109 max -96\(d)NF -118\(d)SNR 6.25")
    #expect(SpectrumReadout.line(input, level: 3) == "-42 s\(d)avg -109 max -96\(d)NF -118")
    #expect(SpectrumReadout.line(input, level: 4) == "-42 s\(d)avg -109 max -96")
    #expect(SpectrumReadout.lines(input).count == SpectrumReadout.levels)
  }

  @Test
  func `negative SNR, no packet, gaps and transmits`() {
    var input = full()
    let d = Self.dot
    input.snrX4 = -51
    #expect(SpectrumReadout.line(input, level: 2) == "-42 s\(d)avg -109 max -96\(d)NF -118\(d)SNR -12.75")
    input.snrX4 = nil
    input.nf = nil
    input.busy = nil
    #expect(SpectrumReadout.line(input, level: 0) == "-42 s\(d)min -112 avg -109 max -96")
    input.hasData = false
    input.isTX = true
    #expect(SpectrumReadout.line(input, level: 0) == "-42 s\(d)transmitting")
    input.isTX = false
    #expect(SpectrumReadout.line(input, level: 0) == "-42 s\(d)no data")
  }

  @Test
  func `SNR keeps the radio's two decimals`() {
    #expect(SpectrumReadout.snr(x4: 25) == "6.25")
    #expect(SpectrumReadout.snr(x4: 28) == "7.00")
    #expect(SpectrumReadout.snr(x4: -2) == "-0.50")
    #expect(SpectrumReadout.snr(x4: 0) == "0.00")
  }

  @Test
  func `a column's readout comes from the radio's view`() {
    var history = SpectrumDeviceHistory(window: 1, ncols: 180)
    let column = CairnSpectrumColumn(isData: true, isTX: false, min: -112, max: -96, avg: -109, nf: -118, busy: 8)
    let mark = CairnSpectrumMark(back: 0, width: 3, header: 0x11, pathLength: 2, rssi: -91, snrX4: 25, length: 101, rxMs: 5000)
    let stats = CairnSpectrumStats(
      floorCalibrated: true, sweeping: false, fast: true, epoch: 3, nowMs: 6000, frequencyKHz: 869_525,
      bandwidthHz: 250_000, spreadingFactor: 11, codingRate: 5, window: 1, nowRSSI: -91, floor: -112,
      thermal: -120, busyPercent: 7, packetsPerMinuteX10: 60, airX10: 36, rxAirX10: 31, txAirX10: 5,
      packets: 6, coveredSeconds: 60, statsSeconds: 60, peak: -96
    )
    let reply = CairnSpectrumHistoryReply(
      status: .ok, stats: stats, xfer: 1, isFull: true, columns: 180, nowSlot: 1000, count: 180, scaleLo: -120,
      refFloor: -112, peakBack: 0, marks: 1, frames: 1, markCursor: 5000
    )
    let columns: [CairnSpectrumColumn?] = Array(repeating: CairnSpectrumColumn.gap, count: 179) + [column]
    history.apply(CairnSpectrumHistory(reply: reply, columns: columns, marks: [mark], completed: true))

    // the newest column is 1/6 s old at its middle: "now"; the mark over it gives the SNR
    let input = history.readoutInput(column: 179)
    #expect(input == SpectrumReadout.Input(
      when: "now", hasData: true, isTX: false, min: -112, avg: -109, max: -96, nf: -118, snrX4: 25, busy: 8
    ))
    #expect(history.readoutInput(column: 0).hasData == false)
    // a column 42 s back: 126 columns of 1/3 s
    #expect(history.readoutInput(column: 179 - 126).when == "-42 s")
    #expect(history.level(ofColumn: 179) == .signal)
  }
}
