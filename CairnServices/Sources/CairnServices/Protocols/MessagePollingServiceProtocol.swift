import Foundation
import MeshCore

/// Protocol for MessagePollingService to enable testability of SyncCoordinator.
///
/// This protocol abstracts the message polling operations used by SyncCoordinator,
/// allowing it to be tested with mock implementations.
///
/// ## Usage
///
/// Services can accept this protocol type for dependency injection:
/// ```swift
/// actor MyCoordinator {
///     private let messagePollingService: any MessagePollingServiceProtocol
///
///     init(messagePollingService: any MessagePollingServiceProtocol) {
///         self.messagePollingService = messagePollingService
///     }
/// }
/// ```
protocol MessagePollingServiceProtocol: Actor {
  // MARK: - Message Polling

  /// Poll all waiting messages from the device.
  /// - Returns: Count of messages retrieved
  func pollAllMessages() async throws -> Int

  /// Wait for all pending message handlers to complete.
  /// Call this after pollAllMessages() to ensure all messages are fully processed.
  func waitForPendingHandlers(timeout: Duration) async -> Bool

  // MARK: - Auto-Fetch Lifecycle

  /// Start periodic message auto-fetch for the connected radio.
  func startAutoFetch(radioID: UUID) async

  /// Pause auto-fetch (e.g. while a sync owns the transport).
  func pauseAutoFetch() async

  /// Resume auto-fetch after a pause.
  func resumeAutoFetch() async

  /// Drain the radio's message queue now, without waiting for its next `messagesWaiting` push.
  func requestDrain() async

  // MARK: - Ingestion Handlers

  /// Install the handler invoked for each incoming direct message.
  func setContactMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?, DeliveryContext) async -> Void)

  /// Install the handler invoked for each incoming channel message.
  func setChannelMessageHandler(_ handler: @escaping @Sendable (ChannelMessage, ChannelDTO?, DeliveryContext) async -> Void)

  /// Install the handler invoked for each incoming signed room message.
  func setSignedMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?) async -> Void)

  /// Install the handler invoked for each incoming CLI response.
  func setCLIMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?) async -> Void)

  /// Install the handler invoked for each message sent from the radio's own UI.
  func setRadioSentMessageHandler(_ handler: @escaping @Sendable (RadioSentMessage, DeliveryContext) async -> Void)

  /// Opt this link in to the radio's sent-message echo (Cairn firmware; no-op elsewhere).
  func enableRadioSentSync() async

  /// Whether the connected radio runs Cairn firmware (DEVICE_INFO); `false` skips the Cairn
  /// extensions' probes for this connection.
  func setCairnFirmware(_ isCairn: Bool) async

  /// Pulls a Cairn board's own chat history (firmware's `HIST_SYNC.md`) past what this app already
  /// has from it, through the message handlers, stored read and silent. Returns the records walked.
  func importRadioHistory() async -> Int

  /// Install the handler told what a Cairn radio's offline queue lost while the app was away
  /// (firmware's `QUEUE_SYNC.md`). It returns whether the loss reached the user or was recorded for
  /// them; the radio's counters are cleared only then.
  func setQueueLossHandler(_ handler: @escaping @Sendable (CairnQueueLoss) async -> Bool)
}

// MARK: - Default Implementations

extension MessagePollingServiceProtocol {
  /// Default no-op for stubs; `MessagePollingService` implements it.
  func setQueueLossHandler(_: @escaping @Sendable (CairnQueueLoss) async -> Bool) {}

  /// Default no-op for stubs; `MessagePollingService` implements it.
  func setRadioSentMessageHandler(_: @escaping @Sendable (RadioSentMessage, DeliveryContext) async -> Void) {}

  /// Default no-op for stubs; `MessagePollingService` implements it.
  func enableRadioSentSync() async {}
  func importRadioHistory() async -> Int { 0 }
  func setCairnFirmware(_: Bool) async {}

  /// Default no-op for stubs; `MessagePollingService` implements it.
  func requestDrain() async {}
}
