import CairnServices
import SwiftUI

/// Identifies a conversation opened in its own window. Codable so the scene can restore it;
/// the window reloads the current contact or channel by id rather than holding a stale copy.
struct ConversationWindowID: Codable, Hashable {
  enum Kind: String, Codable {
    case direct
    case channel
  }

  let kind: Kind
  let id: UUID

  /// Nil for rooms, which need an authenticated session and stay in the main window.
  init?(route: ChatRoute) {
    switch route {
    case let .direct(contact):
      kind = .direct
      id = contact.id
    case let .channel(channel):
      kind = .channel
      id = channel.id
    case .room:
      return nil
    }
  }
}

/// A single conversation in its own window (Mac and iPad multi-window): the same
/// `ChatConversationView` the split layout shows, without the conversation list.
struct ConversationWindowView: View {
  @Environment(\.appState) private var appState
  let windowID: ConversationWindowID?

  @State private var conversationType: ChatConversationType?
  @State private var didLoad = false

  var body: some View {
    NavigationStack {
      if let conversationType {
        ChatConversationView(
          conversationType: conversationType,
          coordinatorRegistry: appState.ensureChatCoordinatorRegistry()
        )
      } else if didLoad {
        ContentUnavailableView(L10n.Chats.Chats.Window.unavailable, systemImage: "bubble.left.and.exclamationmark.bubble.right")
      } else {
        ProgressView()
      }
    }
    .task(id: windowID) { await load() }
    // The contact's or channel's name in the Mac title bar; the Chats section's until it loads.
    .macWindowTitle(conversationType?.navigationTitle ?? AppTab.chats.title)
  }

  private func load() async {
    defer { didLoad = true }
    guard let windowID, let store = appState.offlineDataStore else { return }
    switch windowID.kind {
    case .direct:
      if let contact = try? await store.fetchContact(id: windowID.id) {
        conversationType = .dm(contact)
      }
    case .channel:
      if let channel = try? await store.fetchChannel(id: windowID.id) {
        conversationType = .channel(channel)
      }
    }
  }
}
