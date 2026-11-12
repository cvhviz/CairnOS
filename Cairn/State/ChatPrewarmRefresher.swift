import Foundation
import CairnServices

/// Re-primes warm `ChatCoordinator`s when a message arrives for a conversation
/// that is not currently open.
///
/// A coordinator prewarmed by `AppState.prefetchConversation` keeps the tail it
/// had at prime time: nothing updates it while its chat is closed, because the
/// message event stream only feeds the open conversation's view model.
/// Reopening then renders the stale list on the first frame, and the fresh
/// fetch lands in the tiled list as an offset-preserving tail append, leaving
/// the view scrolled above the new messages instead of at the bottom.
/// Re-priming at arrival time keeps the warm tail current, so a reopen's first
/// frame is already complete and bottom-anchored.
///
/// Owned by `AppState` (see `ensureChatPrewarmRefresher`), fed by
/// `MessageEventDispatcher`. Rooms have no coordinator and need no refresh.
@MainActor
final class ChatPrewarmRefresher {
  /// Identifies the conversation a message event belongs to, carrying just
  /// enough to key the coordinator lookup up front and resolve the full
  /// conversation lazily after the debounce.
  enum ConversationKind {
    case dm(contact: ContactDTO)
    case channel(radioID: UUID, channelIndex: UInt8)

    var coordinatorID: ChatConversationID {
      switch self {
      case let .dm(contact):
        .dm(radioID: contact.radioID, contactID: contact.id)
      case let .channel(radioID, channelIndex):
        .channel(radioID: radioID, channelIndex: channelIndex)
      }
    }
  }

  struct Hooks {
    /// Registry holding the warm coordinators; nil while no store is available.
    var registry: @MainActor () -> ChatCoordinatorRegistry?
    /// Dependency bundle for the priming path; nil when the owner is gone.
    var dependencies: @MainActor () -> ChatTimelinePrimer.Dependencies?
    /// Environment snapshot to bake items with; nil when no chat UI has
    /// rendered yet (nothing can be warm then, so skipping is safe).
    var envInputs: @MainActor (ChatConversationType) -> EnvInputs?
    /// Whether the conversation is currently open. The open view model already
    /// appends arrivals in place; re-priming under it would race its
    /// optimistic rows.
    var isConversationActive: @MainActor (ConversationKind) -> Bool
    /// Resolves the channel DTO for a channel event's radio + slot index.
    var channel: @MainActor (UUID, UInt8) async -> ChannelDTO?
    /// Resolves the contact DTO for a DM event's radio + contact id. Re-fetched
    /// at refresh time so the bake reads the post-increment unread count, not the
    /// pre-increment DTO captured when the event was dispatched.
    var contact: @MainActor (UUID, UUID) async -> ContactDTO?
    /// Link-preview cache for the primer, so a refresh also warms preview
    /// metadata and hero dimensions for the fresh tail; nil skips preview
    /// warming.
    var linkPreviewCache: @MainActor () -> (any LinkPreviewCaching)?
    /// Whether the app is in the foreground. A background arrival only marks
    /// the conversation stale; `refreshStaleConversations()` re-primes it on
    /// return, so a busy channel can't keep priming (and fetching previews)
    /// while nobody can see it.
    var isAppActive: @MainActor () -> Bool = { true }
  }

  private let hooks: Hooks

  /// Coalescing window: a sync catch-up delivers a burst of messages for the
  /// same conversation; one refresh at the end of the window covers them all.
  private let debounce: Duration

  /// One scheduled refresh per conversation; an arrival during the window
  /// rides the refresh already scheduled.
  private(set) var inFlight: [ChatConversationID: Task<Void, Never>] = [:]

  /// Conversations that got an arrival while their refresh was already running
  /// (past the debounce). The running refresh may have read the store before
  /// that arrival landed, so it reruns once more when it finishes.
  private var rerunRequested: Set<ChatConversationID> = []

  /// Warm conversations that got an arrival while the app was inactive. Re-primed
  /// by `refreshStaleConversations()` on return to the foreground, or by
  /// `consumeStale(_:)` when the conversation is prefetched for an open.
  private(set) var staleWhileInactive: [ChatConversationID: ConversationKind] = [:]

  init(hooks: Hooks, debounce: Duration = .milliseconds(250)) {
    self.hooks = hooks
    self.debounce = debounce
  }

  func noteDirectMessage(contact: ContactDTO) {
    schedule(.dm(contact: contact))
  }

  func noteChannelMessage(radioID: UUID, channelIndex: UInt8) {
    schedule(.channel(radioID: radioID, channelIndex: channelIndex))
  }

  /// Re-primes every conversation marked stale while the app was inactive.
  /// Called when the app returns to the foreground.
  func refreshStaleConversations() {
    let stale = staleWhileInactive
    staleWhileInactive.removeAll()
    for kind in stale.values {
      schedule(kind)
    }
  }

  /// Clears and reports the stale mark for `id`, so an open-time prefetch
  /// re-primes a warm coordinator that missed background arrivals instead of
  /// treating it as current.
  func consumeStale(_ id: ChatConversationID) -> Bool {
    staleWhileInactive.removeValue(forKey: id) != nil
  }

  private func schedule(_ kind: ConversationKind) {
    let id = kind.coordinatorID
    if inFlight[id] != nil {
      rerunRequested.insert(id)
      return
    }
    guard !hooks.isConversationActive(kind),
          let registry = hooks.registry(),
          registry.existingCoordinator(for: id)?.renderState.phase == .loaded
    else { return }

    guard hooks.isAppActive() else {
      staleWhileInactive[id] = kind
      return
    }

    let debounce = debounce
    inFlight[id] = Task { [weak self] in
      defer {
        self?.inFlight[id] = nil
        self?.rerunRequested.remove(id)
      }
      var shouldRun = true
      while shouldRun {
        try? await Task.sleep(for: debounce)
        guard let self, !Task.isCancelled else { return }
        // Arrivals during the debounce are covered by the refresh about to run.
        rerunRequested.remove(id)
        await refresh(kind, id: id)
        shouldRun = rerunRequested.contains(id)
      }
    }
  }

  private func refresh(_ kind: ConversationKind, id: ChatConversationID) async {
    // Re-validate after the debounce: the user may have opened the chat, the
    // registry may have torn down on disconnect, or the LRU may have evicted
    // the entry. A cold entry needs no refresh; the next open fetches fresh.
    guard !hooks.isConversationActive(kind),
          let registry = hooks.registry(),
          registry.existingCoordinator(for: id)?.renderState.phase == .loaded
    else { return }

    // Backgrounded during the debounce: defer to the foreground re-prime.
    guard hooks.isAppActive() else {
      staleWhileInactive[id] = kind
      return
    }

    // Re-fetch the DM contact so the divider bakes from the current unread count
    // (which also sizes the first page from that count); fall back to the
    // event-time DTO if the store lookup misses.
    let conversation: ChatConversationType? = switch kind {
    case let .dm(contact):
      await hooks.contact(contact.radioID, contact.id).map(ChatConversationType.dm) ?? .dm(contact)
    case let .channel(radioID, channelIndex):
      await hooks.channel(radioID, channelIndex).map(ChatConversationType.channel)
    }
    guard let conversation,
          let dependencies = hooks.dependencies(),
          let envInputs = hooks.envInputs(conversation)
    else { return }

    // A `.prime` bind is denied while an interactive owner is active (the
    // denied bind aborts inside `prime`). A mid-refresh open revokes the
    // writer and remaining writes no-op.
    let primer = ChatTimelinePrimer(
      dependencies: dependencies,
      linkPreviewCache: hooks.linkPreviewCache()
    )
    await primer.prime(conversation, envInputs: envInputs)
  }
}
