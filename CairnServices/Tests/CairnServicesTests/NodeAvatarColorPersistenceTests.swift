import Foundation
@testable import CairnServices
import MeshCore
import SwiftData
import Testing

/// A node's picked avatar colour (`Contact.avatarColorRaw`) and this radio's own avatar
/// (`RadioAvatarStorage`): stored, kept through every contact update, carried in backups, and
/// read back as Automatic from rows and backups made before the colour existed.
@Suite("Node avatar colour persistence")
struct NodeAvatarColorPersistenceTests {
  private let publicKey = Data(repeating: 0x5C, count: 32)

  private func service(_ store: MockPersistenceStore) -> ContactService {
    ContactService(session: MockMeshCoreSession(), dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
  }

  // MARK: - ContactService

  @Test
  func `updateContactAvatarColor sets and clears the colour`() async throws {
    let store = MockPersistenceStore()
    let contact = ContactDTO.testContact(publicKey: publicKey)
    try await store.saveContact(contact)
    let service = service(store)

    try await service.updateContactAvatarColor(contactID: contact.id, color: .teal)
    #expect(await store.contacts[contact.id]?.avatarColor == .teal)
    #expect(await store.contacts[contact.id]?.avatarColorRaw == "teal")

    try await service.updateContactAvatarColor(contactID: contact.id, color: nil)
    #expect(await store.contacts[contact.id]?.avatarColor == nil)
  }

  @Test
  func `the colour survives photo, preference, favourite and OCV updates`() async throws {
    let store = MockPersistenceStore()
    let contact = ContactDTO.testContact(publicKey: publicKey)
    try await store.saveContact(contact)
    // The favourite write reads the radio's record first.
    let session = MockMeshCoreSession()
    await session.setStubbedContact(contact.toContactFrame().toMeshContact(), for: publicKey)
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)

    try await service.updateContactAvatarColor(contactID: contact.id, color: .purple)
    try await service.updateContactAvatar(contactID: contact.id, imageData: Data([0x01, 0x02]))
    try await service.updateContactPreferences(contactID: contact.id, nickname: "Base")
    try await service.setContactFavorite(contact.id, isFavorite: true)
    try await service.updateContactOCVSettings(contactID: contact.id, preset: OCVPreset.liIon.rawValue, customArray: nil)

    let updated = try #require(await store.contacts[contact.id])
    #expect(updated.avatarColor == .purple)
    #expect(updated.avatarImageData == Data([0x01, 0x02]))
    #expect(updated.nickname == "Base")
    #expect(updated.isFavorite)
  }

  @Test
  func `an unknown raw value reads as Automatic`() {
    let contact = ContactDTO.testContact(avatarColorRaw: "chartreuse-from-the-future")
    #expect(contact.avatarColor == nil)
  }

  // MARK: - Store

  @Test
  func `the colour round-trips through the store and survives a radio contact sync`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let contact = ContactDTO.testContact(radioID: radioID, publicKey: publicKey, name: "Alice", avatarColorRaw: "amber")
    try await store.saveContact(contact)
    #expect(try await store.fetchContact(id: contact.id)?.avatarColor == .amber)

    // A contact frame from the radio updates the row without touching app-side avatar fields.
    let frame = ContactFrame(
      publicKey: publicKey,
      type: .chat,
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0xFF,
      outPath: Data(),
      name: "Alice Renamed",
      lastAdvertTimestamp: 10,
      latitude: 0,
      longitude: 0,
      lastModified: 10
    )
    _ = try await store.saveContact(radioID: radioID, from: frame)
    let synced = try #require(await store.fetchContact(id: contact.id))
    #expect(synced.name == "Alice Renamed")
    #expect(synced.avatarColor == .amber)
  }

  // MARK: - Backups

  @Test
  func `the colour survives encode and decode, and old backups decode as Automatic`() throws {
    let withColor = ContactDTO.testContact(avatarColorRaw: NodeAvatarColor.purple.rawValue)
    let encoded = try JSONEncoder().encode(withColor)
    #expect(try JSONDecoder().decode(ContactDTO.self, from: encoded).avatarColor == .purple)

    var legacyJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyJSON.removeValue(forKey: "avatarColorRaw")
    let legacy = try JSONDecoder().decode(ContactDTO.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    #expect(legacy.avatarColorRaw == nil)
  }

  @Test
  func `a backup import inserts the colour and merges it onto a contact without one`() async throws {
    let radioID = UUID()
    let destStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let device = DeviceDTO.testDevice(id: radioID, radioID: radioID)
    let service = AppBackupService()

    let inserted = ContactDTO.testContact(radioID: radioID, publicKey: Data(repeating: 0x71, count: 32), name: "Bob", avatarColorRaw: "green")
    _ = try await service.importBackup(envelope: AppBackupEnvelope.test(devices: [device], contacts: [inserted]), into: destStore)
    #expect(try await destStore.fetchContact(radioID: radioID, publicKey: inserted.publicKey)?.avatarColor == .category(.companion))

    let local = ContactDTO.testContact(radioID: radioID, publicKey: Data(repeating: 0x72, count: 32), name: "Carol")
    try await destStore.saveContact(local)
    let backup = ContactDTO.testContact(radioID: radioID, publicKey: local.publicKey, name: "Carol", avatarColorRaw: "sky")
    _ = try await service.importBackup(envelope: AppBackupEnvelope.test(devices: [device], contacts: [backup]), into: destStore)
    #expect(try await destStore.fetchContact(radioID: radioID, publicKey: local.publicKey)?.avatarColor == .sky)

    // A colour already picked on this phone wins over the backup's.
    let otherBackup = ContactDTO.testContact(radioID: radioID, publicKey: local.publicKey, name: "Carol", avatarColorRaw: "red")
    _ = try await service.importBackup(envelope: AppBackupEnvelope.test(devices: [device], contacts: [otherBackup]), into: destStore)
    #expect(try await destStore.fetchContact(radioID: radioID, publicKey: local.publicKey)?.avatarColor == .sky)
  }

  // MARK: - Migration

  @Test
  func `a store written before the colour existed opens with every contact on Automatic`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("legacy.store")
    let radioID = UUID()
    let contactID = UUID()

    // Write a row with the Contact entity as it was before `avatarColorRaw`.
    do {
      let schema = Schema([LegacyAvatarSchema.Contact.self])
      let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
      let context = ModelContext(container)
      context.insert(LegacyAvatarSchema.Contact(
        id: contactID,
        radioID: radioID,
        publicKey: publicKey,
        name: "Legacy",
        avatarImageData: Data([0xAB])
      ))
      try context.save()
    }

    // Open it with today's full schema: SwiftData's inferred lightweight migration adds the column.
    let container = try ModelContainer(
      for: PersistenceStore.schema,
      configurations: [ModelConfiguration(schema: PersistenceStore.schema, url: storeURL)]
    )
    let store = PersistenceStore(modelContainer: container)
    let migrated = try #require(await store.fetchContact(id: contactID))
    #expect(migrated.name == "Legacy")
    #expect(migrated.avatarImageData == Data([0xAB]))
    #expect(migrated.avatarColorRaw == nil)

    try await store.saveContact(migrated.with(avatarColorRaw: "cyan"))
    #expect(try await store.fetchContact(id: contactID)?.avatarColor == .category(.channel))
  }

  // MARK: - This radio's avatar

  @Test
  func `this radio's colour and photo round-trip through a backup without overwriting local picks`() throws {
    let sourceSuite = "RadioAvatarBackup.source.\(UUID().uuidString)"
    let destSuite = "RadioAvatarBackup.dest.\(UUID().uuidString)"
    let source = try #require(UserDefaults(suiteName: sourceSuite))
    let dest = try #require(UserDefaults(suiteName: destSuite))
    let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      source.removePersistentDomain(forName: sourceSuite)
      dest.removePersistentDomain(forName: destSuite)
      try? FileManager.default.removeItem(at: sourceDir)
      try? FileManager.default.removeItem(at: destDir)
    }

    let radioA = UUID()
    let radioB = UUID()
    RadioAvatarStorage.setColor(.lime, radioID: radioA, defaults: source)
    RadioAvatarStorage.setColor(.purple, radioID: radioB, defaults: source)
    try RadioAvatarStorage.setPhoto(Data("photo-a".utf8), radioID: radioA, directory: sourceDir)
    try RadioAvatarStorage.setPhoto(Data("photo-b".utf8), radioID: radioB, directory: sourceDir)

    let snapshot = BackupUserDefaults.snapshot(from: source, radioAvatarDirectory: sourceDir)
    let decoded = try JSONDecoder().decode(BackupUserDefaults.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded.radioAvatarColors?[radioA.uuidString] == "lime")
    #expect(decoded.radioAvatarPhotos?[radioB.uuidString] == Data("photo-b".utf8))

    // The phone being restored already picked a colour and photo for radio B; those stay.
    RadioAvatarStorage.setColor(.red, radioID: radioB, defaults: dest)
    try RadioAvatarStorage.setPhoto(Data("local-b".utf8), radioID: radioB, directory: destDir)
    decoded.restore(to: dest, radioAvatarDirectory: destDir)

    #expect(RadioAvatarStorage.color(radioID: radioA, defaults: dest) == .lime)
    #expect(RadioAvatarStorage.color(radioID: radioB, defaults: dest) == .red)
    #expect(RadioAvatarStorage.photo(radioID: radioA, directory: destDir) == Data("photo-a".utf8))
    #expect(RadioAvatarStorage.photo(radioID: radioB, directory: destDir) == Data("local-b".utf8))
  }

  @Test
  func `a backup from before radio avatars decodes with none`() throws {
    let data = Data("{\"mapShowLabels\":true}".utf8)
    let decoded = try JSONDecoder().decode(BackupUserDefaults.self, from: data)
    #expect(decoded.radioAvatarColors == nil)
    #expect(decoded.radioAvatarPhotos == nil)
  }
}

/// The `Contact` entity as stored before `avatarColorRaw` was added, for the migration test.
enum LegacyAvatarSchema {
  @Model
  final class Contact {
    #Index<Contact>(
      [\.radioID],
      [\.radioID, \.publicKey]
    )

    @Attribute(.unique)
    var id: UUID
    var radioID: UUID
    var publicKey: Data
    var name: String
    var typeRawValue: UInt8 = 0
    var flags: UInt8 = 0
    var outPathLength: Int = 255
    var outPath = Data()
    var lastAdvertTimestamp: UInt32 = 0
    var latitude: Double = 0
    var longitude: Double = 0
    var lastModified: UInt32 = 0
    var lastHeardTimestamp: UInt32 = 0
    var nickname: String?
    var isBlocked = false
    var isMuted = false
    var isFavorite = false
    var lastMessageDate: Date?
    var unreadCount = 0
    var unreadMentionCount = 0
    var ocvPreset: String?
    var customOCVArrayString: String?
    var avatarImageData: Data?

    init(id: UUID, radioID: UUID, publicKey: Data, name: String, avatarImageData: Data?) {
      self.id = id
      self.radioID = radioID
      self.publicKey = publicKey
      self.name = name
      self.avatarImageData = avatarImageData
    }
  }
}
