import CoreLocation
import SwiftUI

/// The two pages of the GPS tab, mirroring Cairn's [Position | Map] segmented control.
enum GPSSegment: Hashable, CaseIterable {
  /// The device's own fix: status, coordinates, altitude, speed and the compass.
  case position
  /// The mesh map (the former Map tab), showing nodes with known locations.
  case map
}

extension NavigationCoordinator {
  /// Opens the GPS tab on its Map segment and asks the map to drop a pin on and center `coordinate`
  /// (a chat coordinate tap). The map lives inside the GPS tab, so the segment is switched as well
  /// as the tab; `MapView` consumes `pendingMapFocus` once it appears.
  func navigateToMap(coordinate: CLLocationCoordinate2D) {
    pendingMapFocus = MapFocusRequest(latitude: coordinate.latitude,
                                      longitude: coordinate.longitude)
    gpsSegment = .map
    selectedTab = AppTab.gps.rawValue
  }

  /// A tap on the tab already showing: the Map tab goes back from its map to the Position page,
  /// where it opens (the user, 2026-11-08).
  func reselectTab(_ tab: Int) {
    guard tab == AppTab.gps.rawValue, gpsSegment != .position else { return }
    gpsSegment = .position
  }
}
