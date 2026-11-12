import CoreGraphics
import Foundation
import MapLibre
import UIKit

/// Pure math for mouse-wheel zoom, kept separate from the gesture handler so it
/// can be unit tested.
enum ScrollWheelZoom {
  /// Zoom levels applied per point of vertical wheel scroll.
  static let zoomPerPoint: Double = 1.0 / 50.0

  /// Largest zoom change one scroll event may apply, so a fast wheel spin
  /// can't jump several levels at once.
  static let maxStepPerEvent: Double = 1.0

  /// Zoom change for a vertical scroll translation. A positive translation
  /// (content pulled down, the same scroll that reveals content above) zooms
  /// in, matching web maps under the system's scroll-direction setting.
  static func zoomDelta(forVerticalScroll translation: CGFloat) -> Double {
    let raw = Double(translation) * zoomPerPoint
    return min(max(raw, -maxStepPerEvent), maxStepPerEvent)
  }

  /// The screen point, measured before zooming, whose coordinate must become
  /// the camera center so the coordinate under `anchor` stays under it after
  /// zooming by `zoomDelta` levels.
  static func anchoredCenter(center: CGPoint, anchor: CGPoint, zoomDelta: Double) -> CGPoint {
    let scale = pow(2, zoomDelta)
    return CGPoint(
      x: anchor.x + (center.x - anchor.x) / scale,
      y: anchor.y + (center.y - anchor.y) / scale
    )
  }
}

// MARK: - Scroll input

extension CairnMapView.Coordinator {
  /// Adds pointer scroll support, used on Mac and on iPad with a mouse or
  /// trackpad. MapLibre ignores scroll events, so without these a mouse wheel
  /// did nothing. Wheel clicks (discrete) zoom around the pointer; trackpad
  /// two-finger scrolls (continuous) pan, as in Apple Maps. Trackpad pinch
  /// already reaches MapLibre's own pinch recognizer.
  func installScrollInputRecognizers() {
    let wheelZoom = UIPanGestureRecognizer(target: self, action: #selector(handleScrollWheelZoom(_:)))
    wheelZoom.allowedScrollTypesMask = .discrete
    // Zero touches limits the recognizer to scroll events, leaving finger
    // and mouse-drag pans to MapLibre.
    wheelZoom.maximumNumberOfTouches = 0
    wheelZoom.delegate = self
    mapView.addGestureRecognizer(wheelZoom)

    let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
    scrollPan.allowedScrollTypesMask = .continuous
    scrollPan.maximumNumberOfTouches = 0
    scrollPan.delegate = self
    mapView.addGestureRecognizer(scrollPan)
  }

  @objc func handleScrollWheelZoom(_ sender: UIPanGestureRecognizer) {
    trackScrollInput(sender.state)
    guard sender.state == .began || sender.state == .changed, mapView.isZoomEnabled else { return }
    let translation = sender.translation(in: mapView)
    sender.setTranslation(.zero, in: mapView)

    let current = mapView.zoomLevel
    let requested = current + ScrollWheelZoom.zoomDelta(forVerticalScroll: translation.y)
    let target = min(max(requested, mapView.minimumZoomLevel), mapView.maximumZoomLevel)
    let applied = target - current
    guard abs(applied) > 0.0001 else { return }

    let anchor = sender.location(in: mapView)
    // The camera center sits inside any content inset, so project it rather
    // than using the view's midpoint.
    let center = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
    let newCenter = ScrollWheelZoom.anchoredCenter(center: center, anchor: anchor, zoomDelta: applied)
    mapView.setCenter(
      mapView.convert(newCenter, toCoordinateFrom: mapView),
      zoomLevel: target,
      animated: false
    )
    didMoveCameraFromScrollInput()
  }

  @objc func handleScrollPan(_ sender: UIPanGestureRecognizer) {
    trackScrollInput(sender.state)
    guard sender.state == .began || sender.state == .changed, mapView.isScrollEnabled else { return }
    let translation = sender.translation(in: mapView)
    sender.setTranslation(.zero, in: mapView)
    guard translation != .zero else { return }

    let center = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
    let newCenter = CGPoint(x: center.x - translation.x, y: center.y - translation.y)
    mapView.setCenter(mapView.convert(newCenter, toCoordinateFrom: mapView), animated: false)
    didMoveCameraFromScrollInput()
  }

  /// Scroll input is a user gesture too, but its camera moves read as programmatic, so report
  /// its start and end here for callers that hold camera fits back during gestures.
  private func trackScrollInput(_ state: UIGestureRecognizer.State) {
    let isActive = state == .began || state == .changed
    guard isActive != isScrollInputActive else { return }
    isScrollInputActive = isActive
    guard isActive != isUserGestureActive else { return }
    setUserGestureActive(isActive)
  }

  /// Scroll input moves the camera with `setCenter`, which MapLibre reports as
  /// a programmatic change, so do the bookkeeping a user gesture would get.
  private func didMoveCameraFromScrollInput() {
    let report = setIsCenteredOnUser
    DispatchQueue.main.async { report?(false) }
    scheduleCameraWriteBack()
  }
}
