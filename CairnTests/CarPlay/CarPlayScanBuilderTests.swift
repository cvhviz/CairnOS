import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("CarPlayScanBuilder")
@MainActor
struct CarPlayScanBuilderTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let radioID = UUID()

  private static let alphaKey = Data(repeating: 0xA1, count: 32)
  private static let bravoKey = Data(repeating: 0xB2, count: 32)
  private static let sensorKey = Data(repeating: 0x5E, count: 32)
  /// No known key starts with it: an unidentified relay.
  private static let unknownHash = Data([0xEE])
  /// Two repeaters this radio observed start with it, neither proven: "Ridge? · could be 2 nodes".
  private static let sharedHash = Data([0xAB])
  private static let ridgeKey = sharedHash + Data(repeating: 0x01, count: 31)
  private static let summitKey = sharedHash + Data(repeating: 0x02, count: 31)

  // MARK: - Fixtures

  private func readyInputs() -> CarPlayInputs {
    var inputs = CarPlayInputs()
    inputs.connectionState = .ready
    inputs.isRadioReady = true
    inputs.radio = .init(name: "Heltec", frequency: "910.525 MHz", presetName: "USA", locationSharing: "Off")
    return inputs
  }

  private func stats(count: Int = 1, first: TimeInterval, last: TimeInterval) -> NeighbourSourceStats {
    NeighbourSourceStats(count: count, firstHeard: now.addingTimeInterval(first), lastHeard: now.addingTimeInterval(last))
  }

  /// Alpha: a saved repeater heard by its advert and relaying, placed about 1 km north of where
  /// it was heard. Bravo: a room that answered our scan and hears us. A relay nobody is known by,
  /// one heard once that two repeaters could be, and a sensor that answered the probe at -1 s.
  private var records: [NeighbourRecord] {
    [
      NeighbourRecord(
        identity: .fullKey(Self.alphaKey),
        firstHeard: now.addingTimeInterval(-600),
        lastHeard: now.addingTimeInterval(-60),
        heardCount: 4,
        lastSNR: 5,
        snrEWMA: 5,
        lastRSSI: -80,
        sources: [.advert: stats(first: -60, last: -60), .relay: stats(count: 3, first: -300, last: -90)],
        nodeTypeRaw: ContactType.repeater.rawValue,
        name: "Alpha",
        latitude: 45.009,
        longitude: -122.0,
        heardFrom: NeighbourHeardFrom(
          fix: NeighbourFix(latitude: 45.0, longitude: -122.0, horizontalAccuracy: 5, timestamp: now.addingTimeInterval(-60)),
          snr: 5
        )
      ),
      NeighbourRecord(
        identity: .fullKey(Self.bravoKey),
        firstHeard: now.addingTimeInterval(-120),
        lastHeard: now.addingTimeInterval(-120),
        heardCount: 1,
        lastSNR: 9,
        snrEWMA: 9,
        lastRSSI: -90,
        uplinkSNR: 7.5,
        uplinkAt: now.addingTimeInterval(-120),
        hearsYouAt: now.addingTimeInterval(-120),
        sources: [.replyToUs: stats(first: -120, last: -120)],
        nodeTypeRaw: ContactType.room.rawValue,
        name: "Bravo"
      ),
      NeighbourRecord(
        identity: .hash(Self.unknownHash),
        firstHeard: now.addingTimeInterval(-40),
        lastHeard: now.addingTimeInterval(-30),
        heardCount: 2,
        lastSNR: 2,
        snrEWMA: 2,
        sources: [.relay: stats(count: 2, first: -40, last: -30)]
      ),
      NeighbourRecord(
        identity: .hash(Self.sharedHash),
        firstHeard: now.addingTimeInterval(-20),
        lastHeard: now.addingTimeInterval(-20),
        heardCount: 1,
        lastSNR: 1,
        snrEWMA: 1,
        sources: [.relay: stats(first: -20, last: -20)]
      ),
      NeighbourRecord(
        identity: .fullKey(Self.sensorKey),
        firstHeard: now.addingTimeInterval(-45),
        lastHeard: now.addingTimeInterval(-1),
        heardCount: 2,
        lastSNR: 7,
        snrEWMA: 7,
        sources: [.advert: stats(first: -45, last: -45), .replyToUs: stats(first: -1, last: -1)],
        nodeTypeRaw: NeighbourDirectory.sensorType,
        name: "Soil"
      ),
    ]
  }

  /// What this radio observed on its channel: Ridge and Summit, both by their adverts an hour
  /// ago. The rows resolve against these alone.
  private var index: PacketNodeIndex {
    let heard = now.addingTimeInterval(-3600)
    return PacketNodeIndex(ledger: TrafficClaremontFixtures.ledger([
      TrafficClaremontFixtures.observation(Self.ridgeKey, name: "Ridge", at: heard),
      TrafficClaremontFixtures.observation(Self.summitKey, name: "Summit", at: heard),
    ], takenAt: now))
  }

  /// A directory showing `records`, as the radio's neighbour service would send them.
  private func directory(_ records: [NeighbourRecord]? = nil) -> NeighbourDirectory {
    let directory = NeighbourDirectory(now: { [now] in now })
    directory.apply(NeighbourSnapshot(
      radioID: radioID,
      takenAt: now,
      neighbours: NeighbourResolver.resolveAll(NeighbourTable(records: records ?? self.records), index: index, now: now)
    ))
    return directory
  }

  private func probe(
    _ filter: NodeDiscoveryFilter,
    origins: Set<DiscoveryProbeCoordinator.Origin>,
    sentAgo: TimeInterval? = 3,
    endsIn: TimeInterval? = 6
  ) -> DiscoveryProbeCoordinator.Probe {
    DiscoveryProbeCoordinator.Probe(
      filter: filter,
      radioID: radioID,
      origins: origins,
      tag: sentAgo == nil ? nil : 7,
      sentAt: sentAgo.map { now.addingTimeInterval(-$0) },
      endsAt: endsIn.map { now.addingTimeInterval($0) }
    )
  }

  private func source(
    _ state: DiscoveryProbeCoordinator.State = .idle,
    directory: NeighbourDirectory? = nil,
    filter: NodeDiscoveryFilter = .repeaters,
    lastSummary: DiscoveryProbeCoordinator.Summary? = nil,
    contactKeys: Set<Data> = [],
    message: String? = nil,
    isWardriving: Bool = false,
    canScan: Bool = true
  ) -> CarPlayScanBuilder.Source {
    CarPlayScanBuilder.source(
      directory: directory ?? self.directory(),
      probeState: state,
      lastSummary: lastSummary,
      filter: filter,
      contactKeys: contactKeys,
      message: message,
      isWardriving: isWardriving,
      canScan: canScan,
      now: now
    )
  }

  /// Whether a radio running official companion firmware can scan, from what its DEVICE_INFO
  /// reports (FIRMWARE_VER_CODE and the version string, from the release tags).
  private static func canScan(firmwareVersion: UInt8, firmwareVersionString: String) -> Bool {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
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
    ).supportsNodeDiscover
  }

  private func scan(_ source: CarPlayScanBuilder.Source, inputs: CarPlayInputs? = nil) -> CarPlaySnapshot.Scan {
    CarPlayScanBuilder.scan(inputs ?? readyInputs(), source: source)
  }

  // MARK: - Rows from the directory

  @Test
  func `The rows are the directory's repeaters, strongest first, without a scan`() {
    let result = scan(source())
    #expect(result.results.map(\.name) == [
      "Bravo",
      "Alpha",
      L10n.Tools.Tools.NodeDiscovery.unidentifiedRelay("EE"),
      L10n.Tools.Tools.NodeDiscovery.ambiguous("Ridge?", 2),
    ])
    #expect(result.sections.map(\.title) == [NodeRouteFormat.joined([NodeDiscoveryFilter.repeaters.localizedTitle, "4"])])
    #expect(result.results.first?.publicKey == Self.bravoKey)
    #expect(result.results.last?.publicKey == Self.sharedHash)
  }

  @Test
  func `A saved name reads only on a row resolved to exactly its key`() {
    // Saved nodes sharing the unknown relay's hash and the shared one, never heard on this channel
    let konaKey = Self.unknownHash + Data(repeating: 0x7F, count: 31)
    let lookalike = Self.sharedHash + Data(repeating: 0x09, count: 31)
    var labelled = source()
    labelled.nicknames = [Self.alphaKey: "Alpha Ops", konaKey: "Kona Hill", lookalike: "Lookalike", Self.summitKey: "Summit Ops"]
    let names = scan(labelled).results.map(\.name)
    #expect(names == [
      "Bravo",
      "Alpha Ops",
      L10n.Tools.Tools.NodeDiscovery.unidentifiedRelay("EE"),
      L10n.Tools.Tools.NodeDiscovery.ambiguous("Ridge?", 2),
    ])
    #expect(!names.contains { $0.contains("Kona Hill") || $0.contains("Lookalike") })
  }

  @Test
  func `Sensors list only the sensors`() {
    let result = scan(source(filter: .sensors))
    #expect(result.results.map(\.name) == ["Soil"])
    #expect(result.sections.map(\.title) == [NodeRouteFormat.joined([NodeDiscoveryFilter.sensors.localizedTitle, "1"])])
  }

  @Test
  func `Saved and new nodes split into New then Contacts with full counts`() {
    let sections = scan(source(contactKeys: [Self.alphaKey])).sections
    #expect(sections.map(\.title) == [
      NodeRouteFormat.joined([L10n.Tools.Tools.NodeDiscovery.Badge.new, "3"]),
      NodeRouteFormat.joined([L10n.Contacts.Contacts.Discovery.Segment.contacts, "1"]),
    ])
    #expect(sections[1].rows.map(\.name) == ["Alpha"])
  }

  @Test
  func `Rows fit beside the controls, strongest taken before the split`() {
    var inputs = readyInputs()
    inputs.listLimit = 4
    let result = scan(source(contactKeys: [Self.alphaKey]), inputs: inputs)
    #expect(result.results.map(\.name) == ["Bravo", "Alpha"])
    #expect(result.sections.map(\.title) == [
      NodeRouteFormat.joined([L10n.Tools.Tools.NodeDiscovery.Badge.new, "3"]),
      NodeRouteFormat.joined([L10n.Contacts.Contacts.Discovery.Segment.contacts, "1"]),
    ])
  }

  @Test
  func `A row reads both directions and the place`() {
    let rows = scan(source()).results
    let bravo = rows[0]
    #expect(bravo.detail == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.snrDown("9.0"), L10n.Tools.Tools.NodeDiscovery.snrUp("7.5"),
    ]))
    let alpha = rows[1]
    let place = alpha.info.first { $0.title == L10n.Tools.Tools.NodeDiscovery.distanceWhenHeard }?.detail
    #expect(place?.isEmpty == false)
    #expect(alpha.detail == NodeRouteFormat.joined([L10n.Tools.Tools.NodeDiscovery.snrDown("5.0"), place]))
    // No uplink is known for a relay, and no place without a heard-from fix.
    #expect(rows[2].detail == L10n.Tools.Tools.NodeDiscovery.snrDown("2.0"))
  }

  @Test
  func `Signal bars and colour come from SNRQuality`() {
    let rows = scan(source()).results
    #expect(rows.map(\.barLevel) == [1.0, 0.75, 0.75, 0.75])
    #expect(rows[0].tint == .color(.green))
  }

  @Test
  func `The detail screen says how the node was heard, read-only`() {
    let rows = scan(source()).results
    let bravo = rows[0].info
    #expect(bravo.map(\.title) == [
      L10n.Tools.Tools.NodeDiscovery.youHearThem,
      L10n.Tools.Tools.NodeDiscovery.theyHearYou,
      L10n.RemoteNodes.RemoteNodes.History.rssi,
      L10n.Contacts.Contacts.Detail.lastHeard,
      L10n.Contacts.Contacts.Detail.type,
      L10n.Contacts.Contacts.PathDetail.status,
    ])
    #expect(bravo[0].detail == NodeRouteFormat.joined([NodeDiscoveryFormat.snr(9), SNRQuality.excellent.localizedLabel]))
    #expect(bravo[2].detail == "-90 dBm")
    #expect(bravo[3].detail == L10n.Tools.Tools.NodeDiscovery.freshness(HomeFormat.age(120)))
    #expect(bravo[4].detail == ContactType.room.localizedName)
    #expect(bravo.last?.detail == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.Badge.new,
      L10n.Tools.Tools.NodeDiscovery.Badge.answeredYourScan,
      L10n.Tools.Tools.NodeDiscovery.Badge.hearsYou,
    ]))

    // Heard relaying once: dimmed on the phone, "Heard once" here, and no type was said.
    let shared = rows[3].info
    #expect(!shared.contains { $0.title == L10n.Contacts.Contacts.Detail.type })
    #expect(shared.last?.detail == NodeRouteFormat.joined([
      L10n.Tools.Tools.NodeDiscovery.Badge.new,
      L10n.Tools.Tools.NodeDiscovery.Badge.relaying,
      L10n.Tools.Tools.NodeDiscovery.Badge.heardOnce,
    ]))
    #expect(rows.allSatisfy { $0.info.count <= CarPlaySnapshotBuilder.maxInfoItems })
  }

  // MARK: - Header and summary

  @Test
  func `The header counts the nodes nearby`() {
    // Alpha, Bravo, the twice-heard relay and the sensor are confirmed and live; the relay
    // heard once is not.
    #expect(scan(source()).header == L10n.Localizable.CarPlay.Scan.nearby(4))
    #expect(scan(source(directory: NeighbourDirectory())).header == L10n.Tools.Tools.Subtitle.nodeDiscovery)
  }

  @Test
  func `The subtitle carries the best and farthest nodes`() {
    // Only Alpha has a position and a heard-from fix, so it is the farthest.
    let subtitle = scan(source()).subtitle
    #expect(subtitle?.hasPrefix(L10n.Localizable.CarPlay.Scan.best(NodeDiscoveryFormat.snr(9), "Bravo")) == true)
    #expect(subtitle?.hasSuffix("Alpha") == true)
  }

  @Test
  func `Nothing heard yet says so`() {
    let result = scan(source(directory: directory([])))
    #expect(result.header == L10n.Localizable.CarPlay.Scan.nearby(0))
    #expect(result.subtitle == L10n.Tools.Tools.NodeDiscovery.NothingHeard.title)
    #expect(result.sections.isEmpty)
  }

  // MARK: - Controls and the probe

  @Test
  func `Idle controls scan for each kind, then read Scan Again with the kind`() {
    var controls = scan(source()).controls
    #expect(controls.map(\.title) == [L10n.Localizable.CarPlay.Scan.repeaters, L10n.Localizable.CarPlay.Scan.sensors])
    #expect(controls.allSatisfy { $0.isEnabled && !$0.stops && $0.tint == .feature(.scan) })

    let summary = DiscoveryProbeCoordinator.Summary(filter: .repeaters, answered: 1, heardRelaying: 2, finishedAt: now)
    controls = scan(source(lastSummary: summary)).controls
    #expect(controls[0].title == L10n.Tools.Tools.NodeDiscovery.scanAgain)
    #expect(controls[0].detail == NodeDiscoveryFilter.repeaters.localizedTitle)
    #expect(controls[1].title == L10n.Localizable.CarPlay.Scan.sensors)
  }

  @Test
  func `There is no scan action while cooling down, and the wait is shown`() {
    let until = now.addingTimeInterval(32)
    let result = scan(source(.coolingDown(until: until, reason: .othersScanning)))
    #expect(result.controls.allSatisfy { !$0.isEnabled && !$0.stops })
    #expect(result.header == L10n.Localizable.CarPlay.Scan.nearby(4))
    #expect(CarPlayScanBuilder.timeLeft(until: until, now: now) == Duration.seconds(32).formatted(.time(pattern: .minuteSecond)))
    #expect(result.subtitle == L10n.Localizable.CarPlay.Scan.nextScanIn(CarPlayScanBuilder.timeLeft(until: until, now: now)))
    // The rows stay: the list never empties for a cooldown.
    #expect(result.results.count == 4)
  }

  @Test
  func `A probe started on the phone shows as running in CarPlay`() {
    let source = source(.probing(probe(.sensors, origins: [.phone])))
    #expect(source.filter == .sensors)
    #expect(source.phase == .probing(secondsLeft: 6))
    // The sensor answered at -1 s, after the request went out at -3 s; Bravo's reply is older.
    #expect(source.answeredCount == 1)

    let result = scan(source)
    #expect(result.header == L10n.Tools.Tools.NodeDiscovery.Status.listening(1))
    let sensors = result.controls[1]
    #expect(sensors.title == L10n.Tools.Tools.NodeDiscovery.stopButton)
    #expect(sensors.detail == L10n.Localizable.CarPlay.Scan.progress(1, 6))
    #expect(sensors.stops && sensors.isEnabled && sensors.symbol == "stop.fill")
    #expect(!result.controls[0].isEnabled && !result.controls[0].stops)
    #expect(result.results.map(\.name) == ["Soil"])
  }

  @Test
  func `While Wardrive runs, one row stops it, between probes and during one`() {
    for state: DiscoveryProbeCoordinator.State in [.coolingDown(until: now.addingTimeInterval(40), reason: .spacing),
                                                   .probing(probe(.repeaters, origins: [.wardrive]))] {
      let result = scan(source(state, isWardriving: true))
      #expect(result.controls.count == 1)
      let stop = result.controls[0]
      #expect(stop.title == L10n.Tools.Tools.NodeDiscovery.wardriveStop)
      #expect(stop.detail == L10n.Tools.Tools.NodeDiscovery.wardriveRunning)
      #expect(stop.stops && stop.isEnabled && stop.tint == .critical)
    }
  }

  @Test
  func `A rebuilt connection keeps the probe running`() {
    let source = source(.interrupted(probe(.repeaters, origins: [.carPlay, .wardrive])))
    #expect(source.phase == .probing(secondsLeft: 6))
    #expect(scan(source).controls[0].stops)
  }

  @Test
  func `A probe still waiting to go out shows its answers without a countdown`() {
    let source = source(.probing(probe(.repeaters, origins: [.phone], sentAgo: nil, endsIn: nil)))
    #expect(source.phase == .probing(secondsLeft: nil))
    #expect(source.answeredCount == 0)
    #expect(scan(source).controls[0].detail == L10n.Tools.Tools.NodeDiscovery.Status.listening(0))
  }

  @Test
  func `The Dashboard's Scan row counts the answers while a probe listens`() {
    let inputs = readyInputs()
    var snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    let probing = source(.probing(probe(.sensors, origins: [.phone])))
    CarPlayScanBuilder.complete(&snapshot, inputs: inputs, source: probing)
    #expect(snapshot.scan == CarPlayScanBuilder.scan(inputs, source: probing))
    let option = snapshot.dashboard.options.first { $0.kind == .scan }
    #expect(option?.detail == L10n.Localizable.CarPlay.Scan.progress(1, 6))

    var idle = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    CarPlayScanBuilder.complete(&idle, inputs: inputs, source: source())
    #expect(idle.dashboard.options.first { $0.kind == .scan }?.detail == L10n.Tools.Tools.Subtitle.nodeDiscovery)
  }

  @Test
  func `The snapshot builder's own pass shows the phase from the inputs`() {
    var inputs = readyInputs()
    inputs.scan.isScanning = true
    inputs.scan.secondsLeft = 9
    let controls = CarPlayScanBuilder.scan(inputs).controls
    #expect(controls[0].stops)
    #expect(controls[0].detail == L10n.Localizable.CarPlay.Scan.progress(0, 9))
    #expect(!controls[1].isEnabled)
  }

  // MARK: - Firmware and delivery

  @Test
  func `A listen-only scan started on the phone leaves the car's screen as it was`() {
    // Firmware before v1.10: the phone's Scan Now only listens; nothing was asked to answer
    var listening = probe(.sensors, origins: [.phone], sentAgo: 2, endsIn: 4)
    listening.listensOnly = true
    let idle = source(canScan: false)
    for state in [DiscoveryProbeCoordinator.State.probing(listening), .interrupted(listening)] {
      let listened = source(state, canScan: false)
      #expect(listened == idle, "not a scan in the car: no phase, no answered count, the car's own kind")
      let result = scan(listened)
      #expect(result.header == L10n.Localizable.CarPlay.Scan.nearby(4))
      #expect(result.subtitle == L10n.Localizable.CarPlay.Scan.unsupported)
      #expect(result.controls.allSatisfy { !$0.isEnabled && !$0.stops })
    }
  }

  @Test
  func `On firmware without scanning the rows stay off and say why, and the nodes stay listed`() {
    let canScan = Self.canScan(firmwareVersion: 7, firmwareVersionString: "v1.9.0")
    #expect(!canScan)
    let result = scan(source(canScan: canScan))
    #expect(result.controls.count == 2)
    #expect(result.controls.allSatisfy { !$0.isEnabled && !$0.stops })
    #expect(result.controls.allSatisfy { $0.detail == L10n.Localizable.CarPlay.Scan.unsupported })
    #expect(result.subtitle == L10n.Localizable.CarPlay.Scan.unsupported)
    #expect(result.header == L10n.Localizable.CarPlay.Scan.nearby(4))
    #expect(result.results.count == 4)

    // From v1.10 the rows scan as before
    let scanning: [(code: UInt8, version: String)] = [(8, "v1.10.0"), (8, "v1.11.0"), (14, "v1.18.0")]
    for (code, version) in scanning {
      let controls = scan(source(canScan: Self.canScan(firmwareVersion: code, firmwareVersionString: version))).controls
      #expect(controls.allSatisfy { $0.isEnabled && $0.detail == nil }, "\(version)")
    }

    // The snapshot builder's own pass agrees
    var inputs = readyInputs()
    inputs.scan.canScan = false
    #expect(CarPlayScanBuilder.scan(inputs).controls.allSatisfy { !$0.isEnabled })
  }

  @Test
  func `The link and the last failure come before the firmware, which comes before the wait`() {
    var inputs = readyInputs()
    inputs.isRadioReady = false
    inputs.connectionState = .syncing
    #expect(scan(source(canScan: false), inputs: inputs).subtitle == L10n.Settings.BleStatus.Status.syncing)
    let failed = L10n.Localizable.CarPlay.Scan.failed
    #expect(scan(source(message: failed, canScan: false)).subtitle == failed)
    let cooling = source(.coolingDown(until: now.addingTimeInterval(30), reason: .othersScanning), canScan: false)
    #expect(scan(cooling).subtitle == L10n.Localizable.CarPlay.Scan.unsupported)
  }

  @Test
  func `After a scan the radio missed packets in, the subtitle says replies may be missing until the next scan`() {
    let missed = DiscoveryProbeCoordinator.Summary(filter: .repeaters, answered: 1, heardRelaying: 2, finishedAt: now, radioMissed: 4)
    let missing = L10n.Localizable.CarPlay.Scan.repliesMayBeMissing
    // In its cooldown, beside the wait
    let until = now.addingTimeInterval(32)
    let cooling = scan(source(.coolingDown(until: until, reason: .spacing), lastSummary: missed))
    #expect(cooling.subtitle == NodeRouteFormat.joined([
      L10n.Localizable.CarPlay.Scan.nextScanIn(CarPlayScanBuilder.timeLeft(until: until, now: now)),
      missing,
    ]))
    // Then alone, in place of the best and farthest nodes
    #expect(scan(source(lastSummary: missed)).subtitle == missing)
    // Not while the next scan listens
    #expect(scan(source(.probing(probe(.repeaters, origins: [.phone])), lastSummary: missed)).subtitle != missing)
    // A failure still heads it
    #expect(scan(source(lastSummary: missed, message: L10n.Localizable.CarPlay.Scan.failed)).subtitle == L10n.Localizable.CarPlay.Scan.failed)

    // Nothing missed, or not measured: the usual subtitle
    for radioMissed: Int? in [0, nil] {
      let summary = DiscoveryProbeCoordinator.Summary(
        filter: .repeaters, answered: 1, heardRelaying: 2, finishedAt: now, radioMissed: radioMissed
      )
      let subtitle = scan(source(lastSummary: summary)).subtitle
      #expect(subtitle?.hasPrefix(L10n.Localizable.CarPlay.Scan.best(NodeDiscoveryFormat.snr(9), "Bravo")) == true)
    }
  }

  @Test
  func `No firmware or delivery wording mentions the phone`() {
    let texts = [L10n.Localizable.CarPlay.Scan.unsupported, L10n.Localizable.CarPlay.Scan.repliesMayBeMissing]
    #expect(texts.allSatisfy { !$0.localizedCaseInsensitiveContains("phone") })
  }

  @Test
  func `Why the last probe failed heads the list`() {
    let result = scan(source(message: L10n.Localizable.CarPlay.Scan.failed))
    #expect(result.subtitle == L10n.Localizable.CarPlay.Scan.failed)
    #expect(result.results.count == 4)
  }

  @Test
  func `A link still coming up is not called disconnected`() {
    var inputs = readyInputs()
    inputs.isRadioReady = false
    inputs.connectionState = .syncing
    let result = scan(source(), inputs: inputs)
    #expect(result.subtitle == L10n.Settings.BleStatus.Status.syncing)
    #expect(result.controls.allSatisfy { !$0.isEnabled })

    var gone = CarPlayInputs()
    gone.lastRadioName = "Heltec"
    // What was heard before the radio went stays listed.
    #expect(scan(source(), inputs: gone).subtitle == L10n.Localizable.CarPlay.Scan.notReady)
    #expect(scan(source(), inputs: gone).results.count == 4)
    gone.bluetooth = .poweredOff
    #expect(scan(source(), inputs: gone).subtitle == L10n.Localizable.CarPlay.Home.bluetoothOff)
  }

  @Test
  func `No blocked or empty wording mentions the phone`() {
    let texts = [
      L10n.Localizable.CarPlay.Scan.busy, L10n.Localizable.CarPlay.Scan.notReady, L10n.Localizable.CarPlay.Scan.failed,
      L10n.Localizable.CarPlay.Scan.noReplies, L10n.Localizable.CarPlay.Home.starting,
      L10n.Localizable.CarPlay.Home.noRadioPaired, L10n.Localizable.CarPlay.Home.bluetoothOff,
      L10n.Localizable.CarPlay.Home.bluetoothNotAllowed, L10n.Localizable.CarPlay.Chats.siriOff,
      L10n.Localizable.CarPlay.Chats.empty, L10n.Localizable.CarPlay.Chats.siriHint,
      L10n.Localizable.CarPlay.Advert.Sheet.message, L10n.Localizable.CarPlay.Advert.failed,
      L10n.Localizable.CarPlay.Scan.nextScanIn("0:32"), L10n.Localizable.CarPlay.Scan.nearby(3),
      L10n.Tools.Tools.Subtitle.nodeDiscovery, L10n.Tools.Tools.NodeDiscovery.NothingHeard.title,
      L10n.Tools.Tools.NetworkHealth.Empty.title,
    ]
    #expect(texts.allSatisfy { !$0.localizedCaseInsensitiveContains("phone") })
  }

  @Test
  func `Only a full node list passes through as itself`() {
    #expect(CarPlayController.carSafeMessage(nil, maxContacts: 100) == nil)
    let full = L10n.Contacts.Contacts.Add.Error.nodeListFull(100)
    #expect(CarPlayController.carSafeMessage(full, maxContacts: 100) == full)
    let simple = L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
    #expect(CarPlayController.carSafeMessage(simple, maxContacts: nil) == simple)
    #expect(CarPlayController.carSafeMessage("Open the app on your iPhone", maxContacts: 100) == L10n.Localizable.CarPlay.Scan.failed)
  }
}
