import Foundation

/// Thread-safe notification preferences (read-only snapshot from UserDefaults)
struct NotificationPreferences {
  let contactMessagesEnabled: Bool
  let channelMessagesEnabled: Bool
  let roomMessagesEnabled: Bool
  let newContactDiscoveredEnabled: Bool
  let discoveryContactEnabled: Bool
  let discoveryRepeaterEnabled: Bool
  let discoveryRoomEnabled: Bool
  let reactionNotificationsEnabled: Bool
  let soundEnabled: Bool
  let badgeEnabled: Bool
  let lowBatteryEnabled: Bool
  /// Quiet hours: when on, notifications inside the window arrive silently (see `QuietHoursWindow`),
  /// direct messages excepted when `quietHoursAllowDirectMessages` is on.
  let quietHoursEnabled: Bool
  let quietHoursWindow: QuietHoursWindow
  let quietHoursAllowDirectMessages: Bool

  init() {
    let defaults = UserDefaults.standard
    func enabled(_ key: AppStorageKey) -> Bool {
      defaults.object(forKey: key.rawValue) as? Bool ?? AppStorageKey.defaultNotificationEnabled
    }
    quietHoursEnabled = defaults.object(forKey: AppStorageKey.notificationQuietHoursEnabled.rawValue) as? Bool
      ?? AppStorageKey.defaultNotificationQuietHoursEnabled
    quietHoursWindow = QuietHoursWindow(
      startMinute: defaults.object(forKey: AppStorageKey.notificationQuietHoursStart.rawValue) as? Int
        ?? AppStorageKey.defaultNotificationQuietHoursStart,
      endMinute: defaults.object(forKey: AppStorageKey.notificationQuietHoursEnd.rawValue) as? Int
        ?? AppStorageKey.defaultNotificationQuietHoursEnd
    )
    quietHoursAllowDirectMessages = defaults.object(forKey: AppStorageKey.notificationQuietHoursAllowDirect.rawValue) as? Bool
      ?? AppStorageKey.defaultNotificationQuietHoursAllowDirect
    contactMessagesEnabled = enabled(.notifyContactMessages)
    channelMessagesEnabled = enabled(.notifyChannelMessages)
    roomMessagesEnabled = enabled(.notifyRoomMessages)
    newContactDiscoveredEnabled = enabled(.notifyNewContacts)
    discoveryContactEnabled = enabled(.notifyNewContactsContact)
    discoveryRepeaterEnabled = enabled(.notifyNewContactsRepeater)
    discoveryRoomEnabled = enabled(.notifyNewContactsRoom)
    reactionNotificationsEnabled = enabled(.notifyReactions)
    soundEnabled = enabled(.notificationSoundEnabled)
    badgeEnabled = enabled(.notificationBadgeEnabled)
    lowBatteryEnabled = enabled(.notifyLowBattery)
  }
}

/// Observable store for notification preferences (used by Settings UI for two-way binding)
@Observable
@MainActor
public final class NotificationPreferencesStore {
  private let defaults = UserDefaults.standard

  /// Observation anchor for the UserDefaults-backed computed properties:
  /// `@Observable` only instruments stored properties, so every getter reads
  /// this and every setter bumps it, making writes visible to SwiftUI.
  private var revision = 0

  private func isEnabled(_ key: AppStorageKey) -> Bool {
    _ = revision
    return defaults.object(forKey: key.rawValue) as? Bool ?? AppStorageKey.defaultNotificationEnabled
  }

  private func setEnabled(_ newValue: Bool, for key: AppStorageKey) {
    defaults.set(newValue, forKey: key.rawValue)
    revision += 1
  }

  // MARK: - Message Notifications

  /// Enable notifications for contact (direct) messages
  public var contactMessagesEnabled: Bool {
    get { isEnabled(.notifyContactMessages) }
    set { setEnabled(newValue, for: .notifyContactMessages) }
  }

  /// Enable notifications for channel messages
  public var channelMessagesEnabled: Bool {
    get { isEnabled(.notifyChannelMessages) }
    set { setEnabled(newValue, for: .notifyChannelMessages) }
  }

  /// Enable notifications for room messages
  public var roomMessagesEnabled: Bool {
    get { isEnabled(.notifyRoomMessages) }
    set { setEnabled(newValue, for: .notifyRoomMessages) }
  }

  /// Enable notifications when new contacts are discovered
  public var newContactDiscoveredEnabled: Bool {
    get { isEnabled(.notifyNewContacts) }
    set {
      let wasEnabled = isEnabled(.notifyNewContacts)
      setEnabled(newValue, for: .notifyNewContacts)
      // Only auto-enable children on first activation (keys never written before)
      if newValue, !wasEnabled {
        let hasExistingChoices = defaults.object(forKey: AppStorageKey.notifyNewContactsContact.rawValue) != nil
          || defaults.object(forKey: AppStorageKey.notifyNewContactsRepeater.rawValue) != nil
          || defaults.object(forKey: AppStorageKey.notifyNewContactsRoom.rawValue) != nil
        if !hasExistingChoices {
          discoveryContactEnabled = true
          discoveryRepeaterEnabled = true
          discoveryRoomEnabled = true
        }
      }
    }
  }

  /// Enable discovery notifications for companion (chat) nodes
  public var discoveryContactEnabled: Bool {
    get { isEnabled(.notifyNewContactsContact) }
    set { setEnabled(newValue, for: .notifyNewContactsContact) }
  }

  /// Enable discovery notifications for repeater nodes
  public var discoveryRepeaterEnabled: Bool {
    get { isEnabled(.notifyNewContactsRepeater) }
    set { setEnabled(newValue, for: .notifyNewContactsRepeater) }
  }

  /// Enable discovery notifications for room nodes
  public var discoveryRoomEnabled: Bool {
    get { isEnabled(.notifyNewContactsRoom) }
    set { setEnabled(newValue, for: .notifyNewContactsRoom) }
  }

  /// Enable notifications when someone reacts to your messages
  public var reactionNotificationsEnabled: Bool {
    get { isEnabled(.notifyReactions) }
    set { setEnabled(newValue, for: .notifyReactions) }
  }

  // MARK: - Sound & Badge

  /// Enable notification sounds
  public var soundEnabled: Bool {
    get { isEnabled(.notificationSoundEnabled) }
    set { setEnabled(newValue, for: .notificationSoundEnabled) }
  }

  /// Enable badge count on app icon
  public var badgeEnabled: Bool {
    get { isEnabled(.notificationBadgeEnabled) }
    set { setEnabled(newValue, for: .notificationBadgeEnabled) }
  }

  // MARK: - Low Battery

  /// Enable low battery warning notifications
  public var lowBatteryEnabled: Bool {
    get { isEnabled(.notifyLowBattery) }
    set { setEnabled(newValue, for: .notifyLowBattery) }
  }

  // MARK: - Quiet Hours

  /// Whether notifications inside the quiet-hours window arrive silently.
  public var quietHoursEnabled: Bool {
    get {
      _ = revision
      return defaults.object(forKey: AppStorageKey.notificationQuietHoursEnabled.rawValue) as? Bool
        ?? AppStorageKey.defaultNotificationQuietHoursEnabled
    }
    set { setEnabled(newValue, for: .notificationQuietHoursEnabled) }
  }

  /// The window's start, minutes past midnight.
  public var quietHoursStartMinute: Int {
    get {
      _ = revision
      return defaults.object(forKey: AppStorageKey.notificationQuietHoursStart.rawValue) as? Int
        ?? AppStorageKey.defaultNotificationQuietHoursStart
    }
    set {
      defaults.set(newValue, forKey: AppStorageKey.notificationQuietHoursStart.rawValue)
      revision += 1
    }
  }

  /// The window's end, minutes past midnight; before the start means it spans midnight.
  public var quietHoursEndMinute: Int {
    get {
      _ = revision
      return defaults.object(forKey: AppStorageKey.notificationQuietHoursEnd.rawValue) as? Int
        ?? AppStorageKey.defaultNotificationQuietHoursEnd
    }
    set {
      defaults.set(newValue, forKey: AppStorageKey.notificationQuietHoursEnd.rawValue)
      revision += 1
    }
  }

  /// Whether direct messages still arrive as full alerts during quiet hours.
  public var quietHoursAllowDirectMessages: Bool {
    get {
      _ = revision
      return defaults.object(forKey: AppStorageKey.notificationQuietHoursAllowDirect.rawValue) as? Bool
        ?? AppStorageKey.defaultNotificationQuietHoursAllowDirect
    }
    set { setEnabled(newValue, for: .notificationQuietHoursAllowDirect) }
  }

  /// The window the start and end describe.
  public var quietHoursWindow: QuietHoursWindow {
    QuietHoursWindow(startMinute: quietHoursStartMinute, endMinute: quietHoursEndMinute)
  }

  // MARK: - Not Receiving

  /// Remind the user when the app has heard nothing from its radio for a while in the background
  /// (it may have been closed, or Bluetooth turned off), and when Bluetooth is turned off.
  public var notReceivingReminderEnabled: Bool {
    get { isEnabled(.notifyNotReceiving) }
    set { setEnabled(newValue, for: .notifyNotReceiving) }
  }

  public init() {}
}
