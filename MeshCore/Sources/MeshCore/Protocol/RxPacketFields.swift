import Foundation

/// The fields of one received packet that neighbour evidence is read from.
///
/// Both a live ``ParsedRxLogData`` and a stored RX log entry carry these, so the same extractor
/// runs on the live stream and on the replay of stored entries.
public struct RxPacketFields: Sendable, Equatable {
  public let routeType: RouteType
  public let payloadType: PayloadType
  /// The encoded path-length byte (bits 7-6 hash size mode, bits 5-0 hop count).
  public let pathLength: UInt8
  /// The raw path bytes, first hop first.
  public let pathNodes: Data
  /// The packet payload after the header, transport code and path.
  public let packetPayload: Data
  /// The correlation hash of `packetPayload` (``ParsedRxLogData/computePacketHash(from:)``).
  public let packetHash: String
  /// SNR at this radio in dB, if the radio reported it.
  public let snr: Double?
  /// RSSI at this radio in dBm, if the radio reported it.
  public let rssi: Int?

  public init(
    routeType: RouteType,
    payloadType: PayloadType,
    pathLength: UInt8,
    pathNodes: Data,
    packetPayload: Data,
    packetHash: String,
    snr: Double?,
    rssi: Int?
  ) {
    self.routeType = routeType
    self.payloadType = payloadType
    self.pathLength = pathLength
    self.pathNodes = pathNodes
    self.packetPayload = packetPayload
    self.packetHash = packetHash
    self.snr = snr
    self.rssi = rssi
  }

  public init(_ parsed: ParsedRxLogData) {
    self.init(
      routeType: parsed.routeType,
      payloadType: parsed.payloadType,
      pathLength: parsed.pathLength,
      pathNodes: Data(parsed.pathNodes),
      packetPayload: parsed.packetPayload,
      packetHash: parsed.packetHash,
      snr: parsed.snr,
      rssi: parsed.rssi
    )
  }
}
