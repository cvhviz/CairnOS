import Foundation

/// Session operations for observing connection state and subscribing to device events.
public protocol SessionEventStreaming: Actor {
  // MARK: - Connection State

  /// Provides an observable connection state stream for UI binding.
  var connectionState: AsyncStream<ConnectionState> { get }

  // MARK: - Event Operations

  /// Subscribes to all events from the device.
  ///
  /// Each subscriber receives all events independently.
  ///
  /// - Returns: An async stream yielding ``MeshEvent`` values as they are received.
  func events() async -> AsyncStream<MeshEvent>

  /// Subscribes to events passing the given filter.
  ///
  /// Prefer this over ``events()`` when the consumer only cares about a
  /// narrow slice of events.
  ///
  /// - Parameter filter: The ``EventFilter`` that determines which events reach the stream.
  /// - Returns: An async stream yielding only events that pass `filter`.
  func events(filter: EventFilter) async -> AsyncStream<MeshEvent>

  /// Subscribes to events passing the given filter, with a buffer of the caller's choosing.
  ///
  /// A consumer that must not miss a burst (the RX log, the neighbour table) asks for a deeper
  /// buffer than the default 100 events, and a label so its drops can be read back with
  /// ``eventDropCount(label:)``.
  ///
  /// - Parameters:
  ///   - filter: The ``EventFilter`` that determines which events reach the stream.
  ///   - buffering: What the stream keeps while the consumer lags.
  ///   - label: The name the subscription's drops are counted under, or `nil`.
  /// - Returns: An async stream yielding only events that pass `filter`.
  func events(
    filter: EventFilter,
    buffering: AsyncStream<MeshEvent>.Continuation.BufferingPolicy,
    label: String?
  ) async -> AsyncStream<MeshEvent>

  /// Events dropped so far by the subscriptions labelled `label`, because they lagged.
  func eventDropCount(label: String) async -> Int

  /// Waits for an event matching an ``EventFilter`` with timeout.
  ///
  /// - Parameters:
  ///   - filter: The event filter to apply.
  ///   - timeout: Maximum time to wait in seconds. Uses the session's default timeout when `nil`.
  /// - Returns: The matching event, or `nil` if the timeout expired.
  func waitForEvent(filter: EventFilter, timeout: TimeInterval?) async -> MeshEvent?

  // MARK: - Link Pacing

  /// Waits until the radio's link has been free of pushed frames for `quiet`, or for at most
  /// `maxWait`, after any hold from ``holdBackgroundTraffic(for:owner:)`` ends.
  ///
  /// Official companion firmware drops a frame when its small Bluetooth send queue is full, and
  /// drops the answer to a message fetch after it has already taken the message off its queue.
  /// Call this before an optional command whose answer matters, never before a user's send.
  ///
  /// - Parameters:
  ///   - quiet: How long the link must have been free of pushes.
  ///   - maxWait: The longest the wait lasts once any hold has ended.
  func waitForQuietLink(quiet: Duration, maxWait: Duration) async

  /// Holds back optional traffic (message fetches and other ``waitForQuietLink(quiet:maxWait:)``
  /// callers) for `duration`, at most 30 seconds, while a burst of replies is expected, such as a
  /// discover listen window. Each owner has one hold, which a later call can only extend; release
  /// it with ``releaseBackgroundTraffic(owner:)`` when the burst won't come.
  ///
  /// - Parameters:
  ///   - duration: How long from now the hold lasts.
  ///   - owner: Who holds it, such as the scan or region discovery.
  func holdBackgroundTraffic(for duration: Duration, owner: String) async

  /// Ends `owner`'s hold now: the request it was for failed or was stopped.
  func releaseBackgroundTraffic(owner: String) async
}

// MARK: - Default Implementations

public extension SessionEventStreaming {
  /// Default for conformers without buffer control (test doubles): the plain filtered stream.
  func events(
    filter: EventFilter,
    buffering _: AsyncStream<MeshEvent>.Continuation.BufferingPolicy,
    label _: String?
  ) async -> AsyncStream<MeshEvent> {
    await events(filter: filter)
  }

  /// Default for conformers that count no drops.
  func eventDropCount(label _: String) async -> Int {
    0
  }

  /// Waits for an event using the session's default timeout.
  func waitForEvent(filter: EventFilter) async -> MeshEvent? {
    await waitForEvent(filter: filter, timeout: nil)
  }

  /// Default for conformers with no radio link to pace (test doubles): returns at once.
  func waitForQuietLink(quiet _: Duration, maxWait _: Duration) async {}

  /// Default for conformers with no radio link to pace (test doubles): holds nothing.
  func holdBackgroundTraffic(for _: Duration, owner _: String) async {}

  /// Default for conformers with no radio link to pace (test doubles): nothing to release.
  func releaseBackgroundTraffic(owner _: String) async {}

  /// Waits for ``QuietLink/quiet`` (300 ms) without pushed frames, for at most `maxWait`.
  func waitForQuietLink(maxWait: Duration = QuietLink.maxWait) async {
    await waitForQuietLink(quiet: QuietLink.quiet, maxWait: maxWait)
  }
}
