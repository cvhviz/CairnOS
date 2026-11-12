import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "ChannelInfoSheet")

/// Sheet displaying channel info with sharing and deletion options
struct ChannelInfoSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.chatViewModel) private var viewModel

  let channel: ChannelDTO
  let onClearMessages: () -> Void
  let onDelete: () -> Void

  @State private var notificationLevel: NotificationLevel
  @State private var isFavorite: Bool
  @State private var isDeleting = false
  @State private var isClearingMessages = false
  @State private var showingDeleteConfirmation = false
  @State private var showingClearMessagesConfirmation = false
  @State private var errorMessage: String?
  @State private var failedOperation: FailableOperation?
  @State private var copyHapticTrigger = 0
  @State private var notificationTask: Task<Void, Never>?
  @State private var favoriteTask: Task<Void, Never>?
  @State private var isRegionExpanded = false
  @State private var showingRegionManagement = false
  @State private var selectedFloodScope: ChannelFloodScope
  @State private var headerHeight: CGFloat = 80
  @State private var showingShareChannel = false

  init(channel: ChannelDTO, onClearMessages: @escaping () -> Void, onDelete: @escaping () -> Void) {
    self.channel = channel
    self.onClearMessages = onClearMessages
    self.onDelete = onDelete
    _notificationLevel = State(initialValue: channel.notificationLevel)
    _isFavorite = State(initialValue: channel.isFavorite)
    _selectedFloodScope = State(initialValue: channel.floodScope)
  }

  var body: some View {
    NavigationStack {
      CardForm {
        // Compact header with the everyday actions as cards beneath it
        ChannelInfoHeaderSection(
          channel: channel,
          measuredHeight: $headerHeight,
          isFavorite: $isFavorite,
          notificationLevel: $notificationLevel,
          canShare: canShareChannel,
          onShare: { showingShareChannel = true }
        )
        // Both are app-only store writes, so they persist with the radio away; without a chat
        // view model (the sheet opened over the list) the store is written directly.
        .onChange(of: notificationLevel) { _, newValue in
          notificationTask?.cancel()
          notificationTask = Task {
            if let viewModel {
              await viewModel.setNotificationLevel(.channel(channel), level: newValue)
            } else {
              await persistDirectly { try await $0.setChannelNotificationLevel(channel.id, level: newValue) }
            }
          }
        }
        .onChange(of: isFavorite) { _, newValue in
          favoriteTask?.cancel()
          favoriteTask = Task {
            if let viewModel {
              await viewModel.setFavorite(.channel(channel), isFavorite: newValue)
            } else {
              await persistDirectly { try await $0.setChannelFavorite(channel.id, isFavorite: newValue) }
            }
          }
        }
        .onDisappear {
          notificationTask?.cancel()
          favoriteTask?.cancel()
        }

        // Region Scope
        ChannelInfoRegionSection(
          knownRegions: knownRegions,
          selectedFloodScope: selectedFloodScope,
          deviceDefaultFloodScopeName: appState.connectedDevice?.defaultFloodScopeName,
          isExpanded: $isRegionExpanded,
          onFloodScopeSelected: { scope in
            Task { await selectFloodScope(scope) }
          },
          onManageTapped: {
            showingRegionManagement = true
          }
        )

        if let errorMessage {
          ConversationInfoErrorCard(message: errorMessage) {
            Task { await retryFailedOperation() }
          }
        }

        ChannelInfoActionsSection(
          isActionInProgress: isDeleting || isClearingMessages,
          isClearingMessages: isClearingMessages,
          isDeleting: isDeleting,
          showingClearMessagesConfirmation: $showingClearMessagesConfirmation,
          showingDeleteConfirmation: $showingDeleteConfirmation
        )
      }
      .navigationBarTitleDisplayMode(.inline)
      .scrollRevealNavigationTitle(channel.displayName, revealAfter: headerHeight)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Chats.Chats.Common.done) {
            dismiss()
          }
        }
      }
      // The QR code and the secret key live one tap away behind the Share card: needed when
      // inviting someone, not every time the sheet opens.
      .navigationDestination(isPresented: $showingShareChannel) {
        CardForm {
          ChannelInfoQRCodeSection(channel: channel, floodScope: selectedFloodScope)
          ChannelInfoSecretKeySection(
            channel: channel,
            copyHapticTrigger: $copyHapticTrigger
          )
        }
        .flashingNavigationTitle(L10n.Chats.Chats.ChannelInfo.shareChannel)
        .navigationBarTitleDisplayMode(.inline)
      }
      // The same Manage Regions page as Settings → Radio, discovery included.
      .navigationDestination(isPresented: $showingRegionManagement) {
        RegionManagementView()
      }
    }
    .confirmationDialog(
      L10n.Chats.Chats.ChannelInfo.ClearMessagesConfirm.title,
      isPresented: $showingClearMessagesConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Chats.Chats.ChannelInfo.clearMessagesButton, role: .destructive) {
        Task {
          await clearMessages()
        }
      }
      Button(L10n.Chats.Chats.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Chats.Chats.ChannelInfo.ClearMessagesConfirm.message)
    }
    .confirmationDialog(
      L10n.Chats.Chats.ChannelInfo.DeleteConfirm.title,
      isPresented: $showingDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Chats.Chats.ChannelInfo.deleteButton, role: .destructive) {
        Task {
          await deleteChannel()
        }
      }
      Button(L10n.Chats.Chats.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Chats.Chats.ChannelInfo.DeleteConfirm.message)
    }
    .sensoryFeedback(.success, trigger: copyHapticTrigger)
  }

  // MARK: - Private Methods

  /// Only private channels carry a secret worth sharing; public and hashtag channels are
  /// joined by name.
  private var canShareChannel: Bool {
    channel.hasSecret && !channel.isPublicChannel
  }

  /// The destructive operations that report through `errorMessage`, so Try Again
  /// re-runs the one that failed instead of always deleting the channel.
  private enum FailableOperation {
    case deleteChannel
    case clearMessages
  }

  private func retryFailedOperation() async {
    switch failedOperation {
    case .deleteChannel:
      await deleteChannel()
    case .clearMessages:
      await clearMessages()
    case nil:
      errorMessage = nil
    }
  }

  /// Writes a header toggle straight to the store when no chat view model is in the environment.
  private func persistDirectly(_ write: (PersistenceStore) async throws -> Void) async {
    guard let store = appState.offlineDataStore else {
      errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
      return
    }
    do {
      try await write(store)
      await appState.services?.notificationService.updateBadgeCount()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  private func clearNotificationsForChannel(radioID: UUID) async {
    await appState.services?.notificationService.removeDeliveredNotifications(
      forChannelIndex: channel.index,
      radioID: radioID
    )
    await appState.services?.notificationService.updateBadgeCount()
  }

  private func deleteChannel() async {
    failedOperation = .deleteChannel

    guard let radioID = appState.connectedDevice?.radioID else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    guard let channelService = appState.services?.channelService else {
      errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
      return
    }

    isDeleting = true
    errorMessage = nil

    do {
      // Clear channel on device (sends empty name + zero secret via BLE)
      // and deletes from local database
      try await channelService.clearChannel(
        radioID: radioID,
        index: channel.index
      )

      await clearNotificationsForChannel(radioID: radioID)

      dismiss()
      onDelete()
    } catch {
      errorMessage = error.userFacingMessage
      isDeleting = false
    }
  }

  private func clearMessages() async {
    failedOperation = .clearMessages

    guard let radioID = appState.connectedDevice?.radioID else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    guard let channelService = appState.services?.channelService else {
      errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
      return
    }

    isClearingMessages = true
    errorMessage = nil

    do {
      try await channelService.clearChannelMessages(
        radioID: radioID,
        channelIndex: channel.index
      )

      await clearNotificationsForChannel(radioID: radioID)

      onClearMessages()
      dismiss()
    } catch {
      errorMessage = error.userFacingMessage
      isClearingMessages = false
    }
  }

  private func selectFloodScope(_ scope: ChannelFloodScope) async {
    let previous = selectedFloodScope
    selectedFloodScope = scope
    do {
      try await appState.offlineDataStore?.setChannelFloodScope(channel.id, floodScope: scope)
    } catch {
      logger.error("Failed to save flood scope: \(error.localizedDescription)")
      selectedFloodScope = previous
      return
    }

    if let session = appState.services?.session {
      let resolved = ChannelFloodScopeResolver.resolve(
        channelFloodScope: scope,
        deviceDefaultFloodScopeName: appState.connectedDevice?.defaultFloodScopeName,
        supportsUnscopedFloodSend: appState.connectedDevice?.supportsUnscopedFloodSend ?? false
      )
      switch resolved {
      case .unscoped:
        try? await session.setFloodScopeUnscoped()
      case let .scope(scope):
        try? await session.setFloodScope(scope)
      }
    }
  }

  private var knownRegions: [String] {
    appState.connectedDevice?.knownRegions ?? []
  }
}

// MARK: - Extracted Views

private struct ChannelInfoHeaderSection: View {
  let channel: ChannelDTO
  @Binding var measuredHeight: CGFloat
  @Binding var isFavorite: Bool
  @Binding var notificationLevel: NotificationLevel
  let canShare: Bool
  let onShare: () -> Void

  private var channelTypeLabel: String {
    if channel.isPublicChannel {
      L10n.Chats.Chats.ChannelInfo.ChannelType.public
    } else if channel.name.hasPrefix("#") {
      L10n.Chats.Chats.ChannelInfo.ChannelType.hashtag
    } else {
      L10n.Chats.Chats.ChannelInfo.ChannelType.private
    }
  }

  var body: some View {
    VStack(spacing: ConversationInfoLayout.headerSpacing) {
      ConversationInfoHeader(
        title: channel.displayName,
        subtitle: channelTypeLabel,
        measuredHeight: $measuredHeight
      ) {
        ChannelAvatar(channel: channel, size: ConversationInfoLayout.avatarSize)
      }
      .padding(.horizontal, 4)

      ConversationActionCardRow {
        FavoriteActionCard(isFavorite: $isFavorite)
        NotificationLevelActionCard(
          selection: $notificationLevel,
          availableLevels: NotificationLevel.channelLevels
        )
        if canShare {
          ConversationActionCard(
            title: L10n.Chats.Chats.ChannelInfo.share,
            systemImage: "qrcode",
            action: onShare
          )
        }
      }
    }
  }
}

private struct ChannelInfoQRCodeSection: View {
  let channel: ChannelDTO
  let floodScope: ChannelFloodScope

  @State private var qrImage: UIImage?

  var body: some View {
    CardFormSection(L10n.Chats.Chats.ChannelInfo.shareChannel) {
      VStack(spacing: 12) {
        if let qrImage {
          Image(uiImage: qrImage)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: 180, height: 180)
            .accessibilityLabel(L10n.Localizable.Accessibility.qrCodeFor(channel.displayName))
        }

        Text(L10n.Chats.Chats.ChannelInfo.scanToJoin)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .cardSurface(padding: 16)
    }
    .task(id: floodScope) {
      qrImage = generateQRCode()
    }
  }

  private func generateQRCode() -> UIImage? {
    let urlString = ChannelService.exportChannelURI(
      name: channel.name,
      secret: channel.secret,
      floodScope: floodScope
    )
    return QRCodeGenerator.generate(from: urlString)
  }
}

private struct ChannelInfoSecretKeySection: View {
  let channel: ChannelDTO
  @Binding var copyHapticTrigger: Int

  var body: some View {
    CardFormSection(
      L10n.Chats.Chats.ChannelInfo.manualSharing,
      info: L10n.Chats.Chats.ChannelInfo.manualSharingFooter
    ) {
      ContentCard(L10n.Chats.Chats.ChannelInfo.secretKey, systemImage: "key.fill", color: .orange) {
        HStack {
          Text(channel.secret.uppercaseHexString())
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)

          Spacer()

          Button(L10n.Chats.Chats.ChannelInfo.copy, systemImage: "doc.on.doc") {
            copyHapticTrigger += 1
            UIPasteboard.general.setChannelSecret(channel.secret.uppercaseHexString())
          }
          .labelStyle(.iconOnly)
        }
      }
    }
  }
}

private struct ChannelInfoActionsSection: View {
  let isActionInProgress: Bool
  let isClearingMessages: Bool
  let isDeleting: Bool
  @Binding var showingClearMessagesConfirmation: Bool
  @Binding var showingDeleteConfirmation: Bool

  var body: some View {
    CardFormSection(footer: L10n.Chats.Chats.ChannelInfo.deleteFooter) {
      ConversationDestructiveActionCard(
        title: L10n.Chats.Chats.ChannelInfo.clearMessagesButton,
        systemImage: "xmark.circle",
        isBusy: isClearingMessages
      ) {
        showingClearMessagesConfirmation = true
      }
      .disabled(isActionInProgress)

      ConversationDestructiveActionCard(
        title: L10n.Chats.Chats.ChannelInfo.deleteButton,
        systemImage: "trash",
        isBusy: isDeleting
      ) {
        showingDeleteConfirmation = true
      }
      .disabled(isActionInProgress)
    }
  }
}

/// The channel's region scope as one card: the header row shows the current scope and expands
/// the card in place to pick another, so the choice stays next to its value.
private struct ChannelInfoRegionSection: View {
  let knownRegions: [String]
  let selectedFloodScope: ChannelFloodScope
  let deviceDefaultFloodScopeName: String?
  @Binding var isExpanded: Bool
  let onFloodScopeSelected: (ChannelFloodScope) -> Void
  let onManageTapped: () -> Void

  private var sortedPartitioned: (public: [String], private: [String]) {
    let sorted = knownRegions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return (sorted.filter { !$0.isPrivateRegion }, sorted.filter(\.isPrivateRegion))
  }

  private var regionValueLabel: String {
    if knownRegions.isEmpty {
      return L10n.Chats.Chats.ChannelInfo.Region.notConfigured
    }
    switch selectedFloodScope {
    case .inherit:
      if let name = deviceDefaultFloodScopeName, !name.isEmpty {
        return L10n.Chats.Chats.ChannelInfo.Region.useDefaultFormat(name)
      }
      return L10n.Chats.Chats.ChannelInfo.Region.allRegions
    case .allRegions:
      return L10n.Chats.Chats.ChannelInfo.Region.allRegions
    case let .region(name):
      return name
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(.snappy) { isExpanded.toggle() }
      } label: {
        ChannelInfoRegionLabel(regionValueLabel: regionValueLabel, isExpanded: isExpanded)
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? L10n.Chats.Chats.Message.Action.expanded : L10n.Chats.Chats.Message.Action.collapsed)

      if isExpanded {
        Divider()
        if knownRegions.isEmpty {
          ChannelInfoRegionEmptyContent(onManageTapped: onManageTapped)
        } else {
          ChannelInfoRegionPickerContent(
            selectedFloodScope: selectedFloodScope,
            deviceDefaultFloodScopeName: deviceDefaultFloodScopeName,
            publicRegions: sortedPartitioned.public,
            privateRegions: sortedPartitioned.private,
            onFloodScopeSelected: onFloodScopeSelected,
            onManageTapped: onManageTapped
          )
        }
      }
    }
    .cardSurface(padding: 12)
  }
}

private struct ChannelInfoRegionLabel: View {
  let regionValueLabel: String
  let isExpanded: Bool

  var body: some View {
    HStack(spacing: 12) {
      IconTile(systemImage: "globe", color: .teal)
        .accessibilityHidden(true)
      Text(L10n.Chats.Chats.ChannelInfo.region)
        .foregroundStyle(Color.primary)
      Spacer(minLength: 8)
      Text(regionValueLabel)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(.tertiaryLabel))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .accessibilityHidden(true)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }
}

private struct ChannelInfoRegionActions: View {
  let onManageTapped: () -> Void

  var body: some View {
    Button(L10n.Chats.Chats.ChannelInfo.Region.manageRegions, systemImage: "list.bullet") {
      onManageTapped()
    }
  }
}

private struct ChannelInfoRegionEmptyContent: View {
  let onManageTapped: () -> Void

  var body: some View {
    Text(L10n.Chats.Chats.ChannelInfo.Region.explanation)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    ChannelInfoRegionActions(onManageTapped: onManageTapped)
  }
}

private struct ChannelInfoRegionPickerContent: View {
  let selectedFloodScope: ChannelFloodScope
  let deviceDefaultFloodScopeName: String?
  let publicRegions: [String]
  let privateRegions: [String]
  let onFloodScopeSelected: (ChannelFloodScope) -> Void
  let onManageTapped: () -> Void

  private var effectiveDefault: String? {
    guard let name = deviceDefaultFloodScopeName, !name.isEmpty else { return nil }
    return name
  }

  var body: some View {
    if let defaultName = effectiveDefault {
      pickerRow(
        title: L10n.Chats.Chats.ChannelInfo.Region.useDefaultFormat(defaultName),
        isSelected: selectedFloodScope == .inherit,
        scope: .inherit
      )
    }

    pickerRow(
      title: L10n.Chats.Chats.ChannelInfo.Region.allRegions,
      isSelected: selectedFloodScope == allRegionsSelection,
      scope: allRegionsSelection
    )

    ForEach(publicRegions, id: \.self) { region in
      pickerRow(
        title: region,
        isSelected: selectedFloodScope == .region(region),
        scope: .region(region)
      )
    }

    // Private regions (shown disabled — can't scope to these)
    ForEach(privateRegions, id: \.self) { region in
      HStack {
        Text(region)
        Spacer()
        Text(L10n.Chats.Chats.ChannelInfo.Region.private)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .foregroundStyle(.secondary)
    }

    Divider()
    ChannelInfoRegionActions(onManageTapped: onManageTapped)
  }

  /// When no device default is set, `.inherit` and `.allRegions` collapse into a
  /// single row — writing `.inherit` is the conservative choice so a later default
  /// change flows through naturally.
  private var allRegionsSelection: ChannelFloodScope {
    effectiveDefault != nil ? .allRegions : .inherit
  }

  private func pickerRow(title: String, isSelected: Bool, scope: ChannelFloodScope) -> some View {
    Button {
      onFloodScopeSelected(scope)
    } label: {
      HStack {
        Text(title)
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview {
  ChannelInfoSheet(
    channel: ChannelDTO(from: Channel(
      radioID: UUID(),
      index: 1,
      name: "General",
      secret: Data(repeating: 0xAB, count: 16)
    )),
    onClearMessages: {},
    onDelete: {}
  )
  .environment(\.appState, AppState())
}
