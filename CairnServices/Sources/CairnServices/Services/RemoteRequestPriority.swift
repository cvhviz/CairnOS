import Foundation

/// Who a request to a remote node is for. Each one crosses the mesh in seconds and the radio
/// carries one at a time, so a page's automatic loading (status, sensors, neighbours, settings)
/// would otherwise hold up what the user just asked for, like a clock sync, for a minute or more.
///
/// Requests are `.user` unless the code that makes them runs inside
/// `RemoteRequestPriority.$current.withValue(.background) { ... }`; a task started in there
/// inherits it. A user request goes ahead of any background one waiting for the node, and no
/// background request to that node starts while a user request is waiting or in flight.
public enum RemoteRequestPriority: Sendable {
  case user
  case background

  @TaskLocal public static var current: RemoteRequestPriority = .user
}

extension RemoteNodeService {
  /// How often a background request checks whether the user's requests are done.
  static let userActionPollInterval: Duration = .milliseconds(250)

  /// Counts a user request to the node from now until `endUserAction`.
  func beginUserAction(for prefix: Data) {
    userActionCounts[prefix, default: 0] += 1
  }

  func endUserAction(for prefix: Data) {
    guard let count = userActionCounts[prefix] else { return }
    userActionCounts[prefix] = count > 1 ? count - 1 : nil
  }

  /// A background request to the node waits here while the user has one waiting or in flight,
  /// so it can't take the radio from them. Returns at once for a user request.
  public func yieldToUserActions(publicKey: Data) async {
    guard RemoteRequestPriority.current == .background else { return }
    let prefix = Data(publicKey.prefix(6))
    while userActionCounts[prefix] != nil, !Task.isCancelled {
      try? await Task.sleep(for: Self.userActionPollInterval)
    }
  }
}
