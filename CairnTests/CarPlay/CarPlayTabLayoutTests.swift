@testable import Cairn
import Testing

@Suite("CarPlayTabLayout")
struct CarPlayTabLayoutTests {
  @Test
  func `Three tabs in the app's order with the app's titles and symbols`() {
    let tabs = CarPlayTabLayout.tabs()
    #expect(tabs == [.dashboard, .nodes, .comm])
    // The phone's tab-bar order, so the car can't drift from it.
    let appTabs = Array(AppTab.allCases.prefix(3))
    #expect(tabs.map(CarPlayTabLayout.title) == appTabs.map(\.title))
    #expect(tabs.map(CarPlayTabLayout.symbol) == appTabs.map(\.symbolName))
    #expect(CarPlayTabLayout.title(.comm) == L10n.Localizable.Tabs.chats)
    #expect(CarPlayTabLayout.symbol(.comm) == "message.fill")
  }

  @Test
  @MainActor
  func `Every tab symbol loads, the app's own walkie-talkie included`() {
    for tab in AppTab.allCases {
      #expect(CarPlayTemplates.symbol(tab.symbolName) != nil, "\(tab) symbol would render blank")
    }
    #expect(AppTab.home.isCustomSymbol)
  }

  @Test
  func `GPS and Spectrum are pushed screens, only with the radio tools`() {
    #expect(CarPlayTabLayout.pushedScreens(radioTools: true) == [.gps, .spectrum])
    #expect(CarPlayTabLayout.pushedScreens(radioTools: false).isEmpty)
    #expect(CarPlayTabLayout.title(.gps) == AppTab.gps.title)
    #expect(CarPlayTabLayout.title(.spectrum) == AppTab.spectrum.title)
  }
}
