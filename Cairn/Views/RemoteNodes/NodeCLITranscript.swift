import Foundation

/// The commands typed into a node's command line, kept per node between visits so the up arrow
/// finds last week's `set tx 20` too.
enum NodeCLIHistoryStore {
  static let maxEntries = 100

  static func key(for publicKey: Data) -> String {
    "nodeCLIHistory." + publicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  static func load(publicKey: Data, defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: key(for: publicKey)) ?? []
  }

  static func save(_ history: [String], publicKey: Data, defaults: UserDefaults = .standard) {
    defaults.set(Array(history.suffix(maxEntries)), forKey: key(for: publicKey))
  }
}

/// A command line's destructive commands, matched the way the Controls page lists them (reboot,
/// poweroff, clear stats, log erase, set radio), so typing one asks first as a tile would.
enum NodeCLIConfirmation {
  /// The confirmation text for `command`, or nil for anything that needs none.
  @MainActor
  static func message(for command: String) -> String? {
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let words = normalized.split(separator: " ").map(String.init)
    guard let first = words.first else { return nil }
    if first == "reboot" {
      return L10n.RemoteNodes.RemoteNodes.Settings.rebootMessage
    }
    if first == "set", words.count > 1, words[1] == "radio" {
      return L10n.RemoteNodes.RemoteNodes.NodeCli.confirmSetRadio
    }
    for listed in RepeaterControlsModel.commands where listed.confirmation != nil {
      if normalized == listed.command.lowercased() || normalized.hasPrefix(listed.command.lowercased() + " ") {
        return listed.confirmation
      }
    }
    return nil
  }
}

/// The terminal's output as plain text to share or copy: each command on its own line after the
/// prompt, replies as they came.
enum NodeCLITranscript {
  static func text(lines: [CLIOutputLine], nodeName: String, now: Date = .now) -> String {
    let header = "\(nodeName) · \(now.formatted(date: .abbreviated, time: .shortened))"
    let body = lines.map(\.text).joined(separator: "\n")
    return header + "\n\n" + body
  }
}
