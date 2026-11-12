import Foundation
import UserNotifications

/// When the "Cairn may not be receiving" reminder is scheduled, pushed back or cancelled. Pure, so
/// the rules are tested without notifications.
///
/// iOS does not relaunch a bluetooth-central app the user swiped away, and a Bluetooth power cycle
/// or a reboot leaves it no pending connect. Nothing can store the radio's messages then, and the
/// radio's queue eventually overflows. The reminder is a dead-man's switch: armed when the app goes to
/// the background wanting its radio, pushed back by every sign of life from the link (a suspended
/// app only runs when the radio wakes it), and cancelled when the app returns. If the app stops
/// hearing from the radio for ``delay``, the pending notification fires on its own, whether the app
/// was suspended, killed or never relaunched.
public struct ListeningReminderPolicy: Sendable, Equatable {
  /// How long without a sign of life from the link before the reminder shows. A quiet mesh can be
  /// silent this long too, so the reminder is worded as a "may" and can be turned off.
  public static let delay: TimeInterval = 45 * 60
  /// The least time between two reschedules, so a busy link doesn't churn the notification center.
  public static let rescheduleThrottle: TimeInterval = 60

  public enum Action: Sendable, Equatable {
    case none
    case schedule(after: TimeInterval)
    case cancel
  }

  public private(set) var inBackground = false
  public private(set) var armed = false
  public private(set) var lastScheduledAt: Date?

  public init() {}

  public mutating func enteredBackground(wantsConnection: Bool, hasRadio: Bool, enabled: Bool, now: Date) -> Action {
    inBackground = true
    guard wantsConnection, hasRadio, enabled else {
      armed = false
      lastScheduledAt = nil
      return .cancel
    }
    armed = true
    lastScheduledAt = now
    return .schedule(after: Self.delay)
  }

  /// The radio sent something: push the reminder back (throttled) while it is armed.
  public mutating func linkActivity(now: Date) -> Action {
    guard inBackground, armed else { return .none }
    if let lastScheduledAt, now.timeIntervalSince(lastScheduledAt) < Self.rescheduleThrottle {
      return .none
    }
    lastScheduledAt = now
    return .schedule(after: Self.delay)
  }

  public mutating func becameActive() -> Action {
    inBackground = false
    armed = false
    lastScheduledAt = nil
    return .cancel
  }

  /// The user disconnected or forgot the radio: nothing is expected from it.
  public mutating func connectionAbandoned() -> Action {
    armed = false
    lastScheduledAt = nil
    return .cancel
  }
}

/// Posts and withdraws the app's local notifications by identifier.
@MainActor
public protocol LocalNotificationScheduling: AnyObject {
  /// Adds (or replaces) the notification `identifier`, shown after `delay` seconds, or at once for nil.
  func schedule(identifier: String, title: String, body: String, after delay: TimeInterval?) async
  /// Withdraws pending and delivered notifications with these identifiers.
  func cancel(identifiers: [String])
}

/// `UNUserNotificationCenter`, only while the user allows notifications.
@MainActor
public final class UserNotificationScheduler: LocalNotificationScheduling {
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "ListeningReminder")

  public init() {}

  public func schedule(identifier: String, title: String, body: String, after delay: TimeInterval?) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined, .denied:
      return
    default:
      break
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["type": identifier]
    let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
    do {
      try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    } catch {
      logger.warning("Failed to schedule \(identifier): \(error.localizedDescription)")
    }
  }

  public func cancel(identifiers: [String]) {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }
}

/// The "may not be receiving" reminder and the "Bluetooth is off" notice. `ConnectionManager` drives
/// it from the app lifecycle, the link's activity, Bluetooth power and disconnects.
@MainActor
public final class ListeningReminder {
  public static let reminderIdentifier = "cairn.not-receiving"
  public static let bluetoothOffIdentifier = "cairn.bluetooth-off"

  private var policy = ListeningReminderPolicy()
  private let scheduler: LocalNotificationScheduling
  private let strings: NotificationStringProvider?
  private let isEnabled: @MainActor () -> Bool
  private let now: @MainActor () -> Date

  /// - Parameters:
  ///   - strings: Localized texts (English when nil).
  ///   - isEnabled: The user's setting (Settings → Notifications).
  public init(
    scheduler: LocalNotificationScheduling = UserNotificationScheduler(),
    strings: NotificationStringProvider? = nil,
    isEnabled: @escaping @MainActor () -> Bool = { NotificationPreferencesStore().notReceivingReminderEnabled },
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.scheduler = scheduler
    self.strings = strings
    self.isEnabled = isEnabled
    self.now = now
  }

  public var currentPolicy: ListeningReminderPolicy { policy }

  func appEnteredBackground(wantsConnection: Bool, deviceName: String?) async {
    let action = policy.enteredBackground(
      wantsConnection: wantsConnection,
      hasRadio: deviceName != nil,
      enabled: isEnabled(),
      now: now()
    )
    await apply(action, deviceName: deviceName)
  }

  func linkActivity(deviceName: String?) async {
    await apply(policy.linkActivity(now: now()), deviceName: deviceName)
  }

  func appBecameActive() async {
    await apply(policy.becameActive(), deviceName: nil)
    scheduler.cancel(identifiers: [Self.bluetoothOffIdentifier])
  }

  func connectionAbandoned() async {
    await apply(policy.connectionAbandoned(), deviceName: nil)
    scheduler.cancel(identifiers: [Self.bluetoothOffIdentifier])
  }

  /// Bluetooth turned off while the app is in the background and wants its radio: nothing can
  /// reach the radio until it is back, so say so now instead of waiting for the reminder.
  func bluetoothPoweredOff(deviceName: String?) async {
    guard policy.inBackground, policy.armed, isEnabled(), let deviceName else { return }
    await scheduler.schedule(
      identifier: Self.bluetoothOffIdentifier,
      title: strings?.bluetoothOffTitle ?? "Bluetooth Is Off",
      body: strings?.bluetoothOffBody(deviceName: deviceName)
        ?? "Cairn can't receive messages from \(deviceName) until Bluetooth is turned back on.",
      after: nil
    )
  }

  func bluetoothPoweredOn() {
    scheduler.cancel(identifiers: [Self.bluetoothOffIdentifier])
  }

  private func apply(_ action: ListeningReminderPolicy.Action, deviceName: String?) async {
    switch action {
    case .none:
      break
    case .cancel:
      scheduler.cancel(identifiers: [Self.reminderIdentifier])
    case let .schedule(delay):
      let name = deviceName ?? ""
      await scheduler.schedule(
        identifier: Self.reminderIdentifier,
        title: strings?.notReceivingTitle ?? "Cairn May Not Be Receiving",
        body: strings?.notReceivingBody(deviceName: name)
          ?? "Nothing has come in from \(name) for a while. Open Cairn to collect any messages waiting on the radio.",
        after: delay
      )
    }
  }
}
