import CoreLocation
import Foundation
import CairnServices

/// Route and distance wording shared by the node rows, node cards, and the readings tiles, so a
/// node reads the same wherever it appears.
enum NodeRouteFormat {
  /// "Direct" for a zero-hop out-path, the hop count when one is known (the out-path, or for a
  /// flood-routed node the hops its advert was heard over), otherwise "Flood".
  static func routeLabel(isFloodRouted: Bool, pathHopCount: Int, displayedHopCount: Int?) -> String {
    if !isFloodRouted, pathHopCount == 0 {
      L10n.Contacts.Contacts.Route.direct
    } else if let hops = displayedHopCount {
      hopCount(hops)
    } else {
      L10n.Contacts.Contacts.Route.flood
    }
  }

  /// "1 hop" / "3 hops".
  static func hopCount(_ hops: Int) -> String {
    hops == 1 ? L10n.Map.Map.Detail.hopSingular : L10n.Contacts.Contacts.Route.hops(hops)
  }

  /// The road distance from `userLocation` to the coordinate, in the user's measurement units,
  /// or nil without a user location.
  static func distance(from userLocation: CLLocation?, latitude: Double, longitude: Double) -> String? {
    guard let userLocation else { return nil }
    let meters = userLocation.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(
      width: .abbreviated,
      usage: .road
    ).locale(MeasurementPreference.locale()))
  }

  /// `distance(from:latitude:longitude:)` as "1.2 km away".
  static func distanceAway(from userLocation: CLLocation?, latitude: Double, longitude: Double) -> String? {
    distance(from: userLocation, latitude: latitude, longitude: longitude).map { L10n.Contacts.Contacts.Row.away($0) }
  }

  /// The present parts as one line separated by middle dots: "1 hop · 2.3 km away".
  static func joined(_ parts: [String?]) -> String {
    parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
  }
}
