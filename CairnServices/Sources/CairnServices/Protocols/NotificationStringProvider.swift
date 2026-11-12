import Foundation

/// Provides localized strings for notifications.
///
/// This protocol allows the app layer to inject localized strings into
/// CairnServices without the service layer depending on L10n directly.
public protocol NotificationStringProvider: Sendable {
  /// Returns the notification title for a discovered contact of the given type.
  /// - Parameter type: The type of contact discovered
  /// - Returns: Localized notification title (e.g., "New Repeater Discovered")
  func discoveryNotificationTitle(for type: ContactType) -> String

  /// Returns the localized title for the "Reply" notification action.
  var replyActionTitle: String { get }

  /// Returns the localized title for the "Send" button in notification quick reply.
  var sendButtonTitle: String { get }

  /// Returns the localized placeholder for the notification quick reply text input.
  var messagePlaceholder: String { get }

  /// Returns the localized title for the "Mark as Read" notification action.
  var markAsReadActionTitle: String { get }

  /// Returns the localized title for a low battery warning notification.
  var lowBatteryTitle: String { get }

  /// Returns the localized body for a low battery warning notification.
  /// - Parameters:
  ///   - deviceName: The name of the device with low battery
  ///   - percentage: The current battery percentage
  /// - Returns: Localized notification body
  func lowBatteryBody(deviceName: String, percentage: Int) -> String

  /// Returns the localized title for a failed quick-reply notification.
  var quickReplyFailedTitle: String { get }

  /// Returns the localized body for a failed quick-reply notification.
  /// - Parameter conversationName: The contact or channel display name
  /// - Returns: Localized notification body
  func quickReplyFailedBody(conversationName: String) -> String

  /// Returns the localized fallback display name for a discovered contact with no advertised name.
  var unknownContactName: String { get }

  /// Returns the localized fallback display name for a channel with no stored name.
  /// - Parameter index: The channel's slot index
  func defaultChannelName(index: Int) -> String

  /// Returns the localized body for a reaction notification.
  /// - Parameters:
  ///   - emoji: The reaction emoji
  ///   - messagePreview: Truncated preview of the reacted-to message
  func reactionNotificationBody(emoji: String, messagePreview: String) -> String

  /// Returns the localized body for one notification standing for several messages that
  /// arrived in a conversation while the app was away (e.g., "3 new messages").
  /// - Parameter count: How many messages arrived (2 or more)
  func catchUpMessagesBody(count: Int) -> String

  /// A channel sender matched to a contact by name only: the contact's nickname with the name it
  /// put on air, e.g. "Dad (Frank Wilson)". The name alone is not proof of identity, so the
  /// nickname never stands without it where there is room.
  func unverifiedSenderName(nickname: String, wireName: String) -> String

  /// What a room post's author reads as when only their key prefix is known, e.g.
  /// "Unknown (50515253)".
  func unknownRoomAuthor(keyPrefixHex: String) -> String

  /// Title of the reminder that the app has heard nothing from its radio for a while.
  var notReceivingTitle: String { get }

  /// Body of that reminder. - Parameter deviceName: The radio's name.
  func notReceivingBody(deviceName: String) -> String

  /// Title of the notice that Bluetooth was turned off while the app wanted its radio.
  var bluetoothOffTitle: String { get }

  /// Body of that notice. - Parameter deviceName: The radio's name.
  func bluetoothOffBody(deviceName: String) -> String

  /// Title of the notice that a Cairn radio's message queue lost messages while the app was away.
  var radioQueueLossTitle: String { get }

  /// Body of that notice.
  /// - Parameters:
  ///   - deviceName: The radio's name.
  ///   - count: How many messages were lost (1 or more).
  func radioQueueLossBody(deviceName: String, count: Int) -> String
}

public extension NotificationStringProvider {
  /// English fallback for providers that predate the catch-up notification.
  func catchUpMessagesBody(count: Int) -> String {
    "\(count) new messages"
  }

  func unverifiedSenderName(nickname: String, wireName: String) -> String {
    ChannelSenderNameResolver.defaultLabel(nickname: nickname, wireName: wireName)
  }

  func unknownRoomAuthor(keyPrefixHex: String) -> String {
    keyPrefixHex
  }

  var notReceivingTitle: String {
    "Cairn May Not Be Receiving"
  }

  func notReceivingBody(deviceName: String) -> String {
    "Nothing has come in from \(deviceName) for a while. Open Cairn to collect any messages waiting on the radio."
  }

  var bluetoothOffTitle: String {
    "Bluetooth Is Off"
  }

  func bluetoothOffBody(deviceName: String) -> String {
    "Cairn can't receive messages from \(deviceName) until Bluetooth is turned back on."
  }

  var radioQueueLossTitle: String {
    "Messages Lost on the Radio"
  }

  func radioQueueLossBody(deviceName: String, count: Int) -> String {
    "\(deviceName) ran out of room for messages while Cairn was away. Messages lost: \(count)."
  }
}
