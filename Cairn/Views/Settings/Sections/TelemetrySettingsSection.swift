import CairnServices
import SwiftUI

/// Firmware telemetry permission levels, shared by the base, location, and environment modes.
private enum TelemetryMode {
  static let off: UInt8 = 0
  static let trustedOnly: UInt8 = 1
  static let everyone: UInt8 = 2
}

/// The telemetry levels a switch asks for: on at the trusted-only level while that's in force,
/// everyone otherwise. Shared by the Telemetry section and Location & Sharing's Telemetry card, so
/// both write the same thing.
enum TelemetrySwitches {
  static func isOn(_ mode: UInt8) -> Bool {
    mode > TelemetryMode.off
  }

  static func isTrustedOnly(_ device: DeviceDTO) -> Bool {
    device.telemetryModeBase == TelemetryMode.trustedOnly
  }

  /// The device's modes with the given switches changed (nil keeps a switch as it is).
  static func modes(
    _ device: DeviceDTO,
    base: Bool? = nil,
    location: Bool? = nil,
    environment: Bool? = nil,
    trustedOnly: Bool? = nil
  ) -> TelemetryModes {
    let level = (trustedOnly ?? isTrustedOnly(device)) ? TelemetryMode.trustedOnly : TelemetryMode.everyone
    func mode(_ wanted: Bool?, current: UInt8) -> UInt8 {
      (wanted ?? isOn(current)) ? level : TelemetryMode.off
    }
    return TelemetryModes(
      base: mode(base, current: device.telemetryModeBase),
      location: mode(location, current: device.telemetryModeLoc),
      environment: mode(environment, current: device.telemetryModeEnv)
    )
  }
}
