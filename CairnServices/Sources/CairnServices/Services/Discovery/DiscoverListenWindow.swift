import Foundation

/// How long to listen for answers to one `NODE_DISCOVER_REQ`, from the radio's LoRa settings.
///
/// A stock repeater answers after a random delay of up to four retransmit delays, `4 · 5 · t`
/// with `t = 0.5 · A` (`tx_delay_factor` 0.5), where A is the reply's airtime: a window of
/// 10 · A. Listening for that window, one more airtime for the last reply to land and 1.5 s of
/// link latency gives `10A + A + 1.5 s`, clamped to 6...15 s. At WCMesh's SF7/BW62.5 that is the
/// 6 s floor. The ceiling covers Cairn repeaters, which widen their window with neighbour density;
/// the caller extends the window by ``extensionStep`` for each reply arriving near its end.
public enum DiscoverListenWindow {
  /// Bytes on air of a full-key discover reply.
  public static let replyBytes = 46
  public static let minimum: TimeInterval = 6
  public static let maximum: TimeInterval = 15
  /// Link latency between the radio hearing a reply and the app seeing it.
  static let latency: TimeInterval = 1.5
  /// A reply arriving within this long of the window's end extends it by the same amount.
  public static let extensionStep: TimeInterval = 3

  /// The listen window for the connected radio. `bandwidth` is in Hz, as `DeviceDTO` stores it.
  public static func seconds(for device: DeviceDTO) -> TimeInterval {
    seconds(
      spreadingFactor: Int(device.spreadingFactor),
      bandwidthHz: Double(device.bandwidth),
      codingRate: Int(device.codingRate)
    )
  }

  /// The listen window: `clamp(10A + A + 1.5 s, 6 s, 15 s)` with A the airtime of one reply.
  public static func seconds(spreadingFactor: Int, bandwidthHz: Double, codingRate: Int) -> TimeInterval {
    let airtime = replyAirtime(spreadingFactor: spreadingFactor, bandwidthHz: bandwidthHz, codingRate: codingRate)
    return min(max(10 * airtime + airtime + latency, minimum), maximum)
  }

  /// Where the window ends after a reply at `reply`: pushed out by ``extensionStep`` when the reply
  /// came within that long of the current `end`, never past ``maximum`` after `start`.
  public static func extendedEnd(_ end: Date, start: Date, reply: Date) -> Date {
    guard end.timeIntervalSince(reply) <= extensionStep else { return end }
    return min(end.addingTimeInterval(extensionStep), start.addingTimeInterval(maximum))
  }

  /// Time on air of one discover reply at these settings.
  static func replyAirtime(spreadingFactor: Int, bandwidthHz: Double, codingRate: Int) -> TimeInterval {
    timeOnAir(
      payloadBytes: replyBytes,
      spreadingFactor: spreadingFactor,
      bandwidthHz: bandwidthHz,
      codingRate: codingRate
    )
  }

  /// LoRa time on air with an explicit header and CRC (Semtech SX126x datasheet), with MeshCore's
  /// preamble: 32 symbols up to SF8, 16 above (`RadioLibWrapper::preambleLengthForSF`). The same
  /// formula as the Spectrum tab's `LoRaChannelMath.timeOnAir` and Cairn's `fmt::airtimeMs`.
  static func timeOnAir(payloadBytes: Int, spreadingFactor: Int, bandwidthHz: Double, codingRate: Int) -> TimeInterval {
    let sf = Double(min(max(spreadingFactor, 5), 12))
    let cr = Double(min(max(codingRate, 5), 8))
    let symbol = pow(2, sf) / max(bandwidthHz, 1)
    let preamble: Double = sf <= 8 ? 32 : 16
    let lowDataRateOptimize = symbol >= 0.016 ? 1.0 : 0.0
    let numerator = 8 * Double(payloadBytes) - 4 * sf + 28 + 16
    let denominator = 4 * (sf - 2 * lowDataRateOptimize)
    let payloadSymbols = 8 + max(ceil(numerator / denominator) * cr, 0)
    return (preamble + 4.25 + payloadSymbols) * symbol
  }
}
