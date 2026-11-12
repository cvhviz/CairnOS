import CairnServices
import CoreLocation
import Foundation

/// A recorded trip worked out from its points as copied from the radio (`TripLogPointDTO`), the way the
/// radio works out its own Trip page (firmware `TripMath.h`), so the two agree:
///
/// - A point closer than `minStep` (or its own accuracy, if worse) to the last one kept is jitter.
/// - A jump faster than `maxSpeed` is a bad fix and is dropped.
/// - The altitude is smoothed, and climb only counts once it has moved `climbHysteresis` from the last turn.
/// - Time across a gap longer than `gap` (nothing recorded meanwhile) isn't moving time, though the straight
///   line still counts as distance (the least the trip can have covered).
///
/// The radio only records points its own numbers kept, so these rules mostly find nothing to drop; they
/// matter for a log written by older firmware, and keep the numbers honest whatever the points are.
struct TripSummary: Equatable {
  struct Point: Equatable {
    let latitude: Double
    let longitude: Double
    let time: Date
    /// Metres from the start along the trail.
    let distance: Double
    /// The smoothed altitude, metres; nil when no point so far had one.
    let altitude: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
  }

  var distance: Double = 0
  var movingTime: TimeInterval = 0
  var climb: Double = 0
  var descent: Double = 0
  var lowest: Double?
  var highest: Double?
  /// The trail as kept, oldest first.
  var points: [Point] = []

  var start: Date? { points.first?.time }
  var end: Date? { points.last?.time }
  var hasAltitude: Bool { lowest != nil }
  var isEmpty: Bool { points.isEmpty }

  static let minStep = 10.0
  static let maxSpeed = 70.0
  static let climbHysteresis = 4.0
  static let altitudeSmoothing = 0.3
  static let gap: TimeInterval = 300
  static let movingSpeed = 0.4
  init() {}

  init(_ raw: [TripLogPointDTO]) {
    let sorted = raw.sorted { $0.timestamp < $1.timestamp }
    var smoothed: Double?
    var turn: Double?
    var last: TripLogPointDTO?
    for point in sorted {
      if point.latitude == 0, point.longitude == 0 { continue }
      if let previous = last {
        let dt = point.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { continue }
        let step = Self.metres(previous, point)
        if step < Self.minStep { continue }
        if step / dt > Self.maxSpeed { continue }
        distance += step
        if dt <= Self.gap, step / dt >= Self.movingSpeed { movingTime += dt }
      }
      if let altitude = point.altitude {
        if let current = smoothed {
          smoothed = current + Self.altitudeSmoothing * (altitude - current)
        } else {
          smoothed = altitude
          turn = altitude
        }
        if let value = smoothed, let reference = turn {
          if value - reference >= Self.climbHysteresis { climb += value - reference; turn = value }
          else if reference - value >= Self.climbHysteresis { descent += reference - value; turn = value }
          lowest = min(lowest ?? value, value)
          highest = max(highest ?? value, value)
        }
      }
      points.append(Point(
        latitude: point.latitude, longitude: point.longitude, time: point.timestamp,
        distance: distance, altitude: smoothed
      ))
      last = point
    }
  }

  /// Great-circle metres between two points.
  static func metres(_ a: TripLogPointDTO, _ b: TripLogPointDTO) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
      .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
  }

  /// At most `limit` points for drawing (the map's line, the chart), evenly spread, the last kept.
  func thinned(to limit: Int) -> [Point] {
    guard points.count > limit, limit > 1 else { return points }
    let stride = Double(points.count - 1) / Double(limit - 1)
    return (0..<limit).map { points[Int((Double($0) * stride).rounded())] }
  }
}
