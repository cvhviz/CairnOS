import CoreLocation
import MapLibre
import UIKit

/// Lets a SwiftUI overlay drawn over a `CairnMapView` place things on the map: hand the map one
/// (`CairnMapView.projection`) and ask it where a coordinate sits on screen, in the map view's own
/// space, which is the overlay's when the overlay is laid over the map with the same frame. It
/// reads the live camera on each call, so an overlay that redraws every frame (the Traffic map's
/// lasers) stays on its nodes while the map is panned or zoomed.
@MainActor
final class MapProjection {
  weak var mapView: MLNMapView?

  /// Where `coordinate` is on screen; nil before the map is made.
  func point(for coordinate: CLLocationCoordinate2D) -> CGPoint? {
    guard let mapView, mapView.bounds.width > 1 else { return nil }
    return mapView.convert(coordinate, toPointTo: mapView)
  }
}
