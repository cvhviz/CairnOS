@testable import CairnServices
import Foundation
import MeshCore
import Testing

@Suite("NeighbourResolver")
struct NeighbourResolverTests {
  // MARK: - Fixtures

  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
  private static let radioID = UUID()

  private func key(_ prefix: [UInt8], fill: UInt8 = 0x10) -> Data {
    Data(prefix + [UInt8](repeating: fill, count: 32 - prefix.count))
  }

  /// An observation of `key` on the channel: heard straight from it when `hops` is 0.
  private func observed(
    _ key: Data,
    type: UInt8 = 2,
    name: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    hops: Int = 2,
    at date: Date = now.addingTimeInterval(-600)
  ) -> NodeObservation {
    NodeObservation(
      identity: ObservedIdentity(bytes: key)!,
      kind: hops == 0 ? .advertDirect : .advertRelayed,
      channelKey: Self.channel.key,
      at: date,
      hops: hops,
      snr: 6,
      rssi: -90,
      name: name,
      nodeTypeRaw: type,
      latitude: latitude,
      longitude: longitude
    )
  }

  private func index(_ observations: [NodeObservation], contacts: [ContactDTO] = []) -> PacketNodeIndex {
    var ledger = ObservationLedger(radioID: Self.radioID, channel: Self.channel, selfKey: nil)
    ledger.ingest(observations)
    return PacketNodeIndex(
      ledger: ledger.snapshot(takenAt: Self.now),
      unobserved: NeighbourKeyIndex(entries: contacts.map(NeighbourKeyEntry.init))
    )
  }

  private func relay(_ hash: [UInt8], packet: String) -> NeighbourEvidence {
    NeighbourEvidence(identity: .hash(Data(hash)), source: .relay, snr: 4, rssi: -100, packetHash: packet)
  }

  private func advert(_ key: Data, type: UInt8 = 2, name: String? = nil) -> NeighbourEvidence {
    NeighbourEvidence(identity: .fullKey(key), source: .advert, snr: 7, rssi: -90, nodeTypeRaw: type, name: name, packetHash: "ADV")
  }

  private func row(_ identity: NeighbourIdentity, lastHeard: Date = now.addingTimeInterval(-60)) -> NeighbourRecord {
    NeighbourRecord(identity: identity, firstHeard: lastHeard, lastHeard: lastHeard, heardCount: 1)
  }

  // MARK: - Resolution Rules

  @Test
  func `a hash row resolves to the only observed node with it, at any size`() {
    let hilltop = key([0x3A, 0x7F, 0x21])
    let index = index([observed(hilltop, name: "Hilltop"), observed(key([0x5C, 0x01]))])
    #expect(NeighbourResolver.resolve(row(.hash(Data([0x3A, 0x7F, 0x21]))), index: index).entry?.name == "Hilltop")
    #expect(NeighbourResolver.resolve(row(.hash(Data([0x3A]))), index: index).entry?.publicKey == hilltop)
    #expect(NeighbourResolver.resolve(row(.hash(Data([0x99]))), index: index) == .unknown(Data([0x99])))
  }

  @Test
  func `a hash only a saved contact has stays unknown`() {
    let kona = ContactDTO.testContact(publicKey: key([0x7F, 0x3A]), name: "Kona Hill", typeRawValue: 2, latitude: 19.6, longitude: -155.9)
    let index = index([observed(key([0x5C, 0x01]), name: "Local")], contacts: [kona])
    #expect(NeighbourResolver.resolve(row(.hash(Data([0x7F]))), index: index) == .unknown(Data([0x7F])))
  }

  @Test
  func `two observed nodes sharing a byte are ambiguous, the one heard directly first`() throws {
    let north = key([0x3A, 0x01])
    let south = key([0x3A, 0x02])
    let index = index([observed(north, name: "North", hops: 3), observed(south, name: "South", hops: 0)])

    guard case let .ambiguous(candidates, total) = NeighbourResolver.resolve(row(.hash(Data([0x3A]))), index: index) else {
      Issue.record("Expected an ambiguous 1-byte hash")
      return
    }
    #expect(total == 2)
    #expect(candidates.map(\.publicKey) == [south, north])
  }

  @Test
  func `a hash row joins the key row it resolves to`() throws {
    let south = key([0x3A, 0x02])
    let index = index([observed(south, name: "South", hops: 0)])
    var table = NeighbourTable()
    table.ingest(relay([0x3A], packet: "P1"), at: Self.now.addingTimeInterval(-60))
    table.ingest(relay([0x3A, 0x02], packet: "P2"), at: Self.now.addingTimeInterval(-50))
    table.ingest(advert(south, name: "South"), at: Self.now.addingTimeInterval(-30))

    let rows = NeighbourResolver.resolveAll(table, index: index, now: Self.now)
    let southRow = try #require(rows.first { $0.resolution.entry?.publicKey == south })
    #expect(rows.count == 1)
    #expect(southRow.record.identity == .fullKey(south))
    #expect(southRow.record.heardCount == 3)
    #expect(southRow.identities.first == .fullKey(south))
    #expect(Set(southRow.identities) == [.fullKey(south), .hash(Data([0x3A, 0x02])), .hash(Data([0x3A]))])
  }

  @Test
  func `a node observed later resolves an earlier hash row on the next snapshot`() {
    var table = NeighbourTable()
    table.ingest(relay([0x3A, 0x7F], packet: "P1"), at: Self.now.addingTimeInterval(-120))
    let hilltop = key([0x3A, 0x7F, 0x21])

    let before = NeighbourResolver.resolveAll(table, index: index([]), now: Self.now)
    #expect(before.first?.resolution == .unknown(Data([0x3A, 0x7F])))

    let after = NeighbourResolver.resolveAll(table, index: index([observed(hilltop, name: "Hilltop")]), now: Self.now)
    #expect(after.first?.resolution.entry?.publicKey == hilltop)
  }

  @Test
  func `full keys and 8-byte prefixes always resolve, filled from their row`() {
    let hilltop = key([0x3A, 0x7F, 0x21])
    var fullRow = row(.fullKey(hilltop))
    fullRow.name = "Hilltop"
    fullRow.nodeTypeRaw = 2
    #expect(NeighbourResolver.resolve(fullRow, index: index([])).entry?.name == "Hilltop")

    let prefix = Data(hilltop.prefix(8))
    #expect(NeighbourResolver.resolve(row(.keyPrefix(prefix)), index: index([])).entry?.publicKey == prefix)
    #expect(NeighbourResolver.resolve(row(.keyPrefix(prefix)), index: index([observed(hilltop, name: "Hilltop")])).entry?.publicKey == hilltop)
  }

  @Test
  func `an ambiguous hash lists at most 4 candidates`() {
    let index = index((1...6).map { observed(key([0x3C, UInt8($0)]), hops: $0) })
    guard case let .ambiguous(candidates, total) = NeighbourResolver.resolve(row(.hash(Data([0x3C]))), index: index) else {
      Issue.record("Expected an ambiguous hash")
      return
    }
    #expect(total == 6)
    #expect(candidates.count == NeighbourResolver.maximumListedCandidates)
    #expect(candidates.first?.publicKey == key([0x3C, 0x01]))
  }

  @Test
  func `a cold index resolves no hash row`() {
    let table = NeighbourTable(records: [row(.hash(Data([0x3A])))])
    let rows = NeighbourResolver.resolveAll(table, index: .empty, now: Self.now)
    #expect(rows.map(\.resolution) == [.unknown(Data([0x3A]))])
  }
}
