// SyncCoordinator+ContactNames.swift
import Foundation

// MARK: - Contact Names For Senders And Sessions

extension SyncCoordinator {
  /// The name this radio puts on air now: the node name firmware prepends to every channel send
  /// (`_prefs.node_name`) and that others mention and react to. Read per message rather than
  /// captured at connect, so a rename from Device Info or the CLI applies at once.
  func currentSelfNodeName(radioID: UUID, dataStore: any PersistenceStoreProtocol) async -> String {
    let device = try? await dataStore.fetchDevice(radioID: radioID)
    return device?.nodeName ?? ""
  }

  /// One radio's contact name tables, built once until contacts next change.
  func contactNameDirectory(radioID: UUID, dataStore: any PersistenceStoreProtocol) async -> ContactNameDirectory {
    if let cached = contactNameDirectories[radioID] { return cached }
    do {
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      let directory = ContactNameDirectory(contacts: contacts)
      contactNameDirectories[radioID] = directory
      return directory
    } catch {
      logger.warning("Contact names unavailable for sender labels: \(error.localizedDescription)")
      return .empty
    }
  }

  /// How a notification names a channel sender: "Dad (Frank Wilson)" when one contact has that
  /// advertised name and a nickname, else the name on air. Nil when the message has no sender.
  func channelSenderLabel(
    _ senderNodeName: String?,
    radioID: UUID,
    dependencies: SyncDependencies
  ) async -> String? {
    guard let senderNodeName, !senderNodeName.isEmpty else { return nil }
    let directory = await contactNameDirectory(radioID: radioID, dataStore: dependencies.dataStore)
    let strings = await dependencies.notificationService.strings
    return directory.channelSenders.labeledName(for: senderNodeName) { nickname, wireName in
      strings?.unverifiedSenderName(nickname: nickname, wireName: wireName)
        ?? ChannelSenderNameResolver.defaultLabel(nickname: nickname, wireName: wireName)
    }
  }

  /// Contacts changed (a nickname, an advert's new name, a contact added or removed): drop the
  /// cached name tables and bring remote node session names up to date.
  func contactsDidChange() {
    contactNameDirectories.removeAll()
    guard let store = contactNameStore else { return }
    sessionNameRefreshTask?.cancel()
    sessionNameRefreshTask = Task { [weak self] in
      // Adverts change contacts in bursts: refresh once per burst.
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await self?.refreshRemoteNodeSessionNames(dataStore: store.dataStore, radioID: store.radioID)
    }
  }

  /// A room or repeater session keeps a copy of its node's name, taken when the session was made.
  /// Rewrites each copy whose contact on this radio is now named differently (nickname set or
  /// cleared, a new advertised name), so the room header, the Chats list, notifications, CarPlay
  /// and Siri follow. A session whose contact is gone keeps its last known name.
  func refreshRemoteNodeSessionNames(dataStore: any PersistenceStoreProtocol, radioID: UUID) async {
    do {
      let sessions = try await dataStore.fetchRemoteNodeSessions(radioID: radioID)
      guard !sessions.isEmpty else { return }
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      let renames = Self.sessionRenames(sessions: sessions, contacts: contacts)
      guard !renames.isEmpty else { return }
      for rename in renames {
        try await dataStore.updateRemoteNodeSessionName(id: rename.sessionID, name: rename.name)
      }
      logger.info("Updated \(renames.count) remote node session name(s) from contacts")
      await notifyConversationsChanged()
    } catch {
      logger.warning("Session name refresh failed: \(error.localizedDescription)")
    }
  }

  /// The sessions whose stored name differs from their contact's current name.
  nonisolated static func sessionRenames(
    sessions: [RemoteNodeSessionDTO],
    contacts: [ContactDTO]
  ) -> [(sessionID: UUID, name: String)] {
    var namesByKey: [Data: String] = [:]
    for contact in contacts {
      namesByKey[contact.publicKey] = contact.displayName
    }
    return sessions.compactMap { session in
      guard let name = namesByKey[session.publicKey], !name.isEmpty, name != session.name else { return nil }
      return (session.id, name)
    }
  }

  // MARK: - One-Time Repairs Of Stored Names

  /// Per-radio marker that the user's own saved reactions were identified once.
  nonisolated static func ownReactionsMarkedKey(radioID: UUID) -> String {
    "cvhvisuals.Cairn.nameIdentity.ownReactionsMarked.\(radioID.uuidString)"
  }

  /// Repairs names older builds stored, for one radio:
  /// - reactions the user made, saved under the node name with nothing marking them as theirs,
  ///   are marked as the user's own (once per radio: afterwards every reaction records it, and a
  ///   stranger who shares the node name must not be taken for the user)
  /// - room posts written on a Cairn radio's screen, once filed as DMs to the room's contact, move
  ///   into the room as the user's own posts
  /// - Parameter defaultsSuiteName: Where the once-per-radio marker lives; nil for the standard
  ///   defaults (tests pass their own suite).
  func repairStoredNames(dependencies: SyncDependencies, radioID: UUID, defaultsSuiteName: String? = nil) async {
    let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    let dataStore = dependencies.dataStore
    let markerKey = Self.ownReactionsMarkedKey(radioID: radioID)
    if !defaults.bool(forKey: markerKey) {
      let nodeName = await currentSelfNodeName(radioID: radioID, dataStore: dataStore)
      do {
        let marked = try await dataStore.markOwnReactions(
          radioID: radioID,
          selfNames: [nodeName, ReactionDTO.legacySelfSenderName]
        )
        defaults.set(true, forKey: markerKey)
        if marked > 0 { logger.info("Marked \(marked) saved reaction(s) as the user's own") }
      } catch {
        logger.warning("Marking own reactions failed: \(error.localizedDescription)")
      }
    }

    do {
      let roomContactIDs = try await dataStore.fetchContacts(radioID: radioID)
        .filter { $0.type == .room }
        .map(\.id)
      let moved = try await dataStore.removeRoomPostsFiledAsDirectMessages(radioID: radioID, roomContactIDs: roomContactIDs)
      guard !moved.isEmpty else { return }
      var contactsByID: [UUID: ContactDTO] = [:]
      for id in Set(moved.compactMap(\.contactID)) {
        contactsByID[id] = try await dataStore.fetchContact(id: id)
      }
      for row in moved {
        guard let contactID = row.contactID, let roomContact = contactsByID[contactID] else { continue }
        _ = try? await dependencies.roomServerService.storeOwnPost(
          roomPublicKeyPrefix: roomContact.publicKey.prefix(6),
          timestamp: row.timestamp,
          text: row.text,
          isDelivered: row.status == .delivered,
          createdAt: row.createdAt
        )
      }
      logger.info("Moved \(moved.count) room post(s) out of direct messages into their rooms")
      await notifyConversationsChanged()
    } catch {
      logger.warning("Moving room posts out of direct messages failed: \(error.localizedDescription)")
    }
  }

  /// How a notification names a room post's author: the contact on this radio its key prefix
  /// matches (nickname first), the room itself for its own posts, else the name known when it
  /// arrived, else "Unknown (50515253)". Never left out: a post with no sender reads as the user's.
  func roomAuthorLabel(
    _ post: RoomMessageDTO,
    session: RemoteNodeSessionDTO?,
    dependencies: SyncDependencies
  ) async -> String {
    let radioID = session?.radioID ?? contactNameStore?.radioID
    let directory: ContactNameDirectory = if let radioID {
      await contactNameDirectory(radioID: radioID, dataStore: dependencies.dataStore)
    } else {
      .empty
    }
    let identity = directory.roomAuthors.resolve(
      post,
      roomPublicKey: session?.publicKey,
      roomName: session?.name,
      selfName: ""
    )
    guard identity.isKeyOnly else { return identity.displayName }
    let strings = await dependencies.notificationService.strings
    return strings?.unknownRoomAuthor(keyPrefixHex: identity.keyPrefixHex) ?? identity.keyPrefixHex
  }
}
