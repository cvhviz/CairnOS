import CairnServices
import SwiftUI

/// Installs the chat-content `OpenURLAction` and the mention disambiguation
/// sheet on any chat surface that renders `MessageText`. Mention links
/// (`cairn://mention/...`, also sent by a tapped sender name or avatar) are
/// resolved locally through `MentionTapEvaluator` and open the contact's page
/// as a sheet over the chat, so reading about someone doesn't leave the
/// conversation; every other chat-relevant URL is forwarded to
/// `ChatLinkRouter`. Used by both `ChatConversationView` (DMs, channels) and
/// `RoomConversationView` so mention taps behave identically across all chat
/// surfaces rather than dying silently where no interceptor is installed.
struct MentionTapHandler: ViewModifier {
  @Environment(\.appState) private var appState

  let contacts: [ContactDTO]
  let radioID: UUID
  /// A secondary (right) click that opens the actions sheet also activates the
  /// link-preview card's `Button`, which routes its open through this same
  /// action. This returns true while the sheet is presenting so that trailing
  /// open is discarded instead of navigating away over the sheet.
  let shouldSuppressOpen: () -> Bool
  /// The open conversation's view of a sender, for the card shown when no node matches.
  var senderContext: MentionSenderContext?

  @State private var pickerContext: MentionPickerContext?
  /// The contact whose page is open over the chat.
  @State private var detailContact: ContactDTO?
  /// The heard-but-not-saved node whose page is open over the chat.
  @State private var detailDiscovered: DiscoveredNodeDTO?
  @State private var addingDiscoveredID: UUID?
  @State private var errorMessage: String?
  @State private var resolverTask: Task<Void, Never>?

  /// Lets the picker finish dismissing before the next sheet or action, so they don't collide.
  private static let sheetHandoffDelay: Duration = .milliseconds(350)

  func body(content: Content) -> some View {
    content
      .environment(\.openURL, OpenURLAction { url in
        if shouldSuppressOpen() { return .discarded }
        if let mentionName = MentionDeeplinkSupport.name(from: url) {
          handleMentionTap(name: mentionName)
          return .handled
        }
        if let keyPrefix = MentionDeeplinkSupport.keyPrefix(from: url) {
          handleKeyTap(prefix: keyPrefix)
          return .handled
        }
        return ChatLinkRouter.route(url, appState: appState) ? .handled : .systemAction
      })
      .sheet(item: $pickerContext) { context in
        MentionPickerSheet(
          context: context,
          onSelect: { contact in
            handOff { detailContact = contact }
          },
          onSelectDiscovered: { node in
            handOff { detailDiscovered = node }
          },
          onMention: senderContext?.onMention.map { mention in
            { handOff { mention(context.name) } }
          },
          onBlock: senderContext?.onBlock.map { block in
            { handOff { block(context.name) } }
          },
          onDismiss: { pickerContext = nil }
        )
      }
      .detailPresentation(item: $detailContact, route: { .contact(id: $0.id, canHideFromMap: false) }) { contact in
        ContactDetailSheet(
          contact: contact,
          onMessage: {
            detailContact = nil
            appState.navigation.navigateToChat(with: contact)
          },
          onDelete: { detailContact = nil }
        )
      }
      .detailPresentation(item: $detailDiscovered, route: {
        .discoveredNode(id: $0.id, radioID: $0.radioID, canHideFromMap: false)
      }) { node in
        DiscoveredNodeDetailSheet(
          node: node,
          isAdding: addingDiscoveredID == node.id,
          onAdd: { add(node) }
        )
        .presentationDetents([.medium, .large])
      }
      .errorAlert($errorMessage)
      .onDisappear {
        resolverTask?.cancel()
        resolverTask = nil
      }
  }

  /// Closes the picker, then runs `action` once it has gone.
  private func handOff(_ action: @escaping @MainActor () -> Void) {
    pickerContext = nil
    Task { @MainActor in
      try? await Task.sleep(for: Self.sheetHandoffDelay)
      action()
    }
  }

  /// Defers resolution into a `@MainActor` task so the sheet mutation lands on
  /// a later runloop turn rather than inside the synchronous `openURL`
  /// callback, matching `ChatLinkRouter`'s deferral convention. Heard-but-not-saved
  /// nodes come from the process-lifetime store, so this works offline too.
  private func handleMentionTap(name: String) {
    resolverTask?.cancel()
    resolverTask = Task { @MainActor in
      let discovered = (try? await appState.offlineDataStore?.fetchDiscoveredNodes(radioID: radioID)) ?? []
      guard !Task.isCancelled else { return }
      let outcome = MentionTapEvaluator.evaluate(
        rawName: name,
        contacts: contacts,
        discoveredNodes: discovered,
        connectedDeviceName: appState.connectedDevice?.nodeName,
        radioID: radioID
      )
      switch outcome {
      case let .navigate(contact):
        detailContact = contact
      case let .navigateDiscovered(node):
        detailDiscovered = node
      case var .picker(context):
        if context.isUnknownSender {
          context.activity = senderContext?.activity(context.name)
        }
        pickerContext = context
      }
    }
  }

  /// A node named by key prefix (a room post's author): the one contact with that key, else the
  /// one heard node, else the sender card for the key, which says no node matches.
  private func handleKeyTap(prefix: Data) {
    resolverTask?.cancel()
    resolverTask = Task { @MainActor in
      let contactMatches = contacts.filter { $0.publicKey.starts(with: prefix) }
      if contactMatches.count == 1, let contact = contactMatches.first {
        detailContact = contact
        return
      }
      if contactMatches.isEmpty {
        let discovered = (try? await appState.offlineDataStore?.fetchDiscoveredNodes(radioID: radioID)) ?? []
        guard !Task.isCancelled else { return }
        let heard = discovered.filter { $0.publicKey.starts(with: prefix) }
        if heard.count == 1, let node = heard.first {
          detailDiscovered = node
          return
        }
      }
      handleMentionTap(name: prefix.map { String(format: "%02X", $0) }.joined())
    }
  }

  /// Saves a heard node from its page, as the Map and Traffic map do.
  private func add(_ node: DiscoveredNodeDTO) {
    guard addingDiscoveredID == nil else { return }
    guard let contactService = appState.services?.contactService else {
      errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }
    addingDiscoveredID = node.id
    Task {
      defer { addingDiscoveredID = nil }
      do {
        try await contactService.addOrUpdateContact(radioID: node.radioID, contact: node.makeContactFrame())
        detailDiscovered = nil
      } catch ContactServiceError.contactTableFull {
        errorMessage = appState.connectedDevice.map { L10n.Contacts.Contacts.Add.Error.nodeListFull(Int($0.maxContacts)) }
          ?? L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}

/// What a chat offers the sender card when a tapped name matches no node: the sender's
/// messages here, and the actions that work without their key.
struct MentionSenderContext {
  var activity: (String) -> SenderChatActivity?
  var onMention: ((String) -> Void)?
  var onBlock: ((String) -> Void)?
}

extension View {
  /// Routes mention-link taps through `MentionTapEvaluator` and forwards every
  /// other chat URL to `ChatLinkRouter`. Apply to any chat surface that renders
  /// `MessageText`.
  func mentionTapHandling(
    contacts: [ContactDTO],
    radioID: UUID,
    shouldSuppressOpen: @escaping () -> Bool,
    senderContext: MentionSenderContext? = nil
  ) -> some View {
    modifier(MentionTapHandler(
      contacts: contacts,
      radioID: radioID,
      shouldSuppressOpen: shouldSuppressOpen,
      senderContext: senderContext
    ))
  }
}
