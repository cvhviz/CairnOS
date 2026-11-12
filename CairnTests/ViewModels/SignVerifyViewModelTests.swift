import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("SignVerifyViewModel")
@MainActor
struct SignVerifyViewModelTests {
  /// Parks the signing step until released, so a test can edit the field mid-request.
  private actor GatedSigner {
    private var gate: CheckedContinuation<Void, Never>?
    private var entered = false

    func sign(_: Data) async -> Data {
      entered = true
      await withCheckedContinuation { gate = $0 }
      return Data(repeating: 0xAB, count: SignatureService.signatureSize)
    }

    var hasEntered: Bool { entered }

    func release() {
      gate?.resume()
      gate = nil
    }
  }

  private static let radioA = UUID()
  private static let keyA = Data(repeating: 0x0A, count: 32)

  private func startSigning(_ text: String) async throws -> (SignVerifyViewModel, GatedSigner) {
    let signer = GatedSigner()
    let viewModel = SignVerifyViewModel()
    viewModel.radioChanged(to: Self.radioA)
    viewModel.message = text
    viewModel.sign(with: SignatureService(signer: { await signer.sign($0) }), publicKey: Self.keyA)
    try await waitUntil("signing should reach the radio") { await signer.hasEntered }
    return (viewModel, signer)
  }

  @Test
  func `signing keeps the signature for the text that was signed`() async throws {
    let (viewModel, signer) = try await startSigning("hello")

    await signer.release()
    try await waitUntil("signing should finish") { !viewModel.isSigning }

    #expect(viewModel.signature == Data(repeating: 0xAB, count: SignatureService.signatureSize))
    #expect(viewModel.signedMessage == "hello")
    #expect(viewModel.signerPublicKey == Self.keyA)
  }

  @Test
  func `a radio change drops the previous radio's signature`() async throws {
    let (viewModel, signer) = try await startSigning("hello")
    await signer.release()
    try await waitUntil("signing should finish") { !viewModel.isSigning }

    viewModel.radioChanged(to: Self.radioA)
    #expect(viewModel.signature != nil)

    viewModel.radioChanged(to: UUID())
    #expect(viewModel.signature == nil)
    #expect(viewModel.signedMessage == nil)
    #expect(viewModel.signerPublicKey == nil)
  }

  @Test
  func `a signature that finishes after a radio change is dropped`() async throws {
    let (viewModel, signer) = try await startSigning("hello")

    viewModel.radioChanged(to: UUID())
    await signer.release()
    try await waitUntil("signing should finish") { !viewModel.isSigning }

    #expect(viewModel.signature == nil)
    #expect(viewModel.signerPublicKey == nil)
    #expect(viewModel.errorMessage == nil)
  }

  @Test
  func `a signature for text edited mid-request is dropped`() async throws {
    let (viewModel, signer) = try await startSigning("hello")

    viewModel.message = "hello world"
    await signer.release()
    try await waitUntil("signing should finish") { !viewModel.isSigning }

    #expect(viewModel.signature == nil)
    #expect(viewModel.signedMessage == nil)
    #expect(viewModel.errorMessage == nil)
  }
}
