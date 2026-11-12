import CairnServices
import SwiftUI

/// Shared identity review for a contact QR scan and a `meshcore://contact/add` chat link.
struct ContactAddConfirmationContent: View {
  let contactResult: MeshCoreURLParser.ContactResult
  let existingContact: ContactDTO?
  let errorMessage: String?
  let isAdding: Bool
  let onAdd: () -> Void
  let onScanAgain: (() -> Void)?

  var displayedName: String {
    existingContact?.displayName ?? contactResult.name
  }

  private var displayedType: ContactType {
    existingContact?.type ?? contactResult.contactType
  }

  var scannedAsName: String? {
    guard existingContact != nil, contactResult.name != displayedName else { return nil }
    return contactResult.name
  }

  var scannedAsText: String? {
    scannedAsName.map { L10n.Contacts.Contacts.Add.scannedAs($0) }
  }

  var publicKeyText: String {
    contactResult.publicKey.uppercaseHexString(separator: " ")
  }

  var showsScanAgain: Bool {
    onScanAgain != nil
  }

  var hidesIdentityGlyph: Bool {
    true
  }

  var body: some View {
    CardForm {
      identitySection
      publicKeySection
      if let errorMessage {
        errorSection(errorMessage)
      }
      addSection
      if showsScanAgain, let onScanAgain {
        scanAgainSection(onScanAgain)
      }
    }
  }

  private var identitySection: some View {
    VStack(spacing: 12) {
      identityGlyph
        .accessibilityHidden(hidesIdentityGlyph)

      Text(displayedName)
        .font(.headline)

      Text(displayedType.localizedName)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let scannedAsText {
        Text(scannedAsText)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }

  @ViewBuilder
  private var identityGlyph: some View {
    switch displayedType {
    case .chat:
      if let existingContact {
        ContactAvatar(contact: existingContact, size: Constants.identityGlyphSize)
      } else {
        ContactAvatar(name: displayedName, size: Constants.identityGlyphSize)
      }
    case .repeater, .room:
      if let existingContact {
        ContactTypeAvatar(contact: existingContact, size: Constants.identityGlyphSize)
      } else {
        NodeAvatar(
          publicKey: contactResult.publicKey,
          role: displayedType == .room ? .roomServer : .repeater,
          size: Constants.identityGlyphSize
        )
      }
    }
  }

  /// Name is claimed; the public key is the verifiable identity.
  private var publicKeySection: some View {
    CardFormSection(L10n.Contacts.Contacts.Add.publicKey) {
      Text(publicKeyText)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .cardSurface(padding: 12)
    }
  }

  private func errorSection(_ message: String) -> some View {
    InlineErrorCard(message: message)
  }

  private var addSection: some View {
    Button(action: onAdd) {
      if isAdding {
        ProgressView()
          .frame(maxWidth: .infinity)
      } else {
        Text(primaryButtonTitle)
          .frame(maxWidth: .infinity)
      }
    }
    .liquidGlassProminentButtonStyle()
    .controlSize(.large)
    .disabled(isAdding)
    .accessibilityLabel(primaryAccessibilityLabel)
  }

  private var primaryButtonTitle: String {
    existingContact == nil
      ? L10n.Contacts.Contacts.Add.add
      : L10n.Contacts.Contacts.Add.view
  }

  var primaryAccessibilityLabel: String {
    if isAdding {
      L10n.Contacts.Contacts.Scan.importing
    } else if let existingContact {
      L10n.Contacts.Contacts.Add.viewAccessibility(existingContact.displayName)
    } else {
      L10n.Contacts.Contacts.Add.add
    }
  }

  private func scanAgainSection(_ action: @escaping () -> Void) -> some View {
    ActionCard(L10n.Contacts.Contacts.Scan.scanAgain, systemImage: "qrcode.viewfinder", color: .purple, action: action)
      .disabled(isAdding)
  }
}

private enum Constants {
  static let identityGlyphSize: CGFloat = 56
}

#Preview("Repeater") {
  NavigationStack {
    ContactAddConfirmationContent(
      contactResult: MeshCoreURLParser.ContactResult(
        name: "Example Repeater",
        publicKey: Data(repeating: 0xAA, count: 32),
        contactType: .repeater
      ),
      existingContact: nil,
      errorMessage: nil,
      isAdding: false,
      onAdd: {},
      onScanAgain: {}
    )
    .flashingNavigationTitle(L10n.Contacts.Contacts.Add.nodeTitle)
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Already added") {
  NavigationStack {
    ContactAddConfirmationContent(
      contactResult: MeshCoreURLParser.ContactResult(
        name: "Claimed Name",
        publicKey: Data(repeating: 0xAA, count: 32),
        contactType: .repeater
      ),
      existingContact: ContactDTO(
        id: UUID(),
        radioID: UUID(),
        publicKey: Data(repeating: 0xAA, count: 32),
        name: "Saved Repeater",
        typeRawValue: ContactType.repeater.rawValue,
        flags: 0,
        outPathLength: 0,
        outPath: Data(),
        lastAdvertTimestamp: 0,
        latitude: 0,
        longitude: 0,
        lastModified: 0,
        lastHeardTimestamp: nil,
        nickname: nil,
        isBlocked: false,
        isMuted: false,
        isFavorite: false,
        lastMessageDate: nil,
        unreadCount: 0
      ),
      errorMessage: nil,
      isAdding: false,
      onAdd: {},
      onScanAgain: {}
    )
    .flashingNavigationTitle("Saved Repeater")
    .navigationBarTitleDisplayMode(.inline)
  }
}
