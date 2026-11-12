import CoreLocation
import MapLibre

/// How the GPS map follows the user, after Apple Maps' location button: off, following the
/// position, or following the position and turning with the phone.
enum MapTrackingMode: Equatable {
  case none
  case follow
  case followWithHeading

  init(_ mode: MLNUserTrackingMode) {
    switch mode {
    case .follow: self = .follow
    // Course tracking is never requested; treat it as heading so the button still reads "on".
    case .followWithHeading, .followWithCourse: self = .followWithHeading
    default: self = .none
    }
  }

  var mlnMode: MLNUserTrackingMode {
    switch self {
    case .none: .none
    case .follow: .follow
    case .followWithHeading: .followWithHeading
    }
  }

  /// The mode one tap on the location button moves to. Heading mode turns the map, so it is
  /// skipped while north is locked and on devices without a compass.
  func next(isNorthLocked: Bool, isHeadingAvailable: Bool) -> MapTrackingMode {
    switch self {
    case .none: .follow
    case .follow: isNorthLocked || !isHeadingAvailable ? .none : .followWithHeading
    case .followWithHeading: .none
    }
  }

  /// The location button's glyph, as Apple Maps draws each state.
  var systemImage: String {
    switch self {
    case .none: "location"
    case .follow: "location.fill"
    case .followWithHeading: "location.north.line.fill"
    }
  }

  var accessibilityValue: String {
    switch self {
    case .none: L10n.Map.Map.Controls.Tracking.off
    case .follow: L10n.Map.Map.Controls.Tracking.follow
    case .followWithHeading: L10n.Map.Map.Controls.Tracking.heading
    }
  }
}

/// A pin the GPS map's navigation readout measures to: the selected contact, discovered node or
/// dropped pin. It outlives the callout so panning the map doesn't lose the target.
struct MapNavigationTarget: Equatable {
  let pointID: UUID
  let name: String
  let coordinate: CLLocationCoordinate2D

  static func == (lhs: MapNavigationTarget, rhs: MapNavigationTarget) -> Bool {
    lhs.pointID == rhs.pointID
      && lhs.name == rhs.name
      && lhs.coordinate.latitude == rhs.coordinate.latitude
      && lhs.coordinate.longitude == rhs.coordinate.longitude
  }
}

/// The navigation readout's geometry, kept pure so it can be unit tested.
enum MapNavigationMath {
  /// Below this the map counts as north-up and flat, so the compass hides. A fraction of a
  /// degree is left over by gesture drift and isn't worth a control.
  static let orientationTolerance = 0.5

  /// Whether the camera is far enough from north-up and flat to show the compass.
  static func isRotatedOrTilted(direction: Double, pitch: Double) -> Bool {
    let offNorth = abs(GPSFormat.normalizedDegrees(direction + 180) - 180)
    return offNorth >= orientationTolerance || pitch >= orientationTolerance
  }

  /// Great-circle distance in metres.
  static func distance(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> CLLocationDistance {
    CLLocation(latitude: origin.latitude, longitude: origin.longitude)
      .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
  }

  /// Where a bearing lies relative to the way the phone faces, in -180..<180: negative to the
  /// left, positive to the right, 0 straight ahead.
  static func relativeAngle(bearing: Double, heading: Double) -> Double {
    GPSFormat.normalizedDegrees(bearing - heading + 180) - 180
  }

  /// Within this many degrees of the target the phone counts as lined up. The full-screen
  /// compass uses the same value, so the map and the compass say "on bearing" at the same moment.
  static let onTargetTolerance: Double = 5
  /// Once lined up, the phone stays so until it is this far off, so a hand's wobble at the edge
  /// doesn't flicker the line and buzz the haptic over and over.
  static let offTargetTolerance = onTargetTolerance + 3

  /// Whether a phone facing `relativeAngle` off the target is lined up with it, given whether it
  /// was a moment ago (see `offTargetTolerance`).
  static func isOnTarget(relativeAngle: Double, wasOnTarget: Bool) -> Bool {
    abs(relativeAngle) <= (wasOnTarget ? offTargetTolerance : onTargetTolerance)
  }

  /// The clock position (1...12, 12 straight ahead) of a relative angle, for VoiceOver.
  static func clockPosition(relativeAngle: Double) -> Int {
    let hour = Int((GPSFormat.normalizedDegrees(relativeAngle) / 30).rounded()) % 12
    return hour == 0 ? 12 : hour
  }

  /// The shortest turn from `current` to `target`, added to an unwrapped angle so an animated
  /// needle goes 359° → 1° by turning 2° clockwise, not 358° back.
  static func shortestTurn(from current: Double, to target: Double) -> Double {
    GPSFormat.normalizedDegrees(target - current + 180) - 180
  }
}

/// The map camera's rotation and tilt in degrees, reported to SwiftUI for the compass control.
struct MapCameraOrientation: Equatable {
  var direction: Double = 0
  var pitch: Double = 0

  var isRotatedOrTilted: Bool {
    MapNavigationMath.isRotatedOrTilted(direction: direction, pitch: pitch)
  }
}
