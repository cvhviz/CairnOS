import Foundation
import CairnServices

enum ContactShareContent {
  static func compactPublicKeyHex(_ publicKey: Data) -> String {
    publicKey.uppercaseHexString()
  }

  /// The first and last four bytes, enough to tell keys apart at a glance: "A1B2C3D4…E5F60718".
  static func shortPublicKeyHex(_ publicKey: Data) -> String {
    let hex = compactPublicKeyHex(publicKey)
    guard hex.count > 16 else { return hex }
    return "\(hex.prefix(8))\u{2026}\(hex.suffix(8))"
  }

  static func uri(name: String, publicKey: Data, type: ContactType) -> String {
    ContactService.exportContactURI(name: name, publicKey: publicKey, type: type)
  }
}
