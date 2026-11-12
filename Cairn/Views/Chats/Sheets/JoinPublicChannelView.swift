import CairnServices
import SwiftUI

/// View for re-adding the public channel on slot 0
struct JoinPublicChannelView: View {
  @Environment(\.appState) private var appState

  let onComplete: (ChannelDTO?) -> Void

  @State private var isJoining = false
  @State private var errorMessage: String?

  var body: some View {
    CardForm {
      VStack(spacing: 12) {
        Image(systemName: "globe")
          .font(.system(size: 48))
          .foregroundStyle(.green)
          .accessibilityHidden(true)

        Text(L10n.Chats.Chats.JoinPublic.channelName)
          .font(.title3.bold())

        Text(L10n.Chats.Chats.JoinPublic.description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .cardSurface(padding: 16)

      if let errorMessage {
        InlineErrorCard(message: errorMessage)
      }

      Button {
        Task {
          await joinPublicChannel()
        }
      } label: {
        BusyActionCardLabel(
          title: L10n.Chats.Chats.JoinPublic.addButton,
          systemImage: "plus",
          color: .green,
          isBusy: isJoining
        )
      }
      .buttonStyle(.plain)
      .disabled(isJoining)
    }
    .flashingNavigationTitle(L10n.Chats.Chats.JoinPublic.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func joinPublicChannel() async {
    guard let radioID = appState.connectedDevice?.radioID else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    isJoining = true
    errorMessage = nil

    do {
      guard let channelService = appState.services?.channelService else {
        errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
        return
      }
      let maxChannels = appState.connectedDevice?.maxChannels ?? 1
      let index = try await channelService.setupPublicChannel(radioID: radioID, maxChannels: maxChannels)

      // Fetch the public channel (the slot it went to) to return it
      var publicChannel: ChannelDTO?
      if let channels = try? await appState.services?.dataStore.fetchChannels(radioID: radioID) {
        publicChannel = channels.first { $0.index == index }
      }
      onComplete(publicChannel)
    } catch {
      errorMessage = error.userFacingMessage
    }

    isJoining = false
  }
}

#Preview {
  NavigationStack {
    JoinPublicChannelView(onComplete: { _ in })
  }
  .environment(\.appState, AppState())
}
