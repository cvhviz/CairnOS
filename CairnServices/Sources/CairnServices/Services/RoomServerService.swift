import Foundation
import MeshCore
import os

// MARK: - Room Server Errors

public enum RoomServerError: Error, Sendable {
  case notConnected
  case sessionNotFound
  case sendFailed(String)
  case permissionDenied
  case invalidResponse
  case sessionError(MeshCoreError)
}

extension RoomServerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConnected: "Not connected to device."
    case .sessionNotFound: "Room session not found."
    case let .sendFailed(msg): "Send failed: \(msg)"
    case .permissionDenied: "Permission denied."
    case .invalidResponse: "Invalid response from device."
    case let .sessionError(e): e.localizedDescription
    }
  }
}

// MARK: - Room Server Service

/// Service for room server interactions.
/// Handles joining rooms, posting messages, and receiving room messages.
public actor RoomServerService {
  // MARK: - Properties

  private let session: any RemoteAccessSessionOps
  private let remoteNodeService: RemoteNodeService
  private let dataStore: any PersistenceStoreProtocol
  private let radioID: UUID
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "RoomServer")
  private let auditLogger = CommandAuditLogger()

  /// This radio's own 4-byte key prefix, the author prefix of the user's posts. Read from the
  /// radio's device record (its key from SelfInfo) on first use, or set by
  /// `setSelfPublicKeyPrefix`.
  private var selfPublicKeyPrefix: Data?

  /// Configuration for retry behavior (shared with MessageService)
  private let config: MessageServiceConfig

  /// Multicast broadcaster for status-update and connection-recovery events.
  private nonisolated let eventBroadcaster = EventBroadcaster<RoomServerEvent>()

  /// Tracks message IDs currently being retried to prevent concurrent retry attempts
  private var inFlightRetries: Set<UUID> = []

  // MARK: - Initialization

  init(
    session: any RemoteAccessSessionOps,
    remoteNodeService: RemoteNodeService,
    dataStore: any PersistenceStoreProtocol,
    radioID: UUID,
    config: MessageServiceConfig = MessageServiceConfig()
  ) {
    self.session = session
    self.remoteNodeService = remoteNodeService
    self.dataStore = dataStore
    self.radioID = radioID
    self.config = config
  }

  /// Set self public key prefix from SelfInfo.
  /// Call this when device info is received.
  public func setSelfPublicKeyPrefix(_ prefix: Data) {
    selfPublicKeyPrefix = prefix.prefix(4)
  }

  /// This radio's own author prefix: set explicitly, else read from its device record. Nil only
  /// when the radio's key isn't known yet.
  func selfKeyPrefix() async -> Data? {
    if let selfPublicKeyPrefix { return selfPublicKeyPrefix }
    guard let key = try? await dataStore.fetchDevice(radioID: radioID)?.publicKey, key.count >= 4,
          !key.allSatisfy({ $0 == 0 }) else { return nil }
    let prefix = Data(key.prefix(4))
    selfPublicKeyPrefix = prefix
    return prefix
  }

  // MARK: - Events

  /// Returns a fresh stream of room-server events. Registration is
  /// synchronous, so events yielded after this call are never dropped.
  /// Consumers must re-subscribe per connection because the owning
  /// `ServiceContainer` is rebuilt on every connection.
  public nonisolated func events() -> AsyncStream<RoomServerEvent> {
    eventBroadcaster.subscribe()
  }

  /// Ends every `events()` subscriber's for-await loop. Called by
  /// `ServiceContainer.tearDown()` so consumer tasks release the service
  /// references they hold.
  nonisolated func finishEvents() {
    eventBroadcaster.finish()
  }

  // MARK: - Room Management

  /// Join a room server by creating a session and authenticating.
  /// Automatically syncs message history based on local state.
  /// - Parameters:
  ///   - radioID: The companion radio device ID
  ///   - contact: The room server contact
  ///   - password: Authentication password (uses keychain if not provided)
  ///   - rememberPassword: Whether to store password in keychain
  ///   - pathLength: Path length for timeout calculation (0 = direct)
  ///   - onTimeoutKnown: Optional callback invoked with timeout in seconds once firmware responds.
  /// - Returns: The authenticated session
  public func joinRoom(
    radioID: UUID,
    contact: ContactDTO,
    password: String?,
    rememberPassword: Bool = true,
    pathLength: UInt8 = 0,
    onTimeoutKnown: (@Sendable (Int) async -> Void)? = nil
  ) async throws -> RemoteNodeSessionDTO {
    let remoteSession = try await remoteNodeService.createSession(
      radioID: radioID,
      contact: contact
    )

    // Login to the room
    _ = try await remoteNodeService.login(
      sessionID: remoteSession.id,
      password: password,
      pathLength: pathLength,
      onTimeoutKnown: onTimeoutKnown
    )

    // Store password only after successful login. A keychain failure must not turn a
    // successful login into a reported failure; the user just re-enters it next time.
    if let password, rememberPassword {
      do {
        try await remoteNodeService.storePassword(password, forNodeKey: contact.publicKey)
      } catch {
        logger.warning("Logged in, but saving the password failed: \(error.localizedDescription)")
      }
    }

    // Attempt additional history sync if needed (non-blocking)
    await syncHistoryIfPossible(sessionID: remoteSession.id)

    guard let updatedSession = try await dataStore.fetchRemoteNodeSession(id: remoteSession.id) else {
      throw RemoteNodeError.sessionNotFound
    }
    return updatedSession
  }

  /// Reconnect to an existing room session and sync any missed messages.
  /// Use this when re-authenticating to a room after app restart or BLE reconnection.
  /// - Parameters:
  ///   - sessionID: The existing room session ID
  ///   - pathLength: Optional path length hint (0 = use shortest known path)
  /// - Returns: Updated session DTO
  /// - Throws: RemoteNodeError if reconnection fails
  public func reconnectRoom(
    sessionID: UUID,
    pathLength: UInt8 = 0
  ) async throws -> RemoteNodeSessionDTO {
    guard let remoteSession = try await dataStore.fetchRemoteNodeSession(id: sessionID) else {
      throw RemoteNodeError.sessionNotFound
    }

    guard remoteSession.isRoom else {
      throw RemoteNodeError.invalidResponse
    }

    // The session keeps a copy of the room's name: bring it up to date with the room's contact
    // (a nickname or a new advertised name since the session was made).
    if let contact = try? await dataStore.fetchContact(radioID: remoteSession.radioID, publicKeyPrefix: remoteSession.publicKey.prefix(6)),
       contact.publicKey == remoteSession.publicKey,
       !contact.displayName.isEmpty, contact.displayName != remoteSession.name {
      try? await dataStore.updateRemoteNodeSessionName(id: sessionID, name: contact.displayName)
    }

    // Re-authenticate to the room
    _ = try await remoteNodeService.login(
      sessionID: sessionID,
      pathLength: pathLength
    )

    // Attempt additional history sync if needed (non-blocking)
    await syncHistoryIfPossible(sessionID: sessionID)

    guard let updatedSession = try await dataStore.fetchRemoteNodeSession(id: sessionID) else {
      throw RemoteNodeError.sessionNotFound
    }
    return updatedSession
  }

  /// Leave a room by sending logout and removing the session.
  /// - Parameters:
  ///   - sessionID: The session to leave
  ///   - publicKey: The room's public key (for keychain cleanup)
  public func leaveRoom(sessionID: UUID, publicKey: Data) async throws {
    try await remoteNodeService.logout(sessionID: sessionID)
    try await remoteNodeService.removeSession(id: sessionID, publicKey: publicKey)
  }

  // MARK: - Message Posting

  /// Post a message to a room server.
  ///
  /// Posts use `TextType.plain`. The room server converts to `signedPlain`
  /// when pushing to other clients. The server does not push messages back
  /// to their authors, so the local message record is created immediately.
  /// - Parameters:
  ///   - sessionID: The room session
  ///   - text: The message text
  /// - Returns: The saved message DTO
  public func postMessage(sessionID: UUID, text: String) async throws -> RoomMessageDTO {
    guard let remoteSession = try await dataStore.fetchRemoteNodeSession(id: sessionID) else {
      throw RoomServerError.sessionNotFound
    }

    guard remoteSession.canPost else {
      throw RoomServerError.permissionDenied
    }

    let timestamp = Date()
    let messageID = UUID()

    // Create local message record immediately with pending status. The author is this radio's
    // own key prefix and no stored name: an own post is labelled at display time (`isFromSelf`).
    let messageDTO = RoomMessageDTO(
      id: messageID,
      sessionID: sessionID,
      authorKeyPrefix: await selfKeyPrefix() ?? Data(repeating: 0, count: 4),
      authorName: nil,
      text: text,
      timestamp: UInt32(timestamp.timeIntervalSince1970),
      isFromSelf: true,
      status: .pending,
      maxRetryAttempts: config.maxAttempts
    )

    try await dataStore.saveRoomMessage(messageDTO)

    // Log room message posted (metadata only, no content)
    await auditLogger.logRoomMessagePosted(publicKey: remoteSession.publicKey, messageLength: text.count)

    // Send message in background so UI can show pending message immediately
    Task { [weak self] in
      guard let self else { return }

      // Send message with retry logic
      // NOTE: sendMessageWithRetry requires full 32-byte public key for path reset
      do {
        let sentInfo = try await session.sendMessageWithRetry(
          to: remoteSession.publicKey, // Full 32-byte key required
          text: text,
          timestamp: timestamp,
          maxAttempts: config.maxAttempts,
          floodAfter: config.floodAfter,
          maxFloodAttempts: config.maxFloodAttempts
        )

        if let sentInfo {
          // Success - update to delivered
          let ackCodeUInt32 = sentInfo.expectedAck.ackCodeUInt32
          // Handle database errors gracefully - don't lose send success state
          do {
            try await dataStore.updateRoomMessageStatus(
              id: messageID,
              status: .delivered,
              ackCode: ackCodeUInt32,
              roundTripTime: UInt32(sentInfo.suggestedTimeoutMs)
            )
          } catch {
            logger.error("Failed to update message status after successful send: \(error)")
          }
          eventBroadcaster.yield(.statusUpdated(messageID: messageID, status: .delivered))
        } else {
          // All retries exhausted — radio transmitted but no ACK received.
          // Mark as sent (not failed) since the message likely reached the room server.
          do {
            try await dataStore.updateRoomMessageStatus(
              id: messageID,
              status: .sent,
              ackCode: nil,
              roundTripTime: nil
            )
          } catch {
            logger.error("Failed to update message status to sent: \(error)")
          }
          eventBroadcaster.yield(.statusUpdated(messageID: messageID, status: .sent))
        }
        // Update sort date only (no sync bookmark — avoids clock skew issues)
        try? await dataStore.updateRoomActivity(sessionID)
      } catch {
        // Send failed with error — do not update activity
        do {
          try await dataStore.updateRoomMessageStatus(
            id: messageID,
            status: .failed,
            ackCode: nil,
            roundTripTime: nil
          )
        } catch let dbError {
          logger.error("Failed to update message status after send error: \(dbError)")
        }
        eventBroadcaster.yield(.statusUpdated(messageID: messageID, status: .failed))
        logger.warning("Room message send failed: \(error)")
      }
    }

    // Return pending message immediately so UI can display it
    return messageDTO
  }

  /// Retry sending a failed room message.
  /// - Parameter id: The message ID to retry
  /// - Returns: Updated message DTO
  public func retryMessage(id: UUID) async throws -> RoomMessageDTO {
    // Guard against concurrent retries
    guard !inFlightRetries.contains(id) else {
      logger.warning("Retry already in progress for message: \(id)")
      throw RoomServerError.sendFailed("Retry already in progress")
    }

    inFlightRetries.insert(id)
    defer { inFlightRetries.remove(id) }

    guard let message = try await dataStore.fetchRoomMessage(id: id) else {
      throw RoomServerError.sendFailed("Message not found")
    }

    guard message.status == .failed else {
      throw RoomServerError.sendFailed("Message is not in failed state")
    }

    guard let remoteSession = try await dataStore.fetchRemoteNodeSession(id: message.sessionID) else {
      throw RoomServerError.sessionNotFound
    }

    // Update to pending/retrying
    let newRetryAttempt = message.retryAttempt + 1
    try await dataStore.updateRoomMessageRetryStatus(
      id: id,
      status: .pending,
      retryAttempt: newRetryAttempt,
      maxRetryAttempts: config.maxAttempts
    )
    eventBroadcaster.yield(.statusUpdated(messageID: id, status: .pending))

    // Retry send with retry logic
    // NOTE: sendMessageWithRetry requires full 32-byte public key for path reset
    do {
      let sentInfo = try await session.sendMessageWithRetry(
        to: remoteSession.publicKey, // Full 32-byte key required
        text: message.text,
        timestamp: Date(),
        maxAttempts: config.maxAttempts,
        floodAfter: config.floodAfter,
        maxFloodAttempts: config.maxFloodAttempts
      )

      if let sentInfo {
        let ackCodeUInt32 = sentInfo.expectedAck.ackCodeUInt32
        do {
          try await dataStore.updateRoomMessageStatus(
            id: id,
            status: .delivered,
            ackCode: ackCodeUInt32,
            roundTripTime: UInt32(sentInfo.suggestedTimeoutMs)
          )
        } catch {
          logger.error("Failed to update message status after successful retry: \(error)")
        }
        eventBroadcaster.yield(.statusUpdated(messageID: id, status: .delivered))
      } else {
        // All retries exhausted — radio transmitted but no ACK received.
        // Mark as sent (not failed) since the message likely reached the room server.
        do {
          try await dataStore.updateRoomMessageStatus(
            id: id,
            status: .sent,
            ackCode: nil,
            roundTripTime: nil
          )
        } catch {
          logger.error("Failed to update message status to sent: \(error)")
        }
        eventBroadcaster.yield(.statusUpdated(messageID: id, status: .sent))
      }
      // Update sort date so room moves to top of conversation list
      try? await dataStore.updateRoomActivity(message.sessionID)
    } catch {
      do {
        try await dataStore.updateRoomMessageStatus(
          id: id,
          status: .failed,
          ackCode: nil,
          roundTripTime: nil
        )
      } catch let dbError {
        logger.error("Failed to update message status after retry error: \(dbError)")
      }
      eventBroadcaster.yield(.statusUpdated(messageID: id, status: .failed))
      logger.warning("Room message retry failed: \(error)")
    }

    guard let updatedMessage = try await dataStore.fetchRoomMessage(id: id) else {
      throw RoomServerError.sendFailed("Failed to fetch message after retry")
    }
    return updatedMessage
  }

  // MARK: - Incoming Messages

  /// Handle incoming room message.
  /// Called by MessagePollingService when a signedPlain message arrives from a room.
  ///
  /// Messages arrive as `TextType.signedPlain` with the room server's key as
  /// `senderPublicKeyPrefix` and the original author's 4-byte key prefix in
  /// the payload (extracted to `extraData` by `decodeMessageV3`).
  ///
  /// Since room servers don't push messages back to their authors, incoming
  /// messages should not be from self. However, we check defensively.
  /// - Parameters:
  ///   - senderPublicKeyPrefix: The room server's 6-byte key prefix
  ///   - timestamp: Message timestamp from server
  ///   - authorPrefix: The original author's 4-byte key prefix
  ///   - text: The message text
  /// - Returns: The saved message DTO, or nil if the message was a duplicate
  @discardableResult
  public func handleIncomingMessage(
    senderPublicKeyPrefix: Data,
    timestamp: UInt32,
    authorPrefix: Data,
    text: String
  ) async throws -> RoomMessageDTO? {
    guard let remoteSession = try await dataStore.fetchRemoteNodeSessions(radioID: radioID)
      .first(where: { $0.publicKey.prefix(6) == senderPublicKeyPrefix && $0.isRoom }) else {
      // A room keeps pushing to a radio that logged in elsewhere (another app) or left: the
      // stock room server ignores logout. Nothing here to file it under; the room replays its
      // recent posts when the user joins.
      logger.info("Dropping room post from \(senderPublicKeyPrefix.uppercaseHexString()): no room session on this radio")
      return nil
    }

    // Receiving any message (even duplicate) proves session is active
    if !remoteSession.isConnected {
      let recovered = await (try? dataStore.markRoomSessionConnected(remoteSession.id)) ?? false
      if recovered {
        eventBroadcaster.yield(.connectionRecovered(sessionID: remoteSession.id))
      }
    }

    // Generate deduplication key
    let dedupKey = RoomMessage.generateDeduplicationKey(
      timestamp: timestamp,
      authorKeyPrefix: authorPrefix,
      text: text
    )

    // Check for duplicate using deduplication key
    if try await dataStore.isDuplicateRoomMessage(
      sessionID: remoteSession.id,
      deduplicationKey: dedupKey
    ) {
      return nil
    }

    // Log room message received (metadata only, no content)
    await auditLogger.logRoomMessageReceived(
      roomPublicKey: senderPublicKeyPrefix,
      authorPrefix: authorPrefix,
      messageLength: text.count
    )

    // Defensive check: room servers shouldn't push our own messages back
    let isFromSelf = await selfKeyPrefix()?.prefix(4) == authorPrefix.prefix(4)
    if isFromSelf {
      logger.info("Received self message from room server (unexpected)")
    }

    let authorName = isFromSelf ? nil : try await resolveAuthorName(keyPrefix: authorPrefix)

    let messageDTO = RoomMessageDTO(
      sessionID: remoteSession.id,
      authorKeyPrefix: authorPrefix,
      authorName: authorName,
      text: text,
      timestamp: timestamp,
      isFromSelf: isFromSelf
    )

    try await dataStore.saveRoomMessage(messageDTO)

    // Update sync bookmark and sort date
    try await dataStore.updateRoomActivity(remoteSession.id, syncTimestamp: timestamp)

    // Increment unread count if not from self
    if !isFromSelf {
      try await dataStore.incrementRoomUnreadCount(remoteSession.id)
    }

    return messageDTO
  }

  // MARK: - Message Retrieval

  /// Fetch messages for a room session.
  /// - Parameters:
  ///   - sessionID: The room session ID
  ///   - limit: Maximum number of messages to return
  ///   - offset: Offset for pagination
  /// - Returns: Array of room message DTOs
  public func fetchMessages(sessionID: UUID, limit: Int? = nil, offset: Int? = nil) async throws -> [RoomMessageDTO] {
    try await dataStore.fetchRoomMessages(sessionID: sessionID, limit: limit, offset: offset)
  }

  /// Mark room as read (reset unread count).
  /// Call when user views the conversation.
  /// - Parameter sessionID: The room session ID
  public func markAsRead(sessionID: UUID) async throws {
    try await dataStore.resetRoomUnreadCount(sessionID)
  }

  /// Deletes all stored messages for a room and zeroes its unread count. Local
  /// only: the room server keeps its history, and the session's sync position is
  /// left alone so cleared messages are not fetched again.
  /// - Parameter sessionID: The room session ID
  public func clearMessages(sessionID: UUID) async throws {
    try await dataStore.deleteRoomMessages(sessionID: sessionID)
    try await dataStore.resetRoomUnreadCount(sessionID)
  }

  // MARK: - Session Queries

  /// Fetch all room sessions for a device.
  /// - Parameter radioID: The companion radio device ID
  /// - Returns: Array of room session DTOs
  public func fetchRoomSessions(radioID: UUID) async throws -> [RemoteNodeSessionDTO] {
    let sessions = try await dataStore.fetchRemoteNodeSessions(radioID: radioID)
    return sessions.filter(\.isRoom)
  }

  /// Check if a contact is a known room server with an active session.
  /// - Parameter publicKeyPrefix: The 6-byte public key prefix
  /// - Returns: The session if found and connected, nil otherwise
  public func getConnectedSession(publicKeyPrefix: Data) async throws -> RemoteNodeSessionDTO? {
    guard let remoteSession = try await dataStore.fetchRemoteNodeSessions(radioID: radioID)
      .first(where: { $0.publicKey.prefix(6) == publicKeyPrefix && $0.isRoom && $0.isConnected }) else {
      return nil
    }
    return remoteSession
  }

  // MARK: - Private Helpers

  /// The author's name as known when the post arrives, saved as its last known name. The display
  /// re-resolves it from the key prefix every time (`RoomAuthorResolver`), so this only matters
  /// when no contact on the connected radio matches later. One contact on this radio wins; else
  /// a contact saved on another of the user's radios; nil when unknown or ambiguous here.
  private func resolveAuthorName(keyPrefix: Data) async throws -> String? {
    let contacts = try await dataStore.fetchContacts(radioID: radioID)
    let matches = contacts.filter { $0.publicKey.starts(with: keyPrefix) }
    if matches.count == 1 { return matches.first?.displayName }
    if matches.count > 1 { return nil }
    return try await dataStore.findContactNameByKeyPrefix(keyPrefix)
  }

  // MARK: - Own Posts Sent From The Radio

  /// The room session on this radio whose node starts with `publicKeyPrefix`.
  func roomSession(publicKeyPrefix: Data) async throws -> RemoteNodeSessionDTO? {
    let prefix = publicKeyPrefix.prefix(6)
    return try await dataStore.fetchRemoteNodeSessions(radioID: radioID)
      .first { $0.isRoom && $0.publicKey.prefix(6) == prefix }
  }

  /// Files a post the user wrote on a Cairn radio's own screen (the radio echoes it as a DM to
  /// the room, SENT_SYNC.md kind 0) or one its history replays, as the user's own post in that
  /// room. The room server never pushes a post back to its author, so this is the only copy.
  ///
  /// - Returns: The saved post; nil when it is already here (posted from this app, or a second
  ///   copy, in which case a delivered status still upgrades it) or no room session exists for it.
  @discardableResult
  public func storeOwnPost(
    roomPublicKeyPrefix: Data,
    timestamp: UInt32,
    text: String,
    isDelivered: Bool,
    createdAt: Date
  ) async throws -> RoomMessageDTO? {
    guard let remoteSession = try await roomSession(publicKeyPrefix: roomPublicKeyPrefix) else {
      logger.info("Own room post from the radio not stored: no room session on this radio")
      return nil
    }
    let selfPrefix = await selfKeyPrefix() ?? Data(repeating: 0, count: 4)
    if let existing = try await existingOwnPost(sessionID: remoteSession.id, timestamp: timestamp, text: text, selfPrefix: selfPrefix) {
      if isDelivered, existing.status != .delivered {
        try await dataStore.updateRoomMessageStatus(id: existing.id, status: .delivered, ackCode: existing.ackCode, roundTripTime: existing.roundTripTime)
        eventBroadcaster.yield(.statusUpdated(messageID: existing.id, status: .delivered))
      }
      return nil
    }
    let post = RoomMessageDTO(
      sessionID: remoteSession.id,
      authorKeyPrefix: selfPrefix,
      authorName: nil,
      text: text,
      timestamp: timestamp,
      createdAt: createdAt,
      isFromSelf: true,
      status: isDelivered ? .delivered : .sent
    )
    try await dataStore.saveRoomMessage(post)
    // An own post moves the room up the list but is never unread.
    try await dataStore.updateRoomActivity(remoteSession.id)
    return post
  }

  /// Applies a delivered / failed update the radio reports for an own post it sent (SENT_SYNC.md
  /// kind 2), found by room and wire timestamp. Returns the updated post's ID.
  @discardableResult
  public func applyOwnPostStatus(
    roomPublicKeyPrefix: Data,
    timestamp: UInt32,
    status: MessageStatus,
    roundTripTime: UInt32?
  ) async throws -> UUID? {
    guard let remoteSession = try await roomSession(publicKeyPrefix: roomPublicKeyPrefix) else { return nil }
    let posts = try await dataStore.fetchRoomMessages(sessionID: remoteSession.id, limit: nil, offset: nil)
    guard let post = posts.last(where: { $0.isFromSelf && $0.timestamp == timestamp }),
          post.status != .delivered else { return nil }
    try await dataStore.updateRoomMessageStatus(id: post.id, status: status, ackCode: post.ackCode, roundTripTime: roundTripTime)
    eventBroadcaster.yield(.statusUpdated(messageID: post.id, status: status))
    return post.id
  }

  /// An own post with this wire timestamp and text already stored: under this radio's prefix, or
  /// under the all-zero prefix older builds saved when the radio's key wasn't known.
  private func existingOwnPost(sessionID: UUID, timestamp: UInt32, text: String, selfPrefix: Data) async throws -> RoomMessageDTO? {
    let prefixes = [selfPrefix, Data(repeating: 0, count: 4)]
    for prefix in prefixes {
      let key = RoomMessage.generateDeduplicationKey(timestamp: timestamp, authorKeyPrefix: prefix, text: text)
      if try await dataStore.isDuplicateRoomMessage(sessionID: sessionID, deduplicationKey: key) {
        let posts = try await dataStore.fetchRoomMessages(sessionID: sessionID, limit: nil, offset: nil)
        return posts.last { $0.deduplicationKey == key }
      }
    }
    return nil
  }

  /// Attempt to sync history, using advert path first, then falling back to path discovery.
  private func syncHistoryIfPossible(sessionID: UUID) async {
    do {
      guard let remoteSession = try await dataStore.fetchRemoteNodeSession(id: sessionID),
            let contact = try await dataStore.findContactByPublicKey(remoteSession.publicKey) else {
        return
      }

      // Strategy:
      // 1. If contact has a path from advertisement (not flood-routed), try it first
      // 2. If that fails or contact is flood-routed, trigger path discovery
      // 3. Wait for discovery result and retry

      if !contact.isFloodRouted {
        // Contact has a path from advertisement - try it directly
        logger.info("Trying advert path for room \(remoteSession.name)")
        do {
          try await remoteNodeService.requestHistorySync(sessionID: sessionID)
          logger.info("History sync succeeded using advert path")
          return
        } catch {
          // Advert path didn't work - fall through to path discovery
          logger.info("Advert path failed for \(remoteSession.name): \(error), trying path discovery")
        }
      } else {
        logger.info("Room \(remoteSession.name) is flood-routed, attempting path discovery")
      }

      // Path discovery fallback
      let hasDirectRoute = try await discoverPathAndWait(sessionID: sessionID)
      if !hasDirectRoute {
        logger.info("Could not establish direct route for \(remoteSession.name), skipping history sync")
        return
      }

      // Retry with newly discovered path
      try await remoteNodeService.requestHistorySync(sessionID: sessionID)
      logger.info("History sync succeeded after path discovery")
    } catch {
      logger.warning("Failed to sync history for session \(sessionID): \(error)")
      // Don't fail the join - messages will arrive via normal flow
    }
  }

  /// Discover path and wait for direct route.
  private func discoverPathAndWait(sessionID: UUID, timeout: Duration = .seconds(10)) async throws -> Bool {
    guard let remoteSession = try await dataStore.fetchRemoteNodeSession(id: sessionID),
          let contact = try await dataStore.findContactByPublicKey(remoteSession.publicKey) else {
      return false
    }

    // Already direct?
    if !contact.isFloodRouted {
      return true
    }

    // Trigger path discovery via MeshCore session
    do {
      _ = try await session.sendPathDiscovery(to: remoteSession.publicKey)
    } catch {
      logger.warning("Path discovery send failed: \(error)")
      return false
    }

    // Wait for result
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(500))

      if let updated = try await dataStore.findContactByPublicKey(remoteSession.publicKey),
         !updated.isFloodRouted {
        return true
      }
    }

    return false
  }
}
