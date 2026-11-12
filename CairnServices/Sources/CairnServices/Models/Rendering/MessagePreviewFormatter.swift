import Foundation

/// The one-line text a message shows outside its bubble: list rows, the Home Chats card,
/// notification bodies, the Live Activity and what Siri reads.
///
/// The bubble draws `@[Name]` as `@Name` and a MeshCore reply (`@[Name]\n>quote..\nbody`) as a
/// quote block. Everywhere else got the raw wire text, so a row read `@[Basecamp]` and a reply
/// showed only its first line. This applies the same two rules, as plain text:
/// - a reply shows its body; a reply with no body shows `@Name`, who it answers
/// - every other `@[Name]` reads `@Name`
/// Line breaks fold to spaces, since every caller shows one line.
///
/// Display only: stored text, mention matching and reaction hashing keep the raw wire text. The
/// mention keeps the wire name (the advertised name), as the bubble does.
public enum MessagePreviewFormatter {
  public static func preview(_ text: String) -> String {
    let source: String
    if let reply = ReplyQuote.parse(text) {
      source = reply.body.isEmpty ? MentionUtilities.createMention(for: reply.mentionName) : reply.body
    } else {
      source = text
    }
    return foldLines(plainMentions(in: source))
  }

  /// `@[Name]` → `@Name`.
  public static func plainMentions(in text: String) -> String {
    guard text.contains("@["), let regex = MentionUtilities.mentionRegex else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "@$1")
  }

  private static func foldLines(_ text: String) -> String {
    guard text.contains(where: \.isNewline) else { return text }
    return text
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
