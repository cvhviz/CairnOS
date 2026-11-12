import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// Covers the remote-commands permission (contact flag 0x10, MeshCore 1.18): set and
/// cleared on the device record without touching the favourite or telemetry bits, and
/// stored locally only once the device confirmed. Every flag write starts from the radio's
/// own record, so a bit revoked on the device is never granted again from a stale copy.
@Suite("ContactService remote commands")
struct ContactServiceRemoteCLITests {
  private let publicKey = Data((0..<32).map { UInt8($0) })

  /// A stored contact and the radio's record of it. `radioFlags` and `radioPath` stand in
  /// for what the device holds now, which may differ from the stored copy; `onRadio: false`
  /// means the radio no longer has the contact.
  private func makeService(
    flags: UInt8,
    isFavorite: Bool = false,
    radioFlags: UInt8? = nil,
    radioPath: Data? = nil,
    onRadio: Bool = true
  ) async throws
    -> (ContactService, MockMeshCoreSession, MockPersistenceStore, UUID) {
    let session = MockMeshCoreSession()
    let store = MockPersistenceStore()
    let contact = ContactDTO.testContact(publicKey: publicKey, flags: flags, isFavorite: isFavorite)
    try await store.saveContact(contact)
    if onRadio {
      let onDevice = ContactDTO.testContact(
        publicKey: publicKey,
        flags: radioFlags ?? flags,
        outPathLength: radioPath.map { UInt8($0.count) } ?? contact.outPathLength,
        outPath: radioPath ?? contact.outPath
      )
      await session.setStubbedContact(onDevice.toContactFrame().toMeshContact(), for: publicKey)
    } else {
      await session.setStubbedContact(nil, for: publicKey)
    }
    let service = ContactService(
      session: session,
      dataStore: store,
      syncCoordinator: nil,
      cleanupCoordinator: nil
    )
    return (service, session, store, contact.id)
  }

  @Test
  func `allowing sets 0x10 and keeps favourite and telemetry`() async throws {
    let (service, session, store, contactID) = try await makeService(flags: 0x0F, isFavorite: true)

    try await service.setRemoteCLIAllowed(contactID, allowed: true)

    let sent = try #require(await session.changeContactFlagsInvocations.first)
    #expect(sent.publicKey == publicKey)
    #expect(sent.flags.rawValue == 0x1F)
    let stored = await store.contacts[contactID]
    #expect(stored?.flags == 0x1F)
    #expect(stored?.isFavorite == true)
    #expect(ContactService.allowsRemoteCLI(flags: stored?.flags ?? 0))
  }

  @Test
  func `stopping clears only 0x10`() async throws {
    let (service, session, store, contactID) = try await makeService(flags: 0x1B)

    try await service.setRemoteCLIAllowed(contactID, allowed: false)

    #expect(await session.changeContactFlagsInvocations.map(\.flags.rawValue) == [0x0B])
    #expect(await store.contacts[contactID]?.flags == 0x0B)
    #expect(!ContactService.allowsRemoteCLI(flags: 0x0B))
  }

  @Test
  func `favourite and telemetry changes keep the remote-commands bit`() async throws {
    let (service, session, store, contactID) = try await makeService(flags: 0x10)

    try await service.setContactFavorite(contactID, isFavorite: true)
    try await service.setTelemetryPermissions(contactID, granted: true)
    try await service.setTelemetryPermissions(contactID, granted: false)
    try await service.setContactFavorite(contactID, isFavorite: false)

    #expect(await session.changeContactFlagsInvocations.map(\.flags.rawValue) == [0x11, 0x1F, 0x11, 0x10])
    #expect(await store.contacts[contactID]?.flags == 0x10)
    #expect(await store.contacts[contactID]?.isFavorite == false)
  }

  @Test
  func `a missing contact is refused before anything is sent`() async throws {
    let (service, session, _, _) = try await makeService(flags: 0)

    await #expect(throws: ContactServiceError.self) {
      try await service.setRemoteCLIAllowed(UUID(), allowed: true)
    }
    #expect(await session.changeContactFlagsInvocations.isEmpty)
  }

  // MARK: - The radio's record wins

  @Test
  func `a bit revoked on the device stays revoked after a favourite toggle`() async throws {
    // Stored copy still says allowed; the device's own contact screen turned it off.
    let (service, session, store, contactID) = try await makeService(flags: 0x10, radioFlags: 0x00)

    try await service.setContactFavorite(contactID, isFavorite: true)
    try await service.setTelemetryPermissions(contactID, granted: true)

    #expect(await session.changeContactFlagsInvocations.map(\.flags.rawValue) == [0x01, 0x0F])
    let stored = try #require(await store.contacts[contactID])
    #expect(stored.flags == 0x0F)
    #expect(!ContactService.allowsRemoteCLI(flags: stored.flags))
    #expect(stored.isFavorite)
  }

  @Test
  func `the radio's newer path is written back and stored`() async throws {
    let radioPath = Data([0xA1, 0xB2])
    let (service, session, store, contactID) = try await makeService(flags: 0, radioPath: radioPath)

    try await service.setRemoteCLIAllowed(contactID, allowed: true)

    let sent = try #require(await session.changeContactFlagsInvocations.first)
    #expect(sent.outPathLength == 2)
    #expect(sent.outPath == radioPath)
    let stored = try #require(await store.contacts[contactID])
    #expect(stored.outPathLength == 2)
    #expect(stored.outPath == radioPath)
    #expect(stored.flags == 0x10)
  }

  @Test
  func `a contact the radio no longer has is not written back`() async throws {
    let (service, session, store, contactID) = try await makeService(flags: 0x10, onRadio: false)

    await #expect(throws: ContactServiceError.self) {
      try await service.setContactFavorite(contactID, isFavorite: true)
    }
    #expect(await session.changeContactFlagsInvocations.isEmpty)
    #expect(await store.contacts[contactID]?.flags == 0x10)
    #expect(await store.contacts[contactID]?.isFavorite == false)
  }

  @Test
  func `a path change writes the radio's flags, not the stored copy's`() async throws {
    let (service, session, store, contactID) = try await makeService(flags: 0x11, radioFlags: 0x01)
    let radioID = try #require(await store.contacts[contactID]?.radioID)

    try await service.setPath(radioID: radioID, publicKey: publicKey, path: Data([0xA1]), pathLength: 1)

    let written = try #require(await session.addContactInvocations.last?.contact)
    #expect(written.flags.rawValue == 0x01)
    #expect(written.outPath == Data([0xA1]))
  }

  @Test
  func `a path change without the radio's record writes nothing`() async throws {
    let (service, session, store, contactID) = try await makeService(flags: 0x13, onRadio: false)
    let radioID = try #require(await store.contacts[contactID]?.radioID)

    await #expect(throws: ContactServiceError.self) {
      try await service.setPath(radioID: radioID, publicKey: publicKey, path: Data([0xA1]), pathLength: 1)
    }

    #expect(await session.addContactInvocations.isEmpty)
  }
}
