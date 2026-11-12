import Foundation
import CairnServices

/// App-layer implementation of NotificationStringProvider using L10n.
struct NotificationStringProviderImpl: NotificationStringProvider {
  func discoveryNotificationTitle(for type: ContactType) -> String {
    switch type {
    case .chat:
      L10n.Localizable.Notifications.Discovery.contact
    case .repeater:
      L10n.Localizable.Notifications.Discovery.repeater
    case .room:
      L10n.Localizable.Notifications.Discovery.room
    }
  }

  var replyActionTitle: String {
    L10n.Localizable.Notifications.Action.reply
  }

  var sendButtonTitle: String {
    L10n.Localizable.Notifications.Action.send
  }

  var messagePlaceholder: String {
    L10n.Localizable.Notifications.Action.messagePlaceholder
  }

  var markAsReadActionTitle: String {
    L10n.Localizable.Notifications.Action.markAsRead
  }

  var lowBatteryTitle: String {
    L10n.Localizable.Notifications.LowBattery.title
  }

  func lowBatteryBody(deviceName: String, percentage: Int) -> String {
    L10n.Localizable.Notifications.LowBattery.body(deviceName, percentage)
  }

  var quickReplyFailedTitle: String {
    L10n.Localizable.Notifications.QuickReplyFailed.title
  }

  func quickReplyFailedBody(conversationName: String) -> String {
    L10n.Localizable.Notifications.QuickReplyFailed.body(conversationName)
  }

  var unknownContactName: String {
    L10n.Localizable.Notifications.Discovery.unknownContact
  }

  func defaultChannelName(index: Int) -> String {
    L10n.Chats.Chats.Channel.defaultName(index)
  }

  func reactionNotificationBody(emoji: String, messagePreview: String) -> String {
    L10n.Localizable.Notifications.Reaction.body(emoji, messagePreview)
  }

  func catchUpMessagesBody(count: Int) -> String {
    L10n.Localizable.Notifications.CatchUp.body(count)
  }

  func unverifiedSenderName(nickname: String, wireName: String) -> String {
    L10n.Chats.Chats.Message.Sender.unverifiedLabel(nickname, wireName)
  }

  func unknownRoomAuthor(keyPrefixHex: String) -> String {
    L10n.Chats.Chats.Message.Sender.unknownAuthor(keyPrefixHex)
  }

  var notReceivingTitle: String {
    L10n.Localizable.Notifications.NotReceiving.title
  }

  func notReceivingBody(deviceName: String) -> String {
    L10n.Localizable.Notifications.NotReceiving.body(deviceName)
  }

  var bluetoothOffTitle: String {
    L10n.Localizable.Notifications.BluetoothOff.title
  }

  func bluetoothOffBody(deviceName: String) -> String {
    L10n.Localizable.Notifications.BluetoothOff.body(deviceName)
  }

  var radioQueueLossTitle: String {
    L10n.Localizable.Notifications.RadioQueueLoss.title
  }

  func radioQueueLossBody(deviceName: String, count: Int) -> String {
    L10n.Localizable.Notifications.RadioQueueLoss.body(deviceName, count)
  }
}
