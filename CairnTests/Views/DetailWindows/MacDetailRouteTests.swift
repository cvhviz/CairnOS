@testable import Cairn
import Foundation
import Testing

@Suite("MacDetailRoute")
struct MacDetailRouteTests {
  static let routes: [MacDetailRoute] = [
    .contact(id: UUID(), canHideFromMap: true),
    .contact(id: UUID(), canHideFromMap: false),
    .discoveredNode(id: UUID(), radioID: UUID(), canHideFromMap: true),
    .discoveredNode(id: UUID(), radioID: UUID(), canHideFromMap: false),
  ]

  @Test(arguments: routes)
  func `Every route survives the scene's encode and decode`(route: MacDetailRoute) throws {
    let data = try JSONEncoder().encode(route)
    #expect(try JSONDecoder().decode(MacDetailRoute.self, from: data) == route)
  }

  @Test
  func `Opening the same node again matches its open window`() {
    let id = UUID()
    #expect(MacDetailRoute.contact(id: id, canHideFromMap: true) == .contact(id: id, canHideFromMap: true))
  }

  @Test
  func `Different nodes get their own windows`() {
    let radioID = UUID()
    #expect(MacDetailRoute.contact(id: UUID(), canHideFromMap: false) != .contact(id: UUID(), canHideFromMap: false))
    #expect(
      MacDetailRoute.discoveredNode(id: UUID(), radioID: radioID, canHideFromMap: false)
        != .discoveredNode(id: UUID(), radioID: radioID, canHideFromMap: false)
    )
  }

  @Test
  func `A node window opens with room for the map and dashboard it pushes`() {
    // No size limits (they stopped the window resizing from every edge); only where it opens.
    #expect(MacWindowSize.detail.preferred.width >= 640)
    #expect(MacWindowSize.detail.preferred.height >= 600)
  }
}
