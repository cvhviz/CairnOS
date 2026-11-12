import CairnServices
import Foundation
import MeshCore

/// One radio on the Connections page. A radio is its public key: the Bluetooth and WiFi records of
/// one radio (two saved rows when they were never merged, or a ghost left behind) show as one row
/// carrying both transports.
struct SavedRadioRow: Identifiable, Equatable {
  /// The record the row shows: the connected one, else the most recently connected.
  let device: DeviceDTO
  /// Every saved record of this radio, the shown one first.
  let records: [DeviceDTO]
  /// The ways in: one Bluetooth, then every WiFi address the radio was saved with, each its own
  /// card and Connect on the radio's page.
  let methods: [ConnectionMethod]
  /// The nickname given on this phone, else the name the radio advertises.
  let displayName: String
  /// Set when a nickname replaces the radio's own name, so the row can still show that name.
  let advertisedName: String?
  let isConnected: Bool
  /// The radio Cairn reconnects to when it opens: the one connected last.
  let isDefault: Bool

  /// Stable whichever record is shown: the key, or the record's ID for a keyless shadow.
  var id: String {
    device.publicKey.isEmpty ? device.id.uuidString : device.publicKey.hexString
  }

  /// Each transport once, whatever the number of addresses.
  var transports: [TransportType] {
    var seen = Set<TransportType>()
    return methods.map(\.transportType).filter { seen.insert($0).inserted }
  }

  /// The peripheral a Bluetooth connect and the scan's signal refer to.
  var bluetoothID: UUID? {
    methods.lazy.compactMap(\.bluetoothPeripheralID).first
      ?? (methods.isEmpty ? device.id : nil)
  }

  var wifiMethod: ConnectionMethod? {
    methods.first(where: \.isWiFi)
  }

  /// The key's first eight hex digits, as node lists show a key.
  var keyPrefix: String {
    String(device.publicKey.hexString.prefix(8)).uppercased()
  }
}

/// How the Radios list orders the radios under the connected one.
enum SavedRadioSort: String, CaseIterable, Identifiable {
  case recent
  case name
  case signal

  var id: Self { self }

  var title: String {
    switch self {
    case .recent: L10n.Settings.Connections.Sort.recent
    case .name: L10n.Settings.Connections.Sort.name
    case .signal: L10n.Settings.Connections.Sort.signal
    }
  }
}

/// Which transports the Radios list shows.
enum SavedRadioTransportFilter: String, CaseIterable, Identifiable {
  case all
  case bluetooth
  case wifi

  var id: Self { self }

  var title: String {
    switch self {
    case .all: L10n.Settings.Connections.Filter.all
    case .bluetooth: TransportType.bluetooth.displayName
    case .wifi: TransportType.wifi.displayName
    }
  }

  func includes(_ row: SavedRadioRow) -> Bool {
    switch self {
    case .all: true
    case .bluetooth: row.transports.contains(.bluetooth)
    case .wifi: row.transports.contains(.wifi)
    }
  }
}

/// The Radios list as shown: the connected radio pinned on top, then the radios heard nearby,
/// then the rest.
struct SavedRadioSections: Equatable {
  var connected: SavedRadioRow?
  var nearby: [SavedRadioRow]
  var saved: [SavedRadioRow]

  var isEmpty: Bool {
    connected == nil && nearby.isEmpty && saved.isEmpty
  }
}

/// Builds the Connections page's radios. Reachability is `DeviceSelectionListBuilder`'s job (the
/// filter the device picker uses); this groups records by key, adds the connected radio,
/// nicknames and the default, and lays the list out for search, sort and filter.
enum SavedRadioListBuilder {
  /// One row per radio, the connected one first, then the most recently connected, then by name.
  /// The connected radio is listed even when the filter dropped it (a simulator radio, a registry
  /// still settling), so the page always shows what is connected.
  static func rows(
    connectable: [DeviceDTO],
    connectedDevice: DeviceDTO?,
    defaultDeviceID: UUID?,
    nicknames: [UUID: String]
  ) -> [SavedRadioRow] {
    var devices = connectable
    if let connectedDevice {
      if let index = devices.firstIndex(where: { $0.id == connectedDevice.id }) {
        // The live copy: name, transport and settings as the radio reports them now.
        devices[index] = connectedDevice
      } else {
        devices.append(connectedDevice)
      }
    }

    // Group by key in first-seen order; a keyless record (a shadow) stands alone.
    var order: [String] = []
    var groups: [String: [DeviceDTO]] = [:]
    for device in devices {
      let key = device.publicKey.isEmpty ? device.id.uuidString : device.publicKey.hexString
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(device)
    }

    let connectedID = connectedDevice?.id
    let rows = order.compactMap { key -> SavedRadioRow? in
      guard let group = groups[key] else { return nil }
      let records = group.sorted { lhs, rhs in
        if lhs.id == connectedID || rhs.id == connectedID { return lhs.id == connectedID }
        return lhs.lastConnected > rhs.lastConnected
      }
      guard let shown = records.first else { return nil }
      let nickname = records.lazy.compactMap { nicknames[$0.id] }.first { !$0.isEmpty }
      return SavedRadioRow(
        device: shown,
        records: records,
        methods: mergedMethods(records),
        displayName: nickname ?? shown.nodeName,
        advertisedName: nickname.flatMap { $0 == shown.nodeName ? nil : shown.nodeName },
        isConnected: records.contains { $0.id == connectedID },
        isDefault: records.contains { $0.id == defaultDeviceID }
      )
    }

    return rows.sorted { lhs, rhs in
      if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
      return byRecent(lhs, rhs)
    }
  }

  /// The first way in per transport across the records, Bluetooth first.
  static func mergedMethods(_ records: [DeviceDTO]) -> [ConnectionMethod] {
    let all = records.flatMap(\.connectionMethods)
    var methods: [ConnectionMethod] = []
    if let bluetooth = all.first(where: \.isBluetooth) { methods.append(bluetooth) }
    var seen = Set<String>()
    for method in all where method.isWiFi && seen.insert(method.id).inserted {
      methods.append(method)
    }
    return methods
  }

  /// Whether `row` matches a search: its nickname, its own name, or the start of its key.
  static func matches(_ row: SavedRadioRow, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    if row.displayName.localizedStandardContains(query) { return true }
    if row.records.contains(where: { $0.nodeName.localizedStandardContains(query) }) { return true }
    let hex = query.lowercased()
    return hex.allSatisfy(\.isHexDigit) && row.device.publicKey.hexString.hasPrefix(hex)
  }

  /// The list as shown. `isNearby` says whether a radio is heard now; `signal` gives its smoothed
  /// RSSI for the Signal sort (nil when not heard).
  static func sections(
    rows: [SavedRadioRow],
    query: String,
    filter: SavedRadioTransportFilter,
    sort: SavedRadioSort,
    isNearby: (SavedRadioRow) -> Bool,
    signal: (SavedRadioRow) -> Int?
  ) -> SavedRadioSections {
    let connected = rows.first(where: \.isConnected)
    let others = rows
      .filter { !$0.isConnected && filter.includes($0) && matches($0, query: query) }
      .sorted { lhs, rhs in
        switch sort {
        case .recent:
          return byRecent(lhs, rhs)
        case .name:
          let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
          return order == .orderedSame ? byRecent(lhs, rhs) : order == .orderedAscending
        case .signal:
          switch (signal(lhs), signal(rhs)) {
          case let (left?, right?) where left != right: return left > right
          case (.some, nil): return true
          case (nil, .some): return false
          default: return byRecent(lhs, rhs)
          }
        }
      }
    return SavedRadioSections(
      connected: connected,
      nearby: others.filter(isNearby),
      saved: others.filter { !isNearby($0) }
    )
  }

  private static func byRecent(_ lhs: SavedRadioRow, _ rhs: SavedRadioRow) -> Bool {
    if lhs.device.lastConnected != rhs.device.lastConnected {
      return lhs.device.lastConnected > rhs.device.lastConnected
    }
    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
  }

  /// The way a tap connects a radio that has more than one: Bluetooth when it is heard now, else
  /// its WiFi address, else Bluetooth (which fails fast and says why).
  static func preferredMethod(_ row: SavedRadioRow, isBluetoothHeard: Bool) -> ConnectionMethod? {
    let bluetooth = row.methods.first(where: \.isBluetooth)
    if isBluetoothHeard, let bluetooth { return bluetooth }
    return row.wifiMethod ?? bluetooth
  }
}
