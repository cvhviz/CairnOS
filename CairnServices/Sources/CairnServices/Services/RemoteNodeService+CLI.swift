import Foundation
import MeshCore

extension RemoteNodeService {
  // MARK: - CLI Commands

  /// Send a CLI command to a remote node and wait for its response (admin only).
  /// Replies to structured `get` queries must parse to their expected shape;
  /// anything else waiting in the mesh is dropped instead of misattributed.
  /// - Parameters:
  ///   - sessionID: The remote node session ID.
  ///   - command: The CLI command to send.
  ///   - timeout: Hard maximum time to wait for response (default 10 seconds).
  /// - Returns: The CLI response text from the remote node.
  public func sendCLICommand(
    sessionID: UUID,
    command: String,
    timeout: Duration = .seconds(10)
  ) async throws -> String {
    try await performCLICommand(
      sessionID: sessionID,
      command: command,
      timeout: timeout,
      acceptsAnyResponse: false
    )
  }

  /// Send a raw CLI command to a remote node (admin only). The next reply from
  /// the node is delivered verbatim without shape validation. Used by CLI
  /// terminals and commands whose reply format is free-form.
  /// - Parameters:
  ///   - sessionID: The remote node session ID.
  ///   - command: The CLI command to send.
  ///   - timeout: Hard maximum time to wait for response (default 10 seconds).
  /// - Returns: The raw response text from the remote node.
  public func sendRawCLICommand(
    sessionID: UUID,
    command: String,
    timeout: Duration = .seconds(10)
  ) async throws -> String {
    let response = try await performCLICommand(
      sessionID: sessionID,
      command: command,
      timeout: timeout,
      acceptsAnyResponse: true
    )

    // Clear stored password after admin password change
    await handlePasswordChangeIfNeeded(command: command, sessionID: sessionID)

    return response
  }

  /// Send a command to another companion's own command line (MeshCore 1.18) and wait
  /// for its reply. No login: the other device runs it only when its contact for this
  /// radio allows remote commands (contact flag 0x10), so silence (not allowed there,
  /// out of range, older firmware there) is a timeout. A timeout is never resent and
  /// never resets the path, since a resend could repeat a `set`.
  ///
  /// The command is cleaned first (``CompanionCLICatalog/clean(_:)``) and goes with a
  /// hex tag; only a reply carrying that tag resolves it. A restart
  /// (``CompanionCLICatalog/restarts(_:)``) waits only the short
  /// ``RemoteOperationTimeoutPolicy/fireAndForgetCLI`` window: a Cairn device answers
  /// "OK - restarting", stock firmware restarts before it answers, so a timeout then
  /// means sent.
  /// - Parameters:
  ///   - publicKey: The other companion's public key (6+ bytes; the first 6 address it).
  ///   - command: The command as typed.
  ///   - timeout: Least time to wait; the firmware's own deadline for the route wins
  ///     when longer, up to 40 s.
  ///   - requestID: Names this command in ``companionCLILateReplies()``: after a timeout its
  ///     reply is still taken for ``companionCLILateWindow`` and comes there with this ID.
  /// - Returns: The reply without its tag, possibly empty. The CLI's own "> " lead is
  ///   kept (``CompanionCLITag/displayText(_:)`` drops it).
  /// - Throws: `RemoteNodeError.sendFailed` for a command that can't be sent,
  ///   `RemoteNodeError.timeout` when no reply came, or `RemoteNodeError.sessionError`
  ///   when the radio refused it (``RemoteNodeError/isUnsupportedByRadio`` before 1.18).
  public func sendCompanionCLICommand(
    publicKey: Data,
    command: String,
    timeout: Duration = RemoteOperationTimeoutPolicy.companionCLIMinimum,
    requestID: UUID = UUID()
  ) async throws -> String {
    guard publicKey.count >= 6 else {
      throw RemoteNodeError.sendFailed("Invalid public key length: \(publicKey.count) bytes")
    }
    guard let cleaned = CompanionCLICatalog.clean(command) else {
      throw RemoteNodeError.sendFailed("Not a command that can be sent")
    }

    await auditLogger.logCLICommand(publicKey: publicKey, command: cleaned)

    let destinationPrefix = Data(publicKey.prefix(6))
    recordCLICommandForAudit(cleaned, prefix: destinationPrefix)

    let isUser = RemoteRequestPriority.current == .user
    if isUser {
      beginUserAction(for: destinationPrefix)
    } else {
      await yieldToUserActions(publicKey: publicKey)
    }
    defer { if isUser { endUserAction(for: destinationPrefix) } }

    try await acquireCLISlot(for: destinationPrefix, waiterID: requestID, isUser: isUser)
    defer { releaseCLISlot(for: destinationPrefix) }

    return try await performCLIExchange(
      publicKey: publicKey,
      destinationPrefix: destinationPrefix,
      command: cleaned,
      acceptsAnyResponse: true,
      timeout: timeout,
      requestID: requestID,
      target: CompanionCLICatalog.restarts(cleaned) ? .companionRestart : .companion
    )
  }

  /// Shared send path: acquires the node's CLI slot so exactly one command is
  /// in flight per node, then performs the exchange.
  private func performCLICommand(
    sessionID: UUID,
    command: String,
    timeout: Duration,
    acceptsAnyResponse: Bool
  ) async throws -> String {
    guard let remoteSession = try await dataStore.fetchRemoteNodeSession(id: sessionID) else {
      throw RemoteNodeError.sessionNotFound
    }

    guard remoteSession.isAdmin else {
      throw RemoteNodeError.permissionDenied
    }

    // `clock sync` is rewritten to `time <epoch>` at the send (performCLIExchange), not here:
    // the command may wait its turn behind others, and the firmware refuses a time earlier
    // than its own clock, so a timestamp taken now would be stale by then. It is stamped ahead
    // by the route's delay (`clockSyncLead`), worked out once the slot is ours.

    // Log CLI command (with password redaction)
    await auditLogger.logCLICommand(publicKey: remoteSession.publicKey, command: command)

    let destinationPrefix = Data(remoteSession.publicKey.prefix(6))
    recordCLICommandForAudit(command, prefix: destinationPrefix)
    let requestID = UUID()

    let isUser = RemoteRequestPriority.current == .user
    if isUser {
      beginUserAction(for: destinationPrefix)
    } else {
      await yieldToUserActions(publicKey: remoteSession.publicKey)
    }
    defer { if isUser { endUserAction(for: destinationPrefix) } }

    try await acquireCLISlot(for: destinationPrefix, waiterID: requestID, isUser: isUser)
    defer { releaseCLISlot(for: destinationPrefix) }

    // Reboot has no reply; path-reset+resend would fire a second reboot. A clock sync whose reply
    // was lost has most likely set the clock already, and a resend would be refused as going
    // backwards, so its timeout goes to the caller as it is.
    let isClockSync = RemoteCLICommandRewriter.isClockSync(command)
    if Self.isFireAndForgetCLI(command) || isClockSync {
      let clockLead = isClockSync
        ? await clockSyncLead(radioID: remoteSession.radioID, publicKey: remoteSession.publicKey)
        : 0
      return try await performCLIExchange(
        publicKey: remoteSession.publicKey,
        destinationPrefix: destinationPrefix,
        command: command,
        acceptsAnyResponse: acceptsAnyResponse,
        timeout: timeout,
        requestID: requestID,
        clockLead: clockLead
      )
    }

    return try await performWithDirectPathFloodRecovery(
      radioID: remoteSession.radioID,
      publicKey: remoteSession.publicKey,
      operationName: "remoteCLI"
    ) {
      try await self.performCLIExchange(
        publicKey: remoteSession.publicKey,
        destinationPrefix: destinationPrefix,
        command: command,
        acceptsAnyResponse: acceptsAnyResponse,
        timeout: timeout,
        requestID: requestID
      )
    }
  }

  /// Commands that intentionally get no reply (or treat timeout as success).
  private static func isFireAndForgetCLI(_ command: String) -> Bool {
    let lower = command.lowercased().trimmingCharacters(in: .whitespaces)
    return lower == "reboot" || lower.hasPrefix("reboot ")
  }

  /// How far ahead to stamp a clock sync for the node's current route
  /// (``RemoteCLICommandRewriter/clockSyncLead(pathHopCount:)``): flood when the contact is unknown.
  private func clockSyncLead(radioID: UUID, publicKey: Data) async -> TimeInterval {
    let contact = try? await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)
    let hops = contact.flatMap { $0.isFloodRouted ? nil : $0.pathHopCount }
    return RemoteCLICommandRewriter.clockSyncLead(pathHopCount: hops)
  }

  /// Who answers a CLI exchange, which decides the frame, the reply matching and the wait.
  enum CLIExchangeTarget {
    /// A repeater or room server (`TXT_TYPE_CLI_DATA`, login required).
    case node
    /// Another companion's command line (`TXT_TYPE_CLI_COMMAND`, MeshCore 1.18).
    case companion
    /// A companion command that restarts it: the short fire-and-forget wait.
    case companionRestart
  }

  /// Register the pending request, send the command, and poll the device for
  /// the reply until it arrives or the effective timeout elapses.
  private func performCLIExchange(
    publicKey: Data,
    destinationPrefix: Data,
    command: String,
    acceptsAnyResponse: Bool,
    timeout: Duration,
    requestID: UUID,
    target: CLIExchangeTarget = .node,
    clockLead: TimeInterval = 0
  ) async throws -> String {
    let wirePrefix = makeCLIWirePrefix()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pendingCLIRequests[destinationPrefix] = PendingCLIRequest(
          id: requestID,
          command: command,
          wirePrefix: wirePrefix,
          acceptsAnyResponse: acceptsAnyResponse,
          requiresEcho: target != .node,
          continuation: continuation
        )

        Task { [self] in
          let sentInfo: MessageSentInfo
          do {
            switch target {
            case .node:
              // Stamped as it goes out, ahead by the route's delay, so it lands on the phone's time.
              let wireCommand = RemoteCLICommandRewriter.rewrite(command, lead: clockLead)
              sentInfo = try await session.sendCommand(to: publicKey, command: wirePrefix + wireCommand)
            case .companion, .companionRestart:
              sentInfo = try await session.sendCompanionCommand(to: publicKey, command: wirePrefix + command)
            }
          } catch {
            if let failed = takePendingCLIRequest(for: destinationPrefix, requestID: requestID) {
              let meshError = error as? MeshCoreError ?? MeshCoreError.connectionLost(underlying: error)
              failed.continuation.resume(throwing: RemoteNodeError.sessionError(meshError))
            }
            return
          }

          let effectiveTimeout = switch target {
          case .node:
            RemoteOperationTimeoutPolicy.cliTimeout(for: sentInfo, requestedTimeout: timeout)
          case .companion:
            RemoteOperationTimeoutPolicy.companionCLITimeout(for: sentInfo, requestedTimeout: timeout)
          case .companionRestart:
            RemoteOperationTimeoutPolicy.fireAndForgetCLI
          }
          let deadline = ContinuousClock.now.advanced(by: effectiveTimeout)
          while ContinuousClock.now < deadline {
            guard pendingCLIRequests[destinationPrefix]?.id == requestID else {
              return // Request was resumed by handleCLIResponse or cancelled
            }

            let pollStart = ContinuousClock.now
            let remaining = deadline - pollStart
            let pollDuration = min(RemoteOperationTimeoutPolicy.pollInterval, remaining)
            let result = try? await session.getMessage(timeout: max(0.1, timeInterval(for: pollDuration)))

            // A fetched message means the queue may hold more, so keep draining.
            // An empty queue or a failed send returns at once; wait out the rest
            // of the interval instead of issuing back-to-back requests.
            switch result {
            case .contactMessage, .channelMessage, .channelDatagram, .radioSentMessage:
              continue
            case .noMoreMessages, nil:
              break
            }
            let unused = pollDuration - (ContinuousClock.now - pollStart)
            guard unused > .zero else { continue }
            do {
              try await Task.sleep(for: unused)
            } catch {
              break
            }
          }

          if let timedOut = takePendingCLIRequest(for: destinationPrefix, requestID: requestID) {
            if target != .node {
              // Silence from a companion is not a refusal: its reply may still come.
              watchForLateCLIReply(
                prefix: destinationPrefix,
                requestID: requestID,
                tag: wirePrefix,
                command: command
              )
            }
            timedOut.continuation.resume(throwing: RemoteNodeError.timeout)
          }
        }
      }
    } onCancel: { [weak self] in
      Task { [weak self] in
        await self?.cancelPendingCLIRequest(for: destinationPrefix, requestID: requestID)
      }
    }
  }

  /// Remember the command a node's next replies answer, for the audit log.
  private func recordCLICommandForAudit(_ command: String, prefix: Data) {
    let now = ContinuousClock.now
    let isSensitive = LogRedaction.isSensitiveCLICommand(command)
    if !isSensitive, let previous = cliAuditEntries[prefix], previous.isSensitive,
       now - previous.sentAt < Self.sensitiveCLIAuditWindow {
      return
    }
    cliAuditEntries[prefix] = CLIAuditEntry(
      redactedCommand: LogRedaction.cliCommand(command),
      isSensitive: isSensitive,
      sentAt: now
    )
  }

  /// The redacted command the audit log should attribute a node's CLI reply to,
  /// or nil when no command has been sent to it on this connection.
  func cliCommandForAudit(publicKey: Data) -> String? {
    cliAuditEntries[Data(publicKey.prefix(6))]?.redactedCommand
  }

  /// Remove and return the pending request if it is still the given one.
  func takePendingCLIRequest(for prefix: Data, requestID: UUID) -> PendingCLIRequest? {
    guard let pending = pendingCLIRequests[prefix], pending.id == requestID else { return nil }
    pendingCLIRequests[prefix] = nil
    return pending
  }

  // MARK: - CLI Slot

  /// Wait for the node's CLI slot (FIFO). Throws `CancellationError` if the
  /// calling task is cancelled while waiting.
  private func acquireCLISlot(for prefix: Data, waiterID: UUID, isUser: Bool) async throws {
    guard cliSlotBusy.contains(prefix) else {
      cliSlotBusy.insert(prefix)
      return
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let waiter = CLISlotWaiter(id: waiterID, isUser: isUser, continuation: continuation)
        var waiters = cliSlotWaiters[prefix, default: []]
        // A user's command joins the end of the user commands, ahead of every background one.
        if isUser, let firstBackground = waiters.firstIndex(where: { !$0.isUser }) {
          waiters.insert(waiter, at: firstBackground)
        } else {
          waiters.append(waiter)
        }
        cliSlotWaiters[prefix] = waiters
      }
    } onCancel: { [weak self] in
      Task { [weak self] in
        await self?.cancelCLISlotWaiter(for: prefix, waiterID: waiterID)
      }
    }
  }

  /// Hand the slot to the next waiter, or free it when none are queued.
  private func releaseCLISlot(for prefix: Data) {
    if var waiters = cliSlotWaiters[prefix], !waiters.isEmpty {
      let next = waiters.removeFirst()
      cliSlotWaiters[prefix] = waiters.isEmpty ? nil : waiters
      next.continuation.resume()
    } else {
      cliSlotBusy.remove(prefix)
    }
  }

  /// Cancel a queued slot waiter when its calling task is cancelled.
  private func cancelCLISlotWaiter(for prefix: Data, waiterID: UUID) {
    guard var waiters = cliSlotWaiters[prefix],
          let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
      return
    }

    let cancelled = waiters.remove(at: index)
    cliSlotWaiters[prefix] = waiters.isEmpty ? nil : waiters
    cancelled.continuation.resume(throwing: CancellationError())
  }

  /// Clear stored password if command is an admin password change.
  private func handlePasswordChangeIfNeeded(command: String, sessionID: UUID) async {
    let lower = command.lowercased().trimmingCharacters(in: .whitespaces)

    // Only admin password changes, not guest
    guard lower.hasPrefix("password "), !lower.contains("guest.password") else {
      return
    }

    guard let session = try? await dataStore.fetchRemoteNodeSession(id: sessionID) else {
      return
    }

    do {
      try await keychainService.deletePassword(forNodeKey: session.publicKey)
      logger.info("Cleared stored password after password change for session \(sessionID)")
    } catch {
      logger.warning("Failed to clear stored password for session \(sessionID): \(error)")
      // Next login fails naturally - user re-enters password, overwrites stale credential
    }
  }
}
