import SwiftUI
import Testing
@testable import Cairn

/// The sensor grid spreads readings evenly over the lines it needs: never one left alone on a line.
@Suite("SensorReadingGrid layout")
@MainActor
struct SensorReadingGridTests {
  /// Items 80 wide, 12 apart, in a width that fits exactly `fit` of them to a line.
  private func perLine(_ count: Int, fit: Int) -> [Int] {
    let width = CGFloat(fit) * 80 + CGFloat(fit - 1) * 12
    return BalancedGridLayout.lines(widths: Array(repeating: 80, count: count), width: width, spacing: 12).map(\.count)
  }

  @Test
  func `readings that fit go on one line`() {
    #expect(perLine(3, fit: 4) == [3])
    #expect(perLine(4, fit: 4) == [4])
    #expect(perLine(1, fit: 4) == [1])
  }

  @Test
  func `readings that don't fit are spread evenly, never one alone`() {
    #expect(perLine(5, fit: 4) == [3, 2])
    #expect(perLine(4, fit: 3) == [2, 2])
    #expect(perLine(7, fit: 4) == [4, 3])
    #expect(perLine(9, fit: 4) == [3, 3, 3])
    #expect(perLine(5, fit: 2) == [2, 2, 1])   // only when a line holds no more than two
  }

  @Test
  func `one long reading takes only its own room`() {
    // a phone's header (~321 pt): temperature, heading, motion, a moving radio's pitch / roll, steps
    let widths: [CGFloat] = [62, 88, 78, 118, 72]
    #expect(BalancedGridLayout.lines(widths: widths, width: 321, spacing: 12).map(\.count) == [3, 2])
  }
}
