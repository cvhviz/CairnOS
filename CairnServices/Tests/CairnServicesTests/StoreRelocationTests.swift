import Foundation
import SwiftData
import Testing
@testable import CairnServices

/// The one-time move of the database out of the App Group container (``StoreRelocation``).
@Suite("Store relocation")
struct StoreRelocationTests {
  private struct Sandbox {
    let root: URL
    let legacy: URL
    let destination: URL
    let defaults: UserDefaults
    let suite: String

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let group = root.appendingPathComponent("group", isDirectory: true)
      legacy = StoreRelocation.groupStoreURL(groupContainer: group, storeName: "Cairn")
      destination = root.appendingPathComponent("app/Library/Application Support/Cairn.store")
      try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
      suite = "StoreRelocationTests." + UUID().uuidString
      defaults = UserDefaults(suiteName: suite)!
    }

    func cleanUp() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private static let key = Data(repeating: 0x42, count: 32)

  /// Writes one contact into a store at `url` and closes it.
  private func writeStore(at url: URL, radioID: UUID, name: String) async throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let container = try ModelContainer(
      for: PersistenceStore.schema,
      configurations: [ModelConfiguration(schema: PersistenceStore.schema, url: url)]
    )
    let store = PersistenceStore(modelContainer: container)
    try await store.saveContact(ContactDTO.testContact(radioID: radioID, publicKey: Self.key, name: name))
  }

  private func contactName(at url: URL, radioID: UUID) async throws -> String? {
    let container = try ModelContainer(
      for: PersistenceStore.schema,
      configurations: [ModelConfiguration(schema: PersistenceStore.schema, url: url)]
    )
    let store = PersistenceStore(modelContainer: container)
    return try await store.fetchContact(radioID: radioID, publicKey: Self.key)?.name
  }

  @Test
  func `the group copy becomes the app's store and is removed`() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let radioID = UUID()
    try await writeStore(at: box.legacy, radioID: radioID, name: "From the group")

    let outcome = try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults)

    #expect(outcome == .moved)
    #expect(box.defaults.bool(forKey: StoreRelocation.markerKey))
    #expect(try await contactName(at: box.destination, radioID: radioID) == "From the group")
    for suffix in ["", "-wal", "-shm", ".relocated"] {
      #expect(!FileManager.default.fileExists(atPath: box.legacy.path + suffix))
    }
  }

  @Test
  func `a lost marker after the move never copies anything over the app's store`() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let radioID = UUID()
    try await writeStore(at: box.legacy, radioID: radioID, name: "Mine")
    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults) == .moved)

    // the process died before the marker reached disk, and left the old log files behind
    box.defaults.removeObject(forKey: StoreRelocation.markerKey)
    try Data("log".utf8).write(to: URL(fileURLWithPath: box.legacy.path + "-wal"))
    try Data("old".utf8).write(to: URL(fileURLWithPath: box.legacy.path + ".relocated"))

    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults) == .nothingToMove)
    #expect(try await contactName(at: box.destination, radioID: radioID) == "Mine")
    for suffix in ["-wal", ".relocated"] {
      #expect(!FileManager.default.fileExists(atPath: box.legacy.path + suffix))
    }
  }

  @Test
  func `the group copy wins over a stale copy in the app container`() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let radioID = UUID()
    try await writeStore(at: box.destination, radioID: radioID, name: "Stale")
    try await writeStore(at: box.legacy, radioID: radioID, name: "Current")

    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults) == .moved)
    #expect(try await contactName(at: box.destination, radioID: radioID) == "Current")
  }

  @Test
  func `nothing to move leaves the app's store alone and is remembered`() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let radioID = UUID()
    try await writeStore(at: box.destination, radioID: radioID, name: "Mine")

    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults) == .nothingToMove)
    #expect(box.defaults.bool(forKey: StoreRelocation.markerKey))
    #expect(try await contactName(at: box.destination, radioID: radioID) == "Mine")
  }

  @Test
  func `a group copy that turns up after the move never replaces newer data`() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let radioID = UUID()
    try await writeStore(at: box.legacy, radioID: radioID, name: "Old")
    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults) == .moved)

    // The app carries on in its own container; an old group copy reappears (a clean-up that
    // failed, a restored backup).
    let newerRadio = UUID()
    let staleRadio = UUID()
    try await writeStore(at: box.destination, radioID: newerRadio, name: "Newer")
    try await writeStore(at: box.legacy, radioID: staleRadio, name: "Old again")

    let outcome = try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults)
    #expect(outcome == .alreadyMoved(leftoverRemoved: true))
    #expect(try await contactName(at: box.destination, radioID: newerRadio) == "Newer")
    #expect(try await contactName(at: box.destination, radioID: staleRadio) == nil)
    #expect(!FileManager.default.fileExists(atPath: box.legacy.path))

    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults)
      == .alreadyMoved(leftoverRemoved: false))
  }

  @Test
  func `a copy that cannot be read throws, sets no marker and keeps both copies`() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let radioID = UUID()
    try await writeStore(at: box.destination, radioID: radioID, name: "Stale")
    try await writeStore(at: box.legacy, radioID: radioID, name: "Current")
    // as before first unlock: the file is there, its bytes are not
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.legacy.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.legacy.path) }

    #expect(throws: (any Error).self) {
      try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults)
    }
    #expect(!box.defaults.bool(forKey: StoreRelocation.markerKey))
    #expect(FileManager.default.fileExists(atPath: box.legacy.path))

    // readable again: the retry moves it
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.legacy.path)
    #expect(try StoreRelocation.relocate(from: box.legacy, to: box.destination, defaults: box.defaults) == .moved)
    #expect(try await contactName(at: box.destination, radioID: radioID) == "Current")
  }
}
