@testable import Cairn
import CairnServices
import Testing

@Suite("MessageByteBudget")
struct MessageByteBudgetTests {
  private static let directMax = ProtocolLimits.maxDirectMessageLength

  private static func ascii(_ count: Int) -> String {
    String(repeating: "a", count: count)
  }

  // MARK: - Byte counting

  @Test
  func `ASCII counts one byte per character`() {
    let budget = MessageByteBudget(text: "hello", maxBytes: Self.directMax)
    #expect(budget.usedBytes == 5)
    #expect(budget.remainingBytes == Self.directMax - 5)
  }

  @Test
  func `Multi-byte text counts UTF-8 bytes, not characters`() {
    // "ü" and "ß" are two bytes each, "€" is three.
    #expect(MessageByteBudget(text: "Grüße", maxBytes: Self.directMax).usedBytes == 7)
    #expect(MessageByteBudget(text: "€", maxBytes: Self.directMax).usedBytes == 3)
    #expect(MessageByteBudget(text: "日本語", maxBytes: Self.directMax).usedBytes == 9)
  }

  @Test
  func `Emoji count four or more bytes`() {
    #expect(MessageByteBudget(text: "😀", maxBytes: Self.directMax).usedBytes == 4)
    // Thumbs up plus a skin tone modifier is one character and eight bytes.
    #expect(MessageByteBudget(text: "👍🏽", maxBytes: Self.directMax).usedBytes == 8)
    // Family joined with zero-width joiners is one character and 25 bytes.
    let family = "👨‍👩‍👧‍👦"
    #expect(family.count == 1)
    #expect(MessageByteBudget(text: family, maxBytes: Self.directMax).usedBytes == 25)
  }

  @Test
  func `Inner whitespace and newlines spend bytes`() {
    #expect(MessageByteBudget(text: "a b\nc", maxBytes: Self.directMax).usedBytes == 5)
  }

  @Test
  func `Leading and trailing whitespace is trimmed like the send path`() {
    #expect(MessageByteBudget(text: " a\n", maxBytes: Self.directMax).usedBytes == 1)
    #expect(MessageByteBudget(text: "  \n ", maxBytes: Self.directMax).usedBytes == 0)
    let fits = String(repeating: "x", count: Self.directMax) + "\n\n  "
    #expect(!MessageByteBudget(text: fits, maxBytes: Self.directMax).isOverLimit)
  }

  @Test
  func `Empty draft has the whole budget and no counter`() {
    let budget = MessageByteBudget(text: "", maxBytes: Self.directMax)
    #expect(budget.remainingBytes == Self.directMax)
    #expect(budget.level == .hidden)
    #expect(!budget.isOverLimit)
  }

  // MARK: - Channel name prefix

  @Test
  func `Channel budget shrinks by the sender name and its separator`() {
    let draft = "hello"
    let shortName = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: "Bob".utf8.count)
    let longName = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: "Base Camp 1".utf8.count)

    let short = MessageByteBudget(text: draft, maxBytes: shortName)
    let long = MessageByteBudget(text: draft, maxBytes: longName)

    #expect(short.remainingBytes == 139 - 3 - 2 - 5)
    #expect(long.remainingBytes == 139 - 11 - 2 - 5)
  }

  @Test
  func `Multi-byte sender name spends its UTF-8 bytes`() {
    let name = "Jürgen 📡"
    #expect(name.utf8.count == 12)
    let maxBytes = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: name.utf8.count)
    let budget = MessageByteBudget(text: "", maxBytes: maxBytes)
    #expect(budget.remainingBytes == 125)
  }

  @Test
  func `Draft that fits a direct message can be over a channel budget`() {
    let draft = Self.ascii(140)
    let channelMax = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: 8)
    #expect(!MessageByteBudget(text: draft, maxBytes: Self.directMax).isOverLimit)
    #expect(MessageByteBudget(text: draft, maxBytes: channelMax).isOverLimit)
  }

  // MARK: - Thresholds

  @Test
  func `Counter stays hidden below three quarters of the budget`() {
    // 75% of 150 is 112.5, so 112 bytes is still under.
    let budget = MessageByteBudget(text: Self.ascii(112), maxBytes: 150)
    #expect(budget.level == .hidden)
  }

  @Test
  func `Counter appears once three quarters of the budget is used`() {
    let budget = MessageByteBudget(text: Self.ascii(113), maxBytes: 150)
    #expect(budget.level == .normal)
    #expect(budget.remainingBytes == 37)
  }

  @Test
  func `Counter appears exactly at three quarters when the budget divides evenly`() {
    #expect(MessageByteBudget(text: Self.ascii(74), maxBytes: 100).level == .hidden)
    #expect(MessageByteBudget(text: Self.ascii(75), maxBytes: 100).level == .normal)
  }

  @Test
  func `Eleven bytes remaining is still the normal style`() {
    let budget = MessageByteBudget(text: Self.ascii(139), maxBytes: 150)
    #expect(budget.remainingBytes == 11)
    #expect(budget.level == .normal)
  }

  @Test
  func `Ten bytes remaining switches to the warning style`() {
    let budget = MessageByteBudget(text: Self.ascii(140), maxBytes: 150)
    #expect(budget.remainingBytes == 10)
    #expect(budget.level == .warning)
  }

  @Test
  func `Exactly at the limit is a warning with zero remaining, not over`() {
    let budget = MessageByteBudget(text: Self.ascii(150), maxBytes: 150)
    #expect(budget.remainingBytes == 0)
    #expect(budget.level == .warning)
    #expect(!budget.isOverLimit)
  }

  @Test
  func `One byte past the limit is over with a negative remainder`() {
    let budget = MessageByteBudget(text: Self.ascii(151), maxBytes: 150)
    #expect(budget.remainingBytes == -1)
    #expect(budget.level == .over)
    #expect(budget.isOverLimit)
  }

  @Test
  func `A single emoji can carry a draft across the limit`() {
    let budget = MessageByteBudget(text: Self.ascii(148) + "😀", maxBytes: 150)
    #expect(budget.remainingBytes == -2)
    #expect(budget.level == .over)
  }

  @Test
  func `Over limit matches the send path's rejection rule`() {
    // The send path rejects when `text.utf8.count > maxBytes`.
    for count in [149, 150, 151] {
      let draft = Self.ascii(count)
      let budget = MessageByteBudget(text: draft, maxBytes: Self.directMax)
      #expect(budget.isOverLimit == (draft.utf8.count > Self.directMax))
    }
  }

  @Test
  func `Zero budget reports nothing remaining rather than hiding`() {
    let maxBytes = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: 200)
    let budget = MessageByteBudget(text: "", maxBytes: maxBytes)
    #expect(budget.remainingBytes == 0)
    #expect(budget.level == .warning)
  }
}
