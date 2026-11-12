import Foundation
@testable import CairnServices
import Testing

@Suite("RadioConfigProfileStore")
struct RadioConfigProfileStoreTests {
  /// A store in its own temporary directory; the caller removes the directory afterwards.
  private func makeStore() -> (store: RadioConfigProfileStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RadioConfigProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
    return (RadioConfigProfileStore(fileURL: directory.appendingPathComponent("profiles.json")), directory)
  }

  private func makeConfig() -> MeshCoreNodeConfig {
    MeshCoreNodeConfig(
      name: "Basecamp",
      publicKey: String(repeating: "ab", count: 32),
      privateKey: String(repeating: "cd", count: 64),
      radioSettings: .init(frequency: 910_525, bandwidth: 62500, spreadingFactor: 7, codingRate: 5, txPower: 22),
      positionSettings: .init(latitude: "47.6", longitude: "-122.3"),
      otherSettings: .init(manualAddContacts: 1, advertLocationPolicy: 0),
      channels: [.init(name: "Public", secret: String(repeating: "0", count: 32))],
      contacts: [.init(
        type: 1, name: "Peer", publicKey: String(repeating: "ef", count: 32), flags: 0,
        latitude: "0", longitude: "0", lastAdvert: 0, lastModified: 0
      )]
    )
  }

  @Test
  func `No file loads as an empty list`() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try store.load().isEmpty)
  }

  @Test
  func `A saved profile round-trips with its contents`() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let profile = RadioConfigProfile(name: "Hiking", createdAt: created, sourceDeviceName: "Basecamp", config: makeConfig())

    try store.upsert(profile)
    let loaded = try store.load()

    #expect(loaded == [profile])
    #expect(loaded.first?.config.radioSettings?.frequency == 910_525)
    #expect(loaded.first?.config.channels?.map(\.name) == ["Public"])
    #expect(loaded.first?.config.name == "Basecamp")
  }

  @Test
  func `A profile never keeps keys, contacts or position`() {
    let profile = RadioConfigProfile(name: "Hiking", config: makeConfig())

    #expect(profile.config.privateKey == nil)
    #expect(profile.config.publicKey == nil)
    #expect(profile.config.contacts == nil)
    #expect(profile.config.positionSettings == nil)
    #expect(profile.config.radioSettings != nil)
  }

  @Test
  func `Decoding strips a key written into the file by hand`() throws {
    let profile = RadioConfigProfile(name: "Hiking", config: makeConfig())
    let encoder = JSONEncoder()
    var json = try #require(
      try JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any]
    )
    var config = try #require(json["config"] as? [String: Any])
    config["private_key"] = String(repeating: "cd", count: 64)
    json["config"] = config

    let decoded = try JSONDecoder().decode(
      RadioConfigProfile.self,
      from: JSONSerialization.data(withJSONObject: json)
    )

    #expect(decoded.config.privateKey == nil)
  }

  @Test
  func `Rename trims, and a blank name changes nothing`() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = RadioConfigProfile(name: "Hiking", config: makeConfig())
    try store.upsert(profile)

    #expect(try store.rename(id: profile.id, to: "  Summit  ").first?.name == "Summit")
    #expect(try store.rename(id: profile.id, to: "   ").first?.name == "Summit")
  }

  @Test
  func `Upsert replaces the profile with the same ID`() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var profile = RadioConfigProfile(name: "Hiking", config: makeConfig())
    try store.upsert(profile)
    profile.config.radioSettings?.txPower = 10

    let profiles = try store.upsert(profile)

    #expect(profiles.count == 1)
    #expect(profiles.first?.config.radioSettings?.txPower == 10)
  }

  @Test
  func `Deleting the last profile removes the file`() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = RadioConfigProfile(name: "Hiking", config: makeConfig())
    try store.upsert(profile)

    #expect(try store.delete(id: profile.id).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  @Test
  func `Profiles sort by name naturally, then oldest first`() {
    let config = MeshCoreNodeConfig()
    let older = RadioConfigProfile(name: "Trail", createdAt: Date(timeIntervalSince1970: 1), config: config)
    let newer = RadioConfigProfile(name: "Trail", createdAt: Date(timeIntervalSince1970: 2), config: config)
    let ten = RadioConfigProfile(name: "Site 10", config: config)
    let two = RadioConfigProfile(name: "Site 2", config: config)

    let sorted = RadioConfigProfileStore.sorted([newer, ten, older, two])

    #expect(sorted.map(\.id) == [two.id, ten.id, older.id, newer.id])
  }

  @Test
  func `Export data is the plain node config format`() throws {
    let profile = RadioConfigProfile(name: "Hiking", config: makeConfig())

    let decoded = try JSONDecoder().decode(MeshCoreNodeConfig.self, from: profile.exportData())

    #expect(decoded == profile.config)
  }
}
