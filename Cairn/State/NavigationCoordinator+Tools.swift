import SwiftUI

extension NavigationCoordinator {
  /// Opens `tool` from elsewhere in the app (the Contacts tab's Heard Nodes page links to the node
  /// scan). The tools live on Home, so this selects the Home tab with the tool as the only page on
  /// its stack. Spectrum is also a tab of its own, so it switches to that tab instead of stacking a
  /// second copy on Home.
  func navigateToTool(_ tool: ToolSelection) {
    if tool == .spectrum {
      showTab(.spectrum)
      return
    }
    homePath = [.tool(tool)]
    showTab(.home)
  }

  /// Opens Scan & Traffic on `section`: the neighbours, or the packets (what the Traffic page was,
  /// before the two became one). The page takes the section from `pendingScanSection` and clears
  /// it, so this also switches the page when it is already open.
  func navigateToScan(section: NodeDiscoverySection) {
    pendingScanSection = section
    navigateToTool(.nodeDiscovery)
  }

  /// Opens Trace Path built on `hops`, first hop beside this radio: a route from a node's page or
  /// a message's path. A 32-byte entry is a whole key (the node at the end of the route). The tool
  /// takes the route from `pendingTraceRoute` and clears it; its auto-return setting adds the way back.
  func navigateToTraceRoute(_ hops: [Data]) {
    pendingTraceRoute = hops
    navigateToTool(.tracePath)
  }
}
