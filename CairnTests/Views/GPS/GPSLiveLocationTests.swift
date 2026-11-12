@testable import Cairn
import Testing

/// The GPS page and the full-screen compass share one `GPSLiveLocation`; each holds its own claim
/// so the order SwiftUI runs their appear and disappear calls in can't stop the other's updates.
@MainActor
@Suite("GPS live location clients")
struct GPSLiveLocationTests {
  @Test
  func `The page leaving after the compass appears keeps updates running`() {
    let live = GPSLiveLocation(tracksHeading: false)
    live.start()
    live.start(for: .fullScreenCompass)
    live.stop()
    #expect(live.isActive)
    live.stop(for: .fullScreenCompass)
    #expect(!live.isActive)
  }

  @Test
  func `The compass closing leaves the page's updates running`() {
    let live = GPSLiveLocation(tracksHeading: false)
    live.start()
    live.start(for: .fullScreenCompass)
    live.stop(for: .fullScreenCompass)
    #expect(live.isActive)
    live.stop()
    #expect(!live.isActive)
  }

  @Test
  func `Repeated starts need only one stop, and extra stops are harmless`() {
    let live = GPSLiveLocation(tracksHeading: false)
    live.start()
    live.start()
    live.stop()
    #expect(!live.isActive)
    live.stop()
    live.stop(for: .fullScreenCompass)
    #expect(!live.isActive)
  }

  @Test
  func `A stop for a client that never started leaves the others running`() {
    let live = GPSLiveLocation(tracksHeading: false)
    live.start()
    live.stop(for: .fullScreenCompass)
    #expect(live.isActive)
  }
}
