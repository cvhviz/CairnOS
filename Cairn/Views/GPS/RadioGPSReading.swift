import Foundation
import CairnServices
import MeshCore

/// Everything a companion radio says about its own GPS, and what the GPS tab and the Home card can
/// honestly derive from it. The companion protocol carries much less than the radio's own screen:
/// - `CMD_GET_CUSTOM_VARS` lists `gps` ("1"/"0", whether the receiver is on) only when the radio
///   has a receiver. Firmware with Eco mode also lists `gps_mode` (0 off, 1 on, 2 Eco), which the
///   reading takes over `gps`: Eco counts as on. It doesn't report the update interval, satellites
///   or fix time.
/// - Self telemetry (`CMD_SEND_TELEMETRY_REQ` to self) adds an LPP GPS point (latitude, longitude,
///   altitude) only while the receiver is powered.
/// - Self info carries the position the radio adverts, which the GPS keeps current while on.
/// So "fix" here means the receiver has produced one since the radio started: the firmware only
/// sets the altitude from a valid fix, and it starts at exactly 0.
struct RadioGPSReading: Equatable {
  /// The receiver's power state from the radio's custom vars; nil until read or when unreadable.
  var receiver: DeviceGPSState?
  /// The GPS point from the radio's self telemetry, present only while the receiver is on.
  var telemetry: TelemetryPosition?
  /// When the app last asked the radio. The radio itself doesn't timestamp its fixes.
  var readAt: Date?

  struct TelemetryPosition: Equatable {
    let latitude: Double
    let longitude: Double
    /// Metres above sea level; 0 until the receiver's first fix since the radio started.
    let altitude: Double
  }

  var status: RadioGPSStatus {
    Self.status(receiver: receiver, telemetry: telemetry)
  }

  /// The radio's altitude, only once it comes from a real fix.
  var altitude: Double? {
    status == .fix ? telemetry?.altitude : nil
  }

  /// The GPS point among a self telemetry reply's data points: the firmware puts it on the self
  /// channel (1), so that one wins over any GPS an attached sensor board reports on another.
  static func telemetryPosition(in points: [LPPDataPoint]) -> TelemetryPosition? {
    let positions: [(channel: UInt8, position: TelemetryPosition)] = points.compactMap { point in
      guard case let .gps(latitude, longitude, altitude) = point.value else { return nil }
      return (point.channel, TelemetryPosition(latitude: latitude, longitude: longitude, altitude: altitude))
    }
    return (positions.first { $0.channel == selfChannel } ?? positions.first)?.position
  }

  static func status(receiver: DeviceGPSState?, telemetry: TelemetryPosition?) -> RadioGPSStatus {
    guard let receiver else { return .unknown }
    guard receiver.isSupported else { return .noReceiver }
    guard receiver.isEnabled else { return .off }
    guard let telemetry else { return .on }
    return telemetry.altitude == 0 ? .searching : .fix
  }

  /// `TELEM_CHANNEL_SELF` in the firmware.
  private static let selfChannel: UInt8 = 1
}

/// The radio GPS states the app can tell apart from what the radio sends.
enum RadioGPSStatus: Equatable {
  /// Not read yet, or the read failed.
  case unknown
  /// The radio has no GPS receiver (no `gps` custom var).
  case noReceiver
  /// The receiver is switched off. A radio in Eco mode reads as on, even while it sleeps between
  /// fixes.
  case off
  /// The receiver is on but the radio didn't send a GPS point to say more.
  case on
  /// The receiver is on and hasn't had a fix since the radio started.
  case searching
  /// The receiver is on and has had a fix; the position follows it.
  case fix

  /// Whether the radio's position follows its GPS receiver right now.
  var positionIsLive: Bool { self == .fix }
}
