import Foundation
import os

public extension MeshCoreSession {
  // MARK: - Cairn queue sync (firmware's examples/companion_radio/ui-l2/net/QUEUE_SYNC.md)

  /// Reads the radio's offline queue state and loss counters.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on firmware
  ///   without queue sync; ``MeshCoreError/timeout`` if no reply arrives.
  func cairnQueueSyncState(timeout: TimeInterval? = nil) async throws -> CairnQueueSyncState {
    try await queueSyncStateExchange(PacketBuilder.cairnQueueSyncState(), op: .state, timeout: timeout)
  }

  /// Turns the radio's queueing of delivery confirmations for NEXT readers on or off. The radio
  /// remembers it across reboots; the app arms it on every connect, which also tells it whether the
  /// firmware has queue sync.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on firmware
  ///   without queue sync; ``MeshCoreError/timeout`` if no reply arrives.
  func armCairnQueueSync(on: Bool, timeout: TimeInterval? = nil) async throws -> CairnQueueSyncState {
    // The radio writes the reply without checking its send queue (unlike NEXT, which answers BUSY):
    // sent into a burst of pushes, as on a reconnect, the reply can be dropped and the probe time out.
    await waitForQuietLink(quiet: linkPacing.fetchQuiet, maxWait: linkPacing.fetchMaxWait)
    return try await queueSyncStateExchange(PacketBuilder.cairnQueueSyncArm(on: on), op: .arm, timeout: timeout)
  }

  /// Subtracts loss counts this app has read and reported. Counts the radio added since stay.
  func clearCairnQueueLoss(_ loss: CairnQueueLoss, timeout: TimeInterval? = nil) async throws -> CairnQueueSyncState {
    try await queueSyncStateExchange(PacketBuilder.cairnQueueSyncClearLoss(loss), op: .clearLoss, timeout: timeout)
  }

  /// The two-step read of the radio's offline queue.
  ///
  /// The radio removes the frame `ackSeq` names (0 = none; the seq of the frame this app stored
  /// since its last NEXT), then answers the next frame and leaves it queued. A link that drops, or an
  /// app suspended or killed before it stored the frame, gets it again from the next NEXT, so nothing
  /// leaves the radio before it is stored here. Send the same `ackSeq` again after a timeout: a seq the
  /// radio already removed is ignored.
  ///
  /// - Parameters:
  ///   - ackSeq: The seq of the last frame stored and not yet named to the radio (0 = none).
  ///   - timeout: Optional timeout override in seconds.
  /// - Returns: The frame, its seq and how many follow it.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` (BUSY or a malformed request),
  ///   ``MeshCoreError/timeout`` when the answer does not come.
  func nextCairnQueuedFrame(ackSeq: UInt32, timeout: TimeInterval? = nil) async throws -> CairnQueuedFrame {
    // Lossless, but a full send queue on the radio still makes it answer BUSY: leave it room first.
    await waitForQuietLink(quiet: linkPacing.fetchQuiet, maxWait: linkPacing.fetchMaxWait)
    let head = QueueSyncNextHead()
    return try await sendAndMatch(PacketBuilder.cairnQueueSyncNext(ackSeq: ackSeq), timeout: timeout) { event in
      guard let (seq, remaining) = head.value else {
        switch event {
        case let .cairnQueueSyncReply(.next(seq, remaining)):
          head.value = (seq, remaining)
          return .ignore
        case let .cairnQueueSyncReply(.refused(op, status)) where op == .next || op == nil:
          return .failure(.deviceError(code: status == .busy ? Self.queueSyncBusyCode : ErrorCode.illegalArgument.rawValue))
        case .error:
          // Not NEXT's answer: firmware with queue sync answers every NEXT with a 0xC0 0x08 reply
          // (stock firmware never gets here, the ARM probe found it), so a plain ERR is someone
          // else's, e.g. a late reply to a timed-out command or another link's error, which the
          // radio writes to every interface. Taking it would fail a NEXT the radio still answers.
          return .ignore
        default:
          return .ignore
        }
      }
      // The radio writes the frame right after its head (it answers BUSY when it can't fit both).
      let content: CairnQueuedFrame.Content
      switch event {
      case let .contactMessageReceived(message):
        content = .message(.contactMessage(message))
      case let .channelMessageReceived(message):
        content = .message(.channelMessage(message))
      case let .channelDataReceived(datagram):
        content = .message(.channelDatagram(datagram))
      case let .radioSentMessage(message) where !message.isLive:
        content = .message(.radioSentMessage(message))
      case let .acknowledgement(code, tripTime):
        content = .confirmation(code: code, tripTime: tripTime)
      case .noMoreMessages:
        content = .noMoreMessages
      case let .parseFailure(data, _) where data.first.map(Self.answersQueueSyncNext) ?? true:
        content = .unreadable
      default:
        return .ignore
      }
      return .success(CairnQueuedFrame(seq: seq, remaining: remaining, content: content))
    }
  }

  /// The device error code ``nextCairnQueuedFrame(ackSeq:timeout:)`` throws for a BUSY answer (not a
  /// firmware error code: 0xF0 is outside MeshCore's range).
  static let queueSyncBusyCode: UInt8 = 0xF0

  /// Whether a frame with this code can be NEXT's frame: anything a stock fetch answers, or a queued
  /// confirmation, or a code this library doesn't know below the push range.
  internal static func answersQueueSyncNext(_ code: UInt8) -> Bool {
    code == ResponseCode.queuedConfirmation.rawValue || answersMessageFetch(code)
  }

  private func queueSyncStateExchange(_ data: Data, op: CairnQueueSyncOp, timeout: TimeInterval?) async throws
    -> CairnQueueSyncState {
    try await sendAndMatch(data, timeout: timeout) { event in
      switch event {
      case let .cairnQueueSyncReply(.state(replyOp, state)) where replyOp == op:
        .success(state)
      case let .cairnQueueSyncReply(.refused(replyOp, _)) where replyOp == op || replyOp == nil:
        .failure(.deviceError(code: ErrorCode.illegalArgument.rawValue))
      case let .error(code):
        .failure(.deviceError(code: code ?? 0))
      default:
        .ignore
      }
    }
  }
}

/// NEXT's head, carried from the reply to the frame after it inside one matcher.
private final class QueueSyncNextHead: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock<(UInt32, UInt16)?>(initialState: nil)
  var value: (UInt32, UInt16)? {
    get { lock.withLock { $0 } }
    set { lock.withLock { $0 = newValue } }
  }
}
