import CoreGraphics
import Foundation
@testable import Cairn
import Testing

@Suite("ScrollWheelZoom")
struct ScrollWheelZoomTests {
  @Test
  func `pulling content down zooms in, pushing it up zooms out`() {
    #expect(ScrollWheelZoom.zoomDelta(forVerticalScroll: 10) > 0)
    #expect(ScrollWheelZoom.zoomDelta(forVerticalScroll: -10) < 0)
    #expect(ScrollWheelZoom.zoomDelta(forVerticalScroll: 0) == 0)
  }

  @Test
  func `one event never moves more than the step cap`() {
    #expect(ScrollWheelZoom.zoomDelta(forVerticalScroll: 10000) == ScrollWheelZoom.maxStepPerEvent)
    #expect(ScrollWheelZoom.zoomDelta(forVerticalScroll: -10000) == -ScrollWheelZoom.maxStepPerEvent)
  }

  @Test
  func `anchor at the center leaves the center in place`() {
    let center = CGPoint(x: 200, y: 400)
    let result = ScrollWheelZoom.anchoredCenter(center: center, anchor: center, zoomDelta: 1)
    #expect(result == center)
  }

  @Test
  func `zooming in one level moves the center halfway to the anchor`() {
    let result = ScrollWheelZoom.anchoredCenter(
      center: CGPoint(x: 200, y: 400),
      anchor: CGPoint(x: 100, y: 200),
      zoomDelta: 1
    )
    #expect(result == CGPoint(x: 150, y: 300))
  }

  @Test
  func `zooming out one level moves the center away from the anchor`() {
    let result = ScrollWheelZoom.anchoredCenter(
      center: CGPoint(x: 200, y: 400),
      anchor: CGPoint(x: 100, y: 200),
      zoomDelta: -1
    )
    #expect(result == CGPoint(x: 300, y: 600))
  }

  /// The anchored coordinate must land back under the pointer: in screen
  /// space around the new center, the anchor's offset is scaled by 2^zoom.
  @Test(arguments: [0.25, 0.5, 1.0, -0.5, -1.0])
  func `anchor stays under the pointer`(zoomDelta: Double) {
    let center = CGPoint(x: 195, y: 422)
    let anchor = CGPoint(x: 40, y: 700)
    let newCenter = ScrollWheelZoom.anchoredCenter(center: center, anchor: anchor, zoomDelta: zoomDelta)
    let scale = pow(2, zoomDelta)
    let anchorAfter = CGPoint(
      x: center.x + (anchor.x - newCenter.x) * scale,
      y: center.y + (anchor.y - newCenter.y) * scale
    )
    #expect(abs(anchorAfter.x - anchor.x) < 0.0001)
    #expect(abs(anchorAfter.y - anchor.y) < 0.0001)
  }
}
