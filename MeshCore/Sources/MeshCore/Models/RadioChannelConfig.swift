import Foundation

/// The LoRa channel a radio listens and transmits on, as the radio itself reports it in
/// `RESP_CODE_SELF_INFO` (stock companion firmware: `radio_freq` in kHz, `radio_bw` in Hz,
/// `radio_sf`, `radio_cr`).
///
/// Values are the radio's own integers, so two readings of the same channel compare equal with
/// no tolerance. Radios hear each other only when frequency, bandwidth and spreading factor
/// match; the coding rate travels in LoRa's explicit header, so radios at different coding rates
/// still hear each other. ``key`` therefore leaves the coding rate out.
public struct RadioChannelConfig: Sendable, Hashable, Codable {
  /// The centre frequency in kHz (910.525 MHz is `910_525`).
  public let frequencyKHz: UInt32
  /// The bandwidth in Hz (250 kHz is `250_000`, 62.5 kHz is `62_500`).
  public let bandwidthHz: UInt32
  /// The LoRa spreading factor (5-12).
  public let spreadingFactor: UInt8
  /// The LoRa coding rate denominator (5-8). Recorded, not part of ``key``.
  public let codingRate: UInt8

  public init(frequencyKHz: UInt32, bandwidthHz: UInt32, spreadingFactor: UInt8, codingRate: UInt8) {
    self.frequencyKHz = frequencyKHz
    self.bandwidthHz = bandwidthHz
    self.spreadingFactor = spreadingFactor
    self.codingRate = codingRate
  }

  /// The channel a `SELF_INFO` reply reports, or `nil` when it reports no frequency.
  ///
  /// ``SelfInfo`` holds the wire integers divided by 1000 (MHz and kHz); multiplying back and
  /// rounding recovers them exactly.
  public init?(selfInfo: SelfInfo) {
    guard selfInfo.radioFrequency.isFinite, selfInfo.radioBandwidth.isFinite,
          selfInfo.radioFrequency > 0, selfInfo.radioBandwidth >= 0 else { return nil }
    let frequency = (selfInfo.radioFrequency * 1000).rounded()
    let bandwidth = (selfInfo.radioBandwidth * 1000).rounded()
    guard frequency >= 1, frequency <= Double(UInt32.max), bandwidth <= Double(UInt32.max) else { return nil }
    self.init(
      frequencyKHz: UInt32(frequency),
      bandwidthHz: UInt32(bandwidth),
      spreadingFactor: selfInfo.radioSpreadingFactor,
      codingRate: selfInfo.radioCodingRate
    )
  }

  /// The channel a ``ChannelKey`` names. The key carries no coding rate, so ``codingRate`` is 0.
  public init?(key: ChannelKey) {
    let parts = key.rawValue.split(separator: "-")
    guard parts.count == 3,
          parts[0].hasPrefix("f"), parts[1].hasPrefix("bw"), parts[2].hasPrefix("sf"),
          let frequency = UInt32(parts[0].dropFirst(1)), frequency > 0,
          let bandwidth = UInt32(parts[1].dropFirst(2)),
          let spreadingFactor = UInt8(parts[2].dropFirst(2)) else { return nil }
    self.init(frequencyKHz: frequency, bandwidthHz: bandwidth, spreadingFactor: spreadingFactor, codingRate: 0)
  }

  /// The identity of the channel: frequency, bandwidth and spreading factor.
  public var key: ChannelKey {
    ChannelKey(rawValue: "f\(frequencyKHz)-bw\(bandwidthHz)-sf\(spreadingFactor)")
  }

  /// The centre frequency in MHz, for display.
  public var frequencyMHz: Double {
    Double(frequencyKHz) / 1000
  }

  /// The bandwidth in kHz, for display.
  public var bandwidthKHz: Double {
    Double(bandwidthHz) / 1000
  }
}

/// The identity of a LoRa channel (``RadioChannelConfig/key``): frequency in kHz, bandwidth in Hz
/// and spreading factor, such as `"f910525-bw250000-sf10"`. Stable across app versions, so it can
/// be stored and compared as a string.
public struct ChannelKey: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
