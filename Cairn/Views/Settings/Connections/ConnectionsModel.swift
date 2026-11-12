import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "Connections")

/// The Radios side of Connections: the saved radios as rows, the scan that marks which are heard,
/// and every action on a radio. One model for the list, the pushed radio page and the iPad/Mac
/// detail pane, so a connect started in one shows its spinner in the others. The connection logic
/// is the device picker's (`DeviceSelectionListBuilder.load`, `AppState.connectToSavedDevice`, the
/// pairing flow behind Add).
@Observable
@MainActor
final class ConnectionsModel {
  private(set) var loaded = DeviceSelectionListBuilder.Loaded(
    list: .init(connectable: [], needsSetup: []),
    connectedElsewhere: []
  )
  /// Built when the saved radios, the connected one or a nickname change, not on every scan
  /// update: with hundreds of radios the grouping is the expensive part.
  private(set) var rows: [SavedRadioRow] = []
  private(set) var hasLoaded = false
  let tracker = RSSIScanTracker()
  /// Off while Add hands Bluetooth to the pairing flow, which runs its own scan.
  var isScanSuspended = false
  /// The radio a Connect is bringing up, for its row's spinner.
  private(set) var connectingRowID: String?

  // Prompts, presented by whichever page shows the radio.
  var renaming: SavedRadioRow?
  var renameText = ""
  var forgetting: SavedRadioRow?
  /// A WiFi address being added to or changed on a saved radio (the address sheet's subject).
  var wifiAddressEdit: WiFiAddressEdit?
  var transportSwitch: TransportSwitchPrompt?
  /// The radio a row's tap asks to connect to (`requestConnect`).
  var confirmingConnect: SavedRadioRow?
  var errorMessage: String?

  private let preferences = DevicePreferenceStore()

  func row(id: String?) -> SavedRadioRow? {
    guard let id else { return nil }
    return rows.first { $0.id == id }
  }

  // MARK: - Loading

  func reload(_ appState: AppState) async {
    loaded = await DeviceSelectionListBuilder.load(from: appState.connectionManager)
    hasLoaded = true
    rebuildRows(appState)
  }

  func rebuildRows(_ appState: AppState) {
    let devices = loaded.list.connectable + [appState.connectedDevice].compactMap(\.self)
    let nicknames = Dictionary(
      devices.compactMap { device in preferences.nickname(deviceID: device.id).map { (device.id, $0) } },
      uniquingKeysWith: { first, _ in first }
    )
    rows = SavedRadioListBuilder.rows(
      connectable: loaded.list.connectable,
      connectedDevice: appState.connectedDevice,
      defaultDeviceID: appState.connectionManager.lastConnectedDeviceID,
      nicknames: nicknames
    )
  }

  // MARK: - Scan readings

  func isHeard(_ row: SavedRadioRow) -> Bool {
    row.bluetoothID.map(tracker.isAdvertising) ?? false
  }

  func signalTier(_ row: SavedRadioRow) -> RSSITuning.SignalTier? {
    row.bluetoothID.flatMap(tracker.signalTier)
  }

  func rssi(_ row: SavedRadioRow) -> Int? {
    row.bluetoothID.flatMap { tracker.devices[$0]?.rssi }
  }

  func isConnectedElsewhere(_ row: SavedRadioRow) -> Bool {
    row.bluetoothID.map(loaded.connectedElsewhere.contains) ?? false
  }

  /// A radio with no way in now: Bluetooth only and not heard. The picker's rule, so a tap never
  /// waits out a connect to a radio that isn't there. The demo radio is always in reach.
  func isOutOfRange(_ row: SavedRadioRow) -> Bool {
    !row.isConnected && !row.device.isDemoRadio && row.wifiMethod == nil && !isHeard(row)
  }

  func status(for row: SavedRadioRow, appState: AppState) -> SavedRadioStatus {
    if row.isConnected { return .connected(appState.connectionState) }
    if connectingRowID == row.id { return .connecting }
    if isConnectedElsewhere(row) { return .connectedElsewhere }
    if isOutOfRange(row) { return .outOfRange(lastConnected: row.device.lastConnected) }
    return .available(lastConnected: row.device.lastConnected)
  }

  /// The way a tap on the row connects.
  func preferredMethod(_ row: SavedRadioRow) -> ConnectionMethod? {
    SavedRadioListBuilder.preferredMethod(row, isBluetoothHeard: isHeard(row))
  }

  /// Whether `method` can be tried now: WiFi always, Bluetooth when heard.
  func canConnect(_ row: SavedRadioRow, via method: ConnectionMethod) -> Bool {
    connectingRowID == nil && (method.isWiFi || isHeard(row))
  }

  // MARK: - Actions

  /// A row's tap: asks before connecting (or switching from the radio connected now), since a tap
  /// on a long list lands easily by accident. The same radio over the other transport has its own
  /// question (`transportSwitch`), so it goes straight there.
  func requestConnect(_ row: SavedRadioRow, appState: AppState) {
    switch appState.connectPlan(for: row.device, via: preferredMethod(row)) {
    case .alreadyConnected:
      return
    case .switchTransport:
      connect(row, appState: appState)
    case .connect:
      confirmingConnect = row
    }
  }

  /// Connects, or switches from the radio connected now: the prompt's Connect, and the explicit
  /// Connect of a row's menu and a radio's page. The same radio over the other transport asks
  /// first; over the same transport it is already connected, so nothing happens.
  func connect(_ row: SavedRadioRow, via method: ConnectionMethod? = nil, appState: AppState) {
    let method = method ?? preferredMethod(row)
    switch appState.connectPlan(for: row.device, via: method) {
    case .alreadyConnected:
      return
    case let .switchTransport(from, to):
      transportSwitch = TransportSwitchPrompt(device: row.device, method: method, radioName: row.displayName, from: from, to: to)
    case .connect:
      start(row.device, rowID: row.id, via: method, appState: appState)
    }
  }

  /// Switch from the prompt: the same radio, over the other transport.
  func confirmSwitch(_ prompt: TransportSwitchPrompt, appState: AppState) {
    start(prompt.device, rowID: rows.first { $0.records.contains(where: { $0.id == prompt.device.id }) }?.id, via: prompt.method, appState: appState)
  }

  private func start(_ device: DeviceDTO, rowID: String?, via method: ConnectionMethod?, appState: AppState) {
    logger.info("[UI] Connections: connect \(device.id.uuidString.prefix(8))")
    connectingRowID = rowID
    Task {
      // Connected from here: on to the Dashboard, the radio's home (which closes Settings), as soon
      // as the link is up, so the sync's progress shows there rather than behind this list (the user
      // asked for that, 2026-11-07); unless the user has moved on from Connections meanwhile. Going
      // home empties Settings' path, so a second call after the connect returns is a no-op.
      @MainActor func goHome() {
        let navigation = appState.navigation
        guard appState.connectedDevice?.publicKey == device.publicKey,
              navigation.isSettingsPresented, navigation.settingsPath.last == .connections else { return }
        navigation.settingsPath = []
        navigation.homePath = []
        navigation.selectedTab = AppTab.home.rawValue
      }
      let watcher = Task {
        while !Task.isCancelled {
          if appState.connectedDevice?.publicKey == device.publicKey, appState.connectionState.isConnected {
            goHome()
            return
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
      await appState.connectToSavedDevice(device, via: method)
      watcher.cancel()
      connectingRowID = nil
      goHome()
      await reload(appState)
    }
  }

  // MARK: - WiFi addresses

  /// Add Address… on a radio's page: a new WiFi address for the radio, kept with any it has.
  func addWiFiAddress(_ row: SavedRadioRow) {
    wifiAddressEdit = WiFiAddressEdit(device: record(row, holding: nil), method: nil)
  }

  /// Edit Address… on one of a radio's WiFi cards.
  func editWiFiAddress(_ row: SavedRadioRow, _ method: ConnectionMethod) {
    wifiAddressEdit = WiFiAddressEdit(device: record(row, holding: method), method: method)
  }

  /// Remove Address on one of a radio's WiFi cards: the record keeps its other ways in.
  func removeWiFiAddress(_ row: SavedRadioRow, _ method: ConnectionMethod, appState: AppState) {
    let device = record(row, holding: method)
    Task {
      do {
        try await appState.connectionManager.updateSavedWiFiAddresses(deviceID: device.id, removing: method)
      } catch {
        errorMessage = error.localizedDescription
      }
      await reload(appState)
    }
  }

  /// The record that holds `method`; for a new address the record that has WiFi, else the shown one.
  private func record(_ row: SavedRadioRow, holding method: ConnectionMethod?) -> DeviceDTO {
    if let method, let record = row.records.first(where: { $0.connectionMethods.contains(method) }) { return record }
    return row.records.first { $0.connectionMethods.contains(where: \.isWiFi) } ?? row.device
  }

  func disconnect(_ appState: AppState) {
    Task {
      await appState.disconnect(reason: .userInitiated)
    }
  }

  func beginRename(_ row: SavedRadioRow) {
    renameText = row.records.lazy.compactMap { self.preferences.nickname(deviceID: $0.id) }.first ?? ""
    renaming = row
  }

  /// Saves the nickname on every record of the radio, so it holds whichever transport is shown.
  func commitRename(_ appState: AppState) {
    guard let row = renaming else { return }
    for record in row.records {
      preferences.setNickname(renameText, deviceID: record.id)
    }
    rebuildRows(appState)
  }

  /// The picker's Delete for each record of the radio: removes the system pairing (iOS confirms
  /// it) and demotes the record, so the radio's conversations and nodes stay for when it is paired
  /// again. A Bluetooth pairing kept only as a connection method (the radio last saved over WiFi)
  /// goes once its record no longer names it.
  func forget(_ row: SavedRadioRow, appState: AppState) {
    Task {
      do {
        for record in row.records {
          try await appState.connectionManager.deleteDevice(id: record.id)
          preferences.setNickname(nil, deviceID: record.id)
        }
        if let bluetoothID = row.bluetoothID, !row.records.contains(where: { $0.id == bluetoothID }) {
          try await appState.connectionManager.removeSystemAccessoriesMissingDeviceRecord([bluetoothID])
        }
      } catch DevicePairingError.cancelled {
      } catch {
        errorMessage = error.userFacingMessage
      }
      await reload(appState)
    }
  }

  /// The picker's Scan: hands Bluetooth to the pairing flow, which presents its own picker.
  func addBluetoothRadio(_ appState: AppState) {
    isScanSuspended = true
    appState.connectionManager.isPairingFlowActive = true
    Task {
      await appState.connectionManager.stopBLEScanning()
      appState.startDeviceScan()
    }
  }

  /// A radio iOS is still paired with: the same Set Up prompt the picker shows.
  func setUp(_ accessory: SystemPairedAccessory, appState: AppState) {
    guard appState.connectionUI.pendingSystemPairingSetup == nil else { return }
    appState.connectionManager.isPairingFlowActive = true
    appState.connectionUI.pendingSystemPairingSetup = SystemPairingSetupPrompt(accessories: [accessory])
  }
}

/// A radio's state as its row and page show it.
enum SavedRadioStatus: Equatable {
  case connected(DeviceConnectionState)
  case connecting
  case connectedElsewhere
  case outOfRange(lastConnected: Date)
  case available(lastConnected: Date)

  var isDimmed: Bool {
    switch self {
    case .connectedElsewhere, .outOfRange: true
    case .connected, .connecting, .available: false
    }
  }
}

/// A WiFi address being added to or changed on a saved radio: the record it belongs to, and the
/// address being changed (nil adds one). `WiFiEditSheet` saves it; the live link's own edit is the
/// sheet without one of these.
struct WiFiAddressEdit: Identifiable, Equatable {
  let device: DeviceDTO
  let method: ConnectionMethod?

  var id: String { "\(device.id.uuidString):\(method?.id ?? "new")" }
}
