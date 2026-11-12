import Foundation

/// Per-node choices made on a repeater's or room's dashboard and kept on this phone: how often to
/// refresh the status while its page is open. Keyed by the node's public key, as `NodeCardCache` is.
/// (Entries saved before 2026-11-09 also hold a low-battery threshold and an alert time for the
/// removed background check; decoding ignores them and the next save drops them.)
enum RemoteNodePreferences {
  struct Entry: Codable, Equatable {
    /// Minutes between status refreshes while the dashboard is open; nil is off.
    var autoRefreshMinutes: Int?
  }

  /// The refresh intervals the dashboard menu offers, in minutes.
  static let refreshChoices = [1, 2, 5, 10, 15]

  static func key(for publicKey: Data) -> String {
    "remoteNodePreferences." + publicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  static func entry(for publicKey: Data, defaults: UserDefaults = .standard) -> Entry {
    guard let data = defaults.data(forKey: key(for: publicKey)),
          let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
    return entry
  }

  static func update(for publicKey: Data, defaults: UserDefaults = .standard, _ change: (inout Entry) -> Void) {
    var entry = entry(for: publicKey, defaults: defaults)
    change(&entry)
    if let data = try? JSONEncoder().encode(entry) {
      defaults.set(data, forKey: key(for: publicKey))
    }
  }

  static func autoRefreshMinutes(for publicKey: Data, defaults: UserDefaults = .standard) -> Int? {
    entry(for: publicKey, defaults: defaults).autoRefreshMinutes
  }

  static func setAutoRefreshMinutes(_ minutes: Int?, for publicKey: Data, defaults: UserDefaults = .standard) {
    update(for: publicKey, defaults: defaults) { $0.autoRefreshMinutes = minutes }
  }
}
