import Foundation

/// What the home-screen widget shows: the radio, its link, battery and unread count, and the
/// node heard last. The app writes it to the App Group's defaults (`WidgetSnapshotStore`) and
/// asks WidgetKit to reload; the widget extension only reads it, as it has no radio access.
///
/// Compiled into both targets. Every field but `connectionState`, `unreadCount` and `updatedAt`
/// is optional, so a snapshot written by a newer app decodes in an older widget and vice versa.
struct WidgetSnapshot: Codable, Equatable, Sendable {
  enum ConnectionState: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
  }

  /// A node whose advert the radio heard, by the name the app shows for it.
  struct HeardNode: Codable, Equatable, Sendable {
    var name: String
    var date: Date
  }

  /// The radio's name, or nil when the app has no radio to show ("No radio").
  var radioName: String?
  var connectionState: ConnectionState
  /// Only while connected; the widget shows nothing for an unknown level.
  var batteryPercent: Int?
  var unreadCount: Int
  var lastHeard: HeardNode?
  /// When the app wrote this snapshot, so the widget can say how old its picture is.
  var updatedAt: Date

  var isConnected: Bool { connectionState == .connected }

  /// Whether two snapshots say the same thing, ignoring when they were written.
  func hasSameContent(as other: WidgetSnapshot) -> Bool {
    var mine = self
    var theirs = other
    mine.updatedAt = .distantPast
    theirs.updatedAt = .distantPast
    return mine == theirs
  }
}

/// Where the snapshot lives: a key in the App Group's `UserDefaults`, as JSON.
enum WidgetSnapshotStore {
  /// The home-screen widget's kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
  static let widgetKind = "cvhvisuals.Cairn.RadioStatus"
  static let defaultsKey = "widgetSnapshot"

  /// The App Group both targets are entitled to (`CAIRN_APP_GROUP` in project.yml):
  /// `group.cvhvisuals.Cairn` for the App Store build and `group.cvhvisuals.Cairn.dev` for the
  /// Debug `.dev` one, so a dev install beside the release app never feeds its widget. Derived
  /// from the bundle identifier (the widget's ends in `.widgets`), which is what the build
  /// setting is derived from too.
  static func appGroupID(bundleIdentifier: String) -> String {
    var base = bundleIdentifier
    if base.hasSuffix(".widgets") {
      base.removeLast(".widgets".count)
    }
    return "group." + base
  }

  static var appGroupID: String {
    appGroupID(bundleIdentifier: Bundle.main.bundleIdentifier ?? "cvhvisuals.Cairn")
  }

  /// The shared defaults, nil only when the suite can't be opened.
  static func defaults() -> UserDefaults? {
    UserDefaults(suiteName: appGroupID)
  }

  static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return try encoder.encode(snapshot)
  }

  static func decode(_ data: Data) throws -> WidgetSnapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode(WidgetSnapshot.self, from: data)
  }

  /// The last snapshot written, or nil when none was or it no longer decodes.
  static func load(from defaults: UserDefaults) -> WidgetSnapshot? {
    guard let data = defaults.data(forKey: defaultsKey) else { return nil }
    return try? decode(data)
  }

  static func save(_ snapshot: WidgetSnapshot, to defaults: UserDefaults) {
    guard let data = try? encode(snapshot) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}
