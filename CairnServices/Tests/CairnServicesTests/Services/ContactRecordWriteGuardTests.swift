import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// The remote-commands permission (contact flag 0x10) can't come back through a full contact
/// record written from a stale, imported or scanned copy, and overlapping read-modify-write
/// changes for one contact apply in turn.
@Suite("ContactService record write guard")
struct ContactRecordWriteGuardTests {
  private let publicKey = Data((0..<32).map { UInt8(0x40 + $0) })

  private func frame(flags: UInt8) -> ContactFrame {
    ContactFrame(
      publicKey: publicKey,
      type: .chat,
      flags: flags,
      outPathLength: 0xFF,
      outPath: Data(),
      name: "Peer",
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0
    )
  }

  private func radioRecord(flags: UInt8) -> MeshContact {
    frame(flags: flags).toMeshContact()
  }

  private func makeService(
    session: MockMeshCoreSession,
    store: MockPersistenceStore,
    lock: ContactRecordWriteLock = ContactRecordWriteLock()
  ) -> ContactService {
    ContactService(
      session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil,
      recordWriteLock: lock
    )
  }

  // MARK: - Adds (QR card, Discover, map, mentions)

  @Test
  func `an added contact never brings a remote-commands bit the radio doesn't hold`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    await session.setStubbedContact(nil, for: publicKey)
    let service = makeService(session: session, store: store)
    let radioID = UUID()

    try await service.addOrUpdateContact(radioID: radioID, contact: frame(flags: 0x13))

    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x03])
    #expect(try await store.fetchContact(radioID: radioID, publicKey: publicKey)?.flags == 0x03)
  }

  @Test
  func `re-adding a contact keeps the grant the radio holds`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    await session.setStubbedContact(radioRecord(flags: 0x11), for: publicKey)
    let service = makeService(session: session, store: store)

    try await service.addOrUpdateContact(radioID: UUID(), contact: frame(flags: 0x00))

    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x10])
  }

  @Test
  func `an add whose radio read fails goes without the remote-commands bit`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    await session.setGetContactError(MeshCoreError.timeout, for: publicKey)
    let service = makeService(session: session, store: store)

    try await service.addOrUpdateContact(radioID: UUID(), contact: frame(flags: 0x1F))

    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x0F])
  }

  // MARK: - Path changes

  @Test
  func `a path change whose radio read fails writes nothing and says so`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    let contact = ContactDTO.testContact(publicKey: publicKey, flags: 0x1B)
    try await store.saveContact(contact)
    await session.setGetContactError(MeshCoreError.timeout, for: publicKey)
    let service = makeService(session: session, store: store)

    do {
      try await service.setPath(radioID: contact.radioID, publicKey: publicKey, path: Data([0xA1]), pathLength: 1)
      Issue.record("Expected the path change to be refused")
    } catch ContactServiceError.radioReadFailed {
      // A read failure is not reported as a missing contact.
    }
    #expect(await session.addContactInvocations.isEmpty)
    #expect(await store.contacts[contact.id]?.outPathLength == contact.outPathLength)
  }

  @Test
  func `a path change for a contact the radio no longer has writes nothing`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    let contact = ContactDTO.testContact(publicKey: publicKey, flags: 0x13)
    try await store.saveContact(contact)
    await session.setStubbedContact(nil, for: publicKey)
    let service = makeService(session: session, store: store)

    await #expect(throws: ContactServiceError.self) {
      try await service.setPath(radioID: contact.radioID, publicKey: publicKey, path: Data([0xA1]), pathLength: 1)
    }
    #expect(await session.addContactInvocations.isEmpty)
  }

  // MARK: - Flag changes

  @Test
  func `a flag change whose radio read fails is not reported as contact not found`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    let contact = ContactDTO.testContact(publicKey: publicKey, flags: 0x10)
    try await store.saveContact(contact)
    await session.setGetContactError(MeshCoreError.deviceError(code: 5), for: publicKey)
    let service = makeService(session: session, store: store)

    do {
      try await service.setContactFavorite(contact.id, isFavorite: true)
      Issue.record("Expected the change to be refused")
    } catch ContactServiceError.radioReadFailed {
    }
    #expect(await session.changeContactFlagsInvocations.isEmpty)
    #expect(
      ContactServiceError.radioReadFailed(.timeout).errorDescription
        != ContactServiceError.contactNotFound.errorDescription
    )
  }

  @Test
  func `overlapping flag changes for one contact apply in turn`() async throws {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    let lock = ContactRecordWriteLock()
    let contact = ContactDTO.testContact(publicKey: publicKey, flags: 0x00)
    try await store.saveContact(contact)
    await session.setStubbedContact(radioRecord(flags: 0x00), for: publicKey)
    let service = makeService(session: session, store: store, lock: lock)

    // The first change reads the radio's record and stalls there.
    await session.holdNextGetContact(for: publicKey)
    let first = Task { try await service.setRemoteCLIAllowed(contact.id, allowed: true) }
    try await waitFor { await session.isGetContactHeld(for: self.publicKey) }

    // Two more arrive while it waits: a revoke, then a favourite tap.
    let second = Task { try await service.setRemoteCLIAllowed(contact.id, allowed: false) }
    try await waitFor { await lock.waitingCount(for: self.publicKey) == 1 }
    let third = Task { try await service.setContactFavorite(contact.id, isFavorite: true) }
    try await waitFor { await lock.waitingCount(for: self.publicKey) == 2 }
    #expect(await session.getContactPublicKeys.count == 1, "the later changes wait for the first")

    await session.releaseGetContact(for: publicKey)
    try await first.value
    try await second.value
    try await third.value

    // Each started from the record the previous one left: the revoke is not undone by the
    // favourite tap, which read the radio before the revoke landed without the lock.
    #expect(await session.changeContactFlagsInvocations.map(\.flags.rawValue) == [0x10, 0x00, 0x01])
    let stored = try #require(await store.contacts[contact.id])
    #expect(stored.flags == 0x01)
    #expect(stored.isFavorite)
  }

  // MARK: - Login heal

  @Test
  func `re-adding an evicted contact on login drops the stored remote-commands bit`() async throws {
    let radioID = UUID()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    try await dataStore.saveContact(ContactDTO.testContact(radioID: radioID, publicKey: publicKey, flags: 0x13))
    let session = MockMeshCoreSession()
    await session.setSendLoginResults([
      .failure(MeshCoreError.deviceError(code: ProtocolError.notFound.rawValue)),
      .success(MessageSentInfo(route: 0, expectedAck: Data([0x01, 0x02, 0x03, 0x04]), suggestedTimeoutMs: 5000))
    ])
    let service = RemoteNodeService(session: session, dataStore: dataStore, keychainService: KeychainService())

    _ = try await service.sendLoginHealingIfNeeded(publicKey: publicKey, radioID: radioID, password: "")

    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x03])
    #expect(try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)?.flags == 0x03)
  }

  // MARK: - Config import (the radio is read again at write time)

  @Test
  func `an import keeps a revoke made after its plan was read`() async throws {
    let session = MockMeshCoreSession()
    await session.setStubbedContact(radioRecord(flags: 0x01), for: publicKey)   // revoked since the plan
    let written = try await writeImportedContact(
      radioRecord(flags: 0x13), session: session, lock: ContactRecordWriteLock()   // planned with the old grant
    )
    #expect(written.flags.rawValue == 0x03)
    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x03])
  }

  @Test
  func `an import keeps a grant the radio holds now, and never grants one itself`() async throws {
    let session = MockMeshCoreSession()
    await session.setStubbedContact(radioRecord(flags: 0x10), for: publicKey)
    _ = try await writeImportedContact(radioRecord(flags: 0x01), session: session, lock: ContactRecordWriteLock())
    let other = MockMeshCoreSession()
    await other.setStubbedContact(nil, for: publicKey)
    _ = try await writeImportedContact(radioRecord(flags: 0x11), session: other, lock: ContactRecordWriteLock())
    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x11])
    #expect(await other.addContactInvocations.map(\.contact.flags.rawValue) == [0x01])
  }

  @Test
  func `an import whose radio read fails writes no remote-commands bit`() async throws {
    let session = MockMeshCoreSession()
    await session.setGetContactError(MeshCoreError.timeout, for: publicKey)
    _ = try await writeImportedContact(radioRecord(flags: 0x13), session: session, lock: ContactRecordWriteLock())
    #expect(await session.addContactInvocations.map(\.contact.flags.rawValue) == [0x03])
  }
}

private func waitFor(
  timeout: Duration = .seconds(5),
  _ predicate: @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Condition not met before the deadline")
}
