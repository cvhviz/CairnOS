import CoreLocation
import CairnServices

extension DiscoveredNodeDTO {
  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
