import MapKit
@testable import Cairn
import Testing
import UIKit

@Suite("TraceCameraFit")
struct TraceCameraFitTests {
  private let radio = CLLocationCoordinate2D(latitude: 21.30, longitude: -157.85)

  // MARK: - Region

  @Test
  func `no valid coordinate gives no region`() {
    #expect(TraceCameraFit.region(fitting: []) == nil)
    #expect(TraceCameraFit.region(fitting: [CLLocationCoordinate2D(latitude: 0, longitude: 0)]) == nil)
  }

  @Test
  func `a single nearby node is widened to the minimum span`() throws {
    let near = CLLocationCoordinate2D(latitude: 21.301, longitude: -157.851)
    let region = try #require(TraceCameraFit.region(fitting: [radio, near]))
    let latMeters = region.span.latitudeDelta * 111_320
    let lonMeters = region.span.longitudeDelta * 111_320 * cos(region.center.latitude * .pi / 180)
    #expect(abs(latMeters - TraceCameraFit.minimumSpanMeters) < 1)
    #expect(abs(lonMeters - TraceCameraFit.minimumSpanMeters) < 1)
    #expect(abs(region.center.latitude - 21.3005) < 1e-9)
  }

  @Test
  func `far nodes are fitted tightly with every endpoint inside`() throws {
    let points = [
      radio,
      CLLocationCoordinate2D(latitude: 21.60, longitude: -157.70),
      CLLocationCoordinate2D(latitude: 21.10, longitude: -158.20),
    ]
    let region = try #require(TraceCameraFit.region(fitting: points))
    #expect(abs(region.span.latitudeDelta - 0.5) < 1e-9)
    #expect(abs(region.span.longitudeDelta - 0.5) < 1e-9)
    for point in points {
      #expect(abs(point.latitude - region.center.latitude) <= region.span.latitudeDelta / 2 + 1e-9)
      #expect(abs(point.longitude - region.center.longitude) <= region.span.longitudeDelta / 2 + 1e-9)
    }
  }

  @Test
  func `a farther node zooms the fit out`() throws {
    let near = CLLocationCoordinate2D(latitude: 21.35, longitude: -157.90)
    let far = CLLocationCoordinate2D(latitude: 21.90, longitude: -158.40)
    let before = try #require(TraceCameraFit.region(fitting: [radio, near]))
    let after = try #require(TraceCameraFit.region(fitting: [radio, near, far]))
    #expect(after.span.latitudeDelta > before.span.latitudeDelta)
    #expect(after.span.longitudeDelta > before.span.longitudeDelta)
  }

  @Test
  func `invalid fixes are ignored`() throws {
    let region = try #require(TraceCameraFit.region(fitting: [
      radio,
      CLLocationCoordinate2D(latitude: 0, longitude: 0),
      CLLocationCoordinate2D(latitude: 200, longitude: 10),
    ]))
    #expect(abs(region.center.latitude - radio.latitude) < 1e-9)
  }

  @Test
  func `spans stay a valid region near the pole and across the globe`() throws {
    let polar = try #require(TraceCameraFit.region(fitting: [
      CLLocationCoordinate2D(latitude: 89.99, longitude: 10),
    ]))
    #expect(polar.center.latitude + polar.span.latitudeDelta / 2 <= 90)
    #expect(polar.span.longitudeDelta <= 360)

    let wide = try #require(TraceCameraFit.region(fitting: [
      CLLocationCoordinate2D(latitude: -60, longitude: -179),
      CLLocationCoordinate2D(latitude: 70, longitude: 179),
    ]))
    #expect(wide.center.latitude - wide.span.latitudeDelta / 2 >= -90)
    #expect(wide.center.latitude + wide.span.latitudeDelta / 2 <= 90)
    #expect(wide.span.longitudeDelta <= 360)
  }

  // MARK: - Edge padding

  @Test
  func `padding adds safe area, overlays, margin and pin clearance`() {
    let padding = TraceCameraFit.edgePadding(
      safeArea: UIEdgeInsets(top: 100, left: 0, bottom: 80, right: 0),
      overlays: TraceCameraFit.overlayInsets(hasStatusPill: true),
      viewSize: CGSize(width: 400, height: 900),
      margin: 30,
      pinClearance: 40
    )
    #expect(abs(padding.top - (100 + TraceCameraFit.statusPillHeight + 30 + 40)) < 0.001)
    #expect(abs(padding.left - 30) < 0.001)
    #expect(abs(padding.bottom - (80 + 30)) < 0.001)
    #expect(abs(padding.right - (TraceCameraFit.controlsToolbarWidth + 30)) < 0.001)
  }

  @Test
  func `padding without a status pill leaves the top to the safe area`() {
    let insets = TraceCameraFit.overlayInsets(hasStatusPill: false)
    #expect(insets.top == 0)
    #expect(insets.right == TraceCameraFit.controlsToolbarWidth)
  }

  @Test
  func `oversized padding is scaled down to keep a usable area`() {
    let size = CGSize(width: 200, height: 300)
    let padding = TraceCameraFit.edgePadding(
      safeArea: UIEdgeInsets(top: 200, left: 100, bottom: 200, right: 100),
      overlays: .zero,
      viewSize: size
    )
    let usableWidth = size.width - padding.left - padding.right
    let usableHeight = size.height - padding.top - padding.bottom
    #expect(abs(usableWidth - size.width * TraceCameraFit.minimumUsableFraction) < 0.001)
    #expect(abs(usableHeight - size.height * TraceCameraFit.minimumUsableFraction) < 0.001)
    // Scaling keeps each side's share, so the frame does not jump sideways.
    #expect(abs(padding.left - padding.right) < 0.001)
  }

  // MARK: - Request padding (MapLibre adds its contentInset on top)

  private let phone = CGSize(width: 393, height: 852)
  /// Bars over an edge-to-edge map: status + navigation bar (+ segment bar) on top, tab bar below.
  private let bars = UIEdgeInsets(top: 147, left: 0, bottom: 83, right: 0)

  /// What MapLibre frames with: the requested edge padding plus its content inset.
  private func effective(_ request: UIEdgeInsets, _ contentInset: UIEdgeInsets) -> UIEdgeInsets {
    UIEdgeInsets(
      top: request.top + contentInset.top,
      left: request.left + contentInset.left,
      bottom: request.bottom + contentInset.bottom,
      right: request.right + contentInset.right
    )
  }

  @Test
  func `a live fit after MapLibre adjusts its inset frames like the first fit`() {
    let overlays = TraceCameraFit.overlayInsets(hasStatusPill: true)
    // First fit on a fresh map: MapLibre has not adjusted contentInset yet.
    let first = TraceCameraFit.requestEdgePadding(
      safeArea: bars, contentInset: .zero, overlays: overlays, viewSize: phone
    )
    // Live fits during the scan: contentInset now mirrors the bars.
    let live = TraceCameraFit.requestEdgePadding(
      safeArea: bars, contentInset: bars, overlays: overlays, viewSize: phone
    )
    #expect(effective(first, .zero) == effective(live, bars))
    // The bars are counted once, not twice (the bug: padding = bars + overlays, then + inset).
    let expected = TraceCameraFit.edgePadding(safeArea: bars, overlays: overlays, viewSize: phone)
    #expect(effective(live, bars) == expected)
  }

  @Test
  func `an inset MapLibre sees but the view does not is still counted once`() {
    let inset = UIEdgeInsets(top: 100, left: 0, bottom: 50, right: 0)
    let request = TraceCameraFit.requestEdgePadding(
      safeArea: .zero, contentInset: inset, overlays: .zero, viewSize: phone
    )
    let expected = TraceCameraFit.edgePadding(safeArea: inset, overlays: .zero, viewSize: phone)
    #expect(effective(request, inset) == expected)
  }

  @Test
  func `request padding is never negative`() {
    let request = TraceCameraFit.requestEdgePadding(
      safeArea: .zero,
      contentInset: UIEdgeInsets(top: 800, left: 300, bottom: 800, right: 300),
      overlays: .zero,
      viewSize: phone
    )
    #expect(request.top >= 0 && request.left >= 0 && request.bottom >= 0 && request.right >= 0)
  }

  @Test
  func `a view with no size gets no padding`() {
    let padding = TraceCameraFit.edgePadding(
      safeArea: UIEdgeInsets(top: 50, left: 0, bottom: 0, right: 0),
      overlays: .zero,
      viewSize: .zero
    )
    #expect(padding == .zero)
  }
}

@Suite("TraceCameraFitScheduler")
@MainActor
struct TraceCameraFitSchedulerTests {
  private func region(_ latitude: Double) -> MKCoordinateRegion {
    MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: latitude, longitude: 10),
      span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
    )
  }

  @Test
  func `flush applies the latest request once`() {
    let scheduler = TraceCameraFitScheduler(debounce: .seconds(60), maxDelay: .seconds(60))
    var applied: [Double] = []
    scheduler.apply = { applied.append($0.center.latitude) }
    scheduler.request(region(1))
    scheduler.request(region(2))
    scheduler.flush()
    scheduler.flush()
    #expect(applied == [2])
    #expect(scheduler.pendingRegion == nil)
  }

  @Test
  func `nil requests are ignored`() {
    let scheduler = TraceCameraFitScheduler(debounce: .seconds(60), maxDelay: .seconds(60))
    scheduler.request(nil)
    #expect(scheduler.pendingRegion == nil)
  }

  @Test
  func `a fit waits out an active gesture`() {
    let scheduler = TraceCameraFitScheduler(debounce: .seconds(60), maxDelay: .seconds(60))
    var applied: [Double] = []
    scheduler.apply = { applied.append($0.center.latitude) }
    scheduler.setGestureActive(true)
    scheduler.request(region(3))
    scheduler.flush()
    #expect(applied.isEmpty)
    #expect(scheduler.pendingRegion != nil)
    scheduler.setGestureActive(false)
    scheduler.flush()
    #expect(applied == [3])
  }

  @Test
  func `cancel drops the queued fit`() {
    let scheduler = TraceCameraFitScheduler(debounce: .seconds(60), maxDelay: .seconds(60))
    var applied: [Double] = []
    scheduler.apply = { applied.append($0.center.latitude) }
    scheduler.request(region(4))
    scheduler.cancel()
    scheduler.flush()
    #expect(applied.isEmpty)
  }

  @Test
  func `a burst of requests is coalesced into one fit after the debounce`() async throws {
    let scheduler = TraceCameraFitScheduler(debounce: .milliseconds(30), maxDelay: .seconds(5))
    var applied: [Double] = []
    scheduler.apply = { applied.append($0.center.latitude) }
    scheduler.request(region(5))
    scheduler.request(region(6))
    scheduler.request(region(7))
    #expect(applied.isEmpty)
    try await Task.sleep(for: .milliseconds(400))
    #expect(applied == [7])
  }

  @Test
  func `a gesture ending applies the held fit after the debounce`() async throws {
    let scheduler = TraceCameraFitScheduler(debounce: .milliseconds(30), maxDelay: .milliseconds(30))
    var applied: [Double] = []
    scheduler.apply = { applied.append($0.center.latitude) }
    scheduler.setGestureActive(true)
    scheduler.request(region(8))
    try await Task.sleep(for: .milliseconds(200))
    #expect(applied.isEmpty)
    scheduler.setGestureActive(false)
    try await Task.sleep(for: .milliseconds(400))
    #expect(applied == [8])
  }
}
