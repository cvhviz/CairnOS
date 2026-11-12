import Foundation
@testable import CairnServices
import Testing

@Suite("Map traffic default")
struct MapTrafficDefaultTests {
  @Test
  func `The maps draw traffic until the user switches it off`() {
    #expect(AppStorageKey.defaultMapShowsTraffic)
  }

  @Test
  func `A user who switched traffic off keeps it off`() throws {
    let defaults = try #require(UserDefaults(suiteName: "MapTrafficDefaultTests"))
    defer { defaults.removePersistentDomain(forName: "MapTrafficDefaultTests") }
    let key = AppStorageKey.mapShowsTraffic.rawValue

    // Nothing stored: the default applies, as @AppStorage reads it.
    #expect((defaults.object(forKey: key) as? Bool) ?? AppStorageKey.defaultMapShowsTraffic)

    defaults.set(false, forKey: key)
    #expect(((defaults.object(forKey: key) as? Bool) ?? AppStorageKey.defaultMapShowsTraffic) == false)
  }
}
