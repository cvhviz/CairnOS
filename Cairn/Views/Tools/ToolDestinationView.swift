import CairnServices
import SwiftUI

/// Maps a `ToolSelection` to its tool view. Single source of truth for every tool, shared
/// by the compact `ToolsView` (stack) and the iPad `ToolsDetailColumn` (split). Line of Sight differs
/// between the two — the compact stack shows the combined map-with-sheet layout from a fresh view
/// model, while the split shows only the map driven by the shared one — so its view is injected.
struct ToolDestinationView<LineOfSight: View>: View {
  let tool: ToolSelection
  @ViewBuilder let lineOfSight: () -> LineOfSight

  var body: some View {
    Group {
      switch tool {
      case .tracePath: TracePathView()
      case .lineOfSight: lineOfSight().flashingNavigationTitle(tool.pageTitle)
      case .spectrum: SpectrumView().flashingNavigationTitle(tool.pageTitle)
      // Its title carries the live dot, so the page sets it.
      case .nodeDiscovery: NodeDiscoveryView()
      case .networkHealth: NetworkHealthView()
      case .cli: CLIToolView()
      case .signVerify: SignVerifyView()
      }
    }
  }
}
