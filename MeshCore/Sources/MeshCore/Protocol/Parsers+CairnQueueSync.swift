import Foundation

extension Parsers {
  // MARK: - CairnQueueSync

  /// Parser for a Cairn companion's queue sync (firmware's
  /// `examples/companion_radio/ui-l2/net/QUEUE_SYNC.md`).
  ///
  /// Integers are little-endian; later versions only append. Offsets are counted in the payload
  /// after the 0xC0 code (one less than the firmware document's).
  enum CairnQueueSync {
    /// A reply's head: `[sub][status][op]`.
    static let replyHeader = 3
    /// STATE / ARM / CLEAR_LOSS: the head, then `[ver][armed][depth u16][cap u16][next_seq u32]`
    /// `[channel_evicted u32][refused u32][snapshot_lost u32][confirm_evicted u32]` = 29 bytes.
    static let stateReply = 29
    /// NEXT: the head, then `[seq u32][remaining u16]` = 9 bytes.
    static let nextReply = 9
    /// A queued confirmation after its code: `[ack u32][rtt_ms u32]`.
    static let confirmation = 8

    /// Parses a queue sync reply (the payload after 0xC0, starting with sub-command 0x08).
    static func parseReply(_ data: Data) -> MeshEvent {
      guard data.count >= replyHeader else {
        return .parseFailure(data: data, reason: "Queue sync reply too short: \(data.count) < \(replyHeader)")
      }
      let status = CairnQueueSyncStatus(rawValue: data[1])
      guard status == .ok else {
        return .cairnQueueSyncReply(.refused(op: CairnQueueSyncOp(rawValue: data[2]), status: status))
      }
      guard let op = CairnQueueSyncOp(rawValue: data[2]) else {
        return .parseFailure(data: data, reason: "Unknown queue sync op: \(data[2])")
      }
      switch op {
      case .next:
        guard data.count >= nextReply else {
          return .parseFailure(data: data, reason: "Queue sync NEXT reply too short: \(data.count) < \(nextReply)")
        }
        let remaining = UInt16(data[7]) | (UInt16(data[8]) << 8)
        return .cairnQueueSyncReply(.next(seq: data.readUInt32LE(at: 3), remaining: remaining))
      case .state, .arm, .clearLoss:
        guard data.count >= stateReply else {
          return .parseFailure(data: data, reason: "Queue sync STATE reply too short: \(data.count) < \(stateReply)")
        }
        return .cairnQueueSyncReply(.state(op: op, CairnQueueSyncState(
          version: data[3],
          isArmed: data[4] != 0,
          depth: UInt16(data[5]) | (UInt16(data[6]) << 8),
          capacity: UInt16(data[7]) | (UInt16(data[8]) << 8),
          nextSeq: data.readUInt32LE(at: 9),
          loss: CairnQueueLoss(
            channelEvicted: data.readUInt32LE(at: 13),
            refused: data.readUInt32LE(at: 17),
            snapshotLost: data.readUInt32LE(at: 21),
            confirmationsEvicted: data.readUInt32LE(at: 25)
          )
        )))
      }
    }

    /// Parses a queued delivery confirmation (the payload after 0xCA) as the acknowledgement it is.
    static func parseConfirmation(_ data: Data) -> MeshEvent {
      guard data.count >= confirmation else {
        return .parseFailure(data: data, reason: "Queued confirmation too short: \(data.count) < \(confirmation)")
      }
      return .acknowledgement(code: Data(data.prefix(4)), tripTime: data.readUInt32LE(at: 4))
    }
  }
}
