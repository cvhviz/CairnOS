import CairnServices
import Foundation

/// Pure rules for forwarding a message into another conversation's draft.
enum ForwardedDraft {
  /// The draft the target conversation should hold after a forward: the
  /// forwarded text alone, or appended on a new line when the user already has
  /// an unsent draft there, so forwarding never discards what they typed.
  static func merged(existing: String?, forwarded: String) -> String {
    guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return forwarded
    }
    return existing + "\n" + forwarded
  }

  /// The text a forward puts in the draft: the original message, named after who wrote it, e.g.
  /// "Fwd from Frank Wilson: on the ridge". Plain text, not an `@[mention]`, so forwarding into
  /// a conversation the author is in doesn't ping them and doesn't read as a reply. A forwarded
  /// reply keeps only its reply, not the `@[Name]` / `>quote` prefix, which would otherwise read
  /// as the user's own reply to that name. With no known author (the user's own message, or a
  /// channel message that carried no name) the text goes as it is.
  /// - Parameters:
  ///   - sender: The author's name as the mesh knows it (the advertised name), or nil.
  ///   - format: Joins author and text; the app passes its localized form.
  static func attributed(
    text: String,
    sender: String?,
    format: (_ sender: String, _ text: String) -> String
  ) -> String {
    let body: String = if let reply = ReplyQuote.parse(text) {
      reply.body.isEmpty ? reply.quotedText : reply.body
    } else {
      text
    }
    guard let sender, !sender.isEmpty else { return body }
    return format(sender, body)
  }
}
