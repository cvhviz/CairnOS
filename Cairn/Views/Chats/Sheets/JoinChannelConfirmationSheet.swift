import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "JoinChannelConfirmationSheet")

/// Confirmation sheet shown when tapping a meshcore://channel/add link in a chat message
@MainActor
struct JoinChannelConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState

  let channelResult: MeshCoreURLParser.ChannelResult
  let onComplete: (ChannelDTO?) -> Void

  @State private var isJoining = false
  @State private var isLoading = true
  @State private var availableSlots: [UInt8] = []
  @State private var errorMessage: String?
  @State private var successTrigger = 0
  @State private var existingChannels: [ChannelDTO] = []
  /// Name to join under; starts as the link's name and is editable only when
  /// that name is already taken on this radio.
  @State private var channelName: String

  init(channelResult: MeshCoreURLParser.ChannelResult, onComplete: @escaping (ChannelDTO?) -> Void) {
    self.channelResult = channelResult
    self.onComplete = onComplete
    _channelName = State(initialValue: channelResult.name)
  }

  /// Same secret is caught before this sheet opens (`ChatLinkRouter`), so only
  /// a name collision with a different channel can remain.
  private var needsRename: Bool {
    PrivateChannelConflict.isNameTaken(channelResult.name, existingChannels: existingChannels)
  }

  private var isMissingDevice: Bool {
    appState.connectedDevice == nil
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if isLoading {
          ProgressView(L10n.Chats.Chats.JoinFromMessage.loading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isMissingDevice {
          ChannelMissingDeviceContent(
            channelName: channelResult.name,
            onDismiss: {
              onComplete(nil)
              dismiss()
            }
          )
        } else if availableSlots.isEmpty {
          ChannelNoSlotsContent(
            channelName: channelResult.name,
            onDismiss: {
              onComplete(nil)
              dismiss()
            }
          )
        } else {
          ChannelJoinConfirmationContent(
            channelResult: channelResult,
            needsRename: needsRename,
            channelName: $channelName,
            isNameTaken: PrivateChannelConflict.isNameTaken(channelName, existingChannels: existingChannels),
            errorMessage: errorMessage,
            isJoining: isJoining,
            onJoin: { Task { await joinChannel() } }
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemGroupedBackground))
      .flashingNavigationTitle(L10n.Chats.Chats.JoinFromMessage.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.Common.cancel) {
            onComplete(nil)
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task {
        await loadAvailableSlots()
      }
      .sensoryFeedback(.success, trigger: successTrigger)
      .sensoryFeedback(.error, trigger: errorMessage)
    }
  }

  // MARK: - Private Methods

  private func loadAvailableSlots() async {
    guard let radioID = appState.connectedDevice?.radioID else {
      isLoading = false
      return
    }

    do {
      existingChannels = try await appState.services?.dataStore.fetchChannels(radioID: radioID) ?? []
      let usedSlots = Set(existingChannels.map(\.index))

      let maxChannels = appState.connectedDevice?.maxChannels ?? 0
      if maxChannels > 1 {
        availableSlots = (1..<maxChannels).filter { !usedSlots.contains($0) }
      }
    } catch {
      logger.error("Failed to load channel slots: \(error)")
    }

    isLoading = false
  }

  private func joinChannel() async {
    guard let radioID = appState.connectedDevice?.radioID else { return }

    guard let channelService = appState.services?.channelService,
          let dataStore = appState.services?.dataStore else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    guard let selectedSlot = availableSlots.first else {
      errorMessage = L10n.Chats.Chats.JoinFromMessage.Error.noSlots
      return
    }

    isJoining = true
    defer { isJoining = false }
    errorMessage = nil

    do {
      try await channelService.setChannelWithSecret(
        radioID: radioID,
        index: selectedSlot,
        name: channelName.trimmingCharacters(in: .whitespacesAndNewlines),
        secret: channelResult.secret
      )

      guard let newChannel = try await dataStore.fetchChannel(radioID: radioID, index: selectedSlot) else {
        errorMessage = L10n.Chats.Chats.JoinFromMessage.Error.loadFailed
        return
      }

      let completed = await ChannelJoinFloodScopeApplier.applyIfNeeded(
        channel: newChannel,
        regionScope: channelResult.regionScope,
        setFloodScope: { channelID, scope in
          try await dataStore.setChannelFloodScope(channelID, floodScope: scope)
        },
        logger: logger
      )

      successTrigger += 1
      onComplete(completed)
      dismiss()
    } catch {
      logger.error("Failed to join channel from link: \(error)")
      errorMessage = error.userFacingMessage
    }
  }
}

// MARK: - Extracted Views

private struct ChannelMissingDeviceContent: View {
  let channelName: String
  let onDismiss: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(L10n.Chats.Chats.JoinFromMessage.NoDevice.title, systemImage: "antenna.radiowaves.left.and.right.slash")
    } description: {
      Text(L10n.Chats.Chats.JoinFromMessage.NoDevice.description(channelName))
    } actions: {
      Button(L10n.Chats.Chats.Common.ok, action: onDismiss)
        .liquidGlassProminentButtonStyle()
    }
  }
}

private struct ChannelNoSlotsContent: View {
  let channelName: String
  let onDismiss: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(L10n.Chats.Chats.JoinFromMessage.NoSlots.title, systemImage: "number.circle.fill")
    } description: {
      Text(L10n.Chats.Chats.JoinFromMessage.NoSlots.description(channelName))
    } actions: {
      Button(L10n.Chats.Chats.Common.ok, action: onDismiss)
        .liquidGlassProminentButtonStyle()
    }
  }
}

private struct ChannelJoinConfirmationContent: View {
  let channelResult: MeshCoreURLParser.ChannelResult
  let needsRename: Bool
  @Binding var channelName: String
  let isNameTaken: Bool
  let errorMessage: String?
  let isJoining: Bool
  let onJoin: () -> Void

  private var isJoinDisabled: Bool {
    isJoining || (needsRename && (isNameTaken || channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
  }

  private var truncatedSecret: String {
    let hex = channelResult.secret.uppercaseHexString()
    guard hex.count >= 16 else { return hex }
    let start = hex.prefix(8)
    let end = hex.suffix(8)
    return "\(start)...\(end)"
  }

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      VStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(.cyan)
            .frame(width: 80, height: 80)

          Image(systemName: "number")
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(.white)
        }

        if needsRename {
          TextField(L10n.Chats.Chats.CreatePrivate.channelName, text: $channelName)
            .textContentType(.name)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .onChange(of: channelName) { _, newValue in
              if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
                channelName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
              }
            }

          if isNameTaken {
            Text(L10n.Chats.Chats.CreatePrivate.Error.nameTaken(channelName))
              .font(.callout)
              .foregroundStyle(.red)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
        } else {
          Text(channelResult.name)
            .font(.title)
            .bold()
        }

        Text(truncatedSecret)
          .font(.caption)
          .monospaced()
          .foregroundStyle(.tertiary)

        if let regionScope = channelResult.regionScope {
          Text(L10n.Chats.Chats.JoinFromMessage.regionScope(regionScope))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        if channelResult.hasHashtagSecretMismatch {
          Text(L10n.Chats.Chats.JoinFromMessage.hashtagSecretMismatch)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.red)
          .padding(.horizontal)
      }

      Button(action: onJoin) {
        if isJoining {
          ProgressView()
        } else {
          Text(L10n.Chats.Chats.JoinPrivate.joinButton)
        }
      }
      .liquidGlassProminentButtonStyle()
      .disabled(isJoinDisabled)
      .padding(.horizontal, 48)
      .padding(.bottom, 32)
    }
  }
}

#Preview {
  let result = MeshCoreURLParser.ChannelResult(
    name: "EmergencyOps",
    secret: Data(repeating: 0xBB, count: 16),
    regionScope: "testregion"
  )
  JoinChannelConfirmationSheet(channelResult: result) { _ in }
    .environment(\.appState, AppState())
    .presentationDetents([.medium, .large])
}
