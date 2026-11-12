import Foundation
import os
import Security

// MARK: - KeychainService

/// Secure password storage for remote node authentication.
/// Passwords are stored device-only (not synced to iCloud), readable after the first unlock so a
/// locked phone (CarPlay, a reconnect in a pocket) can still log back in to rooms and repeaters.
actor KeychainService {
  static let shared = KeychainService()

  private let service = "cvhvisuals.Cairn.nodepasswords"
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "Keychain")
  private let maxRetries = 3
  private let retryDelay: Duration = .milliseconds(100)

  init() {}

  /// The password saved for `account` under `service`, if any.
  private func copyPassword(service: String, account: String) -> (OSStatus, String?) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return (status, nil) }
    return (status, String(data: data, encoding: .utf8))
  }

  /// Store a password for a remote node.
  /// - Parameters:
  ///   - password: The password to store
  ///   - publicKey: The 32-byte public key of the remote node
  func storePassword(_ password: String, forNodeKey publicKey: Data) async throws {
    let account = publicKey.base64EncodedString()
    guard let passwordData = password.data(using: .utf8) else {
      throw KeychainError.encodingFailed
    }

    // Delete existing entry first
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    // Add new entry
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: passwordData,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]

    var lastStatus: OSStatus = errSecSuccess
    for attempt in 1...maxRetries {
      lastStatus = SecItemAdd(addQuery as CFDictionary, nil)
      if lastStatus == errSecSuccess {
        logger.debug("Password stored for node")
        return
      }
      if attempt < maxRetries {
        try await Task.sleep(for: retryDelay)
      }
    }

    throw KeychainError.storageFailed(lastStatus)
  }

  /// Retrieve a stored password for a remote node.
  /// - Parameter publicKey: The 32-byte public key of the remote node
  /// - Returns: The stored password, or nil if not found
  func retrievePassword(forNodeKey publicKey: Data) async throws -> String? {
    let account = publicKey.base64EncodedString()

    let (status, password) = copyPassword(service: service, account: account)

    if status == errSecItemNotFound {
      return nil
    }

    guard status == errSecSuccess, let password else {
      throw KeychainError.retrievalFailed(status)
    }

    return password
  }

  /// Delete a stored password for a remote node.
  /// - Parameter publicKey: The 32-byte public key of the remote node
  func deletePassword(forNodeKey publicKey: Data) async throws {
    let account = publicKey.base64EncodedString()

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]

    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess, status != errSecItemNotFound {
      throw KeychainError.deletionFailed(status)
    }
  }

  /// Check if a password exists for a remote node.
  /// - Parameter publicKey: The 32-byte public key of the remote node
  /// - Returns: True if a password is stored
  func hasPassword(forNodeKey publicKey: Data) async -> Bool {
    let account = publicKey.base64EncodedString()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: false
    ]

    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }
}

// MARK: - KeychainError

public enum KeychainError: Error, LocalizedError, Sendable {
  case encodingFailed
  case storageFailed(OSStatus)
  case retrievalFailed(OSStatus)
  case deletionFailed(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .encodingFailed:
      "Failed to encode password"
    case let .storageFailed(status):
      "Failed to store password (error \(status))"
    case let .retrievalFailed(status):
      "Failed to retrieve password (error \(status))"
    case let .deletionFailed(status):
      "Failed to delete password (error \(status))"
    }
  }
}
