import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("HomeStatusLines")
struct HomeStatusLinesTests {
  private static func device(blePin: UInt32 = 0) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      publicKey: Data(repeating: 0xBB, count: 32),
      nodeName: "TestNode",
      firmwareVersion: 1,
      firmwareVersionString: "1.12.0",
      manufacturerName: "Test",
      buildDate: "2025-01-01",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 910_525,
      bandwidth: 62500,
      spreadingFactor: 7,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 22,
      latitude: 0,
      longitude: 0,
      blePin: blePin,
      manualAddContacts: false,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: true,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }

  @Test
  func `Link titles match the status menu`() {
    #expect(HomeStatusLines.linkTitle(.ready) == L10n.Settings.BleStatus.Status.ready)
    #expect(HomeStatusLines.linkTitle(.disconnected) == L10n.Settings.BleStatus.Status.disconnected)
    #expect(HomeStatusLines.linkTitle(.syncing) == L10n.Settings.BleStatus.Status.syncing)
  }

  @Test
  func `Battery detail explains a missing reading`() {
    #expect(HomeStatusLines.batteryDetail(hasDevice: false, voltage: nil, isReady: false, batteryPresent: nil)
      == L10n.Localizable.Home.noRadio)
    #expect(HomeStatusLines.batteryDetail(hasDevice: true, voltage: nil, isReady: true, batteryPresent: false)
      == L10n.Settings.Battery.notPresent)
    #expect(HomeStatusLines.batteryDetail(hasDevice: true, voltage: nil, isReady: false, batteryPresent: nil)
      == L10n.Settings.Dashboard.noReading)
    #expect(HomeStatusLines.batteryDetail(hasDevice: true, voltage: 4.01, isReady: true, batteryPresent: true)
      == BatteryLevel.formattedVoltage(4.01))
  }

  @Test
  func `Bluetooth names its PIN kind only when asked`() {
    let device = Self.device()
    #expect(HomeStatusLines.transportDetail(device, isWiFi: false) == L10n.Localizable.Home.Network.defaultPin)
    #expect(HomeStatusLines.transportDetail(Self.device(blePin: 424_242), isWiFi: false) == L10n.Localizable.Home.Network.customPin)
    // 123456 is a PIN someone chose: only no PIN at all is the radio's default.
    #expect(HomeStatusLines.transportDetail(Self.device(blePin: 123_456), isWiFi: false) == L10n.Localizable.Home.Network.customPin)
    #expect(HomeStatusLines.transportDetail(device, isWiFi: false, includesPin: false) == nil)
  }

  @Test
  func `Frequency reads in megahertz`() {
    #expect(HomeStatusLines.megahertz(910_525) == (910.525).formatted(.number.precision(.fractionLength(3))))
  }

  @Test
  func `Radio lines lead with the preset and modulation`() {
    let lines = HomeStatusLines.radioLines(Self.device(), region: nil, txPower: 22)
    #expect(lines.count == 3)
    #expect(lines[1] == NodeRouteFormat.joined([HomeStatusLines.modulation(Self.device()), L10n.Tools.Tools.Spectrum.Header.codingRate(Int(Self.device().codingRate))]))
  }

  @Test
  func `Radio line groups keep each fact separate for narrow cards`() {
    let groups = HomeStatusLines.radioLineGroups(Self.device(), region: nil, txPower: 22)
    #expect(groups.count == 3)
    #expect(groups[1] == [HomeStatusLines.modulation(Self.device()), L10n.Tools.Tools.Spectrum.Header.codingRate(Int(Self.device().codingRate))])
    #expect(groups[2] == [L10n.Settings.DeviceInfo.txPowerFormat(22.formatted()), HomeStatusLines.packetAirtime(Self.device())])
    #expect(HomeStatusLines.radioLineGroups(Self.device(), region: nil, txPower: nil)[2] == [HomeStatusLines.packetAirtime(Self.device())])
  }

  @Test
  func `Last heard without positions is just the age`() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(HomeStatusLines.lastHeardLine(lastHeard: now.addingTimeInterval(-120), coordinate: nil, origin: nil, now: now)
      == HomeFormat.age(120))
  }

  // MARK: - Nearby Now

  /// A snapshot of `records` for `radioID`, taken at `date`.
  private static func neighbourSnapshot(_ records: [NeighbourRecord], radioID: UUID, at date: Date) -> NeighbourSnapshot {
    NeighbourSnapshot(
      radioID: radioID,
      takenAt: date,
      neighbours: NeighbourResolver.resolveAll(NeighbourTable(records: records), index: .empty, now: date)
    )
  }

  /// A repeater confirmed by its own advert, heard `age` seconds before `date`.
  private static func advertRecord(key: UInt8, heard age: TimeInterval, before date: Date) -> NeighbourRecord {
    let heard = date.addingTimeInterval(-age)
    return NeighbourRecord(
      identity: .fullKey(Data(repeating: key, count: 32)),
      firstHeard: heard,
      lastHeard: heard,
      heardCount: 1,
      lastSNR: 6,
      sources: [.advert: NeighbourSourceStats(count: 1, firstHeard: heard, lastHeard: heard)],
      nodeTypeRaw: ContactType.repeater.rawValue
    )
  }

  @Test
  @MainActor
  func `Nearby now reads the count for none, one and many`() {
    #expect(HomeStatusCards.nearbyNowLine(0) == L10n.Localizable.Home.Nodes.nearbyNow(0))
    #expect(HomeStatusCards.nearbyNowLine(1) == L10n.Localizable.Home.Nodes.nearbyNow(1))
    #expect(HomeStatusCards.nearbyNowLine(27) == L10n.Localizable.Home.Nodes.nearbyNow(27))
    #expect(HomeStatusCards.nearbyNowLine(27)?.contains("27") == true)
    #expect(HomeStatusCards.nearbyNowAccessibility(0) == L10n.Localizable.Home.Nodes.nearbyNowAccessibility(0))
    #expect(HomeStatusCards.nearbyNowAccessibility(1) == L10n.Localizable.Home.Nodes.nearbyNowAccessibility(1))
    #expect(HomeStatusCards.nearbyNowAccessibility(27) == L10n.Localizable.Home.Nodes.nearbyNowAccessibility(27))
  }

  @Test
  @MainActor
  func `Nearby now is hidden until the directory has a snapshot`() {
    let directory = NeighbourDirectory(now: { Date(timeIntervalSince1970: 1_800_000_000) })
    #expect(directory.nearbyNowCount == nil)
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount) == nil)
    #expect(HomeStatusCards.nearbyNowAccessibility(directory.nearbyNowCount) == nil)
    // An empty snapshot is a real answer: the line shows zero rather than hiding
    let radioID = UUID()
    directory.apply(Self.neighbourSnapshot([], radioID: radioID, at: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount) == L10n.Localizable.Home.Nodes.nearbyNow(0))
  }

  @Test
  @MainActor
  func `Nearby now follows the directory without a dashboard reload`() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let radioID = UUID()
    let directory = NeighbourDirectory(now: { now })
    // Never loaded: the line must come from the directory alone
    let dashboard = HomeDashboardModel(reloadInterval: .zero)

    directory.apply(Self.neighbourSnapshot([Self.advertRecord(key: 0xA1, heard: 60, before: now)], radioID: radioID, at: now))
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount(now: now)) == L10n.Localizable.Home.Nodes.nearbyNow(1))

    // A newer snapshot changes the line at once, still with no dashboard load
    directory.apply(Self.neighbourSnapshot([
      Self.advertRecord(key: 0xA1, heard: 30, before: now),
      Self.advertRecord(key: 0xB2, heard: 90, before: now),
      Self.advertRecord(key: 0xC3, heard: 3 * 3600, before: now),
    ], radioID: radioID, at: now))
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount(now: now)) == L10n.Localizable.Home.Nodes.nearbyNow(2))
    // The card's clock alone counts the neighbours down once they go quiet
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount(now: now.addingTimeInterval(15 * 60)))
      == L10n.Localizable.Home.Nodes.nearbyNow(0))
    #expect(dashboard.lastHeard == nil)
    #expect(dashboard.contactCount == nil)
  }

  @Test
  @MainActor
  func `Nearby now counts only the rows of the channel the radio is on`() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let radioID = UUID()
    let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
    let ledger = LedgerSnapshot(radioID: radioID, channelKey: channel.key, channel: channel, selfKey: nil, takenAt: now, version: 1, nodes: [])
    let directory = NeighbourDirectory(now: { now })
    directory.apply(NeighbourSnapshot(
      radioID: radioID,
      takenAt: now,
      neighbours: NeighbourResolver.resolveAll(
        NeighbourTable(records: [Self.advertRecord(key: 0xA1, heard: 60, before: now), Self.advertRecord(key: 0xB2, heard: 90, before: now)]),
        index: PacketNodeIndex(ledger: ledger),
        now: now
      ),
      ledger: ledger
    ))
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount) == L10n.Localizable.Home.Nodes.nearbyNow(2))

    // Retuned: the service publishes an empty, cold snapshot until the radio reports its channel
    directory.apply(Self.neighbourSnapshot([], radioID: radioID, at: now.addingTimeInterval(5)))
    #expect(directory.ledger.isCold)
    #expect(HomeStatusCards.nearbyNowLine(directory.nearbyNowCount) == L10n.Localizable.Home.Nodes.nearbyNow(0))
  }
}
