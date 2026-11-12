import SwiftUI

/// The size a window opens at on a Mac, for its scene's `defaultSize`. Only that: limiting an
/// iPad app's window on a Mac (`UIWindowScene.sizeRestrictions`, minimum or maximum) stopped it
/// resizing freely from every edge, so these windows have no limits and the user sizes them.
struct MacWindowSize {
  let preferred: CGSize

  /// The main window: wide enough for a tab's list and page side by side.
  static let main = MacWindowSize(preferred: CGSize(width: 1180, height: 780))

  /// A single conversation in its own window: a chat column.
  static let conversation = MacWindowSize(preferred: CGSize(width: 460, height: 720))

  /// A node's window. It also hosts what the node's page pushes (the admin dashboard, the full
  /// map, which wants the width), and every node window shares the one scene default.
  static let detail = MacWindowSize(preferred: CGSize(width: 720, height: 820))
}
