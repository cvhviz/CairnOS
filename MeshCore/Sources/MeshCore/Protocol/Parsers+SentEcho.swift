import Foundation

extension Parsers {
  // MARK: - SentEcho

  /// Parser for Cairn firmware's echo of messages sent from the board's own UI
  /// (`RESP_CODE_SENT_ECHO` 0xC2 from the offline queue, `PUSH_CODE_SENT_ECHO` 0xC3 live).
  ///
  /// ### Binary Format (after the code byte)
  /// - Offset 0 (1 byte): Flags; bits 0–1 kind (0 DM, 1 channel, 2 status), bit 7 delivered
  /// - Offset 1 (6 bytes): Destination (DM key prefix, or channel index then 5 zeros)
  /// - Offset 7 (4 bytes): Timestamp (UInt32 LE)
  /// - Offset 11 (4 bytes): Expected ACK of attempt 0 (UInt32 LE, 0 for channels)
  /// - Offset 15: Text to the end (kinds 0, 1), or `[status u8][rtt_ms u32]` (kind 2)
  enum SentEcho {
    static func parse(_ data: Data, live: Bool) -> MeshEvent {
      guard data.count >= PacketSize.sentEchoHeader else {
        return .parseFailure(
          data: data,
          reason: "Sent echo too short: \(data.count) < \(PacketSize.sentEchoHeader)"
        )
      }
      let flags = data[0]
      guard let kind = RadioSentMessage.Kind(rawValue: flags & 0x03) else {
        return .parseFailure(data: data, reason: "Unknown sent echo kind: \(flags & 0x03)")
      }
      let destination = Data(data[1..<7])
      let timestamp = data.readUInt32LE(at: 7)
      let ackCode = data.readUInt32LE(at: 11)
      let delivered = flags & 0x80 != 0

      if kind == .statusUpdate {
        guard data.count >= PacketSize.sentEchoStatus else {
          return .parseFailure(
            data: data,
            reason: "Sent status update too short: \(data.count) < \(PacketSize.sentEchoStatus)"
          )
        }
        let status = RadioSentMessage.DeliveryStatus(rawValue: data[15])
        let rtt = data.readUInt32LE(at: 16)
        return .radioSentMessage(RadioSentMessage(
          isLive: live,
          kind: kind,
          destination: destination,
          timestamp: timestamp,
          ackCode: ackCode,
          isDelivered: delivered || status == .delivered,
          text: "",
          deliveryStatus: status,
          roundTripTime: status == .delivered ? rtt : nil
        ))
      }

      // No terminator on the wire; drop any trailing NULs a sender might still add.
      var textBytes = Data(data[PacketSize.sentEchoHeader...])
      while textBytes.last == 0 {
        textBytes.removeLast()
      }
      let text = textBytes.decodingLongestValidUTF8Prefix()
      return .radioSentMessage(RadioSentMessage(
        isLive: live,
        kind: kind,
        destination: destination,
        timestamp: timestamp,
        ackCode: ackCode,
        isDelivered: delivered,
        text: text
      ))
    }
  }
}
