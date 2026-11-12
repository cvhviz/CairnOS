@testable import Cairn
import CoreGraphics
import Foundation
import MeshCore
import Testing

/// Where the device card puts things, against the radio's own drawing rules (`SpecChannelView`).
@Suite("Spectrum device geometry")
struct SpectrumDeviceGeometryTests {
  // MARK: Trace scale

  @Test
  func `a dB row a 56th of the trace, clamped at both ends`() {
    let scale = SpectrumTraceGeometry(scaleLo: -120, height: 112)
    #expect(scale.rowHeight == 2)
    #expect(scale.row(-120) == 0)
    #expect(scale.row(-200) == 0)
    #expect(scale.row(-65) == 55)
    #expect(scale.row(0) == 55)
    // the middle of a row: the bottom row's at 1 pt over the bottom, the top row's 1 pt under the top
    #expect(scale.y(-120) == 111)
    #expect(scale.y(-65) == 1)
  }

  @Test
  func `a bar covers whole rows from its max to its min`() {
    let scale = SpectrumTraceGeometry(scaleLo: -120, height: 112)
    #expect(scale.bar(min: -112, max: -96) == 62...96)
    // one reading still draws its row
    #expect(scale.bar(min: -110, max: -110) == 90...92)
    // swapped inputs give the same bar
    #expect(scale.bar(min: -96, max: -112) == 62...96)
  }

  @Test
  func `gridlines every 12 dB on multiples of 12 inside the scale`() {
    #expect(SpectrumTraceGeometry(scaleLo: -120, height: 140).gridlines == [-120, -108, -96, -84, -72])
    #expect(SpectrumTraceGeometry(scaleLo: -118, height: 140).gridlines == [-108, -96, -84, -72])
    // the top row is lo + 55: -64 + 56 - 1 = -9, so 0 is outside and -12 inside
    #expect(SpectrumTraceGeometry(scaleLo: -64, height: 140).gridlines == [-60, -48, -36, -24, -12])
  }

  @Test
  func `labels skip the key row and the floor rule`() {
    // 140 pt over 56 dB: 2.5 pt a dB
    let scale = SpectrumTraceGeometry(scaleLo: -120, height: 140)
    // -72 sits 18.75 pt from the top, inside the radio's 14 dB (35 pt) key band; -120 sits 8 dB
    // (20 pt) under a -112 floor, just clear of the radio's 8-row rule, while -108 is 4 dB over it
    // and gives way, as on the radio
    #expect(scale.labelledGridlines(floor: -112) == [-120, -96, -84])
    // a floor at -110 sits 2 dB (5 pt) under the -108 line: that label gives way
    #expect(scale.labelledGridlines(floor: -110) == [-120, -96, -84])
    // the radio's 8-row rule: 7 dB (17.5 pt, past a label's height) still gives way
    #expect(scale.labelledGridlines(floor: -113) == [-96, -84])
    // and on a taller trace too, where 7 dB is 22.75 pt
    #expect(SpectrumTraceGeometry(scaleLo: -120, height: 182).labelledGridlines(floor: -113) == [-96, -84])
  }

  @Test
  func `level bands split at +6, +20 and +35 over the floor`() {
    let scale = SpectrumTraceGeometry(scaleLo: -120, height: 112)
    let bands = scale.levelBands(floor: -112)
    #expect(bands.map(\.level) == [.noise, .signal, .strong, .veryStrong])
    // noise: rows 0..13 (-120...-107); the signal from -106 (row 14)
    #expect(bands[0].bottom == 112)
    #expect(bands[0].top == CGFloat(84))
    #expect(bands[1].top == CGFloat(56))   // strong from -92: row 28
    #expect(bands[2].top == CGFloat(26))   // very strong from -77: row 43
    #expect(bands[3].top == 0)
  }

  @Test
  func `bands without room are left out`() {
    let scale = SpectrumTraceGeometry(scaleLo: -120, height: 112)
    // a floor at the top: everything is noise
    #expect(scale.levelBands(floor: -40).map(\.level) == [.noise])
    // a floor far under the scale: everything is very strong
    #expect(scale.levelBands(floor: -200).map(\.level) == [.veryStrong])
  }

  // MARK: Columns and marks

  @Test
  func `columns share one x`() {
    let geometry = SpectrumColumnGeometry(columns: 180, width: 360)
    #expect(geometry.columnWidth == 2)
    #expect(geometry.x(0) == 0)
    #expect(geometry.x(180) == 360)
    #expect(geometry.column(at: 0) == 0)
    #expect(geometry.column(at: 3.9) == 1)
    #expect(geometry.column(at: 359.9) == 179)
    #expect(geometry.column(at: 500) == 179)
    #expect(geometry.column(at: -4) == 0)
  }

  @Test
  func `a mark spans its columns and never draws under 2 pt`() {
    let wide = SpectrumColumnGeometry(columns: 240, width: 360)
    #expect(wide.markSpan(10..<14) == 15...21)
    // one 1.5 pt column widens to the left, keeping its end
    #expect(wide.markSpan(10..<11) == 14.5...16.5)
    // at the left edge it widens to the right
    #expect(wide.markSpan(0..<1) == 0...2)
  }

  @Test
  func `the lane picks the mark nearest a tap, within 5 columns, the newer on a tie`() {
    var history = SpectrumDeviceHistory(window: 1, ncols: 180)
    let marks = [
      CairnSpectrumMark(back: 20, width: 2, header: 0x11, pathLength: 0, rssi: -90, snrX4: 20, length: 40, rxMs: 1000),
      CairnSpectrumMark(back: 10, width: 2, header: 0x0A, pathLength: 0, rssi: -80, snrX4: 30, length: 30, rxMs: 2000),
    ]
    history.apply(Self.history(marks: marks))
    // the first ends at column 159 (158...159), the second at 169 (168...169)
    #expect(history.nearestMark(toColumn: 158)?.mark.rxMs == 1000)
    #expect(history.nearestMark(toColumn: 163)?.mark.rxMs == 1000)
    // 164: 5 from the older, 4 from the newer
    #expect(history.nearestMark(toColumn: 164)?.mark.rxMs == 2000)
    #expect(history.nearestMark(toColumn: 174)?.mark.rxMs == 2000)
    #expect(history.nearestMark(toColumn: 175) == nil)
    #expect(history.nearestMark(toColumn: 140) == nil)
    #expect(history.mark(overColumn: 169)?.mark.rxMs == 2000)
    #expect(history.mark(overColumn: 165) == nil)

    // two packets ending in the same column: the newer
    var tied = SpectrumDeviceHistory(window: 1, ncols: 180)
    tied.apply(Self.history(marks: [
      CairnSpectrumMark(back: 10, width: 2, header: 0x11, pathLength: 0, rssi: -90, snrX4: 20, length: 40, rxMs: 2000),
      CairnSpectrumMark(back: 10, width: 2, header: 0x0A, pathLength: 0, rssi: -80, snrX4: 30, length: 30, rxMs: 2001),
    ]))
    #expect(tied.nearestMark(toColumn: 169)?.mark.rxMs == 2001)
    #expect(tied.mark(overColumn: 168)?.mark.rxMs == 2001)
  }

  // MARK: Density

  @Test
  func `density row 0 at the bottom, 28 rows tall`() {
    #expect(SpectrumDensityGeometry.rows == 28)
    #expect(SpectrumDensityGeometry.rowSpan(0, height: 112) == 108...112)
    #expect(SpectrumDensityGeometry.rowSpan(27, height: 112) == 0...4)
    #expect(SpectrumDensityGeometry.rowSpan(2, height: 112) == 100...104)
  }

  @Test
  func `the heat table widens the radio's RGB565 to the spec's 8-bit values`() {
    #expect(SpectrumHeat.count == 32)
    #expect(SpectrumHeat.rgb(8) == 0x5A106B)
    #expect(SpectrumHeat.rgb(12) == 0x8C246B)
    #expect(SpectrumHeat.rgb(16) == 0xC63852)
    #expect(SpectrumHeat.rgb(23) == 0xFF8A08)
    #expect(SpectrumHeat.rgb(28) == 0xF7DB4A)
    #expect(SpectrumHeat.rgb(31) == 0xFFFFA5)
    #expect(SpectrumHeat.rgb(0) == 0)
    // the key runs from the faintest drawn step to the brightest
    #expect(SpectrumHeat.keyIndex(0, steps: 32) == 3)
    #expect(SpectrumHeat.keyIndex(31, steps: 32) == 31)
  }

  @Test
  func `every occupancy step 8...31 is the spec's inferno value`() {
    let spec: [Int] = [
      0x5A106B, 0x63146B, 0x73186B, 0x841C6B, 0x8C246B, 0x9C2863, 0xAD2C5A, 0xB5305A,
      0xC63852, 0xCE414A, 0xD64939, 0xE75531, 0xEF6129, 0xEF6D21, 0xF77910, 0xFF8A08,
      0xFF9A00, 0xFFAA08, 0xFFBA18, 0xFFC729, 0xF7DB4A, 0xF7EB63, 0xF7F784, 0xFFFFA5,
    ]
    #expect((8...31).map(SpectrumHeat.rgb) == spec)
    // out-of-range steps clamp to the ends rather than trapping
    #expect(SpectrumHeat.rgb(40) == 0xFFFFA5)
  }

  @Test
  func `a scale label stays inside the trace panel`() {
    let panel: ClosedRange<CGFloat> = 10...150
    // on its line when there is room
    #expect(SpectrumTraceGeometry.labelCentre(lineY: 80, labelHeight: 14, in: panel) == 80)
    // the bottom row's label moves up, the top's down, just enough
    #expect(SpectrumTraceGeometry.labelCentre(lineY: 148.8, labelHeight: 14, in: panel) == 143)
    #expect(SpectrumTraceGeometry.labelCentre(lineY: 11, labelHeight: 14, in: panel) == 17)
    // a panel shorter than the label centres it
    #expect(SpectrumTraceGeometry.labelCentre(lineY: 0, labelHeight: 14, in: 0...10) == 5)
  }

  // MARK: Ages and the rest

  @Test
  func `a column's age is its middle's`() {
    let history = SpectrumDeviceHistory(window: 1, ncols: 180)
    #expect(history.windowMs == 60000)
    #expect(history.age(ofColumn: 179) == 166)
    #expect(history.age(ofColumn: 0) == 59833)
    #expect(SpectrumDeviceHistory(window: 3, ncols: 240).windowMs == 3_600_000)
  }

  @Test
  func `a mark matches an RX-log packet of its type within 2 s and 1 dB`() {
    let mark = CairnSpectrumMark(back: 0, width: 2, header: 0x11, pathLength: 2, rssi: -91, snrX4: 29, length: 101, rxMs: 123_456)
    let received = Date(timeIntervalSince1970: 1000)
    let date = SpectrumDeviceMarkMatch.date(of: mark, radioNowMs: 125_456, receivedAt: received)
    #expect(date == Date(timeIntervalSince1970: 998))
    #expect(SpectrumDeviceMarkMatch.matches(mark: mark, markDate: date, packetKind: .advert, packetDate: date.addingTimeInterval(1.5), packetRSSI: -92))
    #expect(!SpectrumDeviceMarkMatch.matches(mark: mark, markDate: date, packetKind: .message, packetDate: date, packetRSSI: -91))
    #expect(!SpectrumDeviceMarkMatch.matches(mark: mark, markDate: date, packetKind: .advert, packetDate: date.addingTimeInterval(2.5), packetRSSI: -91))
    #expect(!SpectrumDeviceMarkMatch.matches(mark: mark, markDate: date, packetKind: .advert, packetDate: date, packetRSSI: -93))
    #expect(!SpectrumDeviceMarkMatch.matches(mark: mark, markDate: date, packetKind: .advert, packetDate: date, packetRSSI: nil))
    // the radio's clock wrapped between the mark and the reply
    let wrapped = CairnSpectrumMark(back: 0, width: 2, header: 0x11, pathLength: 2, rssi: -91, snrX4: 29, length: 101, rxMs: .max - 999)
    #expect(SpectrumDeviceMarkMatch.date(of: wrapped, radioNowMs: 1000, receivedAt: received) == Date(timeIntervalSince1970: 998))
  }

  @Test
  func `the 24 h line keeps a 4 dB span, centred`() {
    let flat = SpectrumTrendScale(points: [nil, -113, -113, nil])
    #expect(flat?.label == "-113")
    #expect(flat.map { $0.drawn.bottom == -115 && $0.drawn.span == 4 } == true)
    #expect(flat?.y(-113, height: 10) == 5)
    let wide = SpectrumTrendScale(points: [-115, -109, nil, -112])
    #expect(wide?.label == "-115…-109")
    #expect(wide.map { $0.drawn.bottom == -115 && $0.drawn.span == 6 } == true)
    #expect(wide?.y(-109, height: 12) == 0)
    #expect(SpectrumTrendScale(points: [nil, nil]) == nil)
  }

  @Test
  func `the cells format and colour as the radio's`() {
    #expect(SpectrumDeviceCells.Load(percent: 30) == .normal)
    #expect(SpectrumDeviceCells.Load(percent: 31) == .warning)
    #expect(SpectrumDeviceCells.Load(percent: 61) == .critical)
    // AIR in tenths: 300 is still normal, 301 warns
    #expect(SpectrumDeviceCells.Load(percent: 30.0) == .normal)
    #expect(SpectrumDeviceCells.Load(percent: 30.1) == .warning)
    #expect(SpectrumDeviceCells.condition(floor: -118, thermal: -120) == .quiet)
    #expect(SpectrumDeviceCells.condition(floor: -117, thermal: -120) == .someInterference)
    #expect(SpectrumDeviceCells.condition(floor: -110, thermal: -120) == .heavyInterference)
  }

  @Test
  func `the layout stacks lane, trace and density on one x`() {
    let compact = SpectrumDeviceLayout(regular: false)
    #expect(compact.traceHeight == 140)
    #expect(compact.densityHeight == 112)
    #expect(compact.totalHeight == CGFloat(264))
    #expect(compact.density(width: 300).minY == 152)
    #expect(compact.traceInner(width: 300).height == 136)
    let regular = SpectrumDeviceLayout(regular: true)
    #expect(regular.traceHeight == 180)
    #expect(regular.densityHeight == 144)
  }

  // MARK: Fixture

  private static func history(marks: [CairnSpectrumMark]) -> CairnSpectrumHistory {
    let stats = CairnSpectrumStats(
      floorCalibrated: true, sweeping: false, fast: true, epoch: 3, nowMs: 3000, frequencyKHz: 869_525,
      bandwidthHz: 250_000, spreadingFactor: 11, codingRate: 5, window: 1, nowRSSI: -91, floor: -112,
      thermal: -120, busyPercent: 7, packetsPerMinuteX10: 60, airX10: 36, rxAirX10: 31, txAirX10: 5,
      packets: 6, coveredSeconds: 60, statsSeconds: 60, peak: -80
    )
    let reply = CairnSpectrumHistoryReply(
      status: .ok, stats: stats, xfer: 1, isFull: true, columns: 180, nowSlot: 1000, count: 180, scaleLo: -120,
      refFloor: -112, marks: UInt8(marks.count), frames: 1, markCursor: marks.last?.rxMs ?? 0
    )
    let columns: [CairnSpectrumColumn?] = Array(repeating: CairnSpectrumColumn.gap, count: 180)
    return CairnSpectrumHistory(reply: reply, columns: columns, marks: marks, completed: true)
  }
}
