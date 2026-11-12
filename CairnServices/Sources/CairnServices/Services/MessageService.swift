import Foundation
import MeshCore

// MARK: - Message Service Actor

/// Actor-isolated service for sending messages with retry logic and ACK tracking.
///
/// `MessageService` manages all message operations including:
/// - Sending direct messages to contacts with single-attempt or automatic retry
/// - Sending channel broadcast messages
/// - Tracking pending message acknowledgements (ACKs)
/// - Handling delivery confirmations and failures
/// - Automatic retry with flood routing fallback
///
/// # Example Usage
///
/// ```swift
/// // Send a message with automatic retry
/// let message = try await messageService.sendMessageWithRetry(
///     text: "Hello!",
///     to: contact
/// ) { messageDTO in
///     // Message saved, update UI immediately
///     await updateUI(with: messageDTO)
/// }
/// ```
///
/// # ACK Tracking
///
/// After sending a message, the service tracks pending ACKs and automatically:
/// - Marks messages as delivered when ACK is received
/// - Marks messages as failed when timeout expires
/// - Tracks repeat acknowledgements for network analysis
///
/// Call `startEventMonitoring()` to begin processing ACKs from the session.
public actor MessageService {
  // MARK: - Properties

  let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "MessageService")

  let session: any MeshCoreSessionProtocol
  let dataStore: any PersistenceStoreProtocol
  let config: MessageServiceConfig

  /// Contact service for path management (optional - retry with reset requires this).
  /// Injected by `ServiceContainer` at construction.
  private let contactService: ContactService?

  /// In-flight messages awaiting ACK, keyed by messageID.
  ///
  /// One entry per message. Each entry carries the full set of expected-ACK
  /// CRCs accumulated across retry attempts, so a late ACK from any attempt
  /// can still mark the message delivered.
  var pendingAcks: [UUID: PendingAck] = [:] {
    // The expiry checker only runs while something is in flight; the first
    // insert after it went idle starts it again. No `oldValue` read, so no copy.
    didSet {
      if ackCheckTask == nil, !pendingAcks.isEmpty {
        startAckCheckLoopIfNeeded()
      }
    }
  }

  /// Multicast broadcaster for outbound-message lifecycle events.
  ///
  /// Every yield happens synchronously at its lifecycle site on this actor,
  /// so yield order equals consumption order and multi-ACK bursts reach
  /// subscribers in the order the actor processed them.
  nonisolated let statusEventBroadcaster = EventBroadcaster<MessageStatusEvent>()

  /// Task for periodic ACK expiry checking. Runs only while `pendingAcks` is
  /// non-empty and `isAckExpiryCheckingEnabled`; nil while idle.
  var ackCheckTask: Task<Void, Never>?

  /// Whether `startAckExpiryChecking()` armed the checker (until stopped).
  /// The loop itself is started lazily on the first pending entry.
  var isAckExpiryCheckingEnabled = false

  /// Bumped whenever a checker loop starts or is cancelled, so a loop that is
  /// exiting cannot clear the handle of a newer loop.
  var ackCheckGeneration = 0

  /// Task for listening to session events
  private var eventListenerTask: Task<Void, Never>?

  /// Interval between ACK expiry checks (in seconds)
  var checkInterval: TimeInterval = 5.0

  /// Tracks message IDs currently being retried to prevent concurrent retry attempts
  var inFlightRetries: Set<UUID> = []

  // MARK: - Initialization

  /// Creates a new message service.
  ///
  /// - Parameters:
  ///   - session: The MeshCore session for sending messages
  ///   - dataStore: The persistence store for saving messages
  ///   - contactService: Contact service for path management during retry
  ///   - config: Configuration for retry and routing behavior (defaults to `.default`)
  init(
    session: any MeshCoreSessionProtocol,
    dataStore: any PersistenceStoreProtocol,
    contactService: ContactService?,
    config: MessageServiceConfig = .default
  ) {
    self.session = session
    self.dataStore = dataStore
    self.contactService = contactService
    self.config = config
  }

  /// Whether a contact service was injected at construction.
  var hasContactServiceWired: Bool {
    contactService != nil
  }

  // MARK: - Event Listening

  /// Starts the session ACK event listener.
  ///
  /// Subscribes to `.anyAcknowledgement` events on the session and routes
  /// each one through `handleAcknowledgement`. Call after the connection is
  /// established; without this the listener never runs and pending DMs stay
  /// `.sent` even when ACKs arrive.
  ///
  /// # Lifecycle scope
  ///
  /// This method's counterpart is `stopEventMonitoring()`. It does **not**
  /// start the periodic ACK expiry checker — that's `startAckExpiryChecking()`,
  /// which has its own `stopAckExpiryChecking()` / `stopAndFailAllPending()`
  /// counterparts. `ServiceContainer` pairs both lifecycles together; direct
  /// callers must do the same.
  public func startEventMonitoring() {
    eventListenerTask?.cancel()

    eventListenerTask = Task { [weak self] in
      guard let self else { return }

      for await event in await session.events(filter: .anyAcknowledgement) {
        guard !Task.isCancelled else { break }

        if case let .acknowledgement(code, tripTime) = event {
          await handleAcknowledgement(code: code, tripTime: tripTime)
        }
      }
    }
  }

  /// Stops the session ACK event listener.
  ///
  /// Cancels `eventListenerTask` only. Does **not** cancel the periodic ACK
  /// expiry checker — for that, call `stopAckExpiryChecking()` (just stop
  /// the checker, used on a routine disconnect) or `stopAndFailAllPending()`
  /// (stop the checker and fail every in-flight DM, for explicit full teardown).
  public func stopEventMonitoring() {
    eventListenerTask?.cancel()
    eventListenerTask = nil
  }

  // MARK: - ACK Handling

  /// Handles an end-to-end ACK with no live `pendingAcks` entry.
  ///
  /// A reconnect rebuilds the container, so a DM in flight across it loses its
  /// entry while its row stays `.sent`; the firmware still re-emits the ACK.
  /// Upgrading that `.sent` row here keeps it from showing "Sent" forever. A row
  /// already failed is upgraded too (a late ACK, or one a Cairn radio queued while
  /// the app was away, proves delivery), and a duplicate for a delivered row is a no-op.
  func reconcileUnmatchedAcknowledgement(code: Data, tripTime: UInt32?) async {
    let reconciled: (messageID: UUID, contactID: UUID?)?
    do {
      reconciled = try await dataStore.markOutgoingSentDMDelivered(ackCode: code.ackCodeUInt32, roundTripTime: tripTime)
    } catch {
      logger.error("Failed to reconcile unmatched ACK: \(error.localizedDescription)")
      reconciled = nil
    }
    guard let reconciled else {
      logger.warning("[ack-diag] unmatched ACK code=\(code.uppercaseHexString()) livePending=\(pendingAcks.count) (late post-give-up or duplicate)")
      return
    }

    logger.info("[ack-diag] reconciled orphaned .sent DM \(reconciled.messageID) from an unmatched ACK")
    if let contactID = reconciled.contactID {
      try? await dataStore.updateContactLastMessage(contactID: contactID, date: Date())
    }
    statusEventBroadcaster.yield(.statusResolved(messageID: reconciled.messageID, status: .delivered, roundTripTime: tripTime))
  }

  /// Fails `.sent` DMs a previous container left behind once they are past the
  /// ACK give-up window, as its expiry checker would have. Run on (re)connect;
  /// rows this container is still tracking are skipped.
  public func failOrphanedSentMessages() async {
    let cutoff = Date().addingTimeInterval(-config.ackGiveUpWindow)
    do {
      let failedIDs = try await dataStore.failStaleSentDMs(sentBefore: cutoff, excluding: Set(pendingAcks.keys))
      guard !failedIDs.isEmpty else { return }
      logger.info("[ack-diag] failed \(failedIDs.count) orphaned .sent DM(s) past the give-up window")
      for messageID in failedIDs {
        statusEventBroadcaster.yield(.failed(messageID: messageID))
      }
    } catch {
      logger.error("Failed to sweep orphaned .sent DMs: \(error.localizedDescription)")
    }
  }

  /// Processes an acknowledgement from the session event stream.
  ///
  /// Finds the in-flight message whose accumulated `ackCodes` contains this
  /// CRC, marks it delivered, writes the delivery status + round-trip time
  /// to the database, and removes the entry. This is the sole DB writer for
  /// delivered status on the late-ACK path.
  func handleAcknowledgement(code: Data, tripTime: UInt32?) async {
    guard let (messageID, tracking) = pendingAcks.first(where: {
      $0.value.ackCodes.contains(code) && !$0.value.isDelivered
    }) else {
      await reconcileUnmatchedAcknowledgement(code: code, tripTime: tripTime)
      return
    }

    pendingAcks[messageID]?.isDelivered = true

    // Persist `tripTime` only when firmware supplied it. Date()-based
    // fallbacks against `tracking.sentAt` would be wrong in either
    // direction once retries reset the timestamp, so we prefer a nil
    // `roundTripTime` over a fabricated value.
    let ackCodeUInt32 = code.ackCodeUInt32

    do {
      try await dataStore.updateMessageAck(
        id: messageID,
        ackCode: ackCodeUInt32,
        status: .delivered,
        roundTripTime: tripTime
      )
    } catch {
      logger.error("Failed to write delivered status: \(error.localizedDescription)")
    }

    do {
      try await dataStore.updateContactLastMessage(contactID: tracking.contactID, date: Date())
    } catch {
      logger.error("Failed to update contact lastMessageDate: \(error.localizedDescription)")
    }

    pendingAcks.removeValue(forKey: messageID)

    statusEventBroadcaster.yield(.statusResolved(messageID: messageID, status: .delivered, roundTripTime: tripTime))

    // Diagnostic: how long the ACK took relative to the last send attempt
    // (sentAt is re-stamped per retry), the firmware-reported round trip,
    // and how many other entries were in flight. Distinguishes late-but-
    // arriving ACKs from never-arriving ones and measures table pressure.
    let ackDelta = Date().timeIntervalSince(tracking.sentAt)
    logger.info("[ack-diag] ACK matched deltaSinceLastSend=\(String(format: "%.2f", ackDelta))s firmwareTrip=\(tripTime.map { "\($0)ms" } ?? "nil") livePending=\(pendingAcks.count)")
  }

  // MARK: - Status Events

  /// Returns a fresh stream of outbound-message lifecycle events.
  /// Registration is synchronous, so events yielded after this call are
  /// never dropped. Consumers must re-subscribe per connection because the
  /// owning `ServiceContainer` is rebuilt on every connection.
  public nonisolated func statusEvents() -> AsyncStream<MessageStatusEvent> {
    statusEventBroadcaster.subscribe()
  }

  /// Ends every `statusEvents()` subscriber's for-await loop. Called by
  /// `ServiceContainer.tearDown()` so consumer tasks release the service
  /// references they hold.
  nonisolated func finishStatusEvents() {
    statusEventBroadcaster.finish()
  }

  /// Broadcasts `.failed` for a message from outside the actor. Sole
  /// purpose: the queue-side terminal catch in `ChatSendQueueService` runs
  /// off-actor and needs to surface the failure. Do not grow other callers;
  /// the inline send paths yield the event directly because they own the
  /// catch.
  public func notifyMessageFailed(messageID: UUID) async {
    statusEventBroadcaster.yield(.failed(messageID: messageID))
  }
}
