import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("AllNodesRemoval")
@MainActor
struct AllNodesRemovalTests {
  private struct RadioFailure: Error {}

  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn.tests", category: "AllNodesRemoval")
  private let selfPublicKey = Data(repeating: 0x01, count: 32)

  /// Records what a run asked of the radio and the local store.
  @MainActor
  private final class Recorder {
    var radioRemovals: [String] = []
    var localRemovals: [String] = []
    var progress: [[Int]] = []
    var radioErrors: [String: any Error] = [:]
    var localErrors: [String: any Error] = [:]
    var onRadioRemoval: ((String) -> Void)?

    func removeFromRadio(_ contact: ContactDTO) async throws {
      radioRemovals.append(contact.name)
      onRadioRemoval?(contact.name)
      if let error = radioErrors[contact.name] { throw error }
    }

    func removeLocally(_ contact: ContactDTO) async throws {
      localRemovals.append(contact.name)
      if let error = localErrors[contact.name] { throw error }
    }

    func recordProgress(removed: Int, total: Int) {
      progress.append([removed, total])
    }
  }

  private func makeContacts(_ names: [String]) -> [ContactDTO] {
    names.enumerated().map { index, name in
      ContactDTO.testContact(publicKey: Data(repeating: UInt8(index + 0x10), count: 32), name: name)
    }
  }

  private func run(
    _ targets: [ContactDTO],
    recorder: Recorder
  ) async throws -> RemoveUnfavoritedResult {
    try await AllNodesRemoval.remove(
      targets,
      removeFromRadio: recorder.removeFromRadio,
      removeLocally: recorder.removeLocally,
      onProgress: recorder.recordProgress,
      logger: logger
    )
  }

  // MARK: - Targets

  @Test
  func `targets cover favorites and every node type`() {
    let contacts = [
      ContactDTO.testContact(publicKey: Data(repeating: 0x10, count: 32), name: "Chat"),
      ContactDTO.testContact(publicKey: Data(repeating: 0x11, count: 32), name: "Favorite", isFavorite: true),
      ContactDTO.testContact(
        publicKey: Data(repeating: 0x12, count: 32),
        name: "Repeater",
        typeRawValue: ContactType.repeater.rawValue
      ),
      ContactDTO.testContact(
        publicKey: Data(repeating: 0x13, count: 32),
        name: "Room",
        typeRawValue: ContactType.room.rawValue,
        isFavorite: true
      )
    ]

    let targets = AllNodesRemoval.targets(in: contacts, selfPublicKey: selfPublicKey)

    #expect(targets.map(\.name) == ["Chat", "Favorite", "Repeater", "Room"])
  }

  @Test
  func `targets leave out the V-contact`() throws {
    let vContactKey = try #require(VContactIdentity.publicKey(forSelfPublicKey: selfPublicKey))
    let contacts = [
      ContactDTO.testContact(publicKey: Data(repeating: 0x10, count: 32), name: "Chat"),
      ContactDTO.testContact(publicKey: vContactKey, name: "V-contact")
    ]

    let targets = AllNodesRemoval.targets(in: contacts, selfPublicKey: selfPublicKey)

    #expect(targets.map(\.name) == ["Chat"])
  }

  @Test
  func `targets keep every contact when the radio key is unknown`() {
    let contacts = makeContacts(["A", "B"])

    #expect(AllNodesRemoval.targets(in: contacts, selfPublicKey: nil).map(\.name) == ["A", "B"])
  }

  // MARK: - Removal

  @Test
  func `removes every target and reports progress after each`() async throws {
    let recorder = Recorder()

    let result = try await run(makeContacts(["A", "B", "C"]), recorder: recorder)

    #expect(result.removed == 3)
    #expect(result.total == 3)
    #expect(recorder.radioRemovals == ["A", "B", "C"])
    #expect(recorder.localRemovals.isEmpty)
    #expect(recorder.progress == [[0, 3], [1, 3], [2, 3], [3, 3]])
    #expect(result.failure == nil)
    #expect(result.removedAll)
  }

  @Test
  func `no targets sends nothing`() async throws {
    let recorder = Recorder()

    let result = try await run([], recorder: recorder)

    #expect(result.removed == 0)
    #expect(result.total == 0)
    #expect(!result.removedAll)
    #expect(recorder.radioRemovals.isEmpty)
    #expect(recorder.progress.isEmpty)
  }

  @Test
  func `a contact the radio no longer has is cleaned up locally and counted`() async throws {
    let recorder = Recorder()
    recorder.radioErrors["B"] = ContactServiceError.contactNotFound

    let result = try await run(makeContacts(["A", "B", "C"]), recorder: recorder)

    #expect(result.removed == 3)
    #expect(result.total == 3)
    #expect(recorder.radioRemovals == ["A", "B", "C"])
    #expect(recorder.localRemovals == ["B"])
  }

  @Test
  func `a failed local cleanup is not counted and the run continues`() async throws {
    let recorder = Recorder()
    recorder.radioErrors["B"] = ContactServiceError.contactNotFound
    recorder.localErrors["B"] = RadioFailure()

    let result = try await run(makeContacts(["A", "B", "C"]), recorder: recorder)

    #expect(result.removed == 2)
    #expect(result.total == 3)
    #expect(recorder.radioRemovals == ["A", "B", "C"])
    #expect(recorder.progress.last == [2, 3])
    #expect(result.failure == nil)
    #expect(!result.removedAll)
  }

  @Test
  func `a dropped connection ends the run with the count so far`() async throws {
    let recorder = Recorder()
    recorder.radioErrors["C"] = ContactServiceError.sessionError(MeshCoreError.timeout)

    let result = try await run(makeContacts(["A", "B", "C", "D", "E"]), recorder: recorder)

    #expect(result.removed == 2)
    #expect(result.total == 5)
    #expect(recorder.radioRemovals == ["A", "B", "C"])
    #expect(recorder.progress == [[0, 5], [1, 5], [2, 5]])
    guard case .sessionError(.timeout) = result.failure as? ContactServiceError else {
      Issue.record("Expected the timeout that ended the run, got \(String(describing: result.failure))")
      return
    }
  }

  @Test
  func `a failure on the first contact removes nothing`() async throws {
    let recorder = Recorder()
    recorder.radioErrors["A"] = RadioFailure()

    let result = try await run(makeContacts(["A", "B"]), recorder: recorder)

    #expect(result.removed == 0)
    #expect(result.total == 2)
    #expect(result.failure is RadioFailure)
    #expect(recorder.radioRemovals == ["A"])
  }

  @Test
  func `each contact is sent to the radio once`() async throws {
    let recorder = Recorder()
    recorder.radioErrors["B"] = RadioFailure()

    _ = try await run(makeContacts(["A", "B", "C"]), recorder: recorder)

    #expect(recorder.radioRemovals == ["A", "B"])
  }

  @Test
  func `the run reports every target before its first radio command`() async throws {
    let recorder = Recorder()
    let targets = makeContacts(["A", "B", "C"])
    var started: Set<Data>?
    var radioRemovalsAtStart: Int?

    _ = try await AllNodesRemoval.remove(
      targets,
      removeFromRadio: recorder.removeFromRadio,
      removeLocally: recorder.removeLocally,
      onStart: { keys in
        started = keys
        radioRemovalsAtStart = recorder.radioRemovals.count
      },
      onProgress: recorder.recordProgress,
      logger: logger
    )

    #expect(started == Set(targets.map(\.publicKey)))
    #expect(radioRemovalsAtStart == 0)
  }

  @Test
  func `an empty run reports no start`() async throws {
    var started = false
    _ = try await AllNodesRemoval.remove(
      [],
      removeFromRadio: { _ in },
      removeLocally: { _ in },
      onStart: { _ in started = true },
      onProgress: { _, _ in },
      logger: logger
    )
    #expect(!started)
  }

  @Test
  func `cancellation between contacts stops the run`() async {
    let recorder = Recorder()
    let targets = makeContacts(["A", "B", "C"])
    let logger = logger

    let task = Task { @MainActor in
      try await AllNodesRemoval.remove(
        targets,
        removeFromRadio: recorder.removeFromRadio,
        removeLocally: recorder.removeLocally,
        onProgress: recorder.recordProgress,
        logger: logger
      )
    }
    recorder.onRadioRemoval = { name in
      if name == "B" { task.cancel() }
    }

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(recorder.radioRemovals == ["A", "B"])
  }

  @Test
  func `cancellation raised by the radio call is passed on`() async {
    let recorder = Recorder()
    recorder.radioErrors["B"] = CancellationError()

    await #expect(throws: CancellationError.self) {
      _ = try await run(makeContacts(["A", "B", "C"]), recorder: recorder)
    }
    #expect(recorder.radioRemovals == ["A", "B"])
  }

  // MARK: - ConnectionManager

  @Test
  func `removableNodeCount throws when not connected`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()

    await #expect(throws: ConnectionError.self) {
      _ = try await manager.removableNodeCount()
    }
  }

  @Test
  func `removeAllNodes throws when not connected`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()

    await #expect(throws: ConnectionError.self) {
      _ = try await manager.removeAllNodes(onProgress: { _, _ in })
    }
  }

  @Test
  func `removeAllNodes throws when the device has no services`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()
    manager.setTestState(connectedDevice: DeviceDTO.testDevice(publicKey: selfPublicKey))

    await #expect(throws: ConnectionError.self) {
      _ = try await manager.removeAllNodes(onProgress: { _, _ in })
    }
  }

  @Test
  func `removableNodeCount counts this radio's contacts without the V-contact`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()
    let device = DeviceDTO.testDevice(publicKey: selfPublicKey)
    let vContactKey = try #require(VContactIdentity.publicKey(forSelfPublicKey: selfPublicKey))
    let store = manager.persistenceStore
    try await store.saveDevice(device)
    try await store.saveContact(ContactDTO.testContact(
      radioID: device.radioID,
      publicKey: Data(repeating: 0x10, count: 32),
      name: "Chat"
    ))
    try await store.saveContact(ContactDTO.testContact(
      radioID: device.radioID,
      publicKey: Data(repeating: 0x11, count: 32),
      name: "Favorite",
      isFavorite: true
    ))
    try await store.saveContact(ContactDTO.testContact(
      radioID: device.radioID,
      publicKey: vContactKey,
      name: "V-contact"
    ))
    try await store.saveContact(ContactDTO.testContact(
      radioID: UUID(),
      publicKey: Data(repeating: 0x12, count: 32),
      name: "Other radio"
    ))
    manager.setTestState(connectedDevice: device)

    let count = try await manager.removableNodeCount()

    #expect(count == 2)
  }
}
