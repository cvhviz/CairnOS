import Foundation

/// Session operations for draining the device's message queue.
public protocol MessageFetchSessionOps: Actor {
  /// Returns one message at a time from the device's message queue. Call repeatedly
  /// until ``MessageResult/noMoreMessages`` is returned to drain the queue.
  ///
  /// - Parameter timeout: Optional timeout override in seconds. Uses the session's default timeout when `nil`.
  /// - Returns: A ``MessageResult`` containing the fetched message, if any.
  /// - Throws: `MeshCoreError` if the fetch fails.
  func getMessage(timeout: TimeInterval?) async throws -> MessageResult

  /// Starts automatic message fetching in response to device notifications.
  func startAutoMessageFetching() async

  /// Stops the automatic fetching started by ``startAutoMessageFetching()``.
  func stopAutoMessageFetching()

  /// Drains the device's message queue now, as a `messagesWaiting` notification would.
  /// No-op unless automatic fetching is on.
  func requestMessageDrain() async

  /// Hands every automatic drain (a `messagesWaiting` push, ``requestMessageDrain()``, the
  /// periodic catch-up) to `handler` instead of the session's own fetch loop. The handler drains
  /// the queue to its end and stores each message before asking for the next, so a slow store
  /// slows the fetching instead of overflowing an event buffer with answers the radio has
  /// already dequeued. A thrown error is retried with the session's backoff. `nil` restores the
  /// session's own loop.
  func setAutoMessageDrainHandler(_ handler: (@Sendable () async throws -> Void)?) async

  /// Opts this link in or out of Cairn firmware's echo of messages sent from the board's own UI.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without the feature.
  func setCairnSyncSent(on: Bool, timeout: TimeInterval?) async throws -> CairnSyncSentState

  /// Asks a Cairn touch board how much chat history it holds.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without the feature.
  func queryCairnHistory() async throws -> CairnHistoryPageReply

  /// Fetches one page of a Cairn touch board's chat history (records numbered past `sinceSeq`).
  func fetchCairnHistoryPage(sinceSeq: UInt32, max: UInt8, inactivity: TimeInterval) async throws -> CairnHistoryPage

  /// Turns Cairn queue sync's queued delivery confirmations on or off (firmware's `QUEUE_SYNC.md`);
  /// its answer also tells whether the firmware has queue sync.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without the feature.
  func armCairnQueueSync(on: Bool, timeout: TimeInterval?) async throws -> CairnQueueSyncState

  /// Reads the radio's offline queue state and loss counters (Cairn queue sync).
  func cairnQueueSyncState(timeout: TimeInterval?) async throws -> CairnQueueSyncState

  /// Subtracts loss counts the app has read (Cairn queue sync).
  func clearCairnQueueLoss(_ loss: CairnQueueLoss, timeout: TimeInterval?) async throws -> CairnQueueSyncState

  /// Cairn queue sync's two-step read: removes the frame `ackSeq` names, answers the next one and
  /// leaves it queued until a later call names it.
  func nextCairnQueuedFrame(ackSeq: UInt32, timeout: TimeInterval?) async throws -> CairnQueuedFrame
}

// MARK: - Default Implementations

public extension MessageFetchSessionOps {
  /// Fetches one message using the session's default timeout.
  func getMessage() async throws -> MessageResult {
    try await getMessage(timeout: nil)
  }

  /// Default for conformers without automatic fetching: nothing to drain.
  func requestMessageDrain() async {}

  /// Default for conformers without automatic fetching: nothing calls the handler.
  func setAutoMessageDrainHandler(_: (@Sendable () async throws -> Void)?) async {}

  /// Default for conformers without the feature: answers as other firmware does.
  func setCairnSyncSent(on _: Bool, timeout _: TimeInterval?) async throws -> CairnSyncSentState {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Default for conformers without the feature: answers as other firmware does.
  func queryCairnHistory() async throws -> CairnHistoryPageReply {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Default for conformers without the feature: answers as other firmware does.
  func fetchCairnHistoryPage(sinceSeq _: UInt32, max _: UInt8, inactivity _: TimeInterval) async throws -> CairnHistoryPage {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Default for conformers without the feature: answers as other firmware does.
  func armCairnQueueSync(on _: Bool, timeout _: TimeInterval?) async throws -> CairnQueueSyncState {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Default for conformers without the feature: answers as other firmware does.
  func cairnQueueSyncState(timeout _: TimeInterval?) async throws -> CairnQueueSyncState {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Default for conformers without the feature: answers as other firmware does.
  func clearCairnQueueLoss(_: CairnQueueLoss, timeout _: TimeInterval?) async throws -> CairnQueueSyncState {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Default for conformers without the feature: answers as other firmware does.
  func nextCairnQueuedFrame(ackSeq _: UInt32, timeout _: TimeInterval?) async throws -> CairnQueuedFrame {
    throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }
}
