import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// The light channel check across process lifetimes. iOS relaunches a terminated app in the
/// background (Bluetooth state restoration, the wake source's pending connect, a Background App
/// Refresh run), so the process the user opens is often new and has no in-memory clean record.
/// A clean read by the earlier process (`ConnectionManager.verifiedChannelTableRadioID`) lets that
/// background-started connect, and the foreground sync it leaves pending, check the stored copy
/// with a few reads instead of reading every slot. A visible foreground launch, a forced full
/// sync, a device switch and a radio whose channels changed still read every slot.
@Suite("Channel table trust across launches")
@MainActor
struct ChannelTableTrustTests {
  private let secretA = Data(repeating: 0xA1, count: 16)
  private let secretB = Data(repeating: 0xB2, count: 16)
  private let defaults = UserDefaults(suiteName: "test.channelTableTrust.\(UUID().uuidString)")!

  /// A store holding "Public" in slot 0 and "Hike" in slot 2 of an 8-slot radio: the clean copy
  /// an earlier process left.
  private func storeWithChannels(radioID: UUID) async throws -> PersistenceStore {
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 0, name: "Public", secret: secretA))
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 2, name: "Hike", secret: secretB))
    return store
  }

  /// A radio holding the same two channels as `storeWithChannels`.
  private func matchingSession() async -> MockMeshCoreSession {
    let session = MockMeshCoreSession()
    await session.setStubbedChannels([
      0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA),
      2: MeshCore.ChannelInfo(index: 2, name: "Hike", secret: secretB)
    ])
    return session
  }

  /// A coordinator wired by the real `ConnectionManager.wireCleanChannelSyncCallback`.
  private func wiredCoordinator(to manager: ConnectionManager) async throws -> SyncCoordinator {
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    await manager.wireCleanChannelSyncCallback(on: services)
    return services.syncCoordinator
  }

  /// A new process whose previous one read `radioID`'s channels cleanly.
  private func relaunchedManager(trusting radioID: UUID) throws -> ConnectionManager {
    let (previous, _) = try ConnectionManager.createForTesting(defaults: defaults)
    previous.verifiedChannelTableRadioID = radioID
    let (manager, _) = try ConnectionManager.createForTesting(defaults: defaults)
    return manager
  }

  // MARK: - Bookkeeping

  @Test
  func `a clean read is remembered across launches without feeding the skip window`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let (launch, _) = try ConnectionManager.createForTesting(defaults: defaults)
    let session = await matchingSession()
    try await wiredCoordinator(to: launch).performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: ChannelService(session: session, dataStore: store, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: launch.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(launch.verifiedChannelTableRadioID == radioID)

    // The next process: no in-memory record, so no skip, but the stored copy is trusted.
    let (relaunch, _) = try ConnectionManager.createForTesting(defaults: defaults)
    let config = relaunch.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    #expect(config.lastCleanChannelSync == nil)
    #expect(config.storedChannelTableVerified)
    #expect(!relaunch.currentChannelSyncConfig(for: UUID(), transportType: .bluetooth).storedChannelTableVerified)
  }

  @Test
  func `a partial read that rewrote rows withdraws the trust`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: radioID)
    manager.lastCleanChannelSync = (radioID: radioID, completedAt: Date().addingTimeInterval(-900))
    // "Hike" was left on the radio, and slot 3 holds a channel that does not answer.
    let session = MockMeshCoreSession()
    await session.setStubbedChannels([0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA)])
    await session.setStubbedGetChannelErrorsByIndex([3: MeshCoreError.deviceError(code: 3)])

    let result = try await wiredCoordinator(to: manager).performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: ChannelService(session: session, dataStore: store, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )

    #expect(result.channels == .partial)
    #expect(try await store.fetchChannels(radioID: radioID).map(\.index) == [0], "slot 2's row was deleted")
    // A check against this table would read slots 0 and 1 and pass, never reaching slot 3.
    #expect(manager.verifiedChannelTableRadioID == nil, "the mixed table must not be checked next launch")
    #expect(manager.lastCleanChannelSync == nil, "nor by the next reconnect in this process")
  }

  @Test
  func `a read that fails without changing the stored table keeps the trust`() async throws {
    let radioID = UUID()
    let lastClean = Date().addingTimeInterval(-900)

    // The link drops during the check, and the full read that follows throws.
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: radioID)
    manager.lastCleanChannelSync = (radioID: radioID, completedAt: lastClean)
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.failure(ChannelServiceError.sessionError(.timeout)))
    await channels.setSyncChannelsFailureForTrustTesting(ChannelServiceError.sessionError(.timeout))
    try await wiredCoordinator(to: manager).performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(await channels.syncChannelsInvocations.count == 1)
    #expect(manager.verifiedChannelTableRadioID == radioID, "a read that threw persisted nothing")
    #expect(manager.lastCleanChannelSync?.radioID == radioID)

    // Slot 2 does not answer the check or the full read; every slot that did matches the store.
    let partialManager = try relaunchedManager(trusting: radioID)
    partialManager.lastCleanChannelSync = (radioID: radioID, completedAt: lastClean)
    let session = await matchingSession()
    await session.setStubbedGetChannelErrorsByIndex([2: MeshCoreError.deviceError(code: 3)])
    let result = try await wiredCoordinator(to: partialManager).performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: ChannelService(session: session, dataStore: store, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: partialManager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(result.channels == .partial)
    #expect(await session.getChannelIndices.count > 2, "the failed check led to a full read")
    #expect(partialManager.verifiedChannelTableRadioID == radioID, "the stored table is still the clean copy")
    #expect(partialManager.lastCleanChannelSync?.radioID == radioID)
  }

  @Test
  func `a pending read that rewrote rows without finishing withdraws the trust`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: radioID)
    let session = MockMeshCoreSession()
    await session.setStubbedChannels([0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA)])
    await session.setStubbedGetChannelErrorsByIndex([3: MeshCoreError.deviceError(code: 3)])
    let channels = ChannelService(session: session, dataStore: store, rxLogService: nil)
    let coordinator = try await wiredCoordinator(to: manager)

    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    let clean = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )

    #expect(!clean)
    #expect(manager.verifiedChannelTableRadioID == nil)
  }

  // MARK: - Channel-only retry

  /// A full read that rewrote rows and timed out on slots 3 and 4 (and, with `unreadSlot`,
  /// circuit-broke slot 5); the connect's own retry timed out again, so the channel-only retry is
  /// left with `[3, 4]`.
  private func partialConnect(
    radioID: UUID,
    manager: ConnectionManager,
    channels: MockChannelService,
    unreadSlot: Bool
  ) async throws -> (SyncCoordinator, FullSyncResult, PersistenceStore) {
    let store = try await storeWithChannels(radioID: radioID)
    let timeouts = [3, 4].map { ChannelSyncError(index: $0, errorType: .timeout, description: "timeout") }
    let circuitBroken = ChannelSyncError(index: 5, errorType: .circuitBreaker, description: "circuit breaker")
    await channels.setResultsForTrustTesting(
      sync: ChannelSyncResult(
        channelsSynced: 1,
        errors: unreadSlot ? timeouts + [circuitBroken] : timeouts,
        changedStoredTable: true
      ),
      retry: ChannelSyncResult(channelsSynced: 0, errors: timeouts)
    )
    let coordinator = try await wiredCoordinator(to: manager)
    let result = try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    return (coordinator, result, store)
  }

  @Test
  func `a clean channel-only retry vouches for a table with every slot read`() async throws {
    let radioID = UUID()
    let manager = try relaunchedManager(trusting: radioID)
    let channels = MockChannelService()
    let (coordinator, connect, _) = try await partialConnect(
      radioID: radioID, manager: manager, channels: channels, unreadSlot: false
    )
    #expect(connect.channels == .partial)
    #expect(connect.channelRetryIndices == [3, 4])
    #expect(manager.verifiedChannelTableRadioID == nil, "the rewritten table is withdrawn until a clean read")

    await channels.setResultsForTrustTesting(retry: ChannelSyncResult(channelsSynced: 1, errors: []))
    let retry = await coordinator.retryChannels(radioID: radioID, channelService: channels, indices: [3, 4])

    #expect(retry.isComplete)
    #expect(manager.verifiedChannelTableRadioID == radioID)
    #expect(manager.lastCleanChannelSync?.radioID == radioID)
  }

  @Test
  func `a clean channel-only retry does not vouch for a table with a circuit-broken slot`() async throws {
    let radioID = UUID()
    let manager = try relaunchedManager(trusting: radioID)
    let channels = MockChannelService()
    let (coordinator, connect, store) = try await partialConnect(
      radioID: radioID, manager: manager, channels: channels, unreadSlot: true
    )
    #expect(connect.channels == .partial)
    #expect(connect.channelRetryIndices == [3, 4], "the circuit-broken slot 5 is never retried")
    #expect(manager.verifiedChannelTableRadioID == nil)

    await channels.setResultsForTrustTesting(retry: ChannelSyncResult(channelsSynced: 1, errors: []))
    let retry = await coordinator.retryChannels(radioID: radioID, channelService: channels, indices: [3, 4])

    #expect(retry.isComplete)
    // A check of this table would stop at its first empty slot and never reach a channel in 5.
    #expect(manager.verifiedChannelTableRadioID == nil, "slot 5 was never read")
    #expect(manager.lastCleanChannelSync == nil)

    // The next connect's full read reads slot 5 too, and a clean one vouches for the table again.
    await channels.setResultsForTrustTesting(sync: ChannelSyncResult(channelsSynced: 2, errors: []))
    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      forceFullSync: true,
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(manager.verifiedChannelTableRadioID == radioID)
  }

  @Test
  func `a slot the channel-only retry circuit-breaks keeps a later clean retry from vouching`() async throws {
    let radioID = UUID()
    let manager = try relaunchedManager(trusting: radioID)
    let channels = MockChannelService()
    let (coordinator, _, _) = try await partialConnect(
      radioID: radioID, manager: manager, channels: channels, unreadSlot: false
    )

    // The first retry times out on slot 3 and circuit-breaks slot 4, so the next asks only for 3.
    await channels.setResultsForTrustTesting(retry: ChannelSyncResult(channelsSynced: 0, errors: [
      ChannelSyncError(index: 3, errorType: .timeout, description: "timeout"),
      ChannelSyncError(index: 4, errorType: .circuitBreaker, description: "circuit breaker")
    ]))
    let first = await coordinator.retryChannels(radioID: radioID, channelService: channels, indices: [3, 4])
    #expect(first.retryableIndices == [3])

    await channels.setResultsForTrustTesting(retry: ChannelSyncResult(channelsSynced: 1, errors: []))
    let second = await coordinator.retryChannels(radioID: radioID, channelService: channels, indices: [3])

    #expect(second.isComplete)
    #expect(manager.verifiedChannelTableRadioID == nil, "slot 4 was never read")
    #expect(manager.lastCleanChannelSync == nil)
  }

  @Test
  func `explicit disconnects and forgetting clear the trust, transient drops keep it`() async throws {
    let radioID = UUID()
    for reason in [DisconnectReason.resyncFailed, .wifiAddressChange, .wifiReconnectPrep, .pairingFailed] {
      let manager = try relaunchedManager(trusting: radioID)
      manager.setTestState(connectionIntent: .wantsConnection())
      await manager.disconnect(reason: reason)
      #expect(manager.verifiedChannelTableRadioID == radioID, "\(reason) keeps the trust")
    }
    for reason in [DisconnectReason.userInitiated, .statusMenuDisconnectTap, .forgetDevice, .factoryReset, .switchingDevice] {
      let manager = try relaunchedManager(trusting: radioID)
      manager.setTestState(connectionIntent: .wantsConnection())
      await manager.disconnect(reason: reason)
      #expect(manager.verifiedChannelTableRadioID == nil, "\(reason) clears the trust")
    }
    let manager = try relaunchedManager(trusting: radioID)
    await manager.clearPersistedConnection(for: UUID())
    #expect(manager.verifiedChannelTableRadioID == nil, "forget / delete / removal from Settings clears it")
  }

  @Test
  func `switching device clears the trust`() async throws {
    let manager = try relaunchedManager(trusting: UUID())
    _ = try? await manager.switchDevice(to: UUID())
    #expect(manager.verifiedChannelTableRadioID == nil)
  }

  @Test
  func `importing a backup clears the trust`() async throws {
    let radioID = UUID()
    let suiteName = "test.channelTableTrust.backup.\(UUID().uuidString)"
    UserDefaults(suiteName: suiteName)?.set(radioID.uuidString, forKey: PersistenceKeys.verifiedChannelTableRadioID)
    let source = try await storeWithChannels(radioID: radioID)
    let envelope = try await parseBackup(data: AppBackupService().export(persistenceStore: source).data)

    let destination = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    try await Self.importBackup(envelope, into: destination, defaultsSuite: suiteName)

    #expect(UserDefaults(suiteName: suiteName)?.object(forKey: PersistenceKeys.verifiedChannelTableRadioID) == nil)
  }

  @Test
  func `a reconnect soon after a backup import reads every slot instead of skipping`() async throws {
    let radioID = UUID()
    let suiteName = "test.channelTableTrust.backupReconnect.\(UUID().uuidString)"
    let (manager, _) = try ConnectionManager.createForTesting(defaults: #require(UserDefaults(suiteName: suiteName)))
    // A clean read a minute ago: a transient reconnect now would skip the channel phase.
    manager.lastCleanChannelSync = (radioID: radioID, completedAt: Date().addingTimeInterval(-60))
    manager.verifiedChannelTableRadioID = radioID
    #expect(manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth).lastCleanChannelSync != nil)

    let source = try await storeWithChannels(radioID: radioID)
    let envelope = try await parseBackup(data: AppBackupService().export(persistenceStore: source).data)
    let destination = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    try await Self.importBackup(envelope, into: destination, defaultsSuite: suiteName)

    let config = manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    #expect(config.lastCleanChannelSync == nil, "the imported rows must not ride the skip window")
    #expect(!config.storedChannelTableVerified, "nor be checked as the radio's clean copy")
    #expect(manager.lastCleanChannelSync == nil, "the in-memory record goes with the persisted one")

    let session = await matchingSession()
    let result = try await wiredCoordinator(to: manager).performFullSync(
      radioID: radioID, dataStore: destination, contactService: MockContactService(),
      channelService: ChannelService(session: session, dataStore: destination, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: config
    )
    #expect(result.channels == .clean)
    #expect(await session.getChannelIndices.count == 8, "the channel phase reads every slot")
  }

  @Test
  func `an ESP32 reconnect soon after a backup import reads every slot instead of skipping`() async throws {
    let radioID = UUID()
    let suiteName = "test.channelTableTrust.backupReconnectESP32.\(UUID().uuidString)"
    let (manager, _) = try ConnectionManager.createForTesting(defaults: #require(UserDefaults(suiteName: suiteName)))
    // A channel phase began 10 s ago and did not finish cleanly (no marker): an ESP32 reconnect
    // now would skip the channel phase inside the 30 s attempted-sync window.
    manager.setTestState(
      detectedPlatform: .esp32,
      lastAttemptedChannelSync: (radioID: radioID, attemptedAt: Date().addingTimeInterval(-10))
    )
    #expect(manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth).lastAttemptedChannelSync != nil)

    let source = try await storeWithChannels(radioID: radioID)
    let envelope = try await parseBackup(data: AppBackupService().export(persistenceStore: source).data)
    let destination = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    try await Self.importBackup(envelope, into: destination, defaultsSuite: suiteName)

    let config = manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    #expect(config.channelSyncSkipWindow == .seconds(30))
    #expect(config.lastAttemptedChannelSync == nil, "the imported rows must not ride the attempted-sync window")
    #expect(manager.lastAttemptedChannelSync == nil, "the in-memory record goes with the import")

    let session = await matchingSession()
    let result = try await wiredCoordinator(to: manager).performFullSync(
      radioID: radioID, dataStore: destination, contactService: MockContactService(),
      channelService: ChannelService(session: session, dataStore: destination, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: config
    )
    #expect(result.channels == .clean)
    #expect(await session.getChannelIndices.count == 8, "the channel phase reads every slot")
    let next = manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    #expect(next.lastAttemptedChannelSync != nil, "records made after the import still count")
    #expect(next.lastCleanChannelSync != nil)
  }

  /// Imports off the main actor with its own handle on the defaults suite, so no
  /// non-Sendable `UserDefaults` crosses isolation.
  private nonisolated static func importBackup(
    _ envelope: AppBackupEnvelope,
    into store: PersistenceStore,
    defaultsSuite: String
  ) async throws {
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    try await AppBackupService().importBackup(envelope: envelope, into: store, defaults: defaults)
  }

  // MARK: - Background relaunch, then open

  @Test
  func `a background relaunch's open checks the stored copy with a few reads`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: radioID)
    let session = await matchingSession()
    let channels = ChannelService(session: session, dataStore: store, rxLogService: nil)
    let coordinator = try await wiredCoordinator(to: manager)

    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(await coordinator.channelSyncPendingRadioID == radioID)
    #expect(await coordinator.channelSyncPendingVerifiable)
    #expect(await session.getChannelIndices.isEmpty, "the background connect reads no channels")

    let clean = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )

    #expect(clean)
    #expect(await session.getChannelIndices == [0, 2, 1], "the 2 occupied slots and the first empty one")
    #expect(manager.lastCleanChannelSync?.radioID == radioID, "later reconnects in this process skip or check too")
    #expect(manager.verifiedChannelTableRadioID == radioID)
  }

  @Test
  func `opening during a background relaunch's contact phase checks instead of reading every slot`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: radioID)
    let session = await matchingSession()

    // In the background when the sync starts, in the foreground by the channel phase.
    let result = try await wiredCoordinator(to: manager).performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: ChannelService(session: session, dataStore: store, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      appStateProvider: SequencedAppStateProvider([false, true]),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )

    #expect(result.channels == .clean)
    #expect(await session.getChannelIndices == [0, 2, 1])
  }

  @Test
  func `a channel joined on the radio while the app was gone still gets every slot read`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: radioID)
    let session = MockMeshCoreSession()
    await session.setStubbedChannels([
      0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA),
      1: MeshCore.ChannelInfo(index: 1, name: "#new", secret: Data(repeating: 0xC3, count: 16)),
      2: MeshCore.ChannelInfo(index: 2, name: "Hike", secret: secretB)
    ])
    let channels = ChannelService(session: session, dataStore: store, rxLogService: nil)
    let coordinator = try await wiredCoordinator(to: manager)

    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    _ = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )

    let reads = await session.getChannelIndices
    #expect(Array(reads.prefix(3)) == [0, 2, 1], "the check runs first")
    #expect(Set(reads.dropFirst(3)) == Set(0 ..< 8), "and the change it finds reads every slot")
    #expect(try await store.fetchChannels(radioID: radioID).contains { $0.index == 1 && $0.name == "#new" })
  }

  @Test
  func `a visible launch and a forced full sync still read every slot`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)

    let manager = try relaunchedManager(trusting: radioID)
    let launchSession = await matchingSession()
    try await wiredCoordinator(to: manager).performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: ChannelService(session: launchSession, dataStore: store, rxLogService: nil),
      messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: true),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(await launchSession.getChannelIndices.count == 8, "a foreground launch reads every slot")

    let forced = try relaunchedManager(trusting: radioID)
    let coordinator = try await wiredCoordinator(to: forced)
    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: MockChannelService(), messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      forceFullSync: true,
      channelSyncConfig: forced.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(await coordinator.channelSyncPendingVerifiable == false, "a forced sync owes a full read")
  }

  @Test
  func `a background relaunch to a different radio reads every slot on open`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let manager = try relaunchedManager(trusting: UUID())
    let session = await matchingSession()
    let channels = ChannelService(session: session, dataStore: store, rxLogService: nil)
    let coordinator = try await wiredCoordinator(to: manager)

    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: manager.currentChannelSyncConfig(for: radioID, transportType: .bluetooth)
    )
    #expect(await coordinator.channelSyncPendingVerifiable == false)
    _ = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )
    #expect(await session.getChannelIndices.count == 8)
    #expect(manager.verifiedChannelTableRadioID == radioID, "the clean read now vouches for this radio")
  }

  // MARK: - Pending sync details

  @Test
  func `the pending full read keeps the transport's pipelined policy`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let coordinator = SyncCoordinator()
    let channels = MockChannelService()

    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: ChannelSyncConfig(usePipelinedChannelRead: true)
    )
    _ = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )

    #expect(await channels.syncChannelsInvocations.map(\.usePipelinedRead) == [true])
  }

  @Test
  func `a pending sync deferred by a running sync runs when that sync ends`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let coordinator = SyncCoordinator()
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.unchanged(slotsRead: 3)))
    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: ChannelSyncConfig(lastCleanChannelSync: Date().addingTimeInterval(-900))
    )

    await coordinator.setSyncInProgressForTrustTesting(true)
    let ranNow = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )
    #expect(!ranNow)
    #expect(await coordinator.channelSyncPendingRadioID == radioID)

    await coordinator.setSyncInProgressForTrustTesting(false)
    try await waitUntil { await coordinator.channelSyncPendingRadioID == nil }
    #expect(await channels.verifyInvocations.count == 1)
    #expect(await channels.syncChannelsInvocations.isEmpty)
  }

  @Test
  func `a deferred pending sync waits for the next foreground if the app left again`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let coordinator = SyncCoordinator()
    let channels = MockChannelService()
    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: ChannelSyncConfig(lastCleanChannelSync: Date().addingTimeInterval(-900))
    )
    let catchUpState = CountingAppStateProvider(isInForeground: false)
    await coordinator.setCatchUpAppStateProviderForTrustTesting(catchUpState)

    await coordinator.setSyncInProgressForTrustTesting(true)
    _ = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )
    await coordinator.setSyncInProgressForTrustTesting(false)
    // The deferred closure ran: it asked whether the app is still in the foreground.
    try await waitUntil { await catchUpState.queries > 0 }
    await Task.yield()

    #expect(await channels.verifyInvocations.isEmpty)
    #expect(await coordinator.channelSyncPendingRadioID == radioID, "still owed to the next foreground")
  }

  @Test
  func `a disconnect drops a deferred pending sync and the link it was deferred on`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let coordinator = services.syncCoordinator
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.unchanged(slotsRead: 3)))
    try await coordinator.performFullSync(
      radioID: radioID, dataStore: store, contactService: MockContactService(),
      channelService: channels, messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: ChannelSyncConfig(lastCleanChannelSync: Date().addingTimeInterval(-900))
    )
    let catchUpState = CountingAppStateProvider(isInForeground: true)
    await coordinator.setCatchUpAppStateProviderForTrustTesting(catchUpState)

    await coordinator.setSyncInProgressForTrustTesting(true)
    _ = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID, dataStore: store, channelService: channels, rxLogService: nil
    )
    // Kept aside to stand in for a claim released while `onDisconnected` was suspended.
    let deferred = try #require(await coordinator.deferredPendingChannelSync)

    await coordinator.onDisconnected(notificationService: services.notificationService)
    #expect(await coordinator.deferredPendingChannelSync == nil)
    #expect(await !coordinator.isSyncInProgress)

    await deferred()
    #expect(await catchUpState.queries == 0, "it stood down before anything else")
    #expect(await channels.verifyInvocations.isEmpty)
    #expect(await channels.syncChannelsInvocations.isEmpty)
  }

  private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @escaping () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("condition not met within \(timeout)")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// Answers a fixed foreground state and counts how often it was asked.
private actor CountingAppStateProvider: AppStateProvider {
  private let answer: Bool
  private(set) var queries = 0

  init(isInForeground: Bool) {
    answer = isInForeground
  }

  var isInForeground: Bool {
    get async {
      queries += 1
      return answer
    }
  }
}

/// Reports each foreground answer in turn, then keeps the last one.
private actor SequencedAppStateProvider: AppStateProvider {
  private var answers: [Bool]

  init(_ answers: [Bool]) {
    self.answers = answers
  }

  var isInForeground: Bool {
    get async {
      answers.count > 1 ? answers.removeFirst() : answers.first ?? true
    }
  }
}

extension SyncCoordinator {
  /// Stands in for a sync still holding the claim when the foreground catch-up fires.
  fileprivate func setSyncInProgressForTrustTesting(_ value: Bool) {
    isSyncInProgress = value
  }

  fileprivate func setCatchUpAppStateProviderForTrustTesting(_ provider: AppStateProvider) {
    catchUpAppStateProvider = provider
  }
}

extension MockChannelService {
  /// The next full read's and retry's results; `nil` keeps the current stub.
  fileprivate func setResultsForTrustTesting(sync: ChannelSyncResult? = nil, retry: ChannelSyncResult? = nil) {
    if let sync {
      stubbedSyncChannelsResult = .success(sync)
    }
    if let retry {
      stubbedRetryResult = .success(retry)
    }
  }

  /// A full read that throws, so nothing is persisted (like the real service's pipelined read
  /// when the link drops).
  fileprivate func setSyncChannelsFailureForTrustTesting(_ error: Error) {
    stubbedSyncChannelsResult = .failure(error)
  }
}
