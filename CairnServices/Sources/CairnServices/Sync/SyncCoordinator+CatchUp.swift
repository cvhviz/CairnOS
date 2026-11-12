// SyncCoordinator+CatchUp.swift
import Foundation

// MARK: - Catch-up Notifications

/// A conversation that got messages while notifications were suppressed for a catch-up sync.
enum CatchUpConversation: Hashable {
  case direct(contactID: UUID)
  case channel(radioID: UUID, index: UInt8)
}

/// What a conversation's catch-up notification needs: the count, and the newest message for a
/// single one, which posts as that message's own notification.
struct CatchUpEntry {
  var count: Int
  let name: String
  var latestText: String
  var latestSender: String?
  var latestMessageID: UUID
  let isMuted: Bool
  let notificationLevel: NotificationLevel
  var hasSelfMention: Bool
}

extension SyncCoordinator {
  /// Notes a stored DM whose notification the catch-up suppression swallowed.
  func recordCatchUpDirectMessage(
    contactID: UUID,
    contactName: String,
    text: String,
    messageID: UUID,
    isMuted: Bool
  ) {
    recordCatchUp(
      .direct(contactID: contactID),
      name: contactName,
      text: text,
      sender: nil,
      messageID: messageID,
      isMuted: isMuted,
      notificationLevel: .all,
      hasSelfMention: false
    )
  }

  /// Notes a stored channel message whose notification the catch-up suppression swallowed.
  func recordCatchUpChannelMessage( // swiftlint:disable:this function_parameter_count
    radioID: UUID,
    channelIndex: UInt8,
    channelName: String,
    senderName: String?,
    text: String,
    messageID: UUID,
    notificationLevel: NotificationLevel,
    hasSelfMention: Bool
  ) {
    recordCatchUp(
      .channel(radioID: radioID, index: channelIndex),
      name: channelName,
      text: text,
      sender: senderName,
      messageID: messageID,
      isMuted: false,
      notificationLevel: notificationLevel,
      hasSelfMention: hasSelfMention
    )
  }

  private func recordCatchUp( // swiftlint:disable:this function_parameter_count
    _ conversation: CatchUpConversation,
    name: String,
    text: String,
    sender: String?,
    messageID: UUID,
    isMuted: Bool,
    notificationLevel: NotificationLevel,
    hasSelfMention: Bool
  ) {
    if var entry = catchUpTally[conversation] {
      entry.count += 1
      entry.latestText = text
      entry.latestSender = sender
      entry.latestMessageID = messageID
      entry.hasSelfMention = entry.hasSelfMention || hasSelfMention
      catchUpTally[conversation] = entry
    } else {
      catchUpTally[conversation] = CatchUpEntry(
        count: 1,
        name: name,
        latestText: text,
        latestSender: sender,
        latestMessageID: messageID,
        isMuted: isMuted,
        notificationLevel: notificationLevel,
        hasSelfMention: hasSelfMention
      )
      catchUpOrder.append(conversation)
    }
  }

  /// Posts what the catch-up suppression swallowed, once it has been lifted: one notification per
  /// conversation ("3 new messages from Bob", or the message itself when only one came), and only
  /// when the app is away. In the foreground the lists and badges already show it, so the tally
  /// is dropped rather than turned into a burst of banners. Every entry is a message the dedup
  /// key let through, so a retried or re-drained message never counts twice.
  func flushCatchUpNotifications(notificationService: NotificationService) async {
    guard !catchUpOrder.isEmpty else { return }
    let tally = catchUpTally
    let order = catchUpOrder
    catchUpTally = [:]
    catchUpOrder = []

    let inForeground = await catchUpAppStateProvider?.isInForeground ?? true
    guard !inForeground else {
      logger.debug("[Sync] Catch-up brought messages for \(order.count) conversation(s) while in the foreground")
      return
    }
    logger.info("[Sync] Posting catch-up notifications for \(order.count) conversation(s)")

    for conversation in order {
      guard let entry = tally[conversation] else { continue }
      switch conversation {
      case let .direct(contactID):
        if entry.count == 1 {
          await notificationService.postDirectMessageNotification(
            from: entry.name,
            contactID: contactID,
            messageText: entry.latestText,
            messageID: entry.latestMessageID,
            isMuted: entry.isMuted
          )
        } else {
          await notificationService.postDirectMessageCatchUpNotification(
            from: entry.name,
            contactID: contactID,
            count: entry.count,
            latestMessageID: entry.latestMessageID,
            isMuted: entry.isMuted
          )
        }
      case let .channel(radioID, index):
        if entry.count == 1 {
          await notificationService.postChannelMessageNotification(
            channelName: entry.name,
            channelIndex: index,
            radioID: radioID,
            senderName: entry.latestSender,
            messageText: entry.latestText,
            messageID: entry.latestMessageID,
            notificationLevel: entry.notificationLevel,
            hasSelfMention: entry.hasSelfMention
          )
        } else {
          await notificationService.postChannelMessageCatchUpNotification(
            channelName: entry.name,
            channelIndex: index,
            radioID: radioID,
            count: entry.count,
            latestMessageID: entry.latestMessageID,
            notificationLevel: entry.notificationLevel,
            hasSelfMention: entry.hasSelfMention
          )
        }
      }
    }
  }

  /// Drops the tally without posting (a disconnect mid-sync, or a test reset).
  func discardCatchUpNotifications() {
    catchUpTally = [:]
    catchUpOrder = []
  }
}
