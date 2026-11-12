import Foundation
@testable import Cairn
import Testing

@Suite("Map recency window")
struct MapRecencyTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

  @Test
  func `windows include only recent nodes`() {
    #expect(MapRecencyWindow.day.includes(lastHeard: ago(days: 0.5), now: now))
    #expect(!MapRecencyWindow.day.includes(lastHeard: ago(days: 2), now: now))
    #expect(MapRecencyWindow.week.includes(lastHeard: ago(days: 6), now: now))
    #expect(!MapRecencyWindow.week.includes(lastHeard: ago(days: 8), now: now))
    #expect(MapRecencyWindow.all.includes(lastHeard: ago(days: 400), now: now))
  }

  @Test
  func `pins fade with age down to a floor`() {
    #expect(MapRecencyWindow.week.pinOpacity(lastHeard: ago(days: 0.5), now: now) == 1)
    let mid = MapRecencyWindow.week.pinOpacity(lastHeard: ago(days: 4), now: now)
    #expect(mid < 1 && mid > 0.45)
    #expect(abs(MapRecencyWindow.week.pinOpacity(lastHeard: ago(days: 7), now: now) - 0.45) < 1e-9)
    #expect(abs(MapRecencyWindow.all.pinOpacity(lastHeard: ago(days: 300), now: now) - 0.45) < 1e-9)
  }

  @Test
  func `new installs see every discovered node`() {
    let seed = MapFilterState.seed(for: .mainMap)
    #expect(seed.showDiscovered)
    #expect(seed.heardWithin == .all)
  }

  @Test(arguments: MapFilterHost.allCases)
  func `no map leaves any node out until its filter is changed`(host: MapFilterHost) {
    let seed = MapFilterState.seed(for: host)
    #expect(seed.effectiveShowDiscovered)
    #expect(seed.heardWithin == .all)
    #expect(seed.showChat && seed.showRepeater && seed.showRoom)
  }

}
