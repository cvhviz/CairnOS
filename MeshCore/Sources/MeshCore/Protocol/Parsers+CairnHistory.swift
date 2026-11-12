import Foundation

extension Parsers {
  // MARK: - CairnHistory

  /// Parser for a Cairn touch board's chat history pushes (firmware's `net/HIST_SYNC.md`).
  enum CairnHistory {
    /// Parses a ``ResponseCode/historyRecord`` push (the payload after 0xC4).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): Flags (``CairnHistoryRecord/Flags``); bit 6 = a continuation
    /// - First frame: offset 1 seq u32, 5 key (6), 11 channel i8 (-1 = a DM), 12 path_len,
    ///   13 stored_ts u32, 17 sent_ts u32, 21 snr_x4 i8, 22 rssi i16, 24 text
    /// - Continuation: offset 1 seq u32, 5 the text's tail
    static func parseRecord(_ data: Data) -> MeshEvent {
      guard let first = data.first else {
        return .parseFailure(data: data, reason: "History record empty")
      }
      let flags = CairnHistoryRecord.Flags(rawValue: first)
      if flags.contains(.continuation) {
        guard data.count >= PacketSize.cairnHistoryContHeader else {
          return .parseFailure(data: data, reason: "History continuation too short: \(data.count)")
        }
        return .cairnHistoryRecord(CairnHistoryRecord(
          flags: flags,
          seq: data.readUInt32LE(at: 1),
          key: Data(),
          channelIndex: nil,
          pathLength: 0xFF,
          storedAt: 0,
          sentAt: 0,
          snrX4: 0,
          rssi: 0,
          text: Data(data[PacketSize.cairnHistoryContHeader...])
        ))
      }
      guard data.count >= PacketSize.cairnHistoryRecordHeader else {
        return .parseFailure(
          data: data,
          reason: "History record too short: \(data.count) < \(PacketSize.cairnHistoryRecordHeader)"
        )
      }
      let channel = Int8(bitPattern: data[11])
      return .cairnHistoryRecord(CairnHistoryRecord(
        flags: flags,
        seq: data.readUInt32LE(at: 1),
        key: Data(data[5..<11]),
        channelIndex: channel < 0 ? nil : UInt8(channel),
        pathLength: data[12],
        storedAt: data.readUInt32LE(at: 13),
        sentAt: data.readUInt32LE(at: 17),
        snrX4: Int8(bitPattern: data[21]),
        rssi: data.readInt16LE(at: 22),
        text: Data(data[PacketSize.cairnHistoryRecordHeader...])
      ))
    }

    /// Parses a ``ResponseCode/historyEnd`` push (the payload after 0xC5).
    static func parseEnd(_ data: Data) -> MeshEvent {
      guard data.count >= PacketSize.cairnHistoryEnd else {
        return .parseFailure(
          data: data,
          reason: "History end too short: \(data.count) < \(PacketSize.cairnHistoryEnd)"
        )
      }
      return .cairnHistoryEnd(CairnHistoryEnd(
        aborted: data[0] != 0,
        lastSeq: data.readUInt32LE(at: 1),
        remaining: data.readUInt16LE(at: 5),
        storeID: data.readUInt32LE(at: 7)
      ))
    }
  }
}
