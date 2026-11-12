import Foundation
import MeshCore

public enum RemoteNodeError: Error, LocalizedError, Sendable {
  case notConnected
  case loginFailed(String)
  case sendFailed(String)
  case invalidResponse
  case permissionDenied
  case timeout
  case sessionNotFound
  case passwordNotFound
  case floodRouted // Keep-alive requires direct path
  case pathDiscoveryFailed
  case contactNotFound
  case radioContactsFull // Radio's contact table is full; cannot auto-add a missing node
  case cancelled // Login cancelled due to duplicate attempt or shutdown
  case sessionError(MeshCoreError)

  public var errorDescription: String? {
    switch self {
    case .notConnected:
      "Not connected to mesh device"
    case let .loginFailed(reason):
      "Login failed: \(reason)"
    case let .sendFailed(reason):
      "Failed to send: \(reason)"
    case .invalidResponse:
      "Invalid response from remote node"
    case .permissionDenied:
      "Permission denied"
    case .timeout:
      "Request timed out"
    case .sessionNotFound:
      "Remote node session not found"
    case .passwordNotFound:
      "Password not found in keychain"
    case .floodRouted:
      "Keep-alive requires direct routing path"
    case .pathDiscoveryFailed:
      "Failed to establish direct path"
    case .contactNotFound:
      "Contact not found in database"
    case .radioContactsFull:
      "Radio contact list is full"
    case .cancelled:
      "Login cancelled"
    case let .sessionError(error):
      error.localizedDescription
    }
  }

  /// Whether the radio refused the command as unsupported (``FirmwareDeviceErrorCode/unsupportedCommand``),
  /// e.g. a companion CLI command sent through firmware older than MeshCore 1.18.
  public var isUnsupportedByRadio: Bool {
    if case let .sessionError(.deviceError(code)) = self {
      return code == FirmwareDeviceErrorCode.unsupportedCommand
    }
    return false
  }

  public var isRetryable: Bool {
    switch self {
    case .timeout, .notConnected, .floodRouted:
      true
    default:
      false
    }
  }
}
