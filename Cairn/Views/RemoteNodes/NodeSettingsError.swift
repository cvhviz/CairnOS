import Foundation

/// Shared error type for the repeater and room settings screens.
enum NodeSettingsError: LocalizedError {
  case noService
  /// The node answered a command with an error, in its own words.
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .noService: L10n.RemoteNodes.RemoteNodes.Settings.noService
    case let .commandFailed(message): message
    }
  }
}
