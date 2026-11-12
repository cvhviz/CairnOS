import CoreLocation

struct MapLine: Identifiable, Equatable {
  let id: String
  let coordinates: [CLLocationCoordinate2D]
  let style: LineStyle
  let opacity: Double
  var pathIndex: Int?
  /// `tripTrail`: where this segment sits in the day's elevation range, 0 the lowest, 1 the highest
  /// (its colour, teal through gold to orange).
  var elevationFraction: Double?

  enum LineStyle: String, Hashable {
    case los
    case traceUntraced
    case traceWeak
    case traceMedium
    case traceGood
    case messagePath
    /// A faint dashed connector threading location reports in time order. Not a
    /// proven route; only visual continuity between sampled fixes.
    case locationTrail
    /// The GPS map's dashed guide from the user to the navigation target: a straight line,
    /// not a route.
    case navigationTarget
    /// The same guide while the phone faces the target: solid green, so the line agrees with
    /// the readout that you're lined up.
    case navigationTargetOnTarget
    /// A link between two nodes that has carried packets lately, on the Traffic map: a soft
    /// teal glow whose strength (`opacity`) follows how busy and how recent the link is.
    case trafficLink
    /// A day's trail on the Trips page (`TripsView`): solid, coloured by elevation per segment
    /// (`elevationFraction`) over a dark casing.
    case tripTrail
  }

  /// The straight guide from `origin` to a navigation target, green and solid while on target.
  static func aim(id: String, from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, isOnTarget: Bool) -> MapLine {
    MapLine(
      id: id,
      coordinates: [origin, target],
      style: isOnTarget ? .navigationTargetOnTarget : .navigationTarget,
      opacity: 1
    )
  }

  static func == (lhs: MapLine, rhs: MapLine) -> Bool {
    lhs.id == rhs.id
      && lhs.style == rhs.style
      && lhs.opacity == rhs.opacity
      && lhs.elevationFraction == rhs.elevationFraction
      && lhs.coordinates.count == rhs.coordinates.count
      && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
        $0.latitude == $1.latitude && $0.longitude == $1.longitude
      }
  }
}
