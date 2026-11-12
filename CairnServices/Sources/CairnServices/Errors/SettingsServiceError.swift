import Foundation
import MeshCore

public enum SettingsServiceError: Error, LocalizedError, Sendable {
  case notConnected
  case sendFailed
  case invalidResponse
  case sessionError(MeshCoreError)
  case verificationFailed(expected: String, actual: String)
  case deviceGPSVerificationFailed(expectedEnabled: Bool, actualEnabled: Bool)
  /// The radio has the setting but its hardware can't do it (its reply: "Error: unsupported").
  case unsupportedSetting
  /// A preset's frequency, bandwidth, spreading factor and coding rate were applied and read back,
  /// but its path hash size was not: the radio is on the preset's channel with its old hash size.
  case presetPathHashNotApplied(presetName: String)

  /// A transport failure as the settings error it means: the link is down, or a write never left.
  public init(transportError: MeshTransportError) {
    switch transportError {
    case .notConnected: self = .notConnected
    default: self = .sendFailed
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notConnected: return "Device not connected"
    case .sendFailed: return "Failed to send command"
    case .invalidResponse: return "Invalid response from device"
    case let .sessionError(error): return error.localizedDescription
    case let .verificationFailed(expected, actual):
      return "Setting was not saved. Expected '\(expected)' but device reports '\(actual)'."
    case let .deviceGPSVerificationFailed(expectedEnabled, actualEnabled):
      let expected = expectedEnabled ? "On" : "Off"
      let actual = actualEnabled ? "On" : "Off"
      return "Device GPS setting was not saved. Expected '\(expected)' but device reports '\(actual)'."
    case .unsupportedSetting:
      return "This radio's hardware doesn't support that setting."
    case let .presetPathHashNotApplied(presetName):
      return "The radio is on \(presetName)'s frequency settings, but its path hash size couldn't be set."
    }
  }

  /// Whether this error suggests a connection issue that might be resolved by retrying
  public var isRetryable: Bool {
    switch self {
    case .sendFailed, .notConnected:
      return true
    case let .sessionError(error):
      if case .timeout = error { return true }
      return false
    default:
      return false
    }
  }
}
