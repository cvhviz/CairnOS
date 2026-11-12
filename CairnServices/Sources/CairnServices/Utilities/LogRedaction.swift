import Foundation

/// Centralized redaction utility for logging sensitive data.
enum LogRedaction {
  /// Formats public key prefix as hex string.
  /// Public keys are NOT redacted since they're public.
  /// - Parameters:
  ///   - key: The public key data
  ///   - prefixLength: Number of bytes to include (default 6)
  /// - Returns: Hex string representation
  static func publicKeyHex(_ key: Data, prefixLength: Int = 6) -> String {
    key.prefix(prefixLength).map { String(format: "%02x", $0) }.joined()
  }

  /// Redacts a node/room name to first 3 chars + "***".
  /// - Parameter name: The node or room name
  /// - Returns: Redacted name
  static func nodeName(_ name: String) -> String {
    guard name.count > 3 else { return "***" }
    return String(name.prefix(3)) + "***"
  }

  /// Redacts sensitive parts of CLI commands (passwords, keys).
  ///
  /// Redaction is by key, not by position: a command that carries or requests a
  /// secret is logged as its verb and key only, so no value token is ever emitted.
  /// - Parameter command: The CLI command string
  /// - Returns: Command with secret values redacted
  static func cliCommand(_ command: String) -> String {
    if let sensitive = sensitiveCommandParts(command) {
      let head = sensitive.head.joined(separator: " ")
      return sensitive.hasValue ? head + " " + passwordPlaceholder : head
    }
    // Truncate long commands
    return command.count <= 40 ? command : String(command.prefix(40)) + "..."
  }

  /// Whether a CLI command carries or requests a secret, so its reply must not be logged.
  static func isSensitiveCLICommand(_ command: String) -> Bool {
    sensitiveCommandParts(command) != nil
  }

  /// Formats a CLI reply for logging.
  ///
  /// The reply to a sensitive command is reduced to its length, as is the
  /// firmware's `password now: {pw}` echo whatever command it is attributed to.
  /// - Parameters:
  ///   - response: The reply text
  ///   - command: The command the reply answers, if known
  /// - Returns: Reply text safe to log
  static func cliResponse(_ response: String, forCommand command: String? = nil) -> String {
    let answersSensitiveCommand = command.map(isSensitiveCLICommand) ?? false
    if answersSensitiveCommand || response.range(of: passwordEcho, options: .caseInsensitive) != nil {
      return "\(passwordPlaceholder) len=\(response.count)"
    }
    // Truncate very long responses for readability
    return response.count <= 100 ? response : String(response.prefix(100)) + "..."
  }

  /// Placeholder for password values that should never be logged.
  static let passwordPlaceholder = "[REDACTED]"

  // MARK: - Private Helpers

  private static let passwordVerb = "password"
  private static let passwordEcho = "password now:"
  private static let keyedVerbs: Set<String> = ["set", "get"]
  private static let sensitiveKeyFragments = ["password", "pwd", "prv.key", "secret", "pin"]

  /// Splits a sensitive command into the tokens that are safe to log.
  /// Returns nil when the command neither carries nor requests a secret.
  private static func sensitiveCommandParts(_ command: String) -> (head: [String], hasValue: Bool)? {
    let tokens = command.split(whereSeparator: \.isWhitespace)
    guard let verb = tokens.first else { return nil }

    // A value glued to the verb (`password=x`) is still a value, so the verb is emitted as a literal.
    if verb.lowercased().hasPrefix(passwordVerb) {
      return ([passwordVerb], tokens.count > 1 || verb.count > passwordVerb.count)
    }

    guard keyedVerbs.contains(verb.lowercased()), tokens.count > 1 else { return nil }
    let keyToken = tokens[1]
    guard sensitiveKeyFragments.contains(where: { keyToken.lowercased().contains($0) }) else {
      return nil
    }

    // Same for a value glued to the key (`set guest.password=x`).
    let key = keyToken.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    return ([String(verb), String(key)], tokens.count > 2 || key.count < keyToken.count)
  }
}
