import Foundation
import os
import SwiftData

// MARK: - PersistenceStore Errors

public enum PersistenceStoreError: Error, Sendable {
  case deviceNotFound
  case contactNotFound
  case messageNotFound
  case channelNotFound
  case remoteNodeSessionNotFound
  case saveFailed(String)
  case fetchFailed(String)
  case invalidData
}

extension PersistenceStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .deviceNotFound: "Device not found."
    case .contactNotFound: "Contact not found."
    case .messageNotFound: "Message not found."
    case .channelNotFound: "Channel not found."
    case .remoteNodeSessionNotFound: "Remote node session not found."
    case let .saveFailed(msg): "Failed to save: \(msg)"
    case let .fetchFailed(msg): "Failed to fetch: \(msg)"
    case .invalidData: "Invalid data."
    }
  }
}

// MARK: - PersistenceStore Actor

/// `DefaultSerialModelExecutor` runs jobs on the caller's thread, so a
/// main-actor caller would run SwiftData work on the main thread.  This runs
/// the actor and owns its `ModelContext` on a dedicated queue instead.
private final class StoreExecutor: SerialModelExecutor, @unchecked Sendable {
  let modelContext: ModelContext
  private let queue: DispatchSerialQueue

  init(container: ModelContainer) {
    let queue = DispatchSerialQueue(label: "PersistenceStore")
    modelContext = queue.sync { ModelContext(container) }
    self.queue = queue
  }

  func enqueue(_ job: consuming ExecutorJob) {
    queue.enqueue(job)
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }
}

/// ModelActor for background SwiftData operations.
/// Provides per-device data isolation and thread-safe access.
public actor PersistenceStore: ModelActor, PersistenceStoreProtocol {
  public nonisolated let modelExecutor: any ModelExecutor
  public nonisolated let modelContainer: ModelContainer

  public init(modelContainer: ModelContainer) {
    modelExecutor = StoreExecutor(container: modelContainer)
    self.modelContainer = modelContainer
  }

  var rxLogEntryCountsByDevice: [UUID: Int] = [:]
  var unsavedRxLogInsertCount = 0
  var rxLogFlushTask: Task<Void, Never>?

  /// Pending coalesced save for advert-driven updates to existing discovered
  /// nodes. A busy mesh re-adverts the same nodes constantly; saving each one
  /// (like the RX log) is batched instead. New nodes still save immediately.
  var discoveredNodeFlushTask: Task<Void, Never>?
  static let discoveredNodeFlushInterval: Duration = .milliseconds(1500)

  func commitPendingRxLogEntries() throws {
    rxLogFlushTask?.cancel()
    rxLogFlushTask = nil
    guard unsavedRxLogInsertCount > 0 else { return }
    try modelContext.save()
    #if DEBUG
      rxLogInitiatedSaveCount += 1
    #endif
    unsavedRxLogInsertCount = 0
    for radioID in Array(rxLogEntryCountsByDevice.keys) {
      try pruneRxLogEntries(radioID: radioID)
    }
  }

  #if DEBUG
    /// Inserts since the last RxLog-initiated `modelContext.save()`. Does not
    /// count piggyback saves from other store APIs.
    var rxLogInitiatedSaveCount = 0

    /// Test-only hook fired immediately before `modelContext.save()` in `batchSaveChannels`.
    var batchSaveChannelsFaultInjection: (@Sendable () throws -> Void)?

    /// Test-only hook fired immediately before `modelContext.save()` in
    /// `deleteMessagesForChannel`.
    var deleteMessagesForChannelFaultInjection: (@Sendable () throws -> Void)?

    /// Test-only hook fired immediately before `modelContext.save()` in `deleteContacts`.
    var deleteContactsFaultInjection: (@Sendable () throws -> Void)?

    /// Test-only fault-injection hook fired immediately before `modelContext.save()`
    /// in `importBackupDatabase`. Debug-only so the production API stays clean.
    /// SwiftData upserts on unique-constraint conflicts, so there is no reliable
    /// in-band way to provoke a save failure from a well-formed envelope.
    var backupImportFaultInjection: (@Sendable () throws -> Void)?

    /// Test-only hook fired after `modelContext.save()` succeeds and the
    /// transaction is committed. Tests use it to cancel the outer task so
    /// they can assert post-commit behaviour of `importBackup`.
    var backupImportPostCommitHook: (@Sendable () -> Void)?

    /// Test-only fault injection fired at the top of
    /// `incrementPendingSendAttemptCount`. Tests use it to verify the
    /// bump-failure park-and-requeue path in `ChatSendQueueService`'s drain
    /// closures — a real SwiftData save failure here is otherwise hard to
    /// provoke from a well-formed row.
    var incrementPendingSendAttemptCountFaultInjection: (@Sendable () throws -> Void)?

    /// Test-only hook at the top of `fetchDevice(id:)`. The pairing query skips that id on throw.
    var fetchDeviceByIDFaultInjection: (@Sendable () throws -> Void)?

    func setDeleteContactsFaultInjection(_ hook: (@Sendable () throws -> Void)?) {
      deleteContactsFaultInjection = hook
    }
  #endif

  /// Shared schema for Cairn models
  public static let schema = Schema([
    Device.self,
    Contact.self,
    Message.self,
    MessageRepeat.self,
    Reaction.self,
    Channel.self,
    RemoteNodeSession.self,
    RoomMessage.self,
    SavedTracePath.self,
    TracePathRun.self,
    RxLogEntry.self,
    DebugLogEntry.self,
    LinkPreviewData.self,
    DiscoveredNode.self,
    NodeStatusSnapshot.self,
    BlockedChannelSender.self,
    PendingSend.self,
    NeighbourLink.self,
    ObservedNodeRecord.self,
    TripLog.self,
    TripLogPoint.self,
    DailySteps.self
  ])

  /// The on-disk store's name: `Cairn.store` in the app's own Application Support.
  static let storeName = "Cairn"

  /// The database file, in the app's own container. Never the App Group's: iOS kills an app that
  /// is suspended while it holds a lock on a shared-container file (see ``StoreRelocation``).
  public static var storeURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appending(path: "\(storeName).store", directoryHint: .notDirectory)
  }

  /// Creates a ModelContainer for the app. Schema changes rely on SwiftData's lightweight
  /// migration.
  ///
  /// - Parameter legacyAppGroupID: The App Group whose container builds 1.4 (3) to 1.5 (4) kept the
  ///   database in. A copy found there is moved to ``storeURL`` before the store opens; a failed
  ///   move throws, and nothing is opened.
  public static func createContainer(
    inMemory: Bool = false,
    legacyAppGroupID: String? = nil,
    defaults: UserDefaults = .standard
  ) throws -> ModelContainer {
    if inMemory {
      let configuration = ModelConfiguration(
        storeName,
        schema: schema,
        isStoredInMemoryOnly: true,
        allowsSave: true,
        groupContainer: .none,
        cloudKitDatabase: .none
      )
      return try ModelContainer(for: schema, configurations: [configuration])
    }

    let url = storeURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let legacyAppGroupID,
       let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: legacyAppGroupID) {
      try StoreRelocation.relocate(
        from: StoreRelocation.groupStoreURL(groupContainer: group, storeName: storeName),
        to: url,
        defaults: defaults
      )
    }

    // The URL is given, not derived: with an App Group entitlement SwiftData's default location
    // is the group container.
    let configuration = ModelConfiguration(
      storeName,
      schema: schema,
      url: url,
      allowsSave: true,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  // MARK: - Database Warm-up

  /// Forces SwiftData to initialize the database.
  /// Call this early in app lifecycle to avoid lazy initialization during user operations.
  public func warmUp() throws {
    // Perform a simple fetch to trigger modelContext initialization
    _ = try modelContext.fetchCount(FetchDescriptor<Device>())

    // Idempotent: purgeOrphanPendingSends filters by absence of a matching
    // Device.radioID and returns an empty row set once Device rows catch
    // up. Running it on every connect costs an empty fetch and self-heals
    // the "erase device then re-pair" path — a process-level latch would
    // suppress that recovery.
    let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "PersistenceStore.warmUp")
    do {
      try purgeOrphanPendingSends()
    } catch {
      logger.warning("purgeOrphanPendingSends failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Discovered Nodes

  /// Per-radio cap for the discover list. Public so UI copy and import trim share one source of truth.
  public static let maxDiscoveredNodes = 1000

  /// Inbound advert hop counts heard via the RX log before the matching node row exists.
  /// The firmware emits the 0x88 RX packet before the 0x80 advert push that creates the row,
  /// so a keyed write would otherwise miss on first contact. Buffered here and drained by the
  /// upsert when the row lands. Bounded; the partner advert normally drains an entry at once.
  private var pendingInboundHops: [PendingHopKey: PendingHop] = [:]
  private let maxPendingInboundHops = 256

  private struct PendingHopKey: Hashable {
    let radioID: UUID
    let publicKey: Data
  }

  private struct PendingHop {
    let hopCount: Int
    let advertTimestamp: UInt32?
  }

  public func upsertDiscoveredNode(radioID: UUID, from frame: ContactFrame) throws -> (node: DiscoveredNodeDTO, isNew: Bool) {
    let targetRadioID = radioID
    let publicKey = frame.publicKey
    let predicate = #Predicate<DiscoveredNode> { node in
      node.radioID == targetRadioID && node.publicKey == publicKey
    }
    var descriptor = FetchDescriptor<DiscoveredNode>(predicate: predicate)
    descriptor.fetchLimit = 1
    let existing = try modelContext.fetch(descriptor)

    let node: DiscoveredNode
    let isNew: Bool
    if let existingNode = existing.first {
      existingNode.name = frame.name
      existingNode.typeRawValue = frame.type.rawValue
      // Callers hear the node now (0x8A, a discovery reply). A refresh from stored radio
      // fields goes through `touchContactHeard`, which keeps the real heard time.
      existingNode.lastHeard = max(existingNode.lastHeard, Date())
      existingNode.lastAdvertTimestamp = frame.lastAdvertTimestamp
      existingNode.latitude = frame.latitude
      existingNode.longitude = frame.longitude
      existingNode.outPathLength = Int(frame.outPathLength)
      existingNode.outPath = frame.outPath
      node = existingNode
      isNew = false
    } else {
      node = DiscoveredNode(
        radioID: radioID,
        publicKey: frame.publicKey,
        name: frame.name,
        typeRawValue: frame.type.rawValue,
        lastAdvertTimestamp: frame.lastAdvertTimestamp,
        latitude: frame.latitude,
        longitude: frame.longitude,
        outPathLength: frame.outPathLength,
        outPath: frame.outPath
      )
      modelContext.insert(node)
      isNew = true

      try enforceDiscoveredNodeCap(radioID: radioID)
    }

    applyPendingInboundHop(to: node)

    if isNew {
      try modelContext.save()
      discoveredNodeFlushTask?.cancel()
      discoveredNodeFlushTask = nil
    } else {
      // Reads on this context already see the change; the coalesced save
      // publishes it to other contexts within `discoveredNodeFlushInterval`.
      scheduleDiscoveredNodeFlush()
    }

    return (node: DiscoveredNodeDTO(from: node), isNew: isNew)
  }

  private func scheduleDiscoveredNodeFlush() {
    guard discoveredNodeFlushTask == nil else { return }
    discoveredNodeFlushTask = Task {
      try? await Task.sleep(for: Self.discoveredNodeFlushInterval)
      guard !Task.isCancelled else { return }
      self.flushPendingDiscoveredNodeChanges()
    }
  }

  /// Saves batched discovered-node updates now. Also run by the teardown
  /// flush (`flushPendingRxLogEntries`) so a disconnect doesn't drop them.
  func flushPendingDiscoveredNodeChanges() {
    discoveredNodeFlushTask?.cancel()
    discoveredNodeFlushTask = nil
    guard modelContext.hasChanges else { return }
    do {
      try modelContext.save()
    } catch {
      Logger(subsystem: "cvhvisuals.Cairn", category: "PersistenceStore")
        .error("Failed to save batched discovered node updates: \(error.localizedDescription)")
    }
  }

  public func setInboundHopCount(radioID: UUID, publicKey: Data, hopCount: Int, advertTimestamp: UInt32?) throws {
    let targetRadioID = radioID
    let targetKey = publicKey
    let predicate = #Predicate<DiscoveredNode> { node in
      node.radioID == targetRadioID && node.publicKey == targetKey
    }
    var descriptor = FetchDescriptor<DiscoveredNode>(predicate: predicate)
    descriptor.fetchLimit = 1
    // No row yet: buffer the pair so the advert upsert drains it on first contact.
    guard let node = try modelContext.fetch(descriptor).first else {
      bufferPendingInboundHop(radioID: targetRadioID, publicKey: targetKey, hopCount: hopCount, advertTimestamp: advertTimestamp)
      return
    }
    guard let adopted = adoptInboundHop(
      storedHops: node.inboundHopCount,
      storedTimestamp: node.inboundHopAdvertTimestamp,
      incomingHops: hopCount,
      incomingTimestamp: advertTimestamp
    ) else {
      return
    }
    node.inboundHopCount = adopted.hopCount
    node.inboundHopAdvertTimestamp = adopted.advertTimestamp
    try modelContext.save()
  }

  /// Stash an inbound hop count heard before its node row exists. Applies the same adopt rule
  /// as the live-row path. Evicts an arbitrary entry past the cap so a flood of never-resolved
  /// adverts can't grow this without bound.
  private func bufferPendingInboundHop(radioID: UUID, publicKey: Data, hopCount: Int, advertTimestamp: UInt32?) {
    let key = PendingHopKey(radioID: radioID, publicKey: publicKey)
    let existing = pendingInboundHops[key]
    guard let adopted = adoptInboundHop(
      storedHops: existing?.hopCount,
      storedTimestamp: existing?.advertTimestamp,
      incomingHops: hopCount,
      incomingTimestamp: advertTimestamp
    ) else { return }
    if existing == nil,
       pendingInboundHops.count >= maxPendingInboundHops,
       let evicted = pendingInboundHops.keys.first {
      pendingInboundHops.removeValue(forKey: evicted)
    }
    pendingInboundHops[key] = PendingHop(hopCount: adopted.hopCount, advertTimestamp: adopted.advertTimestamp)
  }

  /// Apply and clear any inbound hop count buffered before this row existed.
  private func applyPendingInboundHop(to node: DiscoveredNode) {
    let key = PendingHopKey(radioID: node.radioID, publicKey: node.publicKey)
    guard let buffered = pendingInboundHops.removeValue(forKey: key) else { return }
    if let adopted = adoptInboundHop(
      storedHops: node.inboundHopCount,
      storedTimestamp: node.inboundHopAdvertTimestamp,
      incomingHops: buffered.hopCount,
      incomingTimestamp: buffered.advertTimestamp
    ) {
      node.inboundHopCount = adopted.hopCount
      node.inboundHopAdvertTimestamp = adopted.advertTimestamp
    }
  }

  private func enforceDiscoveredNodeCap(radioID: UUID) throws {
    let targetRadioID = radioID
    let countPredicate = #Predicate<DiscoveredNode> { $0.radioID == targetRadioID }
    let countDescriptor = FetchDescriptor<DiscoveredNode>(predicate: countPredicate)
    let count = try modelContext.fetchCount(countDescriptor)

    if count > Self.maxDiscoveredNodes {
      var oldestDescriptor = FetchDescriptor<DiscoveredNode>(
        predicate: countPredicate,
        sortBy: [SortDescriptor(\.lastHeard, order: .forward)]
      )
      oldestDescriptor.fetchLimit = count - Self.maxDiscoveredNodes
      let toDelete = try modelContext.fetch(oldestDescriptor)
      for node in toDelete {
        modelContext.delete(node)
      }
      let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "PersistenceStore")
      logger.warning("DiscoveredNode cap exceeded, evicted \(toDelete.count) oldest nodes")
    }
  }

  public func fetchDiscoveredNodes(radioID: UUID) throws -> [DiscoveredNodeDTO] {
    let targetRadioID = radioID
    let predicate = #Predicate<DiscoveredNode> { $0.radioID == targetRadioID }
    let descriptor = FetchDescriptor<DiscoveredNode>(predicate: predicate)
    let nodes = try modelContext.fetch(descriptor)
    return nodes.map { DiscoveredNodeDTO(from: $0) }
  }

  public func deleteDiscoveredNode(id: UUID) throws {
    let targetID = id
    let predicate = #Predicate<DiscoveredNode> { $0.id == targetID }
    var descriptor = FetchDescriptor<DiscoveredNode>(predicate: predicate)
    descriptor.fetchLimit = 1
    if let node = try modelContext.fetch(descriptor).first {
      modelContext.delete(node)
      try modelContext.save()
    }
  }

  /// Deletes the heard records of the given nodes on one radio, in one save: deleting a node
  /// forgets it (`ContactService.removeContact`), and without this its heard record would put it
  /// straight back on the maps and the Heard list. A node heard again afterwards gets a new record.
  /// - Returns: How many records were deleted.
  @discardableResult
  public func deleteDiscoveredNodes(radioID: UUID, publicKeys: Set<Data>) throws -> Int {
    guard !publicKeys.isEmpty else { return 0 }
    let targetRadioID = radioID
    let predicate = #Predicate<DiscoveredNode> { $0.radioID == targetRadioID }
    let nodes = try modelContext.fetch(FetchDescriptor<DiscoveredNode>(predicate: predicate))
    var deleted = 0
    for node in nodes where publicKeys.contains(node.publicKey) {
      modelContext.delete(node)
      deleted += 1
    }
    if deleted > 0 {
      try modelContext.save()
    }
    return deleted
  }

  public func clearDiscoveredNodes(radioID: UUID) throws {
    let targetRadioID = radioID
    let predicate = #Predicate<DiscoveredNode> { $0.radioID == targetRadioID }
    let descriptor = FetchDescriptor<DiscoveredNode>(predicate: predicate)
    let nodes = try modelContext.fetch(descriptor)
    for node in nodes {
      modelContext.delete(node)
    }
    try modelContext.save()
  }
}
