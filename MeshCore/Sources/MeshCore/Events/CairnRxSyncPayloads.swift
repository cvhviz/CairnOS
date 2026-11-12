import Foundation

// MARK: - Cairn RX_SYNC (firmware's examples/companion_radio/ui-l2/net/RX_SYNC.md)

/// The ops of an RX_SYNC request (`[0xC0][0x07][op][...]`), which its reply repeats.
public enum CairnRxSyncOp: UInt8, Sendable {
  /// The radio's receive journal: its epoch, the records it holds and its loss counters.
  case state = 0x00
  /// Turns this link's RX_SYNC delivery on (with a resume point) or back to stock 0x88 frames.
  case subscribe = 0x01
  /// Asks for held records again, pushed as ``ResponseCode/rxRecord`` frames marked
  /// ``CairnRxRecordFrame/Flags/backfill`` and ended by a ``CairnRxFetchEnd``.
  case fetch = 0x02
}

/// The status byte of an RX_SYNC reply.
public enum CairnRxSyncStatus: Sendable, Equatable {
  case ok
  /// FETCH: this link's previous fetch is still going out (ask again after its end); SUBSCRIBE:
  /// every one of the radio's link slots is taken.
  case busy
  /// The request was malformed (a wrong length, a FETCH `max` outside 1...32), or a FETCH came
  /// from a link that has not opted in.
  case badArgument
  /// A status this library doesn't know.
  case other(UInt8)

  public init(rawValue: UInt8) {
    switch rawValue {
    case 0: self = .ok
    case 1: self = .busy
    case 2: self = .badArgument
    default: self = .other(rawValue)
    }
  }

  public var rawValue: UInt8 {
    switch self {
    case .ok: 0
    case .busy: 1
    case .badArgument: 2
    case let .other(value): value
    }
  }
}

/// The radio's receive journal as a STATE reply describes it.
public struct CairnRxSyncState: Sendable, Equatable {
  /// The protocol version the radio speaks (1); later versions only append fields.
  public let version: UInt8
  /// The journal's identity, random at each boot: a different epoch means the app's cursor no
  /// longer applies.
  public let epoch: UInt32
  /// The oldest record the journal still holds (``lastSeq`` + 1 while it is empty).
  public let firstSeq: UInt32
  /// The newest record (0 while nothing has been received since boot).
  public let lastSeq: UInt32
  /// The journal's size in bytes.
  public let capacityBytes: UInt32
  /// This link already receives RX_SYNC records.
  public let isOptedIn: Bool
  /// Records evicted before an opted-in link had been sent them, since boot.
  public let overwritten: UInt32
  /// Stock pushes a link refused because its send queue was full, since boot.
  public let pushRefused: UInt32
  /// Which frames were refused since boot (``CairnRxLoss/refusedMask`` bits).
  public let refusedMask: UInt32

  public init(
    version: UInt8, epoch: UInt32, firstSeq: UInt32, lastSeq: UInt32, capacityBytes: UInt32,
    isOptedIn: Bool, overwritten: UInt32, pushRefused: UInt32, refusedMask: UInt32
  ) {
    self.version = version
    self.epoch = epoch
    self.firstSeq = firstSeq
    self.lastSeq = lastSeq
    self.capacityBytes = capacityBytes
    self.isOptedIn = isOptedIn
    self.overwritten = overwritten
    self.pushRefused = pushRefused
    self.refusedMask = refusedMask
  }
}

/// The radio's answer to a SUBSCRIBE: the state in force and where this link's delivery starts.
public struct CairnRxSubscribeResult: Sendable, Equatable {
  /// RX_SYNC delivery is on for this link (`false`: back to stock 0x88 frames).
  public let isOn: Bool
  /// The request's resume point applied: delivery picks up after it (otherwise live only).
  public let resumed: Bool
  public let epoch: UInt32
  public let firstSeq: UInt32
  public let lastSeq: UInt32
  /// The first record this link's live pushes carry (0 when off).
  public let cursor: UInt32

  public init(isOn: Bool, resumed: Bool, epoch: UInt32, firstSeq: UInt32, lastSeq: UInt32, cursor: UInt32) {
    self.isOn = isOn
    self.resumed = resumed
    self.epoch = epoch
    self.firstSeq = firstSeq
    self.lastSeq = lastSeq
    self.cursor = cursor
  }
}

/// The radio's answer to a FETCH; `count` backfill records and one ``CairnRxFetchEnd`` follow.
public struct CairnRxFetchReply: Sendable, Equatable {
  /// The oldest record the journal holds: anything the app misses below it is lost at the radio.
  public let firstSeq: UInt32
  /// The newest record the journal holds.
  public let lastSeq: UInt32
  /// Records this fetch will push (fewer than asked when the journal ends first). Fewer still
  /// arrive when the journal overwrites some first: ``CairnRxFetchEnd/sent`` is the authority.
  public let count: UInt8

  public init(firstSeq: UInt32, lastSeq: UInt32, count: UInt8) {
    self.firstSeq = firstSeq
    self.lastSeq = lastSeq
    self.count = count
  }
}

/// The answer to an RX_SYNC request.
public enum CairnRxSyncReply: Sendable, Equatable {
  case state(CairnRxSyncState)
  case subscribe(CairnRxSubscribeResult)
  case fetch(CairnRxFetchReply)
  /// The radio answered with a non-OK status (BUSY, BAD_ARG); no fields follow it. `op` is `nil`
  /// when the radio named none this library knows (0xFF: the request was too short to carry one).
  case refused(op: CairnRxSyncOp?, status: CairnRxSyncStatus)
  /// The firmware has no RX_SYNC: it answered `ERR_CODE_UNSUPPORTED_CMD`. Use the stock 0x88
  /// frames for this connection. Never parsed from a 0xC0 frame; see ``init(answering:to:)``.
  case unsupported

  /// The op this answers; `nil` for ``unsupported`` and for a refusal that names no known op.
  public var op: CairnRxSyncOp? {
    switch self {
    case .state: .state
    case .subscribe: .subscribe
    case .fetch: .fetch
    case let .refused(op, _): op
    case .unsupported: nil
    }
  }

  /// Reads `event` as the answer to an RX_SYNC request of `op`: its reply, or ``unsupported`` for
  /// the `[RESP_CODE_ERR][ERR_CODE_UNSUPPORTED_CMD]` frame that firmware without RX_SYNC sends.
  ///
  /// A refusal that names no known op answers whichever request is waiting: requests are sent one
  /// at a time, and the radio refuses a request it can't read without naming its op.
  ///
  /// Returns `nil` for every other event, including another op's reply and other errors.
  public init?(answering event: MeshEvent, to op: CairnRxSyncOp) {
    switch event {
    case let .cairnRxSyncReply(reply) where reply.op == op:
      self = reply
    case let .cairnRxSyncReply(.refused(nil, status)):
      self = .refused(op: nil, status: status)
    case .error(code: ErrorCode.unsupportedCommand.rawValue):
      self = .unsupported
    default:
      return nil
    }
  }
}

/// One frame of a received packet from the radio's journal: a record's first frame, or
/// (``Flags/continuation``) the rest of its raw bytes.
public struct CairnRxRecordFrame: Sendable, Equatable {
  public struct Flags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Sent again for a FETCH, not live.
    public static let backfill = Flags(rawValue: 0x01)
    /// A continuation with the same `seq` follows.
    public static let more = Flags(rawValue: 0x02)
    public static let continuation = Flags(rawValue: 0x04)
    /// Records before this one were overwritten before this link was sent them.
    public static let gap = Flags(rawValue: 0x08)
  }

  public let flags: Flags
  /// The radio's number for the packet, growing by one per packet within an epoch.
  public let seq: UInt32
  /// How long before the frame was written the radio received the packet, in ms (0 on a
  /// continuation).
  public let ageMs: UInt32
  /// SNR ×4 as the radio measured it (0 on a continuation).
  public let snrX4: Int8
  /// RSSI in dBm (0 on a continuation).
  public let rssi: Int8
  /// A continuation's position in the packet's raw bytes (0 on a first frame).
  public let offset: UInt8
  /// The packet's raw bytes (a first frame's head, or a continuation's tail).
  public let raw: Data

  public init(
    flags: Flags, seq: UInt32, ageMs: UInt32, snrX4: Int8, rssi: Int8, offset: UInt8 = 0, raw: Data
  ) {
    self.flags = flags
    self.seq = seq
    self.ageMs = ageMs
    self.snrX4 = snrX4
    self.rssi = rssi
    self.offset = offset
    self.raw = raw
  }

  /// SNR in dB.
  public var snr: Double { Double(snrX4) / 4.0 }

  /// How long before the frame was written the radio received the packet.
  public var radioAge: Duration { .milliseconds(Int64(ageMs)) }

  /// A first frame without ``Flags/more``: the whole packet.
  public var isComplete: Bool {
    !flags.contains(.continuation) && !flags.contains(.more)
  }

  /// This first frame with `continuation`'s tail appended, or `nil` when `continuation` isn't
  /// the next part of this record (another `seq`, not a continuation, or a different offset).
  ///
  /// The result keeps this frame's flags, with ``Flags/more`` taken from the continuation.
  public func appending(_ continuation: CairnRxRecordFrame) -> CairnRxRecordFrame? {
    guard !flags.contains(.continuation), flags.contains(.more),
          continuation.flags.contains(.continuation), continuation.seq == seq,
          Int(continuation.offset) == raw.count else {
      return nil
    }
    var joined = flags.subtracting(.more)
    if continuation.flags.contains(.more) { joined.insert(.more) }
    return CairnRxRecordFrame(
      flags: joined, seq: seq, ageMs: ageMs, snrX4: snrX4, rssi: rssi, raw: raw + continuation.raw
    )
  }

  /// The whole packet parsed as a 0x88 frame's would be, with its RX_SYNC position set; `nil`
  /// while the record is incomplete or when its bytes don't parse as a packet.
  ///
  /// - Parameters:
  ///   - epoch: The journal epoch the record belongs to.
  ///   - isBackfill: Whether the record is sent again rather than live; `nil` takes the
  ///     ``Flags/backfill`` flag. The session passes `true` for the backlog a resumed SUBSCRIBE
  ///     sends, which the radio pushes as live records.
  public func rxLogData(epoch: UInt32, isBackfill: Bool? = nil) -> ParsedRxLogData? {
    guard isComplete,
          let parsed = RxLogParser.parse(snr: snr, rssi: Int(rssi), payload: raw) else {
      return nil
    }
    return parsed.withRxSync(
      seq: seq, epoch: epoch, radioAge: radioAge, isBackfill: isBackfill ?? flags.contains(.backfill)
    )
  }
}

/// The end of a FETCH, pushed after its records.
public struct CairnRxFetchEnd: Sendable, Equatable {
  public let epoch: UInt32
  /// The oldest record the journal holds: what the app misses below it is lost at the radio.
  public let firstSeq: UInt32
  public let lastSeq: UInt32
  /// Records the fetch sent.
  public let sent: UInt8

  public init(epoch: UInt32, firstSeq: UInt32, lastSeq: UInt32, sent: UInt8) {
    self.epoch = epoch
    self.firstSeq = firstSeq
    self.lastSeq = lastSeq
    self.sent = sent
  }
}

/// The radio lost something this link should have had: journal records overwritten before they
/// were sent, or pushes refused because the link's send queue was full.
public struct CairnRxLoss: Sendable, Equatable {
  public let epoch: UInt32
  /// Records evicted from the journal before this link was sent them, since boot.
  public let overwritten: UInt32
  /// The frames refused since this link's last LOSS: bit `n` is a push with code `0x80 + n`
  /// (0x80...0x9E), bit 31 any other frame (a reply, a Cairn push).
  public let refusedMask: UInt32
  /// Frames refused since this link's last LOSS.
  public let refusedCount: UInt16

  public init(epoch: UInt32, overwritten: UInt32, refusedMask: UInt32, refusedCount: UInt16) {
    self.epoch = epoch
    self.overwritten = overwritten
    self.refusedMask = refusedMask
    self.refusedCount = refusedCount
  }

  /// A push with this code was refused (always `false` for codes outside 0x80...0x9E).
  public func refused(_ code: ResponseCode) -> Bool {
    guard code.rawValue >= 0x80, code.rawValue < 0x80 + 31 else { return false }
    return refusedMask & (1 << UInt32(code.rawValue - 0x80)) != 0
  }

  /// A frame other than a stock push (a reply, a Cairn push) was refused.
  public var refusedOther: Bool { refusedMask & (1 << 31) != 0 }
}
