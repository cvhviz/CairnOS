import CoreLocation
import MapKit
import UIKit

/// Camera framing for a discovery scan's SNR traces: the region that holds this radio and every
/// node that answered, and the screen padding that keeps them clear of the map's overlays.
///
/// The region is the tight bounds of the endpoints (no multiplier): the margin comes from the
/// edge padding instead, which is in points, so a far node gets the same breathing room as a
/// near one and the overlays (status pill, controls, sheet) are accounted for exactly.
enum TraceCameraFit {
  /// Narrowest span a fit shows. A single node a few hundred meters away would otherwise zoom to
  /// street level; LoRa links are kilometers, so a 3 km window keeps the neighborhood in view.
  static let minimumSpanMeters: Double = 3000

  /// Breathing room between the outermost endpoint and the usable area's edge.
  static let margin: CGFloat = 32

  /// Extra room above the topmost endpoint, where its pin sprite and name label are drawn.
  static let pinClearance: CGFloat = 36

  /// The usable area never shrinks below this fraction of the view, however large the overlays.
  static let minimumUsableFraction: CGFloat = 0.3

  /// Height a status pill pinned to the top of the map takes: 8 pt offset, 44 pt pill, 8 pt gap.
  static let statusPillHeight: CGFloat = 60

  /// Width the bottom-trailing `MapControlsToolbar` takes: 44 pt buttons with 16 pt padding each side.
  static let controlsToolbarWidth: CGFloat = 76

  /// What a scan map draws over its own content: an optional status pill at the top and the
  /// controls toolbar on the trailing edge.
  static func overlayInsets(hasStatusPill: Bool) -> UIEdgeInsets {
    UIEdgeInsets(top: hasStatusPill ? statusPillHeight : 0, left: 0, bottom: 0, right: controlsToolbarWidth)
  }

  private static let metersPerDegreeLatitude = 111_320.0
  private static let latitudeLimit = 90.0

  /// The region holding every valid coordinate, widened to `minimumSpanMeters` when the points
  /// are close together. Spans are clamped only as far as needed to stay a valid region (the
  /// world), so far nodes are never cut off. Returns nil when no coordinate is a valid fix.
  static func region(
    fitting coordinates: [CLLocationCoordinate2D],
    minimumSpanMeters: Double = minimumSpanMeters
  ) -> MKCoordinateRegion? {
    let valid = coordinates.filter(\.isValidFix)
    guard let first = valid.first else { return nil }

    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for coordinate in valid.dropFirst() {
      minLat = min(minLat, coordinate.latitude)
      maxLat = max(maxLat, coordinate.latitude)
      minLon = min(minLon, coordinate.longitude)
      maxLon = max(maxLon, coordinate.longitude)
    }

    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    // Longitude degrees shrink toward the poles; floor the cosine so the minimum stays finite.
    let cosLatitude = max(0.01, cos(center.latitude * .pi / 180))
    let minLatDelta = minimumSpanMeters / metersPerDegreeLatitude
    let minLonDelta = minimumSpanMeters / (metersPerDegreeLatitude * cosLatitude)

    // center ± span/2 must stay inside ±90° latitude (MapLibre aborts beyond it) and 360° longitude.
    let maxLatDelta = (latitudeLimit - abs(center.latitude)) * 2
    let latDelta = min(max(maxLat - minLat, minLatDelta), maxLatDelta)
    let lonDelta = min(max(maxLon - minLon, minLonDelta), 360)
    guard latDelta > 0, lonDelta > 0 else { return nil }

    return MKCoordinateRegion(
      center: center,
      span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
    )
  }

  /// The `edgePadding` to hand MapLibre for a fit so the padding it actually uses is
  /// `edgePadding(safeArea:overlays:viewSize:)` whatever its `contentInset` is at the time.
  ///
  /// MapLibre adds `contentInset` to every `edgePadding` it is given (its `cameraEdgeInsets` is
  /// the sum), and with `automaticallyAdjustsContentInset` (the default) it keeps that inset in
  /// step with the bars covering the map as layout changes. Passing padding that already holds
  /// the safe area counted the bars twice whenever the inset was set, so the live fits during a
  /// scan zoomed out too far, while a fit on a freshly built map (inset not yet adjusted) framed
  /// correctly. Subtracting the inset makes every fit frame the same. The safe area is taken as the larger of the view's own and
  /// MapLibre's inset, since the inset is applied regardless.
  static func requestEdgePadding(
    safeArea: UIEdgeInsets,
    contentInset: UIEdgeInsets,
    overlays: UIEdgeInsets,
    viewSize: CGSize
  ) -> UIEdgeInsets {
    let covered = UIEdgeInsets(
      top: max(0, contentInset.top),
      left: max(0, contentInset.left),
      bottom: max(0, contentInset.bottom),
      right: max(0, contentInset.right)
    )
    let total = edgePadding(
      safeArea: UIEdgeInsets(
        top: max(safeArea.top, covered.top),
        left: max(safeArea.left, covered.left),
        bottom: max(safeArea.bottom, covered.bottom),
        right: max(safeArea.right, covered.right)
      ),
      overlays: overlays,
      viewSize: viewSize
    )
    return UIEdgeInsets(
      top: max(0, total.top - covered.top),
      left: max(0, total.left - covered.left),
      bottom: max(0, total.bottom - covered.bottom),
      right: max(0, total.right - covered.right)
    )
  }

  /// Screen padding for a fit: the safe area (bars), the overlays drawn over the map, plus a
  /// margin and room for the top pin's sprite. When that would leave less than
  /// `minimumUsableFraction` of the view, each axis is scaled down proportionally so the camera
  /// can still frame the traces (and MapLibre never gets padding larger than the view).
  static func edgePadding(
    safeArea: UIEdgeInsets,
    overlays: UIEdgeInsets,
    viewSize: CGSize,
    margin: CGFloat = margin,
    pinClearance: CGFloat = pinClearance
  ) -> UIEdgeInsets {
    guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
    var padding = UIEdgeInsets(
      top: safeArea.top + overlays.top + margin + pinClearance,
      left: safeArea.left + overlays.left + margin,
      bottom: safeArea.bottom + overlays.bottom + margin,
      right: safeArea.right + overlays.right + margin
    )

    let maxHorizontal = viewSize.width * (1 - minimumUsableFraction)
    let horizontal = padding.left + padding.right
    if horizontal > maxHorizontal {
      let scale = maxHorizontal / horizontal
      padding.left *= scale
      padding.right *= scale
    }

    let maxVertical = viewSize.height * (1 - minimumUsableFraction)
    let vertical = padding.top + padding.bottom
    if vertical > maxVertical {
      let scale = maxVertical / vertical
      padding.top *= scale
      padding.bottom *= scale
    }
    return padding
  }
}

/// Asks the map camera to frame the traces a set of overlays draws: tags a region request with
/// the overlay insets so `CairnMapView` pads it to the unobstructed part of the map. Only the
/// request with `regionVersion` gets the padding; later moves (zoom buttons, focus on a node)
/// keep the map's own framing.
struct MapCameraFitPadding: Equatable {
  var regionVersion: Int
  var overlays: UIEdgeInsets
}

/// Coalesces the fits a scan asks for as replies land, so the camera moves once per burst rather
/// than jittering, and holds a fit back while the user is dragging or pinching the map.
///
/// A request waits `debounce` after the latest one, but never more than `maxDelay` after the
/// first unapplied one, so a steady stream of replies still moves the camera. A fit that falls due
/// mid-gesture is kept and applied `debounce` after the gesture ends.
@MainActor
final class TraceCameraFitScheduler {
  static let defaultDebounce: Duration = .milliseconds(300)
  static let defaultMaxDelay: Duration = .seconds(1)

  /// Moves the camera. Set by the owning view.
  var apply: (MKCoordinateRegion) -> Void = { _ in }

  private(set) var pendingRegion: MKCoordinateRegion?
  private(set) var isGestureActive = false

  private let debounce: Duration
  private let maxDelay: Duration
  private let clock = ContinuousClock()
  private var firstPendingAt: ContinuousClock.Instant?
  private var task: Task<Void, Never>?

  init(debounce: Duration = defaultDebounce, maxDelay: Duration = defaultMaxDelay) {
    self.debounce = debounce
    self.maxDelay = maxDelay
  }

  /// Queues a fit to `region`, replacing any queued one. Nil is ignored (nothing to frame).
  func request(_ region: MKCoordinateRegion?) {
    guard let region else { return }
    pendingRegion = region
    let now = clock.now
    let first = firstPendingAt ?? now
    firstPendingAt = first
    schedule(at: min(now + debounce, first + maxDelay))
  }

  /// Reports a user drag/pinch starting or ending on the map.
  func setGestureActive(_ isActive: Bool) {
    guard isActive != isGestureActive else { return }
    isGestureActive = isActive
    if !isActive, pendingRegion != nil {
      schedule(at: clock.now + debounce)
    }
  }

  /// Drops any queued fit, e.g. when the results are cleared.
  func cancel() {
    task?.cancel()
    task = nil
    pendingRegion = nil
    firstPendingAt = nil
  }

  /// Applies the queued fit now unless a gesture is in progress, which keeps it queued.
  func flush() {
    guard !isGestureActive, let region = pendingRegion else { return }
    task?.cancel()
    task = nil
    pendingRegion = nil
    firstPendingAt = nil
    apply(region)
  }

  private func schedule(at deadline: ContinuousClock.Instant) {
    task?.cancel()
    task = Task { [weak self, clock] in
      try? await clock.sleep(until: deadline)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }
}
