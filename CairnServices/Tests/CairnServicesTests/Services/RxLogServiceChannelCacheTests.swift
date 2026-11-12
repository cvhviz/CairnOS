import CommonCrypto
import CryptoKit
import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// Covers the channel cache rebuild tolerating duplicate slot rows, and the
/// device private key not outliving the connection it was exported for.
@Suite("RxLogService channel cache and key lifetime")
struct RxLogServiceChannelCacheTests {
  private func makeService() throws -> RxLogService {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let dataStore = PersistenceStore(modelContainer: container)
    let session = MeshCoreSession(transport: MockTransport())
    return RxLogService(session: session, dataStore: dataStore, heardRepeatsService: nil)
  }

  // MARK: - Duplicate channel slots

  @Test
  func `duplicate channel slot rows keep the first row instead of trapping`() async throws {
    let service = try makeService()
    let radioID = UUID()
    let firstSecret = Data(repeating: 0x11, count: 16)
    let secondSecret = Data(repeating: 0x22, count: 16)

    await service.updateChannels(from: [
      ChannelDTO.testChannel(radioID: radioID, index: 1, name: "First", secret: firstSecret),
      ChannelDTO.testChannel(radioID: radioID, index: 1, name: "Second", secret: secondSecret)
    ])

    let fromFirst = await service.decryptEntry(
      Self.channelEntry(radioID: radioID, text: "hello", secret: firstSecret)
    )
    #expect(fromFirst.decryptStatus == .success)
    #expect(fromFirst.channelIndex == 1)
    #expect(fromFirst.channelName == "First")

    let fromSecond = await service.decryptEntry(
      Self.channelEntry(radioID: radioID, text: "hello", secret: secondSecret)
    )
    #expect(fromSecond.decodedText == nil, "The later duplicate row must not replace the first")
  }

  // MARK: - Private key lifetime

  @Test
  func `stopping event monitoring drops the device private key`() async throws {
    let service = try makeService()
    await service.updatePrivateKey(Data(repeating: 0x07, count: 64))
    #expect(await service.hasPrivateKey)

    await service.stopEventMonitoring()

    #expect(await service.hasPrivateKey == false)
  }

  // MARK: - Helpers

  private static func channelEntry(radioID: UUID, text: String, secret: Data) -> RxLogEntryDTO {
    let payload = encryptedChannelPayload(timestamp: 1_700_000_000, text: text, secret: secret)
    let parsed = ParsedRxLogData(
      snr: 8.0,
      rssi: -70,
      rawPayload: payload,
      routeType: .flood,
      payloadType: .groupText,
      payloadVersion: 0,
      payloadTypeBits: 0,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: payload
    )
    return RxLogEntryDTO(radioID: radioID, from: parsed, decryptStatus: .noMatchingKey)
  }

  /// Builds a wire-format channel payload (`[channelHash:1][MAC:2][ciphertext:N]`)
  /// that `ChannelCrypto.decrypt` accepts: AES-128 ECB ciphertext authenticated
  /// with a truncated HMAC-SHA256, mirroring the firmware's encrypt-then-MAC.
  private static func encryptedChannelPayload(timestamp: UInt32, text: String, secret: Data) -> Data {
    var plaintext = withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }
    plaintext.append(0)
    plaintext.append(Data(text.utf8))
    let blockSize = kCCBlockSizeAES128
    let paddedCount = (plaintext.count + blockSize - 1) / blockSize * blockSize
    plaintext.append(Data(count: paddedCount - plaintext.count))

    var ciphertext = Data(count: plaintext.count)
    var encryptedCount: size_t = 0
    let keyBytes = secret.prefix(kCCKeySizeAES128)
    let status = ciphertext.withUnsafeMutableBytes { outPtr in
      plaintext.withUnsafeBytes { inPtr in
        keyBytes.withUnsafeBytes { keyPtr in
          CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            keyPtr.baseAddress, kCCKeySizeAES128,
            nil,
            inPtr.baseAddress, plaintext.count,
            outPtr.baseAddress, plaintext.count,
            &encryptedCount
          )
        }
      }
    }
    precondition(status == kCCSuccess, "test fixture encryption failed")

    let mac = Data(
      HMAC<SHA256>.authenticationCode(for: ciphertext, using: SymmetricKey(data: secret))
        .prefix(ChannelCrypto.macSize)
    )
    return Data([0x00]) + mac + ciphertext.prefix(encryptedCount)
  }
}
