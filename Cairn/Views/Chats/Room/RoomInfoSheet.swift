import CairnServices
import SwiftUI

private typealias Strings = L10n.RemoteNodes.RemoteNodes.Room

struct RoomInfoSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.chatViewModel) private var viewModel
  @Environment(\.appState) private var appState

  let session: RemoteNodeSessionDTO
  /// Called after the room's stored messages were cleared, so the presenter can reload.
  var onMessagesCleared: (() async -> Void)?

  @State private var notificationLevel: NotificationLevel
  @State private var isFavorite: Bool
  @State private var notificationTask: Task<Void, Never>?
  @State private var favoriteTask: Task<Void, Never>?
  @State private var showTelemetry = false
  @State private var showSettings = false
  @State private var headerHeight: CGFloat = 80
  @State private var showingClearMessagesConfirmation = false
  @State private var isClearingMessages = false
  @State private var errorMessage: String?

  init(session: RemoteNodeSessionDTO, onMessagesCleared: (() async -> Void)? = nil) {
    self.session = session
    self.onMessagesCleared = onMessagesCleared
    _notificationLevel = State(initialValue: session.notificationLevel)
    _isFavorite = State(initialValue: session.isFavorite)
  }

  var body: some View {
    NavigationStack {
      CardForm {
        // Compact header with the everyday actions as cards beneath it
        VStack(spacing: ConversationInfoLayout.headerSpacing) {
          ConversationInfoHeader(
            title: session.name,
            subtitle: L10n.RemoteNodes.RemoteNodes.Auth.typeRoom,
            measuredHeight: $headerHeight
          ) {
            NodeAvatar(publicKey: session.publicKey, role: .roomServer, size: ConversationInfoLayout.avatarSize)
          }
          .padding(.horizontal, 4)

          ConversationActionCardRow {
            FavoriteActionCard(isFavorite: $isFavorite)
            NotificationLevelActionCard(
              selection: $notificationLevel,
              availableLevels: NotificationLevel.roomLevels
            )
            // Telemetry and management need a live session with the room.
            if session.isConnected {
              ConversationActionCard(
                title: L10n.Contacts.Contacts.Detail.telemetry,
                systemImage: "chart.line.uptrend.xyaxis"
              ) { showTelemetry = true }
              if session.isAdmin {
                ConversationActionCard(
                  title: L10n.Contacts.Contacts.Detail.management,
                  systemImage: "gearshape.2"
                ) { showSettings = true }
              }
            }
          }
        }
        .onChange(of: notificationLevel) { _, newValue in
          notificationTask?.cancel()
          notificationTask = Task {
            await viewModel?.setNotificationLevel(.room(session), level: newValue)
          }
        }
        .onChange(of: isFavorite) { _, newValue in
          favoriteTask?.cancel()
          favoriteTask = Task {
            await viewModel?.setFavorite(.room(session), isFavorite: newValue)
          }
        }
        .onDisappear {
          notificationTask?.cancel()
          favoriteTask?.cancel()
        }

        CardFormSection(Strings.details) {
          MetricTileGrid {
            MetricTile(
              Strings.permission,
              systemImage: "person.badge.key",
              value: session.permissionLevel.localizedName
            )
            MetricTile(
              Strings.status,
              systemImage: "antenna.radiowaves.left.and.right",
              value: session.isConnected ? Strings.connected : Strings.disconnected,
              valueTint: session.isConnected ? .green : nil
            )
            MetricTile(
              Strings.lastConnected,
              systemImage: "clock",
              value: session.lastConnectedDate?.formatted(.relative(presentation: .named)) ?? "—"
            )
          }
        }

        // The public key is for troubleshooting and verification, so it stays folded away;
        // the name it used to sit beside is already the header.
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 4) {
            Text(Strings.publicKey)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(session.publicKeyHex)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
        } label: {
          SettingCardLabel(Strings.identification, systemImage: "key.fill", color: .gray)
        }
        .cardSurface(padding: 12)

        CardFormSection {
          ConversationDestructiveActionCard(
            title: L10n.Chats.Chats.ChannelInfo.clearMessagesButton,
            systemImage: "xmark.circle",
            isBusy: isClearingMessages
          ) {
            showingClearMessagesConfirmation = true
          }
          .disabled(isClearingMessages)

          if let errorMessage {
            Text(errorMessage)
              .font(.footnote)
              .foregroundStyle(.red)
              .padding(.horizontal, 4)
          }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .scrollRevealNavigationTitle(session.name, revealAfter: headerHeight)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
          .keyboardShortcut(.defaultAction)
        }
      }
      // Inside the stack: on a Mac these push onto this sheet's stack rather than opening more.
      .nodePagePresentation(isPresented: $showTelemetry) {
        RoomStatusView(session: session)
      } pushed: {
        RoomStatusView(session: session, isPushed: true)
      }
      .nodePagePresentation(isPresented: $showSettings) {
        NavigationStack {
          RoomSettingsView(session: session)
        }
      } pushed: {
        RoomSettingsView(session: session)
      }
    }
    .confirmationDialog(
      L10n.Chats.Chats.ChannelInfo.ClearMessagesConfirm.title,
      isPresented: $showingClearMessagesConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Chats.Chats.ChannelInfo.clearMessagesButton, role: .destructive) {
        Task { await clearMessages() }
      }
      Button(L10n.Chats.Chats.Common.cancel, role: .cancel) {}
    } message: {
      Text(Strings.clearMessagesConfirmMessage)
    }
  }

  private func clearMessages() async {
    guard let roomServerService = appState.services?.roomServerService else {
      errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
      return
    }
    isClearingMessages = true
    defer { isClearingMessages = false }
    errorMessage = nil

    do {
      try await roomServerService.clearMessages(sessionID: session.id)
      await onMessagesCleared?()
      viewModel?.requestConversationReload()
      dismiss()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }
}
