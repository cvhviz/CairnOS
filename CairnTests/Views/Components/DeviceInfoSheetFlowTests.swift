@testable import Cairn
import Testing

/// The toolbar mark's Device Info sheet (`DeviceInfoSheetFlow`, run by `BLEStatusIndicatorView`):
/// opening and closing it never touches Settings' path, Settings' presentation or the selected tab
/// (on iPad, the sidebar's section), so it can't leave a typed Settings page behind in any section.
/// Only the firmware card and the toolbar's Connections button hand over to Settings, after the
/// sheet has gone: onto Firmware Update over Device Info, or onto Connections.
@Suite("Device Info sheet flow")
@MainActor
struct DeviceInfoSheetFlowTests {
  @Test
  func `opening and closing the sheet leaves navigation as it was`() {
    let navigation = NavigationCoordinator()
    navigation.showTab(.gps)
    let tab = navigation.selectedTab
    var flow = DeviceInfoSheetFlow()

    flow.open()
    #expect(flow.isPresented)
    flow.isPresented = false // Done or a swipe
    flow.dismissed(navigation: navigation)

    #expect(!flow.isPresented)
    #expect(!navigation.isSettingsPresented)
    #expect(navigation.settingsPath.isEmpty)
    #expect(navigation.selectedTab == tab)
  }

  @Test
  func `over the Settings section the sheet keeps Settings on the page it was on`() {
    let navigation = NavigationCoordinator()
    navigation.presentSettings()
    navigation.settingsPath = [.about]
    var flow = DeviceInfoSheetFlow()

    flow.open()
    flow.isPresented = false
    flow.dismissed(navigation: navigation)

    #expect(navigation.isSettingsPresented)
    #expect(navigation.settingsPath == [.about])
  }

  @Test
  func `the firmware card closes the sheet first and opens Settings only once it has gone`() {
    let navigation = NavigationCoordinator()
    var flow = DeviceInfoSheetFlow()
    flow.open()

    flow.requestFirmwareUpdate()
    #expect(!flow.isPresented)
    #expect(!navigation.isSettingsPresented, "Settings waits for the sheet to go: never two sheets at once")
    #expect(navigation.settingsPath.isEmpty)

    flow.dismissed(navigation: navigation)
    #expect(navigation.isSettingsPresented)
    #expect(navigation.settingsPath == [.deviceInfo, .firmwareUpdate])
  }

  @Test
  func `the hand-off is taken once: the next open and close goes back to leaving Settings alone`() {
    let navigation = NavigationCoordinator()
    var flow = DeviceInfoSheetFlow()
    flow.open()
    flow.requestFirmwareUpdate()
    flow.dismissed(navigation: navigation)
    navigation.dismissSettings()
    navigation.settingsPath = []

    flow.open()
    flow.isPresented = false
    flow.dismissed(navigation: navigation)

    #expect(!navigation.isSettingsPresented)
    #expect(navigation.settingsPath.isEmpty)
  }

  @Test
  func `Connections closes the sheet first and opens Settings on Connections once it has gone`() {
    let navigation = NavigationCoordinator()
    navigation.showTab(.gps)
    let tab = navigation.selectedTab
    var flow = DeviceInfoSheetFlow()
    flow.open()

    flow.requestConnections()
    #expect(!flow.isPresented)
    #expect(flow.handOff == .connections)
    #expect(!navigation.isSettingsPresented, "Settings waits for the sheet to go: never two sheets at once")
    #expect(navigation.settingsPath.isEmpty)

    flow.dismissed(navigation: navigation)
    #expect(flow.handOff == nil)
    #expect(navigation.isSettingsPresented)
    #expect(navigation.settingsPath == [.connections])
    #expect(navigation.selectedTab == tab, "the hand-off opens Settings, never another tab")
  }

  @Test
  func `Connections from the sheet over Settings replaces the page Settings was on`() {
    let navigation = NavigationCoordinator()
    navigation.presentSettings()
    navigation.settingsPath = [.about]
    var flow = DeviceInfoSheetFlow()
    flow.open()

    flow.requestConnections()
    #expect(navigation.settingsPath == [.about], "nothing moves under the sheet")
    flow.dismissed(navigation: navigation)

    #expect(navigation.settingsPath == [.connections])
  }

  @Test
  func `opening the sheet again drops a hand-off it never took`() {
    let navigation = NavigationCoordinator()
    var flow = DeviceInfoSheetFlow()
    flow.requestFirmwareUpdate()
    flow.open()
    flow.isPresented = false
    flow.dismissed(navigation: navigation)

    #expect(!navigation.isSettingsPresented)
    #expect(navigation.settingsPath.isEmpty)
  }
}
