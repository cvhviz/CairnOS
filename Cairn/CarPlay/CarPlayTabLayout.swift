import Foundation

/// Where CarPlay goes, named after the app's tabs. Dashboard, Nodes and Comm are the car's tabs;
/// GPS and Spectrum are screens their Dashboard rows push, so the tab bar stays short.
enum CarPlayTab: CaseIterable, Hashable {
  case dashboard
  case nodes
  case comm
  case gps
  case spectrum

  /// The app tab this one mirrors; titles and symbols come from it so the two never drift.
  var appTab: AppTab {
    switch self {
    case .dashboard: .home
    case .nodes: .contacts
    case .comm: .chats
    case .spectrum: .spectrum
    case .gps: .gps
    }
  }
}

/// Switches for what CarPlay offers beyond messaging.
enum CarPlayFeatures {
  /// The radio tools: every Dashboard option (Network Health, Send Advert, Scan for Nodes) and
  /// the Spectrum and GPS screens. Kept as one switch in case CarPlay review asks for a
  /// messaging-only screen; the Dashboard's status cards, Nodes and Comm stay either way.
  static let radioTools = true
  /// One short line (`CarPlayCardBuilder.maxTextLength`) of the last message on the Dashboard's
  /// Messages card (iOS 26). Off: CarPlay leaves message content to Siri, and a passenger's text
  /// has no place on the head unit; the card keeps the sender, age and where it came from.
  static let messagePreview = false
}

/// Which tabs the car shows, in the app's order. Pure, so the order is tested.
enum CarPlayTabLayout {
  /// Dashboard, Nodes and Comm, whatever the car allows: Comm is why the app is in the car at
  /// all. Three tabs keep the bar short; GPS and Spectrum open from the Dashboard
  /// (`pushedScreens`).
  static func tabs() -> [CarPlayTab] {
    [.dashboard, .nodes, .comm]
  }

  /// The screens the Dashboard pushes instead of giving them tabs, with the radio tools on.
  static func pushedScreens(radioTools: Bool) -> [CarPlayTab] {
    radioTools ? [.gps, .spectrum] : []
  }

  static func title(_ tab: CarPlayTab) -> String {
    tab.appTab.title
  }

  static func symbol(_ tab: CarPlayTab) -> String {
    tab.appTab.symbolName
  }
}
