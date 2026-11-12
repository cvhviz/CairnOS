import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("NodeDiscoveryEntries")
@MainActor
struct NodeDiscoveryEntriesTests {
  private let anchor = CLLocationCoordinate2D(latitude: 21.30, longitude: -157.85)

  private func key(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: 32)
  }

  /// A node heard best at `heardAt`, or with no fix when it is nil, that advertised itself at
  /// `position` in a packet this radio received.
  private func result(
    _ byte: UInt8,
    name: String = "Node",
    snr: Double = 0,
    heardAt: CLLocationCoordinate2D? = nil,
    position: CLLocationCoordinate2D? = nil
  ) -> NodeDiscoveryResult {
    var result = NodeDiscoveryResult(
      name: name,
      publicKey: key(byte),
      nodeType: 0x02,
      snr: snr,
      rssi: -90,
      scanFilter: .repeaters,
      receivedAt: Date(),
      heardFrom: heardAt.map {
        NodeDiscoveryHeardFrom(
          fix: NodeDiscoveryFix(
            latitude: $0.latitude,
            longitude: $0.longitude,
            horizontalAccuracy: 5,
            timestamp: Date()
          ),
          snr: snr
        )
      }
    )
    result.coordinate = position
    return result
  }

  private func contact(_ byte: UInt8, latitude: Double = 0, longitude: Double = 0) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: key(byte),
      name: "Contact",
      typeRawValue: 0x02,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func discovered(_ byte: UInt8, latitude: Double, longitude: Double) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: key(byte),
      name: "Discovered",
      typeRawValue: 0x02,
      lastHeard: Date(),
      lastAdvertTimestamp: 0,
      latitude: latitude,
      longitude: longitude,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }

  /// One contact 0.1° north (~11 km), one unsaved node with no position, one contact 0.01° east,
  /// all heard at `anchor`, each where it advertised itself.
  private func sampleEntries() -> [NodeDiscoveryEntry] {
    NodeDiscoveryEntries.make(
      results: [
        result(0x01, name: "Bravo", snr: 2, heardAt: anchor, position: CLLocationCoordinate2D(latitude: 21.40, longitude: -157.85)),
        result(0x02, name: "alpha", snr: 9, heardAt: anchor),
        result(0x03, name: "Charlie", snr: -4, heardAt: anchor, position: CLLocationCoordinate2D(latitude: 21.30, longitude: -157.84)),
      ],
      contacts: [
        key(0x01): contact(0x01, latitude: 21.40, longitude: -157.85),
        key(0x03): contact(0x03, latitude: 21.30, longitude: -157.84),
      ],
      discovered: [:]
    )
  }

  @Test
  func `entries carry position, distance, direction and contact state`() throws {
    let entries = sampleEntries()
    let north = try #require(entries.first { $0.id == key(0x01) })
    #expect(north.isContact)
    #expect(!north.isNew)
    let distance = try #require(north.distance)
    #expect(abs(distance - 11_000) < 300)
    let bearing = try #require(north.bearing)
    #expect(HomeFormat.compassPointIndex(bearing: bearing) == 0)

    let stranger = try #require(entries.first { $0.id == key(0x02) })
    #expect(stranger.isNew)
    #expect(stranger.coordinate == nil)
    #expect(stranger.distance == nil)
  }

  @Test
  func `without a fix where it was heard there is no distance`() {
    let advertised = CLLocationCoordinate2D(latitude: 21.40, longitude: -157.85)
    let entries = NodeDiscoveryEntries.make(
      results: [
        result(0x01, position: advertised),
        result(0x02, heardAt: CLLocationCoordinate2D(latitude: 0, longitude: 0), position: advertised),
      ],
      contacts: [
        key(0x01): contact(0x01, latitude: 21.40, longitude: -157.85),
        key(0x02): contact(0x02, latitude: 21.40, longitude: -157.85),
      ],
      discovered: [:]
    )
    #expect(entries.allSatisfy { $0.coordinate != nil })
    #expect(entries.allSatisfy { $0.distance == nil && $0.bearing == nil })
    #expect(entries.allSatisfy {
      NodeDiscoveryFormat.placeLine($0).hasPrefix(L10n.Tools.Tools.NodeDiscovery.Map.noFixWhenHeard)
    })
  }

  @Test
  func `distance runs from where each node was heard`() throws {
    // Both nodes sit at the same spot; one was heard next to it, the other ~11 km south.
    let node = CLLocationCoordinate2D(latitude: 21.40, longitude: -157.85)
    let entries = NodeDiscoveryEntries.make(
      results: [result(0x01, heardAt: node, position: node), result(0x02, heardAt: anchor, position: node)],
      contacts: [
        key(0x01): contact(0x01, latitude: node.latitude, longitude: node.longitude),
        key(0x02): contact(0x02, latitude: node.latitude, longitude: node.longitude),
      ],
      discovered: [:]
    )
    let near = try #require(entries.first { $0.id == key(0x01) }?.distance)
    let far = try #require(entries.first { $0.id == key(0x02) }?.distance)
    #expect(near < 1)
    #expect(abs(far - 11_000) < 300)
  }

  @Test
  func `a stored record's position never places a row; only the node's own advert does`() throws {
    // A contact typed in (or imported) far away, and a discovered record, neither heard
    // advertising a position, are not placed; a node that advertised itself is placed there
    // even though its contact says otherwise.
    let heardAt = CLLocationCoordinate2D(latitude: 21.32, longitude: -157.86)
    let entries = NodeDiscoveryEntries.make(
      results: [result(0x01, heardAt: anchor), result(0x02, heardAt: anchor), result(0x03, heardAt: anchor, position: heardAt)],
      contacts: [
        key(0x01): contact(0x01, latitude: 19.60, longitude: -155.90),
        key(0x03): contact(0x03, latitude: 19.60, longitude: -155.90),
      ],
      discovered: [key(0x02): discovered(0x02, latitude: 21.40, longitude: -157.95)]
    )
    #expect(entries.first { $0.id == key(0x01) }?.coordinate == nil)
    #expect(entries.first { $0.id == key(0x02) }?.coordinate == nil)
    let placed = try #require(entries.first { $0.id == key(0x03) }?.coordinate)
    #expect(placed.latitude == heardAt.latitude)
    #expect(placed.longitude == heardAt.longitude)
  }

  @Test
  func `hidden keys are flagged`() {
    let entries = NodeDiscoveryEntries.make(
      results: [result(0x01)],
      contacts: [:],
      discovered: [:],
      hiddenKeys: [key(0x01)]
    )
    #expect(entries.first?.isHiddenFromMap == true)
  }

  @Test
  func `signal sorts strongest first`() {
    let sorted = NodeDiscoveryEntries.sorted(sampleEntries(), by: .snr)
    #expect(sorted.map(\.result.name) == ["alpha", "Bravo", "Charlie"])
  }

  @Test
  func `distance sorts nearest first and unplaced nodes last`() {
    let sorted = NodeDiscoveryEntries.sorted(sampleEntries(), by: .distance)
    #expect(sorted.map(\.result.name) == ["Charlie", "Bravo", "alpha"])
  }

  @Test
  func `name sorts alphabetically ignoring case`() {
    let sorted = NodeDiscoveryEntries.sorted(sampleEntries(), by: .name)
    #expect(sorted.map(\.result.name) == ["alpha", "Bravo", "Charlie"])
  }

  @Test
  func `ties keep a stable order by key`() {
    let entries = NodeDiscoveryEntries.make(
      results: [result(0x09, snr: 1), result(0x04, snr: 1)],
      contacts: [:],
      discovered: [:]
    )
    #expect(NodeDiscoveryEntries.sorted(entries, by: .snr).map(\.id) == [key(0x04), key(0x09)])
  }

  @Test
  func `filters split new nodes from contacts`() {
    let entries = sampleEntries()
    #expect(NodeDiscoveryEntries.count(entries, matching: .all) == 3)
    #expect(NodeDiscoveryEntries.count(entries, matching: .new) == 1)
    #expect(NodeDiscoveryEntries.count(entries, matching: .contacts) == 2)
    #expect(NodeDiscoveryEntries.filtered(entries, by: .new).map(\.id) == [key(0x02)])
    #expect(NodeDiscoveryEntries.chipsVisible(entries))
  }

  // MARK: - Chips

  @Test
  func `with the chips hidden every entry is listed whatever chip was picked`() {
    // Every node new: the chips have nothing to split, so they hide.
    let entries = NodeDiscoveryEntries.make(results: [result(0x01), result(0x02)], contacts: [:], discovered: [:])
    #expect(!NodeDiscoveryEntries.chipsVisible(entries))
    #expect(NodeDiscoveryEntries.filtered(entries, by: .new, chipsVisible: false).count == 2)
    #expect(NodeDiscoveryEntries.filtered(entries, by: .contacts, chipsVisible: false).count == 2)
    #expect(NodeDiscoveryEntries.filtered(entries, by: .contacts, chipsVisible: true).isEmpty)
  }

  @Test
  func `the picked chip goes back to All when the chips hide`() {
    #expect(NodeDiscoveryEntries.listFilter(.new, chipsVisible: false) == .all)
    #expect(NodeDiscoveryEntries.listFilter(.contacts, chipsVisible: false) == .all)
    #expect(NodeDiscoveryEntries.listFilter(.new, chipsVisible: true) == .new)
  }

  // MARK: - Unresolved rows

  /// A relay known only by `hash`, which no single node could be pinned on.
  private func relay(_ hash: Data, snr: Double, ambiguousAmong total: Int? = nil) -> NodeDiscoveryResult {
    let resolution: NeighbourResolution = if let total {
      .ambiguous(
        candidates: [NeighbourKeyEntry(publicKey: key(hash[0]), nodeTypeRaw: 2, name: "Maybe")],
        total: total
      )
    } else {
      .unknown(hash)
    }
    return NodeDiscoveryResult(
      id: .hash(hash),
      name: "Relay",
      isNamed: false,
      publicKey: nil,
      nodeType: 0x02,
      snr: snr,
      rssi: -70,
      scanFilter: .repeaters,
      receivedAt: Date(),
      resolution: resolution,
      sources: [.relay],
      isConfirmed: false
    )
  }

  @Test
  func `unresolved rows go last in every order and are never placed`() {
    let entries = NodeDiscoveryEntries.make(
      results: [relay(Data([0x01]), snr: 20), result(0x01, name: "Bravo", snr: 2, heardAt: anchor), relay(Data([0x02, 0x03]), snr: 15, ambiguousAmong: 3)],
      contacts: [key(0x01): contact(0x01, latitude: 21.40, longitude: -157.85)],
      discovered: [:]
    )
    for order in NodeDiscoverySortOrder.allCases {
      let sorted = NodeDiscoveryEntries.sorted(entries, by: order)
      #expect(sorted.first?.id == key(0x01), "\(order): the named node leads")
      #expect(sorted.dropFirst().allSatisfy { !$0.result.isResolved })
    }
    let relays = entries.filter { !$0.result.isResolved }
    #expect(relays.allSatisfy { $0.coordinate == nil && $0.distance == nil && !$0.isContact })
    #expect(relays.map(\.id) == [Data([0x01]), Data([0x02, 0x03])], "keyed by their hash")
    #expect(relays.last?.result.candidates?.total == 3)
  }

  // MARK: - Badges and freshness

  @Test
  func `badges follow the evidence`() {
    let answered = NodeDiscoveryResult(
      name: "Node",
      publicKey: key(0x01),
      nodeType: 0x02,
      snr: 4,
      rssi: -80,
      scanFilter: .repeaters,
      receivedAt: Date(),
      sources: [.replyToUs, .relay, .advert, .replyToOthers],
      uplinkSNR: 6,
      hearsYou: true
    )
    #expect(NodeDiscoveryFormat.badges(answered) == [.relaying, .advert, .answeredYourScan, .answeredAnotherScan, .hearsYou])
    #expect(!NodeDiscoveryFormat.isDimmed(answered))

    let once = relay(Data([0x0A]), snr: 1)
    #expect(NodeDiscoveryFormat.badges(once) == [.relaying, .heardOnce])
    #expect(NodeDiscoveryFormat.isDimmed(once), "a relay heard once is drawn faded")
  }

  @Test
  func `older rows are drawn faded`() {
    let older = NodeDiscoveryResult(
      name: "Older",
      publicKey: key(0x0D),
      nodeType: 0x02,
      snr: 3,
      rssi: -90,
      scanFilter: .repeaters,
      receivedAt: Date(),
      freshness: .older
    )
    #expect(NodeDiscoveryFormat.isDimmed(older))
  }

  @Test
  func `rows heard before the current scan are drawn faded and listed after its own`() {
    func row(_ byte: UInt8, snr: Double, isEarlier: Bool) -> NodeDiscoveryResult {
      NodeDiscoveryResult(
        name: "Node \(byte)",
        publicKey: key(byte),
        nodeType: 0x02,
        snr: snr,
        rssi: -80,
        scanFilter: .repeaters,
        receivedAt: Date(),
        isEarlier: isEarlier
      )
    }
    let earlier = row(0x01, snr: 12, isEarlier: true)
    #expect(NodeDiscoveryFormat.isDimmed(earlier))
    #expect(!NodeDiscoveryFormat.isDimmed(row(0x02, snr: 3, isEarlier: false)))

    let entries = NodeDiscoveryEntries.make(
      results: [earlier, row(0x02, snr: 3, isEarlier: false), row(0x03, snr: 6, isEarlier: false)],
      contacts: [:],
      discovered: [:]
    )
    for order in NodeDiscoverySortOrder.allCases {
      #expect(NodeDiscoveryEntries.sorted(entries, by: order).last?.id == key(0x01), "\(order)")
    }
    #expect(NodeDiscoveryEntries.sorted(entries, by: .snr).map(\.id) == [key(0x03), key(0x02), key(0x01)])
  }

  @Test
  func `freshness says how long ago, never in the future`() {
    let start = Date(timeIntervalSince1970: 1000)
    #expect(NodeDiscoveryFormat.freshness(lastHeard: start, now: start + 125)
      == L10n.Tools.Tools.NodeDiscovery.freshness(HomeFormat.age(125)))
    #expect(NodeDiscoveryFormat.freshness(lastHeard: start, now: start + 20) == L10n.Chats.Chats.Timestamp.now)
    #expect(NodeDiscoveryFormat.freshness(lastHeard: start + 10, now: start) == L10n.Chats.Chats.Timestamp.now)
  }

  @Test
  func `an unmeasured uplink is left out of what VoiceOver reads`() throws {
    let entry = try #require(NodeDiscoveryEntries.make(results: [result(0x01, snr: 3)], contacts: [:], discovered: [:]).first)
    let value = NodeDiscoveryFormat.accessibilityValue(entry)
    #expect(value.contains(L10n.Tools.Tools.NodeDiscovery.youHearThem))
    #expect(!value.contains(L10n.Tools.Tools.NodeDiscovery.theyHearYou))
  }

  @Test
  func `summary picks the best signal and the farthest located node`() throws {
    let summary = NodeDiscoverySummary(entries: sampleEntries())
    #expect(summary.replied == 3)
    #expect(summary.newCount == 1)
    let best = try #require(summary.bestSignal)
    #expect(best.name == "alpha")
    #expect(best.value == 9)
    let farthest = try #require(summary.farthest)
    #expect(farthest.name == "Bravo")
  }

  @Test
  func `summary of no replies has no highlights`() {
    let summary = NodeDiscoverySummary(entries: [])
    #expect(summary.replied == 0)
    #expect(summary.bestSignal == nil)
    #expect(summary.farthest == nil)
  }

  @Test
  func `summary has no farthest node without distances`() {
    let entries = NodeDiscoveryEntries.make(results: [result(0x01, snr: 3)], contacts: [:], discovered: [:])
    let summary = NodeDiscoverySummary(entries: entries)
    #expect(summary.bestSignal != nil)
    #expect(summary.farthest == nil)
  }

  @Test
  func `snr is signed with one decimal`() {
    let locale = Locale(identifier: "en_US")
    #expect(NodeDiscoveryFormat.snr(10.5, locale: locale).hasPrefix("+10.5"))
    #expect(NodeDiscoveryFormat.snr(-3, locale: locale).hasPrefix("-3.0"))
  }
}
