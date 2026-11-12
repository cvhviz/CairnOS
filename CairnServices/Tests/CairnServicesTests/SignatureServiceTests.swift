import CryptoKit
import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("SignatureService")
struct SignatureServiceTests {
  // RFC 8032 section 7.1, TEST 2 (one-byte message 0x72).
  private let rfcPublicKey = SignatureService.parseBytes(
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
  )!
  private let rfcSignature = SignatureService.parseBytes(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
      + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
  )!

  @Test
  func `verifies the RFC 8032 Ed25519 test vector`() {
    #expect(SignatureService.verify(message: Data([0x72]), signature: rfcSignature, publicKey: rfcPublicKey))
  }

  @Test
  func `rejects a modified message`() {
    #expect(!SignatureService.verify(message: Data([0x73]), signature: rfcSignature, publicKey: rfcPublicKey))
  }

  @Test
  func `rejects malformed lengths`() {
    #expect(!SignatureService.verify(message: Data([0x72]), signature: rfcSignature.prefix(63), publicKey: rfcPublicKey))
    #expect(!SignatureService.verify(message: Data([0x72]), signature: rfcSignature, publicKey: rfcPublicKey.prefix(31)))
  }

  @Test
  func `verifies a freshly generated signature over UTF-8 text`() throws {
    let key = Curve25519.Signing.PrivateKey()
    let message = Data("hello mesh ✓".utf8)
    let signature = try key.signature(for: message)
    #expect(SignatureService.verify(
      message: message,
      signature: signature,
      publicKey: key.publicKey.rawRepresentation
    ))
  }

  @Test
  func `parses hex with separators and base64`() {
    #expect(SignatureService.parseBytes("0x0A ff:10") == Data([0x0A, 0xFF, 0x10]))
    #expect(SignatureService.parseBytes(Data([1, 2, 3, 250]).base64EncodedString()) == Data([1, 2, 3, 250]))
    #expect(SignatureService.parseBytes("not valid!") == nil)
    #expect(SignatureService.parseBytes("  ") == nil)
  }

  @Test
  func `verifies typed input and flags malformed input`() throws {
    let key = Curve25519.Signing.PrivateKey()
    let signature = try key.signature(for: Data("hi".utf8))
    let publicKey = key.publicKey.rawRepresentation
    #expect(SignatureService.verify(message: "hi", signatureText: signature.base64EncodedString(), publicKey: publicKey) == true)
    let hex = signature.map { String(format: "%02X", $0) }.joined()
    #expect(SignatureService.verify(message: "hi", signatureText: hex, publicKey: publicKey) == true)
    #expect(SignatureService.verify(message: "hi!", signatureText: hex, publicKey: publicKey) == false)
    #expect(SignatureService.verify(message: "hi", signatureText: "abcd", publicKey: publicKey) == nil)
    #expect(SignatureService.verify(message: "hi", signatureText: hex, publicKey: nil) == nil)
  }

  @Test
  func `sign forwards bytes to the radio session and returns its signature`() async throws {
    let service = SignatureService { data in
      #expect(data == Data("abc".utf8))
      return Data(repeating: 7, count: 64)
    }
    let signature = try await service.sign(text: "abc")
    #expect(signature == Data(repeating: 7, count: 64))
  }

  @Test
  func `sign maps the radio's size limit to messageTooLarge`() async {
    let service = SignatureService { _ in throw MeshCoreError.dataTooLarge(maxSize: 8, actualSize: 9) }
    await #expect(throws: SignatureService.SignatureError.messageTooLarge(maxSize: 8, actualSize: 9)) {
      try await service.sign(text: "123456789")
    }
  }

  @Test
  func `sign rejects empty input and wrong-length signatures`() async {
    let service = SignatureService { _ in Data(repeating: 1, count: 10) }
    await #expect(throws: SignatureService.SignatureError.emptyMessage) { try await service.sign(text: "") }
    await #expect(throws: SignatureService.SignatureError.unexpectedSignatureLength(10)) {
      try await service.sign(text: "x")
    }
  }
}
