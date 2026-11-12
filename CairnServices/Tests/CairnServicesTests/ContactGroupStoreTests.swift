import Foundation
@testable import CairnServices
import Testing

@Suite("ContactGroupStore")
@MainActor
struct ContactGroupStoreTests {
  private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "test.contactGroups.\(UUID().uuidString)"
    return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
  }

  private let alice = Data([0xAB, 0x01, 0x02])
  private let bob = Data([0xCD, 0x03, 0x04])

  // MARK: - Lifecycle

  @Test
  func `create trims the name and rejects blanks and duplicates`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)

    let group = try #require(store.createGroup(name: "  Family  "))
    #expect(group.name == "Family")
    #expect(store.createGroup(name: "   ") == nil)
    #expect(store.createGroup(name: "family") == nil)
    #expect(store.groups.map(\.name) == ["Family"])
  }

  @Test
  func `create caps the name length`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)

    let group = try #require(store.createGroup(name: String(repeating: "x", count: 80)))
    #expect(group.name.count == ContactGroup.maxNameLength)
  }

  @Test
  func `rename updates the name and refuses a taken or blank name`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    let family = try #require(store.createGroup(name: "Family"))
    _ = try #require(store.createGroup(name: "Hiking"))

    #expect(store.rename(family.id, to: "Relatives"))
    #expect(store.group(id: family.id)?.name == "Relatives")
    #expect(!store.rename(family.id, to: "HIKING"))
    #expect(!store.rename(family.id, to: " "))
    // Renaming to its own name with different case is allowed.
    #expect(store.rename(family.id, to: "relatives"))
    #expect(!store.rename(UUID(), to: "Ghost"))
  }

  @Test
  func `delete removes only the target group`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    let first = try #require(store.createGroup(name: "A"))
    _ = try #require(store.createGroup(name: "B"))

    store.delete(first.id)
    #expect(store.groups.map(\.name) == ["B"])
  }

  @Test
  func `move follows onMove semantics`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    for groupName in ["A", "B", "C", "D"] {
      store.createGroup(name: groupName)
    }

    store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(store.groups.map(\.name) == ["B", "C", "A", "D"])
    store.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
    #expect(store.groups.map(\.name) == ["D", "B", "C", "A"])
    store.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
    #expect(store.groups.map(\.name) == ["C", "A", "D", "B"])
  }

  // MARK: - Membership

  @Test
  func `add and remove members without duplicates`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    let group = try #require(store.createGroup(name: "Team"))

    store.add(alice, to: group.id)
    store.add(alice, to: group.id)
    store.add(bob, to: group.id)
    #expect(store.group(id: group.id)?.memberKeys == ["ab0102", "cd0304"])
    #expect(store.isMember(alice, of: group.id))

    store.remove(alice, from: group.id)
    #expect(!store.isMember(alice, of: group.id))
    #expect(store.group(id: group.id)?.memberKeys == ["cd0304"])

    store.toggle(alice, in: group.id)
    #expect(store.isMember(alice, of: group.id))
    store.toggle(alice, in: group.id)
    #expect(!store.isMember(alice, of: group.id))
  }

  @Test
  func `a node can belong to several groups`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    let first = try #require(store.createGroup(name: "One"))
    let second = try #require(store.createGroup(name: "Two"))
    _ = try #require(store.createGroup(name: "Three"))

    store.add(alice, to: first.id)
    store.add(alice, to: second.id)
    #expect(store.groups(containing: alice).map(\.name) == ["One", "Two"])
    #expect(store.groups(containing: bob).isEmpty)
  }

  @Test
  func `prune drops keys that are no longer contacts`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    let group = try #require(store.createGroup(name: "Team"))
    store.add(alice, to: group.id)
    store.add(bob, to: group.id)

    let removed = store.prune(keeping: [ContactGroup.memberKey(for: bob)])
    #expect(removed == 1)
    #expect(store.group(id: group.id)?.memberKeys == ["cd0304"])
    #expect(store.prune(keeping: [ContactGroup.memberKey(for: bob)]) == 0)
  }

  // MARK: - Persistence

  @Test
  func `mutations persist and reload in a fresh store`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    let group = try #require(store.createGroup(name: "Team", symbol: "star.fill", color: "red"))
    store.add(alice, to: group.id)
    store.setAppearance(group.id, symbol: "flag.fill", color: "green")

    let reloaded = ContactGroupStore(defaults: defaults)
    #expect(reloaded.groups == store.groups)
    let persisted = try #require(reloaded.groups.first)
    #expect(persisted.symbol == "flag.fill")
    #expect(persisted.color == "green")
    #expect(persisted.contains(alice))
  }

  @Test
  func `reload picks up externally written groups`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ContactGroupStore(defaults: defaults)
    #expect(store.groups.isEmpty)

    ContactGroupsStorage.save([ContactGroup(name: "Restored")], to: defaults)
    store.reload()
    #expect(store.groups.map(\.name) == ["Restored"])
  }

  @Test
  func `corrupt data loads as empty`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(Data("not json".utf8), forKey: ContactGroupsStorage.defaultsKey)
    #expect(ContactGroupStore(defaults: defaults).groups.isEmpty)
  }

  // MARK: - Backup

  @Test
  func `backup round-trips groups and restore fills only an unset key`() throws {
    let (source, sourceName) = try makeDefaults()
    defer { source.removePersistentDomain(forName: sourceName) }
    let store = ContactGroupStore(defaults: source)
    let group = try #require(store.createGroup(name: "Team"))
    store.add(alice, to: group.id)

    let snapshot = BackupUserDefaults.snapshot(from: source)
    #expect(snapshot.contactGroups == store.groups)

    let decoded = try JSONDecoder().decode(BackupUserDefaults.self, from: JSONEncoder().encode(snapshot))
    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }
    let setKeys = decoded.restore(to: target)
    #expect(setKeys.contains(ContactGroupsStorage.defaultsKey))
    #expect(ContactGroupsStorage.load(from: target) == store.groups)

    let (existing, existingName) = try makeDefaults()
    defer { existing.removePersistentDomain(forName: existingName) }
    ContactGroupsStorage.save([ContactGroup(name: "Local")], to: existing)
    #expect(!decoded.restore(to: existing).contains(ContactGroupsStorage.defaultsKey))
    #expect(ContactGroupsStorage.load(from: existing).map(\.name) == ["Local"])
  }

  @Test
  func `snapshot omits groups when never set`() throws {
    let (defaults, name) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(BackupUserDefaults.snapshot(from: defaults).contactGroups == nil)
  }
}
