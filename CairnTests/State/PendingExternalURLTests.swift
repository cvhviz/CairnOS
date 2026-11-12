import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("PendingExternalURL Tests")
@MainActor
struct PendingExternalURLTests {
  private func makeAppState() -> AppState {
    AppState()
  }

  @Test
  func `A URL submitted before ready is held, not routed, until markReady`() throws {
    let appState = makeAppState()
    let holder = PendingExternalURL()
    let url = try #require(URL(string: "meshcore://map?lat=37.7749&lon=-122.4194"))

    holder.submit(url, appState: appState)

    // The guard is the whole point of the holder: a cold-launch URL delivered
    // before initialization settles must not route into a not-ready AppState.
    #expect(holder.isReady == false)
    #expect(holder.url != nil)
    #expect(appState.navigation.pendingMapFocus == nil)

    holder.markReady(appState)

    #expect(holder.isReady)
    #expect(holder.url == nil)
    #expect(appState.navigation.pendingMapFocus != nil)
  }

  @Test
  func `markReady routes a held URL exactly once`() throws {
    let appState = makeAppState()
    let holder = PendingExternalURL()
    let url = try #require(URL(string: "meshcore://map?lat=37.7749&lon=-122.4194"))

    holder.submit(url, appState: appState)
    holder.markReady(appState)

    #expect(appState.navigation.pendingMapFocus != nil)
    #expect(holder.url == nil)

    // A second markReady cannot re-route: the held URL was consumed.
    holder.markReady(appState)
    #expect(holder.url == nil)
  }

  @Test
  func `A URL submitted after ready routes immediately`() throws {
    let appState = makeAppState()
    let holder = PendingExternalURL()
    let url = try #require(URL(string: "meshcore://map?lat=37.7749&lon=-122.4194"))
    holder.markReady(appState)

    holder.submit(url, appState: appState)

    #expect(appState.navigation.pendingMapFocus != nil)
    #expect(holder.url == nil)
  }

  @Test
  func `The Live Activity status URL leaves the open screen alone`() throws {
    let appState = makeAppState()
    appState.navigation.selectedTab = AppTab.chats.rawValue
    appState.navigation.presentSettings()
    let holder = PendingExternalURL()
    holder.markReady(appState)

    holder.submit(try #require(URL(string: "cairn://status")), appState: appState)

    #expect(appState.navigation.selectedTab == AppTab.chats.rawValue)
    #expect(appState.navigation.isSettingsPresented)
    #expect(holder.url == nil)
  }

  @Test
  func `A status URL held from launch leaves the open screen alone`() throws {
    let appState = makeAppState()
    appState.navigation.selectedTab = AppTab.chats.rawValue
    let holder = PendingExternalURL()

    holder.submit(try #require(URL(string: "cairn://status")), appState: appState)
    holder.markReady(appState)

    #expect(appState.navigation.selectedTab == AppTab.chats.rawValue)
    #expect(holder.url == nil)
  }
}
