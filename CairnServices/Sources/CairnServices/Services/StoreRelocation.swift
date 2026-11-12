import CoreData
import Foundation
import os

/// Moves the app's database out of the App Group container, once.
///
/// From 1.4 (3), when the app gained the widget's App Group entitlement, SwiftData's default
/// (`groupContainer: .automatic`) quietly opened `Cairn.store` in the *group* container. iOS
/// terminates an app that is suspended while it holds a lock on a file in a shared container
/// (termination reason 0xdead10cc), so every save that happened to be in flight as the app was
/// suspended in the background killed it. Nothing but the app reads the database (the widget reads
/// a snapshot from the group's `UserDefaults`), so it belongs in the app's own container, where
/// that rule does not apply. ``PersistenceStore/createContainer(inMemory:legacyAppGroupID:defaults:)``
/// names that location explicitly and runs this first.
///
/// The group copy, when there is one, holds everything written since 1.4 (3) and wins over the app
/// container's copy, which is the stale one an upgrade from 1.4 (2) or earlier left behind. The
/// copy is Core Data's own (`replacePersistentStore`: the write-ahead log and external-storage
/// files travel with it), and a marker is set before the old copy is removed, so the move is never
/// repeated: a second run could otherwise put an old group copy back over newer data.
public enum StoreRelocation {
  /// Set in `defaults` once the group copy has been moved (or there was none to move).
  public static let markerKey = "cairn.storeRelocatedToAppContainer"

  public enum Outcome: Equatable, Sendable {
    /// No group copy: a fresh install, or one that never ran a build that used the group.
    case nothingToMove
    /// The group copy now is the app container's store.
    case moved
    /// Moved on an earlier launch. `leftoverRemoved`: an old group copy still lying there was
    /// cleaned up now.
    case alreadyMoved(leftoverRemoved: Bool)
  }

  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "StoreRelocation")

  /// Where SwiftData put `<name>.store` in an App Group container.
  public static func groupStoreURL(groupContainer: URL, storeName: String) -> URL {
    groupContainer
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
      .appending(path: "\(storeName).store", directoryHint: .notDirectory)
  }

  /// Runs before the store is opened. Throws when the copy fails (the files unreadable before
  /// first unlock, the volume full): the caller must then not open `destination`, because writes
  /// made there would be overwritten by the retry.
  ///
  /// What says "moved" is on disk, not only in `defaults`: straight after the copy the group
  /// store is renamed aside, so however the process dies afterwards no later launch finds a store
  /// to copy again. The old copy is never emptied in place (Core Data's destroy leaves a valid,
  /// empty store, and copying that over the app's would erase it).
  @discardableResult
  public static func relocate(
    from legacy: URL,
    to destination: URL,
    defaults: UserDefaults,
    fileManager: FileManager = .default
  ) throws -> Outcome {
    let legacyExists = fileManager.fileExists(atPath: legacy.path)

    if defaults.bool(forKey: markerKey) {
      let hadLeftovers = removeLeftovers(of: legacy, includingStore: true, fileManager: fileManager)
      return .alreadyMoved(leftoverRemoved: hadLeftovers)
    }

    guard legacyExists else {
      // nothing to copy; what a move that was cut short after its rename left behind goes now
      removeLeftovers(of: legacy, includingStore: false, fileManager: fileManager)
      defaults.set(true, forKey: markerKey)
      return .nothingToMove
    }

    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // An empty model is enough: replace works on the store's files, not its schema.
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
    try coordinator.replacePersistentStore(
      at: destination,
      destinationOptions: nil,
      withPersistentStoreFrom: legacy,
      sourceOptions: nil,
      type: .sqlite
    )
    // Aside first (one atomic rename), marker second, removal last.
    let aside = asideURL(for: legacy)
    try? fileManager.removeItem(at: aside)
    do {
      try fileManager.moveItem(at: legacy, to: aside)
    } catch {
      // the whole old copy stays, untouched; the marker alone keeps it from being copied again
      logger.error("Could not set the old database copy aside: \(error.localizedDescription, privacy: .public)")
    }
    defaults.set(true, forKey: markerKey)
    logger.notice("Moved the database from the App Group container to the app's own")
    removeLeftovers(of: legacy, includingStore: true, fileManager: fileManager)
    return .moved
  }

  private static func asideURL(for legacy: URL) -> URL {
    legacy.deletingLastPathComponent().appending(path: legacy.lastPathComponent + ".relocated")
  }

  /// Removes what the old copy left in the group container: the store set aside, its write-ahead
  /// log and shared-memory files, SwiftData's external-storage folder, and (once the move is
  /// known to be done) a store file still under its own name. Best effort: whatever stays is
  /// never opened again and is tried again next launch. true = something was there.
  @discardableResult
  private static func removeLeftovers(of legacy: URL, includingStore: Bool, fileManager: FileManager) -> Bool {
    let directory = legacy.deletingLastPathComponent()
    let base = legacy.lastPathComponent
    let stem = legacy.deletingPathExtension().lastPathComponent
    var names = [base + ".relocated", base + "-wal", base + "-shm", ".\(stem)_SUPPORT"]
    if includingStore { names.append(base) }
    var found = false
    for name in names {
      let file = directory.appending(path: name)
      guard fileManager.fileExists(atPath: file.path) else { continue }
      found = true
      do {
        try fileManager.removeItem(at: file)
      } catch {
        logger.error("Could not remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
    return found
  }
}
