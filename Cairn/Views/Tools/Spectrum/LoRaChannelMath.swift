import Foundation

/// LoRa figures derived from the radio's channel settings (Semtech SX126x datasheet and
/// AN1200.13). All values are theoretical; the Spectrum tab pairs them with what the radio measures.
struct LoRaChannelMath: Equatable {
  /// Centre frequency in Hz.
  let frequencyHz: Double
  /// Occupied bandwidth in Hz.
  let bandwidthHz: Double
  let spreadingFactor: Int
  /// Coding rate denominator: 5...8 for 4/5...4/8.
  let codingRate: Int
  /// Receiver noise figure the thermal floor assumes (SX126x typical).
  static let noiseFigure = 6.0
  /// MeshCore's preamble: longer at low spreading factors for reliability
  /// (`RadioLibWrapper::preambleLengthForSF`).
  var preambleSymbols: Double {
    spreadingFactor <= 8 ? 32 : 16
  }

  init(frequencyHz: Double, bandwidthHz: Double, spreadingFactor: Int, codingRate: Int) {
    self.frequencyHz = frequencyHz
    self.bandwidthHz = max(bandwidthHz, 1)
    self.spreadingFactor = min(max(spreadingFactor, 5), 12)
    self.codingRate = min(max(codingRate, 5), 8)
  }

  /// Thermal noise in the channel: kTB plus the receiver noise figure.
  var thermalNoiseFloor: Double {
    -174 + 10 * log10(bandwidthHz) + Self.noiseFigure
  }

  /// How far a measured noise floor sits above thermal noise, i.e. sensitivity lost to interference.
  /// Against thermal noise rounded to a whole dB, as Cairn's `spec::thermalDbm` rounds it, so the
  /// whole-dB floor the radio reports lands on the same side of the 3 and 10 dB steps on both.
  func desensitization(noiseFloor: Double) -> Double {
    max(0, noiseFloor - thermalNoiseFloor.rounded())
  }

  var symbolDuration: TimeInterval {
    pow(2, Double(spreadingFactor)) / bandwidthHz
  }

  /// The payload size Cairn quotes its airtime hint for ("~214 ms / 40B pkt"): about a short
  /// channel message, so a slower preset shows its cost before anything is sent.
  static let airtimeHintBytes = 40

  /// Time on air for a packet with an explicit header and CRC. The same formula as Cairn's
  /// `fmt::airtimeMs`, so the two agree on the same settings.
  func timeOnAir(payloadBytes: Int) -> TimeInterval {
    let sf = Double(spreadingFactor)
    let lowDataRateOptimize = symbolDuration >= 0.016 ? 1.0 : 0.0
    let numerator = 8 * Double(payloadBytes) - 4 * sf + 28 + 16
    let denominator = 4 * (sf - 2 * lowDataRateOptimize)
    let payloadSymbols = 8 + max(ceil(numerator / denominator) * Double(codingRate), 0)
    return (preambleSymbols + 4.25 + payloadSymbols) * symbolDuration
  }
}
