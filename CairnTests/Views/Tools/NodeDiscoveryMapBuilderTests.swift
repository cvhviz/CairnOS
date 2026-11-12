import CoreLocation
import Foundation
import MapKit
@testable import Cairn
import CairnServices
import Testing

@Suite("NodeDiscoveryMapBuilder")
@MainActor
struct NodeDiscoveryMapBuilderTests {
  private let contactKey = Data(repeating: 0xAA, count: 32)
  private let discoveredKey = Data(repeating: 0xBB, count: 32)
  private let unlocatedKey = Data(repeating: 0xCC, count: 32)
  private let anchor = CLLocationCoordinate2D(latitude: 21.35, longitude: -157.90)
  private let allNodes = MapFilterState(showDiscovered: true)

  private func heardFrom(_ coordinate: CLLocationCoordinate2D, snr: Double = 7.5) -> NodeDiscoveryHeardFrom {
    NodeDiscoveryHeardFrom(
      fix: NodeDiscoveryFix(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        horizontalAccuracy: 5,
        timestamp: Date()
      ),
      snr: snr
    )
  }

  /// Where each fixture node advertised itself in a packet this radio received; the unlocated
  /// node never did.
  private var advertised: [Data: CLLocationCoordinate2D] {
    [
      contactKey: CLLocationCoordinate2D(latitude: 21.30, longitude: -157.85),
      discoveredKey: CLLocationCoordinate2D(latitude: 21.40, longitude: -157.95),
    ]
  }

  /// A node heard best at `heardAt`, or with no fix when it is nil, placed where it advertised
  /// itself (``advertised``).
  private func result(
    _ key: Data,
    nodeType: UInt8 = 0x02,
    snr: Double = 7.5,
    heardAt: CLLocationCoordinate2D? = nil,
    isEarlier: Bool = false
  ) -> NodeDiscoveryResult {
    var result = NodeDiscoveryResult(
      name: "Node",
      publicKey: key,
      nodeType: nodeType,
      snr: snr,
      rssi: -90,
      scanFilter: .repeaters,
      receivedAt: Date(),
      heardFrom: heardAt.map { heardFrom($0, snr: snr) },
      isEarlier: isEarlier
    )
    result.coordinate = advertised[key]
    return result
  }

  private func contact(_ key: Data, latitude: Double, longitude: Double, isFavorite: Bool = false) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: key,
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
      isFavorite: isFavorite,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func discovered(_ key: Data, latitude: Double, longitude: Double) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: key,
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

  private func build(
    _ results: [NodeDiscoveryResult],
    filter: MapFilterState? = nil,
    overridesFilter: Bool = false
  ) -> NodeDiscoveryMapBuilder.Plotted {
    NodeDiscoveryMapBuilder.build(
      results: results,
      contacts: [contactKey: contact(contactKey, latitude: 21.30, longitude: -157.85, isFavorite: true)],
      discovered: [
        discoveredKey: discovered(discoveredKey, latitude: 21.40, longitude: -157.95),
        unlocatedKey: discovered(unlocatedKey, latitude: 0, longitude: 0),
      ],
      filter: filter ?? allNodes,
      overridesFilter: overridesFilter
    )
  }

  /// A relay known only by `hash`: no node (`.unknown`) or several (`.ambiguous`) could have sent it.
  private func relay(_ hash: Data, ambiguous: Bool = false) -> NodeDiscoveryResult {
    let resolution: NeighbourResolution = ambiguous
      ? .ambiguous(candidates: [NeighbourKeyEntry(publicKey: contactKey, nodeTypeRaw: 2)], total: 2)
      : .unknown(hash)
    return NodeDiscoveryResult(
      id: .hash(hash),
      name: "Relay",
      isNamed: false,
      publicKey: nil,
      nodeType: 0x02,
      snr: 4,
      rssi: -80,
      scanFilter: .repeaters,
      receivedAt: Date(),
      heardFrom: heardFrom(anchor),
      resolution: resolution,
      sources: [.relay]
    )
  }

  @Test
  func `located nodes get a pin, a line and a badge from where they were heard`() {
    let plotted = build([result(contactKey, heardAt: anchor), result(unlocatedKey, heardAt: anchor)])
    #expect(plotted.points.count == 2)
    #expect(plotted.points.contains { $0.pinStyle == .repeater && $0.label == "Node" })
    #expect(plotted.lines.count == 1)
    #expect(plotted.unplacedCount == 1)
    #expect(plotted.hiddenByFilterCount == 0)
    #expect(plotted.fitRegion != nil)
    #expect(plotted.keysByPointID.values.contains(contactKey))
  }

  @Test
  func `each line starts where its node was heard, not at one shared anchor`() throws {
    // Driving: the first node answered at the start, the second ten minutes down the road.
    let start = CLLocationCoordinate2D(latitude: 21.35, longitude: -157.90)
    let later = CLLocationCoordinate2D(latitude: 21.45, longitude: -158.00)
    let plotted = build([
      result(contactKey, snr: 9, heardAt: start),
      result(discoveredKey, snr: -3, heardAt: later),
    ])
    let first = try #require(plotted.lines.first { $0.id.contains(contactKey.uppercaseHexString()) })
    let second = try #require(plotted.lines.first { $0.id.contains(discoveredKey.uppercaseHexString()) })
    #expect(first.coordinates.first?.latitude == start.latitude)
    #expect(first.coordinates.first?.longitude == start.longitude)
    #expect(first.coordinates.last?.latitude == 21.30)
    #expect(second.coordinates.first?.latitude == later.latitude)
    #expect(second.coordinates.first?.longitude == later.longitude)
    #expect(second.coordinates.last?.latitude == 21.40)
    // Each line is colored by the SNR heard where it starts.
    #expect(first.style == .forSNR(9))
    #expect(second.style == .forSNR(-3))
    // Both reception points are in the camera fit.
    let fit = try #require(plotted.fitRegion)
    for point in [start, later] {
      #expect(abs(point.latitude - fit.center.latitude) <= fit.span.latitudeDelta / 2 + 1e-9)
      #expect(abs(point.longitude - fit.center.longitude) <= fit.span.longitudeDelta / 2 + 1e-9)
    }
  }

  @Test
  func `a reply heard without a fix is pinned with no line or badge`() {
    let plotted = build([result(contactKey, heardAt: anchor), result(discoveredKey)])
    #expect(plotted.lines.count == 1)
    #expect(plotted.lines.allSatisfy { $0.id.contains(contactKey.uppercaseHexString()) })
    #expect(plotted.coordinatesByKey[discoveredKey] != nil, "still pinned")
    // Two pins and one badge.
    #expect(plotted.points.count == 3)
  }

  @Test
  func `a node heard again shows its line's SNR on its pin`() throws {
    // Latest reply at 2 dB, the line from where it was heard at 9 dB.
    var repeated = result(contactKey, snr: 2)
    repeated.heardFrom = heardFrom(anchor, snr: 9)
    let plotted = build([repeated])
    let pin = try #require(plotted.points.first { plotted.keysByPointID[$0.id] == contactKey })
    #expect(pin.detail == MapLabelBadge.snrDetail(9), "the pin, line and badge give one SNR")
    #expect(plotted.lines.first?.style == .forSNR(9))
  }

  @Test
  func `the trace fit holds where each was heard and every located node`() throws {
    let plotted = build([result(contactKey, heardAt: anchor), result(discoveredKey, heardAt: anchor)])
    let fit = try #require(plotted.fitRegion)
    for point in plotted.points where plotted.keysByPointID[point.id] != nil {
      #expect(abs(point.coordinate.latitude - fit.center.latitude) <= fit.span.latitudeDelta / 2 + 1e-9)
      #expect(abs(point.coordinate.longitude - fit.center.longitude) <= fit.span.longitudeDelta / 2 + 1e-9)
    }
    #expect(abs(anchor.latitude - fit.center.latitude) <= fit.span.latitudeDelta / 2 + 1e-9)
    #expect(abs(anchor.longitude - fit.center.longitude) <= fit.span.longitudeDelta / 2 + 1e-9)
  }

  @Test
  func `without a reception fix nodes are pinned with no lines`() {
    let plotted = build([result(contactKey), result(discoveredKey)])
    #expect(plotted.points.count == 2)
    #expect(plotted.lines.isEmpty)
  }

  @Test
  func `hiding discovered keeps only contacts and counts the rest`() {
    let plotted = build([result(contactKey), result(discoveredKey)], filter: MapFilterState(showDiscovered: false))
    #expect(plotted.keysByPointID.values.sorted { $0.first! < $1.first! } == [contactKey])
    #expect(plotted.hiddenByFilterCount == 1, "a node the filter hides is counted, not dropped")
    #expect(plotted.unplacedCount == 0)
  }

  @Test
  func `favorites only keeps favorite contacts`() {
    let plotted = build([result(contactKey), result(discoveredKey)], filter: MapFilterState(favoritesOnly: true))
    #expect(Array(plotted.keysByPointID.values) == [contactKey])
    #expect(plotted.hiddenByFilterCount == 1)
  }

  @Test
  func `show all draws what the filter hides`() {
    let plotted = build(
      [result(contactKey), result(discoveredKey)],
      filter: MapFilterState(favoritesOnly: true),
      overridesFilter: true
    )
    #expect(plotted.coordinatesByKey.count == 2)
    #expect(plotted.hiddenByFilterCount == 0)
  }

  @Test
  func `nodes with no stored location are counted as unplaced`() {
    let plotted = build([result(unlocatedKey), result(Data(repeating: 0xDD, count: 32))])
    #expect(plotted.points.isEmpty)
    #expect(plotted.unplacedCount == 2)
    #expect(plotted.fitRegion == nil)
  }

  @Test
  func `a stored record's position never places a node`() {
    // The contact and discovered records have stored positions, but neither node was heard
    // advertising one: they are counted unplaced, not pinned where the records say.
    var contactRow = result(contactKey, heardAt: anchor)
    contactRow.coordinate = nil
    var discoveredRow = result(discoveredKey, heardAt: anchor)
    discoveredRow.coordinate = nil
    let plotted = build([contactRow, discoveredRow])
    #expect(plotted.points.isEmpty)
    #expect(plotted.lines.isEmpty)
    #expect(plotted.unplacedCount == 2)
  }

  @Test
  func `a node is pinned where it advertised itself, not where its contact says`() {
    var moved = result(contactKey, heardAt: anchor)
    moved.coordinate = CLLocationCoordinate2D(latitude: 21.33, longitude: -157.87)
    let plotted = build([moved])
    #expect(plotted.coordinatesByKey[contactKey]?.latitude == 21.33)
  }

  @Test
  func `a node's own advertised position places it when no record does`() {
    var advertised = result(Data(repeating: 0xDD, count: 32), heardAt: anchor)
    advertised.coordinate = CLLocationCoordinate2D(latitude: 21.32, longitude: -157.88)
    let plotted = build([advertised])
    #expect(plotted.coordinatesByKey[Data(repeating: 0xDD, count: 32)]?.latitude == 21.32)
    #expect(plotted.unplacedCount == 0)
  }

  @Test
  func `relay hashes are counted but never pinned`() {
    // The ambiguous relay's likeliest candidate is a located contact: still not pinned on it.
    let plotted = build([result(contactKey, heardAt: anchor), relay(Data([0x3A])), relay(Data([0xAA]), ambiguous: true)])
    #expect(plotted.coordinatesByKey.keys.sorted { $0.count < $1.count } == [contactKey])
    #expect(plotted.unplacedCount == 2)
    #expect(plotted.lines.count == 1)
    #expect(plotted.pointID(for: Data([0x3A])) == nil)
    #expect(plotted.pointID(for: Data([0xAA])) == nil)
  }

  @Test
  func `relay hashes count as unplaced even under a filter that hides them`() {
    let plotted = build([relay(Data([0x3A]))], filter: MapFilterState(favoritesOnly: true))
    #expect(plotted.unplacedCount == 1)
    #expect(plotted.hiddenByFilterCount == 0)
  }

  @Test
  func `pin ids are stable across rebuilds`() {
    let first = build([result(contactKey, heardAt: anchor)])
    let second = build([result(contactKey, heardAt: anchor)])
    #expect(first.points.map(\.id) == second.points.map(\.id))
  }

  @Test
  func `unknown node types fall back to a chat pin`() {
    #expect(NodeDiscoveryMapBuilder.pinStyle(for: 0x10) == .contactChat)
    #expect(NodeDiscoveryMapBuilder.pinStyle(for: 0x02) == .repeater)
  }

  // MARK: - Selection

  @Test
  func `selecting a node dims the other traces and pins`() throws {
    let plotted = NodeDiscoveryMapBuilder.build(
      results: [result(contactKey, heardAt: anchor), result(discoveredKey, heardAt: anchor)],
      contacts: [contactKey: contact(contactKey, latitude: 21.30, longitude: -157.85)],
      discovered: [discoveredKey: discovered(discoveredKey, latitude: 21.40, longitude: -157.95)],
      filter: allNodes,
      selectedKey: contactKey
    )
    let selectedLine = try #require(plotted.lines.first { $0.id.contains(contactKey.uppercaseHexString()) })
    let otherLine = try #require(plotted.lines.first { $0.id.contains(discoveredKey.uppercaseHexString()) })
    #expect(selectedLine.opacity == 1)
    #expect(otherLine.opacity == NodeDiscoveryMapBuilder.unselectedLineOpacity)
    let selectedPin = try #require(plotted.points.first { $0.id == plotted.pointID(for: contactKey) })
    #expect(selectedPin.opacity == 1)
    let otherPin = try #require(plotted.points.first { $0.id == plotted.pointID(for: discoveredKey) })
    #expect(otherPin.opacity == NodeDiscoveryMapBuilder.unselectedPinOpacity)
  }

  @Test
  func `nothing is dimmed without a selection and unplotted keys have no pin`() {
    let plotted = build([result(contactKey, heardAt: anchor), result(unlocatedKey, heardAt: anchor)])
    #expect(plotted.lines.allSatisfy { $0.opacity == 1 })
    #expect(plotted.points.allSatisfy { $0.opacity == 1 })
    #expect(plotted.pointID(for: unlocatedKey) == nil)
    #expect(plotted.pointID(for: nil) == nil)
    #expect(plotted.coordinatesByKey[contactKey] != nil)
  }

  @Test
  func `a node heard before the current scan is pinned faded, unless it is the one picked`() throws {
    let results = [result(contactKey, heardAt: anchor), result(discoveredKey, heardAt: anchor, isEarlier: true)]
    let plotted = build(results)
    let currentPin = try #require(plotted.points.first { $0.id == plotted.pointID(for: contactKey) })
    let earlierPin = try #require(plotted.points.first { $0.id == plotted.pointID(for: discoveredKey) })
    #expect(currentPin.opacity == 1)
    #expect(earlierPin.opacity == NodeDiscoveryMapBuilder.earlierPinOpacity)
    let earlierLine = try #require(plotted.lines.first { $0.id.contains(discoveredKey.uppercaseHexString()) })
    #expect(earlierLine.opacity == NodeDiscoveryMapBuilder.earlierLineOpacity)

    let picked = NodeDiscoveryMapBuilder.build(
      results: results,
      contacts: [contactKey: contact(contactKey, latitude: 21.30, longitude: -157.85)],
      discovered: [discoveredKey: discovered(discoveredKey, latitude: 21.40, longitude: -157.95)],
      filter: allNodes,
      selectedKey: discoveredKey
    )
    let pickedPin = try #require(picked.points.first { $0.id == picked.pointID(for: discoveredKey) })
    #expect(pickedPin.opacity == 1)
    let otherPin = try #require(picked.points.first { $0.id == picked.pointID(for: contactKey) })
    #expect(otherPin.opacity == NodeDiscoveryMapBuilder.unselectedPinOpacity)
  }
}

@Suite("NodeDiscoveryOpeningCamera")
struct NodeDiscoveryOpeningCameraTests {
  private let phone = CLLocationCoordinate2D(latitude: 34.05, longitude: -118.24)
  private let radio = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
  private let traces = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 21.35, longitude: -157.90),
    span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
  )

  private func expectPosition(_ target: NodeDiscoveryOpeningCamera.Target?, at coordinate: CLLocationCoordinate2D) {
    #expect(target?.region.center.latitude == coordinate.latitude)
    #expect(target?.region.center.longitude == coordinate.longitude)
    // The location button's zoom, not the traces' or the world's
    #expect(target?.region.span.latitudeDelta == AppState.userLocationSpan)
    #expect(target?.region.span.longitudeDelta == AppState.userLocationSpan)
  }

  @Test
  func `opens on the phone's fix at the location button's zoom, ahead of the radio and the traces`() {
    let target = NodeDiscoveryOpeningCamera.target(phone: phone, radio: radio, traces: traces)
    #expect(target?.source == .phone)
    expectPosition(target, at: phone)
  }

  @Test
  func `with no position yet it opens on the last camera, and a fix landing moves it`() {
    let saved = MKCoordinateRegion(center: radio, span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
    let target = NodeDiscoveryOpeningCamera.target(phone: nil, radio: nil, traces: nil, saved: saved)
    #expect(target?.source == .saved)
    #expect(target?.region.span.latitudeDelta == 0.1)
    // A position known later is better than the last camera.
    #expect(NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .saved, new: .phone))
    #expect(NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .saved, new: .radio))
    // Nothing at all: no target, so the camera waits for one rather than framing anything.
    #expect(NodeDiscoveryOpeningCamera.target(phone: nil, radio: nil, traces: nil, saved: nil) == nil)
    #expect(NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: nil, new: .phone))
  }

  @Test
  func `the packets' route fit never zooms out to the whole world`() {
    // Nothing to fit, and routes spread across the planet, give no fit: the page opens on a
    // position instead.
    #expect(NodeDiscoveryOpeningCamera.routeRegion(fitting: []) == nil)
    let worldwide = [phone, CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)]
    #expect(NodeDiscoveryOpeningCamera.routeRegion(fitting: worldwide) == nil)
    // A local mesh is framed with room around it.
    let local = [phone, CLLocationCoordinate2D(latitude: 34.2, longitude: -118.0)]
    let region = NodeDiscoveryOpeningCamera.routeRegion(fitting: local)
    #expect(region != nil)
    #expect((region?.span.latitudeDelta ?? 0) <= NodeDiscoveryOpeningCamera.maxRouteSpan)
    #expect(NodeDiscoveryOpeningCamera.routeRegion(fitting: [phone])?.span.latitudeDelta == 0.3)
  }

  @Test
  func `without a phone fix it opens on the radio's own position`() {
    let target = NodeDiscoveryOpeningCamera.target(phone: nil, radio: radio, traces: traces)
    #expect(target?.source == .radio)
    expectPosition(target, at: radio)
  }

  @Test
  func `a null-island or invalid fix is no position`() {
    let nullIsland = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let invalid = CLLocationCoordinate2D(latitude: 200, longitude: 0)
    let target = NodeDiscoveryOpeningCamera.target(phone: nullIsland, radio: invalid, traces: nil)
    #expect(target == nil)
    let onRadio = NodeDiscoveryOpeningCamera.target(phone: invalid, radio: radio, traces: nil)
    #expect(onRadio?.source == .radio)
  }

  @Test
  func `with no position it frames the traces, and with none of either it leaves the camera alone`() {
    let target = NodeDiscoveryOpeningCamera.target(phone: nil, radio: nil, traces: traces)
    #expect(target?.source == .traces)
    #expect(target?.region.span.latitudeDelta == traces.span.latitudeDelta)
    #expect(target?.region.center.latitude == traces.center.latitude)
    #expect(NodeDiscoveryOpeningCamera.target(phone: nil, radio: nil, traces: nil) == nil)
  }

  @Test
  func `a phone fix outranks the radio, which outranks the traces`() {
    #expect(NodeDiscoveryOpeningCamera.Source.phone > .radio)
    #expect(NodeDiscoveryOpeningCamera.Source.radio > .traces)
  }

  @Test
  func `a late radio position or phone fix moves the opening camera once, to a better source only`() {
    // Nothing to open on, then the radio's position lands
    #expect(NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: nil, new: .radio))
    // On the radio, then the phone's first fix lands
    #expect(NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .radio, new: .phone))
    // On the traces, then the phone's first fix lands
    #expect(NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .traces, new: .phone))
  }

  @Test
  func `the same or a worse source, or no source, leaves the opening camera where it is`() {
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .phone, new: .phone))
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .traces, new: .traces))
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: nil, new: .traces))
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .phone, new: .radio))
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: true, current: .radio, new: nil))
  }

  @Test
  func `a camera the user has moved is never moved by a late position`() {
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: false, current: nil, new: .radio))
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: false, current: .radio, new: .phone))
    #expect(!NodeDiscoveryOpeningCamera.shouldRecenter(isAtOpeningCamera: false, current: .traces, new: .phone))
  }
}
