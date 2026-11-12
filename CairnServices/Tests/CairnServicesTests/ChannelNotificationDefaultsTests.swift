import Foundation
@testable import CairnServices
import Testing

@Suite("ChannelNotificationDefaults")
struct ChannelNotificationDefaultsTests {
  private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "test.channelNotificationDefaults.\(UUID().uuidString)"
    return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
  }

  @Test
  func `an unset preference falls back to notifying for everything`() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(ChannelNotificationDefaults.level(from: defaults) == .all)
  }

  @Test(arguments: NotificationLevel.allCases)
  func `a chosen level round trips`(level: NotificationLevel) throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ChannelNotificationDefaults.setLevel(level, in: defaults)
    #expect(ChannelNotificationDefaults.level(from: defaults) == level)
  }

  @Test
  func `an unknown stored value falls back instead of crashing`() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(99, forKey: ChannelNotificationDefaults.defaultsKey)
    #expect(ChannelNotificationDefaults.level(from: defaults) == .all)
  }

  @Test
  func `backup carries the level and restore fills it when unset`() throws {
    let (source, sourceName) = try makeDefaults()
    defer { source.removePersistentDomain(forName: sourceName) }
    ChannelNotificationDefaults.setLevel(.mentionsOnly, in: source)

    let snapshot = BackupUserDefaults.snapshot(from: source)
    #expect(snapshot.defaultChannelNotificationLevel == NotificationLevel.mentionsOnly.rawValue)

    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }
    _ = snapshot.restore(to: target)
    #expect(ChannelNotificationDefaults.level(from: target) == .mentionsOnly)
  }

  @Test
  func `setAllChannelsNotificationLevel changes one radio's channels only`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let radioID = UUID()
    let otherRadioID = UUID()
    let secret = Data(repeating: 0xA1, count: 16)
    let first = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 1, name: "One", secret: secret))
    let second = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 2, name: "Two", secret: secret))
    let other = try await store.saveChannel(radioID: otherRadioID, from: ChannelInfo(index: 1, name: "Other", secret: secret))

    try await store.setAllChannelsNotificationLevel(radioID: radioID, level: .mentionsOnly)

    #expect(try await store.fetchChannel(id: first)?.notificationLevel == .mentionsOnly)
    #expect(try await store.fetchChannel(id: second)?.notificationLevel == .mentionsOnly)
    #expect(try await store.fetchChannel(id: other)?.notificationLevel == .all)
  }
}
