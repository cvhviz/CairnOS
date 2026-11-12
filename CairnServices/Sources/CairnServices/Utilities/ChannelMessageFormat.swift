import Foundation

/// The one parser for the `"NodeName: MessageText"` text inside a decrypted group (channel)
/// payload. Firmware, stock MeshCore and Cairn alike, builds it in
/// `BaseChatMesh::sendGroupMessage` as `sprintf("%s: ", sender_name)` followed by the text, and
/// does not filter `:` out of node names. So the separator is the first `": "` (colon then space),
/// never the first `:`: a node named `KD2ABC:Base` sends `"KD2ABC:Base: hello"`.
///
/// Every consumer that derives a sender or a deduplication key from channel text goes through
/// here (live receive, RX-log correlation, heard repeats, own-transmission matching), so the key
/// saved with a message and the key rebuilt later from an RX-log row always agree. It is a pure
/// function of the text on purpose: it must not depend on the contact list.
///
/// Matches Cairn firmware's `splitSender` (ui-sf32/ui-l2 `Format.cpp`): no sender when the text
/// has no `": "`, when the prefix is empty, or when the prefix is longer than a node name can be.
public enum ChannelMessageFormat {
  /// Longest sender prefix accepted, in UTF-8 bytes. `node_name` is a 32-byte field, and Cairn
  /// firmware's `splitSender` rejects a prefix longer than this. A longer prefix is a sentence
  /// that happens to contain `": "` from a client that sends no name.
  public static let maxSenderNameBytes = 32

  /// The `": "` separator firmware writes between the node name and the text.
  public static let separator = ": "

  /// Parses `"NodeName: MessageText"` from a decrypted channel message.
  /// - Parameter text: The full decrypted channel message text
  /// - Returns: The sender name and the message text, or nil when the text carries no sender
  public static func parse(_ text: String) -> (senderName: String, messageText: String)? {
    guard let range = text.range(of: separator) else { return nil }
    let rawSender = text[..<range.lowerBound]
    guard rawSender.utf8.count <= maxSenderNameBytes else { return nil }
    let senderName = rawSender.trimmingCharacters(in: .whitespaces)
    guard !senderName.isEmpty else { return nil }
    // Whitespace is trimmed from the body as it always was, so a stored row's deduplication key
    // (which hashes the body) still matches the same message arriving again from history.
    let messageText = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    return (senderName, messageText)
  }

  /// The sender and text of a channel message, or no sender and the text unchanged when it
  /// carries none (another client, a raw group packet).
  public static func split(_ text: String) -> (senderNodeName: String?, messageText: String) {
    if let parsed = parse(text) {
      return (parsed.senderName, parsed.messageText)
    }
    return (nil, text)
  }
}
