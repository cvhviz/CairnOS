import CryptoKit
import Foundation
import MeshCore

/// Signs data with the connected radio's identity key and verifies MeshCore signatures.
///
/// The companion firmware signs the raw bytes it receives (`CMD_SIGN_START` /
/// `CMD_SIGN_DATA` / `CMD_SIGN_FINISH`) with `ed25519_sign` over the node's identity
/// key, so signatures are standard 64-byte Ed25519 over the unhashed message and
/// verify against the node's 32-byte public key with any Ed25519 implementation.
public actor SignatureService {
  public enum SignatureError: Error, Equatable, Sendable {
    case emptyMessage
    case messageTooLarge(maxSize: Int, actualSize: Int)
    case unexpectedSignatureLength(Int)
    case session(String)
  }

  /// Ed25519 signature size in bytes.
  public static let signatureSize = 64
  /// Ed25519 public key size in bytes.
  public static let publicKeySize = 32

  private let signer: @Sendable (Data) async throws -> Data

  public init(session: any ConfigurationSessionOps) {
    signer = { data in try await session.sign(data) }
  }

  /// Injects the signing step directly (tests, simulator).
  init(signer: @escaping @Sendable (Data) async throws -> Data) {
    self.signer = signer
  }

  /// Signs the UTF-8 bytes of `text` with the radio's private key.
  public func sign(text: String) async throws -> Data {
    try await sign(Data(text.utf8))
  }

  /// Signs raw bytes with the radio's private key. Returns the 64-byte Ed25519 signature.
  public func sign(_ data: Data) async throws -> Data {
    guard !data.isEmpty else { throw SignatureError.emptyMessage }
    let signature: Data
    do {
      signature = try await signer(data)
    } catch let MeshCoreError.dataTooLarge(maxSize, actualSize) {
      throw SignatureError.messageTooLarge(maxSize: maxSize, actualSize: actualSize)
    } catch {
      throw SignatureError.session(error.localizedDescription)
    }
    guard signature.count == Self.signatureSize else {
      throw SignatureError.unexpectedSignatureLength(signature.count)
    }
    return signature
  }

  /// Verifies an Ed25519 `signature` over `message` against a 32-byte `publicKey`.
  /// Works offline; returns false for malformed keys or signatures.
  public static func verify(message: Data, signature: Data, publicKey: Data) -> Bool {
    guard signature.count == signatureSize, publicKey.count == publicKeySize,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
      return false
    }
    return key.isValidSignature(signature, for: message)
  }

  /// Verifies user input: the UTF-8 `message`, a typed `signatureText` (hex or Base64)
  /// and the signer's key. Returns nil when the signature or key is malformed.
  public static func verify(message: String, signatureText: String, publicKey: Data?) -> Bool? {
    guard let signature = parseBytes(signatureText), signature.count == signatureSize,
          let publicKey, publicKey.count == publicKeySize else {
      return nil
    }
    return verify(message: Data(message.utf8), signature: signature, publicKey: publicKey)
  }

  /// Parses a signature or key typed as hex (spaces, colons and `0x` allowed) or base64.
  public static func parseBytes(_ text: String) -> Data? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var hex = trimmed.lowercased()
    if hex.hasPrefix("0x") { hex.removeFirst(2) }
    hex.removeAll { $0 == " " || $0 == ":" || $0 == "\n" || $0 == "-" }
    if hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) {
      var bytes = Data(capacity: hex.count / 2)
      var index = hex.startIndex
      while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
      }
      return bytes
    }
    return Data(base64Encoded: trimmed.filter { !$0.isWhitespace })
  }
}
