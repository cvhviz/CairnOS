import Foundation
import CairnServices

extension ChatViewModel {
  // MARK: - Reactions

  /// Send a reaction emoji to a message (channel or DM)
  func sendReaction(emoji: String, to message: MessageDTO) async {
    guard reactionServiceProvider() != nil,
          messageService != nil,
          let dataStore else {
      return
    }

    // Prevent duplicate sends from rapid taps
    let reactionKey = "\(message.id)-\(emoji)"
    guard !inFlightReactions.contains(reactionKey) else {
      logger.debug("Reaction \(emoji) already in flight for message \(message.id), ignoring")
      return
    }
    inFlightReactions.insert(reactionKey)
    defer { inFlightReactions.remove(reactionKey) }

    // The node name the radio puts on air now: the reaction goes out under it.
    let localNodeName = connectedDeviceProvider()?.nodeName ?? ""

    // Check if user already reacted with this emoji: any of the user's own reactions, whatever
    // name it went out under (a rename must not allow a second one).
    let ownReaction = ReactionDTO(
      messageID: message.id, emoji: emoji, senderName: localNodeName, messageHash: "", rawText: "",
      radioID: message.radioID, isFromSelf: true
    )
    if let alreadyReacted = try? await dataStore.hasReaction(matching: ownReaction), alreadyReacted {
      logger.debug("User already reacted with \(emoji), ignoring")
      return
    }

    // Handle channel vs DM
    if let channelIndex = message.channelIndex {
      await sendChannelReaction(
        emoji: emoji,
        to: message,
        channelIndex: channelIndex,
        localNodeName: localNodeName
      )
    } else if let contactID = message.contactID {
      await sendDMReaction(
        emoji: emoji,
        to: message,
        contactID: contactID,
        localNodeName: localNodeName
      )
    }
  }

  private func sendChannelReaction(
    emoji: String,
    to message: MessageDTO,
    channelIndex: UInt8,
    localNodeName: String
  ) async {
    guard let reactionService = reactionServiceProvider(),
          let messageService,
          let dataStore else { return }

    // Who the mesh knows the reacted-to message's author as: the sender's on-air name, or for the
    // user's own message the name it went out under (which outlives a rename).
    guard let targetSenderName = message.onAirSenderName(
      currentSelfName: localNodeName.isEmpty ? nil : localNodeName
    ) else { return }

    let reactionText = reactionService.buildReactionText(
      emoji: emoji,
      targetSender: targetSenderName,
      targetText: message.text,
      targetTimestamp: message.reactionTimestamp
    )

    do {
      _ = try await messageService.sendChannelMessage(
        text: reactionText,
        channelIndex: channelIndex,
        radioID: message.radioID
      )

      // Optimistic local update
      let messageHash = ReactionParser.generateMessageHash(
        text: message.text,
        timestamp: message.reactionTimestamp
      )
      let reactionDTO = ReactionDTO(
        messageID: message.id,
        emoji: emoji,
        senderName: localNodeName,
        messageHash: messageHash,
        rawText: reactionText,
        channelIndex: channelIndex,
        radioID: message.radioID,
        isFromSelf: true
      )
      if let result = await reactionService.persistReactionAndUpdateSummary(
        reactionDTO,
        using: dataStore
      ) {
        updateReactionSummary(for: result.messageID, summary: result.summary)
      }
    } catch {
      logger.error("Failed to send channel reaction: \(error)")
      errorMessage = error.userFacingMessage
    }
  }

  private func sendDMReaction(
    emoji: String,
    to message: MessageDTO,
    contactID: UUID,
    localNodeName: String
  ) async {
    guard let reactionService = reactionServiceProvider(),
          let messageService,
          let dataStore else { return }

    // Fetch the contact for sending
    guard let contact = try? await dataStore.fetchContact(id: contactID) else {
      logger.error("Failed to fetch contact for DM reaction")
      return
    }

    let reactionText = reactionService.buildDMReactionText(
      emoji: emoji,
      targetText: message.text,
      targetTimestamp: message.reactionTimestamp
    )
    do {
      // Send as DM to the contact
      _ = try await messageService.sendDirectMessage(
        text: reactionText,
        to: contact
      )

      // Optimistic local update
      let messageHash = ReactionParser.generateMessageHash(
        text: message.text,
        timestamp: message.reactionTimestamp
      )
      let reactionDTO = ReactionDTO(
        messageID: message.id,
        emoji: emoji,
        senderName: localNodeName,
        messageHash: messageHash,
        rawText: reactionText,
        contactID: contactID,
        radioID: message.radioID,
        isFromSelf: true
      )
      if let result = await reactionService.persistReactionAndUpdateSummary(
        reactionDTO,
        using: dataStore
      ) {
        updateReactionSummary(for: result.messageID, summary: result.summary)
      }
    } catch {
      logger.error("Failed to send DM reaction: \(error)")
      errorMessage = error.userFacingMessage
    }
  }

  // MARK: - Reaction Updates

  /// Update reaction summary for a specific message inline (O(1) update)
  func updateReactionSummary(for messageID: UUID, summary: String) {
    updateMessage(id: messageID) { $0.reactionSummary = summary }
  }
}
