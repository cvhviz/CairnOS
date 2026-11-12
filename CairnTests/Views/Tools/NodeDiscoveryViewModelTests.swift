import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("NodeDiscoveryViewModel")
@MainActor
struct NodeDiscoveryViewModelTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  /// One radio throughout: a new id on every read would count as a radio switch, which clears.
  private static let radio = UUID()

  private static let alphaKey = Data(repeating: 0xA1, count: 32)
  private static let bravoKey = Data(repeating: 0xB2, count: 32)
  private static let strangerKey = Data(repeating: 0x5C, count: 32)
  /// No known key starts with it, so it stays an unidentified relay.
  private static let unknownHash = Data([0xEE])

  /// How often the view model said discovered nodes changed.
  @MainActor
  private final class ChangeLog {
    var count = 0
  }

  /// The scan whose list is shown, as the coordinator would hold it: a test starts new ones.
  @MainActor
  private final class ScanLog {
    var scan: DiscoveryProbeCoordinator.Scan?

    init(_ scan: DiscoveryProbeCoordinator.Scan? = nil) {
      self.scan = scan
    }
  }

  /// A scan of the test radio that started `offset` seconds from `now`.
  private func scan(at offset: TimeInterval = -900, filter: NodeDiscoveryFilter = .repeaters, listensOnly: Bool = false) -> DiscoveryProbeCoordinator.Scan {
    DiscoveryProbeCoordinator.Scan(radioID: Self.radio, filter: filter, startedAt: now.addingTimeInterval(offset), listensOnly: listensOnly)
  }

  // MARK: - Fixtures

  private func stats(count: Int = 1, first: TimeInterval, last: TimeInterval) -> NeighbourSourceStats {
    NeighbourSourceStats(count: count, firstHeard: now.addingTimeInterval(first), lastHeard: now.addingTimeInterval(last))
  }

  private func record(
    _ identity: NeighbourIdentity,
    heard: TimeInterval,
    snr: Double,
    sources: [NeighbourSourceKind: NeighbourSourceStats],
    type: UInt8? = nil,
    name: String? = nil
  ) -> NeighbourRecord {
    NeighbourRecord(
      identity: identity,
      firstHeard: now.addingTimeInterval(heard - 600),
      lastHeard: now.addingTimeInterval(heard),
      heardCount: sources.values.reduce(0) { $0 + $1.count },
      lastSNR: snr,
      bestSNR: snr,
      snrEWMA: snr,
      lastRSSI: -80,
      sources: sources,
      nodeTypeRaw: type,
      name: name
    )
  }

  /// Alpha (5 dB) and Bravo (9 dB), named repeaters; a stranger repeater nothing names (7 dB); and
  /// a relay hash heard the loudest (12 dB) that no key can be pinned on.
  private var records: [NeighbourRecord] {
    [
      record(
        .fullKey(Self.alphaKey), heard: -60, snr: 5,
        sources: [.advert: stats(first: -60, last: -60)],
        type: ContactType.repeater.rawValue, name: "Alpha"
      ),
      record(
        .fullKey(Self.bravoKey), heard: -120, snr: 9,
        sources: [.advert: stats(first: -120, last: -120), .relay: stats(count: 3, first: -400, last: -130)],
        type: ContactType.repeater.rawValue, name: "bravo"
      ),
      record(
        .fullKey(Self.strangerKey), heard: -30, snr: 7,
        sources: [.replyToOthers: stats(first: -30, last: -30)],
        type: ContactType.repeater.rawValue
      ),
      record(
        .hash(Self.unknownHash), heard: -10, snr: 12,
        sources: [.relay: stats(count: 1, first: -10, last: -10)]
      ),
    ]
  }

  private func directory(_ records: [NeighbourRecord]? = nil) -> NeighbourDirectory {
    let directory = NeighbourDirectory(now: { [now] in now })
    directory.apply(NeighbourSnapshot(
      radioID: Self.radio,
      takenAt: now,
      neighbours: NeighbourResolver.resolveAll(
        NeighbourTable(records: records ?? self.records),
        index: .empty,
        now: now
      )
    ))
    return directory
  }

  private func dependencies(
    directory: NeighbourDirectory?,
    radioID: @escaping @MainActor () -> UUID? = { NodeDiscoveryViewModelTests.radio },
    dataStore: PersistenceStore? = nil,
    resolver: NodeNameResolver? = nil,
    changes: ChangeLog? = nil,
    isConnected: Bool = true,
    device: DeviceDTO? = nil,
    scans: ScanLog? = nil
  ) -> NodeDiscoveryViewModel.Dependencies {
    // Unless a test says otherwise, a scan started 15 minutes ago: before every fixture row
    let scans = scans ?? ScanLog(scan())
    return NodeDiscoveryViewModel.Dependencies(
      directory: { directory },
      currentScan: { scans.scan },
      isConnected: { isConnected },
      dataStore: { dataStore },
      radioID: radioID,
      contactService: { nil },
      maxContacts: { nil },
      nameResolver: { resolver },
      // With a device, what its firmware allows, as the live dependencies read it.
      supportsNameRequests: { device.map { NodeDiscoveryViewModel.supportsNameRequests(device: $0) } ?? (resolver != nil) },
      onNodesChanged: { changes?.count += 1 },
      now: { [now] in now }
    )
  }

  /// A radio as it identifies itself: official companion firmware's FIRMWARE_VER_CODE and version
  /// string (v1.10.0 to v1.12.0 all report code 8).
  private static func device(firmwareVersion: UInt8, firmwareVersionString: String) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: radio,
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "TestDevice",
      firmwareVersion: firmwareVersion,
      firmwareVersionString: firmwareVersionString,
      manufacturerName: "TestMfg",
      buildDate: "01 Jan 2025",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 915_000,
      bandwidth: 250_000,
      spreadingFactor: 10,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 20,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      manualAddContacts: false,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: false,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }

  /// Counts the name requests that went over the air.
  private actor RequestLog {
    var count = 0
    func record() { count += 1 }
  }

  private func countingResolver(_ log: RequestLog) -> NodeNameResolver {
    NodeNameResolver(dependencies: .init(
      radioContact: { _ in nil },
      requestName: { _ in
        await log.record()
        return NodeOwnerInfo(nodeName: "Ridge", ownerInfo: "owner")
      },
      addTemporaryContact: nil,
      removeTemporaryContact: { _ in }
    ))
  }

  // MARK: - Results from the neighbour table

  @Test
  func `neighbour rows become results with unresolved rows last in every order`() {
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory()))

    viewModel.sortOrder = .snr
    let bySignal = viewModel.sortedResults
    #expect(bySignal.map(\.key) == [Self.bravoKey, Self.strangerKey, Self.alphaKey, Self.unknownHash])
    let relay = bySignal[3]
    #expect(!relay.isResolved)
    #expect(relay.publicKey == nil)
    #expect(relay.name == L10n.Tools.Tools.NodeDiscovery.unidentifiedRelay("EE"))
    #expect(!relay.isNamed)
    #expect(!relay.isConfirmed, "a relay heard once is Heard once")

    viewModel.sortOrder = .name
    #expect(viewModel.sortedResults.last?.key == Self.unknownHash, "a hash row goes last by name too")
    #expect(viewModel.sortedResults.prefix(2).map(\.name) == ["Alpha", "bravo"])
  }

  @Test
  func `results carry the row's evidence`() throws {
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory()))
    let bravo = try #require(viewModel.results.first { $0.publicKey == Self.bravoKey })
    #expect(bravo.sources == [.advert, .relay])
    #expect(bravo.isConfirmed)
    #expect(bravo.freshness == .live)
    #expect(bravo.snr == 9)
    #expect(bravo.uplinkSNR == nil, "nothing measured how it hears us")
    #expect(bravo.hasFullKey)

    let stranger = try #require(viewModel.results.first { $0.publicKey == Self.strangerKey })
    #expect(stranger.name == NodeDiscoveryViewModel.placeholderName(for: Self.strangerKey))
    #expect(!stranger.isNamed)
  }

  @Test
  func `sensors list only sensor rows`() {
    let sensorKey = Data(repeating: 0x5E, count: 32)
    let rows = records + [record(
      .fullKey(sensorKey), heard: -45, snr: 3,
      sources: [.advert: stats(first: -45, last: -45)],
      type: NeighbourDirectory.sensorType, name: "Soil"
    )]
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(rows)))
    viewModel.filter = .sensors
    #expect(viewModel.results.map(\.name) == ["Soil"])
    #expect(viewModel.results.allSatisfy { $0.scanFilter == .sensors })
  }

  @Test
  func `older rows are listed only with Show Older`() {
    let olderKey = Data(repeating: 0x0D, count: 32)
    let rows = [record(
      .fullKey(olderKey), heard: -3 * 3600, snr: 4,
      sources: [.advert: stats(first: -3 * 3600, last: -3 * 3600)],
      type: ContactType.repeater.rawValue, name: "Older"
    )]
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(rows)))
    #expect(viewModel.results.isEmpty)
    viewModel.showsOlder = true
    #expect(viewModel.results.map(\.name) == ["Older"])
    #expect(viewModel.results.first?.freshness == .older)
    #expect(viewModel.results.first?.isEarlier == true, "heard before the scan started")
    #expect(viewModel.currentResults.isEmpty)
  }

  @Test
  func `no directory lists nothing`() {
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: nil))
    #expect(viewModel.results.isEmpty)
    #expect(viewModel.isEmpty)
    #expect(viewModel.probeState == .idle)
  }

  @Test
  func `switching radios drops the selection`() {
    var radio = UUID()
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(), radioID: { radio }))
    viewModel.selectedKey = Self.alphaKey

    viewModel.configure(dependencies: dependencies(directory: directory(), radioID: { radio }))
    #expect(viewModel.selectedKey == Self.alphaKey, "reconfiguring for the same radio keeps it")

    radio = UUID()
    viewModel.configure(dependencies: dependencies(directory: directory(), radioID: { radio }))
    #expect(viewModel.selectedKey == nil)
  }

  @Test
  func `a probe without a coordinator says the radio is not connected`() {
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory()))
    viewModel.requestProbe()
    #expect(viewModel.errorMessage == L10n.Tools.Tools.NodeDiscovery.notConnectedDescription(viewModel.filter.localizedTitle))
  }

  // MARK: - One scan's list

  @Test
  func `a scan's list holds only what was heard since it started, the rest only with Show Older`() throws {
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(), scans: ScanLog(scan(at: -100))))
    // Bravo, the loudest named one, was last heard 120 s ago: before the scan
    #expect(Set(viewModel.results.map(\.key)) == [Self.alphaKey, Self.strangerKey, Self.unknownHash])
    #expect(viewModel.results.allSatisfy { !$0.isEarlier })

    viewModel.showsOlder = true
    let bravo = try #require(viewModel.results.first { $0.key == Self.bravoKey })
    #expect(bravo.isEarlier)
    #expect(NodeDiscoveryFormat.isDimmed(bravo))
    #expect(viewModel.currentResults.count == 3)
    viewModel.sortOrder = .snr
    #expect(viewModel.sortedResults.last?.key == Self.bravoKey, "earlier rows go after the scan's own, however strong")
    #expect(viewModel.sortedResults.map(\.key) == [Self.strangerKey, Self.alphaKey, Self.unknownHash, Self.bravoKey])
  }

  @Test
  func `before the first scan nothing is listed but, with Show Older, what was heard`() {
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(), scans: ScanLog()))
    #expect(viewModel.scanStartedAt == nil)
    #expect(viewModel.results.isEmpty)
    #expect(viewModel.scanStatus.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.readyToScan)
    #expect(viewModel.scanStatus.nearbyCount == 0)

    viewModel.showsOlder = true
    #expect(viewModel.results.count == 4)
    #expect(viewModel.results.allSatisfy { $0.isEarlier })
    #expect(viewModel.currentResults.isEmpty)
    #expect(viewModel.scanStatus.nearbyCount == 0, "the earlier rows aren't the scan's")
  }

  @Test
  func `another radio's scan doesn't cut this radio's list`() {
    let viewModel = NodeDiscoveryViewModel()
    let other = DiscoveryProbeCoordinator.Scan(radioID: UUID(), filter: .repeaters, startedAt: now.addingTimeInterval(-900), listensOnly: false)
    viewModel.configure(dependencies: dependencies(directory: directory(), scans: ScanLog(other)))
    #expect(viewModel.scanStartedAt == nil)
    #expect(viewModel.results.isEmpty)
  }

  @Test
  func `a node that answered this scan is listed with this scan's evidence only`() throws {
    let answeredKey = Data(repeating: 0x7A, count: 32)
    let lastScanKey = Data(repeating: 0x7B, count: 32)
    let rows = [
      record(
        .fullKey(answeredKey), heard: -50, snr: 6,
        sources: [
          .advert: stats(first: -3 * 3600, last: -3 * 3600),
          .relay: stats(count: 4, first: -7200, last: -5000),
          .replyToUs: stats(first: -50, last: -50),
        ],
        type: ContactType.repeater.rawValue, name: "Answered"
      ),
      // It answered the scan before this one, not this one
      record(.fullKey(lastScanKey), heard: -200, snr: 8, sources: [.replyToUs: stats(first: -200, last: -200)],
             type: ContactType.repeater.rawValue, name: "LastScan"),
    ]
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(rows), scans: ScanLog(scan(at: -100))))
    let answered = try #require(viewModel.results.first)
    #expect(viewModel.results.map(\.name) == ["Answered"])
    #expect(answered.sources == [.replyToUs])
    #expect(NodeDiscoveryFormat.badges(answered).contains(.answeredYourScan))
    #expect(!NodeDiscoveryFormat.badges(answered).contains(.advert), "an advert from hours ago isn't this scan's")

    viewModel.showsOlder = true
    let lastScan = try #require(viewModel.results.first { $0.name == "LastScan" })
    #expect(lastScan.isEarlier)
    #expect(lastScan.sources == [.replyToUs], "an earlier row keeps all its evidence")
    #expect(NodeDiscoveryFormat.badges(lastScan) == [.answeredEarlierScan], "it answered an earlier scan, not this one")
  }

  @Test
  func `a row of this scan shows the link and the spot this scan measured, not an earlier one's`() throws {
    let key = Data(repeating: 0x7C, count: 32)
    let scanStart = now.addingTimeInterval(-100)
    func fix(_ offset: TimeInterval, latitude: Double) -> NeighbourFix {
      NeighbourFix(latitude: latitude, longitude: -122.4, horizontalAccuracy: 10, timestamp: now.addingTimeInterval(offset))
    }
    // It answered the previous scan from a spot far back (the best it was ever heard), then
    // only relayed during this one: once without a fix, once with one
    var row = record(
      .fullKey(key), heard: -20, snr: 3,
      sources: [.replyToUs: stats(first: -500, last: -500), .relay: stats(count: 2, first: -60, last: -20)],
      type: ContactType.repeater.rawValue, name: "Ridge"
    )
    row.latitude = 37.6
    row.longitude = -122.4
    row.uplinkSNR = 7.5
    row.uplinkAt = now.addingTimeInterval(-500)
    row.hearsYouAt = now.addingTimeInterval(-500)
    row.heardFrom = NeighbourHeardFrom(fix: fix(-505, latitude: 37.0), snr: 11, heardAt: now.addingTimeInterval(-500))
    row.latestHeardFrom = NeighbourHeardFrom(fix: fix(-130, latitude: 37.5), snr: 3, heardAt: now.addingTimeInterval(-60))

    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory([row]), scans: ScanLog(scan(at: -100))))
    let current = try #require(viewModel.results.first)
    #expect(!current.isEarlier)
    #expect(current.sources == [.relay])
    #expect(!current.hearsYou, "the previous scan's proof isn't this scan's")
    #expect(current.uplinkSNR == nil, "nor its uplink reading")
    #expect(NodeDiscoveryFormat.badges(current) == [.relaying])
    // The reception this scan heard with a fix, although that fix was taken just before it began
    #expect(current.heardFrom?.fix.latitude == 37.5)
    #expect(current.heardFrom?.snr == 3)
    #expect(NodeDiscoveryEntries.make(results: [current], contacts: [:], discovered: [:]).first?.distance != nil)

    // Heard this scan only without a fix: no spot at all rather than the earlier one
    row.latestHeardFrom = row.heardFrom
    let unplaced = try #require(NodeDiscoveryViewModel.makeResults(
      directory([row]).scanList(.repeaters, since: scanStart, includeEarlier: false, now: now).current,
      filter: .repeaters, storedNames: [:], scanStart: scanStart, now: now
    ).first)
    #expect(unplaced.heardFrom == nil)
    let entry = try #require(NodeDiscoveryEntries.make(results: [unplaced], contacts: [:], discovered: [:]).first)
    #expect(entry.distance == nil, "no distance from where it was heard before the scan")

    // Heard best during this scan: that spot, and this scan's proof and uplink show
    row.heardFrom = NeighbourHeardFrom(fix: fix(-40, latitude: 37.8), snr: 12, heardAt: now.addingTimeInterval(-40))
    row.uplinkAt = now.addingTimeInterval(-40)
    row.hearsYouAt = now.addingTimeInterval(-40)
    let best = try #require(NodeDiscoveryViewModel.makeResults(
      directory([row]).scanList(.repeaters, since: scanStart, includeEarlier: false, now: now).current,
      filter: .repeaters, storedNames: [:], scanStart: scanStart, now: now
    ).first)
    #expect(best.heardFrom?.fix.latitude == 37.8)
    #expect(best.hearsYou)
    #expect(best.uplinkSNR == 7.5)
  }

  @Test
  func `an earlier row keeps its best spot and its link`() throws {
    let key = Data(repeating: 0x7D, count: 32)
    var row = record(.fullKey(key), heard: -500, snr: 4, sources: [.replyToUs: stats(first: -500, last: -500)],
                     type: ContactType.repeater.rawValue, name: "Before")
    row.uplinkSNR = 6
    row.uplinkAt = now.addingTimeInterval(-500)
    row.hearsYouAt = now.addingTimeInterval(-500)
    row.heardFrom = NeighbourHeardFrom(
      fix: NeighbourFix(latitude: 37.2, longitude: -122.4, horizontalAccuracy: 10, timestamp: now.addingTimeInterval(-500)),
      snr: 4
    )
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory([row]), scans: ScanLog(scan(at: -100))))
    #expect(viewModel.results.isEmpty)
    viewModel.showsOlder = true
    let earlier = try #require(viewModel.results.first)
    #expect(earlier.isEarlier)
    #expect(earlier.heardFrom?.fix.latitude == 37.2)
    #expect(earlier.hearsYou)
    #expect(earlier.uplinkSNR == 6)
  }

  @Test
  func `every scan of a series starts a new list`() {
    let aKey = Data(repeating: 0x1A, count: 32)
    let bKey = Data(repeating: 0x1B, count: 32)
    let cHash = Data([0x1C])
    let rows = [
      // Answered the first scan only
      record(.fullKey(aKey), heard: -500, snr: 5, sources: [.replyToUs: stats(first: -500, last: -500)],
             type: ContactType.repeater.rawValue, name: "A"),
      // Answered both
      record(.fullKey(bKey), heard: -50, snr: 6, sources: [.replyToUs: stats(count: 2, first: -500, last: -50)],
             type: ContactType.repeater.rawValue, name: "B"),
      // Heard relaying after the second scan started
      record(.hash(cHash), heard: -20, snr: 2, sources: [.relay: stats(count: 2, first: -400, last: -20)]),
    ]
    let scans = ScanLog(scan(at: -600))
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(rows), scans: scans))
    #expect(Set(viewModel.results.map(\.key)) == [aKey, bKey, cHash])

    scans.scan = scan(at: -100)
    #expect(Set(viewModel.results.map(\.key)) == [bKey, cHash], "the next scan empties the list and lists its own")
    viewModel.showsOlder = true
    #expect(viewModel.results.filter(\.isEarlier).map(\.key) == [aKey], "the first scan's node is kept, apart")

    viewModel.showsOlder = false
    scans.scan = scan(at: -5)
    #expect(viewModel.results.isEmpty, "nothing heard since the third one started yet")
  }

  @Test
  func `the scan card counts the list it shows`() {
    let rows = records + [record(
      .fullKey(Data(repeating: 0x2A, count: 32)), heard: -40, snr: 4,
      sources: [.replyToUs: stats(first: -40, last: -40)],
      type: ContactType.repeater.rawValue, name: "Answered"
    )]
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory(rows), scans: ScanLog(scan(at: -100))))
    viewModel.showsOlder = true
    let status = viewModel.scanStatus
    // Alpha, the stranger, the relay and Answered since the scan; Bravo is earlier
    #expect(viewModel.results.count == 5)
    #expect(status.nearbyCount == viewModel.currentResults.count)
    #expect(status.scanCounts == NodeDiscoveryScanStatus.ScanCounts(listed: 4, answered: 1))
    #expect(status.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.probeSummary(1, 3))
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listeningNearby(
      4,
      NodeDiscoveryScanStatus.relative(now, now: now)
    ))

    let summary = NodeDiscoverySummary(entries: NodeDiscoveryEntries.make(
      results: viewModel.currentResults, contacts: [:], discovered: [:]
    ))
    #expect(summary.replied == status.nearbyCount)
    #expect(summary.bestSignal?.key == Self.unknownHash, "the loudest of this scan, not Bravo from before it")
  }

  @Test
  func `a radio that can't send a scan starts one that only listens`() async throws {
    let gate = DiscoverRequestGate()
    let coordinator = DiscoveryProbeCoordinator(
      gate: gate,
      location: .init(latestFix: { nil }, canFollow: { false }, setDemand: { _ in })
    )
    let connection = NSObject()
    coordinator.bind(DiscoveryProbeCoordinator.Binding(
      id: ObjectIdentifier(connection),
      radioID: Self.radio,
      listenWindow: 6,
      sendDiscoverRequest: { _, _ in Issue.record("nothing goes on air") },
      noteProbe: { _, _, _ in },
      overheardRequests: { AsyncStream { $0.finish() } },
      updateLocationFix: { _ in },
      canDiscover: false
    ))
    var deps = dependencies(directory: directory(), scans: ScanLog())
    deps.coordinator = { coordinator }
    deps.currentScan = { coordinator.currentScan }
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: deps)
    #expect(viewModel.results.isEmpty)

    viewModel.requestProbe()
    #expect(coordinator.currentScan?.listensOnly == true)
    #expect(viewModel.isProbing)
    #expect(viewModel.scanStatus.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listeningOnly)
    #expect(viewModel.errorMessage == nil)
    coordinator.stopProbe()
    withExtendedLifetime(connection) {}
  }

  @Test
  func `others scanning nearby never stop a radio that can't send a scan from starting a new list`() async throws {
    let gate = DiscoverRequestGate()
    let coordinator = DiscoveryProbeCoordinator(
      gate: gate,
      location: .init(latestFix: { nil }, canFollow: { false }, setDemand: { _ in })
    )
    let connection = NSObject()
    coordinator.bind(DiscoveryProbeCoordinator.Binding(
      id: ObjectIdentifier(connection),
      radioID: Self.radio,
      listenWindow: 6,
      sendDiscoverRequest: { _, _ in Issue.record("nothing goes on air") },
      noteProbe: { _, _, _ in },
      overheardRequests: { AsyncStream { $0.finish() } },
      updateLocationFix: { _ in },
      canDiscover: false
    ))
    // Three requests from other phones: the gate would make a radio that can send one wait
    let heard = Date()
    for offset in [-30.0, -20, -10] {
      await gate.noteOverheard(at: heard.addingTimeInterval(offset))
    }
    guard case .coolingDown(_, .othersScanning) = await gate.status() else {
      Issue.record("the gate counts others' requests")
      return
    }
    var deps = dependencies(directory: directory(), scans: ScanLog())
    deps.coordinator = { coordinator }
    deps.currentScan = { coordinator.currentScan }
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: deps)
    await viewModel.refreshCooldown()
    #expect(viewModel.probeState == .idle)
    #expect(viewModel.scanStatus.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.scanNow)

    viewModel.toggleScan()
    let first = try #require(coordinator.currentScan, "Scan Now starts a listen-only scan")
    #expect(first.listensOnly)
    #expect(!viewModel.showsCooldownReason)
    coordinator.stopProbe()
    try await Task.sleep(for: .milliseconds(20))
    #expect(viewModel.probeState == .idle)

    // And the next one starts a new list again
    try await Task.sleep(for: .milliseconds(5))
    viewModel.toggleScan()
    let second = try #require(coordinator.currentScan)
    #expect(second.startedAt > first.startedAt)
    coordinator.stopProbe()
    withExtendedLifetime(connection) {}
  }

  // MARK: - Naming by observation

  /// Saved nodes never heard on this channel: Kona Hill shares the unknown relay's byte, Ridge
  /// Two the shared one's.
  private static let konaKey = unknownHash + Data(repeating: 0x7F, count: 31)
  private static let sharedHash = Data([0xAB])
  private static let ridgeKey = sharedHash + Data(repeating: 0x01, count: 31)
  private static let summitKey = sharedHash + Data(repeating: 0x02, count: 31)
  private static let ridgeTwoKey = sharedHash + Data(repeating: 0x09, count: 31)

  /// The current channel's index: Ridge and Summit observed by their adverts an hour ago, Kona
  /// Hill and Ridge Two saved but never heard here.
  private var observedIndex: PacketNodeIndex {
    let heard = now.addingTimeInterval(-3600)
    return PacketNodeIndex(
      ledger: TrafficClaremontFixtures.ledger([
        TrafficClaremontFixtures.observation(Self.ridgeKey, name: "Ridge", at: heard),
        TrafficClaremontFixtures.observation(Self.summitKey, name: "Summit", at: heard),
      ], takenAt: now),
      unobserved: NeighbourKeyIndex(entries: [
        NeighbourKeyEntry(publicKey: Self.konaKey, nodeTypeRaw: ContactType.repeater.rawValue, name: "Kona Hill", latitude: 19.6, longitude: -156),
        NeighbourKeyEntry(publicKey: Self.ridgeTwoKey, nodeTypeRaw: ContactType.repeater.rawValue, name: "Ridge Two"),
      ])
    )
  }

  /// `records` plus a relay heard by the byte Ridge and Summit share, resolved against
  /// ``observedIndex``.
  private var observedNeighbours: [ResolvedNeighbour] {
    let shared = record(.hash(Self.sharedHash), heard: -15, snr: 3, sources: [.relay: stats(count: 2, first: -40, last: -15)])
    return NeighbourResolver.resolveAll(NeighbourTable(records: records + [shared]), index: observedIndex, now: now)
  }

  @Test
  func `a saved node sharing an unresolved row's byte never names it, and only hints`() throws {
    let results = NodeDiscoveryViewModel.makeResults(
      observedNeighbours,
      filter: .repeaters,
      storedNames: [Self.konaKey: "Kona Hill", Self.ridgeTwoKey: "Ridge Two"],
      hints: observedIndex,
      now: now
    )
    let relay = try #require(results.first { $0.id == .hash(Self.unknownHash) })
    #expect(relay.name == L10n.Tools.Tools.NodeDiscovery.unidentifiedRelay("EE"))
    #expect(!relay.isNamed)
    #expect(relay.publicKey == nil)
    #expect(relay.unobservedSharers.map(\.entry.name) == ["Kona Hill"])
    #expect(relay.unobservedSharers.first?.reason == .notHeard)

    let shared = try #require(results.first { $0.id == .hash(Self.sharedHash) })
    #expect(shared.name == L10n.Tools.Tools.NodeDiscovery.ambiguous("Ridge?", 2))
    #expect(!shared.isNamed)
    #expect(shared.candidates?.entries.map(\.name) == ["Ridge", "Summit"])
    #expect(shared.unobservedSharers.map(\.entry.name) == ["Ridge Two"])
    #expect(!results.contains { $0.name.contains("Kona Hill") || $0.name.contains("Ridge Two") })
  }

  @Test
  func `a stored name names a row resolved to exactly its key`() throws {
    let results = NodeDiscoveryViewModel.makeResults(
      observedNeighbours,
      filter: .repeaters,
      storedNames: [Self.alphaKey: "Alpha Ops", Self.summitKey: "Summit Ops"],
      hints: observedIndex,
      now: now
    )
    let alpha = try #require(results.first { $0.publicKey == Self.alphaKey })
    #expect(alpha.name == "Alpha Ops")
    #expect(alpha.isNamed)
    #expect(alpha.unobservedSharers.isEmpty)
    // A saved name labels an observed candidate by its exact key, never the row
    let shared = try #require(results.first { $0.id == .hash(Self.sharedHash) })
    #expect(shared.candidates?.entries.map(\.name) == ["Ridge", "Summit Ops"])
    #expect(!shared.isNamed)
  }

  @Test
  func `the simulator's replies resolve against what they made observed, without contacts`() throws {
    let strangers = [Data(repeating: 0xA7, count: 32), Data(repeating: 0x3C, count: 32)]
    let rows = strangers.enumerated().map { position, key in
      record(.fullKey(key), heard: -Double(position), snr: 10 - Double(position), sources: [.replyToUs: stats(first: -1, last: -1)], type: ContactType.repeater.rawValue)
    }
    let probe = NeighbourProbe(tag: 0, filter: NodeDiscoveryFilter.repeaters.filterValue, sentAt: now.addingTimeInterval(-5))
    let snapshot = NodeDiscoveryViewModel.simulatedSnapshot(radioID: Self.radio, records: rows, probe: probe, now: now)
    #expect(snapshot.channelKey == NodeDiscoveryViewModel.simulatedChannel.key)
    #expect(Set(snapshot.ledger.nodes.map(\.identity.bytes)) == Set(strangers))
    #expect(snapshot.ledger.nodes.allSatisfy { $0.lastDirectAt != nil })
    #expect(snapshot.answeredLastProbeCount == 2)
    let entries = snapshot.neighbours.compactMap(\.resolution.entry)
    #expect(Set(entries.map(\.publicKey)) == Set(strangers))
    #expect(entries.allSatisfy { $0.isObserved })

    let directory = NeighbourDirectory(now: { [now] in now })
    directory.apply(snapshot)
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(directory: directory))
    #expect(viewModel.results.map(\.name).sorted() == strangers.map(NodeDiscoveryViewModel.placeholderName(for:)).sorted())
  }

  // MARK: - Names

  @Test(.timeLimit(.minutes(1)))
  func `a stored name tells the app exactly once`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let resolver = NodeNameResolver(dependencies: .init(
      radioContact: { _ in nil },
      requestName: { _ in NodeOwnerInfo(nodeName: "Ridge", ownerInfo: "owner") },
      addTemporaryContact: nil,
      removeTemporaryContact: { _ in }
    ))
    let changes = ChangeLog()
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(
      directory: directory(),
      dataStore: store,
      resolver: resolver,
      changes: changes
    ))

    viewModel.requestName(for: Self.strangerKey)
    try await waitUntil { changes.count == 1 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(changes.count == 1)
    #expect(viewModel.results.first { $0.publicKey == Self.strangerKey }?.name == "Ridge")
    let stored = try await store.fetchDiscoveredNodes(radioID: Self.radio)
    #expect(stored.map(\.name) == ["Ridge"])
  }

  @Test(.timeLimit(.minutes(1)))
  func `a name the radio doesn't know is not stored and tells nobody`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let resolver = NodeNameResolver(dependencies: .init(
      radioContact: { _ in nil },
      requestName: { _ in throw MeshCoreError.timeout },
      addTemporaryContact: nil,
      removeTemporaryContact: { _ in }
    ))
    let changes = ChangeLog()
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(
      directory: directory(),
      dataStore: store,
      resolver: resolver,
      changes: changes
    ))

    viewModel.requestName(for: Self.strangerKey)
    try await waitUntil { !viewModel.resolvingNameKeys.contains(Self.strangerKey) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(changes.count == 0)
    #expect(try await store.fetchDiscoveredNodes(radioID: Self.radio).isEmpty)
  }

  @Test
  func `asking a node for its name needs companion v1.12`() {
    // CMD_SEND_ANON_REQ first appears in companion-v1.12.0, still VER_CODE 8 like v1.10 and v1.11.
    #expect(!NodeDiscoveryViewModel.supportsNameRequests(device: nil))
    #expect(!NodeDiscoveryViewModel.supportsNameRequests(device: Self.device(firmwareVersion: 7, firmwareVersionString: "v1.9.0")))
    #expect(!NodeDiscoveryViewModel.supportsNameRequests(device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.10.0")))
    #expect(!NodeDiscoveryViewModel.supportsNameRequests(device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.11.0")))
    #expect(NodeDiscoveryViewModel.supportsNameRequests(device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.12.0")))
    #expect(NodeDiscoveryViewModel.supportsNameRequests(device: Self.device(firmwareVersion: 9, firmwareVersionString: "v1.13.0")))
    #expect(NodeDiscoveryViewModel.supportsNameRequests(device: Self.device(firmwareVersion: 14, firmwareVersionString: "v1.18.0")))
  }

  @Test(.timeLimit(.minutes(1)))
  func `a v1.11 radio sends no name request`() async throws {
    let log = RequestLog()
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(
      directory: directory(),
      resolver: countingResolver(log),
      device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.11.0")
    ))
    #expect(!viewModel.canRequestNames, "the Request Name button is hidden")

    viewModel.requestName(for: Self.strangerKey)
    #expect(!viewModel.resolvingNameKeys.contains(Self.strangerKey))
    try await Task.sleep(for: .milliseconds(300))
    #expect(await log.count == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func `a v1.12 radio asks a node for its name`() async throws {
    let log = RequestLog()
    let viewModel = NodeDiscoveryViewModel()
    viewModel.configure(dependencies: dependencies(
      directory: directory(),
      resolver: countingResolver(log),
      device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.12.0")
    ))
    #expect(viewModel.canRequestNames)

    viewModel.requestName(for: Self.strangerKey)
    try await waitUntil { await log.count == 1 }
  }

  @Test
  func `the names info says what the connected radio can do`() {
    let disconnected = NodeDiscoveryViewModel()
    disconnected.configure(dependencies: dependencies(directory: directory(), isConnected: false))
    #expect(disconnected.namesInfo == L10n.Tools.Tools.NodeDiscovery.namesFooterDisconnected)

    let resolver = countingResolver(RequestLog())
    let v111 = NodeDiscoveryViewModel()
    v111.configure(dependencies: dependencies(
      directory: directory(),
      resolver: resolver,
      device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.11.0")
    ))
    #expect(v111.namesInfo == L10n.Tools.Tools.NodeDiscovery.namesFooterNeedsFirmware)

    for device in [
      Self.device(firmwareVersion: 8, firmwareVersionString: "v1.12.0"),
      Self.device(firmwareVersion: 14, firmwareVersionString: "v1.18.0"),
    ] {
      let viewModel = NodeDiscoveryViewModel()
      viewModel.configure(dependencies: dependencies(directory: directory(), resolver: resolver, device: device))
      #expect(viewModel.namesInfo == L10n.Tools.Tools.NodeDiscovery.namesFooter)
    }
  }

  // MARK: - Scan wording

  private func probe(sentAt: TimeInterval? = -2, window: TimeInterval = 6, listensOnly: Bool = false) -> DiscoveryProbeCoordinator.Probe {
    DiscoveryProbeCoordinator.Probe(
      filter: .repeaters,
      radioID: Self.radio,
      origins: [.phone],
      tag: sentAt == nil || listensOnly ? nil : 7,
      sentAt: sentAt.map { now.addingTimeInterval($0) },
      endsAt: sentAt.map { now.addingTimeInterval($0 + window) },
      listensOnly: listensOnly
    )
  }

  @Test
  func `idle and listening says how many the scan's list holds`() {
    let status = NodeDiscoveryScanStatus(nearbyCount: 3, updatedAt: now.addingTimeInterval(-120), scan: scan())
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listeningNearby(
      3,
      NodeDiscoveryScanStatus.relative(now.addingTimeInterval(-120), now: now)
    ))
    #expect(status.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.scanNow)
    #expect(status.detail(now: now) == nil)
    #expect(status.secondsLeft(now: now) == nil)
    #expect(!status.isCountingDown)
  }

  // MARK: - Sheet header and Scan button

  @Test
  func `the header says how many are near and the packets a minute`() {
    let status = NodeDiscoveryScanStatus(nearbyCount: 3, updatedAt: now.addingTimeInterval(-120), scan: scan())
    #expect(status.headerLine(now: now, packetsPerMinute: 12) == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.Status.nearby(3),
      L10n.Tools.Tools.NodeDiscovery.Status.packetsPerMinute("12"),
    ]))
    // Too soon to measure: no rate yet.
    #expect(status.headerLine(now: now, packetsPerMinute: nil) == L10n.Tools.Tools.NodeDiscovery.Status.nearby(3))
  }

  @Test
  func `the header before the first scan says one is ready; while asking, how many replied`() {
    let ready = NodeDiscoveryScanStatus(nearbyCount: 0, updatedAt: now, scanCounts: .init(listed: 0, answered: 0))
    #expect(ready.headerLine(now: now, packetsPerMinute: nil) == L10n.Tools.Tools.NodeDiscovery.Status.readyToScan)

    let probing = NodeDiscoveryScanStatus(state: .probing(probe()), nearbyCount: 3, updatedAt: now, scanCounts: .init(listed: 3, answered: 2))
    #expect(probing.headerLine(now: now, packetsPerMinute: nil) == L10n.Tools.Tools.NodeDiscovery.Status.listening(2))

    let disconnected = NodeDiscoveryScanStatus(isConnected: false)
    #expect(disconnected.headerLine(now: now, packetsPerMinute: 4) == disconnected.headline(now: now))
  }

  @Test
  func `the Scan button says Scan, then the seconds left while it listens`() {
    let idle = NodeDiscoveryScanStatus(nearbyCount: 0, updatedAt: now)
    #expect(NodeDiscoveryScanButtons.label(idle, secondsLeft: idle.secondsLeft(now: now)) == L10n.Tools.Tools.NodeDiscovery.scan)

    let probing = NodeDiscoveryScanStatus(state: .probing(probe()))
    let label = NodeDiscoveryScanButtons.label(probing, secondsLeft: probing.secondsLeft(now: now))
    #expect(label == Duration.seconds(4).formatted(.units(allowed: [.seconds], width: .narrow)))

    let waitingForFix = NodeDiscoveryScanStatus(state: .probing(probe(sentAt: nil)))
    #expect(NodeDiscoveryScanButtons.label(waitingForFix, secondsLeft: nil) == L10n.Tools.Tools.NodeDiscovery.scan)
  }

  @Test
  func `before anything is heard the headline says so`() {
    let status = NodeDiscoveryScanStatus()
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.NothingHeard.title)
  }

  @Test
  func `before the first scan the headline says one is ready and nothing is counted`() {
    let status = NodeDiscoveryScanStatus(nearbyCount: 0, updatedAt: now, scanCounts: .init(listed: 0, answered: 0))
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.readyToScan)
    #expect(status.detail(now: now) == nil)
    #expect(status.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.scanNow)
  }

  @Test
  func `a probe says it asks, offers stop, and counts its window down`() {
    let status = NodeDiscoveryScanStatus(state: .probing(probe()), nearbyCount: 3, updatedAt: now)
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.probing)
    #expect(status.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.stopButton)
    #expect(status.secondsLeft(now: now) == 4)
    #expect(status.windowProgress(now: now) == 2.0 / 6.0)
    #expect(status.isCountingDown)

    let waitingForFix = NodeDiscoveryScanStatus(state: .probing(probe(sentAt: nil)))
    #expect(waitingForFix.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.probing)
    #expect(waitingForFix.secondsLeft(now: now) == nil, "no countdown before the request goes out")
    #expect(waitingForFix.windowProgress(now: now) == nil)
  }

  @Test
  func `a rebuilt connection says it still listens`() {
    let status = NodeDiscoveryScanStatus(state: .interrupted(probe()), nearbyCount: 3, updatedAt: now)
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.interrupted)
    #expect(status.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.stopButton)
  }

  @Test
  func `a cooldown counts down and explains itself when asked`() {
    let until = now.addingTimeInterval(32)
    var status = NodeDiscoveryScanStatus(state: .coolingDown(until: until, reason: .spacing), nearbyCount: 1, updatedAt: now, scan: scan())
    #expect(status.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.Cooldown.scanAgainIn(
      NodeDiscoveryFormat.countdown(seconds: 32)
    ))
    #expect(status.secondsLeft(now: now) == 32)
    #expect(status.secondsLeft(now: now.addingTimeInterval(31.5)) == 1, "rounded up, so it reaches 0 at the end")
    #expect(status.secondsLeft(now: now.addingTimeInterval(40)) == 0)
    #expect(status.isCountingDown)
    #expect(status.detail(now: now) == nil, "the reason shows once the button is tapped")

    status.showsCooldownReason = true
    #expect(status.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Cooldown.explainer)
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listeningNearby(
      1,
      NodeDiscoveryScanStatus.relative(now, now: now)
    ), "the list keeps listening meanwhile")
  }

  @Test
  func `others scanning says so instead of a countdown`() {
    let status = NodeDiscoveryScanStatus(state: .coolingDown(until: now.addingTimeInterval(70), reason: .othersScanning))
    #expect(status.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.Cooldown.othersScanning)
  }

  @Test
  func `after a scan the detail counts its list: who answered and who else was heard`() {
    let counts = NodeDiscoveryScanStatus.ScanCounts(listed: 7, answered: 2)
    let repeaters = NodeDiscoveryScanStatus(filter: .repeaters, nearbyCount: 7, updatedAt: now, scan: scan(), scanCounts: counts)
    #expect(repeaters.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.probeSummary(2, 5))
    // The other kind wasn't asked: only how many were heard since the scan started
    let sensors = NodeDiscoveryScanStatus(filter: .sensors, nearbyCount: 7, updatedAt: now, scan: scan(), scanCounts: counts)
    #expect(sensors.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listenSummary(7))
    let probing = NodeDiscoveryScanStatus(state: .probing(probe()), nearbyCount: 7, updatedAt: now, scan: scan(), scanCounts: counts)
    #expect(probing.detail(now: now) == nil, "the headline says it asks meanwhile")
  }

  @Test
  func `a scan's detail says when the radio heard packets that never reached the app`() {
    let counts = NodeDiscoveryScanStatus.ScanCounts(listed: 7, answered: 2)
    var summary = DiscoveryProbeCoordinator.Summary(filter: .repeaters, answered: 2, heardRelaying: 5, finishedAt: now, radioMissed: 4)
    let status = NodeDiscoveryScanStatus(filter: .repeaters, nearbyCount: 7, updatedAt: now, summary: summary, scan: scan(at: -10), scanCounts: counts)
    #expect(status.detail(now: now) == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.Status.probeSummary(2, 5),
      L10n.Tools.Tools.NodeDiscovery.Summary.radioMissed(4),
    ]))

    // Measured clean, or not measured at all: the counts alone.
    for missed in [0, nil] as [Int?] {
      summary.radioMissed = missed
      let clean = NodeDiscoveryScanStatus(filter: .repeaters, nearbyCount: 7, updatedAt: now, summary: summary, scan: scan(at: -10), scanCounts: counts)
      #expect(clean.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.probeSummary(2, 5))
    }
    // A summary from before the scan started is another scan's
    summary.radioMissed = 4
    let earlier = NodeDiscoveryScanStatus(filter: .repeaters, nearbyCount: 7, updatedAt: now, summary: summary, scan: scan(at: 10), scanCounts: counts)
    #expect(earlier.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.probeSummary(2, 5))
  }

  @Test
  func `firmware that can't send a scan says so until a scan has only listened, shorter on the map`() {
    let before = NodeDiscoveryScanStatus(nearbyCount: 0, updatedAt: now, isScanSupported: false, scanCounts: .init(listed: 0, answered: 0))
    #expect(before.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.scanUnsupported)
    #expect(before.compactDetail(now: now) == L10n.Tools.Tools.NodeDiscovery.scanUnsupportedShort)
    #expect(before.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.readyToScan)

    let listening = NodeDiscoveryScanStatus(
      state: .probing(probe(listensOnly: true)), nearbyCount: 2, updatedAt: now, isScanSupported: false,
      scan: scan(at: -2, listensOnly: true), scanCounts: .init(listed: 2, answered: 0)
    )
    #expect(listening.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listeningOnly)
    #expect(listening.secondsLeft(now: now) == 4, "it counts its window down like a scan")
    #expect(listening.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.stopButton)

    let listened = NodeDiscoveryScanStatus(
      nearbyCount: 3, updatedAt: now, isScanSupported: false,
      scan: scan(at: -30, listensOnly: true), scanCounts: .init(listed: 3, answered: 0)
    )
    #expect(listened.detail(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listenSummary(3))
    #expect(listened.compactDetail(now: now) == listened.detail(now: now))
    #expect(listened.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.listeningNearby(
      3,
      NodeDiscoveryScanStatus.relative(now, now: now)
    ))

    let supported = NodeDiscoveryScanStatus(nearbyCount: 3, updatedAt: now, scan: scan(), scanCounts: .init(listed: 3, answered: 1))
    #expect(supported.isScanSupported)
    #expect(supported.compactDetail(now: now) == supported.detail(now: now))
  }

  @Test
  func `VoiceOver hears what the scan button does and why Wardrive is off`() {
    // The card's and the map bar's scan buttons share one hint, as their wording does
    let unsupported = NodeDiscoveryScanStatus(nearbyCount: 3, updatedAt: now, isScanSupported: false)
    #expect(unsupported.scanButtonHint == L10n.Tools.Tools.NodeDiscovery.scanListensOnlyHint, "it works, but only listens")
    #expect(unsupported.wardriveButtonHint == L10n.Tools.Tools.NodeDiscovery.scanUnsupportedShort)

    let coolingDown = NodeDiscoveryScanStatus(state: .coolingDown(until: now.addingTimeInterval(30), reason: .spacing))
    #expect(coolingDown.scanButtonHint == L10n.Tools.Tools.NodeDiscovery.Cooldown.hint)
    #expect(coolingDown.wardriveButtonHint == L10n.Tools.Tools.NodeDiscovery.wardriveHint)

    let ready = NodeDiscoveryScanStatus(nearbyCount: 3, updatedAt: now)
    #expect(ready.scanButtonHint.isEmpty)
    #expect(ready.wardriveButtonHint == L10n.Tools.Tools.NodeDiscovery.wardriveHint)

    // Wardrive running on a radio that refused a scan meanwhile: its stop button still works
    var stopping = unsupported
    stopping.isWardriving = true
    #expect(stopping.scanButtonHint.isEmpty)
  }

  @Test
  func `disconnected shows until when the list was heard`() {
    let heardAt = now.addingTimeInterval(-600)
    let status = NodeDiscoveryScanStatus(isConnected: false, nearbyCount: 0, updatedAt: heardAt)
    #expect(status.headline(now: now) == L10n.Tools.Tools.NodeDiscovery.Status.disconnected(
      heardAt.formatted(date: .omitted, time: .shortened)
    ))
  }

  @Test
  func `wardrive says it runs and counts down to its next probe`() {
    let next = now.addingTimeInterval(20)
    let waiting = NodeDiscoveryScanStatus(isWardriving: true, wardriveProbeCount: 2, nextWardriveProbeAt: next)
    #expect(waiting.buttonTitle(now: now) == L10n.Tools.Tools.NodeDiscovery.wardriveStop)
    #expect(waiting.detail(now: now) == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.wardriveRunning,
      L10n.Tools.Tools.NodeDiscovery.Status.wardriveWaiting(2),
    ]))
    #expect(waiting.secondsLeft(now: now) == 20)

    let listening = NodeDiscoveryScanStatus(state: .probing(probe()), isWardriving: true, wardriveProbeCount: 3)
    #expect(listening.detail(now: now) == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.wardriveRunning,
      L10n.Tools.Tools.NodeDiscovery.Status.wardriveListening(3),
    ]))
  }

  @Test
  func `the countdown reads minutes and seconds`() {
    #expect(NodeDiscoveryFormat.countdown(seconds: 32).hasSuffix("32"))
    #expect(NodeDiscoveryFormat.countdown(seconds: 95).hasSuffix("35"))
    #expect(NodeDiscoveryFormat.countdown(seconds: -4).hasSuffix("00"), "never negative")
  }
}

private struct WaitTimedOut: Error {}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while await !condition() {
    guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
    try await Task.sleep(for: .milliseconds(10))
  }
}
