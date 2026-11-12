import CairnServices
import SwiftUI

/// Settings for the compact (iPhone) shell, presented as a sheet by the toolbar gear and by every
/// shortcut to a setting (`NavigationCoordinator.navigateToSetting(_:)`). Each screen has one way
/// out: Done on the sheet's first page, Back on any page pushed over it.
/// At regular width (iPad) Settings covers the tabs instead, its hub in one column and its page in
/// the next (`SettingsTabSplit`), never this view.
struct SettingsView: View {
  var body: some View {
    SettingsStack(showsDone: true, showsLinkStatus: false)
  }
}

/// Settings' own stack: the hub (`SettingsHubView`) with its pages pushed on
/// `NavigationCoordinator.settingsPath`, so a shortcut can open it straight onto a page. In the
/// iPhone sheet that page is then the stack's first, with no hub beneath it to go back to; the
/// path still holds it, so the rest of the app reads one path either way. Everything in it draws as
/// the iPhone's Settings does (`isInSettings`: grouped rows).
struct SettingsStack: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  /// Done on the first page, for the iPhone sheet.
  var showsDone: Bool
  var showsLinkStatus: Bool
  /// The column beside the iPad's hub: the path's first page is its root, with nothing to go back to;
  /// a page opened from another page still has Back to that page.
  var isPane = false

  var body: some View {
    let navigation = appState.navigation
    let firstPage = isPane || (showsDone && navigation.opensSettingsOnPage) ? navigation.settingsPath.first : nil
    let path = Binding<[SettingsDetail]>(
      get: { firstPage == nil ? navigation.settingsPath : Array(navigation.settingsPath.dropFirst()) },
      set: { pushed in navigation.settingsPath = (firstPage.map { [$0] } ?? []) + pushed }
    )
    NavigationStack(path: path) {
      Group {
        if let firstPage {
          SettingsDetailView(detail: firstPage)
            .id(firstPage)
        } else if isPane {
          AboutHeroCard()
            .padding(CardStyle.pageInset)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardCanvas(theme)
        } else {
          SettingsHubView(showsLinkStatus: showsLinkStatus)
        }
      }
      .modifier(SettingsDoneButton(isShown: showsDone, asBack: firstPage == .deviceInfo && !isPane))
      .navigationDestination(for: SettingsDetail.self) { detail in
        // Set on each page as well: in the iPad split view's column a pushed page does not
        // inherit what is set on the stack.
        SettingsDetailView(detail: detail)
          .environment(\.isInSettings, true)
      }
    }
    .environment(\.isInSettings, true)
  }
}

/// Settings' Done: on the iPhone sheet's first page (a page pushed over that has Back instead), and
/// on the iPad's hub column. Hidden while an app-started firmware update holds its page.
struct SettingsDoneButton: ViewModifier {
  @Environment(\.appState) private var appState
  let isShown: Bool
  /// Device Info as the sheet's first page: Back on the left, to where it was opened from (its
  /// Disconnect has the right), rather than Done.
  var asBack = false

  func body(content: Content) -> some View {
    content.toolbar {
      if isShown, !appState.navigation.holdsDevicePagesForUpdate {
        if asBack {
          ToolbarItem(placement: .cancellationAction) {
            NodePageBackButton { appState.navigation.dismissSettings() }
              .accessibilityIdentifier("settings.done")
          }
        } else {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) {
              appState.navigation.dismissSettings()
            }
            .accessibilityIdentifier("settings.done")
          }
        }
      }
    }
  }
}

#Preview {
  SettingsView()
    .environment(\.appState, AppState())
}
