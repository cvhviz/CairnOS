import SwiftUI

/// Every page of Settings. Settings is the one home for every setting: the hub behind the gear
/// (`SettingsHubView`) lists the radio's pages, then the app's, then About, and each opens here,
/// inside Settings' own stack (`NavigationCoordinator.settingsPath`). Everything else that leads to a
/// setting (a Home card, a tab's sliders button, the radio button, a link on another page) opens the
/// same page through `NavigationCoordinator.navigateToSetting(_:)`, so no setting has a second copy.
/// `SettingsDetailView` renders each page.
enum SettingsDetail: Hashable, CaseIterable {
  // This radio
  case radio
  case location
  case battery
  case nodes
  case connection
  case deviceInfo
  /// Firmware Update, pushed from Device Info's firmware card on Cairn touch firmware.
  case firmwareUpdate
  /// The radio's clock and its time zone, pushed from Device Info's Clock row.
  case clock
  /// Connections: every saved radio and the radio config profiles, from the hub's radio header.
  /// Not one of the radio's own pages: it is where a radio is chosen, so it stays open without one.
  case connections

  // The app
  case notifications
  case chats
  /// Maps & GPS: the position source, the phone's location permission, map look and offline maps.
  case gps
  case spectrum
  case appearance
  case carPlaySiri
  /// Privacy & Blocking: blocked contacts, channel senders and keywords, and Sign & Verify.
  case privacy
  case backup

  // About
  case about
  /// Diagnostics (debug logs) and, once unlocked, Demo Mode.
  case advanced

  /// The radio's pages: they only make sense while a radio is connected, so the hub dims them
  /// without one and they pop off Settings' stack when it goes away (`popsWithoutRadio`). Nodes is
  /// not among them: its list layout, sort and auto-remove are the app's own and work offline (its
  /// radio parts dim).
  var isDeviceSetting: Bool {
    switch self {
    case .radio, .location, .battery, .connection, .deviceInfo, .firmwareUpdate, .clock:
      true
    case .nodes, .connections, .notifications, .chats, .gps, .spectrum, .appearance, .carPlaySiri,
         .privacy, .backup, .about, .advanced:
      false
    }
  }

  /// Whether the page pops off Settings' stack when the radio goes away or changes: every radio
  /// page but Device Info, which stays open on its own "No Device Connected" state with its way to
  /// Connections, so Back from a disconnect made on Connections over it returns to it. (A connect
  /// or switch made there goes on to the Dashboard instead, as from any Connections.)
  var popsWithoutRadio: Bool {
    isDeviceSetting && self != .deviceInfo
  }

  /// The page's name: the hub row's title and the pushed page's navigation title.
  var title: String {
    switch self {
    case .radio: L10n.Settings.Radio.header
    case .location: L10n.Settings.LocationSharing.title
    case .battery: L10n.Settings.DeviceInfo.battery
    case .nodes: L10n.Settings.Hub.nodes
    case .connection: L10n.Settings.Hub.connection
    case .deviceInfo: L10n.Settings.Hub.deviceInfo
    case .firmwareUpdate: L10n.Settings.FirmwareUpdate.title
    case .clock: L10n.Settings.Clock.header
    case .connections: L10n.Settings.Connections.title
    case .notifications: L10n.Settings.Notifications.header
    case .chats: L10n.Settings.ChatSettings.title
    case .gps: L10n.Settings.Hub.mapsGps
    case .spectrum: L10n.Settings.Hub.spectrum
    case .appearance: L10n.Settings.Appearance.title
    case .carPlaySiri: L10n.Settings.CarPlaySiri.header
    case .privacy: L10n.Settings.Hub.privacy
    case .backup: L10n.Settings.BackupData.header
    case .about: L10n.Settings.Hub.about
    case .advanced: L10n.Settings.Hub.advanced
    }
  }

  var systemImage: String {
    switch self {
    case .radio: "antenna.radiowaves.left.and.right"
    case .location: "location.fill"
    case .battery: "battery.75percent"
    case .nodes: "person.2.fill"
    case .connection: "lock.fill"
    case .deviceInfo: "info.circle.fill"
    case .firmwareUpdate: "arrow.down.circle.fill"
    case .clock: "clock.fill"
    case .connections: "dot.radiowaves.left.and.right"
    case .notifications: "bell.badge.fill"
    case .chats: "bubble.left.and.bubble.right.fill"
    case .gps: "map.fill"
    case .spectrum: "waveform"
    case .appearance: "paintbrush.fill"
    case .carPlaySiri: "car.fill"
    case .privacy: "hand.raised.fill"
    case .backup: "externaldrive.fill"
    case .about: "questionmark.circle.fill"
    case .advanced: "wrench.and.screwdriver.fill"
    }
  }

  /// The row's icon tile colour, as the iPhone's own Settings colours its rows.
  var color: Color {
    switch self {
    case .radio: .orange
    case .location: .green
    case .battery: .green
    case .nodes: .blue
    case .connection: .gray
    case .deviceInfo: .gray
    case .firmwareUpdate: .blue
    case .clock: .teal
    case .connections: .green
    case .notifications: .red
    case .chats: .blue
    case .gps: .green
    case .spectrum: .purple
    case .appearance: .indigo
    case .carPlaySiri: .orange
    case .privacy: .blue
    case .backup: .teal
    case .about: .gray
    case .advanced: .gray
    }
  }

  /// The hub's sections, in order. Firmware Update and Connections are not hub rows: Firmware
  /// Update opens from Device Info, Connections from the hub's radio header.
  static let thisRadio: [SettingsDetail] = [.radio, .location, .battery, .nodes, .connection, .deviceInfo]
  static let app: [SettingsDetail] = [
    .notifications, .chats, .gps, .spectrum, .appearance, .carPlaySiri, .privacy, .backup,
  ]
  static let aboutSection: [SettingsDetail] = [.about, .advanced]

  /// The path that opens this page in Settings: Firmware Update sits over Device Info, so Back from
  /// it goes there; every other page sits directly on the hub.
  var settingsPath: [SettingsDetail] {
    switch self {
    case .firmwareUpdate: [.deviceInfo, .firmwareUpdate]
    case .clock: [.deviceInfo, .clock]
    default: [self]
    }
  }
}

extension EnvironmentValues {
  /// True on the pages inside Settings' stack. Their `CardForm` sections draw as grouped rows
  /// (`CardFormSection`), the iPhone Settings look, while the same components elsewhere in the app
  /// (node admin, contact sheets) keep their separate cards.
  @Entry var isInSettings = false
}
