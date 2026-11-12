import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The editor's duplicate guard, position inserts, change tracking, one-level undo and copying
/// another node's route.
@Suite("PathManagementViewModel Insert and Undo")
struct PathManagementViewModelInsertTests {
  private func makeSuiteDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.insert.\(UUID().uuidString)")!
  }

  private func key(_ byte: UInt8) -> Data {
    Data([byte] + Array(repeating: 0x00, count: 31))
  }

  // MARK: - Duplicate guard

  @Test
  @MainActor
  func `insert skips a node already in the path`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    let node = ContactDTO.fixture(name: "A", publicKey: key(0x01))
    vm.insert(node, at: .append)
    vm.insert(node, at: .append)
    vm.insert(node, at: .insert(at: 0))
    #expect(vm.editablePath.count == 1)
    #expect(vm.isInPath(node.publicKey))
    #expect(!vm.isInPath(key(0x02)))
  }

  @Test
  @MainActor
  func `isInPath compares at the current hash width`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    // hashSize is 1 without a device: 0x01... and 0x01... with other tails are the same hop.
    vm.insert(ContactDTO.fixture(name: "A", publicKey: key(0x01)), at: .append)
    var other = Data(key(0x01))
    other[5] = 0xFF
    #expect(vm.isInPath(other))
    vm.insert(ContactDTO.fixture(name: "B", publicKey: other), at: .append)
    #expect(vm.editablePath.count == 1)
  }

  // MARK: - Insert at position

  @Test
  @MainActor
  func `insert at a position puts the hop there and shifts the rest`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.insert(ContactDTO.fixture(name: "A", publicKey: key(0x01)), at: .append)
    vm.insert(ContactDTO.fixture(name: "C", publicKey: key(0x03)), at: .append)
    vm.insert(ContactDTO.fixture(name: "B", publicKey: key(0x02)), at: .insert(at: 1))
    #expect(vm.editablePath.map(\.resolvedName) == ["A", "B", "C"])
  }

  @Test
  @MainActor
  func `insert at a position past the end appends`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.insert(ContactDTO.fixture(name: "A", publicKey: key(0x01)), at: .append)
    vm.insert(ContactDTO.fixture(name: "B", publicKey: key(0x02)), at: .insert(at: 9))
    #expect(vm.editablePath.map(\.resolvedName) == ["A", "B"])
  }

  // MARK: - hasChanges

  @Test
  @MainActor
  func `hasChanges follows edits against the path the editor opened on`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    let contact = ContactDTO.fixture(name: "Target", publicKey: key(0xFE), outPathLength: 0x01, outPath: Data([0xA1]))
    vm.initializeEditablePath(from: contact)
    #expect(!vm.hasChanges)
    vm.insert(ContactDTO.fixture(name: "B", publicKey: key(0x02)), at: .append)
    #expect(vm.hasChanges)
    vm.removeRepeater(at: 1)
    #expect(!vm.hasChanges)
  }

  // MARK: - Undo

  @Test
  @MainActor
  func `removing a hop is undoable once`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.insert(ContactDTO.fixture(name: "A", publicKey: key(0x01)), at: .append)
    vm.insert(ContactDTO.fixture(name: "B", publicKey: key(0x02)), at: .append)
    vm.removeRepeater(at: 0)
    #expect(vm.editablePath.map(\.resolvedName) == ["B"])
    #expect(vm.undoEntry?.description == L10n.Contacts.Contacts.PathEdit.Undo.removed("A"))
    vm.undo()
    #expect(vm.editablePath.map(\.resolvedName) == ["A", "B"])
    #expect(vm.undoEntry == nil)
    vm.undo()
    #expect(vm.editablePath.map(\.resolvedName) == ["A", "B"])
  }

  @Test
  @MainActor
  func `a reorder is undoable and a move to the same place is not recorded`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.insert(ContactDTO.fixture(name: "A", publicKey: key(0x01)), at: .append)
    vm.insert(ContactDTO.fixture(name: "B", publicKey: key(0x02)), at: .append)
    let version = vm.undoVersion
    vm.moveRepeater(from: IndexSet(integer: 0), to: 0)
    #expect(vm.undoEntry == nil)
    #expect(vm.undoVersion == version)
    vm.moveRepeater(from: IndexSet(integer: 0), to: 2)
    #expect(vm.editablePath.map(\.resolvedName) == ["B", "A"])
    #expect(vm.undoEntry?.description == L10n.Contacts.Contacts.PathEdit.Undo.moved)
    #expect(vm.undoVersion == version + 1)
    vm.undo()
    #expect(vm.editablePath.map(\.resolvedName) == ["A", "B"])
  }

  // MARK: - Copy path from

  @Test
  @MainActor
  func `copyable sources are the other nodes with a stored route, by name`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    let me = ContactDTO.fixture(name: "Me", publicKey: key(0x10), outPathLength: 0x01, outPath: Data([0xA1]))
    let routed = ContactDTO.fixture(name: "Zed", publicKey: key(0x11), type: .chat, outPathLength: 0x02, outPath: Data([0xA1, 0xB2]))
    let alsoRouted = ContactDTO.fixture(name: "Amy", publicKey: key(0x12), type: .chat, outPathLength: 0x01, outPath: Data([0xC3]))
    let flood = ContactDTO.fixture(name: "Flood", publicKey: key(0x13), type: .chat)
    let direct = ContactDTO.fixture(name: "Direct", publicKey: key(0x14), type: .chat, outPathLength: 0x00)
    vm.allContacts = [me, routed, alsoRouted, flood, direct]
    #expect(vm.copyablePathSources(excluding: me.publicKey).map(\.displayName) == ["Amy", "Zed"])
  }

  @Test
  @MainActor
  func `adoptPath replaces the hops with the source's route, undoably`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.insert(ContactDTO.fixture(name: "A", publicKey: key(0x01)), at: .append)
    let source = ContactDTO.fixture(name: "Zed", publicKey: key(0x11), type: .chat, outPathLength: 0x02, outPath: Data([0xA1, 0xB2]))
    vm.adoptPath(from: source)
    #expect(vm.editablePath.map(\.hashBytes) == [Data([0xA1]), Data([0xB2])])
    #expect(vm.undoEntry?.description == L10n.Contacts.Contacts.PathEdit.Undo.replaced)
    vm.undo()
    #expect(vm.editablePath.map(\.hashBytes) == [Data([0x01])])
  }

  // MARK: - Return route

  @Test
  func `hops(of:) chunks a path at its hash width`() {
    let hops = PathManagementViewModel.hops(of: Data([0xA1, 0xA2, 0xB1, 0xB2, 0xFF]), byteLength: 4, hashSize: 2)
    #expect(hops == [Data([0xA1, 0xA2]), Data([0xB1, 0xB2])])
  }
}
