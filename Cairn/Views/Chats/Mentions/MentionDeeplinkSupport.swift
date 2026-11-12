import Foundation

/// Single source of truth for the `cairn://mention/<name>` deep link that
/// `MessageText` produces and `ChatConversationView` consumes. Centralising the
/// scheme, host, and percent-encoding here keeps the producer and consumer from
/// diverging — a mismatch would route a mention tap to the wrong contact.
enum MentionDeeplinkSupport {
  static let scheme = "cairn"
  static let host = "mention"

  /// `/` is removed from the allowed set so a name containing a slash is
  /// percent-encoded into a single path component instead of splitting the
  /// URL path (which would drop everything before the last slash).
  private static let nameAllowed = CharacterSet.urlPathAllowed
    .subtracting(CharacterSet(charactersIn: "/"))

  /// Builds `cairn://mention/<percent-encoded-name>` for a mention run,
  /// or `nil` if the name cannot be encoded or is empty.
  static func url(forName name: String) -> URL? {
    guard let encoded = name.addingPercentEncoding(withAllowedCharacters: nameAllowed),
          !encoded.isEmpty else {
      return nil
    }
    return URL(string: "\(scheme)://\(host)/\(encoded)")
  }

  /// Returns the decoded mention name if `url` is a mention deep link, else
  /// `nil`. Reads the still-encoded path and decodes it exactly once;
  /// `lastPathComponent` is avoided because it decodes `%2F` back to `/` and
  /// then re-splits, dropping everything before the slash.
  static func name(from url: URL) -> String? {
    guard url.scheme == scheme, url.host == host else { return nil }
    var encodedPath = url.path(percentEncoded: true)
    if encodedPath.hasPrefix("/") {
      encodedPath.removeFirst()
    }
    guard !encodedPath.isEmpty,
          let decoded = encodedPath.removingPercentEncoding,
          !decoded.isEmpty else {
      return nil
    }
    return decoded
  }

  static let nodeHost = "node"

  /// `cairn://node/<hex key prefix>`: a node named by its key prefix (a room post's author), so a
  /// tap opens the node with that key rather than whatever node a shown name matches.
  static func url(forKeyPrefix prefix: Data) -> URL? {
    guard !prefix.isEmpty else { return nil }
    let hex = prefix.map { String(format: "%02X", $0) }.joined()
    return URL(string: "\(scheme)://\(nodeHost)/\(hex)")
  }

  /// The key prefix a `cairn://node/...` link names, else nil.
  static func keyPrefix(from url: URL) -> Data? {
    guard url.scheme == scheme, url.host == nodeHost else { return nil }
    var hex = url.path(percentEncoded: false)
    if hex.hasPrefix("/") { hex.removeFirst() }
    guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.count <= 64 else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return Data(bytes)
  }
}
