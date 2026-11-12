import Foundation

public struct MessageTextPayload: Sendable, Hashable {
  public let raw: String
  public let formatted: AttributedString?
  public let baseColor: BaseColorSlot
  public let isOutgoing: Bool
  /// Nil means no Translation offer row. `raw` / `formatted` always describe
  /// the stored original; the view chooses the visible body from `phase`.
  public let translation: MessageTranslationChrome?
  /// Set when the text is a MeshCore reply (`@[Name]\n>quote\n` + text). `formatted` then
  /// holds only the reply's own text; the bubble draws the quote as a block above it.
  public let replyQuote: ReplyQuote?
  /// The quote block's `@Name` header, styled and linked as an in-text mention.
  public let replyHeader: AttributedString?

  public init(
    raw: String,
    formatted: AttributedString?,
    baseColor: BaseColorSlot,
    isOutgoing: Bool,
    translation: MessageTranslationChrome? = nil,
    replyQuote: ReplyQuote? = nil,
    replyHeader: AttributedString? = nil
  ) {
    self.raw = raw
    self.formatted = formatted
    self.baseColor = baseColor
    self.isOutgoing = isOutgoing
    self.translation = translation
    self.replyQuote = replyQuote
    self.replyHeader = replyHeader
  }
}
