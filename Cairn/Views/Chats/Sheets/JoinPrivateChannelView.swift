import CairnServices
import SwiftUI

/// View for joining a private channel by entering name and hex secret key
struct JoinPrivateChannelView: View {
  @Environment(\.appState) private var appState

  let availableSlots: [UInt8]
  let onComplete: (ChannelDTO?) -> Void

  @State private var channelName = ""
  @State private var secretKeyHex = ""
  @State private var selectedSlot: UInt8
  @State private var isJoining = false
  @State private var errorMessage: String?
  @State private var existingChannels: [ChannelDTO] = []

  init(availableSlots: [UInt8], onComplete: @escaping (ChannelDTO?) -> Void) {
    self.availableSlots = availableSlots
    self.onComplete = onComplete
    _selectedSlot = State(initialValue: availableSlots.first ?? 1)
  }

  private var isValidSecret: Bool {
    let cleaned = secretKeyHex.replacing(" ", with: "").uppercased()
    return cleaned.count == ProtocolLimits.channelSecretSize * 2 && cleaned.allSatisfy(\.isHexDigit)
  }

  private var conflict: PrivateChannelConflict? {
    PrivateChannelConflict.check(
      name: channelName,
      secret: isValidSecret ? Data(hexString: secretKeyHex) : nil,
      existingChannels: existingChannels
    )
  }

  /// The channel already using the entered secret; the button opens it instead of re-joining.
  private var alreadyJoinedChannel: ChannelDTO? {
    if case let .alreadyJoined(channel) = conflict { return channel }
    return nil
  }

  private var isJoinDisabled: Bool {
    if isJoining || !isValidSecret { return true }
    switch conflict {
    case .alreadyJoined: return false
    case .nameTaken: return true
    case nil: return channelName.isEmpty
    }
  }

  /// The problem with what's typed so far, shown in red under the fields.
  private var validationMessage: String? {
    if !secretKeyHex.isEmpty, !isValidSecret {
      L10n.Chats.Chats.JoinPrivate.Error.invalidSecret
    } else if conflict == .nameTaken {
      L10n.Chats.Chats.CreatePrivate.Error.nameTaken(channelName)
    } else {
      nil
    }
  }

  var body: some View {
    CardForm {
      CardFormSection(
        L10n.Chats.Chats.CreatePrivate.Section.details,
        info: L10n.Chats.Chats.JoinPrivate.footer
      ) {
        ContentCard {
          TextField(L10n.Chats.Chats.CreatePrivate.channelName, text: $channelName)
            .textContentType(.name)
            .onChange(of: channelName) { _, newValue in
              if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
                channelName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
              }
            }

          Divider()

          TextField(L10n.Chats.Chats.JoinPrivate.secretKeyPlaceholder, text: $secretKeyHex)
            .textContentType(.password)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.characters)
            .onChange(of: secretKeyHex) { _, newValue in
              // Clean and format as user types
              secretKeyHex = newValue.uppercased().filter(\.isHexDigit)
            }

          if let validationMessage {
            Text(validationMessage)
              .font(.footnote)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if let errorMessage {
        InlineErrorCard(message: errorMessage)
      }

      VStack(spacing: 8) {
        Button {
          if let existing = alreadyJoinedChannel {
            onComplete(existing)
          } else {
            Task {
              await joinChannel()
            }
          }
        } label: {
          BusyActionCardLabel(
            title: alreadyJoinedChannel.map { L10n.Chats.Chats.JoinPrivate.goToButton($0.name) }
              ?? L10n.Chats.Chats.JoinPrivate.joinButton,
            systemImage: alreadyJoinedChannel == nil ? "key.fill" : "arrow.right.circle",
            color: .orange,
            isBusy: isJoining
          )
        }
        .buttonStyle(.plain)
        .disabled(isJoinDisabled)

        if alreadyJoinedChannel != nil {
          Label(L10n.Chats.Chats.JoinHashtag.alreadyJoined, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .accessibilityLabel(L10n.Chats.Chats.JoinHashtag.alreadyJoinedAccessibility)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .flashingNavigationTitle(L10n.Chats.Chats.JoinPrivate.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      guard let radioID = appState.connectedDevice?.radioID,
            let dataStore = appState.services?.dataStore else { return }
      // Fail open: without the list, joining proceeds unchecked.
      existingChannels = await (try? dataStore.fetchChannels(radioID: radioID)) ?? []
    }
  }

  private func joinChannel() async {
    guard let radioID = appState.connectedDevice?.radioID else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    guard let secret = Data(hexString: secretKeyHex) else {
      errorMessage = L10n.Chats.Chats.JoinPrivate.Error.invalidFormat
      return
    }

    isJoining = true
    defer { isJoining = false }
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

      // Fetch the joined channel to return it
      var joinedChannel: ChannelDTO?
      if let channels = try? await appState.services?.dataStore.fetchChannels(radioID: radioID) {
        joinedChannel = channels.first { $0.index == selectedSlot }
      }
      onComplete(joinedChannel)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }
}

#Preview {
  NavigationStack {
    JoinPrivateChannelView(availableSlots: [1, 2, 3], onComplete: { _ in })
  }
  .environment(\.appState, AppState())
}
