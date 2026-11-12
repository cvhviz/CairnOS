import SwiftUI

/// The gear in Home's top leading corner that opens Settings. Settings is not a tab (the tab bar
/// carries Dashboard, Nodes, Chats, Map and Spectrum), so this and ⌘, are its entry points:
/// compact width presents it as a sheet from `MainTabView`, and regular width (iPad) covers the
/// tabs with its hub beside its page. Both read `NavigationCoordinator.isSettingsPresented`.
///
/// The item is always present with the same button, so the toolbar keeps a stable identity (the
/// iOS 26 toolbar crashes when an item swaps view types between updates). Plain icon-only button:
/// a glass button style inside a toolbar item draws a second capsule.
///
/// Home's Tools button faces it across the bar (`HomeToolsButton`). The other tab roots carry only
/// their own sliders (`tabSettingsToolbarItem(for:)`), so each has a single settings button.
@MainActor
@ToolbarContentBuilder
func settingsGearToolbarItem() -> some ToolbarContent {
  ToolbarItem(placement: .topBarLeading) {
    SettingsGearButton()
  }
}

/// The gear button itself.
struct SettingsGearButton: View {
  @Environment(\.appState) private var appState

  var body: some View {
    Button {
      appState.navigation.presentSettings()
    } label: {
      Label(L10n.Localizable.Tabs.settings, systemImage: "gearshape")
        .labelStyle(.iconOnly)
    }
    .help(L10n.Localizable.Tabs.settings)
    .accessibilityIdentifier("settings.gear")
  }
}
