import Foundation

/// A MeshCore-style reply split into its parts: the `@[Name]` mention, the `>` quoted line(s)
/// and the reply itself. Companion firmware and apps send a reply as
/// `@[Name]\n>first-10-chars..\n` followed by the text (`MentionUtilities.buildReplyText`), so
/// the bubble can draw the quote as a block instead of a stray `>` line.
public struct ReplyQuote: Sendable, Hashable {
  /// The replied-to node's name, without the `@[` `]` wrapper.
  public let mentionName: String
  /// The quoted preview, without the leading `>`; several quote lines are joined by newlines.
  public let quotedText: String
  /// The reply text after the quote; empty when the reply is only the quote.
  public let body: String

  public init(mentionName: String, quotedText: String, body: String) {
    self.mentionName = mentionName
    self.quotedText = quotedText
    self.body = body
  }

  /// Splits `text` when it opens with a mention followed by at least one `>` quote line.
  /// A plain mention, a quote without a leading mention, or a mention with text on the same
  /// line is not a reply and returns nil, so the text renders as before.
  public static func parse(_ text: String) -> ReplyQuote? {
    // Fast path: almost every message is not a reply.
    guard text.hasPrefix("@[") else { return nil }
    // "\r\n" is one Character in Swift, so normalize before looking for line starts.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.contains("\n>") else { return nil }
    guard let close = normalized.firstIndex(of: "]") else { return nil }
    let nameStart = normalized.index(normalized.startIndex, offsetBy: 2)
    let name = String(normalized[nameStart..<close])
    guard !name.isEmpty, !name.contains("\n"), !name.contains("[") else { return nil }

    // Only spaces may sit between the mention and its line break.
    var lines = normalized[normalized.index(after: close)...].split(separator: "\n", omittingEmptySubsequences: false)
    guard let mentionTail = lines.first, mentionTail.allSatisfy({ $0 == " " }) else { return nil }
    lines.removeFirst()

    var quoteLines: [String] = []
    while let line = lines.first, line.hasPrefix(">") {
      var quote = line.dropFirst()
      if quote.first == " " { quote = quote.dropFirst() }
      quoteLines.append(String(quote))
      lines.removeFirst()
    }
    guard !quoteLines.isEmpty else { return nil }

    let quoted = quoteLines.joined(separator: "\n")
    guard !quoted.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return ReplyQuote(
      mentionName: name,
      quotedText: quoted,
      body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}
