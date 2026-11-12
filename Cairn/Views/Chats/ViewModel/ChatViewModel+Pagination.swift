import CairnServices
import SwiftUI

extension ChatViewModel {
  // MARK: - Pagination

  /// Load older messages when user scrolls near the top. The timeline owns
  /// the paging sequence (spinner, fetch, dedupe, prepend, rebake); this
  /// wrapper layers the caller-side bookkeeping on top: mention-picker
  /// sender registration, reaction indexing, and the error surface.
  /// Pages older history in until `messageID` is part of the loaded window, so
  /// a search hit from far back can be scrolled to. Returns whether it is loaded.
  /// Ends when history runs out, a page comes back empty, or the task is cancelled.
  func revealMessage(_ messageID: UUID) async -> Bool {
    while messagesByID[messageID] == nil {
      guard renderState.hasMoreMessages, !Task.isCancelled else { return false }
      let loadedBefore = messages.count
      await loadOlderMessages()
      // A failed or skipped page would otherwise spin here forever.
      guard messages.count > loadedBefore else { return false }
    }
    return true
  }

  func loadOlderMessages() async {
    guard let dataStore else { return }

    // Snapshot conversation context before any await — actor reentrancy
    // means currentContact/currentChannel can change during suspensions
    let contact = currentContact
    let channel = currentChannel

    do {
      let olderMessages = try await timeline.loadOlder()
      guard !olderMessages.isEmpty else { return }

      // Register senders from the older page; without this, scrolling
      // back to a sender who only appears in older pages leaves them
      // missing from the @-autocomplete list.
      if let channel {
        for message in olderMessages {
          if let senderName = message.senderNodeName {
            addChannelSenderIfNew(senderName, radioID: channel.radioID, timestamp: message.timestamp)
          }
        }
      }

      // Index older channel messages for reaction matching and process pending reactions
      if let channel,
         let reactionService = reactionServiceProvider() {
        await indexMessagesForReactions(
          olderMessages,
          scope: .channel(channel, localNodeName: connectedDeviceProvider()?.nodeName),
          reactionService: reactionService,
          dataStore: dataStore
        )
      }

      // Index older DM messages for reaction matching and process pending reactions
      if let contact,
         let reactionService = reactionServiceProvider() {
        await indexMessagesForReactions(
          olderMessages,
          scope: .direct(contact),
          reactionService: reactionService,
          dataStore: dataStore
        )
      }

    } catch {
      errorBannerMessage = L10n.Chats.Chats.Error.loadOlderMessagesFailed
      logger.error("Failed to load older messages: \(error)")
    }
  }
}
