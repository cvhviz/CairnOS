import Foundation

/// The notification level a newly added channel starts with.
///
/// A user preference in `UserDefaults`; the store reads it when it inserts a
/// channel row, so every way a channel arrives (create, join, QR, link, sync from
/// the radio) gets the same default without each call site passing it through.
public enum ChannelNotificationDefaults {
  public static let defaultsKey = AppStorageKey.defaultChannelNotificationLevel.rawValue

  /// Level used until the user picks one: every message notifies, as before this setting existed.
  public static let fallback = NotificationLevel.all

  public static func level(from defaults: UserDefaults = .standard) -> NotificationLevel {
    guard let raw = defaults.object(forKey: defaultsKey) as? Int else { return fallback }
    return NotificationLevel(rawValue: raw) ?? fallback
  }

  public static func setLevel(_ level: NotificationLevel, in defaults: UserDefaults = .standard) {
    defaults.set(level.rawValue, forKey: defaultsKey)
  }
}
