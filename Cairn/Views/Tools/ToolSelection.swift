import SwiftUI

/// The set of diagnostic tools, each a page pushed on Home's stack (`HomeRoute.tool`) from the
/// Tools button's picker (`HomeToolsSheet`) or from another tab (`NavigationCoordinator
/// .navigateToTool(_:)`); `ToolDestinationView` maps each to its view. Scan & Traffic is one
/// tool, `nodeDiscovery`: Scan for Nodes and the Traffic page (once `rxLog`) are its two sections
/// (`NodeDiscoverySection`); `NavigationCoordinator.navigateToScan(section:)` opens it on either.
/// The raw value names the tool in `UserDefaults` (Home's last-used quick row).
enum ToolSelection: String, Hashable, CaseIterable {
  case tracePath
  case lineOfSight
  case spectrum
  case nodeDiscovery
  case networkHealth
  case cli
  case signVerify

  /// The tool is nothing but a "connect a radio" page without one: Scan & Traffic and CLI talk to
  /// the radio, where Trace Path, Line of Sight, Network Health and Sign & Verify (its Verify
  /// side) still work from what's stored.
  var needsRadio: Bool {
    switch self {
    case .nodeDiscovery, .cli: true
    case .tracePath, .lineOfSight, .networkHealth, .spectrum, .signVerify: false
    }
  }

  var title: String {
    switch self {
    case .tracePath: L10n.Tools.Tools.tracePath
    case .lineOfSight: L10n.Tools.Tools.lineOfSight
    case .spectrum: L10n.Tools.Tools.spectrum
    case .nodeDiscovery: L10n.Tools.Tools.scanTraffic
    case .networkHealth: L10n.Tools.Tools.networkHealth
    case .cli: L10n.Tools.Tools.cli
    case .signVerify: L10n.Tools.Tools.signVerify
    }
  }

  var systemImage: String {
    switch self {
    case .tracePath: "point.3.connected.trianglepath.dotted"
    case .lineOfSight: "eye"
    case .spectrum: "chart.xyaxis.line"
    case .nodeDiscovery: "dot.radiowaves.left.and.right"
    case .networkHealth: "stethoscope"
    case .cli: "terminal"
    case .signVerify: "signature"
    }
  }

  /// Short line under the tool's name on its Tools hub card, saying what it is for.
  var subtitle: String {
    switch self {
    case .tracePath: L10n.Tools.Tools.Subtitle.tracePath
    case .lineOfSight: L10n.Tools.Tools.Subtitle.lineOfSight
    case .spectrum: L10n.Tools.Tools.Subtitle.spectrum
    case .nodeDiscovery: L10n.Tools.Tools.Subtitle.scanTraffic
    case .networkHealth: L10n.Tools.Tools.Subtitle.networkHealth
    case .cli: L10n.Tools.Tools.Subtitle.cli
    case .signVerify: L10n.Tools.Tools.Subtitle.signVerify
    }
  }

  /// Fill for the tool's icon tile in the Tools hub.
  var tileColor: Color {
    switch self {
    case .networkHealth: .green
    // Indigo rather than teal: Scan and Send Advert share it as filled buttons, and white reads
    // clearly on it.
    case .nodeDiscovery: .indigo
    case .spectrum: .purple
    case .tracePath: .orange
    case .lineOfSight: .blue
    case .cli: .gray
    case .signVerify: .mint
    }
  }

  /// Group the tool's card sits in on the Tools hub, in hub order.
  enum Category: CaseIterable {
    case network, routing, advanced

    var title: String {
      switch self {
      case .network: L10n.Tools.Tools.Category.network
      case .routing: L10n.Tools.Tools.Category.routing
      case .advanced: L10n.Tools.Tools.Category.advanced
      }
    }

    var tools: [ToolSelection] {
      switch self {
      case .network: [.networkHealth, .nodeDiscovery, .spectrum]
      case .routing: [.tracePath, .lineOfSight]
      case .advanced: [.cli, .signVerify]
      }
    }
  }

  /// Title for a pushed tool page. Line of Sight owns its own inline chrome over the map, so it
  /// renders titleless.
  var pageTitle: String {
    self == .lineOfSight ? "" : title
  }
}
