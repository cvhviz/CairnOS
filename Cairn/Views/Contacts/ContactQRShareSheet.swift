import CairnServices
import SwiftUI

/// Sheet for sharing a contact via QR code
struct ContactQRShareSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  let contactName: String
  let publicKey: Data
  let contactType: ContactType

  @State private var showCopyFeedback = false
  @State private var qrImage: UIImage?
  @State private var copyHapticTrigger = 0

  private var contactURI: String {
    ContactShareContent.uri(name: contactName, publicKey: publicKey, type: contactType)
  }

  var body: some View {
    NavigationStack {
      CardForm {
        QRCodeSection(contactName: contactName, qrImage: qrImage)

        ContactInfoSection(publicKey: publicKey)

        ActionsSection(
          contactURI: contactURI,
          showCopyFeedback: $showCopyFeedback,
          copyToClipboard: copyToClipboard
        )
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.Qr.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Contacts.Contacts.Common.done) {
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .onAppear {
        qrImage = generateQRCode()
      }
      .sensoryFeedback(.success, trigger: copyHapticTrigger)
    }
    .presentationBackground(theme.canvasColor ?? Color(.systemGroupedBackground))
  }

  // MARK: - Private Methods

  private func generateQRCode() -> UIImage? {
    QRCodeGenerator.generate(
      from: contactURI, scale: Constants.qrScale, correctionLevel: Constants.qrCorrectionLevel
    )
  }

  private func copyToClipboard() {
    copyHapticTrigger += 1
    UIPasteboard.general.string = ContactShareContent.compactPublicKeyHex(publicKey)
    showCopyFeedback = true

    Task {
      try? await Task.sleep(for: Constants.copyFeedbackDuration)
      showCopyFeedback = false
    }
  }
}

// MARK: - Constants

private enum Constants {
  static let qrScale = 10.0
  static let qrCorrectionLevel = "M"
  static let copyFeedbackDuration = Duration.seconds(2)
  static let qrCodeSize: CGFloat = 200
}

// MARK: - QR Code Section

private struct QRCodeSection: View {
  let contactName: String
  let qrImage: UIImage?

  var body: some View {
    VStack(spacing: 12) {
      if let qrImage {
        Image(uiImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .foregroundStyle(.primary)
          .frame(width: Constants.qrCodeSize, height: Constants.qrCodeSize)
          .accessibilityLabel(L10n.Localizable.Accessibility.qrCodeFor(contactName))
      }

      Text(contactName)
        .font(.title2)
        .bold()
    }
    .frame(maxWidth: .infinity)
    .cardSurface(padding: 16)
  }
}

// MARK: - Contact Info Section

private struct ContactInfoSection: View {
  let publicKey: Data

  var body: some View {
    CardFormSection(L10n.Contacts.Contacts.Add.publicKey) {
      Text(publicKey.uppercaseHexString(separator: " "))
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .cardSurface(padding: 12)
    }
  }
}

// MARK: - Actions Section

private struct ActionsSection: View {
  let contactURI: String
  @Binding var showCopyFeedback: Bool
  let copyToClipboard: () -> Void

  @State private var showShareSheet = false

  var body: some View {
    VStack(spacing: CardStyle.spacing) {
      ActionCard(
        showCopyFeedback ? L10n.Contacts.Contacts.Qr.copied : L10n.Contacts.Contacts.Qr.copy,
        systemImage: showCopyFeedback ? "checkmark" : "doc.on.doc",
        color: showCopyFeedback ? .green : .blue,
        action: copyToClipboard
      )
      .disabled(showCopyFeedback)

      ActionCard(L10n.Contacts.Contacts.Qr.share, systemImage: "square.and.arrow.up", color: .blue) {
        showShareSheet = true
      }
      .sheet(isPresented: $showShareSheet) {
        ActivityView(activityItems: [
          ContactURIActivityItem(
            uri: contactURI,
            subject: L10n.Contacts.Contacts.Qr.shareSubject
          )
        ])
      }
    }
  }
}
