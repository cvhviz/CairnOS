import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("SavedRadioListBuilder")
struct SavedRadioListBuilderTests {
  @Test
  func `The connected radio comes first, then the most recently connected`() {
    let old = makeDevice(name: "Old", lastConnected: Date(timeIntervalSince1970: 100))
    let recent = makeDevice(name: "Recent", lastConnected: Date(timeIntervalSince1970: 300))
    let connected = makeDevice(name: "Live", lastConnected: Date(timeIntervalSince1970: 200))

    let rows = SavedRadioListBuilder.rows(
      connectable: [old, connected, recent],
      connectedDevice: connected,
      defaultDeviceID: nil,
      nicknames: [:]
    )

    #expect(rows.map(\.displayName) == ["Live", "Recent", "Old"])
    #expect(rows.map(\.isConnected) == [true, false, false])
  }

  @Test
  func `Equal dates sort by name naturally`() {
    let date = Date(timeIntervalSince1970: 100)
    let ten = makeDevice(name: "Node 10", lastConnected: date)
    let two = makeDevice(name: "Node 2", lastConnected: date)

    let rows = SavedRadioListBuilder.rows(connectable: [ten, two], connectedDevice: nil, defaultDeviceID: nil, nicknames: [:])

    #expect(rows.map(\.displayName) == ["Node 2", "Node 10"])
  }

  @Test
  func `A connected radio the filter dropped is still listed`() {
    let saved = makeDevice(name: "Saved")
    let connected = makeDevice(name: "Simulator")

    let rows = SavedRadioListBuilder.rows(connectable: [saved], connectedDevice: connected, defaultDeviceID: nil, nicknames: [:])

    #expect(rows.count == 2)
    #expect(rows.first?.device.id == connected.id)
  }

  @Test
  func `The connected radio's live record replaces its stored one`() {
    let stored = makeDevice(name: "Before")
    var live = stored
    live.nodeName = "After"

    let rows = SavedRadioListBuilder.rows(connectable: [stored], connectedDevice: live, defaultDeviceID: nil, nicknames: [:])

    #expect(rows.map(\.displayName) == ["After"])
  }

  @Test
  func `A nickname replaces the name and keeps the radio's own beside it`() {
    let device = makeDevice(name: "MeshCore-1234")

    let rows = SavedRadioListBuilder.rows(
      connectable: [device],
      connectedDevice: nil,
      defaultDeviceID: device.id,
      nicknames: [device.id: "Truck"]
    )

    #expect(rows.first?.displayName == "Truck")
    #expect(rows.first?.advertisedName == "MeshCore-1234")
    #expect(rows.first?.isDefault == true)
  }

  @Test
  func `A nickname equal to the radio's name shows it once`() {
    let device = makeDevice(name: "Truck")

    let rows = SavedRadioListBuilder.rows(connectable: [device], connectedDevice: nil, defaultDeviceID: nil, nicknames: [device.id: "Truck"])

    #expect(rows.first?.advertisedName == nil)
  }

  private func makeDevice(
    name: String,
    lastConnected: Date = Date(timeIntervalSince1970: 0),
    key: Data? = nil,
    methods: [ConnectionMethod]? = nil
  ) -> DeviceDTO {
    let id = UUID()
    return DeviceDTO(
      id: id,
      radioID: id,
      publicKey: key ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
      nodeName: name,
      firmwareVersion: 9,
      firmwareVersionString: "v1.13.0",
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
      lastConnected: lastConnected,
      lastContactSync: 0,
      isActive: false,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: methods ?? [.bluetooth(peripheralUUID: id, displayName: nil)]
    )
  }

  // MARK: - One radio, several WiFi addresses

  @Test
  func `A radio keeps every WiFi address as its own way in, each transport named once`() {
    let key = Data(repeating: 0xCD, count: 32)
    let lan = ConnectionMethod.wifi(host: "192.168.1.20", port: 5000, displayName: nil)
    let vpn = ConnectionMethod.wifi(host: "100.64.0.9", port: 5000, displayName: nil)
    let ble = makeDevice(name: "Basecamp", lastConnected: Date(timeIntervalSince1970: 100), key: key)
    let overWiFi = makeDevice(name: "Basecamp", lastConnected: Date(timeIntervalSince1970: 200), key: key, methods: [vpn, lan, vpn])

    let rows = SavedRadioListBuilder.rows(connectable: [ble, overWiFi], connectedDevice: nil, defaultDeviceID: ble.id, nicknames: [:])

    #expect(rows.count == 1)
    #expect(rows.first?.methods.count == 3)
    #expect(rows.first?.methods.filter(\.isWiFi) == [vpn, lan])
    #expect(rows.first?.wifiMethod == vpn)
    #expect(rows.first?.transports == [.bluetooth, .wifi])
  }

  // MARK: - One radio, two transports

  private let wifi = ConnectionMethod.wifi(host: "192.168.1.20", port: 5000, displayName: nil)

  @Test
  func `Records sharing a key are one row with both transports`() {
    let key = Data(repeating: 0xAB, count: 32)
    let ble = makeDevice(name: "Basecamp", lastConnected: Date(timeIntervalSince1970: 100), key: key)
    let overWiFi = makeDevice(name: "Basecamp", lastConnected: Date(timeIntervalSince1970: 200), key: key, methods: [wifi])

    let rows = SavedRadioListBuilder.rows(connectable: [ble, overWiFi], connectedDevice: nil, defaultDeviceID: ble.id, nicknames: [ble.id: "Truck"])

    #expect(rows.count == 1)
    #expect(rows.first?.transports == [.bluetooth, .wifi])
    #expect(rows.first?.device.id == overWiFi.id)
    #expect(rows.first?.records.count == 2)
    #expect(rows.first?.bluetoothID == ble.id)
    #expect(rows.first?.displayName == "Truck")
    #expect(rows.first?.isDefault == true)
  }

  @Test
  func `The connected record leads its radio's row`() {
    let key = Data(repeating: 0xCD, count: 32)
    let older = makeDevice(name: "A", lastConnected: Date(timeIntervalSince1970: 100), key: key)
    let newer = makeDevice(name: "A", lastConnected: Date(timeIntervalSince1970: 200), key: key, methods: [wifi])

    let rows = SavedRadioListBuilder.rows(connectable: [older, newer], connectedDevice: older, defaultDeviceID: nil, nicknames: [:])

    #expect(rows.first?.device.id == older.id)
    #expect(rows.first?.isConnected == true)
  }

  @Test
  func `A tap prefers Bluetooth when heard, else WiFi`() {
    let both = makeDevice(name: "A", methods: [.bluetooth(peripheralUUID: UUID(), displayName: nil), wifi])
    let row = SavedRadioListBuilder.rows(connectable: [both], connectedDevice: nil, defaultDeviceID: nil, nicknames: [:])[0]

    #expect(SavedRadioListBuilder.preferredMethod(row, isBluetoothHeard: true)?.isBluetooth == true)
    #expect(SavedRadioListBuilder.preferredMethod(row, isBluetoothHeard: false)?.isWiFi == true)
  }

  // MARK: - Sections, search, sort, filter

  private func sections(
    _ rows: [SavedRadioRow],
    query: String = "",
    filter: SavedRadioTransportFilter = .all,
    sort: SavedRadioSort = .recent,
    nearby: Set<String> = [],
    signal: [String: Int] = [:]
  ) -> SavedRadioSections {
    SavedRadioListBuilder.sections(
      rows: rows, query: query, filter: filter, sort: sort,
      isNearby: { nearby.contains($0.id) }, signal: { signal[$0.id] }
    )
  }

  @Test
  func `The connected radio is pinned; the rest split into nearby and saved`() {
    let live = makeDevice(name: "Live")
    let heard = makeDevice(name: "Heard")
    let quiet = makeDevice(name: "Quiet")
    let rows = SavedRadioListBuilder.rows(connectable: [live, heard, quiet], connectedDevice: live, defaultDeviceID: nil, nicknames: [:])
    let heardID = rows.first { $0.device.id == heard.id }!.id

    let result = sections(rows, nearby: [heardID])

    #expect(result.connected?.device.id == live.id)
    #expect(result.nearby.map(\.device.id) == [heard.id])
    #expect(result.saved.map(\.device.id) == [quiet.id])
  }

  @Test
  func `Search matches nickname, own name and key prefix`() {
    let key = Data([0xBE, 0xEF] + Array(repeating: 0, count: 30))
    let device = makeDevice(name: "MeshCore-1234", key: key)
    let rows = SavedRadioListBuilder.rows(connectable: [device], connectedDevice: nil, defaultDeviceID: nil, nicknames: [device.id: "Truck"])

    #expect(SavedRadioListBuilder.matches(rows[0], query: "truck"))
    #expect(SavedRadioListBuilder.matches(rows[0], query: "1234"))
    #expect(SavedRadioListBuilder.matches(rows[0], query: "BEEF"))
    #expect(!SavedRadioListBuilder.matches(rows[0], query: "beef00ff"))
    #expect(sections(rows, query: "nothing").isEmpty)
  }

  @Test
  func `Sorts by name, by signal (unheard last), and by recent`() {
    let alpha = makeDevice(name: "Alpha", lastConnected: Date(timeIntervalSince1970: 100))
    let bravo = makeDevice(name: "Bravo", lastConnected: Date(timeIntervalSince1970: 300))
    let charlie = makeDevice(name: "Charlie", lastConnected: Date(timeIntervalSince1970: 200))
    let rows = SavedRadioListBuilder.rows(connectable: [alpha, bravo, charlie], connectedDevice: nil, defaultDeviceID: nil, nicknames: [:])
    let id = { (name: String) in rows.first { $0.displayName == name }!.id }

    #expect(sections(rows, sort: .recent).saved.map(\.displayName) == ["Bravo", "Charlie", "Alpha"])
    #expect(sections(rows, sort: .name).saved.map(\.displayName) == ["Alpha", "Bravo", "Charlie"])
    let bySignal = sections(rows, sort: .signal, signal: [id("Alpha"): -60, id("Charlie"): -90])
    #expect(bySignal.saved.map(\.displayName) == ["Alpha", "Charlie", "Bravo"])
  }

  @Test
  func `The transport filter keeps radios that have that transport`() {
    let ble = makeDevice(name: "BLE")
    let wifiOnly = makeDevice(name: "WiFi", methods: [wifi])
    let rows = SavedRadioListBuilder.rows(connectable: [ble, wifiOnly], connectedDevice: nil, defaultDeviceID: nil, nicknames: [:])

    #expect(sections(rows, filter: .bluetooth).saved.map(\.displayName) == ["BLE"])
    #expect(sections(rows, filter: .wifi).saved.map(\.displayName) == ["WiFi"])
    #expect(sections(rows, filter: .all).saved.count == 2)
  }

  // MARK: - The demo radio

  /// The demo radio has no pairing or connection method, so it is listed only when asked for (the
  /// simulator, Demo Mode), and then it is always in reach, never "Not in range".
  @Test @MainActor
  func `The saved demo radio is listed when offered and is always in reach`() {
    var demo = makeDevice(name: "Basecamp", lastConnected: Date(timeIntervalSince1970: 100), methods: [])
    demo.id = MockDataProvider.simulatorDeviceID
    #expect(demo.isDemoRadio)

    let hidden = DeviceSelectionListBuilder.make(
      saved: [demo], accessories: [], needsSetup: [], hasSystemPairingRegistry: true
    )
    let listed = DeviceSelectionListBuilder.make(
      saved: [demo], accessories: [], needsSetup: [], hasSystemPairingRegistry: true, includesDemoRadio: true
    )
    #expect(hidden.connectable.isEmpty)
    #expect(listed.connectable.map(\.id) == [MockDataProvider.simulatorDeviceID])

    let model = ConnectionsModel()
    let rows = { (devices: [DeviceDTO]) in
      SavedRadioListBuilder.rows(connectable: devices, connectedDevice: nil, defaultDeviceID: nil, nicknames: [:])
    }
    #expect(!model.isOutOfRange(rows([demo])[0]))
    #expect(model.isOutOfRange(rows([makeDevice(name: "Far")])[0]), "A Bluetooth radio not heard stays out of range")
  }
}

@Suite("SavedRadioConnectPlan")
struct SavedRadioConnectPlanTests {
  private let key = Data(repeating: 0x11, count: 32)

  @Test
  func `Another radio, or none connected, just connects`() {
    #expect(SavedRadioConnectPlan.plan(targetKey: key, targetTransport: .wifi, connectedKey: nil, connectedTransport: nil) == .connect)
    #expect(SavedRadioConnectPlan.plan(
      targetKey: key, targetTransport: .wifi, connectedKey: Data(repeating: 0x22, count: 32), connectedTransport: .bluetooth
    ) == .connect)
  }

  @Test
  func `The same radio over the same transport is already connected`() {
    #expect(SavedRadioConnectPlan.plan(targetKey: key, targetTransport: .bluetooth, connectedKey: key, connectedTransport: .bluetooth) == .alreadyConnected)
  }

  @Test
  func `The same radio over the other transport asks to switch`() {
    #expect(SavedRadioConnectPlan.plan(targetKey: key, targetTransport: .wifi, connectedKey: key, connectedTransport: .bluetooth)
      == .switchTransport(from: .bluetooth, to: .wifi))
  }

  @Test
  func `An unknown key connects`() {
    #expect(SavedRadioConnectPlan.plan(targetKey: Data(), targetTransport: .wifi, connectedKey: key, connectedTransport: .bluetooth) == .connect)
  }
}

@Suite("RadioProfileSummary")
struct RadioProfileSummaryTests {
  private let radio = MeshCoreNodeConfig.RadioSettings(
    frequency: 910_525,
    bandwidth: 62500,
    spreadingFactor: 7,
    codingRate: 5,
    txPower: 22
  )

  @Test
  func `Figures read as Radio Settings shows them`() {
    #expect(RadioProfileSummary.frequency(radio) == L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz(910_525)))
    #expect(RadioProfileSummary.modulation(radio) == "\(L10n.Settings.Dashboard.modulation(7, "62.5")) · CR5")
    #expect(RadioProfileSummary.txPower(radio) == L10n.Settings.Radio.TxPower.radioSetting(L10n.Settings.DeviceInfo.txPowerFormat("22")))
  }

  @Test
  func `An unmatched tuple is Custom`() {
    let odd = MeshCoreNodeConfig.RadioSettings(frequency: 433_123, bandwidth: 7800, spreadingFactor: 12, codingRate: 8, txPower: 2)
    #expect(RadioProfileSummary.presetName(odd) == L10n.Settings.BatteryCurve.custom)
  }

  @Test
  func `The card line holds only what the profile has`() {
    let channelsOnly = MeshCoreNodeConfig(channels: [.init(name: "Public", secret: ""), .init(name: "", secret: "")])

    #expect(RadioProfileSummary.line(channelsOnly) == L10n.Settings.Connections.Profiles.channelCount(2))
    #expect(RadioProfileSummary.channelNames(channelsOnly) == ["Public"])
    #expect(RadioProfileSummary.line(MeshCoreNodeConfig()).isEmpty)
  }
}

@Suite("Connections navigation")
@MainActor
struct ConnectionsNavigationTests {
  @Test
  func `Connections opens in Settings over the tab and outlives a disconnect`() {
    #expect(!SettingsDetail.connections.isDeviceSetting)
    let coordinator = NavigationCoordinator()
    coordinator.selectedTab = AppTab.chats.rawValue

    coordinator.navigateToSetting(.connections)
    coordinator.settingsPath.append(.connection)
    coordinator.clearPerDeviceSelection()

    #expect(coordinator.selectedTab == AppTab.chats.rawValue)
    #expect(coordinator.isSettingsPresented)
    #expect(coordinator.settingsPath == [.connections])
  }

  @Test
  func `A nickname is trimmed, and a blank one clears it`() {
    let suiteName = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = DevicePreferenceStore(userDefaults: defaults)
    let id = UUID()

    store.setNickname("  Truck  ", deviceID: id)
    #expect(store.nickname(deviceID: id) == "Truck")

    store.setNickname("   ", deviceID: id)
    #expect(store.nickname(deviceID: id) == nil)
  }
}
