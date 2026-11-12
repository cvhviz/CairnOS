import Foundation
@testable import Cairn
import Testing

/// The Analyzer plot's motion between readings: columns spring to their readings and settle, caps
/// hold then fall, a packet ripples once as it's heard, and Reduce Motion stills all of it.
@MainActor
struct AnalyzerSpectrumTests {
  private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

  /// Six bars, the newest three at `dBm`, on a 1 s grid ending at `start`.
  private func frame(dBm: Double? = -90, marks: [MiniSpectrumFrame.Mark] = [], newestKey: Int64 = 100) -> MiniSpectrumFrame {
    var bars = [MiniSpectrumFrame.Bar](repeating: MiniSpectrumFrame.Bar(), count: 6)
    for index in 3..<6 {
      bars[index].dBm = dBm
      bars[index].floor = -110
    }
    return MiniSpectrumFrame(bars: bars, floor: -110, marks: marks, barSeconds: 1, newestDate: start, newestKey: newestKey)
  }

  /// Steps the motion at 60 fps for `seconds`.
  private func run(_ motion: AnalyzerMotion, frame: MiniSpectrumFrame, from: TimeInterval, seconds: TimeInterval, animated: Bool = true) -> AnalyzerMotion.State {
    var state = motion.advance(to: start.addingTimeInterval(from), frame: frame, animated: animated)
    var elapsed = 0.0
    while elapsed < seconds {
      elapsed += 1.0 / 60
      state = motion.advance(to: start.addingTimeInterval(from + elapsed), frame: frame, animated: animated)
    }
    return state
  }

  @Test func theFirstFrameStandsEveryColumnOnItsReading() {
    let motion = AnalyzerMotion()
    let frame = frame()
    let target = MiniSpectrumFrame.height(dBm: -90, floor: -110)
    let first = motion.advance(to: start, frame: frame, animated: true)
    #expect(first.columns.count == 6)
    #expect(first.columns[0] == nil, "A bar without a reading has no column")
    #expect(first.columns[5]?.shown == target, "Opened on its readings, nothing climbs")
  }

  @Test func aNewColumnContinuesFromTheOneBeforeIt() {
    let motion = AnalyzerMotion()
    var waiting = frame(dBm: -100)
    waiting.bars[5].dBm = nil
    _ = run(motion, frame: waiting, from: 0, seconds: 1)
    let previous = MiniSpectrumFrame.height(dBm: -100, floor: -110)

    var landed = frame(dBm: -100)
    landed.bars[5].dBm = -85
    let target = MiniSpectrumFrame.height(dBm: -85, floor: -110)
    let early = motion.advance(to: start.addingTimeInterval(1 + 1.0 / 60), frame: landed, animated: true)
    let shown = early.columns[5]!.shown
    #expect(shown > previous - 0.001, "Starts at the column before it, not the floor")
    #expect(shown < previous + (target - previous) * 0.3, "On its way, not there yet")

    let settled = run(motion, frame: landed, from: 1 + 1.0 / 60, seconds: 1.5)
    #expect(abs(settled.columns[5]!.shown - target) < 0.005, "Settled on the reading")
    #expect(abs(settled.columns[5]!.velocity) < 0.01)
  }

  @Test func capHoldsThenFallsAfterTheReadingDrops() {
    let motion = AnalyzerMotion()
    let high = frame(dBm: -85)
    let low = frame(dBm: -105)
    let highHeight = MiniSpectrumFrame.height(dBm: -85, floor: -110)
    _ = run(motion, frame: high, from: 0, seconds: 1.5)

    let dropped = run(motion, frame: low, from: 1.5, seconds: 0.2)
    #expect(abs(dropped.columns[5]!.cap - highHeight) < 0.005, "Held at the old peak within the hold time")
    #expect(dropped.columns[5]!.shown < highHeight - 0.2, "The column itself has dropped")

    let later = run(motion, frame: low, from: 1.7, seconds: 1)
    let lowHeight = MiniSpectrumFrame.height(dBm: -105, floor: -110)
    #expect(later.columns[5]!.cap < highHeight - 0.05, "Falling once the hold is over")
    #expect(later.columns[5]!.cap >= lowHeight - 0.001, "Never below the column")
  }

  @Test func aPacketRipplesOnceWhenFirstDrawn() {
    let motion = AnalyzerMotion()
    let id = UUID()
    let mark = MiniSpectrumFrame.Mark(secondsBeforeNewest: 0.5, kind: .advert, packetID: id)

    let opened = motion.advance(to: start, frame: frame(marks: [mark]), animated: true)
    #expect(opened.ripples.isEmpty, "What was already on the plot when it came up doesn't ripple")

    let newID = UUID()
    let newMark = MiniSpectrumFrame.Mark(secondsBeforeNewest: 0.2, kind: .message, packetID: newID)
    let heard = motion.advance(to: start.addingTimeInterval(1), frame: frame(marks: [mark, newMark]), animated: true)
    #expect(heard.ripples.map(\.mark.packetID) == [newID])
    #expect(heard.ripples[0].age == 0)

    let mid = motion.advance(to: start.addingTimeInterval(1.5), frame: frame(marks: [mark, newMark]), animated: true)
    #expect(mid.ripples.count == 1)
    #expect(abs(mid.ripples[0].age - 0.5) < 0.001)

    let over = motion.advance(to: start.addingTimeInterval(1 + AnalyzerMotion.rippleLife + 0.1), frame: frame(marks: [mark, newMark]), animated: true)
    #expect(over.ripples.isEmpty, "Rippled out")
  }

  @Test func aColumnNeverRisesPastItsReading() {
    let motion = AnalyzerMotion()
    var low = frame(dBm: -105)
    low.bars[5].dBm = nil
    _ = run(motion, frame: low, from: 0, seconds: 0.5)
    var frame = frame(dBm: -105)
    frame.bars[5].dBm = -90
    let target = MiniSpectrumFrame.height(dBm: -90, floor: -110)
    var highest = 0.0
    var state = motion.advance(to: start.addingTimeInterval(0.5), frame: frame, animated: true)
    for tick in 1...120 {
      state = motion.advance(to: start.addingTimeInterval(0.5 + Double(tick) / 60), frame: frame, animated: true)
      highest = max(highest, state.columns[5]!.shown)
    }
    #expect(highest <= target + 0.0001, "No overshoot, so a reading doesn't sink back after it lands")
    #expect(abs(state.columns[5]!.shown - target) < 0.005)
  }

  @Test func reduceMotionStandsEveryColumnOnItsReading() {
    let motion = AnalyzerMotion()
    let target = MiniSpectrumFrame.height(dBm: -90, floor: -110)
    let state = motion.advance(to: start, frame: frame(), animated: false)
    #expect(state.columns[5]?.shown == target)
    #expect(state.columns[5]?.cap == target)

    let mark = MiniSpectrumFrame.Mark(secondsBeforeNewest: 0.2, kind: .message, packetID: UUID())
    let heard = motion.advance(to: start.addingTimeInterval(1), frame: frame(marks: [mark]), animated: false)
    #expect(heard.ripples.isEmpty, "Nothing ripples without motion")
  }

  @Test func aNewScaleStartsOver() {
    let motion = AnalyzerMotion()
    _ = run(motion, frame: frame(), from: 0, seconds: 1)
    var wider = frame()
    wider.barSeconds = 2
    let target = MiniSpectrumFrame.height(dBm: -90, floor: -110)
    let reset = motion.advance(to: start.addingTimeInterval(1 + 1.0 / 60), frame: wider, animated: true)
    #expect(reset.columns[5]?.shown == target, "A new scale opens on its readings, as the first frame does")
  }

  @Test func geometryPutsTheNewestBarAtTheEdge() {
    let geometry = AnalyzerGeometry(barCount: 10, barSeconds: 1, secondsPastNewest: 0)
    #expect(geometry.pitch(in: 100) == 10)
    #expect(geometry.barX(9, width: 100) == 90, "The newest bar's left edge is one pitch in from the right")
    #expect(geometry.x(secondsBeforeNewest: 0, width: 100) == 100)

    let scrolled = AnalyzerGeometry(barCount: 10, barSeconds: 1, secondsPastNewest: 0.5)
    #expect(scrolled.barX(9, width: 100) == 85, "Half a bar on, the plot has moved half a pitch left")
  }
}
