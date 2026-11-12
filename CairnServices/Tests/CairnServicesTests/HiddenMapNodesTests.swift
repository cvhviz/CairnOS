import Foundation
@testable import CairnServices
import Testing

@Suite("HiddenMapNodes")
struct HiddenMapNodesTests {
  private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "test.hiddenMapNodes.\(UUID().uuidString)"
    return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
  }

  private let radio = UUID()
  private let otherRadio = UUID()
  private let alice = Data([0xAB, 0x01, 0x02])
  private let bob = Data([0xCD, 0x03, 0x04])

  // MARK: - Hide and show

  @Test
  func `nothing is hidden by default`() {
    let hidden = HiddenMapNodes()
    #expect(hidden.publicKeys(for: radio).isEmpty)
    #expect(!hidden.contains(alice, radioID: radio))
  }

  @Test
  func `hide adds a node once and keeps the order hidden`() {
    var hidden = HiddenMapNodes()
    hidden.hide(bob, radioID: radio)
    hidden.hide(alice, radioID: radio)
    hidden.hide(bob, radioID: radio)

    #expect(hidden.keysByRadio[radio.uuidString] == ["cd0304", "ab0102"])
    #expect(hidden.publicKeys(for: radio) == [alice, bob])
    #expect(hidden.contains(alice, radioID: radio))
  }

  @Test
  func `hide ignores an empty key`() {
    var hidden = HiddenMapNodes()
    hidden.hide(Data(), radioID: radio)
    #expect(hidden == HiddenMapNodes())
  }

  @Test
  func `show removes only the named node`() {
    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    hidden.hide(bob, radioID: radio)

    hidden.show(alice, radioID: radio)

    #expect(hidden.publicKeys(for: radio) == [bob])
  }

  @Test
  func `showing the last node leaves no entry for the radio`() {
    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    hidden.show(alice, radioID: radio)
    #expect(hidden == HiddenMapNodes())
  }

  @Test
  func `showing a node that is not hidden changes nothing`() {
    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    let before = hidden

    hidden.show(bob, radioID: radio)
    hidden.show(alice, radioID: otherRadio)

    #expect(hidden == before)
  }

  @Test
  func `hidden nodes are kept per radio`() {
    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    hidden.hide(bob, radioID: otherRadio)

    #expect(hidden.publicKeys(for: radio) == [alice])
    #expect(hidden.publicKeys(for: otherRadio) == [bob])
    #expect(!hidden.contains(alice, radioID: otherRadio))
  }

  @Test
  func `show all clears one radio and leaves the others`() {
    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    hidden.hide(bob, radioID: radio)
    hidden.hide(alice, radioID: otherRadio)

    hidden.showAll(radioID: radio)

    #expect(hidden.publicKeys(for: radio).isEmpty)
    #expect(hidden.publicKeys(for: otherRadio) == [alice])
  }

  // MARK: - Normalization

  @Test
  func `init lowercases keys and drops duplicates, invalid entries and empty radios`() {
    let hidden = HiddenMapNodes(keysByRadio: [
      radio.uuidString.lowercased(): ["AB0102", "ab0102", "not hex", "", "cd0304"],
      otherRadio.uuidString: ["zz"],
      "not-a-radio": ["ab0102"]
    ])

    #expect(hidden.keysByRadio == [radio.uuidString: ["ab0102", "cd0304"]])
  }

  @Test
  func `a node stored in another spelling can still be shown again`() throws {
    let json = Data(#"{"keysByRadio":{"\#(radio.uuidString.lowercased())":["AB0102"]}}"#.utf8)
    var hidden = try JSONDecoder().decode(HiddenMapNodes.self, from: json)
    #expect(hidden.contains(alice, radioID: radio))

    hidden.show(alice, radioID: radio)

    #expect(hidden.publicKeys(for: radio).isEmpty)
  }

  // MARK: - Persistence

  @Test
  func `save and load round trip through UserDefaults`() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(HiddenMapNodesStorage.load(from: defaults) == HiddenMapNodes())

    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    hidden.hide(bob, radioID: otherRadio)
    HiddenMapNodesStorage.save(hidden, to: defaults)

    #expect(HiddenMapNodesStorage.load(from: defaults) == hidden)
  }

  @Test
  func `corrupt data loads as nothing hidden`() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not json".utf8), forKey: HiddenMapNodesStorage.defaultsKey)

    #expect(HiddenMapNodesStorage.load(from: defaults) == HiddenMapNodes())
    #expect(HiddenMapNodesStorage.decode(Data()) == HiddenMapNodes())
  }

  // MARK: - Backup

  @Test
  func `backup round-trips hidden nodes and restore fills only an unset key`() throws {
    let (source, sourceName) = try makeDefaults()
    defer { source.removePersistentDomain(forName: sourceName) }
    var hidden = HiddenMapNodes()
    hidden.hide(alice, radioID: radio)
    HiddenMapNodesStorage.save(hidden, to: source)

    let snapshot = BackupUserDefaults.snapshot(from: source)
    #expect(snapshot.hiddenMapNodes == hidden)

    let decoded = try JSONDecoder().decode(BackupUserDefaults.self, from: JSONEncoder().encode(snapshot))
    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }
    let setKeys = decoded.restore(to: target)
    #expect(setKeys.contains(HiddenMapNodesStorage.defaultsKey))
    #expect(HiddenMapNodesStorage.load(from: target) == hidden)

    let (existing, existingName) = try makeDefaults()
    defer { existing.removePersistentDomain(forName: existingName) }
    var local = HiddenMapNodes()
    local.hide(bob, radioID: radio)
    HiddenMapNodesStorage.save(local, to: existing)
    #expect(!decoded.restore(to: existing).contains(HiddenMapNodesStorage.defaultsKey))
    #expect(HiddenMapNodesStorage.load(from: existing) == local)
  }

  @Test
  func `snapshot omits hidden nodes when never set`() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(BackupUserDefaults.snapshot(from: defaults).hiddenMapNodes == nil)
  }

  @Test
  func `line of sight filter travels with a backup`() throws {
    let (source, sourceName) = try makeDefaults()
    defer { source.removePersistentDomain(forName: sourceName) }
    source.set("{\"showDiscovered\":true}", forKey: AppStorageKey.mapFilterLineOfSight.rawValue)

    let snapshot = BackupUserDefaults.snapshot(from: source)
    #expect(snapshot.mapFilterLineOfSight == "{\"showDiscovered\":true}")

    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }
    let setKeys = snapshot.restore(to: target)
    #expect(setKeys.contains(AppStorageKey.mapFilterLineOfSight.rawValue))
    #expect(target.string(forKey: AppStorageKey.mapFilterLineOfSight.rawValue) == "{\"showDiscovered\":true}")
  }
}
