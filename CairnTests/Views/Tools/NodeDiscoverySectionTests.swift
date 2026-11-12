@testable import Cairn
import Foundation
import Testing

@Suite("Scan & Traffic sections")
struct NodeDiscoverySectionTests {
  // MARK: - Camera

  @Test
  func `packets frame the routes, whatever the neighbours`() {
    for hasSelection in [false, true] {
      for hasNeighbours in [false, true] {
        #expect(NodeDiscoverySectionCamera.target(
          for: .packets, hasSelection: hasSelection, hasNeighbours: hasNeighbours
        ) == .fitRoutes)
      }
    }
  }

  @Test
  func `nodes center a picked neighbour first`() {
    #expect(NodeDiscoverySectionCamera.target(for: .nodes, hasSelection: true, hasNeighbours: true) == .centerOnSelection)
  }

  @Test
  func `nodes frame the neighbours with none picked`() {
    #expect(NodeDiscoverySectionCamera.target(for: .nodes, hasSelection: false, hasNeighbours: true) == .fitNeighbours)
  }

  @Test
  func `nodes with no neighbour placed open on the phone or radio, as Scan opens`() {
    #expect(NodeDiscoverySectionCamera.target(for: .nodes, hasSelection: false, hasNeighbours: false) == .opening)
  }

  // MARK: - Filter badges

  @Test
  func `the nodes' badge counts sensors and a list pick while it's offered`() {
    #expect(NodeDiscoveryFilterBadge.nodes(kind: .repeaters, listFilter: .all, chipsVisible: true) == 0)
    #expect(NodeDiscoveryFilterBadge.nodes(kind: .sensors, listFilter: .all, chipsVisible: true) == 1)
    #expect(NodeDiscoveryFilterBadge.nodes(kind: .sensors, listFilter: .new, chipsVisible: true) == 2)
    // With the choice gone, the pick no longer narrows the list.
    #expect(NodeDiscoveryFilterBadge.nodes(kind: .repeaters, listFilter: .contacts, chipsVisible: false) == 0)
  }

  @Test
  func `the packets' badge counts the route and decrypt filters and grouping`() {
    #expect(NodeDiscoveryFilterBadge.packets(route: .all, decrypt: .all, groupsDuplicates: false) == 0)
    #expect(NodeDiscoveryFilterBadge.packets(route: .floodOnly, decrypt: .all, groupsDuplicates: false) == 1)
    #expect(NodeDiscoveryFilterBadge.packets(route: .directOnly, decrypt: .failed, groupsDuplicates: true) == 3)
  }

  // MARK: - Sheet drag

  private let height: CGFloat = 800
  private let lowered: CGFloat = 200

  private func target(from state: NodeDiscoverySheetState, _ predicted: CGFloat) -> NodeDiscoverySheetState {
    NodeDiscoverySheetSnap.target(from: state, predictedTranslation: predicted, height: height, splitFraction: 0.4, loweredHeight: lowered)
  }

  @Test
  func `the sheet rests at the list's top, the split, and its header`() {
    #expect(NodeDiscoverySheetSnap.top(of: .list, height: height, splitFraction: 0.4, loweredHeight: lowered) == 0)
    #expect(NodeDiscoverySheetSnap.top(of: .split, height: height, splitFraction: 0.4, loweredHeight: lowered) == 320)
    #expect(NodeDiscoverySheetSnap.top(of: .lowered, height: height, splitFraction: 0.4, loweredHeight: lowered) == 600)
  }

  @Test
  func `a short drag settles back where it started`() {
    #expect(target(from: .split, 40) == .split)
    #expect(target(from: .split, -40) == .split)
    #expect(target(from: .lowered, -60) == .lowered)
    #expect(target(from: .list, 50) == .list)
  }

  @Test
  func `a drag or a flick settles at the nearest resting place it would reach`() {
    #expect(target(from: .split, 200) == .lowered)
    #expect(target(from: .split, -250) == .list)
    #expect(target(from: .lowered, -200) == .split)
    // A hard flick from the header goes all the way up.
    #expect(target(from: .lowered, -900) == .list)
    #expect(target(from: .list, 1000) == .lowered)
    #expect(target(from: .list, 300) == .split)
  }

  @Test
  func `the sheet follows the finger only between the list's top and its header`() {
    func offset(_ state: NodeDiscoverySheetState, _ translation: CGFloat) -> CGFloat {
      NodeDiscoverySheetSnap.offset(from: state, translation: translation, height: height, splitFraction: 0.4, loweredHeight: lowered)
    }
    #expect(offset(.split, 100) == 100)
    #expect(offset(.split, 500) == 280)
    #expect(offset(.split, -500) == -320)
    #expect(offset(.lowered, 50) == 0)
    #expect(offset(.list, -30) == 0)
  }

  // MARK: - One tool

  @Test
  func `Scan for Nodes and Traffic are one tool, Scan & Traffic`() {
    #expect(ToolSelection.nodeDiscovery.title == L10n.Tools.Tools.scanTraffic)
    #expect(ToolSelection.nodeDiscovery.subtitle == L10n.Tools.Tools.Subtitle.scanTraffic)
    #expect(ToolSelection.nodeDiscovery.needsRadio)
    #expect(!ToolSelection.allCases.map { "\($0)" }.contains("rxLog"))
  }

  @Test
  func `the Tools sheet lists Scan & Traffic once, and no Traffic entry of its own`() {
    let tools = HomeToolEntry.all.compactMap { entry -> ToolSelection? in
      if case let .tool(tool) = entry { return tool }
      return nil
    }
    #expect(tools.filter { $0 == .nodeDiscovery }.count == 1)
    #expect(HomeToolEntry.all.filter { $0.title == L10n.Tools.Tools.Traffic.title }.isEmpty)
    #expect(HomeToolEntry.tool(.nodeDiscovery).title == L10n.Tools.Tools.scanTraffic)
    #expect(HomeToolEntry.tool(.nodeDiscovery).identifier == "home.tools.nodeDiscovery")
  }
}
