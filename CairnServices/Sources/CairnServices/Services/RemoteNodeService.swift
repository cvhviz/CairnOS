import Foundation
import MeshCore
import os

// MARK: - CLI Response Text Type

/// Wire value `0x01` — firmware `TXT_TYPE_CLI_DATA`.
/// `ContactMessage.textType` is a raw byte on the MeshCore side, so we keep
/// the constant as a `UInt8` rather than routing through a Swift enum.
private let cliResponseTextType: UInt8 = 0x01

// MARK: - Remote Node Service

/// Shared service for remote node operations.
/// Handles login, keep-alive, status, telemetry, and CLI for both room servers and repeaters.
public actor RemoteNodeService {
  // MARK: - Properties

  let session: any RemoteAccessSessionOps & SessionEventStreaming & ContactSessionOps
  let dataStore: any PersistenceStoreProtocol
  let keychainService: KeychainService
  let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "RemoteNode")
  let auditLogger = CommandAuditLogger()

  struct PendingLogin {
    /// Session that called `login`, so a prefix match cannot update another radio's row.
    let sessionID: UUID
    let continuation: CheckedContinuation<LoginResult, Error>
  }

  /// Pending login continuations keyed by 6-byte public key prefix.
  /// Using 6-byte prefix matches MeshCore protocol format for login results.
  var pendingLogins: [Data: PendingLogin] = [:]

  /// Timeout tasks for pending logins, keyed by 6-byte public key prefix.
  /// Cancelled when login succeeds/fails before timeout.
  var pendingLoginTimeoutTasks: [Data: Task<Void, Never>] = [:]

  /// The in-flight CLI request for a node. `acceptsAnyResponse` marks raw
  /// passthrough commands whose reply shape can't be validated. `wirePrefix`
  /// is the correlation token prepended to the command on the wire; firmware
  /// reflects it back at the start of the reply. `requiresEcho` marks another
  /// companion's command line, whose firmware always reflects the tag: only a
  /// reply carrying exactly that tag resolves it.
  struct PendingCLIRequest {
    let id: UUID
    let command: String
    let wirePrefix: String
    let acceptsAnyResponse: Bool
    var requiresEcho = false
    let continuation: CheckedContinuation<String, Error>
  }

  /// The single in-flight CLI request per node, keyed by 6-byte public key
  /// prefix. Replies echoing the request's wire prefix are attributed
  /// deterministically; unprefixed replies (firmware that predates the echo)
  /// fall back to single-flight shape validation, and foreign-prefixed
  /// replies are stale by definition and dropped.
  var pendingCLIRequests: [Data: PendingCLIRequest] = [:]

  /// Cycling counter for CLI wire prefixes ("00|" through "FF|"). Seeded at random per
  /// service (one per connection), so a reply still in the mesh from an earlier connection is
  /// unlikely to carry the tag of this connection's first commands.
  var cliPrefixCounter: UInt8

  /// A companion command that timed out, still listening for its reply
  /// (``companionCLILateReplies()``), as the firmware keeps its sent tags.
  struct LateCLIWatch {
    let requestID: UUID
    let tag: String
    let command: String
    let until: ContinuousClock.Instant
  }

  /// Timed-out companion commands per node (6-byte prefix) whose late reply is still shown.
  var lateCLIWatches: [Data: [LateCLIWatch]] = [:]

  /// How long after its timeout a companion command's reply is still taken as late.
  static let companionCLILateWindow: Duration = .seconds(60)

  /// The last CLI command sent to a node, already redacted, kept so the audit
  /// log can withhold the reply to a command that carries or requests a secret.
  struct CLIAuditEntry {
    let redactedCommand: String
    let isSensitive: Bool
    let sentAt: ContinuousClock.Instant
  }

  /// Audit entries keyed by 6-byte public key prefix.
  var cliAuditEntries: [Data: CLIAuditEntry] = [:]

  /// How long a sensitive command keeps owning a node's replies after a later
  /// command goes out. Its reply, or the duplicate from a flood resend, can
  /// arrive after the next command was sent.
  static let sensitiveCLIAuditWindow: Duration = .seconds(30)

  /// A task queued for a node's CLI slot while another command is in flight.
  struct CLISlotWaiter {
    let id: UUID
    /// A user's command, which goes ahead of background ones (`RemoteRequestPriority`).
    let isUser: Bool
    let continuation: CheckedContinuation<Void, Error>
  }

  /// Nodes whose CLI slot is held by an in-flight command.
  var cliSlotBusy: Set<Data> = []

  /// Waiters for a node's CLI slot, keyed by 6-byte public key prefix: user commands first, each
  /// group in arrival order.
  var cliSlotWaiters: [Data: [CLISlotWaiter]] = [:]

  /// User requests waiting or in flight per node (6-byte prefix); background requests to that
  /// node hold off while any are (`yieldToUserActions`).
  var userActionCounts: [Data: Int] = [:]

  /// Keep-alive timer tasks
  var keepAliveTasks: [UUID: Task<Void, Never>] = [:]

  /// Keep-alive intervals per session (from login response, in seconds)
  /// Default to 90 seconds if not specified
  var keepAliveIntervals: [UUID: Duration] = [:]
  static let defaultKeepAliveInterval: Duration = .seconds(90)

  /// Reentrancy guard for BLE reconnection handling
  var isReauthenticating = false

  /// Event monitoring task
  private var eventMonitorTask: Task<Void, Never>?

  // MARK: - Handlers

  /// Handler for keep-alive ACK responses
  /// Called when ACK with unsynced count is received.
  /// Nothing assigns or reads this property today.
  public var keepAliveResponseHandler: (@Sendable (UUID, Int) async -> Void)?

  // MARK: - Events

  /// Multicast broadcaster for session connection-state events.
  nonisolated let eventBroadcaster = EventBroadcaster<RemoteNodeEvent>()

  /// Returns a fresh stream of remote-node session events. Registration is
  /// synchronous, so events yielded after this call are never dropped.
  /// Consumers must re-subscribe per connection because the owning
  /// `ServiceContainer` is rebuilt on every connection.
  public nonisolated func events() -> AsyncStream<RemoteNodeEvent> {
    eventBroadcaster.subscribe()
  }

  /// Ends every `events()` subscriber's for-await loop. Called by
  /// `ServiceContainer.tearDown()` so consumer tasks release the service
  /// references they hold.
  nonisolated func finishEvents() {
    eventBroadcaster.finish()
    lateCLIReplyBroadcaster.finish()
  }

  /// Multicast broadcaster for companion CLI replies that came after their command timed out.
  nonisolated let lateCLIReplyBroadcaster = EventBroadcaster<CompanionCLILateReply>()

  /// Replies to companion commands (``sendCompanionCLICommand(publicKey:command:timeout:requestID:)``)
  /// that came after the command had timed out, up to ``companionCLILateWindow`` later. A terminal
  /// shows one under its command, as the firmware's Remote commands page shows a LATE line:
  /// silence was not a refusal, and a `set` may have applied.
  public nonisolated func companionCLILateReplies() -> AsyncStream<CompanionCLILateReply> {
    lateCLIReplyBroadcaster.subscribe(bufferingPolicy: .bufferingNewest(16))
  }

  // MARK: - Initialization

  /// - Parameter cliPrefixSeed: The first CLI wire tag's sequence number; random unless a
  ///   test needs a known one.
  init(
    session: any RemoteAccessSessionOps & SessionEventStreaming & ContactSessionOps,
    dataStore: any PersistenceStoreProtocol,
    keychainService: KeychainService,
    cliPrefixSeed: UInt8 = .random(in: .min ... .max)
  ) {
    self.session = session
    self.dataStore = dataStore
    self.keychainService = keychainService
    self.cliPrefixCounter = cliPrefixSeed
  }

  deinit {
    eventMonitorTask?.cancel()
    for task in keepAliveTasks.values {
      task.cancel()
    }
  }

  // MARK: - Event Monitoring

  /// Start monitoring MeshCore events for login results
  public func startEventMonitoring() {
    eventMonitorTask?.cancel()

    eventMonitorTask = Task { [weak self] in
      guard let self else { return }
      let filter = EventFilter { event in
        switch event {
        case .loginSuccess, .loginFailed:
          true
        case let .contactMessageReceived(info) where info.textType == cliResponseTextType:
          true
        case .statusResponse, .telemetryResponse, .neighboursResponse, .binaryResponse:
          true
        default:
          false
        }
      }
      let events = await session.events(filter: filter)

      for await event in events {
        guard !Task.isCancelled else { break }
        await handleEvent(event)
      }
    }
  }

  /// Stop monitoring events
  public func stopEventMonitoring() {
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
  }

  /// Handle incoming MeshCore event
  private func handleEvent(_ event: MeshEvent) async {
    switch event {
    case let .loginSuccess(info):
      let prefixHex = info.publicKeyPrefix.map { String(format: "%02x", $0) }.joined()
      logger.info("loginSuccess received for prefix \(prefixHex)")
      let result = LoginResult(
        success: true,
        isAdmin: info.isAdmin,
        aclPermissions: info.permissions,
        publicKeyPrefix: info.publicKeyPrefix,
        serverTime: info.serverTime
      )
      await handleLoginResult(result, fromPublicKeyPrefix: info.publicKeyPrefix)

    case let .loginFailed(publicKeyPrefix):
      if let prefix = publicKeyPrefix {
        let result = LoginResult(
          success: false,
          isAdmin: false,
          aclPermissions: nil,
          publicKeyPrefix: prefix
        )
        await handleLoginResult(result, fromPublicKeyPrefix: prefix)
      }

    case let .contactMessageReceived(message):
      if message.textType == cliResponseTextType {
        handleCLIResponse(message)
      }

    default:
      break
    }
  }

  /// Handle CLI response from a contact message. The wire prefix echoed by
  /// firmware attributes a reply deterministically; an unprefixed reply falls
  /// back to single-flight shape validation for older firmware, and a reply
  /// echoing a different prefix belongs to an earlier command and is dropped.
  private func handleCLIResponse(_ message: ContactMessage) {
    let prefix = Data(message.senderPublicKeyPrefix.prefix(6))

    guard let pending = pendingCLIRequests[prefix] else {
      if takeLateCLIReply(message, from: prefix) { return }
      logger.debug("Unmatched CLI response (no pending request): len=\(message.text.count)")
      return
    }

    let responseText: String
    if pending.requiresEcho {
      // Another companion: an untagged reply (a 1.17 answer, "Unknown command" to a
      // command too short to tag) or a foreign tag (a Cairn radio's own `^x|`, a
      // late reply to an earlier command) is never this command's.
      guard CompanionCLITag.matches(message.text, tag: pending.wirePrefix) else {
        if takeLateCLIReply(message, from: prefix) { return }
        logger.warning(
          "Dropping companion CLI reply that doesn't carry \(pending.wirePrefix): len=\(message.text.count)"
        )
        return
      }
      responseText = CompanionCLITag.body(of: message.text)
    } else if let echoed = CLIResponse.splitEchoedPrefix(message.text) {
      guard echoed.prefix == pending.wirePrefix else {
        logger.warning(
          "Dropping stale CLI response with prefix \(echoed.prefix) while awaiting \(pending.wirePrefix)"
        )
        return
      }
      responseText = echoed.body
    } else {
      // Firmware without prefix echo: fall back to shape validation.
      guard pending.acceptsAnyResponse
        || CLIResponse.isPlausibleResponse(message.text, forQuery: pending.command) else {
        logger.warning(
          "Dropping CLI response that doesn't match pending '\(LogRedaction.cliCommand(pending.command))': len=\(message.text.count)"
        )
        return
      }
      responseText = message.text
    }

    pendingCLIRequests[prefix] = nil
    pending.continuation.resume(returning: responseText)
  }

  /// Takes a reply to a companion command that already timed out, if it carries the tag of one
  /// still in ``lateCLIWatches``, and passes it on as ``CompanionCLILateReply``.
  private func takeLateCLIReply(_ message: ContactMessage, from prefix: Data) -> Bool {
    let now = ContinuousClock.now
    var watches = lateCLIWatches[prefix, default: []].filter { $0.until > now }
    defer { lateCLIWatches[prefix] = watches.isEmpty ? nil : watches }
    guard let index = watches.firstIndex(where: { CompanionCLITag.matches(message.text, tag: $0.tag) }) else {
      return false
    }
    let watch = watches.remove(at: index)
    logger.info("Late companion CLI reply for \(watch.tag): len=\(message.text.count)")
    lateCLIReplyBroadcaster.yield(CompanionCLILateReply(
      requestID: watch.requestID,
      publicKeyPrefix: prefix,
      command: watch.command,
      text: CompanionCLITag.body(of: message.text)
    ))
    return true
  }

  /// Keeps listening for a timed-out companion command's reply for ``companionCLILateWindow``.
  func watchForLateCLIReply(prefix: Data, requestID: UUID, tag: String, command: String) {
    let now = ContinuousClock.now
    var watches = lateCLIWatches[prefix, default: []].filter { $0.until > now }
    watches.append(LateCLIWatch(
      requestID: requestID,
      tag: tag,
      command: command,
      until: now.advanced(by: Self.companionCLILateWindow)
    ))
    lateCLIWatches[prefix] = watches
  }

  /// Returns the next cycling CLI wire prefix ("00|" through "FF|").
  func makeCLIWirePrefix() -> String {
    defer { cliPrefixCounter &+= 1 }
    return CompanionCLITag.make(sequence: cliPrefixCounter)
  }

  func timeInterval(for duration: Duration) -> TimeInterval {
    let (seconds, attoseconds) = duration.components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }

  func cancelPendingLogin(for prefix: Data) {
    pendingLoginTimeoutTasks.removeValue(forKey: prefix)?.cancel()
    if let pending = pendingLogins.removeValue(forKey: prefix) {
      pending.continuation.resume(throwing: RemoteNodeError.cancelled)
    }
  }

  func cancelPendingCLIRequest(for prefix: Data, requestID: UUID) {
    guard let cancelled = takePendingCLIRequest(for: prefix, requestID: requestID) else { return }
    cancelled.continuation.resume(throwing: CancellationError())
  }

  // MARK: - Session Management

  /// Create a session DTO for a contact, optionally preserving data from an existing session.
  private func makeSessionDTO(
    radioID: UUID,
    contact: ContactDTO,
    role: RemoteNodeRole,
    preserving existing: RemoteNodeSessionDTO? = nil
  ) -> RemoteNodeSessionDTO {
    RemoteNodeSessionDTO(
      id: existing?.id ?? UUID(),
      radioID: radioID,
      publicKey: contact.publicKey,
      name: contact.displayName,
      role: role,
      latitude: contact.latitude,
      longitude: contact.longitude,
      isConnected: false,
      permissionLevel: existing?.permissionLevel ?? .guest,
      lastConnectedDate: existing?.lastConnectedDate,
      lastBatteryMillivolts: existing?.lastBatteryMillivolts,
      lastUptimeSeconds: existing?.lastUptimeSeconds,
      lastNoiseFloor: existing?.lastNoiseFloor,
      unreadCount: existing?.unreadCount ?? 0,
      notificationLevel: existing?.notificationLevel ?? .all,
      isFavorite: existing?.isFavorite ?? false,
      lastRxAirtimeSeconds: existing?.lastRxAirtimeSeconds,
      neighborCount: existing?.neighborCount ?? 0,
      lastSyncTimestamp: existing?.lastSyncTimestamp ?? 0,
      lastMessageDate: existing?.lastMessageDate
    )
  }

  /// Create a new session for a remote node.
  public func createSession(
    radioID: UUID,
    contact: ContactDTO
  ) async throws -> RemoteNodeSessionDTO {
    guard let role = RemoteNodeRole(contactType: contact.type) else {
      throw RemoteNodeError.invalidResponse
    }

    guard contact.publicKey.count == ProtocolLimits.publicKeySize else {
      throw RemoteNodeError.loginFailed("Invalid public key length: expected \(ProtocolLimits.publicKeySize) bytes, got \(contact.publicKey.count)")
    }

    let pubKeyHex = contact.publicKey.prefix(6).map { String(format: "%02x", $0) }.joined()

    let existing = try await dataStore.fetchRemoteNodeSessions(radioID: radioID)
      .first { $0.publicKey == contact.publicKey }

    if let existing {
      logger.info("createSession: reusing existing session \(existing.id) for \(pubKeyHex), isConnected=\(existing.isConnected)")
    } else {
      logger.info("createSession: creating new session for \(pubKeyHex)")
    }

    let dto = makeSessionDTO(radioID: radioID, contact: contact, role: role, preserving: existing)

    try await dataStore.saveRemoteNodeSessionDTO(dto)

    try await dataStore.cleanupDuplicateRemoteNodeSessions(publicKey: contact.publicKey, keepID: dto.id)

    guard let saved = try await dataStore.fetchRemoteNodeSession(id: dto.id) else {
      logger.error("createSession: failed to fetch saved session for \(pubKeyHex)")
      throw RemoteNodeError.sessionNotFound
    }

    logger.info("createSession: saved session \(saved.id) for \(pubKeyHex)")
    return saved
  }

  /// Remove a session and its associated data
  public func removeSession(id: UUID, publicKey: Data) async throws {
    stopKeepAlive(sessionID: id)
    try await keychainService.deletePassword(forNodeKey: publicKey)
    try await dataStore.deleteRemoteNodeSession(id: id)
  }

  /// Check if a password is stored for a contact's public key.
  public func hasPassword(forContact contact: ContactDTO) async -> Bool {
    await keychainService.hasPassword(forNodeKey: contact.publicKey)
  }

  /// Retrieve the stored password for a contact's public key.
  public func retrievePassword(forContact contact: ContactDTO) async -> String? {
    try? await keychainService.retrievePassword(forNodeKey: contact.publicKey)
  }

  /// Store a password for a remote node.
  /// Call this after successful login to save correct passwords only.
  public func storePassword(_ password: String, forNodeKey publicKey: Data) async throws {
    try await keychainService.storePassword(password, forNodeKey: publicKey)
  }

  /// Delete the stored password for a contact's public key.
  public func deletePassword(forContact contact: ContactDTO) async throws {
    try await keychainService.deletePassword(forNodeKey: contact.publicKey)
  }

  // MARK: - Disconnect

  /// Mark session as disconnected without sending logout.
  public func disconnect(sessionID: UUID) async {
    stopKeepAlive(sessionID: sessionID)
    do {
      try await dataStore.markSessionDisconnected(sessionID)
    } catch {
      logger.error("Failed to persist disconnected state for session \(sessionID): \(error)")
    }

    // Notify UI of session state change
    eventBroadcaster.yield(.sessionStateChanged(sessionID: sessionID, isConnected: false))
  }

  // MARK: - Cleanup

  /// Stop all keep-alive timers and resume any parked login continuations (call on app termination)
  public func stopAllKeepAlives() {
    for task in keepAliveTasks.values {
      task.cancel()
    }
    keepAliveTasks.removeAll()

    // Resume parked logins before dropping their timeout tasks; otherwise the
    // continuation that would have resumed them is gone and the caller hangs.
    for prefix in Array(pendingLogins.keys) {
      cancelPendingLogin(for: prefix)
    }
  }

  /// Number of login continuations currently parked. Exposed for teardown tests.
  var pendingLoginCount: Int {
    pendingLogins.count
  }
}
