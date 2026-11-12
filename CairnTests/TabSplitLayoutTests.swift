@testable import Cairn
import SwiftUI
import Testing

/// One navigation on every device, the bottom tab bar; at regular width the list tabs and Settings
/// put each list beside its page (`TabSplitLayout`).
@Suite("TabSplitLayout")
struct TabSplitLayoutTests {
  @Test
  func `A phone keeps its stacks when landscape makes it regular-width`() {
    // A Plus or Pro Max in landscape: swapping layouts there rebuilt the tab's pages on rotation.
    #expect(!TabSplitLayout.usesSplit(horizontalSizeClass: .regular, verticalSizeClass: .compact, idiom: .phone))
    #expect(!TabSplitLayout.usesSplit(horizontalSizeClass: .compact, verticalSizeClass: .regular, idiom: .phone))
  }

  @Test
  func `An unfolded iPhone Duo splits its lists and folded keeps its stacks`() {
    // The inner display is regular both ways; the outer one is an ordinary compact-width phone.
    #expect(TabSplitLayout.usesSplit(horizontalSizeClass: .regular, verticalSizeClass: .regular, idiom: .phone))
    #expect(!TabSplitLayout.usesSplit(horizontalSizeClass: .compact, verticalSizeClass: .regular, idiom: .phone))
  }

  @Test
  func `An iPad splits its lists at regular width, either way up, and stacks them in Split View`() {
    #expect(TabSplitLayout.usesSplit(horizontalSizeClass: .regular, verticalSizeClass: .regular, idiom: .pad))
    #expect(TabSplitLayout.usesSplit(horizontalSizeClass: .regular, verticalSizeClass: .compact, idiom: .pad))
    // Split View and Slide Over narrow it to compact width.
    #expect(!TabSplitLayout.usesSplit(horizontalSizeClass: .compact, verticalSizeClass: .regular, idiom: .pad))
    #expect(!TabSplitLayout.usesSplit(horizontalSizeClass: nil, verticalSizeClass: .regular, idiom: .pad))
  }

  @Test
  func `Settings' hub column fits its rows on one line, and leaves the page room`() {
    // 11-inch upright: the rows' width, the page the rest.
    #expect(SettingsTabSplit.hubColumnWidth(windowWidth: 834) == 440)
    // Sideways and on a 13-inch: a little over a third, up to 480.
    #expect(SettingsTabSplit.hubColumnWidth(windowWidth: 1210) == 1210 * 0.38)
    #expect(SettingsTabSplit.hubColumnWidth(windowWidth: 1376) == 480)
    // A narrow regular-width window never gives the hub more than 55%.
    #expect(SettingsTabSplit.hubColumnWidth(windowWidth: 700) == 700 * 0.55)
    // Before the window is measured.
    #expect(SettingsTabSplit.hubColumnWidth(windowWidth: 0) == 440)
  }

  @Test
  func `My Radios lists alone beside Settings' hub, however wide its column`() {
    // An iPad on its side gives the Settings page 700 to 900 pt: list and radio beside the hub made
    // three columns.
    #expect(!ConnectionsView.showsDetailPane(width: 896, isBesideList: true))
    #expect(!ConnectionsView.showsDetailPane(width: 732, isBesideList: true))
    // A wide window of its own keeps the radio's page beside the list; a narrow one lists alone.
    #expect(ConnectionsView.showsDetailPane(width: 900, isBesideList: false))
    #expect(!ConnectionsView.showsDetailPane(width: 600, isBesideList: false))
  }

  @Test
  @MainActor
  func `A tab selection closes Settings, wherever it shows`() {
    let navigation = NavigationCoordinator()
    navigation.presentSettings()
    #expect(navigation.isSettingsPresented)

    navigation.selectedTab = AppTab.gps.rawValue
    #expect(!navigation.isSettingsPresented)
    #expect(navigation.selectedTab == AppTab.gps.rawValue)
  }

  @Test
  @MainActor
  func `Every page, the radio's and the app's, opens in Settings`() {
    let navigation = NavigationCoordinator()
    navigation.selectedTab = AppTab.chats.rawValue

    navigation.navigateToSetting(.appearance)
    #expect(navigation.isSettingsPresented)

    navigation.navigateToSetting(.connection)
    #expect(navigation.isSettingsPresented)
    #expect(navigation.settingsPath == [.connection])
    #expect(navigation.homePath.isEmpty)
    // The tab underneath stays as it was.
    #expect(navigation.selectedTab == AppTab.chats.rawValue)
  }
}
