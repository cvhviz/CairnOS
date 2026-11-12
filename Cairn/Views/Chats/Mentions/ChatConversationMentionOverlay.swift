import CairnServices
import SwiftUI

/// Floating mention suggestions overlay for the chat input.
///
/// Also the one place the conversation observes the composer text: reading `composingText` here
/// rather than in `ChatConversationView.body` keeps each keystroke from re-evaluating the whole
/// conversation (timeline, toolbar, sheets); only this small view and the input bar re-render.
struct ChatConversationMentionOverlay: View {
  /// Clearance above the compose bar when the keyboard is down (bar ~height).
  private static let composeBarClearance: CGFloat = 60

  let chatViewModel: ChatViewModel
  let conversationType: ChatConversationType
  /// Called after every composer text change; the host debounces the draft save from it.
  let onComposingTextChange: () -> Void

  /// Channel sender recency frozen when a mention query opens, so suggestions don't reshuffle
  /// under the user's finger as new messages arrive mid-query.
  @State private var mentionSenderOrder: [String: UInt32]?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Reduce Motion keeps the fade and drops the slide and scale.
  private var popupTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .move(edge: .bottom)
        .combined(with: .opacity)
        .combined(with: .scale(scale: 0.95, anchor: .bottom)),
      removal: .move(edge: .bottom).combined(with: .opacity)
    )
  }

  var body: some View {
    // Evaluated once per body pass and shared by the suggestions and the change handler.
    let query = MentionUtilities.detectActiveMention(in: chatViewModel.composingText)
    let suggestions = mentionSuggestions(for: query)

    // A non-hit-testing base keeps the change handlers installed while no popup is shown.
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .overlay(alignment: .bottom) {
        if !suggestions.isEmpty {
          VStack {
            Spacer()
            MentionSuggestionView(contacts: suggestions) { contact in
              insertMention(for: contact)
            }
            .padding(.horizontal)
            // Clearance above the compose bar, then `chatKeyboardLift` for the keyboard.
            .padding(.bottom, Self.composeBarClearance)
            .chatKeyboardLiftPadding()
            .transition(popupTransition)
          }
          .animation(.spring(response: 0.3, dampingFraction: 0.8), value: suggestions.isEmpty)
        }
      }
      .onChange(of: chatViewModel.composingText) { _, _ in
        onComposingTextChange()
      }
      .onChange(of: query != nil) { _, isActive in
        mentionSenderOrder = isActive ? chatViewModel.channelSenderOrder : nil
      }
  }

  private func mentionSuggestions(for query: String?) -> [ContactDTO] {
    guard let query else { return [] }
    switch conversationType {
    case .dm:
      return MentionUtilities.filterContacts(chatViewModel.allContacts, query: query)
    case .channel:
      let combined = chatViewModel.allContacts + chatViewModel.channelSenders
      let order = mentionSenderOrder ?? chatViewModel.channelSenderOrder
      return MentionUtilities.filterContacts(combined, query: query, senderOrder: order)
    }
  }

  private func insertMention(for contact: ContactDTO) {
    guard let query = MentionUtilities.detectActiveMention(in: chatViewModel.composingText) else { return }

    let searchPattern = "@" + query
    if let range = chatViewModel.composingText.range(of: searchPattern, options: .backwards) {
      let mention = MentionUtilities.createMention(for: contact.name)
      chatViewModel.composingText.replaceSubrange(range, with: mention + " ")
    }
  }
}
