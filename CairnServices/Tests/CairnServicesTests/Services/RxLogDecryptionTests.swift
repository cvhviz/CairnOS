import CommonCrypto
import CryptoKit
import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

@Suite("RxLogService decryption")
struct RxLogDecryptionTests {
  // MARK: - Channel payloads

  @Test
  func `channel payload decrypts with the matching secret`() {
    let secret = Data(repeating: 0x42, count: 16)
    let payload = Self.channelPayload(timestamp: 1_700_000_000, text: "Bob: hi", secret: secret)
    let outcome = RxLogService.decryptChannelPayload(
      payload,
      secrets: [0: Data(repeating: 0x99, count: 16), 4: secret],
      names: [4: "#test"]
    )
    #expect(outcome.status == .success)
    #expect(outcome.channelIndex == 4)
    #expect(outcome.channelName == "#test")
    #expect(outcome.timestamp == 1_700_000_000)
    #expect(outcome.text == "Bob: hi")
  }

  @Test
  func `channel payload without a known key reports noMatchingKey`() {
    let payload = Self.channelPayload(timestamp: 1, text: "x", secret: Data(repeating: 0x42, count: 16))
    let outcome = RxLogService.decryptChannelPayload(
      payload,
      secrets: [0: Data(repeating: 0x99, count: 16)],
      names: [:]
    )
    #expect(outcome.status == .noMatchingKey)
    #expect(outcome.text == nil)
  }

  @Test
  func `tampered payload whose hash byte matches a known key reports hmacFailed`() {
    let secret = Data(repeating: 0x42, count: 16)
    var payload = Self.channelPayload(timestamp: 1, text: "hello", secret: secret)
    payload[payload.count - 1] ^= 0xFF
    let outcome = RxLogService.decryptChannelPayload(payload, secrets: [2: secret], names: [:])
    #expect(outcome.status == .hmacFailed)
  }

  @Test
  func `truncated channel payload with keys reports decryptFailed, not pending`() {
    let outcome = RxLogService.decryptChannelPayload(
      Data([0x01, 0x02, 0x03]),
      secrets: [0: Data(repeating: 0x42, count: 16)],
      names: [:]
    )
    #expect(outcome.status == .decryptFailed)
  }

  @Test
  func `channel hash byte is the first SHA-256 byte of the secret`() {
    let secret = Data(repeating: 0x42, count: 16)
    let expected = Array(SHA256.hash(data: secret))[0]
    #expect(RxLogService.channelHashByte(for: secret) == expected)
  }

  // MARK: - Direct messages

  @Test
  func `DM decrypts using the sender prefix key`() throws {
    let me = Curve25519.KeyAgreement.PrivateKey()
    let contact = Curve25519.KeyAgreement.PrivateKey()
    let shared = try Self.sharedSecret(me, contact.publicKey)
    let payload = Self.dmPayload(dest: 0x11, src: 0x22, timestamp: 1234, text: "ping", sharedSecret: shared)

    let result = RxLogService.tryDecryptDM(
      payload: payload,
      myPrivateKey: me.rawRepresentation,
      contactPublicKeysByPrefix: [0x22: [contact.publicKey.rawRepresentation]]
    )
    #expect(result?.timestamp == 1234)
    #expect(result?.text == "ping")
    #expect(result?.publicKey == contact.publicKey.rawRepresentation)
  }

  @Test
  func `own outgoing DM decrypts using the destination prefix key`() throws {
    let me = Curve25519.KeyAgreement.PrivateKey()
    let contact = Curve25519.KeyAgreement.PrivateKey()
    let shared = try Self.sharedSecret(me, contact.publicKey)
    // Sent by us (src 0x11) to the contact (dest 0x22).
    let payload = Self.dmPayload(dest: 0x22, src: 0x11, timestamp: 99, text: "echo", sharedSecret: shared)

    let result = RxLogService.tryDecryptDM(
      payload: payload,
      myPrivateKey: me.rawRepresentation,
      contactPublicKeysByPrefix: [0x22: [contact.publicKey.rawRepresentation]]
    )
    #expect(result?.text == "echo")
  }

  @Test
  func `DM with an unknown contact does not decrypt`() throws {
    let me = Curve25519.KeyAgreement.PrivateKey()
    let contact = Curve25519.KeyAgreement.PrivateKey()
    let other = Curve25519.KeyAgreement.PrivateKey()
    let shared = try Self.sharedSecret(me, contact.publicKey)
    let payload = Self.dmPayload(dest: 0x11, src: 0x22, timestamp: 1, text: "x", sharedSecret: shared)

    let result = RxLogService.tryDecryptDM(
      payload: payload,
      myPrivateKey: me.rawRepresentation,
      contactPublicKeysByPrefix: [0x22: [other.publicKey.rawRepresentation]]
    )
    #expect(result == nil)
  }

  // MARK: - Service level

  @Test
  func `decryptEntry marks a previously undecryptable channel entry as decrypted`() async throws {
    let radioID = UUID()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let dataStore = PersistenceStore(modelContainer: container)
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: dataStore,
      heardRepeatsService: nil
    )
    let secret = Data(repeating: 0x42, count: 16)
    await service.updateChannels(secrets: [1: secret], names: [1: "Mesh"])

    let payload = Self.channelPayload(timestamp: 42, text: "Ann: yo", secret: secret)
    let entry = RxLogEntryDTO(
      radioID: radioID,
      from: Self.parsed(payloadType: .groupText, routeType: .flood, payload: payload),
      decryptStatus: .noMatchingKey
    )
    let decoded = await service.decryptEntry(entry)
    #expect(decoded.decryptStatus == .success)
    #expect(decoded.decodedText == "Ann: yo")
    #expect(decoded.channelName == "Mesh")
  }

  @Test
  func `decryptEntry names the contact whose key decrypted a direct message`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: PersistenceStore(modelContainer: container),
      heardRepeatsService: nil
    )
    let me = Curve25519.KeyAgreement.PrivateKey()
    let contactKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    let contactX25519 = try #require(Ed25519ToX25519.convertPublicKey(contactKey))
    let shared = try Self.sharedSecret(me, Curve25519.KeyAgreement.PublicKey(rawRepresentation: contactX25519))
    await service.updatePrivateKey(me.rawRepresentation + Data(count: 32))
    await service.updateContactPublicKeys([contactKey[0]: [contactKey]])

    let payload = Self.dmPayload(dest: 0x11, src: contactKey[0], timestamp: 7, text: "hey", sharedSecret: shared)
    let entry = RxLogEntryDTO(
      radioID: UUID(),
      from: Self.parsed(payloadType: .textMessage, routeType: .flood, payload: payload),
      decryptStatus: .dmNoMatchingKey
    )
    let decoded = await service.decryptEntry(entry)
    #expect(decoded.decodedText == "hey")
    #expect(decoded.peerPublicKey == contactKey)
  }

  // MARK: - Fixtures

  static func parsed(payloadType: PayloadType, routeType: RouteType, payload: Data) -> ParsedRxLogData {
    ParsedRxLogData(
      snr: 5,
      rssi: -80,
      rawPayload: payload,
      routeType: routeType,
      payloadType: payloadType,
      payloadVersion: 0,
      payloadTypeBits: 0,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: payload
    )
  }

  static func sharedSecret(
    _ mine: Curve25519.KeyAgreement.PrivateKey,
    _ theirs: Curve25519.KeyAgreement.PublicKey
  ) throws -> Data {
    try mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
  }

  static func aesECB(_ plaintext: Data, key: Data) -> Data {
    var padded = plaintext
    let blockSize = kCCBlockSizeAES128
    padded.append(Data(count: (blockSize - padded.count % blockSize) % blockSize))
    var out = Data(count: padded.count)
    var written: size_t = 0
    let keyBytes = key.prefix(kCCKeySizeAES128)
    let status = out.withUnsafeMutableBytes { outPtr in
      padded.withUnsafeBytes { inPtr in
        keyBytes.withUnsafeBytes { keyPtr in
          CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            keyPtr.baseAddress, kCCKeySizeAES128, nil,
            inPtr.baseAddress, padded.count, outPtr.baseAddress, padded.count, &written
          )
        }
      }
    }
    precondition(status == kCCSuccess)
    return out.prefix(written)
  }

  static func mac(_ data: Data, key: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).prefix(2))
  }

  /// `[channelHash:1][MAC:2][ciphertext]`, plaintext `[timestamp:4][txtType:1][text]`.
  static func channelPayload(timestamp: UInt32, text: String, secret: Data) -> Data {
    var plaintext = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
    plaintext.append(0)
    plaintext.append(Data(text.utf8))
    let ciphertext = aesECB(plaintext, key: secret)
    let hashByte = RxLogService.channelHashByte(for: secret)
    return Data([hashByte]) + mac(ciphertext, key: secret) + ciphertext
  }

  /// `[dest:1][src:1][MAC:2][ciphertext]`, plaintext `[timestamp:4][typeAttempt:1][text]`.
  static func dmPayload(dest: UInt8, src: UInt8, timestamp: UInt32, text: String, sharedSecret: Data) -> Data {
    var plaintext = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
    plaintext.append(0)
    plaintext.append(Data(text.utf8))
    let ciphertext = aesECB(plaintext, key: sharedSecret)
    return Data([dest, src]) + mac(ciphertext, key: sharedSecret) + ciphertext
  }
}
