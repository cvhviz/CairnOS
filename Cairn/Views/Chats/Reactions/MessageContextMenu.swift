import CairnServices
import UIKit

/// Native right-click menu for a message bubble on Mac. Mirrors the actions sheet's buttons,
/// with the quick reactions in a submenu; "Details and More…" opens the full sheet for the
/// emoji picker and path details, which don't fit a menu.
@MainActor
enum MessageContextMenu {
  static func make(
    availability: MessageActionAvailability,
    replyWithQuote: Bool,
    recentEmojis: [String],
    onAction: @escaping (MessageAction) -> Void,
    onMore: @escaping () -> Void
  ) -> UIMenu {
    typealias Strings = L10n.Chats.Chats.Message.Action

    func item(_ title: String, _ icon: String, _ action: MessageAction, destructive: Bool = false) -> UIAction {
      UIAction(
        title: title,
        image: UIImage(systemName: icon),
        attributes: destructive ? .destructive : []
      ) { _ in onAction(action) }
    }

    let reactions = UIMenu(
      title: Strings.react,
      image: UIImage(systemName: "face.smiling"),
      children: recentEmojis.prefix(8).map { emoji in
        UIAction(title: emoji) { _ in onAction(.react(emoji)) }
      }
    )

    var primary: [UIMenuElement] = []
    if availability.canReply {
      primary.append(item(replyWithQuote ? Strings.reply : Strings.mention, "arrowshape.turn.up.left", .reply))
    }
    if availability.canSendDM {
      primary.append(item(Strings.sendDM, "bubble.left.and.bubble.right", .sendDM))
    }
    primary.append(item(Strings.copy, "doc.on.doc", .copy))
    if availability.canSelectText {
      primary.append(item(Strings.selectText, "character.cursor.ibeam", .selectText))
    }
    primary.append(item(Strings.select, "checkmark.circle", .select))
    if availability.canForward {
      primary.append(item(Strings.forward, "arrowshape.turn.up.right", .forward))
    }
    primary.append(item(Strings.translate, "translate", .translate))
    if availability.canSendAgain {
      primary.append(item(Strings.sendAgain, "arrow.uturn.forward", .sendAgain))
    }

    var destructive: [UIMenuElement] = []
    if availability.canBlockSender {
      destructive.append(item(Strings.blockSender, "hand.raised", .blockSender, destructive: true))
    }
    if availability.canDelete {
      destructive.append(item(Strings.delete, "trash", .delete, destructive: true))
    }

    let more = UIAction(title: Strings.moreActions, image: UIImage(systemName: "ellipsis.circle")) { _ in onMore() }

    return UIMenu(children: [
      UIMenu(options: .displayInline, children: recentEmojis.isEmpty ? [] : [reactions]),
      UIMenu(options: .displayInline, children: primary),
      UIMenu(options: .displayInline, children: [more]),
      UIMenu(options: .displayInline, children: destructive)
    ])
  }
}
