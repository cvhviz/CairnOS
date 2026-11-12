import SwiftUI

/// A page pushed onto Home's stack: one of the tools under Home's cards. The stack's path lives on
/// `NavigationCoordinator.homePath`, so other tabs can open a tool here. The radio's own pages (its
/// cards' destinations) open in Settings (`NavigationCoordinator.navigateToSetting(_:)`).
enum HomeRoute: Hashable {
  case tool(ToolSelection)
}
