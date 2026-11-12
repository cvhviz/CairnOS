import Foundation

public struct DeviceGPSState: Sendable, Equatable {
  public let isSupported: Bool
  public let isEnabled: Bool
  /// Whether the receiver runs in Eco (duty-cycled) mode, or `nil` when the firmware has no
  /// Eco mode. Cairn firmware that runs Eco reports it through the `gps_mode` custom var.
  public let isEco: Bool?
  /// The receiver's satellites, HDOP and so on, on firmware that reports them.
  public let details: RadioGPSDetails?

  /// Whether the firmware offers GPS Eco mode.
  public var supportsEco: Bool {
    isEco != nil
  }

  public init(isSupported: Bool, isEnabled: Bool, isEco: Bool? = nil, details: RadioGPSDetails? = nil) {
    self.isSupported = isSupported
    self.isEnabled = isEnabled
    self.isEco = isEco
    self.details = details
  }
}
