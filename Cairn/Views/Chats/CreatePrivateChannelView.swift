import CairnServices
import SwiftUI
import UniformTypeIdentifiers

/// View for creating a private channel with auto-generated secret and QR code
struct CreatePrivateChannelView: View {
  @Environment(\.appState) private var appState

  let availableSlots: [UInt8]
  let onComplete: (ChannelDTO?) -> Void

  @State private var channelName = ""
  @State private var selectedSlot: UInt8
  @State private var generatedSecret: Data?
  @State private var isCreating = false
  @State private var createdChannel: ChannelDTO?
  @State private var errorMessage: String?
  @State private var copyHapticTrigger = 0
  @State private var existingChannels: [ChannelDTO] = []

  private var isCreated: Bool {
    createdChannel != nil
  }

  private var isNameTaken: Bool {
    PrivateChannelConflict.isNameTaken(channelName, existingChannels: existingChannels)
  }

  init(availableSlots: [UInt8], onComplete: @escaping (ChannelDTO?) -> Void) {
    self.availableSlots = availableSlots
    self.onComplete = onComplete
    _selectedSlot = State(initialValue: availableSlots.first ?? 1)
  }

  var body: some View {
    CardForm {
      if !isCreated {
        CreateChannelFormContent(
          channelName: $channelName,
          generatedSecret: generatedSecret,
          isNameTaken: isNameTaken,
          isCreating: isCreating,
          errorMessage: errorMessage,
          onCreate: { Task { await createChannel() } }
        )
      } else {
        ShareChannelContent(
          channelName: channelName,
          generatedSecret: generatedSecret,
          copyHapticTrigger: $copyHapticTrigger
        )
      }
    }
    .flashingNavigationTitle(isCreated ? L10n.Chats.Chats.CreatePrivate.titleShare : L10n.Chats.Chats.CreatePrivate.titleCreate)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if isCreated {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Chats.Chats.Common.done) {
            onComplete(createdChannel)
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .onAppear {
      generateSecret()
    }
    .task {
      guard let radioID = appState.connectedDevice?.radioID,
            let dataStore = appState.services?.dataStore else { return }
      // Fail open: without the list, creation proceeds unchecked.
      existingChannels = await (try? dataStore.fetchChannels(radioID: radioID)) ?? []
    }
    .sensoryFeedback(.success, trigger: copyHapticTrigger)
  }

  // MARK: - Private Methods

  private func generateSecret() {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      // Never fall back to the zeroed buffer: the channel would be created with a known key.
      generatedSecret = nil
      errorMessage = L10n.Chats.Chats.CreatePrivate.Error.secretGenerationFailed
      return
    }
    generatedSecret = Data(bytes)
  }

  private func createChannel() async {
    guard let radioID = appState.connectedDevice?.radioID,
          let secret = generatedSecret else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    isCreating = true
    defer { isCreating = false }
    errorMessage = nil

    do {
      guard let channelService = appState.services?.channelService else {
        errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
        return
      }
      try await channelService.setChannelWithSecret(
        radioID: radioID,
        index: selectedSlot,
        name: channelName,
        secret: secret
      )

      // Fetch the created channel to return it
      if let channels = try? await appState.services?.dataStore.fetchChannels(radioID: radioID) {
        createdChannel = channels.first { $0.index == selectedSlot }
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
  }
}

// MARK: - Extracted Views

private struct CreateChannelFormContent: View {
  @Binding var channelName: String
  let generatedSecret: Data?
  let isNameTaken: Bool
  let isCreating: Bool
  let errorMessage: String?
  let onCreate: () -> Void

  var body: some View {
    CardFormSection(L10n.Chats.Chats.CreatePrivate.Section.details) {
      ContentCard {
        TextField(L10n.Chats.Chats.CreatePrivate.channelName, text: $channelName)
          .textContentType(.name)
          .onChange(of: channelName) { _, newValue in
            if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
              channelName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
            }
          }
        if isNameTaken {
          Text(L10n.Chats.Chats.CreatePrivate.Error.nameTaken(channelName))
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    if let secret = generatedSecret {
      CardFormSection(
        L10n.Chats.Chats.CreatePrivate.Section.secret,
        info: L10n.Chats.Chats.CreatePrivate.secretFooter
      ) {
        ContentCard(L10n.Chats.Chats.ChannelInfo.secretKey, systemImage: "key.fill", color: .orange) {
          Text(secret.uppercaseHexString())
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
    }

    if let errorMessage {
      InlineErrorCard(message: errorMessage)
    }

    Button(action: onCreate) {
      BusyActionCardLabel(
        title: L10n.Chats.Chats.CreatePrivate.createButton,
        systemImage: "plus",
        color: .blue,
        isBusy: isCreating
      )
    }
    .buttonStyle(.plain)
    .disabled(channelName.isEmpty || isNameTaken || isCreating || generatedSecret == nil)
  }
}

private struct ShareChannelContent: View {
  let channelName: String
  let generatedSecret: Data?
  @Binding var copyHapticTrigger: Int

  var body: some View {
    VStack(spacing: 16) {
      if let qrImage = generateQRCode() {
        Image(uiImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .foregroundStyle(.primary)
          .frame(width: 200, height: 200)
          .accessibilityLabel(L10n.Localizable.Accessibility.qrCodeFor(channelName))
      }

      Text(channelName)
        .font(.headline)

      Text(L10n.Chats.Chats.ChannelInfo.scanToJoin)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .cardSurface(padding: 16)

    if let secret = generatedSecret {
      CardFormSection(
        L10n.Chats.Chats.CreatePrivate.Section.shareManually,
        info: L10n.Chats.Chats.CreatePrivate.shareManuallyFooter
      ) {
        ContentCard(L10n.Chats.Chats.ChannelInfo.secretKey, systemImage: "key.fill", color: .orange) {
          HStack {
            Text(secret.uppercaseHexString())
              .font(.system(.body, design: .monospaced))

            Spacer()

            Button(L10n.Chats.Chats.ChannelInfo.copy, systemImage: "doc.on.doc") {
              copyHapticTrigger += 1
              UIPasteboard.general.setChannelSecret(secret.uppercaseHexString())
            }
            .labelStyle(.iconOnly)
          }
        }
      }
    }
  }

  private func generateQRCode() -> UIImage? {
    guard let secret = generatedSecret else { return nil }

    let urlString = ChannelService.exportChannelURI(
      name: channelName,
      secret: secret,
      floodScope: .inherit
    )
    return QRCodeGenerator.generate(from: urlString)
  }
}

// MARK: - Channel secret pasteboard

extension UIPasteboard {
  /// How long a copied channel secret stays on the pasteboard.
  private static let channelSecretLifetime: TimeInterval = 120

  /// Copies a channel secret for this device only and with an expiry, so the key neither
  /// syncs through Universal Clipboard nor lingers on the pasteboard.
  func setChannelSecret(_ secret: String) {
    setItems(
      [[UTType.utf8PlainText.identifier: secret]],
      options: [
        .localOnly: true,
        .expirationDate: Date.now.addingTimeInterval(Self.channelSecretLifetime)
      ]
    )
  }
}

#Preview {
  NavigationStack {
    CreatePrivateChannelView(availableSlots: [1, 2, 3], onComplete: { _ in })
  }
  .environment(\.appState, AppState())
}
