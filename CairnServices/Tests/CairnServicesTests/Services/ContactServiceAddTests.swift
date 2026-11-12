import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// `ContactService.addOrUpdateContact` on a radio holding a temporary entry for the key, left by
/// an anonymous request. Firmware 1.16+ keeps those in reserved slots that contact sync skips, so
/// an add that updated the entry in place never synced and kept showing as addable.
@Suite("ContactService Add Tests")
struct ContactServiceAddTests {
  private let repeaterKey = Data(repeating: 0x5A, count: ProtocolLimits.publicKeySize)

  private func makeStore(radioID: UUID, firmwareVersion: UInt8, firmwareVersionString: String) async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    try await store.saveDevice(DeviceDTO.testDevice(
      id: radioID,
      radioID: radioID,
      firmwareVersion: firmwareVersion,
      firmwareVersionString: firmwareVersionString
    ))
    return store
  }

  private func placeholder(_ key: Data) -> MeshContact {
    MeshContact(
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

  private func repeaterFrame() -> ContactFrame {
    ContactFrame(
      publicKey: repeaterKey,
      type: .repeater,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      name: "Hilltop",
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0
    )
  }

  @Test
  func `Add pushes the temporary entry out of the reserved slots first`() async throws {
    let radioID = UUID()
    let store = try await makeStore(radioID: radioID, firmwareVersion: 13, firmwareVersionString: "v1.16.0")
    let session = MockMeshCoreSession()
    await session.setStubbedContact(placeholder(repeaterKey), for: repeaterKey)
    await session.setPlaceholdersRecycleAfterAdds(3)

    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    try await service.addOrUpdateContact(radioID: radioID, contact: repeaterFrame())

    let added = await session.addContactInvocations.map(\.contact)
    #expect(added.count == 4)
    let fillers = added.dropLast()
    #expect(fillers.allSatisfy { $0.isTemporaryPlaceholder && $0.publicKey != repeaterKey })
    #expect(Set(fillers.map(\.publicKey)).count == fillers.count)
    #expect(added.last?.publicKey == repeaterKey)
    #expect(added.last?.advertisedName == "Hilltop")
    #expect(try await store.fetchContact(radioID: radioID, publicKey: repeaterKey) != nil)
  }

  @Test
  func `Add gives up evicting after a bounded number of writes and still adds`() async throws {
    let radioID = UUID()
    let store = try await makeStore(radioID: radioID, firmwareVersion: 13, firmwareVersionString: "v1.16.0")
    let session = MockMeshCoreSession()
    await session.setStubbedContact(placeholder(repeaterKey), for: repeaterKey)

    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    try await service.addOrUpdateContact(radioID: radioID, contact: repeaterFrame())

    let added = await session.addContactInvocations.map(\.contact)
    #expect(added.count == ContactService.maxTemporaryEntryEvictionWrites + 1)
    #expect(added.last?.publicKey == repeaterKey)
  }

  @Test
  func `Add writes no filler when the radio holds no temporary entry`() async throws {
    let radioID = UUID()
    let store = try await makeStore(radioID: radioID, firmwareVersion: 13, firmwareVersionString: "v1.16.0")
    let session = MockMeshCoreSession()
    await session.setStubbedContact(nil, for: repeaterKey)

    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    try await service.addOrUpdateContact(radioID: radioID, contact: repeaterFrame())

    let added = await session.addContactInvocations.map(\.contact)
    #expect(added.map(\.publicKey) == [repeaterKey])
  }

  @Test
  func `Add on a radio before 1.16 updates its placeholder in place`() async throws {
    let radioID = UUID()
    let store = try await makeStore(radioID: radioID, firmwareVersion: 9, firmwareVersionString: "v1.13.0")
    let session = MockMeshCoreSession()
    await session.setStubbedContact(placeholder(repeaterKey), for: repeaterKey)

    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    try await service.addOrUpdateContact(radioID: radioID, contact: repeaterFrame())

    let added = await session.addContactInvocations.map(\.contact)
    #expect(added.map(\.publicKey) == [repeaterKey])
    // No eviction lookups: the one read is the remote-commands check every add makes.
    #expect(await session.getContactPublicKeys == [repeaterKey])
  }
}
