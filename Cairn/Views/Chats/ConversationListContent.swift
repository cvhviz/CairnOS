import CairnServices
import SwiftUI

/// The conversation list rendered as a `ScrollView` + `LazyVStack` rather than a `List`.
/// `List` is backed by `UpdateCoalescingCollectionView`, whose batch-consistency assertion
/// is violated when the selected row is deleted; a `LazyVStack` has no collection view, so
/// that crash cannot occur.
struct ConversationListContent: View {
  enum ListMode {
    case selection(Binding<ChatRoute?>)
    case navigation(onNavigate: (ChatRoute) -> Void, onRequestRoomAuth: (RemoteNodeSessionDTO) -> Void)
  }

  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private let viewModel: ChatViewModel
  private let favoriteConversations: [Conversation]
  private let otherConversations: [Conversation]
  private let mode: ListMode
  private let hasLoadedOnce: Bool
  private let emptyStateMessage: (title: String, description: String, systemImage: String)
  private let onDeleteConversation: (Conversation) -> Void
  @Binding private var selectedFilter: ChatFilter
  /// The search, typed in the field above the list (`PullDownSearch`).
  @Binding private var searchText: String
  /// The filter header's height, so the empty state centres in the space under it.
  @State private var headerHeight: CGFloat = 0
  @AppStorage(AppStorageKey.pinFavoriteChats.rawValue) private var pinFavoriteChats = AppStorageKey.defaultPinFavoriteChats
  /// The Favorites group is folded. Kept across launches; open until the user folds it.
  @AppStorage(ConversationListSections.collapsedKey.rawValue) private var isFavoritesCollapsed = false

  /// Extra gap where the Favorites group ends and the rest begin, on top of the usual card
  /// spacing: whitespace groups the two runs of cards without a rule across the canvas.
  private static let favoritesBoundaryGap: CGFloat = 14

  init(
    viewModel: ChatViewModel,
    favoriteConversations: [Conversation],
    otherConversations: [Conversation],
    selectedFilter: Binding<ChatFilter>,
    searchText: Binding<String>,
    hasLoadedOnce: Bool,
    emptyStateMessage: (title: String, description: String, systemImage: String),
    selection: Binding<ChatRoute?>,
    onDeleteConversation: @escaping (Conversation) -> Void
  ) {
    self.viewModel = viewModel
    self.favoriteConversations = favoriteConversations
    self.otherConversations = otherConversations
    _selectedFilter = selectedFilter
    _searchText = searchText
    self.hasLoadedOnce = hasLoadedOnce
    self.emptyStateMessage = emptyStateMessage
    mode = .selection(selection)
    self.onDeleteConversation = onDeleteConversation
  }

  init(
    viewModel: ChatViewModel,
    favoriteConversations: [Conversation],
    otherConversations: [Conversation],
    selectedFilter: Binding<ChatFilter>,
    searchText: Binding<String>,
    hasLoadedOnce: Bool,
    emptyStateMessage: (title: String, description: String, systemImage: String),
    onNavigate: @escaping (ChatRoute) -> Void,
    onRequestRoomAuth: @escaping (RemoteNodeSessionDTO) -> Void,
    onDeleteConversation: @escaping (Conversation) -> Void
  ) {
    self.viewModel = viewModel
    self.favoriteConversations = favoriteConversations
    self.otherConversations = otherConversations
    _selectedFilter = selectedFilter
    _searchText = searchText
    self.hasLoadedOnce = hasLoadedOnce
    self.emptyStateMessage = emptyStateMessage
    mode = .navigation(onNavigate: onNavigate, onRequestRoomAuth: onRequestRoomAuth)
    self.onDeleteConversation = onDeleteConversation
  }

  var body: some View {
    Group {
      if !hasLoadedOnce {
        loadingBody
      } else {
        // No list-wide minute tick: each row's `ConversationTimestamp` runs its own
        // `TimelineView`, so the clock rolling over re-renders timestamps, not every card.
        loadedBody
      }
    }
    // Warm the top registry-capacity conversations after load so open lands settled.
    // Keep warm work off LazyVStack rows: appear/disappear would start and cancel tasks while scrolling.
    .task(id: hasLoadedOnce) {
      guard hasLoadedOnce else { return }
      await prewarmTopConversations()
    }
  }

  private var loadingBody: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        Section {} header: { filterHeader }
      }
    }
    .overlay { ProgressView() }
    .cardCanvas(theme)
  }

  private var loadedBody: some View {
    // Grouped once per pass and shared by the rows and keyboard stepping.
    let sections = self.sections
    return ScrollViewReader { proxy in
      ScrollView {
        // Search waits above the list until it's pulled down.
        PullDownSearch(text: $searchText, prompt: L10n.Chats.Chats.Search.placeholder, proxy: proxy) {
          LazyVStack(spacing: CardStyle.spacing) {
            Section {
              if sections.isEmpty, !showsMessageHits {
                emptyState
              } else {
                rows(sections)
              }
              if showsMessageHits {
                messageHits
              }
            } header: {
              filterHeader
            }
          }
          .padding(.bottom, CardStyle.pageInset)
        }
      }
      .swipeActionsContainerIfAvailable()
      // Pull down past the search field to re-read the store.
      .refreshable { await viewModel.requestConversationReload()?.value }
      .cardCanvas(theme)
      .modifier(ConversationKeyboardStepping(
        selection: selectionBinding,
        conversations: sections.visibleRows,
        hiddenAbove: sections.hiddenFavorites,
        scrollTo: { id in proxy.scrollTo(id) }
      ))
    }
  }

  /// The split layout's selection; nil in navigation (compact) mode, where rows push instead.
  private var selectionBinding: Binding<ChatRoute?>? {
    if case let .selection(selection) = mode { return selection }
    return nil
  }

  /// The route `step` moves to from `current` in `routes`: the first (next) or last (previous)
  /// row when nothing is selected, clamped at both ends, nil when the list is empty. A `current`
  /// in `hiddenAbove` (a folded favorite) sits just above the first row: next goes to the first
  /// row, previous stays put (nil) rather than wrapping to the end of the list.
  static func stepped(
    from current: ChatRoute?,
    in routes: [ChatRoute],
    hiddenAbove: [ChatRoute] = [],
    by step: NavigationCoordinator.ConversationStep
  ) -> ChatRoute? {
    guard !routes.isEmpty else { return nil }
    if let current, !routes.contains(current), hiddenAbove.contains(current) {
      return step == .next ? routes.first : nil
    }
    guard let current, let index = routes.firstIndex(of: current) else {
      return step == .next ? routes.first : routes.last
    }
    let target = step == .next ? min(index + 1, routes.count - 1) : max(index - 1, 0)
    return routes[target]
  }

  /// Messages matching the search, under the name matches, while a search is typed.
  private var showsMessageHits: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.messageSearchHits.isEmpty
  }

  @ViewBuilder
  private var messageHits: some View {
    Text(L10n.Chats.Chats.Search.messagesSection)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, CardStyle.pageInset + ConversationRowLayout.cardPadding)
      .padding(.top, Self.favoritesBoundaryGap)
      .accessibilityAddTraits(.isHeader)
    ForEach(viewModel.messageSearchHits) { hit in
      Button {
        open(hit)
      } label: {
        MessageSearchHitRow(hit: hit, viewModel: viewModel)
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface(padding: ConversationRowLayout.cardPadding)
          .cardInteractionShape()
          .accessibilityElement(children: .combine)
      }
      .buttonStyle(.plain)
      .conversationCardInset()
      .transition(.opacity)
    }
  }

  /// Opens the hit's conversation scrolled to the message: the conversation view takes the
  /// pending target when it loads.
  private func open(_ hit: MessageSearchHit) {
    appState.navigation.pendingScrollToMessageID = hit.message.id
    switch mode {
    case let .selection(selection):
      selection.wrappedValue = hit.route
    case let .navigation(onNavigate, onRequestRoomAuth):
      if case let .room(session) = hit.conversation, !session.isConnected {
        onRequestRoomAuth(session)
      } else {
        onNavigate(hit.route)
      }
    }
  }

  private var filterHeader: some View {
    // No opaque header fill: the header scrolls with the cards (nothing is pinned), and
    // the card canvas already sits behind the iOS 18 segmented fallback.
    ChatFilterPicker(selection: $selectedFilter, isSearching: !searchText.isEmpty)
      .frame(maxWidth: .infinity)
      // The first section sits as far below the bar as every tab's does (`CardStyle.pageInset`),
      // so switching tabs doesn't jump (the user, 2026-11-08); the segmented bar brings 8 of it.
      .padding(.top, CardStyle.pageInset - 8)
      .measuringHeight($headerHeight)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(emptyStateMessage.title, systemImage: emptyStateMessage.systemImage)
    } description: {
      Text(emptyStateMessage.description)
    } actions: {
      if selectedFilter != .all {
        Button(L10n.Chats.Chats.Filter.clear) {
          selectedFilter = .all
        }
      }
    }
    .emptyStateFrame(below: headerHeight)
  }

  /// Display grouping: a collapsible Favorites group above the rest, or one list by recency
  /// when the user turns pinning off.
  private var sections: ConversationListSections {
    ConversationListSections(
      favorites: favoriteConversations,
      others: otherConversations,
      pinFavorites: pinFavoriteChats,
      isFavoritesCollapsed: isFavoritesCollapsed,
      sort: viewModel.sortedByLastMessage
    )
  }

  /// The Favorites group (its header, then its cards unless folded) and the rest of the cards
  /// under it. Where the group ends and the rest begin, a wider gap separates the two instead
  /// of a rule.
  @ViewBuilder
  private func rows(_ sections: ConversationListSections) -> some View {
    let boundaryGap = sections.others.isEmpty ? 0 : Self.favoritesBoundaryGap
    if sections.showsFavoritesGroup {
      FavoriteConversationsHeader(
        count: sections.favorites.count,
        unreadCount: sections.foldedUnreadCount,
        isCollapsed: $isFavoritesCollapsed
      )
        .padding(.bottom, sections.isFavoritesCollapsed ? boundaryGap : 0)
      let favorites = sections.visibleFavorites
      ForEach(Array(favorites.enumerated()), id: \.element.id) { index, conversation in
        rowView(conversation)
          .padding(.bottom, index == favorites.count - 1 ? boundaryGap : 0)
          .transition(.opacity)
      }
    }
    ForEach(sections.others, id: \.id) { conversation in
      rowView(conversation)
        .transition(.opacity)
    }
  }

  /// Warms the top conversations on first load, up to the registry's LRU
  /// capacity. Staggered so the per-conversation fetch and item build don't land
  /// on the main actor in one burst; `prefetchConversation` no-ops for any that
  /// are already warm.
  private func prewarmTopConversations() async {
    // Folded favorites still warm first: folding hides them, it doesn't make them less likely to open.
    let ordered = sections.allRows
    for conversation in ordered.prefix(ChatCoordinatorRegistry.defaultCapacity) {
      guard !Task.isCancelled else { return }
      warm(conversation)
      try? await Task.sleep(for: .milliseconds(30))
    }
  }

  /// Kicks off the coordinator warm for one conversation. Rooms have no
  /// coordinator; skipped.
  private func warm(_ conversation: Conversation) {
    guard let conversationType = ChatRoute(conversation: conversation).chatConversationType else { return }
    appState.prefetchConversation(
      conversationType,
      envInputs: appState.chatEnvInputs(
        for: conversationType,
        themeID: theme.id,
        isDark: colorScheme == .dark,
        isHighContrast: colorSchemeContrast == .increased,
        contentSizeCategory: AppearanceToken.contentSizeCategoryToken(dynamicTypeSize)
      )
    )
  }

  @ViewBuilder
  private func rowView(_ conversation: Conversation) -> some View {
    switch mode {
    case let .selection(selection):
      ConversationSelectionRow(
        conversation: conversation,
        viewModel: viewModel,
        isSelected: selection.wrappedValue == ChatRoute(conversation: conversation),
        onSelect: { selection.wrappedValue = ChatRoute(conversation: conversation) },
        onDelete: { onDeleteConversation(conversation) }
      )
    case let .navigation(onNavigate, onRequestRoomAuth):
      ConversationNavigationRow(
        conversation: conversation,
        viewModel: viewModel,
        onNavigate: onNavigate,
        onRequestRoomAuth: onRequestRoomAuth,
        onDelete: { onDeleteConversation(conversation) }
      )
    }
  }
}

// MARK: - Keyboard Stepping

/// Moves the split layout's selection with ↑/↓ while the list has focus, and with the
/// previous/next conversation menu shortcuts from anywhere. A no-op in navigation mode.
private struct ConversationKeyboardStepping: ViewModifier {
  let selection: Binding<ChatRoute?>?
  let conversations: [Conversation]
  /// Rows folded away above `conversations`: the selection may sit on one of them.
  let hiddenAbove: [Conversation]
  /// Scrolls the stepped-to row into view (keyed by `Conversation.id`).
  let scrollTo: (Conversation.ID) -> Void

  @Environment(\.appState) private var appState

  func body(content: Content) -> some View {
    if let selection {
      content
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(.next, selection) }
        .onKeyPress(.upArrow) { step(.previous, selection) }
        .onChange(of: appState.navigation.conversationStepVersion) { _, _ in
          if let request = appState.navigation.conversationStep {
            _ = step(request, selection)
          }
        }
    } else {
      content
    }
  }

  private func step(_ direction: NavigationCoordinator.ConversationStep, _ selection: Binding<ChatRoute?>) -> KeyPress.Result {
    let routes = conversations.map(ChatRoute.init(conversation:))
    guard let target = ConversationListContent.stepped(
      from: selection.wrappedValue,
      in: routes,
      hiddenAbove: hiddenAbove.map(ChatRoute.init(conversation:)),
      by: direction
    ),
          let index = routes.firstIndex(of: target) else {
      return .ignored
    }
    selection.wrappedValue = target
    scrollTo(conversations[index].id)
    return .handled
  }
}

// MARK: - Row Layout

private enum ConversationRowLayout {
  /// Inside the card; the rows add 4 pt of their own top and bottom.
  static let cardPadding: CGFloat = 10
}

/// Renders a conversation's row body as a card, shared by the selection and navigation rows.
/// `isSelected` draws the shared card selection (accent outline and wash) for the conversation
/// open in the iPad detail column.
private struct ConversationRowLabel: View {
  let conversation: Conversation
  let viewModel: ChatViewModel
  var isSelected = false

  var body: some View {
    Group {
      switch conversation {
      case let .direct(contact):
        ConversationRow(contact: contact, viewModel: viewModel)
      case let .channel(channel):
        ChannelConversationRow(channel: channel, viewModel: viewModel)
      case let .room(session):
        RoomConversationRow(session: session, viewModel: viewModel)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(isSelected: isSelected, padding: ConversationRowLayout.cardPadding)
    .cardInteractionShape()
    // One VoiceOver element per row: name, preview, time and the unread badges in one read.
    .accessibilityElement(children: .combine)
  }
}

private extension View {
  /// Insets a conversation card from the screen edges. Applied outside the swipe actions so
  /// the card itself slides and the revealed actions stay within the page margins.
  func conversationCardInset() -> some View {
    padding(.horizontal, CardStyle.pageInset)
  }
}

// MARK: - Extracted Rows

private struct ConversationSelectionRow: View {
  let conversation: Conversation
  let viewModel: ChatViewModel
  let isSelected: Bool
  let onSelect: () -> Void
  let onDelete: () -> Void

  private var isDeleting: Bool {
    viewModel.deletingIDs.contains(conversation.id)
  }

  var body: some View {
    Button(action: onSelect) {
      ConversationRowLabel(
        conversation: conversation,
        viewModel: viewModel,
        isSelected: isSelected
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .deletingRowOverlay(isDeleting: isDeleting)
    .conversationContextMenu(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
    .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
    .conversationCardInset()
  }
}

private struct ConversationNavigationRow: View {
  let conversation: Conversation
  let viewModel: ChatViewModel
  let onNavigate: (ChatRoute) -> Void
  let onRequestRoomAuth: (RemoteNodeSessionDTO) -> Void
  let onDelete: () -> Void

  private var isDeleting: Bool {
    viewModel.deletingIDs.contains(conversation.id)
  }

  var body: some View {
    Button(action: tap) {
      ConversationRowLabel(conversation: conversation, viewModel: viewModel)
    }
    .buttonStyle(.plain)
    .deletingRowOverlay(isDeleting: isDeleting)
    .conversationContextMenu(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
    .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
    .conversationCardInset()
  }

  private func tap() {
    let route = ChatRoute(conversation: conversation)
    if case let .room(session) = conversation, !session.isConnected {
      onRequestRoomAuth(session)
    } else {
      onNavigate(route)
    }
  }
}
