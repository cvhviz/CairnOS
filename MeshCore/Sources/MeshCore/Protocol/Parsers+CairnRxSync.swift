import Foundation

extension Parsers {
  // MARK: - CairnRxSync

  /// Parser for a Cairn companion's RX_SYNC receive journal (firmware's
  /// `examples/companion_radio/ui-l2/net/RX_SYNC.md`).
  ///
  /// Integers are little-endian. Later protocol versions only append fields, so bytes past the
  /// known layout are ignored. Offsets below are counted in the payload after the code byte (one
  /// less than the firmware document's, which counts the code).
  enum CairnRxSync {
    /// A reply's head: `[sub][status][op]`.
    static let replyHeader = 3
    /// A STATE reply: the head, then `[ver][epoch u32][first_seq u32][last_seq u32][cap_bytes u32]`
    /// `[opted][overwritten u32][push_refused u32][refused_mask u32]` = 33 bytes.
    static let stateReply = 33
    /// A SUBSCRIBE reply: the head, then `[on][resumed][epoch u32][first_seq u32][last_seq u32]`
    /// `[cursor u32]` = 21 bytes.
    static let subscribeReply = 21
    /// A FETCH reply: the head, then `[first_seq u32][last_seq u32][count]` = 12 bytes.
    static let fetchReply = 12
    /// A record's first frame before its raw bytes: `[flags][seq u32][age_ms u32][snr_x4][rssi]`.
    static let recordHeader = 11
    /// A record's continuation before its raw bytes: `[flags][seq u32][offset]`.
    static let continuationHeader = 6
    /// A FETCH_END: `[kind][epoch u32][first_seq u32][last_seq u32][sent]`.
    static let fetchEnd = 14
    /// A LOSS report: `[kind][epoch u32][overwritten u32][refused_mask u32][refused_count u16]`.
    static let loss = 15

    /// Parses an RX_SYNC reply (the payload after the 0xC0 code, starting with sub-command 0x07).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): Sub-command, 0x07
    /// - Offset 1 (1 byte): Status (``CairnRxSyncStatus``); a non-OK reply ends after the op
    /// - Offset 2 (1 byte): Op (``CairnRxSyncOp``); in a non-OK reply it may be one this library
    ///   doesn't know, or 0xFF when the request was too short to carry one
    /// - STATE: offset 3 ver, 4 epoch u32, 8 first_seq u32, 12 last_seq u32, 16 cap_bytes u32,
    ///   20 opted, 21 overwritten u32, 25 push_refused u32, 29 refused_mask u32
    /// - SUBSCRIBE: offset 3 on, 4 resumed, 5 epoch u32, 9 first_seq u32, 13 last_seq u32,
    ///   17 cursor u32
    /// - FETCH: offset 3 first_seq u32, 7 last_seq u32, 11 count
    static func parseReply(_ data: Data) -> MeshEvent {
      guard data.count >= replyHeader else {
        return .parseFailure(data: data, reason: "RX_SYNC reply too short: \(data.count) < \(replyHeader)")
      }
      // A refusal is `[status][op]` whatever the op: the firmware echoes an op it doesn't know, and
      // 0xFF for a request too short to carry one, and the request waiting for it still needs it.
      let status = CairnRxSyncStatus(rawValue: data[1])
      guard status == .ok else {
        return .cairnRxSyncReply(.refused(op: CairnRxSyncOp(rawValue: data[2]), status: status))
      }
      guard let op = CairnRxSyncOp(rawValue: data[2]) else {
        return .parseFailure(data: data, reason: "Unknown RX_SYNC op: \(data[2])")
      }
      switch op {
      case .state:
        guard data.count >= stateReply else {
          return .parseFailure(data: data, reason: "RX_SYNC STATE reply too short: \(data.count) < \(stateReply)")
        }
        return .cairnRxSyncReply(.state(CairnRxSyncState(
          version: data[3],
          epoch: data.readUInt32LE(at: 4),
          firstSeq: data.readUInt32LE(at: 8),
          lastSeq: data.readUInt32LE(at: 12),
          capacityBytes: data.readUInt32LE(at: 16),
          isOptedIn: data[20] != 0,
          overwritten: data.readUInt32LE(at: 21),
          pushRefused: data.readUInt32LE(at: 25),
          refusedMask: data.readUInt32LE(at: 29)
        )))
      case .subscribe:
        guard data.count >= subscribeReply else {
          return .parseFailure(
            data: data, reason: "RX_SYNC SUBSCRIBE reply too short: \(data.count) < \(subscribeReply)"
          )
        }
        return .cairnRxSyncReply(.subscribe(CairnRxSubscribeResult(
          isOn: data[3] != 0,
          resumed: data[4] != 0,
          epoch: data.readUInt32LE(at: 5),
          firstSeq: data.readUInt32LE(at: 9),
          lastSeq: data.readUInt32LE(at: 13),
          cursor: data.readUInt32LE(at: 17)
        )))
      case .fetch:
        guard data.count >= fetchReply else {
          return .parseFailure(data: data, reason: "RX_SYNC FETCH reply too short: \(data.count) < \(fetchReply)")
        }
        return .cairnRxSyncReply(.fetch(CairnRxFetchReply(
          firstSeq: data.readUInt32LE(at: 3),
          lastSeq: data.readUInt32LE(at: 7),
          count: data[11]
        )))
      }
    }

    /// Parses a ``ResponseCode/rxRecord`` push (the payload after 0xC8).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): Flags (``CairnRxRecordFrame/Flags``); bit 2 = a continuation
    /// - First frame: offset 1 seq u32, 5 age_ms u32, 9 snr_x4 i8, 10 rssi i8, 11 raw (≥ 1 byte)
    /// - Continuation: offset 1 seq u32, 5 offset, 6 the raw bytes' tail (≥ 1 byte)
    static func parseRecord(_ data: Data) -> MeshEvent {
      guard let first = data.first else {
        return .parseFailure(data: data, reason: "RX_SYNC record empty")
      }
      let flags = CairnRxRecordFrame.Flags(rawValue: first)
      if flags.contains(.continuation) {
        guard data.count > continuationHeader else {
          return .parseFailure(data: data, reason: "RX_SYNC continuation too short: \(data.count)")
        }
        return .cairnRxRecordFrame(CairnRxRecordFrame(
          flags: flags,
          seq: data.readUInt32LE(at: 1),
          ageMs: 0,
          snrX4: 0,
          rssi: 0,
          offset: data[5],
          raw: Data(data[continuationHeader...])
        ))
      }
      guard data.count > recordHeader else {
        return .parseFailure(data: data, reason: "RX_SYNC record too short: \(data.count)")
      }
      return .cairnRxRecordFrame(CairnRxRecordFrame(
        flags: flags,
        seq: data.readUInt32LE(at: 1),
        ageMs: data.readUInt32LE(at: 5),
        snrX4: Int8(bitPattern: data[9]),
        rssi: Int8(bitPattern: data[10]),
        raw: Data(data[recordHeader...])
      ))
    }

    /// Parses a ``ResponseCode/rxSyncStatus`` push (the payload after 0xC9).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): Kind: 0 FETCH_END, 1 LOSS
    /// - FETCH_END: offset 1 epoch u32, 5 first_seq u32, 9 last_seq u32, 13 sent
    /// - LOSS: offset 1 epoch u32, 5 overwritten u32, 9 refused_mask u32, 13 refused_count u16
    static func parseStatus(_ data: Data) -> MeshEvent {
      guard let kind = data.first else {
        return .parseFailure(data: data, reason: "RX_SYNC status empty")
      }
      switch kind {
      case 0:
        guard data.count >= fetchEnd else {
          return .parseFailure(data: data, reason: "RX_SYNC FETCH_END too short: \(data.count) < \(fetchEnd)")
        }
        return .cairnRxFetchEnd(CairnRxFetchEnd(
          epoch: data.readUInt32LE(at: 1),
          firstSeq: data.readUInt32LE(at: 5),
          lastSeq: data.readUInt32LE(at: 9),
          sent: data[13]
        ))
      case 1:
        guard data.count >= loss else {
          return .parseFailure(data: data, reason: "RX_SYNC LOSS too short: \(data.count) < \(loss)")
        }
        return .cairnRxLoss(CairnRxLoss(
          epoch: data.readUInt32LE(at: 1),
          overwritten: data.readUInt32LE(at: 5),
          refusedMask: data.readUInt32LE(at: 9),
          refusedCount: data.readUInt16LE(at: 13)
        ))
      default:
        return .parseFailure(data: data, reason: "Unknown RX_SYNC status kind: \(kind)")
      }
    }
  }
}
