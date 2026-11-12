import CryptoKit
import Foundation

/// Single source of truth for content-based deduplication key generation.
/// Used by SyncCoordinator (live sync) and PersistenceStore+Backup (export/import).
enum DeduplicationKey {
  static let channelPrefix = "ch-"
  static let directMessagePrefix = "dm-"
  static let outgoingIdentityPrefix = "out-"
  static let unknownContactPlaceholder = "unknown"

  static func contentBased(
    contactID: UUID?,
    channelIndex: UInt8?,
    senderNodeName: String?,
    timestamp: UInt32,
    content: String
  ) -> String {
    let contentHash = SHA256.hash(data: Data(content.utf8))
    let hashPrefix = contentHash.prefix(4).map { String(format: "%02X", $0) }.joined()
    if let channelIndex {
      return "\(channelPrefix)\(channelIndex)-\(timestamp)-\(senderNodeName ?? "")-\(hashPrefix)"
    }
    let contactSegment = contactID?.uuidString ?? unknownContactPlaceholder
    return "\(directMessagePrefix)\(contactSegment)-\(timestamp)-\(hashPrefix)"
  }

  static let radioSentPrefix = "radio-sent|"

  /// Key for a message sent from the radio's own UI (Cairn sent-message echo):
  /// `radio-sent|dm:<prefix hex>|<timestamp>|<hash>` or `radio-sent|ch:<index>|<timestamp>|<hash>`.
  /// Stable across a live push, a queued copy and a snapshot replay of the same message.
  static func radioSent(destination: Data, channelIndex: UInt8?, timestamp: UInt32, content: String) -> String {
    let contentHash = SHA256.hash(data: Data(content.utf8))
    let hashPrefix = contentHash.prefix(4).map { String(format: "%02X", $0) }.joined()
    let conversation = if let channelIndex {
      "ch:\(channelIndex)"
    } else {
      "dm:" + destination.prefix(6).map { String(format: "%02X", $0) }.joined()
    }
    return "\(radioSentPrefix)\(conversation)|\(timestamp)|\(hashPrefix)"
  }
}
