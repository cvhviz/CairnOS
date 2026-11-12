import SwiftUI

/// A tab's settings shortcut: a sliders button in the top trailing corner opening the tab's page of
/// Settings (`AppTab.settingsPage`: Chats → Chats, Nodes → Nodes & Auto-Add, Map → Maps & GPS,
/// Spectrum → Spectrum). It opens the same page the Settings hub lists, through
/// `NavigationCoordinator.navigateToSetting(_:)`, so each setting has one home. On iPhone Settings is
/// a sheet over the tab, so Done comes straight back; on iPad it covers the tabs, hub beside page.
/// Plain icon-only button: a glass button style inside a toolbar item draws a second capsule.
private struct TabSettingsToolbarItem: ViewModifier {
  @Environment(\.appState) private var appState
  let tab: AppTab

  func body(content: Content) -> some View {
    content
      .toolbar {
        if let page = tab.settingsPage {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              appState.navigation.navigateToSetting(page)
            } label: {
              Label(page.title, systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
            }
            .help(page.title)
            .accessibilityIdentifier(tab.settingsButtonIdentifier)
          }
        }
      }
  }
}

extension View {
  /// Adds `tab`'s settings shortcut to this tab root's toolbar; see `TabSettingsToolbarItem`.
  func tabSettingsToolbarItem(for tab: AppTab) -> some View {
    modifier(TabSettingsToolbarItem(tab: tab))
  }
}
