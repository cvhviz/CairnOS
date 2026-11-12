import Foundation
import MeshCore
import os

// MARK: - Contact Service Errors

public enum ContactServiceError: Error, Sendable, LocalizedError {
  case notConnected
  case sendFailed
  case invalidResponse
  case syncInterrupted
  case contactNotFound
  /// The radio did not answer a read of the contact's record (a timeout or a device error
  /// other than not-found), so the change that needed it was not made. Not the same as
  /// ``contactNotFound``: the contact may well still be on the radio.
  case radioReadFailed(MeshCoreError)
  case contactTableFull
  case shareContactUnavailable
  case sessionError(MeshCoreError)

  public var errorDescription: String? {
    switch self {
    case .notConnected:
      "Not connected to radio"
    case .sendFailed:
      "Failed to send message"
    case .invalidResponse:
      "Invalid response from device"
    case .syncInterrupted:
      "Sync was interrupted"
    case .contactNotFound:
      "Contact not found on device"
    case .radioReadFailed:
      "Couldn't read this contact from the radio, so nothing was changed. Check the connection and try again."
    case .contactTableFull:
      "Device node list is full"
    case .shareContactUnavailable:
      "Unable to share node. The node's advertisement may be missing or too old."
    case let .sessionError(error):
      error.localizedDescription
    }
  }
}

/// Reason for contact cleanup (deletion or blocking)
enum ContactCleanupReason {
  case deleted
  case blocked
  case unblocked
}

// MARK: - Sync Result

/// Result of a contact sync operation
public struct ContactSyncResult: Sendable {
  public let contactsReceived: Int
  public let lastSyncTimestamp: UInt32
  public let isIncremental: Bool
  /// The device's whole contact total from the `contactsStart` header (not the
  /// fetched count, which an incremental fetch filters), or `nil` when unknown.
  public let reportedTotal: Int?

  public init(contactsReceived: Int, lastSyncTimestamp: UInt32, isIncremental: Bool, reportedTotal: Int? = nil) {
    self.contactsReceived = contactsReceived
    self.lastSyncTimestamp = lastSyncTimestamp
    self.isIncremental = isIncremental
    self.reportedTotal = reportedTotal
  }
}

// MARK: - Contact Service

/// Service for managing mesh network contacts.
/// Handles contact discovery, sync, add/update/remove operations.
public actor ContactService {
  // MARK: - Properties

  private let session: any MeshCoreSessionProtocol
  private let dataStore: any PersistenceStoreProtocol
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "ContactService")

  /// Sync coordinator for UI refresh notifications.
  /// Injected by `ServiceContainer` at construction.
  private weak var syncCoordinator: SyncCoordinator?

  /// Runs the cross-service cleanup chain when a contact is deleted, blocked, or unblocked.
  /// Injected by `ServiceContainer` at construction.
  private let cleanupCoordinator: (any ContactCleanupHandling)?

  /// Multicast broadcaster for sync progress and node-deletion events.
  /// Consumers subscribe via `events()`; finished by `ServiceContainer.tearDown()`.
  private nonisolated let eventBroadcaster = EventBroadcaster<ContactServiceEvent>()

  /// Holds each contact's radio record still from the read to the write of a flag, path or
  /// add, so overlapping changes apply in turn instead of the later undoing the earlier.
  /// Shared with the other services that write whole contact records.
  private let recordWriteLock: ContactRecordWriteLock

  // MARK: - Initialization

  init(
    session: any MeshCoreSessionProtocol,
    dataStore: any PersistenceStoreProtocol,
    syncCoordinator: SyncCoordinator?,
    cleanupCoordinator: (any ContactCleanupHandling)?,
    recordWriteLock: ContactRecordWriteLock = ContactRecordWriteLock()
  ) {
    self.session = session
    self.dataStore = dataStore
    self.syncCoordinator = syncCoordinator
    self.cleanupCoordinator = cleanupCoordinator
    self.recordWriteLock = recordWriteLock
  }

  // MARK: - Events

  /// Returns a fresh stream of contact service events. Registration is
  /// synchronous, so events yielded after this call returns are never
  /// dropped. Consumers re-subscribe per connection because the owning
  /// `ServiceContainer` is rebuilt.
  public nonisolated func events() -> AsyncStream<ContactServiceEvent> {
    eventBroadcaster.subscribe()
  }

  /// Ends every `events()` subscriber's for-await loop. Called by
  /// `ServiceContainer.tearDown()` so consumer tasks release their service
  /// references.
  nonisolated func finishEvents() {
    eventBroadcaster.finish()
  }

  // MARK: - Configuration

  /// Whether a sync coordinator was injected at construction.
  var hasSyncCoordinatorWired: Bool {
    syncCoordinator != nil
  }

  /// Whether a cleanup coordinator was injected at construction.
  var hasCleanupCoordinatorWired: Bool {
    cleanupCoordinator != nil
  }

  // MARK: - Contact Sync

  /// Sync all contacts from device
  /// - Parameters:
  ///   - radioID: The device to sync from
  ///   - since: Optional date for incremental sync (only contacts modified after this time)
  /// - Returns: Sync result with count and timestamp
  public func syncContacts(radioID: UUID, since: Date? = nil) async throws -> ContactSyncResult {
    do {
      let fetchResult = try await session.getContactsReportingTotal(since: since)
      let meshContacts = fetchResult.contacts

      eventBroadcaster.yield(.syncProgress(received: 0, total: meshContacts.count))

      // Build set of public keys from device for cleanup
      let devicePublicKeys = Set(meshContacts.map(\.publicKey))

      // Persist every received contact in a single transaction rather than one
      // commit per contact; the per-item save was redundant overhead on every sync.
      // A name request to a stranger holds a placeholder entry on the radio for a few seconds;
      // a sync that lands meanwhile must not store it as a nameless contact.
      let frames = meshContacts.filter { !$0.isTemporaryPlaceholder }.map { $0.toContactFrame() }
      let receivedCount = try await dataStore.batchSaveContacts(radioID: radioID, from: frames)

      let lastTimestamp = meshContacts
        .map { UInt32($0.lastModified.timeIntervalSince1970) }
        .max() ?? 0

      eventBroadcaster.yield(.syncProgress(received: receivedCount, total: meshContacts.count))

      // On full sync, remove local contacts that no longer exist on device.
      if since == nil {
        try await pruneOrphans(radioID: radioID, devicePublicKeys: devicePublicKeys, reportedTotal: fetchResult.reportedTotal)
      }

      return ContactSyncResult(
        contactsReceived: receivedCount,
        lastSyncTimestamp: lastTimestamp,
        isIncremental: since != nil,
        reportedTotal: fetchResult.reportedTotal
      )
    } catch let error as MeshCoreError {
      throw ContactServiceError.sessionError(error)
    }
  }

  /// Removes local contacts that a full fetch proves are gone from the device.
  ///
  /// Prunes only on a complete snapshot: received count must meet the
  /// `contactsStart` total. A truncated stream leaves keys missing without a
  /// real device deletion, so those must not prune. A genuine shrink lowers the
  /// reported total in step, so a complete-but-smaller reply still prunes.
  /// Both counts include the ZephCore V-contact when firmware streams it.
  ///
  /// A `nil` `reportedTotal` means the reply carried no `contactsStart` header,
  /// so the device total is unknown and the snapshot cannot be proven complete;
  /// the prune skips.
  ///
  /// Without a usable self public key the V-contact cannot be identified, so the
  /// prune skips rather than risk deleting a local V-contact row that firmware
  /// omitted while clock-deferred.
  private func pruneOrphans(radioID: UUID, devicePublicKeys: Set<Data>, reportedTotal: Int?) async throws {
    guard let reportedTotal else {
      logger.notice("Full sync prune skipped: device sent no contact total (missing contactsStart header)")
      return
    }
    guard devicePublicKeys.count >= reportedTotal else {
      logger.notice(
        "Full sync prune skipped: received \(devicePublicKeys.count) of \(reportedTotal) reported device contacts (incomplete snapshot)"
      )
      return
    }
    guard let selfPublicKey = try? await dataStore.fetchDevice(radioID: radioID)?.publicKey,
          selfPublicKey.count == ProtocolLimits.publicKeySize else {
      logger.notice("Full sync prune skipped: self public key unavailable or invalid, cannot exclude the V-contact")
      return
    }

    let localContacts = try await dataStore.fetchContacts(radioID: radioID)
    let orphans = localContacts.filter { contact in
      guard !devicePublicKeys.contains(contact.publicKey) else { return false }
      if VContactIdentity.isVContact(publicKey: contact.publicKey, selfPublicKey: selfPublicKey) {
        return false
      }
      return true
    }
    if !orphans.isEmpty {
      logger.notice("Full sync prune: \(orphans.count) local contact(s) not found on device (device has \(devicePublicKeys.count), local has \(localContacts.count))")
    }
    for localContact in orphans {
      let keyPrefix = localContact.publicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
      logger.notice("Full sync prune: deleting '\(LogRedaction.nodeName(localContact.name))' [\(keyPrefix)…] (favorite=\(localContact.isFavorite), type=\(localContact.typeRawValue), lastModified=\(localContact.lastModified))")
      try await dataStore.deleteContact(id: localContact.id)
      await cleanupCoordinator?.handleCleanup(
        contactID: localContact.id, reason: .deleted, publicKey: localContact.publicKey
      )
    }
  }

  /// Full contact sync for a user-initiated refresh.
  ///
  /// Atomically waits out an advert-driven delta sync and claims the manual
  /// refresh flag on the coordinator. Separate wait and claim hops leave a
  /// window where a delta can take the claim after the wait returns and before
  /// the flag is set; both publish `syncProgress` on the same event stream, so
  /// that race jumps the pull-to-refresh counter. Callers still call
  /// `AdvertisementService.setSyncingContacts(true)` first so no new delta
  /// starts before this claim runs.
  ///
  /// - Parameter radioID: The device to sync from
  /// - Returns: Sync result with count and timestamp
  public func syncContactsForRefresh(radioID: UUID) async throws -> ContactSyncResult {
    do {
      try await syncCoordinator?.claimManualContactSync()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Wait timed out while an advert delta still held the claim. Do not
      // proceed (races progress) and do not silent-skip: surface so the spinner stops.
      throw ContactServiceError.syncInterrupted
    }
    do {
      let result = try await syncContacts(radioID: radioID)
      await syncCoordinator?.setManualContactSyncActive(false)
      return result
    } catch {
      await syncCoordinator?.setManualContactSyncActive(false)
      throw error
    }
  }

  // MARK: - Get Contact

  /// Get a specific contact by public key from local database
  /// - Parameters:
  ///   - radioID: The device ID
  ///   - publicKey: The contact's 32-byte public key
  /// - Returns: The contact if found
  public func getContact(radioID: UUID, publicKey: Data) async throws -> ContactDTO? {
    try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)
  }

  // MARK: - Add/Update Contact

  /// Add or update a contact on the device
  ///
  /// The remote-commands bit (0x10) of `contact.flags` is ignored: the record goes with the
  /// bit the radio holds for the key now, or without it when the radio has no record or can't
  /// be read (``RemoteCLIFlagGuard``). A QR card, a heard advert or an old stored copy can't
  /// let anyone run this radio's commands; only ``setRemoteCLIAllowed(_:allowed:)`` can.
  /// - Parameters:
  ///   - radioID: The device ID
  ///   - contact: The contact to add/update
  public func addOrUpdateContact(radioID: UUID, contact: ContactFrame) async throws {
    try await recordWriteLock.withLock(contact.publicKey) {
      try await self.addOrUpdateContactHoldingLock(radioID: radioID, contact: contact)
    }
  }

  private func addOrUpdateContactHoldingLock(radioID: UUID, contact: ContactFrame) async throws {
    await evictTemporaryEntryIfNeeded(radioID: radioID, publicKey: contact.publicKey)
    let flags = await RemoteCLIFlagGuard.flags(contact.flags) {
      try await self.session.getContact(publicKey: contact.publicKey)
    }
    try await writeContactRecord(radioID: radioID, contact: contact.with(flags: flags))
  }

  /// Writes a full record to the radio, then stores it. Callers decide the flags and hold
  /// ``recordWriteLock`` for the key.
  private func writeContactRecord(radioID: UUID, contact: ContactFrame) async throws {
    do {
      try await session.addContact(contact.toMeshContact())

      // Save to local database
      _ = try await dataStore.saveContact(radioID: radioID, from: contact)

      // Notify UI to refresh contacts list
      await syncCoordinator?.notifyContactsChanged()
    } catch let error as MeshCoreError {
      if case let .deviceError(code) = error, code == ProtocolError.tableFull.rawValue {
        throw ContactServiceError.contactTableFull
      }
      throw ContactServiceError.sessionError(error)
    }
  }

  /// The radio's current record for `publicKey`, for a change that writes it back.
  /// - Throws: ``ContactServiceError/contactNotFound`` when the radio answers it holds no such
  ///   contact (writing would add it again, with whatever permissions a stored copy still had),
  ///   or ``ContactServiceError/radioReadFailed(_:)`` when the read itself fails.
  private func radioRecordForWrite(publicKey: Data) async throws -> MeshContact {
    let current: MeshContact?
    do {
      current = try await session.getContact(publicKey: publicKey)
    } catch let error as MeshCoreError {
      throw ContactServiceError.radioReadFailed(error)
    }
    guard let current else { throw ContactServiceError.contactNotFound }
    return current
  }

  /// Most filler placeholders written to push a temporary entry out of the radio's reserved
  /// slots. The firmware keeps 8; the extra covers filler that lands on a slot of equal age.
  static let maxTemporaryEntryEvictionWrites = 16

  /// Clears the temporary entry a firmware 1.16+ radio holds for a key it sent an anonymous
  /// request to (a node name or region request), so the add that follows lands in the contact table.
  ///
  /// The radio keeps those entries in reserved slots at the front of its table that contact sync
  /// skips. An add for a key it holds there updates the entry in place, so the new contact stays
  /// in a hidden slot: the next full sync misses it and prunes the local copy, and Discover offers
  /// to add it again. Removing the entry is no way out, as it shifts the table and hides the first
  /// real contact instead. The radio recycles the oldest reserved slot for each new nameless entry,
  /// so this writes filler entries under random keys until the key's entry is gone. Filler
  /// entries are never saved or synced, and are recycled in turn.
  ///
  /// A contact already stored locally came in through sync, so it is not in a reserved slot.
  /// Best effort: a failure here leaves the add to go ahead as it did before.
  private func evictTemporaryEntryIfNeeded(radioID: UUID, publicKey: Data) async {
    guard (try? await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)) == nil,
          let device = try? await dataStore.fetchDevice(radioID: radioID),
          device.supportsAdHocRepeaterRequest else { return }

    do {
      guard let entry = try await session.getContact(publicKey: publicKey),
            entry.isTemporaryPlaceholder else { return }
      for _ in 0 ..< Self.maxTemporaryEntryEvictionWrites {
        try await session.addContact(Self.fillerPlaceholder())
        guard try await session.getContact(publicKey: publicKey) != nil else { return }
      }
      logger.warning("Temporary radio entry for a new contact did not clear; it may not sync until the radio restarts")
    } catch {
      logger.warning("Could not clear temporary radio entry before adding a contact: \(error)")
    }
  }

  private static func fillerPlaceholder() -> MeshContact {
    let key = Data((0 ..< ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: .min ... .max) })
    return MeshContact(
      id: key.hexString,
      publicKey: key,
      type: .chat,
      typeRawValue: 0,
      flags: [],
      outPathLength: 0,
      outPath: Data(),
      advertisedName: "",
      lastAdvertisement: Date(timeIntervalSince1970: 0),
      latitude: 0,
      longitude: 0,
      lastModified: Date(timeIntervalSince1970: 0)
    )
  }

  // MARK: - Remove Contact

  /// Remove a contact from the device
  /// - Parameters:
  ///   - radioID: The device ID
  ///   - publicKey: The contact's 32-byte public key
  ///
  /// ZephCore V-contact remove is disabled: no `CMD_REMOVE` (which would turn `v.contact` off),
  /// no local wipe, and no `.nodeDeleted` storage-full clear.
  public func removeContact(radioID: UUID, publicKey: Data) async throws {
    if await isProtectedVContact(radioID: radioID, publicKey: publicKey) {
      logger.info("removeContact ignored for ZephCore V-contact (remove disabled)")
      return
    }

    do {
      try await session.removeContact(publicKey: publicKey)

      // Remove from local database
      if let contact = try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey) {
        let contactID = contact.id

        try await dataStore.deleteContact(id: contactID)

        // Trigger cleanup (notifications, badge, session)
        await cleanupCoordinator?.handleCleanup(contactID: contactID, reason: .deleted, publicKey: publicKey)
      }
      await forgetHeardRecord(radioID: radioID, publicKey: publicKey)

      // Notify that a node was deleted (for clearing storage full flag)
      eventBroadcaster.yield(.nodeDeleted)

      // Notify UI to refresh contacts list
      await syncCoordinator?.notifyContactsChanged()
    } catch let error as MeshCoreError {
      if case let .deviceError(code) = error, code == ProtocolError.notFound.rawValue {
        throw ContactServiceError.contactNotFound
      }
      throw ContactServiceError.sessionError(error)
    }
  }

  /// Remove a contact's local data and run the full cleanup chain without contacting the device.
  /// Use when the device reports the contact doesn't exist but local data remains.
  ///
  /// ZephCore V-contact remove is disabled (same policy as ``removeContact``).
  public func removeLocalContact(contactID: UUID, publicKey: Data) async throws {
    let contact = try? await dataStore.fetchContact(id: contactID)
    if let contact, await isProtectedVContact(radioID: contact.radioID, publicKey: publicKey) {
      logger.info("removeLocalContact ignored for ZephCore V-contact (remove disabled)")
      return
    }

    try await dataStore.deleteContact(id: contactID)
    await cleanupCoordinator?.handleCleanup(contactID: contactID, reason: .deleted, publicKey: publicKey)
    if let contact {
      await forgetHeardRecord(radioID: contact.radioID, publicKey: publicKey)
    }
    eventBroadcaster.yield(.nodeDeleted)
    await syncCoordinator?.notifyContactsChanged()
  }

  /// Deleting a node forgets it: its heard record goes with the contact, so it leaves the maps and
  /// the Heard list rather than turning from saved into heard, until it is heard again. Only the
  /// deletes someone asks for come here (a node's Delete, Remove Nodes, Auto-Remove); a contact the
  /// radio drops by itself (overwrite oldest, a sync prune) stays heard, as it was. Best effort: the
  /// contact is already gone, so a failed write is logged rather than thrown.
  private func forgetHeardRecord(radioID: UUID, publicKey: Data) async {
    do {
      try await dataStore.deleteDiscoveredNodes(radioID: radioID, publicKeys: [publicKey])
    } catch {
      logger.warning("Could not forget the heard record of a deleted node: \(error.localizedDescription)")
    }
  }

  /// Whether `publicKey` is the ZephCore V-contact for this radio (remove/prune protected).
  private func isProtectedVContact(radioID: UUID, publicKey: Data) async -> Bool {
    guard let selfPublicKey = try? await dataStore.fetchDevice(radioID: radioID)?.publicKey else {
      return false
    }
    return VContactIdentity.isVContact(publicKey: publicKey, selfPublicKey: selfPublicKey)
  }

  /// Clears all messages for a direct conversation without deleting the contact.
  /// Preserves `lastMessageDate` so the now-empty conversation stays in the chats list
  /// (showing "No messages"), unlike delete-conversation which nils the date. Also clears
  /// both unread counters and notifies observers so no stale badge or preview survives.
  public func clearContactMessages(contactID: UUID) async throws {
    try await dataStore.deleteMessagesForContact(contactID: contactID)
    try await dataStore.clearUnreadCount(contactID: contactID)
    try await dataStore.clearUnreadMentionCount(contactID: contactID)
    await syncCoordinator?.notifyConversationsChanged()
  }

  // MARK: - Reset Path

  /// Reset the path for a contact (force rediscovery)
  /// - Parameters:
  ///   - radioID: The device ID
  ///   - publicKey: The contact's 32-byte public key
  public func resetPath(radioID: UUID, publicKey: Data) async throws {
    do {
      try await session.resetPath(publicKey: publicKey)

      // Update local contact to show flood routing
      if let contact = try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey) {
        let frame = contact.floodedContactFrame(asOf: UInt32(Date().timeIntervalSince1970))
        _ = try await dataStore.saveContact(radioID: radioID, from: frame)
      }
    } catch let error as MeshCoreError {
      if case let .deviceError(code) = error, code == ProtocolError.notFound.rawValue {
        throw ContactServiceError.contactNotFound
      }
      throw ContactServiceError.sessionError(error)
    }
  }

  // MARK: - Path Discovery

  /// Send a path discovery request to find optimal route to contact
  /// - Parameters:
  ///   - radioID: The device ID
  ///   - publicKey: The contact's 32-byte public key
  /// - Returns: MessageSentInfo containing the estimated timeout from firmware
  public func sendPathDiscovery(radioID: UUID, publicKey: Data) async throws -> MessageSentInfo {
    do {
      return try await session.sendPathDiscovery(to: publicKey)
    } catch let error as MeshCoreError {
      if case let .deviceError(code) = error, code == ProtocolError.notFound.rawValue {
        throw ContactServiceError.contactNotFound
      }
      throw ContactServiceError.sessionError(error)
    }
  }

  // MARK: - Radio Refresh

  /// Reads one contact back from the radio and stores it, for when the radio changed it on
  /// its own (a `PATH_UPDATED` push) and the caller can't wait for the next delta sync.
  /// - Returns: The stored contact, or `nil` when the radio no longer has it.
  public func refreshContactFromRadio(radioID: UUID, publicKey: Data) async throws -> ContactDTO? {
    do {
      guard let meshContact = try await session.getContact(publicKey: publicKey) else { return nil }
      _ = try await dataStore.saveContact(radioID: radioID, from: meshContact.toContactFrame())
      return try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)
    } catch let error as MeshCoreError {
      throw ContactServiceError.sessionError(error)
    }
  }

  // MARK: - Set Path

  /// Set a specific path for a contact
  /// - Parameters:
  ///   - radioID: The device ID
  ///   - publicKey: The contact's 32-byte public key
  ///   - path: The path data (repeater hashes)
  ///   - pathLength: Encoded path length byte (0xFF for flood, 0 for direct, >0 for routed)
  ///
  /// The flags go as the radio holds them now, never as stored: a permission revoked on the
  /// device (remote commands, telemetry) must not come back with a path change. As with a flag
  /// change, nothing is written when the radio's record can't be read or the radio no longer
  /// has the contact.
  /// - Throws: ``ContactServiceError/contactNotFound`` when the contact is missing here or on
  ///   the radio, ``ContactServiceError/radioReadFailed(_:)`` when the radio's record can't be
  ///   read, or `.sessionError` / `.contactTableFull` when the write fails.
  public func setPath(radioID: UUID, publicKey: Data, path: Data, pathLength: UInt8) async throws {
    try await recordWriteLock.withLock(publicKey) {
      try await self.setPathHoldingLock(radioID: radioID, publicKey: publicKey, path: path, pathLength: pathLength)
    }
  }

  private func setPathHoldingLock(radioID: UUID, publicKey: Data, path: Data, pathLength: UInt8) async throws {
    // Get current contact to preserve other fields
    guard let existingContact = try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey) else {
      throw ContactServiceError.contactNotFound
    }

    let flags = try await radioRecordForWrite(publicKey: publicKey).flags.rawValue

    // Create updated contact frame with new path
    let updatedFrame = ContactFrame(
      publicKey: existingContact.publicKey,
      type: existingContact.type,
      flags: flags,
      outPathLength: pathLength,
      outPath: path,
      name: existingContact.name,
      lastAdvertTimestamp: existingContact.lastAdvertTimestamp,
      latitude: existingContact.latitude,
      longitude: existingContact.longitude,
      lastModified: UInt32(Date().timeIntervalSince1970)
    )

    // Send update to device
    try await writeContactRecord(radioID: radioID, contact: updatedFrame)
  }

  // MARK: - Share Contact

  /// Share a contact via zero-hop broadcast
  /// - Parameter publicKey: The contact's 32-byte public key to share
  public func shareContact(publicKey: Data) async throws {
    do {
      try await session.shareContact(publicKey: publicKey)
    } catch let error as MeshCoreError {
      if case let .deviceError(code) = error, code == ProtocolError.tableFull.rawValue {
        throw ContactServiceError.shareContactUnavailable
      }
      if case let .deviceError(code) = error, code == ProtocolError.notFound.rawValue {
        throw ContactServiceError.contactNotFound
      }
      throw ContactServiceError.sessionError(error)
    }
  }

  // MARK: - Export/Import Contact

  private static let contactURIScheme = "meshcore"
  private static let contactURIHost = "contact"
  private static let contactURIPath = "/add"
  private static let contactURINameKey = "name"
  private static let contactURIPublicKeyKey = "public_key"
  private static let contactURITypeKey = "type"

  /// Build a shareable contact URI from contact information
  /// - Parameters:
  ///   - name: The contact's advertised name
  ///   - publicKey: The contact's 32-byte public key
  ///   - type: The contact type (chat, repeater, room)
  /// - Returns: Contact URI string in format: meshcore://contact/add?name=...&public_key=...&type=...
  public static func exportContactURI(name: String, publicKey: Data, type: ContactType) -> String {
    // Encode via MeshCoreURIQuery so `&`/`=` in the name cannot inject public_key/type.
    var components = URLComponents()
    components.scheme = contactURIScheme
    components.host = contactURIHost
    components.path = contactURIPath
    components.percentEncodedQueryItems = MeshCoreURIQuery.percentEncodedQueryItems(from: [
      URLQueryItem(name: contactURINameKey, value: name),
      URLQueryItem(name: contactURIPublicKeyKey, value: publicKey.uppercaseHexString()),
      URLQueryItem(name: contactURITypeKey, value: String(type.rawValue))
    ])
    return components.url?.absoluteString ?? ""
  }

  /// Import a contact from card data
  /// - Parameter cardData: The contact card data
  public func importContact(cardData: Data) async throws {
    do {
      try await session.importContact(cardData: cardData)
    } catch let error as MeshCoreError {
      throw ContactServiceError.sessionError(error)
    }
  }

  // MARK: - Local Database Operations

  /// Get all contacts for a device from local database
  public func getContacts(radioID: UUID) async throws -> [ContactDTO] {
    try await dataStore.fetchContacts(radioID: radioID)
  }

  /// Get conversations (contacts with messages) from local database
  public func getConversations(radioID: UUID) async throws -> [ContactDTO] {
    try await dataStore.fetchConversations(radioID: radioID)
  }

  /// Get a contact by ID from local database
  public func getContactByID(_ id: UUID) async throws -> ContactDTO? {
    try await dataStore.fetchContact(id: id)
  }

  /// Update local contact preferences (nickname, blocked, favorite, note).
  /// `nickname`: `nil` leaves the existing nickname unchanged; an empty or
  /// whitespace-only string clears it. A non-empty value is trimmed and stored.
  /// `note` works the same way.
  public func updateContactPreferences(
    contactID: UUID,
    nickname: String? = nil,
    isBlocked: Bool? = nil,
    isFavorite: Bool? = nil,
    note: String? = nil
  ) async throws {
    guard let existing = try await dataStore.fetchContact(id: contactID) else {
      throw ContactServiceError.contactNotFound
    }

    // nil => leave unchanged; empty/whitespace => clear; otherwise trim and set.
    let resolvedNickname: String?
    if let nickname {
      let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
      resolvedNickname = trimmed.isEmpty ? nil : trimmed
    } else {
      resolvedNickname = existing.nickname
    }
    let resolvedNote: String?
    if let note {
      let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
      resolvedNote = trimmed.isEmpty ? nil : trimmed
    } else {
      resolvedNote = existing.note
    }

    // Check blocking state transitions
    let isBeingBlocked = isBlocked == true && !existing.isBlocked
    let isBeingUnblocked = isBlocked == false && existing.isBlocked

    // Create updated DTO preserving existing values
    let updated = ContactDTO(
      from: Contact(
        id: existing.id,
        radioID: existing.radioID,
        publicKey: existing.publicKey,
        name: existing.name,
        typeRawValue: existing.typeRawValue,
        flags: existing.flags,
        outPathLength: existing.outPathLength,
        outPath: existing.outPath,
        lastAdvertTimestamp: existing.lastAdvertTimestamp,
        latitude: existing.latitude,
        longitude: existing.longitude,
        lastModified: existing.lastModified,
        lastHeardTimestamp: existing.lastHeardTimestamp ?? 0,
        nickname: resolvedNickname,
        isBlocked: isBlocked ?? existing.isBlocked,
        isMuted: existing.isMuted,
        isFavorite: isFavorite ?? existing.isFavorite,
        lastMessageDate: existing.lastMessageDate,
        unreadCount: isBeingBlocked ? 0 : existing.unreadCount,
        unreadMentionCount: existing.unreadMentionCount,
        ocvPreset: existing.ocvPreset,
        customOCVArrayString: existing.customOCVArrayString,
        avatarImageData: existing.avatarImageData,
        avatarColorRaw: existing.avatarColorRaw,
        note: resolvedNote
      )
    )

    try await dataStore.saveContact(updated)

    // Trigger cleanup for blocking state changes
    if isBeingBlocked {
      await cleanupCoordinator?.handleCleanup(contactID: contactID, reason: .blocked, publicKey: existing.publicKey)
    } else if isBeingUnblocked {
      await cleanupCoordinator?.handleCleanup(contactID: contactID, reason: .unblocked, publicKey: existing.publicKey)
    }

    await syncCoordinator?.notifyContactsChanged()
  }

  /// Updates OCV settings for a contact
  /// - Parameters:
  ///   - contactID: The contact's ID
  ///   - preset: The OCV preset name
  ///   - customArray: Custom OCV array string (for custom preset)
  public func updateContactOCVSettings(
    contactID: UUID,
    preset: String,
    customArray: String?
  ) async throws {
    guard let existing = try await dataStore.fetchContact(id: contactID) else {
      throw ContactServiceError.contactNotFound
    }

    let updated = ContactDTO(
      from: Contact(
        id: existing.id,
        radioID: existing.radioID,
        publicKey: existing.publicKey,
        name: existing.name,
        typeRawValue: existing.typeRawValue,
        flags: existing.flags,
        outPathLength: existing.outPathLength,
        outPath: existing.outPath,
        lastAdvertTimestamp: existing.lastAdvertTimestamp,
        latitude: existing.latitude,
        longitude: existing.longitude,
        lastModified: existing.lastModified,
        lastHeardTimestamp: existing.lastHeardTimestamp ?? 0,
        nickname: existing.nickname,
        isBlocked: existing.isBlocked,
        isMuted: existing.isMuted,
        isFavorite: existing.isFavorite,
        lastMessageDate: existing.lastMessageDate,
        unreadCount: existing.unreadCount,
        unreadMentionCount: existing.unreadMentionCount,
        ocvPreset: preset,
        customOCVArrayString: customArray,
        avatarImageData: existing.avatarImageData,
        avatarColorRaw: existing.avatarColorRaw,
        note: existing.note
      )
    )

    try await dataStore.saveContact(updated)
  }

  /// Updates a contact's locally stored profile picture.
  /// - Parameters:
  ///   - contactID: The contact's ID
  ///   - imageData: Compressed JPEG data for the new avatar, or `nil` to remove it
  public func updateContactAvatar(contactID: UUID, imageData: Data?) async throws {
    guard let existing = try await dataStore.fetchContact(id: contactID) else {
      throw ContactServiceError.contactNotFound
    }

    try await dataStore.saveContact(existing.with(avatarImageData: imageData))
    await syncCoordinator?.notifyContactsChanged()
  }

  /// Updates a contact's locally chosen avatar colour.
  /// - Parameters:
  ///   - contactID: The contact's ID
  ///   - color: The swatch to use, or `nil` for Automatic
  public func updateContactAvatarColor(contactID: UUID, color: NodeAvatarColor?) async throws {
    guard let existing = try await dataStore.fetchContact(id: contactID) else {
      throw ContactServiceError.contactNotFound
    }

    try await dataStore.saveContact(existing.with(avatarColorRaw: color?.rawValue))
    await syncCoordinator?.notifyContactsChanged()
  }

  // MARK: - Device Favorite Sync

  /// Sets a contact's favorite status on the device and updates local storage.
  ///
  /// This method updates the device's contact flags (bit 0 = favorite), waits for
  /// confirmation, then updates the local SwiftData contact.
  ///
  /// - Parameters:
  ///   - contactID: The contact's UUID.
  ///   - isFavorite: Whether to mark the contact as a favorite.
  /// - Throws: `ContactServiceError` if the device update fails.
  public func setContactFavorite(_ contactID: UUID, isFavorite: Bool) async throws {
    try await applyFlags(contactID, set: isFavorite ? 0x01 : 0, clear: isFavorite ? 0 : 0x01, isFavorite: isFavorite)
  }

  // MARK: - Telemetry Permissions

  /// Whether a contact has telemetry permission flags set (bits 1-3).
  public static func hasTelemetryPermissions(flags: UInt8) -> Bool {
    (flags & 0x0E) != 0
  }

  /// Sets telemetry permission flags on a contact's device record.
  /// Bits 1-3 of contact.flags control base/location/environment permissions.
  /// Bit 0 (favourite) is preserved.
  ///
  /// - Parameters:
  ///   - contactID: The contact's UUID.
  ///   - granted: Whether to grant telemetry permissions.
  /// - Throws: `ContactServiceError` if the device update fails.
  public func setTelemetryPermissions(_ contactID: UUID, granted: Bool) async throws {
    // Set or clear bits 1-3, preserving bit 0 (favourite) and bit 4 (remote commands)
    try await applyFlags(contactID, set: granted ? 0x0E : 0, clear: granted ? 0 : 0x0E)
  }

  // MARK: - Remote Commands

  /// Whether a contact may run this radio's command line (bit 4, MeshCore 1.18).
  public static func allowsRemoteCLI(flags: UInt8) -> Bool {
    (flags & ContactFlags.remoteCLI.rawValue) != 0
  }

  /// Lets a contact run this radio's command line over the mesh, or stops it
  /// (contact flag 0x10, firmware `ContactInfo::isRemoteCLIAllowed`, MeshCore 1.18).
  /// The other bits are preserved. This is the permission for *their* commands here;
  /// whether this radio's commands run on theirs is decided by their contact for us.
  ///
  /// A granted contact can rename this radio, change its Bluetooth PIN, Wi-Fi and
  /// radio settings, and restart or power it off: only for a device the user owns.
  ///
  /// - Parameters:
  ///   - contactID: The contact's UUID.
  ///   - allowed: Whether to allow their commands.
  /// - Throws: `ContactServiceError` if the device update fails.
  public func setRemoteCLIAllowed(_ contactID: UUID, allowed: Bool) async throws {
    let bit = ContactFlags.remoteCLI.rawValue
    try await applyFlags(contactID, set: allowed ? bit : 0, clear: allowed ? 0 : bit)
  }

  // MARK: - Flag Updates

  /// Sets and clears contact flag bits on the device record, then in local storage once
  /// the device confirmed. Bits in neither mask are preserved.
  ///
  /// The masks apply to the radio's own record, read back first, never to the stored copy:
  /// a permission revoked on the device itself (its contact screen, or another app) must
  /// not be granted again by a later favourite or telemetry toggle here, and the radio's
  /// newer path, name and position must not be overwritten with older stored ones. The
  /// stored copy then takes the radio's record with the new flags, as
  /// ``refreshContactFromRadio(radioID:publicKey:)`` would.
  ///
  /// - Parameters:
  ///   - contactID: The contact's UUID.
  ///   - set: Bits to set.
  ///   - clear: Bits to clear.
  ///   - isFavorite: The local favourite state to store, or nil to keep it.
  /// Changes for the same contact that overlap (a favourite tap while a telemetry change is
  /// still waiting on the radio) run one after another under ``recordWriteLock``, each from
  /// the record the previous one left, so none is lost.
  ///
  /// - Throws: `ContactServiceError.contactNotFound` if the contact is missing here or on
  ///   the radio, `.radioReadFailed` if the radio's record can't be read (nothing is written
  ///   in either case), or `.sessionError` if the write fails.
  private func applyFlags(_ contactID: UUID, set: UInt8, clear: UInt8, isFavorite: Bool? = nil) async throws {
    guard let publicKey = try await dataStore.fetchContact(id: contactID)?.publicKey else {
      throw ContactServiceError.contactNotFound
    }
    try await recordWriteLock.withLock(publicKey) {
      try await self.applyFlagsHoldingLock(contactID, set: set, clear: clear, isFavorite: isFavorite)
    }
  }

  private func applyFlagsHoldingLock(_ contactID: UUID, set: UInt8, clear: UInt8, isFavorite: Bool?) async throws {
    // Read again under the lock: a change that ran while this one waited may have stored
    // newer app-only fields.
    guard let existing = try await dataStore.fetchContact(id: contactID) else {
      throw ContactServiceError.contactNotFound
    }

    // A contact the radio no longer holds is not written back: that would add it again,
    // with whatever permissions the stored copy still had.
    let onRadio = try await radioRecordForWrite(publicKey: existing.publicKey)

    let newFlags = (onRadio.flags.rawValue & ~clear) | set

    // Push to device and wait for confirmation
    do {
      try await session.changeContactFlags(onRadio, flags: ContactFlags(rawValue: newFlags))
    } catch let error as MeshCoreError {
      throw ContactServiceError.sessionError(error)
    }

    // Device confirmed - store the radio's record with the new flags, keeping the
    // app-only fields.
    let updated = ContactDTO(
      from: Contact(
        id: existing.id,
        radioID: existing.radioID,
        publicKey: existing.publicKey,
        name: onRadio.advertisedName,
        typeRawValue: onRadio.typeRawValue,
        flags: newFlags,
        outPathLength: onRadio.outPathLength,
        outPath: onRadio.outPath,
        lastAdvertTimestamp: UInt32(onRadio.lastAdvertisement.timeIntervalSince1970),
        latitude: onRadio.latitude,
        longitude: onRadio.longitude,
        lastModified: UInt32(onRadio.lastModified.timeIntervalSince1970),
        lastHeardTimestamp: existing.lastHeardTimestamp ?? 0,
        nickname: existing.nickname,
        isBlocked: existing.isBlocked,
        isMuted: existing.isMuted,
        isFavorite: isFavorite ?? existing.isFavorite,
        lastMessageDate: existing.lastMessageDate,
        unreadCount: existing.unreadCount,
        unreadMentionCount: existing.unreadMentionCount,
        ocvPreset: existing.ocvPreset,
        customOCVArrayString: existing.customOCVArrayString,
        avatarImageData: existing.avatarImageData,
        avatarColorRaw: existing.avatarColorRaw,
        note: existing.note
      )
    )

    try await dataStore.saveContact(updated)

    // Pages showing this contact (its Remote commands switch, the favourites list) read the
    // new flags; a telemetry change made in Settings reaches an open contact page this way.
    await syncCoordinator?.notifyContactsChanged()
  }

}

// MARK: - ContactServiceProtocol Conformance

extension ContactService: ContactServiceProtocol {
  // Already implements syncContacts(radioID:since:) -> ContactSyncResult
}

// MARK: - MeshContact Extensions

extension MeshContact {
  /// Converts a MeshContact to a ContactFrame for persistence
  func toContactFrame() -> ContactFrame {
    ContactFrame(
      publicKey: publicKey,
      type: type,
      typeRawValue: typeRawValue,
      flags: flags.rawValue,
      outPathLength: outPathLength,
      outPath: outPath,
      name: advertisedName,
      lastAdvertTimestamp: UInt32(lastAdvertisement.timeIntervalSince1970),
      latitude: latitude,
      longitude: longitude,
      lastModified: UInt32(lastModified.timeIntervalSince1970)
    )
  }
}

// MARK: - ContactFrame Extensions

public extension ContactFrame {
  /// Converts a ContactFrame to a MeshContact for session operations
  func toMeshContact() -> MeshContact {
    MeshContact(
      id: publicKey.uppercaseHexString(),
      publicKey: publicKey,
      type: type,
      typeRawValue: typeRawValue,
      flags: ContactFlags(rawValue: flags),
      outPathLength: outPathLength,
      outPath: outPath,
      advertisedName: name,
      lastAdvertisement: Date(timeIntervalSince1970: TimeInterval(lastAdvertTimestamp)),
      latitude: latitude,
      longitude: longitude,
      lastModified: Date(timeIntervalSince1970: TimeInterval(lastModified))
    )
  }
}
