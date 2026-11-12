import Foundation
import CairnServices

/// State for the Sign & Verify tool. Signing needs the radio (its private key never
/// leaves the device); verification is local Ed25519 and works offline.
@Observable
@MainActor
final class SignVerifyViewModel {
  enum Mode: Hashable {
    case sign
    case verify
  }

  enum Signer: Hashable {
    case thisRadio
    case manual
    case contact(UUID)
  }

  enum VerifyResult: Equatable {
    case valid
    case invalid
    case malformed
  }

  var mode: Mode = .sign
  var message = "" {
    didSet {
      if message != oldValue {
        signature = nil
        verifyResult = nil
      }
    }
  }

  // Sign
  private(set) var isSigning = false
  private(set) var signature: Data?
  private(set) var signedMessage: String?
  /// Key of the radio that made `signature`, so sharing never pairs it with another radio's key.
  private(set) var signerPublicKey: Data?
  var errorMessage: String?

  // Verify
  var signatureText = "" {
    didSet { verifyResult = nil }
  }

  var signer: Signer = .manual {
    didSet { verifyResult = nil }
  }

  var manualKeyText = "" {
    didSet { verifyResult = nil }
  }

  private(set) var verifyResult: VerifyResult?
  private(set) var contacts: [ContactDTO] = []

  private var radioID: UUID?
  /// Bumped on a radio change so a sign request still in flight for the old radio is dropped.
  private var radioGeneration = 0

  /// Drops the previous radio's signature when the connected radio changes.
  func radioChanged(to newRadioID: UUID?) {
    guard newRadioID != radioID else { return }
    radioID = newRadioID
    radioGeneration += 1
    signature = nil
    signedMessage = nil
    signerPublicKey = nil
  }

  func loadContacts(store: PersistenceStore?, radioID: UUID?) async {
    guard let store, let radioID else {
      contacts = []
      return
    }
    let fetched = (try? await store.fetchContacts(radioID: radioID)) ?? []
    contacts = fetched.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  func sign(with service: SignatureService, publicKey: Data?) {
    guard !isSigning else { return }
    let text = message
    let generation = radioGeneration
    isSigning = true
    errorMessage = nil
    Task {
      defer { isSigning = false }
      do {
        let signed = try await service.sign(text: text)
        // Editing the field mid-request already cleared the signature; this one is for other text.
        guard message == text, generation == radioGeneration else { return }
        signature = signed
        signedMessage = text
        signerPublicKey = publicKey
      } catch let SignatureService.SignatureError.messageTooLarge(maxSize, _) {
        guard generation == radioGeneration else { return }
        errorMessage = L10n.Tools.Tools.SignVerify.Error.tooLarge(maxSize)
      } catch {
        guard generation == radioGeneration else { return }
        errorMessage = L10n.Tools.Tools.SignVerify.Error.failed(error.userFacingMessage)
      }
    }
  }

  func verify(ownPublicKey: Data?) {
    let key: Data? = switch signer {
    case .thisRadio: ownPublicKey
    case .manual: SignatureService.parseBytes(manualKeyText)
    case let .contact(id): contacts.first { $0.id == id }?.publicKey
    }
    verifyResult = switch SignatureService.verify(message: message, signatureText: signatureText, publicKey: key) {
    case .some(true): .valid
    case .some(false): .invalid
    case .none: .malformed
    }
  }
}
