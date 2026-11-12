import CairnServices
import SwiftUI

/// Whether a tab's lists sit beside their pages: the iPad (and an unfolded iPhone Duo) at regular
/// width, inside the same bottom tab bar the iPhone uses. A phone stays on its stacks unless it is
/// regular in both directions: a Plus or Pro Max turns regular-width (but compact-height) in
/// landscape, and swapping layouts on that rotation rebuilt the tab's pages (an open chat, a half
/// typed form). Split View and Slide Over narrow an iPad to compact width, which takes the stacks.
enum TabSplitLayout {
  nonisolated static func usesSplit(
    horizontalSizeClass: UserInterfaceSizeClass?,
    verticalSizeClass: UserInterfaceSizeClass?,
    idiom: UIUserInterfaceIdiom
  ) -> Bool {
    guard horizontalSizeClass == .regular else { return false }
    return idiom != .phone || verticalSizeClass == .regular
  }
}

extension EnvironmentValues {
  /// A page shown in the column beside a list (Settings' page beside its hub, a chat or node beside
  /// its list). Such a page doesn't put a list of its own beside its detail, however wide its column:
  /// that made three columns. It lists alone and pushes the picked item's page in the same column.
  @Entry var isBesideList = false
}

/// The Chats tab at regular width: the conversations in one column and the open one beside it,
/// both reading one `ChatViewModel`. The conversation is the column's first page, so it has no Back;
/// a page opened from it does. The tab bar stays: it is the app's navigation here.
struct ChatsTabSplit: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var viewModel = ChatViewModel()
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      NavigationStack {
        ChatsContentColumn(viewModel: viewModel)
      }
      .environment(\.isBarTitleInColumn, true)
      // The list stays beside the page: no button to fold it away.
      .toolbar(removing: .sidebarToggle)
      .navigationSplitViewColumnWidth(min: 320, ideal: 360)
      .modifier(SidebarContentColumnBackground(theme: theme))
    } detail: {
      let route = appState.navigation.chatsSelectedRoute
      NavigationStack {
        ChatsSplitDetailContent(viewModel: viewModel, route: route)
      }
      .environment(\.isBesideList, true)
      .id(route?.conversationID)
    }
    .navigationSplitViewStyle(.balanced)
  }
}

/// The Nodes tab at regular width: the Saved and Heard lists in one column and the picked node
/// beside them (`NavigationCoordinator.selectedContact`), its page the column's first.
struct ContactsTabSplit: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      NavigationStack {
        ContactsContentColumn()
      }
      .environment(\.isBarTitleInColumn, true)
      // The list stays beside the page: no button to fold it away.
      .toolbar(removing: .sidebarToggle)
      .navigationSplitViewColumnWidth(min: 320, ideal: 360)
      .modifier(SidebarContentColumnBackground(theme: theme))
    } detail: {
      NavigationStack {
        ContactsDetailColumn()
      }
      .environment(\.isBesideList, true)
      .id(appState.navigation.selectedContact?.id)
    }
    .navigationSplitViewStyle(.balanced)
  }
}

/// Settings at regular width, over the tabs from the Dashboard gear, ⌘, and every shortcut to a
/// setting: its hub in one column with Done, and its page beside it as that column's first (no
/// Back; a page opened from another page has Back to it). While an app-started firmware update
/// holds its page it can't be closed (`holdsDevicePagesForUpdate`).
///
/// Two stacks side by side rather than a split view: the hub needs a column wide enough for its rows
/// on one line (`hubColumnWidth`), and a split view that wide lays its sidebar over a dimmed page in
/// portrait instead of beside it. Each column fills the height and scrolls on its own.
struct SettingsTabSplit: View {
  @Environment(\.appTheme) private var theme
  /// The window's width, which the hub's column follows.
  @State private var windowWidth: CGFloat = 0

  var body: some View {
    HStack(spacing: 0) {
      NavigationStack {
        SettingsHubView(showsLinkStatus: true, opensPagesInPane: true)
          .modifier(SettingsDoneButton(isShown: true))
      }
      .environment(\.isInSettings, true)
      .environment(\.isBarTitleInColumn, true)
      .frame(width: Self.hubColumnWidth(windowWidth: windowWidth))

      Divider()
        .ignoresSafeArea()

      SettingsStack(showsDone: false, showsLinkStatus: false, isPane: true)
        .environment(\.isBesideList, true)
        .frame(maxWidth: .infinity)
    }
    .themedChrome(theme)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
  }

  /// The hub's column: wide enough that every row keeps its title and its value on one line at the
  /// default text size. The longest in English, "Location & Sharing" with "Shared on request", needs
  /// a row about 406 pt wide, so 440 pt with the page's insets. A little over a third of a wide
  /// window, so sideways the page gets the larger share; never past 55% of the window, so the page
  /// keeps room in a narrow regular-width window. Larger text wraps within it.
  nonisolated static func hubColumnWidth(windowWidth: CGFloat) -> CGFloat {
    guard windowWidth > 0 else { return 440 }
    let preferred = min(max(windowWidth * 0.38, 440), 480)
    return min(preferred, windowWidth * 0.55)
  }
}
