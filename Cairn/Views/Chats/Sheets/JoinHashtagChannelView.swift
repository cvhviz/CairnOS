import CairnServices
import SwiftUI

/// View for joining a hashtag channel (public, name-based)
@MainActor
struct JoinHashtagChannelView: View {
  @Environment(\.appState) private var appState

  let availableSlots: [UInt8]
  let onComplete: (ChannelDTO?) -> Void

  @State private var channelName = ""
  @State private var selectedSlot: UInt8
  @State private var isJoining = false
  @State private var errorMessage: String?
  @State private var existingChannels: [ChannelDTO] = []

  private var existingChannel: ChannelDTO? {
    guard !channelName.isEmpty else { return nil }
    let fullName = "#\(channelName)"
    return existingChannels.first {
      $0.name.localizedCaseInsensitiveCompare(fullName) == .orderedSame
    }
  }

  init(availableSlots: [UInt8], onComplete: @escaping (ChannelDTO?) -> Void) {
    self.availableSlots = availableSlots
    self.onComplete = onComplete
    _selectedSlot = State(initialValue: availableSlots.first ?? 1)
  }

  private var isValidName: Bool {
    HashtagUtilities.isValidHashtagName(channelName)
  }

  var body: some View {
    CardForm {
      CardFormSection(
        L10n.Chats.Chats.JoinHashtag.Section.header,
        info: L10n.Chats.Chats.JoinHashtag.footer,
        footer: L10n.Chats.Chats.JoinHashtag.encryptionDescription
      ) {
        HStack {
          Text("#")
            .font(.title2)
            .foregroundStyle(.cyan)
            .accessibilityHidden(true)

          TextField(L10n.Chats.Chats.JoinHashtag.placeholder, text: $channelName)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: channelName) { _, newValue in
              channelName = HashtagUtilities.sanitizeHashtagNameInput(newValue)
            }
        }
        .cardSurface(padding: 12)
      }

      if let errorMessage {
        InlineErrorCard(message: errorMessage)
      }

      VStack(spacing: 8) {
        Button {
          Task {
            guard !isJoining else { return }
            if let existing = existingChannel {
              onComplete(existing)
            } else {
              await joinChannel()
            }
          }
        } label: {
          BusyActionCardLabel(
            title: existingChannel != nil
              ? L10n.Chats.Chats.JoinHashtag.goToButton(channelName)
              : L10n.Chats.Chats.JoinHashtag.joinButton(channelName),
            systemImage: existingChannel != nil ? "arrow.right.circle" : "number",
            color: .cyan,
            isBusy: isJoining
          )
        }
        .buttonStyle(.plain)
        .disabled(!isValidName || (isJoining && existingChannel == nil))
        .accessibilityHint(existingChannel != nil ? L10n.Chats.Chats.JoinHashtag.existingHint : L10n.Chats.Chats.JoinHashtag.newHint)

        if existingChannel != nil {
          Label(L10n.Chats.Chats.JoinHashtag.alreadyJoined, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .accessibilityLabel(L10n.Chats.Chats.JoinHashtag.alreadyJoinedAccessibility)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .flashingNavigationTitle(L10n.Chats.Chats.JoinHashtag.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      guard let radioID = appState.connectedDevice?.radioID,
            let dataStore = appState.services?.dataStore else { return }
      do {
        existingChannels = try await dataStore.fetchChannels(radioID: radioID)
      } catch {
        // Fail open - allow creation if fetch fails
      }
    }
  }

  private func joinChannel() async {
    guard let radioID = appState.connectedDevice?.radioID else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    guard let channelService = appState.services?.channelService else {
      errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
      return
    }

    isJoining = true
    errorMessage = nil

    do {
      // For hashtag channels, hash the full name including "#" prefix
      // to match meshcore spec: sha256("#channelname")[0:16]
      try await channelService.setChannel(
        radioID: radioID,
        index: selectedSlot,
        name: "#\(channelName)",
        passphrase: "#\(channelName)"
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

    isJoining = false
  }
}

#Preview {
  NavigationStack {
    JoinHashtagChannelView(availableSlots: [1, 2, 3], onComplete: { _ in })
  }
  .environment(\.appState, AppState())
}
