import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The Nodes tab's state kept on the coordinator so it outlives a layout switch (the compact
/// stack and the iPad columns are different views): the Saved list's segment and search text,
/// the heard node open beside the list, and the ⌘F and Add Node requests.
@Suite("Nodes navigation state")
@MainActor
struct NodesNavigationStateTests {
  private static func makeHeardNode() -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0xAB, count: 32),
      name: "Hilltop",
      typeRawValue: ContactType.repeater.rawValue,
      lastHeard: .now,
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }

  @Test func `segment and search start at all and empty`() {
    let navigation = NavigationCoordinator()
    #expect(navigation.nodesSegment == .all)
    #expect(navigation.nodesSearchText.isEmpty)
  }

  /// Both list hosts read the same values, so whichever is built next sees what the last set.
  @Test func `segment and search text persist on the coordinator`() {
    let navigation = NavigationCoordinator()
    navigation.nodesSegment = .repeaters
    navigation.nodesSearchText = "hill"

    #expect(navigation.nodesSegment == .repeaters)
    #expect(navigation.nodesSearchText == "hill")
  }

  @Test func `a search request shows nodes and bumps the version each time`() {
    let navigation = NavigationCoordinator()
    navigation.selectedTab = AppTab.home.rawValue
    let before = navigation.nodesSearchRequestVersion

    navigation.requestNodesSearch()
    navigation.requestNodesSearch()

    #expect(navigation.selectedTab == AppTab.contacts.rawValue)
    #expect(navigation.nodesSearchRequestVersion == before + 2)
  }

  @Test func `an add node request shows nodes and bumps the version`() {
    let navigation = NavigationCoordinator()
    navigation.selectedTab = AppTab.chats.rawValue
    let before = navigation.addNodeRequestVersion

    navigation.requestAddNode()

    #expect(navigation.selectedTab == AppTab.contacts.rawValue)
    #expect(navigation.addNodeRequestVersion == before + 1)
  }

  /// A heard node picked beside the list belongs to the radio that heard it, so a radio switch
  /// drops it with the saved-node selection.
  @Test func `the heard node selection clears with the radio`() {
    let navigation = NavigationCoordinator()
    navigation.selectedHeardNode = Self.makeHeardNode()

    navigation.clearPerRadioSelection()

    #expect(navigation.selectedHeardNode == nil)
    #expect(navigation.selectedContact == nil)
  }

  /// The Dashboard's "Last:" line opens the node it names: its page when saved, the Heard list
  /// when not, so the heard node carries its key and, when saved, the contact.
  @Test func `the last heard node carries its key and the saved contact`() {
    let radioID = UUID()
    let savedKey = Data(repeating: 0x11, count: 32)
    let saved = ContactDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: savedKey,
      name: "Saved",
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 1_700_000_000,
      latitude: 0,
      longitude: 0,
      lastModified: 1_700_000_000,
      lastHeardTimestamp: 1_700_000_000,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
    let heard = Self.makeHeardNode()

    let latest = HomeDashboardModel.lastHeard(contacts: [saved], heard: [heard])
    #expect(latest?.publicKey == heard.publicKey)
    #expect(latest?.contact == nil)
    #expect(latest?.isSaved == false)

    let savedOnly = HomeDashboardModel.lastHeard(contacts: [saved], heard: [])
    #expect(savedOnly?.publicKey == savedKey)
    #expect(savedOnly?.contact?.id == saved.id)
    #expect(savedOnly?.isSaved == true)
  }
}
