import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The Saved list's select mode: picks are kept by id, a bulk action sees only the picks among
/// the nodes shown, Select All follows what is shown, and ending the select drops every pick.
@Suite("ContactsViewModel selection")
@MainActor
struct ContactsViewModelSelectionTests {
  private func makeContact(name: String, type: ContactType = .chat, isFavorite: Bool = false) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data((0..<ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: 0...255) }),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: isFavorite,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  @Test func `select mode starts off and empty`() {
    let viewModel = ContactsViewModel()
    #expect(!viewModel.isSelecting)
    #expect(viewModel.selectedContactIDs.isEmpty)
  }

  @Test func `begin selecting starts with no picks and toggles add and remove`() {
    let viewModel = ContactsViewModel()
    let alice = makeContact(name: "Alice")
    let bob = makeContact(name: "Bob")
    viewModel.contacts = [alice, bob]

    viewModel.beginSelecting()
    #expect(viewModel.isSelecting)
    #expect(viewModel.selectedContactIDs.isEmpty)

    viewModel.toggleSelection(alice)
    #expect(viewModel.isSelected(alice))
    #expect(!viewModel.isSelected(bob))

    viewModel.toggleSelection(alice)
    #expect(!viewModel.isSelected(alice))
  }

  /// A pick hidden by the search or segment is not part of the bulk action.
  @Test func `selected contacts are limited to the nodes shown, in list order`() {
    let viewModel = ContactsViewModel()
    let alice = makeContact(name: "Alice")
    let bob = makeContact(name: "Bob")
    let carol = makeContact(name: "Carol", type: .repeater)
    viewModel.contacts = [alice, bob, carol]

    viewModel.beginSelecting()
    viewModel.toggleSelection(carol)
    viewModel.toggleSelection(alice)

    let shown = [alice, bob]
    #expect(viewModel.selectedContacts(in: shown).map(\.id) == [alice.id])
    #expect(viewModel.selectedContacts(in: [carol, bob, alice]).map(\.id) == [carol.id, alice.id])
  }

  @Test func `select all follows what is shown and deselects once everything shown is picked`() {
    let viewModel = ContactsViewModel()
    let alice = makeContact(name: "Alice")
    let bob = makeContact(name: "Bob")
    let carol = makeContact(name: "Carol")
    viewModel.contacts = [alice, bob, carol]
    viewModel.beginSelecting()
    let shown = [alice, bob]

    #expect(!viewModel.isAllSelected(in: shown))
    viewModel.toggleSelectAll(in: shown)
    #expect(viewModel.isAllSelected(in: shown))
    #expect(viewModel.selectedContactIDs == [alice.id, bob.id])
    #expect(!viewModel.isAllSelected(in: [alice, bob, carol]))

    viewModel.toggleSelectAll(in: shown)
    #expect(viewModel.selectedContactIDs.isEmpty)
    #expect(!viewModel.isAllSelected(in: []))
  }

  @Test func `ending the select drops every pick`() {
    let viewModel = ContactsViewModel()
    let alice = makeContact(name: "Alice")
    viewModel.contacts = [alice]
    viewModel.beginSelecting()
    viewModel.toggleSelection(alice)

    viewModel.endSelecting()

    #expect(!viewModel.isSelecting)
    #expect(viewModel.selectedContactIDs.isEmpty)
  }

  /// A row's Delete and Block wait for the list's confirmation rather than running at once.
  @Test func `row confirmations start empty`() {
    let viewModel = ContactsViewModel()
    #expect(viewModel.deleteConfirmation == nil)
    #expect(viewModel.blockConfirmation == nil)
    #expect(viewModel.deleteTimedOut == nil)
  }

  /// A bulk delete with no radio reports it on the first node and stops, leaving the list alone.
  @Test func `bulk delete without a radio reports once and keeps the rows`() async {
    let viewModel = ContactsViewModel()
    let alice = makeContact(name: "Alice")
    let bob = makeContact(name: "Bob")
    viewModel.contacts = [alice, bob]

    await viewModel.deleteContacts([alice, bob])

    #expect(viewModel.errorMessage == L10n.Contacts.Contacts.ViewModel.connectToDelete)
    #expect(viewModel.contacts.map(\.id) == [alice.id, bob.id])
    #expect(viewModel.pendingRemovalIDs.isEmpty)
  }

  /// Retry with nothing timed out is a no-op.
  @Test func `retry without a timed-out delete does nothing`() async {
    let viewModel = ContactsViewModel()
    let alice = makeContact(name: "Alice")
    viewModel.contacts = [alice]

    await viewModel.retryTimedOutDelete()

    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.contacts.map(\.id) == [alice.id])
  }
}
