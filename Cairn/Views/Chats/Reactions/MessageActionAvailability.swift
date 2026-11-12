import CairnServices

/// Which actions the message sheet offers for a given `MessageDTO`.
struct MessageActionAvailability {
  let canReply: Bool
  let canCopy: Bool
  let canSelectText: Bool
  let canForward: Bool
  let canSendAgain: Bool
  let canBlockSender: Bool
  let canSendDM: Bool
  let canShowRepeatDetails: Bool
  let canViewPath: Bool
  let canDelete: Bool
  /// True when the actions sheet shows the path disclosure.
  let showsPathDetail: Bool

  init(message: MessageDTO) {
    // A channel message names its sender only by the "name: " it carried. With none there is no
    // one to mention, so no Reply: a display string ("Unknown") must never go on air as a name.
    let hasChannelSender = message.isChannelMessage && !message.isOutgoing
      && !(message.senderNodeName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    canReply = !message.isOutgoing && (!message.isChannelMessage || hasChannelSender)
    canCopy = true
    canSelectText = !message.text.isEmpty
    canForward = !message.text.isEmpty
    canSendAgain = message.isOutgoing
    canBlockSender = hasChannelSender
    canSendDM = hasChannelSender
    canShowRepeatDetails = message.isOutgoing && message.heardRepeats > 0
    canViewPath = !message.isOutgoing
      && message.isFloodRouted
      && !(message.pathNodes?.isEmpty ?? true)
    canDelete = true
    showsPathDetail = canViewPath || canShowRepeatDetails || (!message.isOutgoing && message.heardRepeats > 0)
  }
}
