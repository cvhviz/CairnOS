import CairnServices
import SwiftUI

/// Unified inner content view for both DM and Channel conversations.
/// Handles loading state, empty state, the messages list, bubble construction, and overlay buttons.
struct ChatConversationMessagesContent: View {
  // MARK: - Identity

  let conversationType: ChatConversationType
  @Bindable var viewModel: ChatViewModel
  let deviceName: String
  let recentEmojisStore: RecentEmojisStore

  // MARK: - Display Preferences

  let envInputs: EnvInputs

  // MARK: - Scroll State

  @Binding var isAtBottom: Bool
  @Binding var unreadCount: Int
  let scrollToBottomRequest: Int
  let scrollToTargetRequest: Int
  let scrollToTargetID: UUID?

  /// Whether the timeline is ready to show and, if so, the "New Messages"
  /// divider id it opens scrolled to (nil opens at the bottom).
  let firstSnapshotDecision: ChatInitialScrollPolicy.FirstSnapshotDecision

  /// Fired once the tiled view has consumed the presented divider target, so the
  /// owner can retire it and a later `.id` rebuild won't re-jump to the divider.
  let onDividerTargetConsumed: () -> Void

  // MARK: - Sheet State Bindings

  @Binding var selectedMessageForActions: MessageDTO?
  @Binding var imageViewerData: ImageViewerData?

  // MARK: - Callbacks

  let onRetryMessage: (MessageDTO) -> Void
  let onTranslationAction: (UUID) -> Void
  /// Mac right-click menu builder; nil keeps right-click on the actions sheet.
  var messageContextMenu: ((MessageDTO) -> UIMenu?)?

  /// Multi-select state shared with the conversation view; nil in previews.
  var selection: MessageSelectionModel?
  /// Sends a message again from its bubble (an unheard channel message); nil in previews.
  var onSendAgainMessage: ((MessageDTO) -> Void)?
  /// Opens the message a reply's quote was taken from; nil in previews.
  var onReplyQuoteTap: ((MessageDTO) -> Void)?

  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var incomingAvatarFlight = IncomingAvatarFlight()

  // MARK: - Body

  var body: some View {
    Group {
      if showsTimeline {
        messagesList
          .overlay {
            if viewModel.messages.isEmpty {
              emptyState
                .allowsHitTesting(false)
            }
          }
      } else {
        // Blank canvas while the first fetch is in flight, or while a warm
        // page from a previous open is withheld: it must not become the
        // list's first snapshot, or the one-shot divider positioning is spent on it.
        Color.clear
      }
    }
  }

  /// Whether the messages list is mounted. A loaded-but-empty conversation
  /// mounts it too, with the empty state overlaid, so the first sent message
  /// appends into the same list. Swapping the empty state for a freshly built
  /// list on that first append dismisses the keyboard. Mounting it empty is
  /// safe: only the first non-empty snapshot spends the one-shot positioning.
  private var showsTimeline: Bool {
    if viewModel.messages.isEmpty {
      return viewModel.renderState.phase == .loaded
    }
    if case .withhold = firstSnapshotDecision { return false }
    return true
  }

  // MARK: - Messages List

  /// Presented divider target the list opens scrolled to; nil opens at the bottom.
  private var initialScrollTargetID: UUID? {
    if case let .present(target) = firstSnapshotDecision { return target }
    return nil
  }

  /// The messages list bound to the current view model. When the conversation has an unread
  /// backlog it opens scrolled to the baked "New Messages" divider.
  private var messagesList: some View {
    ChatTiledView(
      items: viewModel.items,
      cellContent: { item in
        cellFactory.makeContent(for: item)
          .environment(\.incomingAvatarFlight, incomingAvatarFlight)
      },
      isAtBottom: $isAtBottom,
      unreadCount: $unreadCount,
      scrollToBottomRequest: scrollToBottomRequest,
      countsTowardUnread: { !$0.envelope.isOutgoing },
      scrollToTargetRequest: scrollToTargetRequest,
      scrollTargetID: scrollToTargetID,
      initialScrollTargetID: initialScrollTargetID,
      onLoadOlder: { await viewModel.loadOlderMessages() },
      onInitialTargetConsumed: onDividerTargetConsumed,
      sizeCache: appState.chatSizeCache
    )
    .overlay {
      incomingAvatarFlight.overlay()
    }
    .onAppear {
      viewModel.incomingAvatarFlight = incomingAvatarFlight
      incomingAvatarFlight.isAtBottom = isAtBottom
      incomingAvatarFlight.reduceMotion = reduceMotion
    }
    .onChange(of: isAtBottom, initial: true) { _, atBottom in
      incomingAvatarFlight.isAtBottom = atBottom
    }
    .onChange(of: reduceMotion, initial: true) { _, reduce in
      incomingAvatarFlight.reduceMotion = reduce
    }
    .onChange(of: envInputs) { _, new in
      viewModel.applyEnvInputs(new)
    }
  }

  private var cellFactory: ChatCellContentFactory {
    ChatCellContentFactory(
      contactName: conversationType.navigationTitle,
      deviceName: deviceName,
      configuration: bubbleConfiguration,
      theme: theme,
      openURL: openURL,
      resolver: BubbleResolver(viewModel: viewModel),
      actions: BubbleActions(
        onRetryMessage: onRetryMessage,
        onLongPress: { message in selectedMessageForActions = message },
        onImageTap: { message in
          if let data = viewModel.imageData(for: message.id) {
            imageViewerData = ImageViewerData(
              imageData: data,
              isGIF: viewModel.isGIFImage(for: message.id)
            )
          }
        },
        onRetryInlineImage: { messageID in
          Task { await viewModel.retryImageFetch(for: messageID) }
        },
        onRequestPreviewFetch: { messageID in
          if viewModel.shouldRequestImageFetch(for: messageID) {
            viewModel.requestImageFetch(for: messageID)
          } else {
            viewModel.requestPreviewFetch(for: messageID)
          }
        },
        onManualPreviewFetch: { messageID in
          if viewModel.shouldRequestImageFetch(for: messageID) {
            viewModel.manualFetchImage(for: messageID)
          } else {
            Task { await viewModel.manualFetchPreview(for: messageID) }
          }
        },
        onMapPreviewTap: { coordinate in
          viewModel.navigateToMap(coordinate)
        },
        snapshotResolver: { MapSnapshotStore.shared.image(for: $0) },
        requestSnapshot: { MapSnapshotStore.shared.request($0) },
        retrySnapshot: { MapSnapshotStore.shared.retry($0) },
        onTranslationAction: { messageID in
          onTranslationAction(messageID)
        },
        contextMenu: messageContextMenu,
        onSendAgain: onSendAgainMessage,
        onReplyQuoteTap: onReplyQuoteTap
      ),
      selection: selection
    )
  }

  // MARK: - Empty State

  @ViewBuilder
  private var emptyState: some View {
    switch conversationType {
    case let .dm(contact):
      DMEmptyMessagesView(contact: contact)
    case let .channel(channel):
      ChannelEmptyMessagesView(
        channel: channel,
        displayName: conversationType.navigationTitle,
        isPublicStyle: conversationType.isPublicStyleChannel
      )
    }
  }

  // MARK: - Bubble Configuration

  private var bubbleConfiguration: MessageBubbleConfiguration {
    switch conversationType {
    case .dm:
      .directMessage
    case .channel:
      .channel(isPublic: conversationType.isPublicStyleChannel)
    }
  }
}

// MARK: - DM Empty Messages View

private struct DMEmptyMessagesView: View {
  let contact: ContactDTO

  var body: some View {
    VStack(spacing: 16) {
      ContactAvatar(contact: contact, size: 80)

      Text(contact.displayName)
        .font(.title2)
        .bold()

      Text(L10n.Chats.Chats.EmptyState.startConversation)
        .foregroundStyle(.secondary)

      if contact.hasLocation {
        Label(L10n.Chats.Chats.ContactInfo.hasLocation, systemImage: "location.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

// MARK: - Channel Empty Messages View

private struct ChannelEmptyMessagesView: View {
  let channel: ChannelDTO
  let displayName: String
  let isPublicStyle: Bool

  var body: some View {
    VStack(spacing: 16) {
      ChannelAvatar(channel: channel, size: 80)

      Text(displayName)
        .font(.title2)
        .bold()

      Text(L10n.Chats.Chats.Channel.EmptyState.noMessages)
        .foregroundStyle(.secondary)

      Text(isPublicStyle
        ? L10n.Chats.Chats.Channel.EmptyState.publicDescription
        : L10n.Chats.Chats.Channel.EmptyState.privateDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

// MARK: - Previews

#Preview("DM Conversation") {
  NavigationStack {
    ChatConversationMessagesContent(
      conversationType: .dm(ContactDTO(from: Contact(
        radioID: UUID(),
        publicKey: Data(repeating: 0x42, count: 32),
        name: "Alice",
        lastHeardTimestamp: 0
      ))),
      viewModel: ChatViewModel(),
      deviceName: "My Device",
      recentEmojisStore: RecentEmojisStore(),
      envInputs: .default,
      isAtBottom: .constant(true),
      unreadCount: .constant(0),
      scrollToBottomRequest: 0,
      scrollToTargetRequest: 0,
      scrollToTargetID: nil,
      firstSnapshotDecision: .present(target: nil),
      onDividerTargetConsumed: {},
      selectedMessageForActions: .constant(nil),
      imageViewerData: .constant(nil),
      onRetryMessage: { _ in },
      onTranslationAction: { _ in }
    )
  }
  .environment(\.appState, AppState())
}

#Preview("Channel Conversation") {
  NavigationStack {
    ChatConversationMessagesContent(
      conversationType: .channel(ChannelDTO(from: Channel(
        radioID: UUID(),
        index: 1,
        name: "General"
      ))),
      viewModel: ChatViewModel(),
      deviceName: "My Device",
      recentEmojisStore: RecentEmojisStore(),
      envInputs: .default,
      isAtBottom: .constant(true),
      unreadCount: .constant(0),
      scrollToBottomRequest: 0,
      scrollToTargetRequest: 0,
      scrollToTargetID: nil,
      firstSnapshotDecision: .present(target: nil),
      onDividerTargetConsumed: {},
      selectedMessageForActions: .constant(nil),
      imageViewerData: .constant(nil),
      onRetryMessage: { _ in },
      onTranslationAction: { _ in }
    )
  }
  .environment(\.appState, AppState())
}
