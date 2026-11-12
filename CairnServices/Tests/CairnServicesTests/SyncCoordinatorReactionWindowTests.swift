import Foundation
@testable import CairnServices
import MeshCoreTestSupport
import Testing

@Suite("SyncCoordinator Reaction Timestamp Window")
@MainActor
struct SyncCoordinatorReactionWindowTests {
  /// Largest millisecond timestamp that `parseV1` still accepts; it divides to `UInt32.max` seconds.
  private static let maxTimestampReaction = "r:4294967295000_1_1:x"

  private func createTestDataStore(radioID: UUID) async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    try await store.saveDevice(DeviceDTO.testDevice(id: radioID, nodeName: "TestNode"))
    return store
  }

  private func createDependencies(dataStore: PersistenceStore) async throws -> SyncDependencies {
    let session = MeshCoreSession(transport: SimulatorMockTransport())
    let services = try await ServiceContainer.forTesting(session: session)
    return services.syncDependencies.with(
      dataStore: dataStore,
      messagePollingService: MockMessagePollingService()
    )
  }

  @Test
  func `window saturates at the top of the UInt32 range`() async {
    let coordinator = SyncCoordinator()
    let seconds = await coordinator.reactionTimestampWindowSeconds
    let window = await coordinator.reactionTimestampWindow(anchor: .max)

    #expect(window.upperBound == UInt32.max)
    #expect(window.lowerBound == UInt32.max - seconds)
  }

  @Test
  func `window saturates at the bottom of the UInt32 range`() async {
    let coordinator = SyncCoordinator()
    let seconds = await coordinator.reactionTimestampWindowSeconds
    let window = await coordinator.reactionTimestampWindow(anchor: 0)

    #expect(window.lowerBound == 0)
    #expect(window.upperBound == seconds)
  }

  @Test
  func `window is symmetric around an ordinary anchor`() async {
    let coordinator = SyncCoordinator()
    let seconds = await coordinator.reactionTimestampWindowSeconds
    let anchor: UInt32 = 1_704_000_000
    let window = await coordinator.reactionTimestampWindow(anchor: anchor)

    #expect(window.lowerBound == anchor - seconds)
    #expect(window.upperBound == anchor + seconds)
  }

  @Test
  func `channel v1 reaction with the maximum timestamp is consumed without trapping`() async throws {
    let parsed = try #require(MeshCoreOpenReactionParser.parseV1(Self.maxTimestampReaction))
    #expect(parsed.timestampSeconds == UInt32.max)

    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)
    let dependencies = try await createDependencies(dataStore: dataStore)
    let coordinator = SyncCoordinator()

    let consumed = await coordinator.handleChannelReaction(
      text: Self.maxTimestampReaction,
      channelIndex: 0,
      senderNodeName: "NodeAlpha",
      selfNodeName: "TestNode",
      receiveTime: Date(),
      radioID: radioID,
      dependencies: dependencies
    )

    #expect(consumed)
  }

  @Test
  func `DM v1 reaction with the maximum timestamp is consumed without trapping`() async throws {
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)
    let dependencies = try await createDependencies(dataStore: dataStore)
    let contact = ContactDTO.testContact(radioID: radioID)
    let coordinator = SyncCoordinator()

    let consumed = await coordinator.handleDMReaction(
      text: Self.maxTimestampReaction,
      contact: contact,
      radioID: radioID,
      dependencies: dependencies
    )

    #expect(consumed)
  }
}
