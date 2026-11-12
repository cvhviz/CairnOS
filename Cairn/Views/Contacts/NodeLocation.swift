import CoreLocation
import MapKit

enum NodeLocation {
  /// Opens the node's location in Apple Maps, for directions and the rest.
  static func openInMaps(name: String, coordinate: CLLocationCoordinate2D) {
    let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    mapItem.name = name
    mapItem.openInMaps()
  }
}
