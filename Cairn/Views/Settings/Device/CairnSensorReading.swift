import CairnServices
import Foundation
import MeshCore

/// What Cairn firmware means by the standard LPP types it reuses on the radio's own channel:
/// the IMU's step count today as a generic sensor, its tilt as a gravity vector in the
/// accelerometer slot, whether it is moving as presence, and a magnetometer's compass heading as
/// direction (the Heltec RC52 on its GA01 base). Every other reading, and any reading from other
/// firmware, keeps its plain LPP meaning.
enum CairnSensorReading: Equatable {
  case steps(Int)
  /// Whole degrees: pitch nose-up positive, roll right-side-down positive.
  case tilt(pitch: Int, roll: Int)
  case motion(isMoving: Bool)
  /// Degrees from magnetic north, 0..359.
  case heading(Int)

  /// The LPP channel the radio reports its own readings on (the firmware's `TELEM_CHANNEL_SELF`).
  private static let selfChannel: UInt8 = 1

  init?(_ point: LPPDataPoint) {
    guard point.channel == Self.selfChannel else { return nil }
    switch (point.type, point.value) {
    case let (.genericSensor, .integer(steps)):
      self = .steps(steps)
    case let (.accelerometer, .vector3(x, y, z)):
      // The firmware sends gravity as (−sin p, cos p · sin r, cos p · cos r).
      let pitch = asin(max(-1, min(1, -x))) * 180 / .pi
      let roll = atan2(y, z) * 180 / .pi
      self = .tilt(pitch: Int(pitch.rounded()), roll: Int(roll.rounded()))
    case let (.presence, .digital(isMoving)):
      self = .motion(isMoving: isMoving)
    case let (.direction, .integer(degrees)):
      self = .heading(((degrees % 360) + 360) % 360)
    default:
      return nil
    }
  }

  var label: String {
    switch self {
    case .steps: L10n.RemoteNodes.RemoteNodes.Status.Sensor.steps
    case .tilt: L10n.RemoteNodes.RemoteNodes.Status.Sensor.pitchRoll
    case .motion: L10n.RemoteNodes.RemoteNodes.Status.Sensor.motion
    case .heading: L10n.RemoteNodes.RemoteNodes.Status.Sensor.direction
    }
  }

  var value: String {
    switch self {
    case let .steps(count):
      count.formatted()
    case let .tilt(pitch, roll):
      // Short enough for a sensor card beside the others; the label says which is which.
      "\(pitch.formatted())° / \(roll.formatted())°"
    case let .motion(isMoving):
      isMoving
        ? L10n.RemoteNodes.RemoteNodes.Status.Sensor.moving
        : L10n.RemoteNodes.RemoteNodes.Status.Sensor.still
    case let .heading(degrees):
      // "123° SE": the point in the app's own (localized) compass words
      "\(degrees)\u{00B0} \(HomeFormat.compassPoint(bearing: Double(degrees)))"
    }
  }

  var systemImage: String {
    switch self {
    case .steps: "figure.walk"
    case .tilt: "level"
    case let .motion(isMoving): isMoving ? "figure.walk.motion" : "figure.stand"
    case .heading: "location.north.line"
    }
  }
}
