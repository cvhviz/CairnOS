import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// A reconnect to the radio this session already read (a link that dropped while the app was
/// in the background, a WiFi socket iOS closed while suspended) checks the stored channel table
/// against the radio with a few reads, and reads every slot only when something changed.
@Suite("Reconnect channel verification")
struct ReconnectChannelVerifyTests {
  private let secretA = Data(repeating: 0xA1, count: 16)
  private let secretB = Data(repeating: 0xB2, count: 16)

  /// A store holding "Public" in slot 0 and "Hike" in slot 2 of an 8-slot radio.
  private func storeWithChannels(radioID: UUID) async throws -> PersistenceStore {
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 0, name: "Public", secret: secretA))
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 2, name: "Hike", secret: secretB))
    return store
  }

  /// A session whose radio holds the same two channels as `storeWithChannels`.
  private func matchingSession() async -> MockMeshCoreSession {
    let session = MockMeshCoreSession()
    await session.setStubbedChannels([
      0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA),
      2: MeshCore.ChannelInfo(index: 2, name: "Hike", secret: secretB)
    ])
    return session
  }

  // MARK: - ChannelService.verifyChannels

  @Test
  func `matching radio is verified from the occupied slots and the first empty one`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let session = await matchingSession()
    let service = ChannelService(session: session, dataStore: store, rxLogService: nil)

    let result = try await service.verifyChannels(radioID: radioID, maxChannels: 8)

    #expect(result == .unchanged(slotsRead: 3))
    #expect(await session.getChannelIndices == [0, 2, 1])
  }

  @Test
  func `a channel joined on the radio's screen is caught in the first empty slot`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let session = await matchingSession()
    await session.setStubbedChannels([
      0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA),
      1: MeshCore.ChannelInfo(index: 1, name: "#new", secret: Data(repeating: 0xC3, count: 16)),
      2: MeshCore.ChannelInfo(index: 2, name: "Hike", secret: secretB)
    ])
    let service = ChannelService(session: session, dataStore: store, rxLogService: nil)

    let result = try await service.verifyChannels(radioID: radioID, maxChannels: 8)

    #expect(!result.isUnchanged)
  }

  @Test
  func `an edited or left channel is a change`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)

    let edited = MockMeshCoreSession()
    await edited.setStubbedChannels([
      0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA),
      2: MeshCore.ChannelInfo(index: 2, name: "Hike", secret: Data(repeating: 0xEE, count: 16))
    ])
    let editedResult = try await ChannelService(session: edited, dataStore: store, rxLogService: nil)
      .verifyChannels(radioID: radioID, maxChannels: 8)
    #expect(!editedResult.isUnchanged)

    let left = MockMeshCoreSession()
    await left.setStubbedChannels([0: MeshCore.ChannelInfo(index: 0, name: "Public", secret: secretA)])
    let leftResult = try await ChannelService(session: left, dataStore: store, rxLogService: nil)
      .verifyChannels(radioID: radioID, maxChannels: 8)
    #expect(!leftResult.isUnchanged)
  }

  @Test
  func `verification never writes the store`() async throws {
    let radioID = UUID()
    let store = try await storeWithChannels(radioID: radioID)
    let session = MockMeshCoreSession() // the radio reports every slot empty
    let service = ChannelService(session: session, dataStore: store, rxLogService: nil)

    let result = try await service.verifyChannels(radioID: radioID, maxChannels: 8)

    #expect(!result.isUnchanged)
    #expect(try await store.fetchChannels(radioID: radioID).map(\.index).sorted() == [0, 2])
  }

  @Test
  func `no stored channels means a full read, without touching the radio`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    let session = MockMeshCoreSession()
    let service = ChannelService(session: session, dataStore: store, rxLogService: nil)

    let result = try await service.verifyChannels(radioID: radioID, maxChannels: 8)

    #expect(!result.isUnchanged)
    #expect(await session.getChannelIndices.isEmpty)
  }

  @Test
  func `verification slots cover occupied slots, then the first empty one`() {
    #expect(ChannelService.verificationSlots(localIndices: [3, 0, 1], maxChannels: 8) == [0, 1, 3, 2])
    #expect(ChannelService.verificationSlots(localIndices: [0, 1, 2], maxChannels: 3) == [0, 1, 2])
    #expect(ChannelService.verificationSlots(localIndices: [5], maxChannels: 4) == nil)
  }

  // MARK: - SyncCoordinator

  @Test
  func `reconnect past the skip window verifies instead of reading every slot`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.unchanged(slotsRead: 3)))

    let result = try await SyncCoordinator().performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: ChannelSyncConfig(
        channelSyncSkipWindow: .seconds(30),
        cleanChannelSyncSkipWindow: .seconds(300),
        lastCleanChannelSync: Date().addingTimeInterval(-600)
      )
    )

    #expect(await channels.verifyInvocations.count == 1)
    #expect(await channels.syncChannelsInvocations.isEmpty)
    #expect(result.channels == .clean)
  }

  @Test
  func `a change found by verification reads every slot`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.changed(reason: "slot 1 now holds a channel")))

    try await SyncCoordinator().performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: ChannelSyncConfig(lastCleanChannelSync: Date().addingTimeInterval(-600))
    )

    #expect(await channels.verifyInvocations.count == 1)
    #expect(await channels.syncChannelsInvocations.count == 1)
  }

  @Test
  func `a failed verification falls back to reading every slot`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.failure(ChannelServiceError.sessionError(.timeout)))

    try await SyncCoordinator().performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService(),
      channelSyncConfig: ChannelSyncConfig(lastCleanChannelSync: Date().addingTimeInterval(-600))
    )

    #expect(await channels.syncChannelsInvocations.count == 1)
  }

  @Test
  func `first connect and forced full sync read every slot without verifying`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.unchanged(slotsRead: 1)))

    try await SyncCoordinator().performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService()
    )
    try await SyncCoordinator().performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService(),
      forceFullSync: true,
      channelSyncConfig: ChannelSyncConfig(lastCleanChannelSync: Date().addingTimeInterval(-600))
    )

    #expect(await channels.verifyInvocations.isEmpty)
    #expect(await channels.syncChannelsInvocations.count == 2)
  }

  // MARK: - Background connects

  @Test
  func `a background reconnect inside the clean window owes no channel sync`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let coordinator = SyncCoordinator()

    try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: MockChannelService(),
      messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: ChannelSyncConfig(
        cleanChannelSyncSkipWindow: .seconds(300),
        lastCleanChannelSync: Date().addingTimeInterval(-60)
      )
    )

    #expect(await coordinator.channelSyncPendingRadioID == nil)
  }

  @Test
  func `the channel sync a background reconnect owes is verified on return`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let coordinator = SyncCoordinator()
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.unchanged(slotsRead: 2)))

    try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false),
      channelSyncConfig: ChannelSyncConfig(
        cleanChannelSyncSkipWindow: .seconds(300),
        lastCleanChannelSync: Date().addingTimeInterval(-900)
      )
    )
    #expect(await coordinator.channelSyncPendingRadioID == radioID)

    let ran = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID,
      dataStore: store,
      channelService: channels,
      rxLogService: nil
    )

    #expect(ran)
    #expect(await channels.verifyInvocations.count == 1)
    #expect(await channels.syncChannelsInvocations.isEmpty)
    #expect(await coordinator.channelSyncPendingRadioID == nil)
  }

  @Test
  func `a radio first synced in the background still gets every slot read on return`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let coordinator = SyncCoordinator()
    let channels = MockChannelService()
    await channels.setStubbedVerifyResult(.success(.unchanged(slotsRead: 1)))

    try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channels,
      messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false)
    )
    _ = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID,
      dataStore: store,
      channelService: channels,
      rxLogService: nil
    )

    #expect(await channels.verifyInvocations.isEmpty)
    #expect(await channels.syncChannelsInvocations.count == 1)
  }

  // MARK: - WiFi fast reconnect window

  @Test
  @MainActor
  func `a fast WiFi window frozen by suspension still makes its attempts`() {
    // Ten minutes suspended after one attempt: not spent yet.
    #expect(!ConnectionManager.isFastWiFiReconnectWindowSpent(elapsed: .seconds(600), attempts: 1))
    // Duration passed and the minimum attempts made: spent.
    #expect(ConnectionManager.isFastWiFiReconnectWindowSpent(
      elapsed: .seconds(31),
      attempts: ConnectionManager.wifiMinFastReconnectAttempts
    ))
    // Many quick attempts inside the duration: still running.
    #expect(!ConnectionManager.isFastWiFiReconnectWindowSpent(elapsed: .seconds(10), attempts: 10))
  }
}
