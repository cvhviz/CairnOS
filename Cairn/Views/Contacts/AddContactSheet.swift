import CairnServices
import os
import SwiftUI

/// Sheet for manually adding a contact or scanning a QR code
struct AddContactSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var selectedType: ContactType = .chat
  @State private var contactName = ""
  @State private var publicKeyHex = ""
  @State private var showScanner = false
  @State private var isSubmitting = false
  @State private var errorMessage: String?

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "AddContactSheet")

  // MARK: - Validation

  private var normalizedPublicKeyHex: String {
    publicKeyHex.filter(\.isHexDigit).lowercased()
  }

  private var isValidPublicKey: Bool {
    normalizedPublicKeyHex.count == Constants.publicKeyHexLength
  }

  private var canAdd: Bool {
    !contactName.isEmpty && isValidPublicKey && !isSubmitting
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      CardForm {
        // Said up front rather than on Add: the form still works, so a key can be pasted and
        // checked now and added once a radio is connected.
        if appState.connectedDevice == nil {
          NotConnectedBanner()
        }

        ScannerSection(showScanner: $showScanner)

        TypePickerSection(selectedType: $selectedType)

        NameInputSection(contactName: $contactName)

        PublicKeyInputSection(
          publicKeyHex: $publicKeyHex,
          normalizedCount: normalizedPublicKeyHex.count,
          isValid: isValidPublicKey
        )

        PasteURLSection { result in
          contactName = result.name
          publicKeyHex = result.publicKey.hexString
          selectedType = result.contactType
          errorMessage = nil
        }

        if let errorMessage {
          ErrorSection(message: errorMessage)
        }
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.Add.nodeTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Contacts.Contacts.Add.add) {
            Task {
              await handleAdd()
            }
          }
          .disabled(!canAdd)
          .keyboardShortcut(.defaultAction)
        }
      }
      .navigationDestination(isPresented: $showScanner) {
        ScanContactQRView { contact in
          appState.navigation.navigateToContactDetail(contact)
          showScanner = false
          dismiss()
        }
      }
      .disabled(isSubmitting)
    }
  }

  // MARK: - Actions

  @MainActor
  private func handleAdd() async {
    guard let services = appState.services,
          let device = appState.connectedDevice else {
      logger.error("Services or device not available")
      errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }

    let radioID = device.radioID
    let maxContacts = device.maxContacts

    guard let publicKeyData = Data(hexString: normalizedPublicKeyHex) else {
      logger.error("Failed to convert hex string to data: \(normalizedPublicKeyHex)")
      errorMessage = L10n.Contacts.Contacts.Add.Error.invalidFormat
      return
    }

    guard publicKeyData.count == ProtocolLimits.publicKeySize else {
      logger.error("Public key is not \(ProtocolLimits.publicKeySize) bytes: \(publicKeyData.count)")
      errorMessage = L10n.Contacts.Contacts.Add.Error.invalidSize(ProtocolLimits.publicKeySize, Constants.publicKeyHexLength)
      return
    }

    isSubmitting = true
    errorMessage = nil

    do {
      let currentTimestamp = UInt32(Date.now.timeIntervalSince1970)

      let contactFrame = ContactFrame(
        publicKey: publicKeyData,
        type: selectedType,
        flags: 0,
        outPathLength: PacketBuilder.floodPathSentinel,
        outPath: Data(),
        name: contactName,
        lastAdvertTimestamp: 0, // Never advertised
        latitude: 0,
        longitude: 0,
        lastModified: currentTimestamp
      )

      logger.info("Adding contact: \(contactName) (\(publicKeyData.hexString))")
      try await services.contactService.addOrUpdateContact(radioID: radioID, contact: contactFrame)
      logger.info("Contact added successfully")

      dismiss()
    } catch ContactServiceError.contactTableFull {
      logger.error("Node list is full")
      errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFull(Int(maxContacts))
      isSubmitting = false
    } catch {
      logger.error("Failed to add contact: \(error.localizedDescription)")
      errorMessage = "\(L10n.Contacts.Contacts.Common.error): \(error.userFacingMessage)"
      isSubmitting = false
    }
  }
}

// MARK: - Constants

private enum Constants {
  static let publicKeyHexLength = ProtocolLimits.publicKeySize * 2
}

// MARK: - Scanner Section

private struct ScannerSection: View {
  @Binding var showScanner: Bool

  var body: some View {
    ActionCard(L10n.Contacts.Contacts.Add.scanQR, systemImage: "qrcode.viewfinder", color: .purple) {
      showScanner = true
    }
  }
}

// MARK: - Type Picker Section

private struct TypePickerSection: View {
  @Binding var selectedType: ContactType

  var body: some View {
    CardFormSection(L10n.Contacts.Contacts.Add.type) {
      Picker(L10n.Contacts.Contacts.Add.type, selection: $selectedType) {
        Text(L10n.Contacts.Contacts.NodeKind.chat).tag(ContactType.chat)
        Text(L10n.Contacts.Contacts.NodeKind.repeater).tag(ContactType.repeater)
        Text(L10n.Contacts.Contacts.NodeKind.room).tag(ContactType.room)
      }
      .pickerStyle(.segmented)
    }
  }
}

// MARK: - Name Input Section

private struct NameInputSection: View {
  @Binding var contactName: String

  var body: some View {
    CardFormSection(L10n.Contacts.Contacts.Add.name) {
      ContentCard {
        TextField(L10n.Contacts.Contacts.Add.contactName, text: $contactName)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
          .onChange(of: contactName) { _, newValue in
            if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
              contactName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
            }
          }
      }
    }
  }
}

// MARK: - Public Key Input Section

private struct PublicKeyInputSection: View {
  @Binding var publicKeyHex: String
  let normalizedCount: Int
  let isValid: Bool

  var body: some View {
    CardFormSection(
      L10n.Contacts.Contacts.Add.publicKey,
      info: L10n.Contacts.Contacts.Add.publicKeyFooter(Constants.publicKeyHexLength)
    ) {
      ContentCard {
        TextField(L10n.Contacts.Contacts.Add.hexPlaceholder(Constants.publicKeyHexLength), text: $publicKeyHex)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.asciiCapable)
          .font(.system(.body, design: .monospaced))
          .onChange(of: publicKeyHex) { _, newValue in
            // Filter to hex chars only and lowercase
            let filtered = newValue.filter(\.isHexDigit).lowercased()
            if filtered != newValue {
              publicKeyHex = filtered
            }
          }

        if !publicKeyHex.isEmpty {
          HStack {
            if isValid {
              Label(L10n.Contacts.Contacts.Add.valid, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              Label(L10n.Contacts.Contacts.Add.characterCount(normalizedCount, Constants.publicKeyHexLength), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
          }
          .font(.caption)
        }
      }
    }
  }
}

// MARK: - Error Section

private struct ErrorSection: View {
  let message: String

  var body: some View {
    Text(message)
      .foregroundStyle(.red)
      .font(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)
  }
}

/// Across the top of the form while no radio is connected: the add needs one, the form doesn't.
private struct NotConnectedBanner: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "antenna.radiowaves.left.and.right.slash")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(L10n.Contacts.Contacts.Add.notConnectedBanner)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 12)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Paste URL Section

private struct PasteURLSection: View {
  let onParsed: (MeshCoreURLParser.ContactResult) -> Void

  @State private var showError = false

  var body: some View {
    CardFormSection(footer: L10n.Contacts.Contacts.Add.pasteURLFooter) {
      ActionCard(L10n.Contacts.Contacts.Add.pasteURL, systemImage: "doc.on.clipboard", color: .blue) {
        guard let clipboard = UIPasteboard.general.string,
              let result = MeshCoreURLParser.parseContactURL(clipboard) else {
          showError = true
          return
        }
        showError = false
        onParsed(result)
      }

      if showError {
        Text(L10n.Contacts.Contacts.Add.Error.invalidURL)
          .foregroundStyle(.red)
          .font(.caption)
          .padding(.horizontal, 4)
      }
    }
  }
}

#Preview {
  AddContactSheet()
    .environment(\.appState, AppState())
}
