import CoreLocation
import CairnServices
import Foundation

/// Where the phone was when a discovery reply arrived. The map draws a node's line from here, so
/// a node heard ten minutes into a drive is linked to the road it was heard from, not to where the
/// scan started or where the phone is now.
///
/// Only the phone's fix is used. The radio's own GPS can't stand in: its self telemetry repeats
/// the last valid position after the receiver loses its fix (a tunnel, a garage, Eco mode asleep),
/// and nothing it sends says whether that position is current. Firmware that reported fix
/// validity or age would let it back in.
struct NodeDiscoveryFix: Equatable {
  let latitude: Double
  let longitude: Double
  /// Metres.
  let horizontalAccuracy: CLLocationAccuracy
  /// When the phone took the fix.
  let timestamp: Date

  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

/// The reply a node's line is drawn from: the fix taken when it arrived and the SNR it was heard
/// at there, kept together so the line's color and badge describe the spot it starts from.
struct NodeDiscoveryHeardFrom: Equatable {
  let fix: NodeDiscoveryFix
  /// This radio's SNR for the reply heard at `fix`.
  let snr: Double

  var coordinate: CLLocationCoordinate2D { fix.coordinate }
}

/// The rules for when a reply gets a position, kept pure so the tests can pin them.
enum NodeDiscoveryReception {
  /// Oldest fix that still says where a reply was heard. Wardrive moves at road speed, so an
  /// older fix is somewhere else; following delivers a new one every second or so.
  static let maxFixAge: TimeInterval = 30
  /// Least precise phone fix worth drawing a line from.
  static let maxPhoneAccuracy: CLLocationAccuracy = 100

  /// The position a reply arriving at `now` was heard from: the phone's fix when it is fresh and
  /// precise, else nil. Nil means no line: the map draws only what was measured, never "where the
  /// phone is now" in place of where the reply arrived.
  static func fix(phone: CLLocation?, now: Date) -> NodeDiscoveryFix? {
    guard let phone,
          phone.coordinate.isValidFix,
          phone.horizontalAccuracy >= 0,
          phone.horizontalAccuracy <= maxPhoneAccuracy,
          now.timeIntervalSince(phone.timestamp) <= maxFixAge else { return nil }
    return NodeDiscoveryFix(
      latitude: phone.coordinate.latitude,
      longitude: phone.coordinate.longitude,
      horizontalAccuracy: phone.horizontalAccuracy,
      timestamp: phone.timestamp
    )
  }

  /// Which of a node's replies its line is drawn from: the one with the best SNR among those
  /// heard with a fix. A repeat reply replaces the stored one only when it was heard better (a
  /// tie keeps the first), and a reply without a fix never removes a line already drawn.
  static func best(stored: NodeDiscoveryHeardFrom?, reply: NodeDiscoveryHeardFrom?) -> NodeDiscoveryHeardFrom? {
    guard let reply else { return stored }
    guard let stored else { return reply }
    return reply.snr > stored.snr ? reply : stored
  }
}

/// How much location a discovery screen needs right now. A scan follows the phone so each reply
/// is stamped with where it arrived; Wardrive keeps following with the screen locked or another
/// app in front, since it runs for as long as the drive does.
enum NodeDiscoveryLocationDemand: Equatable {
  case none
  case scan
  case wardrive
}
