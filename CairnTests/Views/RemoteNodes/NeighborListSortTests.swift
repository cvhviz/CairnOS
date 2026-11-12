import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("Neighbor list sort and search")
@MainActor
struct NeighborListSortTests {
  private let alpha = Data([0xAA, 0x01, 0x02, 0x03, 0x04, 0x05])
  private let bravo = Data([0xBB, 0x01, 0x02, 0x03, 0x04, 0x05])
  private let charlie = Data([0xCC, 0x01, 0x02, 0x03, 0x04, 0x05])

  private var neighbors: [Neighbour] {
    [
      Neighbour(publicKeyPrefix: alpha, secondsAgo: 300, snr: 4.5),
      Neighbour(publicKeyPrefix: bravo, secondsAgo: 30, snr: -2.0),
      Neighbour(publicKeyPrefix: charlie, secondsAgo: 3000, snr: 11.25),
    ]
  }

  private func name(_ prefix: Data) -> String {
    switch prefix {
    case alpha: "Zed Hill"
    case bravo: "Mast"
    default: "Barn"
    }
  }

  @Test
  func `signal puts the strongest first`() {
    let sorted = NeighborListSort.snr.sorted(neighbors, name: name)
    #expect(sorted.map(\.publicKeyPrefix) == [charlie, alpha, bravo])
  }

  @Test
  func `last heard puts the most recent first`() {
    let sorted = NeighborListSort.lastHeard.sorted(neighbors, name: name)
    #expect(sorted.map(\.publicKeyPrefix) == [bravo, alpha, charlie])
  }

  @Test
  func `name sorts alphabetically, case-insensitively`() {
    let sorted = NeighborListSort.name.sorted(neighbors, name: name)
    #expect(sorted.map { name($0.publicKeyPrefix) } == ["Barn", "Mast", "Zed Hill"])
  }

  @Test
  func `new first leads with first-seen neighbours, then signal`() {
    let sorted = NeighborListSort.newFirst.sorted(neighbors, name: name) { $0 == bravo }
    #expect(sorted.map(\.publicKeyPrefix) == [bravo, charlie, alpha])
  }

  @Test
  func `search matches names and key prefixes, blank keeps all`() {
    #expect(NeighborListSort.filtered(neighbors, query: "  ", name: name).count == 3)
    #expect(NeighborListSort.filtered(neighbors, query: "mast", name: name).map(\.publicKeyPrefix) == [bravo])
    #expect(NeighborListSort.filtered(neighbors, query: "cc01", name: name).map(\.publicKeyPrefix) == [charlie])
    #expect(NeighborListSort.filtered(neighbors, query: "nothing", name: name).isEmpty)
  }
}
