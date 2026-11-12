import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import Testing

/// The Nodes tab's Nearby group: the located nodes nearest first, and the list order that
/// follows from having somewhere to measure from.
@Suite("CarPlay Nearby")
struct CarPlayNearbyTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let origin = CLLocation(latitude: 37.0, longitude: -122.0)

  private func node(_ name: String, latitude: Double?, longitude: Double?, saved: Bool = true) -> CarPlayNodesSource.Node {
    CarPlayNodesSource.Node(
      publicKey: Data(name.utf8),
      name: name,
      type: .repeater,
      lastHeard: now.addingTimeInterval(-60),
      latitude: latitude,
      longitude: longitude,
      route: L10n.Contacts.Contacts.Route.direct,
      isFavorite: false,
      isSaved: saved
    )
  }

  @Test
  func `Nearby is the located nodes nearest first, heard ones included`() {
    let nodes = [
      node("Far", latitude: 38.0, longitude: -122.0),
      node("Near", latitude: 37.01, longitude: -122.0),
      node("Nowhere", latitude: nil, longitude: nil),
      node("Middle", latitude: 37.1, longitude: -122.0, saved: false),
    ]
    let nearby = CarPlayNodesSource.nearby(nodes, origin: origin)
    #expect(nearby.map(\.name) == ["Near", "Middle", "Far"])
    #expect(CarPlayNodesSource.members(of: .nearby, in: nodes, heardKeys: [], origin: origin).map(\.name) == ["Near", "Middle", "Far"])
  }

  @Test
  func `Without an origin there is no Nearby group`() {
    let nodes = [node("Near", latitude: 37.01, longitude: -122.0)]
    #expect(CarPlayNodesSource.nearby(nodes, origin: nil).isEmpty)
    let rows = CarPlayNodesSource.categories(nodes, heardKeys: [], now: now)
    #expect(!rows.contains { $0.list == .category(.nearby) })
  }

  @Test
  func `The Nearby group row counts the located nodes and names the nearest with its distance`() throws {
    let nodes = [
      node("Far", latitude: 38.0, longitude: -122.0),
      node("Near", latitude: 37.01, longitude: -122.0),
      node("Nowhere", latitude: nil, longitude: nil),
    ]
    let rows = CarPlayNodesSource.categories(nodes, heardKeys: [], origin: origin, now: now)
    let nearby = try #require(rows.first { $0.list == .category(.nearby) })
    #expect(nearby.count == 2)
    #expect(nearby.latestName == "Near")
    #expect(nearby.latestAge == CarPlayNodesSource.distanceAndBearing(nodes[1], origin: origin))
    // Right after Find, ahead of the phone's groups.
    #expect(rows.map(\.list).prefix(2) == [.find, .category(.nearby)])
  }

  @Test
  func `The Nearby list is nearest first whatever order the app chose`() {
    let nodes = [
      node("Far", latitude: 38.0, longitude: -122.0),
      node("Near", latitude: 37.01, longitude: -122.0),
    ]
    let page = CarPlayNodesSource.page(.category(.nearby), nodes: nodes, sortOrder: .name, heardKeys: [], origin: origin, now: now)
    #expect(page.rows.map(\.name) == ["Near", "Far"])
    #expect(page.title == L10n.Localizable.CarPlay.Nodes.nearby)
  }

  @Test
  @MainActor
  func `Lists default to distance when there is an origin and no order was chosen`() {
    #expect(CarPlayController.nodeSortOrder(chosen: nil, hasOrigin: true) == .distance)
    #expect(CarPlayController.nodeSortOrder(chosen: nil, hasOrigin: false) == .lastHeard)
    #expect(CarPlayController.nodeSortOrder(chosen: .name, hasOrigin: true) == .name)
  }
}
