import Foundation
import MeshCore

/// The companion radio's flood timing, as `get rxdelay` / `get af` are on a repeater: the RX
/// delay base, which holds weaker floods back so stronger paths win, and the airtime factor, how
/// long the radio stays quiet after sending as a multiple of its airtime.
public struct RadioTuning: Sendable, Equatable {
  public var rxDelayBase: Double
  public var airtimeFactor: Double

  /// What MeshCore's firmware ships with.
  public static let firmwareDefault = RadioTuning(rxDelayBase: 0, airtimeFactor: 1)

  public init(rxDelayBase: Double, airtimeFactor: Double) {
    self.rxDelayBase = rxDelayBase
    self.airtimeFactor = airtimeFactor
  }

  /// The values as sent and stored: thousandths, as whole numbers.
  var rxDelayWire: UInt32 { Self.wire(rxDelayBase) }
  var airtimeFactorWire: UInt32 { Self.wire(airtimeFactor) }

  private static func wire(_ value: Double) -> UInt32 {
    UInt32(max(0, (value * 1000).rounded()))
  }

  /// Whether a tuning read failed because the firmware has no tuning commands, rather than
  /// because the radio didn't answer.
  public static func isUnsupported(_ error: Error) -> Bool {
    if case let SettingsServiceError.sessionError(sessionError) = error,
       case .deviceError = sessionError {
      return true
    }
    return false
  }
}
