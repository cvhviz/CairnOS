import SwiftUI

/// Block Sender and Delete, side by side as red tiles at the foot of the sheet, under the
/// details, so neither sits where a reach for an everyday action lands.
struct ActionsDestructiveSection: View {
  let availability: MessageActionAvailability
  let onSelectAction: (MessageAction) -> Void

  var body: some View {
    MessageActionGrid(items: items)
      .padding(.top, 16)
      .padding(.bottom, 16)
  }

  private var items: [MessageActionItem] {
    let strings = L10n.Chats.Chats.Message.Action.self
    var items: [MessageActionItem] = []
    if availability.canBlockSender {
      items.append(MessageActionItem(id: "blockSender", title: strings.blockSender, icon: "hand.raised", isDestructive: true) {
        onSelectAction(.blockSender)
      })
    }
    if availability.canDelete {
      items.append(MessageActionItem(id: "delete", title: strings.delete, icon: "trash", isDestructive: true) {
        onSelectAction(.delete)
      })
    }
    return items
  }
}
