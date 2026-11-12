import CairnServices
import SwiftUI
import UIKit

enum ChatInputMetrics {
  /// Shared height for the compose field and its flanking glass buttons so the three controls align.
  static let controlHeight: CGFloat = 36
  /// Corner radius of the compose field, shared by its iOS 26 glass capsule and its outlined
  /// pre-iOS 26 form.
  static let fieldCornerRadius: CGFloat = 20
  /// Hairline width for the pre-iOS 26 field's outline.
  static let fieldBorderWidth: CGFloat = 1
}

/// Opaque plate behind the compose controls before iOS 26. `nil` on iOS 26+ so the
/// field and send button can sample the timeline through a themed canvas.
enum ChatInputBarChrome {
  static func opaqueFill(themedCanvas: Color?) -> Color? {
    if #available(iOS 26.0, *) {
      return nil
    }
    return themedCanvas ?? Color(.systemBackground)
  }
}

struct ChatInputBar<Leading: View>: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Binding var text: String
  /// Focus-request token forwarded to the composer; see `ChatComposerTextView`.
  let focusRequest: Int
  let placeholder: String
  let maxBytes: Int
  let isEncrypted: Bool
  @ViewBuilder let leading: () -> Leading
  var onFocus: () -> Void = {}
  /// The conversation holds sends waiting for the radio; with the radio away, a strip above the
  /// field says they will go on reconnect.
  var hasQueuedSends = false
  let onSend: (String) -> Void

  @State private var isCoolingDown = false
  @State private var sendInvocationCounter: Int = 0
  @State private var composerProxy = ChatComposerProxy()
  @Namespace private var glassNamespace

  private var budget: MessageByteBudget {
    MessageByteBudget(text: text, maxBytes: maxBytes)
  }

  private var isOverLimit: Bool {
    budget.isOverLimit
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsQueuedStrip {
        queuedStrip
      }
      composeRow
    }
    .inputBarBackground(themedCanvas: theme.canvasColor)
    .sensoryFeedback(.start, trigger: sendInvocationCounter)
    .animation(.smooth(duration: 0.28), value: canSend)
    .animation(.smooth(duration: 0.28), value: budget.level)
    .animation(.smooth(duration: 0.28), value: showsQueuedStrip)
  }

  /// Sends written while the radio is away wait in the send queue; say so above the field
  /// rather than hiding the send button, so the message is not lost or left unexplained.
  private var showsQueuedStrip: Bool {
    hasQueuedSends && appState.connectionState != .ready
  }

  private var queuedStrip: some View {
    HStack(spacing: 6) {
      Image(systemName: "clock.arrow.circlepath")
        .accessibilityHidden(true)
      Text(L10n.Chats.Chats.Input.willSendOnReconnect)
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.top, 8)
    .accessibilityElement(children: .combine)
    .transition(.opacity)
  }

  private var composeRow: some View {
    HStack(alignment: .bottom, spacing: 12) {
      leading()
      LiquidGlassContainer(spacing: 12) {
        HStack(alignment: .bottom, spacing: 12) {
          ChatInputTextField(
            text: $text,
            placeholder: placeholder,
            focusRequest: focusRequest,
            isEncrypted: isEncrypted,
            budget: budget,
            proxy: composerProxy,
            onSend: handleHardwareSend,
            onFocus: onFocus,
            glassNamespace: glassNamespace
          )
          if canSend {
            ChatSendButton(
              sendAccessibilityLabel: sendAccessibilityLabel,
              sendAccessibilityHint: sendAccessibilityHint,
              onSend: send
            )
            .liquidGlassID("chatSend", in: glassNamespace)
            .transition(chatSendButtonTransition)
          } else if isReadyToSend {
            // Only the byte limit is in the way. Holding the send button's slot keeps the
            // draft from re-wrapping as it crosses the limit.
            Color.clear
              .frame(width: ChatInputMetrics.controlHeight, height: ChatInputMetrics.controlHeight)
              .accessibilityHidden(true)
          }
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var sendAccessibilityLabel: String {
    if isOverLimit {
      L10n.Chats.Chats.Input.tooLong
    } else {
      L10n.Chats.Chats.Input.sendMessage
    }
  }

  private var sendAccessibilityHint: String {
    if isOverLimit {
      L10n.Chats.Chats.Input.removeCharacters(-budget.remainingBytes)
    } else if canSend, appState.connectionState != .ready {
      L10n.Chats.Chats.Input.queuesUntilReconnect
    } else if canSend {
      L10n.Chats.Chats.Input.tapToSend
    } else {
      L10n.Chats.Chats.Input.typeFirst
    }
  }

  /// Every send gate except the byte limit. The radio's connection is not one: a send while
  /// it is away is stored and queued for the reconnect (`ChatViewModel.queueOfflineMessage`).
  private var isReadyToSend: Bool {
    !isCoolingDown &&
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canSend: Bool {
    isReadyToSend && !isOverLimit
  }

  /// Hardware Return: `true` consumes it and sends under the same gates as the send
  /// button; `false` inserts a newline. The composer keeps focus itself.
  private func handleHardwareSend() -> Bool {
    guard canSend else { return false }
    send()
    return true
  }

  private func send() {
    composerProxy.commitPendingInput()
    // Committing autocorrect or marked IME text can lengthen the draft past the limit after
    // `canSend` passed; keep the draft (the counter now shows it over) instead of losing it
    // to the service's too-long rejection.
    guard !MessageByteBudget(text: text, maxBytes: maxBytes).isOverLimit else { return }
    let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !captured.isEmpty else { return }
    isCoolingDown = true
    text = ""
    sendInvocationCounter &+= 1
    onSend(captured)
    Task {
      try? await Task.sleep(for: .seconds(1))
      isCoolingDown = false
    }
  }
}

extension ChatInputBar where Leading == EmptyView {
  /// Input bar with no leading accessory, for call sites that only pass `onSend`.
  init(
    text: Binding<String>,
    focusRequest: Int,
    placeholder: String,
    maxBytes: Int,
    isEncrypted: Bool,
    onSend: @escaping (String) -> Void
  ) {
    self.init(
      text: text,
      focusRequest: focusRequest,
      placeholder: placeholder,
      maxBytes: maxBytes,
      isEncrypted: isEncrypted,
      leading: { EmptyView() },
      onSend: onSend
    )
  }
}

// MARK: - Extracted Views

private struct ChatInputTextField: View {
  @Binding var text: String
  let placeholder: String
  let focusRequest: Int
  let isEncrypted: Bool
  let budget: MessageByteBudget
  let proxy: ChatComposerProxy
  let onSend: () -> Bool
  let onFocus: () -> Void
  let glassNamespace: Namespace.ID

  var body: some View {
    ChatComposerTextView(
      text: $text,
      focusRequest: focusRequest,
      isEncrypted: isEncrypted,
      proxy: proxy,
      onSend: onSend,
      onFocus: onFocus
    )
    .frame(maxWidth: .infinity, minHeight: ChatInputMetrics.controlHeight)
    .overlay(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.body)
          .foregroundStyle(Color(uiColor: .placeholderText))
          .padding(.top, ChatComposerUITextView.verticalInset)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .padding(.leading, 12)
    .padding(.trailing, 28)
    .overlay(alignment: .trailing) {
      VStack(spacing: 0) {
        Image(systemName: isEncrypted ? "lock.fill" : "lock.open.fill")
          .font(.footnote)
          .foregroundStyle(isEncrypted ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
          .accessibilityHidden(true)
        if budget.level != .hidden {
          // Zero layout width keeps the lock where it sits without the counter; the digits
          // draw centered beneath it inside the strip the field already reserves.
          ChatByteBudgetLabel(budget: budget)
            .fixedSize()
            .frame(width: 0)
            .transition(.opacity)
        }
      }
      .padding(.trailing, 10)
    }
    .textFieldBackground()
    .liquidGlassID("chatComposer", in: glassNamespace)
  }
}

private var chatSendButtonTransition: AnyTransition {
  if #available(iOS 26.0, *) {
    .opacity
  } else {
    .scale(scale: 0.5, anchor: .trailing).combined(with: .opacity)
  }
}

/// Remaining UTF-8 bytes for the draft; negative once it is over the limit.
private struct ChatByteBudgetLabel: View {
  let budget: MessageByteBudget

  var body: some View {
    Text(verbatim: "\(budget.remainingBytes)")
      .font(.caption2)
      .monospacedDigit()
      .foregroundStyle(foregroundStyle)
      .accessibilityLabel(accessibilityLabel)
  }

  private var foregroundStyle: AnyShapeStyle {
    switch budget.level {
    case .hidden, .normal: AnyShapeStyle(.secondary)
    case .warning: AnyShapeStyle(.orange)
    case .over: AnyShapeStyle(.red)
    }
  }

  private var accessibilityLabel: String {
    if budget.isOverLimit {
      L10n.Chats.Chats.Input.bytesOverLimit(-budget.remainingBytes)
    } else {
      L10n.Chats.Chats.Input.bytesRemaining(budget.remainingBytes)
    }
  }
}

private struct ChatSendButton: View {
  @Environment(\.appTheme) private var theme
  let sendAccessibilityLabel: String
  let sendAccessibilityHint: String
  let onSend: () -> Void

  var body: some View {
    Button(action: onSend) {
      Image(systemName: "arrow.up")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(theme.outgoingTextColor)
        .frame(width: ChatInputMetrics.controlHeight, height: ChatInputMetrics.controlHeight)
        .sendButtonBackground(theme.accentColor)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(sendAccessibilityLabel)
    .accessibilityHint(sendAccessibilityHint)
  }
}

// MARK: - Platform-Conditional Styling

private extension View {
  @ViewBuilder
  /// Filled with the theme's outgoing-bubble color so the send control matches what it sends.
  func sendButtonBackground(_ fill: Color) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.tint(fill).interactive(), in: .circle)
    } else {
      background(fill, in: Circle())
    }
  }

  @ViewBuilder
  func textFieldBackground() -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: .rect(cornerRadius: ChatInputMetrics.fieldCornerRadius))
    } else {
      // Without the glass capsule the field would read as one fill on the bar's fill, so its edge
      // carries the affordance. A clear centre keeps it legible against any theme canvas.
      overlay {
        RoundedRectangle(cornerRadius: ChatInputMetrics.fieldCornerRadius)
          .strokeBorder(Color(.separator), lineWidth: ChatInputMetrics.fieldBorderWidth)
      }
    }
  }

  @ViewBuilder
  func inputBarBackground(themedCanvas: Color?) -> some View {
    if let fill = ChatInputBarChrome.opaqueFill(themedCanvas: themedCanvas) {
      background(fill)
    } else {
      self
    }
  }
}

// MARK: - Preview

private struct ChatInputBarPreviewHost: View {
  @State private var plainText = ""
  @State private var leadingText = ""

  var body: some View {
    VStack(spacing: 24) {
      ChatInputBar(
        text: $plainText,
        focusRequest: 0,
        placeholder: "No leading accessory",
        maxBytes: 140,
        isEncrypted: true
      ) { _ in }

      ChatInputBar(
        text: $leadingText,
        focusRequest: 0,
        placeholder: "With leading accessory",
        maxBytes: 140,
        isEncrypted: false,
        leading: { Image(systemName: "plus") }
      ) { _ in }
    }
  }
}

#Preview {
  ChatInputBarPreviewHost()
}
