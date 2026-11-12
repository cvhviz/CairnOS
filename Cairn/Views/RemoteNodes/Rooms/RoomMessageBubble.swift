import CairnServices
import SwiftUI

/// Top padding for same-cluster follow-ups (no timestamp). `ChatTiledView` has no cell spacing.
private let sameClusterPaddingTop: CGFloat = 2

/// Message bubble for room server messages
struct RoomMessageBubble: View {
  let message: RoomMessageDTO
  let showTimestamp: Bool
  let showSenderName: Bool
  let showAvatar: Bool
  /// The room the post is in, so its own system posts read as the room.
  var room: RemoteNodeSessionDTO?
  /// Who wrote the post, when the caller resolved it already. Nil resolves it here, in the
  /// bubble's body, from the key prefix against the radio's current contacts
  /// (`NodeAppearanceIndex.names`), so a nickname or a contact saved later shows at once.
  var author: RoomAuthorIdentity?
  var translation: MessageTranslationChrome?
  var onRetry: (() -> Void)?
  var onLongPress: ((RoomMessageDTO) -> Void)?
  var onTranslationAction: (() -> Void)?

  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  @Environment(\.appState) private var appState

  @State private var isLongPressing = false
  @State private var longPressTrigger = 0
  /// Formatted body memo, so link and mention detection runs once per text and appearance
  /// rather than on every render (long-press, status, and translation changes re-render).
  @State private var formattedTextCache = FormattedTextCache()

  private var isFromSelf: Bool {
    message.isFromSelf
  }

  /// The author as shown, resolved from the post's key prefix now. Read in `body`, so the bubble
  /// redraws when the contacts change.
  var resolvedAuthor: RoomAuthorIdentity {
    author ?? appState.nodeAppearance.names.roomAuthors.resolve(
      message, roomPublicKey: room?.publicKey, roomName: room?.name, selfName: L10n.Chats.Chats.Path.Receiver.you
    )
  }

  var body: some View {
    let formattedBodyText = formattedBodyText
    VStack(spacing: 4) {
      if showTimestamp {
        makeTimestampView()
      }

      HStack(alignment: .bottom, spacing: 8) {
        if isFromSelf {
          Spacer(minLength: 60)
        }

        VStack(alignment: isFromSelf ? .trailing : .leading, spacing: 2) {
          makeBubbleContent(formattedBodyText: formattedBodyText)
          makeStatusIndicator()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessageLabel)
        .accessibilityAction {
          onLongPress?(message)
        }
        .accessibilityActions {
          if let chrome = translation {
            switch chrome.phase {
            case .offer:
              Button(L10n.Chats.Chats.Message.Action.translate) {
                onTranslationAction?()
              }
            case .showing:
              Button(L10n.Chats.Chats.Message.Action.showOriginal) {
                onTranslationAction?()
              }
            case .inProgress:
              EmptyView()
            }
          }
          if accessibilityShowsRetryAction {
            Button(L10n.Chats.Chats.Message.Action.retry) { performAccessibilityRetry() }
          }
          ForEach(accessibilityLinkActions(formatted: formattedBodyText)) { action in
            Button(action.name) { openURL(action.url) }
          }
        }

        if !isFromSelf {
          Spacer(minLength: 60)
        }
      }
      .padding(.horizontal)
      .padding(.top, showTimestamp ? 0 : sameClusterPaddingTop)
    }
  }

  // MARK: - Subviews

  private func makeTimestampView() -> some View {
    TimestampView(date: message.postDate)
  }

  var accessibilityMessageLabel: String {
    let body: String = switch translation?.phase {
    case let .showing(translated, _):
      L10n.Chats.Chats.Message.translatedAccessibility(translated)
    case .inProgress:
      "\(message.text), \(L10n.Chats.Chats.Message.Action.translating)"
    default:
      message.text
    }
    if isFromSelf {
      return "\(body), \(message.accessibilityStatusLabel)"
    }
    return "\(Self.accessibleAuthorName(resolvedAuthor)): \(body)"
  }

  /// The author as VoiceOver reads it: a key-only author is announced as unknown, with its key,
  /// rather than read out as if the hex were a name.
  static func accessibleAuthorName(_ author: RoomAuthorIdentity) -> String {
    switch author.kind {
    case .unknown: L10n.Chats.Chats.Message.Sender.unknownAuthorAccessibility(author.keyPrefixHex)
    case .ambiguous: L10n.Chats.Chats.Message.Sender.ambiguousAuthorAccessibility(author.keyPrefixHex)
    case .me, .room, .contact, .lastKnown: author.displayName
    }
  }

  var accessibilityShowsRetryAction: Bool {
    message.status == .failed && onRetry != nil
  }

  func performAccessibilityRetry() {
    onRetry?()
  }

  func accessibilityLinkActions(formatted: AttributedString) -> [MessageLinkAccessibility.Action] {
    MessageLinkAccessibility.actions(previewURL: nil, formatted: formatted)
  }

  private var formattedBodyText: AttributedString {
    let key = FormattedTextCache.Key(
      text: message.text,
      isFromSelf: isFromSelf,
      isHighContrast: colorSchemeContrast == .increased,
      isDark: colorScheme == .dark,
      themeID: theme.id,
      appearanceRevision: appState.nodeAppearance.revision
    )
    if let cached = formattedTextCache.value(for: key) {
      return cached
    }
    let formatted = MessageText.buildFormattedText(
      text: message.text,
      isOutgoing: isFromSelf,
      isHighContrast: colorSchemeContrast == .increased,
      outgoingTextColor: theme.outgoingTextColor,
      hashtagColor: theme.hashtagColor,
      identityGamut: theme.identityGamut,
      identityBackgroundLuminances: theme.avatarSurfaceLuminances(
        colorScheme: colorScheme,
        contrast: colorSchemeContrast
      ),
      mentionColors: appState.nodeAppearance.colorByLoweredName
    ).text
    formattedTextCache.store(formatted, for: key)
    return formatted
  }

  private func makeBubbleContent(formattedBodyText: AttributedString) -> some View {
    BubbleContent(
      message: message,
      author: resolvedAuthor,
      roomPublicKey: room?.publicKey,
      isFromSelf: isFromSelf,
      showSenderName: showSenderName,
      showAvatar: showAvatar,
      highContrast: colorSchemeContrast == .increased,
      formattedBodyText: formattedBodyText,
      translation: translation,
      onTranslationAction: onTranslationAction
    )
    .messageBubbleLongPressGesture(
      isPressing: $isLongPressing,
      trigger: $longPressTrigger,
      onFire: { onLongPress?(message) }
    )
    .messageBubbleLongPressEffect(isPressing: isLongPressing, trigger: longPressTrigger)
  }

  private func makeStatusIndicator() -> some View {
    StatusIndicator(
      message: message,
      isFromSelf: isFromSelf,
      statusText: message.localizedStatusText,
      accessibilityStatusLabel: message.accessibilityStatusLabel,
      onRetry: onRetry
    )
  }
}

// MARK: - Formatted Text Cache

/// Single-entry memo for a bubble's formatted body. A plain reference held in `@State`, not
/// observed, so storing into it during body evaluation does not invalidate the view.
private final class FormattedTextCache {
  struct Key: Equatable {
    let text: String
    let isFromSelf: Bool
    let isHighContrast: Bool
    let isDark: Bool
    let themeID: String
    /// `NodeAppearanceIndex.revision`, so a newly picked mention colour reformats the body.
    let appearanceRevision: Int
  }

  private var entry: (key: Key, value: AttributedString)?

  func value(for key: Key) -> AttributedString? {
    guard let entry, entry.key == key else { return nil }
    return entry.value
  }

  func store(_ value: AttributedString, for key: Key) {
    entry = (key, value)
  }
}

// MARK: - Timestamp View

/// The time after a pause in the room, in the chats' words: the day (`ChatDayLabel`) and the time,
/// on the same pill as their day dividers.
private struct TimestampView: View {
  let date: Date

  var body: some View {
    TimelineView(.everyMinute) { context in
      Text("\(ChatDayLabel.text(for: date, relativeTo: context.date)) \(date.formatted(date: .omitted, time: .shortened))")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .fixedSize()
    }
    .padding(.vertical, 6)
  }
}

// MARK: - Bubble Content

private struct BubbleContent: View {
  let message: RoomMessageDTO
  let author: RoomAuthorIdentity
  /// The room's key: its own posts wear the room's avatar.
  let roomPublicKey: Data?
  let isFromSelf: Bool
  let showSenderName: Bool
  let showAvatar: Bool
  let highContrast: Bool
  let formattedBodyText: AttributedString
  var translation: MessageTranslationChrome?
  var onTranslationAction: (() -> Void)?

  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  @Environment(\.appState) private var appState

  /// The author's page, found by the post's key prefix (`MentionTapHandler`), never by the shown
  /// name: a nickname or a hex prefix matches no node by name.
  private func openAuthor() {
    guard let url = MentionDeeplinkSupport.url(forKeyPrefix: message.authorKeyPrefix) else { return }
    openURL(url)
  }

  /// The author's picked colour: matched on the key prefix first, so a name two contacts share
  /// can't give the name a different colour from the avatar.
  private var authorColor: NodeAvatarColor? {
    appState.nodeAppearance.appearance(forKeyPrefix: message.authorKeyPrefix)?.color
      ?? (author.isKeyOnly ? nil : appState.nodeAppearance.color(forName: author.displayName))
  }

  private var bubbleBackground: Color {
    if isFromSelf {
      if message.status == .failed {
        return AppColors.Message.outgoingBubbleFailed(highContrast: highContrast)
      }
      return theme.accentColor // matches UnifiedMessageBubble.resolvedBubbleColor
    }
    return theme.incomingBubbleColor
  }

  private var textColor: Color {
    isFromSelf ? theme.outgoingTextColor : .primary
  }

  var body: some View {
    VStack(alignment: isFromSelf ? .trailing : .leading, spacing: 0) {
      if !isFromSelf, showSenderName {
        authorName
          .senderNamePlacement()
          .padding(.leading, IncomingBubbleAvatarMetrics.columnWidth)
          .contentShape(.rect)
          .onTapGesture { openAuthor() }
          .accessibilityHidden(true)
      }

      let gutter = showAvatar
        ? appState.nodeAppearance.roomAuthor(name: author.displayName, keyPrefix: message.authorKeyPrefix)
        : nil
      IncomingAvatarGutter(
        identity: gutter?.identity,
        reserveColumn: !isFromSelf,
        messageID: message.id,
        photo: gutter?.photo,
        roomServerKey: author.kind == .room ? roomPublicKey : nil,
        onAvatarTap: { openAuthor() }
      ) {
        messageBox
      }
    }
  }

  /// The author's name above the cluster. An author known only by key prefix shows the prefix as
  /// a key (monospaced, secondary), not as if it were a name; one several contacts share is
  /// marked as unresolved.
  @ViewBuilder
  private var authorName: some View {
    if author.isKeyOnly {
      HStack(spacing: 4) {
        Text(author.keyPrefixHex)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
        if author.kind == .ambiguous {
          Image(systemName: "questionmark.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      Text(author.displayName)
        .font(.footnote)
        .bold()
        .foregroundStyle(theme.nameColor(
          authorColor,
          colorScheme: colorScheme,
          contrast: highContrast ? .increased : .standard
        ))
    }
  }

  private var messageBox: some View {
    VStack(alignment: isFromSelf ? .trailing : .leading, spacing: 2) {
      if let chrome = translation {
        BubbleTranslationControl(
          phase: chrome.phase,
          onTap: { onTranslationAction?() }
        )
      }
      messageBody
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background { BubbleBackground(color: bubbleBackground, isTinted: isFromSelf) }
    .clipShape(.rect(cornerRadius: BubbleFragmentStack.cornerRadius, style: .continuous))
  }

  @ViewBuilder
  private var messageBody: some View {
    if case let .showing(translated, _) = translation?.phase {
      Text(translated)
        .font(.body)
        .foregroundStyle(textColor)
    } else {
      MessageText(message.text, baseColor: textColor, isOutgoing: isFromSelf, precomputedText: formattedBodyText)
    }
  }
}

// MARK: - Status Indicator

private struct StatusIndicator: View {
  let message: RoomMessageDTO
  let isFromSelf: Bool
  let statusText: String
  let accessibilityStatusLabel: String
  let onRetry: (() -> Void)?

  var body: some View {
    if isFromSelf {
      HStack(spacing: 4) {
        if message.status == .failed, let onRetry {
          Button {
            onRetry()
          } label: {
            HStack(spacing: 2) {
              Image(systemName: "arrow.clockwise")
              Text(L10n.Chats.Chats.Message.Status.retry)
            }
            .font(.caption2)
            .foregroundStyle(.tint)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(L10n.Chats.Chats.Message.Status.retry)
          .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Room.Message.retryHint)
        }

        Text(statusText)
          .font(.caption2)
          .foregroundStyle(.secondary)

        if message.status == .failed {
          Image(systemName: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }
      .padding(.trailing, 4)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityStatusLabel)
    }
  }
}

#Preview("Self Message") {
  RoomMessageBubble(
    message: RoomMessageDTO(
      sessionID: UUID(),
      authorKeyPrefix: Data(repeating: 0x42, count: 4),
      text: "Hello from me!",
      timestamp: UInt32(Date().timeIntervalSince1970),
      isFromSelf: true
    ),
    showTimestamp: true,
    showSenderName: false,
    showAvatar: false
  )
}

#Preview("Other Message") {
  RoomMessageBubble(
    message: RoomMessageDTO(
      sessionID: UUID(),
      authorKeyPrefix: Data(repeating: 0x55, count: 4),
      authorName: "Alice",
      text: "Hello from Alice!",
      timestamp: UInt32(Date().timeIntervalSince1970),
      isFromSelf: false
    ),
    showTimestamp: true,
    showSenderName: true,
    showAvatar: true
  )
}

#Preview("Pending Message") {
  RoomMessageBubble(
    message: RoomMessageDTO(
      sessionID: UUID(),
      authorKeyPrefix: Data(repeating: 0x42, count: 4),
      text: "Sending...",
      timestamp: UInt32(Date().timeIntervalSince1970),
      isFromSelf: true,
      status: .pending
    ),
    showTimestamp: true,
    showSenderName: false,
    showAvatar: false
  )
}

#Preview("Failed Message") {
  RoomMessageBubble(
    message: RoomMessageDTO(
      sessionID: UUID(),
      authorKeyPrefix: Data(repeating: 0x42, count: 4),
      text: "This failed to send",
      timestamp: UInt32(Date().timeIntervalSince1970),
      isFromSelf: true,
      status: .failed
    ),
    showTimestamp: true,
    showSenderName: false,
    showAvatar: false,
    onRetry: { print("Retry tapped") }
  )
}
