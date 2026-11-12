import Foundation
@testable import CairnServices
@testable import MeshCore
import MeshCoreTestSupport
import Testing

/// Settings → Nodes → Remove Nodes against a real `MeshCoreSession` whose radio answers (or
/// doesn't) each CMD_REMOVE_CONTACT, through the contact service and the runner the connection
/// manager uses (`AllNodesRemoval`). The contact service has no cleanup coordinator: its
/// notification clean-up needs an app bundle, which `swift test` doesn't have.
@Suite("Node removal")
@MainActor
struct NodeRemovalTests {
  private let selfPublicKey = Data(repeating: 0x01, count: 32)
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn.tests", category: "NodeRemoval")

  /// How the stand-in radio answers a CMD_REMOVE_CONTACT, by contact key.
  private enum Answer: Sendable {
    case ok
    case notFound
    case silence
  }

  private struct Radio {
    let radioID: UUID
    let store: PersistenceStore
    let transport: MockTransport
    let contactService: ContactService
    let responder: Task<Void, Never>
  }

  /// A radio that answers each remove command with `answer(publicKey)`, holding `names` as
  /// non-favorite contacts (keys 0x10, 0x11, … in order).
  private func makeRadio(
    names: [String],
    answer: @escaping @Sendable (Data) -> Answer = { _ in .ok }
  ) async throws -> Radio {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let device = DeviceDTO.testDevice(publicKey: selfPublicKey)
    try await store.saveDevice(device)
    for (index, name) in names.enumerated() {
      try await store.saveContact(contact(UInt8(index), name, radioID: device.radioID))
    }
    let transport = MockTransport()
    try await transport.connect()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 0.3, clientIdentifier: "NodeRemovalTests")
    )
    let contactService = ContactService(
      session: session,
      dataStore: store,
      syncCoordinator: nil,
      cleanupCoordinator: nil
    )

    // Answers each remove command once it is on the wire (the session subscribes before writing).
    let responder = Task {
      var answered = 0
      while !Task.isCancelled {
        let sent = await transport.sentData
        while answered < sent.count {
          let packet = sent[answered]
          answered += 1
          guard packet.first == CommandCode.removeContact.rawValue else { continue }
          switch answer(Data(packet.dropFirst())) {
          case .ok:
            await session.dispatchForTesting(.ok(value: nil))
          case .notFound:
            await session.dispatchForTesting(.error(code: ErrorCode.notFound.rawValue))
          case .silence:
            break
          }
        }
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
    return Radio(
      radioID: device.radioID,
      store: store,
      transport: transport,
      contactService: contactService,
      responder: responder
    )
  }

  private func contact(_ index: UInt8, _ name: String, radioID: UUID, isFavorite: Bool = false) -> ContactDTO {
    ContactDTO.testContact(
      radioID: radioID,
      publicKey: Data(repeating: 0x10 + index, count: 32),
      name: name,
      isFavorite: isFavorite
    )
  }

  /// What `ConnectionManager.removeContacts` does for the radio.
  private func removeAll(
    on radio: Radio,
    onProgress: (_ removed: Int, _ total: Int) -> Void = { _, _ in }
  ) async throws -> RemoveUnfavoritedResult {
    let contacts = try await radio.store.fetchContacts(radioID: radio.radioID)
    let radioID = radio.radioID
    let service = radio.contactService
    return try await AllNodesRemoval.remove(
      AllNodesRemoval.targets(in: contacts.filter { !$0.isFavorite }, selfPublicKey: selfPublicKey),
      removeFromRadio: { try await service.removeContact(radioID: radioID, publicKey: $0.publicKey) },
      removeLocally: { try await service.removeLocalContact(contactID: $0.id, publicKey: $0.publicKey) },
      onProgress: onProgress,
      logger: logger
    )
  }

  private func remainingNames(_ radio: Radio) async throws -> [String] {
    try await radio.store.fetchContacts(radioID: radio.radioID).map(\.name).sorted()
  }

  private func sentRemoveCount(_ radio: Radio) async -> Int {
    await radio.transport.sentData.count(where: { $0.first == CommandCode.removeContact.rawValue })
  }

  // MARK: - Count

  @Test
  func `the non-favorite count matches what the removal targets`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()
    let device = DeviceDTO.testDevice(publicKey: selfPublicKey)
    let vContactKey = try #require(VContactIdentity.publicKey(forSelfPublicKey: selfPublicKey))
    let store = manager.persistenceStore
    try await store.saveDevice(device)
    try await store.saveContact(contact(1, "Favorite", radioID: device.radioID, isFavorite: true))
    try await store.saveContact(ContactDTO.testContact(radioID: device.radioID, publicKey: vContactKey, name: "V-contact"))
    let services = try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: SimulatorMockTransport()),
      radioID: device.radioID
    )
    manager.setTestState(services: services, connectedDevice: device)

    let count = try await manager.unfavoritedNodeCount()
    let result = try await manager.removeUnfavoritedNodes()

    // Before the fix the count was 1 (the V-contact) and the run found 0 to remove: the
    // confirmation promised a removal that never happened, then showed "Nodes Removed".
    #expect(count == 0)
    #expect(count == result.total)
    #expect(!result.removedAll)
  }

  // MARK: - Removal

  @Test
  func `removes the nodes from the radio and the app, keeping favorites`() async throws {
    let radio = try await makeRadio(names: ["A", "B", "C"])
    defer { radio.responder.cancel() }
    try await radio.store.saveContact(contact(9, "Fav", radioID: radio.radioID, isFavorite: true))

    var progress: [[Int]] = []
    let result = try await removeAll(on: radio) { removed, total in
      progress.append([removed, total])
    }

    #expect(result.removed == 3)
    #expect(result.total == 3)
    #expect(result.failure == nil)
    #expect(result.removedAll)
    #expect(progress == [[0, 3], [1, 3], [2, 3], [3, 3]])
    #expect(try await remainingNames(radio) == ["Fav"])
    #expect(await sentRemoveCount(radio) == 3)
  }

  @Test
  func `a node the radio no longer has is removed from the app`() async throws {
    let radio = try await makeRadio(names: ["A", "B", "C"]) { key in
      key.first == 0x11 ? .notFound : .ok
    }
    defer { radio.responder.cancel() }

    let result = try await removeAll(on: radio)

    #expect(result.removedAll)
    #expect(try await remainingNames(radio).isEmpty)
  }

  @Test
  func `a radio that does not answer ends the run with the reason`() async throws {
    let radio = try await makeRadio(names: ["A", "B", "C"]) { _ in .silence }
    defer { radio.responder.cancel() }

    let result = try await removeAll(on: radio)

    #expect(result.removed == 0)
    #expect(result.total == 3)
    #expect(!result.removedAll)
    // The reason travels with the result, so the screen can say what went wrong.
    guard case .sessionError(.timeout) = result.failure as? ContactServiceError else {
      Issue.record("Expected a timeout, got \(String(describing: result.failure))")
      return
    }
    #expect(try await remainingNames(radio) == ["A", "B", "C"])
    // One command, then it stops rather than waiting out a timeout per node.
    #expect(await sentRemoveCount(radio) == 1)
  }

  @Test
  func `a radio that stops answering part way keeps what was removed`() async throws {
    let radio = try await makeRadio(names: ["A", "B", "C"]) { key in
      key.first == 0x11 ? .silence : .ok
    }
    defer { radio.responder.cancel() }

    let result = try await removeAll(on: radio)

    #expect(result.removed == 1)
    #expect(result.total == 3)
    #expect(result.failure != nil)
    #expect(try await remainingNames(radio) == ["B", "C"])
  }
}
