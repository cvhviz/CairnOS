import Foundation

/// A node's page opened in its own window on a Mac, where the phone and iPad show it as a sheet.
/// One window per node: opening the same node again brings its window forward. What opens from
/// inside the page (status, admin, telemetry, the full map) pushes onto the window's stack.
/// Codable so the scene can restore it; the window reloads the node by id rather than holding a
/// stale copy, and says so when the node is gone.
enum MacDetailRoute: Codable, Hashable {
  /// A saved node's page. `canHideFromMap` keeps the Map tab's Hide from Map action.
  case contact(id: UUID, canHideFromMap: Bool)
  /// A heard node that isn't saved, with Add to Nodes.
  case discoveredNode(id: UUID, radioID: UUID, canHideFromMap: Bool)
}
