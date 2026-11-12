import Foundation

/// UTF-8 byte accounting for a compose draft against the limit the send path enforces.
///
/// `maxBytes` is `ProtocolLimits.maxDirectMessageLength` for direct messages and
/// `ProtocolLimits.maxChannelMessageLength(nodeNameByteCount:)` for channels, where the
/// sender-name prefix has already been taken out of the budget. A flood scope rides in the
/// packet header as transport codes, outside the text payload, and both limits are fixed
/// with that room reserved, so a scope costs the draft nothing.
struct MessageByteBudget: Equatable {
  enum Level: Equatable {
    /// Plenty of room left, so the counter stays out of the way.
    case hidden
    case normal
    case warning
    case over
  }

  /// Percentage of the budget a draft uses before the counter appears.
  static let visibleUsagePercent = 75
  /// Remaining bytes at or below which the counter switches to its warning style.
  static let warningRemainingBytes = 10

  let usedBytes: Int
  let maxBytes: Int

  /// Counts the draft as the send path will transmit it: leading and trailing whitespace is
  /// trimmed before sending, so it costs nothing here either.
  init(text: String, maxBytes: Int) {
    usedBytes = text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
    self.maxBytes = maxBytes
  }

  /// Negative once the draft is over the limit.
  var remainingBytes: Int {
    maxBytes - usedBytes
  }

  var isOverLimit: Bool {
    remainingBytes < 0
  }

  var level: Level {
    if isOverLimit {
      return .over
    }
    if remainingBytes <= Self.warningRemainingBytes {
      return .warning
    }
    if usedBytes * 100 >= maxBytes * Self.visibleUsagePercent {
      return .normal
    }
    return .hidden
  }
}
