import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("CarPlaySnapshot")
struct CarPlaySnapshotTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  /// Message text no CarPlay screen may ever show.
  private static let secret = "SECRET-MESSAGE-TEXT-7f3a"

  private func readyInputs() -> CarPlayInputs {
    var inputs = CarPlayInputs()
    inputs.connectionState = .ready
    inputs.isRadioReady = true
    inputs.radio = .init(
      name: "Heltec",
      model: "Heltec V3 · v1.9.1",
      frequency: "910.525 MHz",
      presetName: "USA/Canada",
      txPower: "22 dBm",
      transportDetail: "Default PIN",
      gpsStatus: .fix,
      locationSharing: "Not sharing"
    )
    inputs.batteryPercent = 87
    inputs.batteryDetail = "4.01 V"
    inputs.contactCount = 42
    inputs.newNodeCount = 3
    inputs.unread = 5
    return inputs
  }

  private func conversation(_ index: Int, unread: Int = 0, muted: Bool = false) -> HomeDashboardModel.ConversationLine {
    HomeDashboardModel.ConversationLine(
      id: UUID(),
      name: "Chat \(index)",
      date: now.addingTimeInterval(-Double(index) * 60),
      preview: Self.secret,
      isUnread: unread > 0,
      kind: index.isMultiple(of: 2) ? .channel : .direct,
      unreadCount: unread,
      isMuted: muted
    )
  }

  private func dashboard(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Dashboard {
    CarPlaySnapshotBuilder.make(from: inputs, now: now).dashboard
  }

  private func card(_ kind: CarPlaySnapshot.CardKind, in inputs: CarPlayInputs) -> CarPlaySnapshot.Card? {
    dashboard(inputs).cards.first { $0.kind == kind }
  }

  private func option(_ kind: CarPlaySnapshot.OptionKind, in inputs: CarPlayInputs) -> CarPlaySnapshot.Option? {
    dashboard(inputs).options.first { $0.kind == kind }
  }

  // MARK: - Dashboard header

  @Test
  func `The header names the radio and leads its subtitle with the link`() {
    let ready = dashboard(readyInputs())
    #expect(ready.header == "Heltec")
    #expect(ready.subtitle == NodeRouteFormat.joined([L10n.Settings.BleStatus.Status.ready, "Heltec V3 · v1.9.1"]))

    var connecting = readyInputs()
    connecting.connectionState = .connecting
    connecting.isRadioReady = false
    #expect(dashboard(connecting).subtitle?.hasPrefix(L10n.Settings.BleStatus.Status.connecting) == true)
  }

  @Test
  func `Bluetooth off explains a radio that won't reconnect, without mentioning the phone`() {
    var inputs = CarPlayInputs()
    inputs.lastRadioName = "Heltec"
    inputs.bluetooth = .poweredOff
    let off = dashboard(inputs)
    #expect(off.header == "Heltec")
    #expect(off.subtitle == L10n.Localizable.CarPlay.Home.bluetoothOff)

    inputs.bluetooth = .unauthorized
    #expect(dashboard(inputs).subtitle == L10n.Localizable.CarPlay.Home.bluetoothNotAllowed)
  }

  @Test
  func `Bluetooth state is ignored while a radio is connected`() {
    var inputs = readyInputs()
    inputs.bluetooth = .poweredOff
    #expect(dashboard(inputs).subtitle?.contains(L10n.Localizable.CarPlay.Home.bluetoothOff) == false)
  }

  @Test
  func `Never paired says so and offers only Network Health`() {
    let snapshot = CarPlaySnapshotBuilder.make(from: CarPlayInputs(), now: now)
    #expect(snapshot.dashboard.header == L10n.Localizable.Home.noRadio)
    #expect(snapshot.dashboard.subtitle == L10n.Localizable.CarPlay.Home.noRadioPaired)
    #expect(snapshot.dashboard.options.filter(\.isEnabled).map(\.kind) == [.scan, .health])
    #expect(snapshot.chats.empty.title == L10n.Localizable.CarPlay.Home.noRadioPaired)
    #expect(snapshot.nodes.emptyTitle == L10n.Localizable.CarPlay.Home.noRadioPaired)
    #expect(snapshot.scan.controls.allSatisfy { !$0.isEnabled })
    #expect(snapshot.scan.subtitle == L10n.Localizable.CarPlay.Home.noRadioPaired)
  }

  @Test
  func `Starting shows the app's name and nothing to tap`() {
    var inputs = readyInputs()
    inputs.isStarting = true
    let snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    #expect(snapshot.dashboard.header == CarPlaySnapshotBuilder.appName)
    #expect(snapshot.dashboard.subtitle == L10n.Localizable.CarPlay.Home.starting)
    #expect(snapshot.dashboard.options.isEmpty)
    #expect(snapshot.dashboard.cards.isEmpty)
    #expect(snapshot.chats.unread == 0)
    #expect(snapshot.scan.subtitle == L10n.Localizable.CarPlay.Home.starting)
  }

  @Test
  func `Long names are cut, never the status`() {
    #expect(CarPlaySnapshotBuilder.glanceName("  🛰️ Hilltop  ") == "Hilltop")
    #expect(CarPlaySnapshotBuilder.glanceName("🛰️🛰️") == "🛰️🛰️")
    let long = CarPlaySnapshotBuilder.glanceName("Mount Wilson Summit Repeater")
    #expect(long.count == CarPlaySnapshotBuilder.maxGlanceNameLength)
    #expect(long.hasSuffix("…"))

    var inputs = readyInputs()
    inputs.lastHeard = .init(name: "Mount Wilson Summit Repeater", line: "2m · 3.4 mi NE")
    let nodes = card(.nodes, in: inputs)
    #expect(nodes?.detail.hasPrefix(NodeRouteFormat.joined([L10n.Localizable.Tabs.nodes, "2m · 3.4 mi NE"])) == true)
  }

  // MARK: - Dashboard options

  @Test
  func `Options are the driving tools, Scan first, and nothing that is setup`() {
    let options = dashboard(readyInputs()).options
    #expect(options.map(\.kind) == [.scan, .advert, .health])
    #expect(options.map(\.text) == [
      // CarPlay scans only, so it keeps Scan for Nodes' name rather than the phone's Scan & Traffic.
      L10n.Tools.Tools.nodeDiscovery, L10n.Tools.Tools.advert, ToolSelection.networkHealth.title,
    ])
    let excluded = [
      ToolSelection.cli.title, L10n.Tools.Tools.Traffic.title, ToolSelection.lineOfSight.title,
      ToolSelection.tracePath.title, L10n.Settings.LocationSharing.title,
    ]
    #expect(!options.contains { excluded.contains($0.text) })
    #expect(options.map(\.pushes) == [true, false, true])
  }

  @Test
  func `Options use the app's tile symbols and colours`() {
    let inputs = readyInputs()
    #expect(option(.health, in: inputs)?.symbol == ToolSelection.networkHealth.systemImage)
    #expect(option(.health, in: inputs)?.tint == .feature(.health))
    #expect(option(.advert, in: inputs)?.symbol == "megaphone.fill")
    #expect(option(.advert, in: inputs)?.tint == .feature(.advert))
    #expect(option(.scan, in: inputs)?.symbol == ToolSelection.nodeDiscovery.systemImage)
    #expect(option(.scan, in: inputs)?.tint == .feature(.scan))
    #expect(option(.scan, in: inputs)?.detail == L10n.Tools.Tools.Subtitle.nodeDiscovery)
  }

  @Test
  func `Send Advert needs a ready radio and is locked while sending; Network Health never is`() {
    var inputs = readyInputs()
    inputs.isRadioReady = false
    inputs.connectionState = .syncing
    #expect(option(.health, in: inputs)?.isEnabled == true)
    #expect(option(.advert, in: inputs)?.isEnabled == false)

    inputs = readyInputs()
    inputs.advertNote = .sending
    #expect(option(.advert, in: inputs)?.isEnabled == false)
    #expect(option(.advert, in: inputs)?.detail == L10n.Localizable.CarPlay.Advert.sending)
  }

  @Test
  func `The advert note goes from idle through sending to sent or failed, as the app's tile`() {
    var inputs = readyInputs()
    #expect(option(.advert, in: inputs)?.detail == L10n.Tools.Tools.Subtitle.advert)

    inputs.advertNote = .sent
    let sent = option(.advert, in: inputs)
    #expect(sent?.detail == L10n.Localizable.CarPlay.Advert.sent)
    #expect(sent?.symbol == "checkmark")
    #expect(sent?.tint == .success)
    #expect(sent?.isEnabled == true)

    inputs.advertNote = .failed
    let failed = option(.advert, in: inputs)
    #expect(failed?.detail == L10n.Localizable.CarPlay.Advert.failed)
    #expect(failed?.symbol == "exclamationmark.triangle.fill")
    #expect(failed?.tint == .warning)
  }

  @Test
  func `A running scan shows its progress on the Scan option`() {
    var inputs = readyInputs()
    inputs.scan.isScanning = true
    inputs.scan.secondsLeft = 9
    #expect(option(.scan, in: inputs)?.detail == L10n.Localizable.CarPlay.Scan.progress(0, 9))
  }

  @Test
  func `Without the radio tools no option is offered, Network Health included`() {
    var inputs = readyInputs()
    inputs.radioTools = false
    #expect(dashboard(inputs).options.isEmpty)
    #expect(dashboard(inputs).cards.count == 5)
  }

  // MARK: - Dashboard cards

  @Test
  func `Cards lead with the radio, then messages and nodes, and radio-only cards need a radio`() {
    #expect(dashboard(readyInputs()).cards.map(\.kind) == [.radio, .chats, .nodes, .mesh, .gps])

    var inputs = CarPlayInputs()
    inputs.lastRadioName = "Heltec"
    #expect(dashboard(inputs).cards.map(\.kind) == [.radio, .chats, .nodes, .mesh])
    #expect(dashboard(CarPlayInputs()).cards.map(\.kind) == [.radio, .chats, .nodes])
  }

  @Test
  func `The Mesh row leads with the last packet's signal, then the rate and the nodes heard`() {
    var inputs = readyInputs()
    inputs.live.lastRSSI = -92
    inputs.live.lastSNR = 7.5
    inputs.live.packetsPerMinute = 12
    let mesh = card(.mesh, in: inputs)
    #expect(mesh?.text == CarPlayCardBuilder.signalText(rssi: -92, snr: 7.5))
    #expect(mesh?.detail == NodeRouteFormat.joined([
      L10n.Localizable.CarPlay.Cards.mesh,
      L10n.Localizable.CarPlay.Cards.perMinute(12),
      L10n.Localizable.CarPlay.Cards.heardCount(CarPlayCardBuilder.heardCount(inputs)),
    ]))
    #expect(mesh?.opensTab == .spectrum)
    #expect(mesh?.info.isEmpty == false, "its readings, for a car without the radio tools")

    inputs.live = .init()
    #expect(card(.mesh, in: inputs)?.text == L10n.Tools.Tools.Spectrum.waitingForPacket)
  }

  @Test
  func `Only a low battery gets a card, under the radio`() {
    var inputs = readyInputs()
    inputs.batteryPercent = 15
    #expect(dashboard(inputs).cards.map(\.kind) == [.radio, .battery, .chats, .nodes, .mesh, .gps])
  }

  @Test
  func `Without a link the Radio card says why, in the warning colour`() {
    var inputs = CarPlayInputs()
    inputs.lastRadioName = "Heltec"
    inputs.connectionState = .disconnected
    let radio = card(.radio, in: inputs)
    #expect(radio?.text == "Heltec")
    #expect(radio?.detail == CarPlaySnapshotBuilder.linkStatus(inputs))
    #expect(radio?.tint == .warning)
  }

  @Test
  func `Card texts are the app's card values`() {
    var low = readyInputs()
    low.batteryPercent = 15
    let battery = card(.battery, in: low)
    #expect(battery?.text == NodeRouteFormat.joined([BatteryLevel.formattedPercent(15), BatteryLevel.low.title]))
    #expect(battery?.detail == NodeRouteFormat.joined([L10n.Settings.DeviceInfo.battery, "4.01 V"]))
    #expect(battery?.symbol == BatteryLevel.symbol(for: 15))

    let inputs = readyInputs()
    let radio = card(.radio, in: inputs)
    #expect(radio?.text == NodeRouteFormat.joined(["Heltec", BatteryLevel.formattedPercent(87)]))
    #expect(radio?.detail == NodeRouteFormat.joined([L10n.Settings.BleStatus.Status.ready, "910.525 MHz", "USA/Canada"]))
    // The radio's own avatar colour, as the phone draws it.
    #expect(radio?.tint == .avatar(.radio))

    let gps = card(.gps, in: inputs)
    #expect(gps?.text == GNSSStatus.fix.text)
    #expect(gps?.detail == NodeRouteFormat.joined([L10n.Localizable.Tabs.gps, "Not sharing"]))

    let nodes = card(.nodes, in: inputs)
    #expect(nodes?.text == NodeRouteFormat.joined(["42", L10n.Localizable.Home.Nodes.new(3)]))
    #expect(nodes?.detail == NodeRouteFormat.joined([L10n.Localizable.Tabs.nodes, L10n.Localizable.Home.Nodes.noAdverts]))

    let chats = card(.chats, in: inputs)
    #expect(chats?.text == L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(5))
    #expect(chats?.detail == L10n.Localizable.Tabs.chats)
  }

  @Test
  func `A low battery and a repeating radio take the app's warning colours`() {
    var inputs = readyInputs()
    inputs.batteryPercent = 15
    inputs.radio?.clientRepeat = true
    #expect(card(.battery, in: inputs)?.tint == .warning)
    #expect(card(.radio, in: inputs)?.tint == .feature(.radioRepeat))
    inputs.batteryPercent = 5
    #expect(card(.battery, in: inputs)?.tint == .critical)
  }

  @Test
  func `No new nodes leaves the note off the Nodes card`() {
    var inputs = readyInputs()
    inputs.newNodeCount = 0
    #expect(card(.nodes, in: inputs)?.text == "42")
  }

  @Test
  func `Chats and Nodes open their tabs, Mesh and GPS push their screens with the radio tools`() {
    var inputs = readyInputs()
    inputs.tabs = CarPlayTabLayout.tabs()
    let cards = dashboard(inputs).cards
    #expect(cards.filter { $0.opensTab != nil }.map(\.kind) == [.chats, .nodes, .mesh, .gps])
    #expect(cards.compactMap(\.opensTab) == [.comm, .nodes, .spectrum, .gps])

    inputs.radioTools = false
    #expect(card(.gps, in: inputs)?.opensTab == nil)
    #expect(card(.mesh, in: inputs)?.opensTab == nil)
  }

  @Test
  func `The Dashboard fits the car's list limit`() {
    var inputs = readyInputs()
    let full = dashboard(inputs)
    #expect(full.options.count + full.cards.count == 8)
    inputs.listLimit = 7
    let limited = dashboard(inputs)
    // The cards come first, as on Home; the options take the room left.
    #expect(limited.cards.count == 5)
    #expect(limited.options.map(\.kind) == [.scan, .advert])
  }

  @Test
  func `Cards without a tab carry their lines for a read-only screen`() {
    var low = readyInputs()
    low.batteryPercent = 15
    let battery = card(.battery, in: low)
    #expect(battery?.title == L10n.Settings.DeviceInfo.battery)
    #expect(battery?.info.map(\.title) == [L10n.Settings.DeviceInfo.battery, L10n.Settings.Battery.voltage])
    #expect(battery?.info.last?.detail == "4.01 V")

    // The Radio card's screen, in pairs for its two columns: Transport | Link, Battery | Model,
    // Frequency | Preset, TX power | PIN.
    let inputs = readyInputs()
    let radio = card(.radio, in: inputs)
    #expect(radio?.title == "Heltec")
    #expect(radio?.info.map(\.title) == [
      L10n.Settings.Connection.transport, L10n.Settings.Dashboard.link,
      L10n.Settings.DeviceInfo.battery, L10n.Settings.DeviceInfo.model,
      L10n.Settings.Radio.Tile.frequency, L10n.Settings.Radio.preset,
      L10n.Settings.Dashboard.txPower, L10n.Localizable.CarPlay.Network.pin,
    ])
    #expect(radio?.info.map(\.detail) == [
      HomeStatusLines.transportName(isWiFi: false), L10n.Settings.BleStatus.Status.ready,
      NodeRouteFormat.joined([BatteryLevel.formattedPercent(87), "4.01 V"]), "Heltec V3 · v1.9.1",
      "910.525 MHz", "USA/Canada",
      "22 dBm", "Default PIN",
    ])

    let cards = dashboard(inputs).cards
    #expect(cards.allSatisfy { $0.opensTab != nil || !$0.info.isEmpty })
  }

  @Test
  func `Siri off says so on the Chats card and in Comm instead of rows that can't work`() {
    var inputs = readyInputs()
    inputs.isSiriAvailable = false
    inputs.conversations = [conversation(1, unread: 2)]
    let snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    #expect(snapshot.chats.rows.isEmpty)
    #expect(snapshot.chats.empty.title == L10n.Localizable.CarPlay.Chats.siriOff)
    #expect(snapshot.chats.empty.subtitle == nil)
    #expect(snapshot.dashboard.cards.first { $0.kind == .chats }?.detail.contains(L10n.Localizable.CarPlay.Chats.siriOff) == true)
  }

  // MARK: - Comm

  @Test
  func `Comm lists at most twelve rows`() {
    var inputs = readyInputs()
    inputs.conversations = (0 ..< 20).map { conversation($0) }
    #expect(CarPlaySnapshotBuilder.make(from: inputs, now: now).chats.rows.count == 12)
  }

  @Test
  func `No message text reaches any part of the snapshot`() {
    var inputs = readyInputs()
    inputs.conversations = (0 ..< 5).map { conversation($0, unread: 2) }
    inputs.health = .init()
    inputs.spectrum = .init()
    inputs.gps = .init(phoneStatus: "No fix", sharing: "")
    let snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    #expect(!String(describing: snapshot).contains(Self.secret))
  }

  @Test
  func `Muted conversations never show unread`() {
    var inputs = readyInputs()
    inputs.conversations = [conversation(1, unread: 3, muted: true), conversation(3, unread: 2)]
    let rows = CarPlaySnapshotBuilder.make(from: inputs, now: now).chats.rows
    #expect(rows[0].showsUnread == false)
    // Before the messages are read, the kind stands in for the sender, then the age.
    #expect(rows[0].detail == NodeRouteFormat.joined([CarPlaySnapshotBuilder.kindName(.direct), HomeFormat.age(60)]))
    #expect(rows[1].showsUnread)
    // The unread count leads: the row's image already says the kind.
    #expect(rows[1].detail == NodeRouteFormat.joined([L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(2), HomeFormat.age(180)]))
  }

  @Test
  func `With a radio, empty lists keep their usual wording`() {
    let snapshot = CarPlaySnapshotBuilder.make(from: readyInputs(), now: now)
    #expect(snapshot.chats.empty.title == L10n.Localizable.CarPlay.Chats.empty)
    #expect(snapshot.chats.empty.subtitle == L10n.Localizable.CarPlay.Chats.siriHint)
    #expect(snapshot.nodes.emptyTitle == L10n.Contacts.Contacts.List.Empty.Contacts.title)
  }

  // MARK: - Nodes

  @Test
  func `Node lists pass through, each within twelve rows`() {
    let row = { (index: Int) in
      CarPlaySnapshot.NodeRow(publicKey: Data([UInt8(index)]), name: "\(index)", detail: "", symbol: "person", info: [])
    }
    var inputs = readyInputs()
    let category = CarPlaySnapshot.NodeGroupRow(list: .category(.contacts), title: "Contacts", count: 20, symbol: "person", tint: .brand)
    inputs.nodeCategories = [category]
    inputs.nodePages = [.init(list: .category(.contacts), title: "Contacts", note: "Showing 12 of 20", rows: (0 ..< 20).map(row), emptyTitle: "")]
    let nodes = CarPlaySnapshotBuilder.make(from: inputs, now: now).nodes
    #expect(nodes.categories == [category])
    #expect(nodes.pages.map(\.rows.count) == [12])
    #expect(nodes.pages.first?.note == "Showing 12 of 20")
    #expect(nodes.rows.count == 12)
  }

  // MARK: - Refresh

  @Test
  func `Changing tab or an advert's result is an edge event`() {
    let inputs = readyInputs()
    let base = CarPlaySnapshotBuilder.edgeKey(inputs)
    var tabbed = inputs
    tabbed.selectedTab = .spectrum
    #expect(CarPlaySnapshotBuilder.edgeKey(tabbed) != base)
    var advert = inputs
    advert.advertNote = .sending
    #expect(CarPlaySnapshotBuilder.edgeKey(advert) != base)
    var routine = inputs
    routine.unread = 99
    #expect(CarPlaySnapshotBuilder.edgeKey(routine) == base)
  }

  // MARK: - Network Health

  private func healthNode(_ name: String, issues: [NetworkHealthIssue] = [], critical: Bool = false) -> CarPlayInputs.HealthNode {
    .init(id: name, name: name, issues: issues, lastHeard: now.addingTimeInterval(-120), isCritical: critical)
  }

  @Test
  func `Network Health leads with the fleet, then attention, then healthy`() {
    let state = CarPlayInputs.HealthState(
      repeaterCount: 3,
      attention: [healthNode("Ridge", issues: [.notHeard, .restarted], critical: true)],
      healthy: [healthNode("Hilltop"), healthNode("Tower")]
    )
    let health = CarPlaySnapshotBuilder.health(state, listLimit: 12, now: now)
    #expect(health.summary?.title == "3 \(L10n.Tools.Tools.NetworkHealth.Summary.repeaters)")
    #expect(health.summary?.detail == NodeRouteFormat.joined([L10n.Tools.Tools.NetworkHealth.Summary.attention, "1"]))
    #expect(health.sections.map(\.title) == [
      L10n.Tools.Tools.NetworkHealth.Section.attention, L10n.Tools.Tools.NetworkHealth.Section.healthy,
    ])
    let ridge = health.sections[0].rows[0]
    #expect(ridge.detail.hasPrefix(NodeRouteFormat.joined([
      NetworkHealthIssue.notHeard.title, NetworkHealthIssue.restarted.title,
    ])))
    #expect(ridge.symbol == NetworkHealthIssue.notHeard.systemImage)
    #expect(ridge.info == [
      .init(
        title: L10n.Contacts.Contacts.PathDetail.status,
        detail: NodeRouteFormat.joined([NetworkHealthIssue.notHeard.title, NetworkHealthIssue.restarted.title])
      ),
      .init(title: L10n.Contacts.Contacts.Detail.lastHeard, detail: HomeFormat.age(120)),
    ])
    #expect(health.sections[1].rows[0].info.first?.detail == L10n.Tools.Tools.NetworkHealth.Section.healthy)
    #expect(ridge.tint == .critical)
    #expect(health.sections[1].rows.allSatisfy { $0.tint == .success })
  }

  @Test
  func `Network Health fits the list limit with its summary`() {
    let state = CarPlayInputs.HealthState(
      repeaterCount: 30,
      attention: (0 ..< 8).map { healthNode("A\($0)", issues: [.restarted]) },
      healthy: (0 ..< 20).map { healthNode("H\($0)") }
    )
    let health = CarPlaySnapshotBuilder.health(state, listLimit: 12, now: now)
    #expect(health.sections.reduce(0) { $0 + $1.rows.count } == 12)
    #expect(CarPlaySnapshotBuilder.health(.init(), listLimit: 12, now: now).summary == nil)
  }

  // MARK: - Spectrum

  @Test
  func `Spectrum reads the condition, floor, last packet, airtime share, traffic, channel and power`() {
    var state = CarPlayInputs.SpectrumState()
    state.noiseFloor = -100
    state.trend = .rising
    state.lastRSSI = -80
    state.lastSNR = 6.25
    state.airtime = (rx: 0.2, tx: 0.05)
    state.channel = LoRaChannelMath(frequencyHz: 910_525_000, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
    state.presetName = "USA/Canada"
    state.frequency = "910.525 MHz"
    state.modulation = "SF7 · 62.5 kHz · CR 4/5"
    state.airtimePerPacket = "56 ms"
    state.txPower = "22 dBm"
    state.packetsPerMinute = 4.5
    state.packetCount = 27
    let rows = CarPlaySnapshotBuilder.spectrum(state, inputs: readyInputs())
    #expect(rows.map(\.title) == [
      L10n.Localizable.CarPlay.Spectrum.condition,
      L10n.Tools.Tools.Spectrum.Figure.noiseFloor,
      L10n.Tools.Tools.Spectrum.Figure.lastPacket,
      L10n.Tools.Tools.Spectrum.Figure.airtime,
      L10n.Localizable.CarPlay.Cards.traffic,
      L10n.Tools.Tools.Spectrum.Figure.channel,
      L10n.Localizable.CarPlay.Home.modulation,
      L10n.Settings.Dashboard.txPower,
    ])
    #expect(rows[4].detail.contains(L10n.Tools.Tools.RxLog.packetsCount(27)))
    #expect(rows[6].detail.hasSuffix("56 ms"))
    #expect(rows[0].detail == ChannelCondition.heavyInterference.title)
    #expect(rows[1].detail.hasSuffix(NoiseTrend.rising.title))
    #expect(rows.count <= CarPlaySnapshotBuilder.maxInfoItems)
  }

  @Test
  func `Spectrum without readings says it is measuring, and without a radio says why`() {
    let rows = CarPlaySnapshotBuilder.spectrum(.init(), inputs: readyInputs())
    #expect(rows[0].detail == L10n.Tools.Tools.Spectrum.measuring)
    #expect(rows[2].detail == L10n.Tools.Tools.Spectrum.waitingForPacket)

    var inputs = readyInputs()
    inputs.isRadioReady = false
    inputs.connectionState = .syncing
    let blocked = CarPlaySnapshotBuilder.spectrum(.init(), inputs: inputs)
    #expect(blocked == [.init(title: L10n.Localizable.Tabs.spectrum, detail: L10n.Settings.BleStatus.Status.syncing)])
  }

  // MARK: - GPS

  @Test
  func `GPS reads radio, source, phone, readings with speed, and sharing, without course`() {
    var state = CarPlayInputs.GPSState(phoneStatus: "Fix", phoneAccuracy: "Good", sharing: "Receiver On")
    state.radioStatus = .fix
    state.radioPosition = "41.8823, -87.6232"
    state.source = "Live GPS"
    state.readings = [
      GNSSReading(id: "radio.altitude", title: "Radio altitude", systemImage: "", value: "180 m"),
      GNSSReading(id: "phone.speed", title: "Speed", systemImage: "", value: "50 km/h"),
      GNSSReading(id: "phone.course", title: "Course", systemImage: "", value: "90°"),
    ]
    let rows = CarPlaySnapshotBuilder.gps(state)
    #expect(rows.map(\.title) == [
      L10n.Map.Map.Gps.Dash.radio,
      L10n.Localizable.CarPlay.Gps.source,
      L10n.Map.Map.Gps.Dash.phone,
      "Radio altitude",
      "Speed",
      L10n.Localizable.CarPlay.Gps.sharing,
    ])
    #expect(rows[0].detail == NodeRouteFormat.joined([GNSSStatus.fix.text, "41.8823, -87.6232"]))
    #expect(rows[2].detail == "Fix · Good")
  }

  @Test
  func `GPS without a radio still shows the phone`() {
    let rows = CarPlaySnapshotBuilder.gps(.init(phoneStatus: "No fix", sharing: "No radio"))
    #expect(rows.map(\.title) == [L10n.Map.Map.Gps.Dash.radio, L10n.Map.Map.Gps.Dash.phone])
    #expect(rows[0].detail == GNSSStatus.noRadio.text)
  }
}
