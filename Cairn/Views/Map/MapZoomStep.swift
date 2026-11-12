import MapKit

/// Pure math for the + and − map buttons.
enum MapZoomStep {
  enum Direction {
    case zoomIn
    case zoomOut
  }

  /// One button press changes the zoom by one level: the visible span halves or doubles.
  static let spanFactor: Double = 2

  /// Smallest span a press may reach (~10 m of latitude), so + can't zoom past usefulness.
  static let minimumSpan: CLLocationDegrees = 0.0001
  /// Largest latitude span; beyond it the region is no longer a valid map rect.
  static let maximumLatitudeSpan: CLLocationDegrees = 170
  static let maximumLongitudeSpan: CLLocationDegrees = 360

  /// `region` zoomed one step around its own center, clamped to sane spans.
  static func region(from region: MKCoordinateRegion, direction: Direction) -> MKCoordinateRegion {
    let factor = direction == .zoomIn ? 1 / spanFactor : spanFactor
    return MKCoordinateRegion(
      center: region.center,
      span: MKCoordinateSpan(
        latitudeDelta: min(max(region.span.latitudeDelta * factor, minimumSpan), maximumLatitudeSpan),
        longitudeDelta: min(max(region.span.longitudeDelta * factor, minimumSpan), maximumLongitudeSpan)
      )
    )
  }
}
