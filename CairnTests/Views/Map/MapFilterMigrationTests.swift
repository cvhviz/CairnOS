import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("MapFilterPreferences migration")
struct MapFilterMigrationTests {
  @Test
  func `tracePath missing key seeds discovered true without writing`() throws {
    let suiteName = "mapFilter.trace.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    let outcome = MapFilterPreferences.resolveMigrating(host: .tracePath, from: suite)
    #expect(outcome.state.showDiscovered == true)
    #expect(!outcome.didWrite)
    #expect(suite.object(forKey: AppStorageKey.mapFilterTracePath.rawValue) == nil)
  }

  @Test
  func `neighborSNR missing key seeds discovered on without writing`() throws {
    let suiteName = "mapFilter.neighbor.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    let outcome = MapFilterPreferences.resolveMigrating(host: .neighborSNR, from: suite)
    #expect(outcome.state.showDiscovered == true)
    #expect(outcome.state.favoritesOnly == false)
    #expect(!outcome.didWrite)
    #expect(suite.object(forKey: AppStorageKey.mapFilterNeighborSNR.rawValue) == nil)
  }

  @Test
  func `pure seed load leaves mainMap key absent`() throws {
    let suiteName = "mapFilter.pureSeed.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    let outcome = MapFilterPreferences.resolveMigrating(host: .mainMap, from: suite)
    #expect(outcome.state == MapFilterState.seed(for: .mainMap).sanitized(for: .mainMap))
    #expect(!outcome.didWrite)
    #expect(suite.object(forKey: AppStorageKey.mapFilterMainMap.rawValue) == nil)
  }

  @Test
  func `corrupt stored JSON falls back to seed via missing decode`() throws {
    let suiteName = "mapFilter.corrupt.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    suite.set("{not-json", forKey: AppStorageKey.mapFilterMainMap.rawValue)
    // Invalid string fails init?(storageString:), so resolveMigrating re-seeds and overwrites.
    let outcome = MapFilterPreferences.resolveMigrating(host: .mainMap, from: suite)
    #expect(
      outcome.state == MapFilterState.seed(for: .mainMap)
        .sanitized(for: .mainMap)
    )
    #expect(outcome.didWrite)
    #expect(suite.string(forKey: AppStorageKey.mapFilterMainMap.rawValue) != nil)
  }

  @Test
  func `ensureMigrated leaves empty raw when pure seed`() throws {
    let suiteName = "mapFilter.ensureEmpty.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    var raw = ""
    MapFilterPreferences.ensureMigrated(raw: &raw, host: .mainMap, defaults: suite)
    #expect(raw.isEmpty)
    #expect(suite.object(forKey: AppStorageKey.mapFilterMainMap.rawValue) == nil)
  }

  @Test
  func `ensureMigrated leaves valid raw unchanged`() throws {
    let suiteName = "mapFilter.ensureValid.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    let original = MapFilterState(
      showDiscovered: true,
      showChat: false,
      showRepeater: true,
      showRoom: true
    ).storageString
    var raw = original
    MapFilterPreferences.ensureMigrated(raw: &raw, host: .mainMap, defaults: suite)
    #expect(raw == original)
    #expect(suite.object(forKey: AppStorageKey.mapFilterMainMap.rawValue) == nil)
  }

  @Test
  func `ensureMigrated rewrites all types off`() throws {
    let suiteName = "mapFilter.ensureSanitize.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    let corrupt = MapFilterState(showChat: false, showRepeater: false, showRoom: false)
    var raw = corrupt.storageString
    MapFilterPreferences.ensureMigrated(raw: &raw, host: .mainMap, defaults: suite)
    let repaired = try #require(MapFilterState(storageString: raw))
    #expect(repaired.showChat && repaired.showRepeater && repaired.showRoom)
    #expect(suite.string(forKey: AppStorageKey.mapFilterMainMap.rawValue) == raw)
  }

  @Test
  func `state from empty raw equals host seed`() {
    let main = MapFilterPreferences.state(fromRaw: "", host: .mainMap)
    #expect(main == MapFilterState.seed(for: .mainMap).sanitized(for: .mainMap))
    let trace = MapFilterPreferences.state(fromRaw: "", host: .tracePath)
    #expect(trace == MapFilterState.seed(for: .tracePath).sanitized(for: .tracePath))
  }

  @Test
  func `encode sanitizes all types off`() throws {
    let raw = MapFilterState(showChat: false, showRepeater: false, showRoom: false)
    let encoded = MapFilterPreferences.encode(raw, host: .mainMap)
    let decoded = try #require(MapFilterState(storageString: encoded))
    #expect(decoded.showChat && decoded.showRepeater && decoded.showRoom)
  }

  @Test
  func `stored all types off is sanitized on load and rewritten`() throws {
    let suiteName = "mapFilter.allTypesOff.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }

    let corrupt = MapFilterState(
      showChat: false,
      showRepeater: false,
      showRoom: false
    )
    suite.set(corrupt.storageString, forKey: AppStorageKey.mapFilterMainMap.rawValue)
    let outcome = MapFilterPreferences.resolveMigrating(host: .mainMap, from: suite)
    #expect(outcome.state.showChat && outcome.state.showRepeater && outcome.state.showRoom)
    #expect(outcome.didWrite)
    let rewritten = MapFilterState(storageString: suite.string(forKey: AppStorageKey.mapFilterMainMap.rawValue) ?? "")
    #expect(rewritten?.showChat == true)
  }
}
