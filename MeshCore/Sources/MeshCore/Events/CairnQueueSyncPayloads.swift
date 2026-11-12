import Foundation

// MARK: - Cairn queue sync (firmware's examples/companion_radio/ui-l2/net/QUEUE_SYNC.md)

/// The ops of ``CairnFirmwareSubcommand/queueSync``.
public enum CairnQueueSyncOp: UInt8, Sendable {
  /// The queue's depth and loss counters.
  case state = 0x00
  /// Turns on (or off) the queueing of delivery confirmations for NEXT readers.
  case arm = 0x01
  /// The two-step read: removes the frame the app stored, answers the next and leaves it queued.
  case next = 0x02
  /// Subtracts loss counts the app has read.
  case clearLoss = 0x03
}

/// A queue sync reply's status.
public enum CairnQueueSyncStatus: UInt8, Sendable {
  case ok = 0
  /// NEXT: the radio's send queue had no room for the answer; nothing was removed, ask again.
  case busy = 1
  /// Malformed request or unknown op.
  case badArgument = 2
}

/// What the radio's offline queue lost (kept by the radio until cleared).
public struct CairnQueueLoss: Sendable, Equatable {
  /// Channel messages and datagrams pushed out by newer frames while the queue was full.
  public let channelEvicted: UInt32
  /// DMs, room posts and CLI replies turned away because the queue was full of them.
  public let refused: UInt32
  /// Frames a reboot lost (the radio's flash snapshot was cut short).
  public let snapshotLost: UInt32
  /// Queued delivery confirmations pushed out.
  public let confirmationsEvicted: UInt32

  public init(channelEvicted: UInt32, refused: UInt32, snapshotLost: UInt32, confirmationsEvicted: UInt32) {
    self.channelEvicted = channelEvicted
    self.refused = refused
    self.snapshotLost = snapshotLost
    self.confirmationsEvicted = confirmationsEvicted
  }

  /// Nothing lost.
  public static let none = CairnQueueLoss(channelEvicted: 0, refused: 0, snapshotLost: 0, confirmationsEvicted: 0)

  /// Messages (not confirmations) lost, saturating.
  public var lostMessages: Int {
    Int(channelEvicted) + Int(refused) + Int(snapshotLost)
  }

  /// Whether anything at all was lost.
  public var isEmpty: Bool {
    channelEvicted == 0 && refused == 0 && snapshotLost == 0 && confirmationsEvicted == 0
  }
}

/// The radio's queue state (a STATE, ARM or CLEAR_LOSS reply).
public struct CairnQueueSyncState: Sendable, Equatable {
  public let version: UInt8
  /// Delivery confirmations are queued for NEXT readers.
  public let isArmed: Bool
  /// Frames waiting for a NEXT reader.
  public let depth: UInt16
  /// The queue's capacity in frames.
  public let capacity: UInt16
  /// The seq the next queued frame gets.
  public let nextSeq: UInt32
  public let loss: CairnQueueLoss

  public init(version: UInt8, isArmed: Bool, depth: UInt16, capacity: UInt16, nextSeq: UInt32, loss: CairnQueueLoss) {
    self.version = version
    self.isArmed = isArmed
    self.depth = depth
    self.capacity = capacity
    self.nextSeq = nextSeq
    self.loss = loss
  }
}

/// A queue sync reply.
public enum CairnQueueSyncReply: Sendable, Equatable {
  /// STATE, ARM or CLEAR_LOSS (`op` says which).
  case state(op: CairnQueueSyncOp, CairnQueueSyncState)
  /// NEXT's head: the seq of the frame that follows (0 with nothing queued) and how many come after it.
  case next(seq: UInt32, remaining: UInt16)
  /// A non-OK reply; `op` is nil for one this library doesn't know (or 0xFF).
  case refused(op: CairnQueueSyncOp?, status: CairnQueueSyncStatus?)
}

/// One frame read with queue sync NEXT.
public struct CairnQueuedFrame: Sendable {
  /// What it was.
  public enum Content: Sendable {
    /// A received message, a channel datagram or a sent-message echo, as a stock fetch answers it.
    case message(MessageResult)
    /// A delivery confirmation the radio kept (also dispatched as ``MeshEvent/acknowledgement(code:tripTime:)``).
    case confirmation(code: Data, tripTime: UInt32?)
    /// A frame this library can't read (newer firmware's kind); acknowledged and skipped.
    case unreadable
    /// The queue is empty.
    case noMoreMessages
  }

  /// The frame's seq, which the next NEXT names once it is stored (0 with ``Content/noMoreMessages``).
  public let seq: UInt32
  /// Frames queued after this one.
  public let remaining: UInt16
  public let content: Content

  public init(seq: UInt32, remaining: UInt16, content: Content) {
    self.seq = seq
    self.remaining = remaining
    self.content = content
  }
}
