import Foundation

/// A companion's receive-gain switches, as `SettingsService.readReceiveGain()` reads them: each is
/// nil when this radio doesn't have it.
public struct ReceiveGain: Sendable, Equatable {
  /// The SX126x boosted RX gain (`radio.rxgain`).
  public var boostedRX: Bool?
  /// The external front end's LNA (`radio.fem.rxgain`).
  public var femLNA: Bool?

  public init(boostedRX: Bool? = nil, femLNA: Bool? = nil) {
    self.boostedRX = boostedRX
    self.femLNA = femLNA
  }

  /// Neither switch exists on this radio.
  public var isEmpty: Bool { boostedRX == nil && femLNA == nil }
}
