import Foundation

/// Codec for WiFi/TCP frame encoding and decoding.
///
/// MeshCore WiFi protocol uses length-prefixed framing:
/// - Outbound (app to device): `<` (0x3C) + 2-byte length (LE) + payload
/// - Inbound (device to app): `>` (0x3E) + 2-byte length (LE) + payload
public enum WiFiFrameCodec: Sendable {
  /// Outbound frame delimiter (app to device)
  public static let outboundDelimiter: UInt8 = 0x3C // '<'

  /// Inbound frame delimiter (device to app)
  public static let inboundDelimiter: UInt8 = 0x3E // '>'

  /// Header size: delimiter (1) + length (2)
  public static let headerSize = 3

  /// Largest inbound payload accepted. The companion protocol's frames stay under 256 bytes
  /// (MAX_FRAME_SIZE is 172 upstream, 176 in Cairn's firmware); this leaves headroom for other
  /// builds while keeping a corrupt length field from parking the decoder on a phantom 64 KB
  /// frame that would swallow every real frame behind it.
  public static let maxInboundPayloadLength = 512

  /// Encodes a payload for transmission to the device.
  /// Format: `<` + 2-byte length (little-endian) + payload
  public static func encode(_ payload: Data) -> Data {
    var frame = Data(capacity: headerSize + payload.count)
    frame.append(outboundDelimiter)

    let length = UInt16(payload.count)
    frame.append(UInt8(length & 0xFF)) // low byte
    frame.append(UInt8((length >> 8) & 0xFF)) // high byte

    frame.append(payload)
    return frame
  }
}

/// Stateful decoder for incoming WiFi frames.
/// Buffers partial data and extracts complete frames.
public struct WiFiFrameDecoder: Sendable {
  private var buffer = Data()

  public init() {}

  /// Decodes incoming data, returning any complete frames.
  /// Partial frames are buffered for subsequent calls.
  public mutating func decode(_ data: Data) -> [Data] {
    buffer.append(data)
    var frames: [Data] = []

    while let frame = extractFrame() {
      frames.append(frame)
    }

    return frames
  }

  /// Extracts a single complete frame from the buffer, if available.
  private mutating func extractFrame() -> Data? {
    while true {
      // Skip any bytes until we find the delimiter
      while buffer.count > 0, buffer[buffer.startIndex] != WiFiFrameCodec.inboundDelimiter {
        buffer.removeFirst()
      }

      // Need at least header
      guard buffer.count >= WiFiFrameCodec.headerSize else {
        return nil
      }

      // Read length (little-endian) using indices relative to startIndex
      let startIdx = buffer.startIndex
      let length = Int(buffer[startIdx + 1]) | (Int(buffer[startIdx + 2]) << 8)

      // No real frame is this long: the '>' was a payload byte or the header is corrupt.
      // Drop that marker and resync on the next one rather than wait for bytes that
      // belong to later frames.
      guard length <= WiFiFrameCodec.maxInboundPayloadLength else {
        buffer.removeFirst()
        continue
      }
      let totalFrameSize = WiFiFrameCodec.headerSize + length

      // Wait for complete frame
      guard buffer.count >= totalFrameSize else {
        return nil
      }

      // Extract payload using proper range
      let payloadStart = startIdx + WiFiFrameCodec.headerSize
      let payloadEnd = startIdx + totalFrameSize
      let payload = Data(buffer[payloadStart..<payloadEnd])
      buffer.removeFirst(totalFrameSize)

      return payload
    }
  }

  /// Clears the internal buffer.
  public mutating func reset() {
    buffer.removeAll()
  }
}
