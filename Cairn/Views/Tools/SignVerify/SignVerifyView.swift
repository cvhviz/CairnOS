import CairnServices
import SwiftUI
import UIKit

/// Tools > Sign & Verify: sign text with the radio's Ed25519 identity key, or verify a
/// signature against a contact's (or a pasted) public key locally.
struct SignVerifyView: View {
  @Environment(\.appState) private var appState
  @State private var viewModel = SignVerifyViewModel()
  @State private var copyTrigger = 0

  var body: some View {
    CardForm {
      Picker(selection: $viewModel.mode) {
        Text(L10n.Tools.Tools.SignVerify.Mode.sign).tag(SignVerifyViewModel.Mode.sign)
        Text(L10n.Tools.Tools.SignVerify.Mode.verify).tag(SignVerifyViewModel.Mode.verify)
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)

      // How signing or verifying works, for the mode picked above.
      CardFormSection(
        L10n.Tools.Tools.SignVerify.message,
        info: viewModel.mode == .sign ? L10n.Tools.Tools.SignVerify.signFooter : L10n.Tools.Tools.SignVerify.verifyFooter
      ) {
        ContentCard {
          TextField(L10n.Tools.Tools.SignVerify.messagePlaceholder, text: $viewModel.message, axis: .vertical)
            .lineLimit(3...10)
            .autocorrectionDisabled()
        }
      }

      switch viewModel.mode {
      case .sign: signSections
      case .verify: verifySections
      }
    }
    .flashingNavigationTitle(L10n.Tools.Tools.signVerify)
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.success, trigger: copyTrigger)
    .task(id: appState.currentRadioID) {
      viewModel.radioChanged(to: appState.currentRadioID)
      await viewModel.loadContacts(
        store: appState.currentRadioID == nil ? nil : appState.connectionManager.persistenceStore,
        radioID: appState.currentRadioID
      )
      if ownPublicKey != nil, viewModel.signer == .manual, viewModel.manualKeyText.isEmpty {
        viewModel.signer = .thisRadio
      }
    }
    .errorAlert($viewModel.errorMessage)
  }

  private var ownPublicKey: Data? {
    appState.connectedDevice?.publicKey
  }

  // MARK: - Sign

  @ViewBuilder
  private var signSections: some View {
    // Why Sign is dimmed; the explanation of signing is behind the Message header's "i".
    CardFormSection(footer: appState.services == nil ? L10n.Tools.Tools.SignVerify.requiresRadio : nil) {
      Button {
        guard let session = appState.services?.session else { return }
        viewModel.sign(with: SignatureService(session: session), publicKey: ownPublicKey)
      } label: {
        BusyActionCardLabel(
          title: viewModel.isSigning ? L10n.Tools.Tools.SignVerify.signing : L10n.Tools.Tools.SignVerify.signButton,
          systemImage: "signature",
          color: .indigo,
          isBusy: viewModel.isSigning
        )
      }
      .buttonStyle(.plain)
      .disabled(appState.services == nil || viewModel.message.isEmpty || viewModel.isSigning)
    }

    if let signature = viewModel.signature {
      CardFormSection(L10n.Tools.Tools.SignVerify.signature) {
        ContentCard {
          hexText(signature)
          Divider()
          copyButtons(signature)
          if let publicKey = viewModel.signerPublicKey {
            Divider()
            ShareLink(item: L10n.Tools.Tools.SignVerify.shareText(
              viewModel.signedMessage ?? viewModel.message,
              hex(signature),
              hex(publicKey)
            )) {
              Label(L10n.Tools.Tools.SignVerify.share, systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }

    if let publicKey = ownPublicKey {
      CardFormSection(L10n.Tools.Tools.SignVerify.publicKey) {
        ContentCard {
          hexText(publicKey)
          Divider()
          copyButtons(publicKey)
        }
      }
    }
  }

  // MARK: - Verify

  @ViewBuilder
  private var verifySections: some View {
    CardFormSection(L10n.Tools.Tools.SignVerify.signature) {
      ContentCard {
        TextField(L10n.Tools.Tools.SignVerify.signaturePlaceholder, text: $viewModel.signatureText, axis: .vertical)
          .font(.system(.body, design: .monospaced))
          .lineLimit(2...6)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
    }

    CardFormSection(L10n.Tools.Tools.SignVerify.publicKey) {
      PickerCard(
        L10n.Tools.Tools.SignVerify.signer,
        systemImage: "person.badge.key",
        color: .indigo,
        selection: $viewModel.signer
      ) {
        Text(L10n.Tools.Tools.SignVerify.manualKey).tag(SignVerifyViewModel.Signer.manual)
        if ownPublicKey != nil {
          Text(L10n.Tools.Tools.SignVerify.thisRadio).tag(SignVerifyViewModel.Signer.thisRadio)
        }
        ForEach(viewModel.contacts) { contact in
          Text(contact.displayName).tag(SignVerifyViewModel.Signer.contact(contact.id))
        }
      }
      if viewModel.signer == .manual {
        ContentCard {
          TextField(L10n.Tools.Tools.SignVerify.keyPlaceholder, text: $viewModel.manualKeyText, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1...3)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      }
    }

    CardFormSection {
      ActionCard(L10n.Tools.Tools.SignVerify.verifyButton, systemImage: "checkmark.shield", color: .green) {
        viewModel.verify(ownPublicKey: ownPublicKey)
        // The result card appears below the button; announce it so VoiceOver users hear the
        // outcome without hunting for it (also when a re-verify gives the same result).
        if let result = viewModel.verifyResult {
          AccessibilityNotification.Announcement(verifyResultText(result)).post()
        }
      }
      .disabled(viewModel.signatureText.isEmpty)
      .dimmedWhenDisabled()

      if let result = viewModel.verifyResult {
        verifyResultRow(result)
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface(padding: 12)
      }
    }
  }

  private func verifyResultText(_ result: SignVerifyViewModel.VerifyResult) -> String {
    switch result {
    case .valid: L10n.Tools.Tools.SignVerify.valid
    case .invalid: L10n.Tools.Tools.SignVerify.invalid
    case .malformed: L10n.Tools.Tools.SignVerify.invalidInput
    }
  }

  @ViewBuilder
  private func verifyResultRow(_ result: SignVerifyViewModel.VerifyResult) -> some View {
    switch result {
    case .valid:
      Label(L10n.Tools.Tools.SignVerify.valid, systemImage: "checkmark.seal.fill")
        .foregroundStyle(.green)
    case .invalid:
      Label(L10n.Tools.Tools.SignVerify.invalid, systemImage: "xmark.seal.fill")
        .foregroundStyle(.red)
    case .malformed:
      Label(L10n.Tools.Tools.SignVerify.invalidInput, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  // MARK: - Helpers

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private func hexText(_ data: Data) -> some View {
    Text(hex(data))
      .font(.system(.footnote, design: .monospaced))
      .textSelection(.enabled)
  }

  private func copyButtons(_ data: Data) -> some View {
    HStack {
      Button(L10n.Tools.Tools.SignVerify.copyHex) {
        UIPasteboard.general.string = hex(data)
        copyTrigger += 1
      }
      Spacer()
      Button(L10n.Tools.Tools.SignVerify.copyBase64) {
        UIPasteboard.general.string = data.base64EncodedString()
        copyTrigger += 1
      }
    }
    .buttonStyle(.borderless)
  }
}
