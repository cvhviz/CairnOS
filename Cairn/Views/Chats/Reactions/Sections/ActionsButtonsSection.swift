import CairnServices
import SwiftUI

/// The message's actions as tiles: Reply (or Mention), Send DM, Copy, Select Text, Select,
/// Forward, Translate, Send Again, each where the message allows it.
struct ActionsButtonsSection: View {
  let availability: MessageActionAvailability
  let onSelectAction: (MessageAction) -> Void

  @AppStorage(AppStorageKey.replyWithQuote.rawValue) private var replyWithQuote = AppStorageKey.defaultReplyWithQuote

  var body: some View {
    MessageActionGrid(items: items)
  }

  private var items: [MessageActionItem] {
    let strings = L10n.Chats.Chats.Message.Action.self
    var items: [MessageActionItem] = []
    func add(_ id: String, _ title: String, _ icon: String, _ action: MessageAction) {
      items.append(MessageActionItem(id: id, title: title, icon: icon) { onSelectAction(action) })
    }
    if availability.canReply {
      add("reply", replyWithQuote ? strings.reply : strings.mention, "arrowshape.turn.up.left", .reply)
    }
    if availability.canSendDM { add("sendDM", strings.sendDM, "bubble.left.and.bubble.right", .sendDM) }
    add("copy", strings.copy, "doc.on.doc", .copy)
    if availability.canSelectText { add("selectText", strings.selectText, "character.cursor.ibeam", .selectText) }
    add("select", strings.select, "checkmark.circle", .select)
    if availability.canForward { add("forward", strings.forward, "arrowshape.turn.up.right", .forward) }
    add("translate", strings.translate, "translate", .translate)
    if availability.canSendAgain { add("sendAgain", strings.sendAgain, "arrow.uturn.forward", .sendAgain) }
    return items
  }
}
