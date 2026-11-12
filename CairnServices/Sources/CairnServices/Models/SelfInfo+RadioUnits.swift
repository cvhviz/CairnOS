import Foundation
import MeshCore

public extension MeshCore.SelfInfo {
  /// The radio's frequency in kHz, as the firmware sent it. The parser divides the firmware's
  /// integer by 1000, and multiplying back can land just under it (512.002 MHz gives
  /// 512001.99999…), so this rounds rather than truncates.
  var radioFrequencyKHz: UInt32 {
    UInt32((max(radioFrequency, 0) * 1000).rounded())
  }

  /// The radio's bandwidth in Hz, as the firmware sent it; rounded for the same reason.
  var radioBandwidthHz: UInt32 {
    UInt32((max(radioBandwidth, 0) * 1000).rounded())
  }
}
