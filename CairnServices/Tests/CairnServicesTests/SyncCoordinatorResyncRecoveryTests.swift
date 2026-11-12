import Foundation
@testable import CairnServices
import MeshCore
import MeshCoreTestSupport
import Testing

/// Covers what a connection recovered by resync must still end up with: a
/// running message auto-fetch, a private-key export that respects the
/// transport, and an RX log channel cache that survives duplicate slot rows.
@Suite("SyncCoordinator Resync Recovery Tests")
@MainActor
struct SyncCoordinatorResyncRecoveryTests {
  // MARK: - Test Helpers

  private func createTestServices() async throws -> (MeshCoreSession, ServiceContainer) {
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "ResyncRecoveryTest")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    return (session, services)
  }

  /// Sync dependencies whose sync phases run against mocks, so a resync or a
  /// connection setup completes without a radio.
  private func makeDependencies(
    from services: ServiceContainer,
    dataStore: any PersistenceStoreProtocol,
    contactService: MockContactService = MockContactService(),
    messagePollingService: any MessagePollingServiceProtocol,
    exportPrivateKey: @escaping @Sendable () async throws -> Data = { Data(repeating: 0x07, count: 64) }
  ) -> SyncDependencies {
    let base = services.syncDependencies
    return SyncDependencies(
      dataStore: dataStore,
      contactService: contactService,
      channelService: MockChannelService(),
      messagePollingService: messagePollingService,
      notificationService: base.notificationService,
      reactionService: base.reactionService,
      advertisementService: base.advertisementService,
      rxLogService: base.rxLogService,
      heardRepeatsService: base.heardRepeatsService,
      roomServerService: base.roomServerService,
      roomAdminService: base.roomAdminService,
      repeaterAdminService: base.repeaterAdminService,
      appStateProvider: nil,
      startEventMonitoring: { _, _ in },
      exportPrivateKey: exportPrivateKey
    )
  }

  // MARK: - Auto-fetch after resync

  @Test
  func `successful resync starts auto-fetch and drains`() async throws {
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MockMessagePollingService()
    let coordinator = SyncCoordinator()

    let succeeded = await coordinator.performResync(
      radioID: radioID,
      dependencies: makeDependencies(from: services, dataStore: dataStore, messagePollingService: polling)
    )

    #expect(succeeded)
    #expect(await polling.pauseAutoFetchCallCount == 0, "auto-fetch stays on through a resync")
    #expect(await polling.requestDrainCallCount == 1)
    #expect(
      await polling.startAutoFetchRadioIDs == [radioID],
      "A resync that recovers a failed initial sync must start auto-fetch, which the initial sync never reached"
    )
  }

  /// A resync whose contact phase fails must still leave the radio's queue drained: auto-fetch
  /// on (started if the initial sync never got that far) and a drain requested.
  @Test
  func `failed resync still starts auto-fetch and drains`() async throws {
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MockMessagePollingService()
    let contactService = MockContactService()
    await contactService.setStubbedSyncContactsResult(.failure(SyncCoordinatorError.syncFailed("contacts saturated")))
    let coordinator = SyncCoordinator()

    let succeeded = await coordinator.performResync(
      radioID: radioID,
      dependencies: makeDependencies(
        from: services,
        dataStore: dataStore,
        contactService: contactService,
        messagePollingService: polling
      )
    )

    #expect(!succeeded)
    #expect(await polling.pauseAutoFetchCallCount == 0)
    #expect(await polling.startAutoFetchRadioIDs == [radioID])
    #expect(await polling.requestDrainCallCount == 1)
  }

  /// The defect end to end: with auto-fetch never started, `resumeAutoFetch`
  /// alone leaves the real polling service idle.
  @Test
  func `resync enables auto-fetch on a polling service that never started it`() async throws {
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = services.messagePollingService
    #expect(await polling.isAutoFetching == false)
    let coordinator = SyncCoordinator()

    let succeeded = await coordinator.performResync(
      radioID: radioID,
      dependencies: makeDependencies(from: services, dataStore: dataStore, messagePollingService: polling)
    )

    #expect(succeeded)
    #expect(await polling.isAutoFetching)

    await polling.stopAutoFetch()
  }

  // MARK: - Private key export

  @Test
  func `connection setup over WiFi does not export the private key`() async throws {
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let exportTracker = CallTracker()
    let coordinator = SyncCoordinator()
    let dependencies = makeDependencies(
      from: services,
      dataStore: dataStore,
      messagePollingService: MockMessagePollingService(),
      exportPrivateKey: {
        exportTracker.markCalled()
        return Data(repeating: 0x07, count: 64)
      }
    )

    try await coordinator.onConnectionEstablished(
      radioID: radioID,
      dependencies: dependencies,
      transportType: .wifi
    )

    #expect(exportTracker.callCount == 0, "The private key must not cross an unencrypted TCP link")
    #expect(await services.rxLogService.hasPrivateKey == false)

    await coordinator.cancelDiscoveryEventMonitoring()
  }

  @Test
  func `connection setup over Bluetooth exports the private key`() async throws {
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let exportTracker = CallTracker()
    let coordinator = SyncCoordinator()
    let dependencies = makeDependencies(
      from: services,
      dataStore: dataStore,
      messagePollingService: MockMessagePollingService(),
      exportPrivateKey: {
        exportTracker.markCalled()
        return Data(repeating: 0x07, count: 64)
      }
    )

    try await coordinator.onConnectionEstablished(
      radioID: radioID,
      dependencies: dependencies,
      transportType: .bluetooth
    )

    #expect(exportTracker.callCount == 1)
    #expect(await services.rxLogService.hasPrivateKey)

    await coordinator.cancelDiscoveryEventMonitoring()
  }

  // MARK: - Duplicate channel slots

  @Test
  func `full sync survives duplicate channel slot rows when refreshing the RX log cache`() async throws {
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    let store = MockPersistenceStore()
    try await store.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID))
    // Two rows claiming slot 1: the keyed-by-id mock can hold what a corrupt
    // store would.
    await store.seedChannels([
      ChannelDTO.testChannel(radioID: radioID, index: 1, name: "First", secret: Data(repeating: 0x11, count: 16)),
      ChannelDTO.testChannel(radioID: radioID, index: 1, name: "Second", secret: Data(repeating: 0x22, count: 16))
    ])
    let coordinator = SyncCoordinator()

    let result = try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: MockChannelService(),
      messagePollingService: MockMessagePollingService(),
      rxLogService: services.rxLogService
    )

    #expect(result.isConnectionUsable)
  }
}

private extension MockPersistenceStore {
  func seedChannels(_ seeded: [ChannelDTO]) {
    for channel in seeded {
      channels[channel.id] = channel
    }
  }
}
