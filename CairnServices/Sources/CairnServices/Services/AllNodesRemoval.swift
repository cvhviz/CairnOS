import Foundation

/// The Settings → Nodes → Remove Nodes calls, so the settings model and its tests can stand in
/// for the radio.
@MainActor
public protocol NodeRemoving: AnyObject {
  /// Returns the number of contacts `removeAllNodes` would remove for the current device.
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func removableNodeCount() async throws -> Int

  /// Removes every contact, favorites included, from the device and app, along with their
  /// messages and heard records (so they leave the maps). Channels are not touched.
  /// - Parameters:
  ///   - onStart: Called once, before the first radio command, with the public keys the run will
  ///     remove, so the app can take them out of its lists and maps at once while the radio works
  ///     through them (one command each).
  ///   - onProgress: Called with `(0, total)` before the first radio command, then after each
  ///     removal with the running count and the total.
  /// - Returns: Count of removed vs total contacts, and why it stopped early if it did
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func removeAllNodes(
    onStart: (_ targets: Set<Data>) -> Void,
    onProgress: (_ removed: Int, _ total: Int) -> Void
  ) async throws -> RemoveUnfavoritedResult

  /// Returns the number of contacts `removeUnfavoritedNodes` would remove for the current device.
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func unfavoritedNodeCount() async throws -> Int

  /// Removes every non-favorite contact from the device and app, along with their messages and
  /// heard records (so they leave the maps).
  /// - Parameters: As for `removeAllNodes`.
  /// - Returns: Count of removed vs total contacts, and why it stopped early if it did
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func removeUnfavoritedNodes(
    onStart: (_ targets: Set<Data>) -> Void,
    onProgress: (_ removed: Int, _ total: Int) -> Void
  ) async throws -> RemoveUnfavoritedResult
}

extension ConnectionManager: NodeRemoving {
  public func removableNodeCount() async throws -> Int {
    guard let device = connectedDevice else {
      throw ConnectionError.notConnected
    }

    let contacts = try await persistenceStore.fetchContacts(radioID: device.radioID)
    return AllNodesRemoval.targets(in: contacts, selfPublicKey: device.publicKey).count
  }

  public func removeAllNodes(
    onStart: (_ targets: Set<Data>) -> Void = { _ in },
    onProgress: (_ removed: Int, _ total: Int) -> Void
  ) async throws -> RemoveUnfavoritedResult {
    guard let device = connectedDevice, let services else {
      throw ConnectionError.notConnected
    }

    let radioID = device.radioID
    let contactService = services.contactService
    let contacts = try await persistenceStore.fetchContacts(radioID: radioID)

    return try await AllNodesRemoval.remove(
      AllNodesRemoval.targets(in: contacts, selfPublicKey: device.publicKey),
      removeFromRadio: { contact in
        try await contactService.removeContact(radioID: radioID, publicKey: contact.publicKey)
      },
      removeLocally: { contact in
        try await contactService.removeLocalContact(contactID: contact.id, publicKey: contact.publicKey)
      },
      onStart: onStart,
      onProgress: onProgress,
      onRemoved: nil,
      logger: logger
    )
  }
}

/// Removes a list of contacts from the radio and the app, one radio command at a time.
@MainActor
enum AllNodesRemoval {
  /// The contacts a removal covers. Never the ZephCore V-contact: CMD_REMOVE turns firmware
  /// v.contact off.
  static func targets(in contacts: [ContactDTO], selfPublicKey: Data?) -> [ContactDTO] {
    guard let selfPublicKey else { return contacts }
    return contacts.filter {
      !VContactIdentity.isVContact(publicKey: $0.publicKey, selfPublicKey: selfPublicKey)
    }
  }

  /// A contact the radio no longer has is cleaned up locally and counts as removed. Any other
  /// failure ends the run with the count so far and the error that ended it: it is how a dropped
  /// connection shows up, and every later command would wait out its timeout the same way.
  /// The targets and the progress are reported once before the first command, so a run queued
  /// behind other radio traffic shows its size (and the app can hide its nodes) at once; the
  /// progress again after each contact.
  static func remove(
    _ targets: [ContactDTO],
    removeFromRadio: (ContactDTO) async throws -> Void,
    removeLocally: (ContactDTO) async throws -> Void,
    onStart: (_ targets: Set<Data>) -> Void = { _ in },
    onProgress: (_ removed: Int, _ total: Int) -> Void,
    onRemoved: ((ContactDTO) -> Void)? = nil,
    logger: PersistentLogger
  ) async throws -> RemoveUnfavoritedResult {
    var removedCount = 0

    if !targets.isEmpty {
      onStart(Set(targets.map(\.publicKey)))
      onProgress(0, targets.count)
    }

    for contact in targets {
      try Task.checkCancellation()

      do {
        try await removeFromRadio(contact)
        removedCount += 1
        onRemoved?(contact)
      } catch ContactServiceError.contactNotFound {
        do {
          try await removeLocally(contact)
          removedCount += 1
          onRemoved?(contact)
          logger.info("Contact not found on device, cleaned up locally: \(contact.name)")
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          logger.warning("Failed to clean up local data for \(contact.name): \(error.localizedDescription)")
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        logger.warning(
          "Node removal stopped at \(removedCount) of \(targets.count): failed to remove \(contact.name): \(error.localizedDescription)"
        )
        return RemoveUnfavoritedResult(removed: removedCount, total: targets.count, failure: error)
      }

      onProgress(removedCount, targets.count)
    }

    return RemoveUnfavoritedResult(removed: removedCount, total: targets.count)
  }
}
