import SwiftUI

/// Tab indices for the main `TabView`, in tab-bar order: Home, then Nodes (`contacts`, the mesh
/// around you), Chats (the conversations), Map, and Spectrum, a diagnostic tool, last.
/// Settings sits behind the gear on Home. The raw value is the integer
/// each `Tab(value:)` uses for selection, so `ContentView` and `NavigationCoordinator` agree on which
/// index selects a given tab. Backed by `Int` because `NavigationCoordinator.selectedTab` remains
/// `Int` (see the deferred Int-to-AppTab migration). The selection is held in memory only, never
/// persisted, so renumbering needs no migration: every launch starts on Home.
enum AppTab: Int, CaseIterable {
  case home
  case contacts
  case chats
  case gps
  case spectrum

  /// Localized tab-bar, sidebar and Go-menu title.
  var title: String {
    switch self {
    case .home: L10n.Localizable.Tabs.home
    case .chats: L10n.Localizable.Tabs.chats
    case .contacts: L10n.Localizable.Tabs.nodes
    case .spectrum: L10n.Localizable.Tabs.spectrum
    case .gps: L10n.Localizable.Tabs.map
    }
  }

  /// The tab's own accent: its buttons, links and controls, and its tab-bar icon while it's open.
  /// The same colours the Home tiles and CarPlay give these areas, so each reads as one place.
  var accentColor: Color {
    switch self {
    case .home: Theme.default.accentColor
    // The Cairn mark's teal: the stones of the mesh.
    case .contacts: .teal
    case .chats: .blue
    case .spectrum: .orange
    case .gps: .green
    }
  }

  /// The symbol for the tab bar and CarPlay. An SF Symbol name, except Home's
  /// walkie-talkie, a MeshCore radio: SF Symbols has none, so it is the app's own symbol in the asset catalog
  /// (`isCustomSymbol`). Draw it through `image`, which loads either kind.
  var symbolName: String {
    switch self {
    case .home: "cairn.walkietalkie.fill"
    case .chats: "message.fill"
    case .contacts: "point.3.filled.connected.trianglepath.dotted"
    case .spectrum: "chart.xyaxis.line"
    case .gps: "map.fill"
    }
  }

  /// Whether `symbolName` names an asset-catalog symbol rather than an SF Symbol.
  var isCustomSymbol: Bool {
    self == .home
  }

  var image: Image {
    isCustomSymbol ? Image(symbolName) : Image(systemName: symbolName)
  }

  /// The Settings page the tab's sliders button opens (`tabSettingsToolbarItem(for:)`); Home has
  /// the Settings gear instead.
  var settingsPage: SettingsDetail? {
    switch self {
    case .home: nil
    case .chats: .chats
    case .contacts: .nodes
    case .spectrum: .spectrum
    case .gps: .gps
    }
  }

  /// Accessibility identifier of the tab's settings button. GPS keeps the identifier its
  /// Location Settings button had before every tab got one.
  var settingsButtonIdentifier: String {
    switch self {
    case .home: "home.tabSettings"
    case .chats: "comm.tabSettings"
    case .contacts: "nodes.tabSettings"
    case .spectrum: "spectrum.tabSettings"
    case .gps: "gps.locationSettings"
    }
  }
}

extension AppTab {
  /// The tab's accent with the connected radio taken into account: the Dashboard is the radio's own
  /// page, so it takes the radio's avatar colour (the picked swatch, else the radio colour), as
  /// its avatar on the page shows. Without a radio, and for the other tabs, the fixed
  /// accent. Night mode wins as everywhere.
  @MainActor
  func accentColor(
    nightMode: Bool,
    appState: AppState,
    theme: Theme,
    colorScheme: ColorScheme,
    contrast: ColorSchemeContrast
  ) -> Color {
    guard self == .home, !nightMode, let device = appState.connectedDevice else {
      return accentColor(nightMode: nightMode)
    }
    return theme.avatarColor(
      appState.radioAvatars.color(for: device.radioID),
      category: .radio,
      colorScheme: colorScheme,
      contrast: contrast
    )
  }
}
