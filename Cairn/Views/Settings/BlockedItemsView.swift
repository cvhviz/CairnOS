import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "BlockedItemsView")

/// Settings › Privacy & Blocking (`SettingsDetail.privacy`): everything the user has blocked, on one
/// page — contacts, channel sender names, and keywords — then Sign & Verify, which signs text with the
/// radio's key or checks someone else's signature. One place to review and undo blocking instead of
/// three sibling screens.
struct BlockedItemsView: View {
  @Environment(\.appState) private var appState

  @State private var contacts: [ContactDTO] = []
  @State private var senders: [BlockedChannelSenderDTO] = []
  @State private var keywords: [String] = []
  @State private var newKeyword = ""
  @State private var hasLoaded = false
  @State private var errorMessage: String?
  /// Cards have no swipe, so Edit reveals a remove button on every item (the context menu
  /// offers the same action on long-press).
  @State private var isEditing = false
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    CardForm {
      contactsSection
      sendersSection
      keywordsSection
      // A tool rather than a setting: proving who wrote a text (and checking another's) with the
      // radio's key. Only its Sign action needs a radio.
      CardFormSection {
        NavigationLink {
          SignVerifyView()
        } label: {
          NavigationTile(L10n.Tools.Tools.signVerify, systemImage: "signature", color: .mint)
        }
        .buttonStyle(.plain)
      }
    }
    .flashingNavigationTitle(SettingsDetail.privacy.title)
    .navigationBarTitleDisplayMode(.inline)
    .errorAlert($errorMessage)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(isEditing ? L10n.Localizable.Common.done : L10n.Localizable.Common.edit) {
          withAnimation { isEditing.toggle() }
        }
        .disabled(!isEditing && contacts.isEmpty && senders.isEmpty && keywords.isEmpty)
      }
    }
    .task {
      keywords = BlockedKeywords.load()
      await loadBlocked()
      hasLoaded = true
    }
    .onChange(of: appState.contactsVersion) { _, _ in
      // Unblocking from a contact's detail page bumps the version; drop it from the list.
      Task { await loadBlocked() }
    }
  }

  // MARK: - Contacts

  private var contactsSection: some View {
    CardFormSection(
      L10n.Contacts.Contacts.Blocked.title,
      footer: hasLoaded && contacts.isEmpty ? L10n.Contacts.Contacts.Blocked.Empty.description : nil
    ) {
      if !hasLoaded {
        loadingCard
      } else if contacts.isEmpty {
        emptyCard(L10n.Contacts.Contacts.Blocked.Empty.title)
      } else {
        ForEach(contacts) { contact in
          HStack(spacing: 8) {
            // A destination link rather than `ContactRoute`, so the push resolves in both the
            // Settings and Contacts stacks without either registering the other's routes.
            NavigationLink {
              ContactDetailView(contact: contact)
            } label: {
              HStack {
                ContactRowView(contact: contact)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(Color(.tertiaryLabel))
                  .accessibilityHidden(true)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isEditing {
              removeButton(L10n.Contacts.Contacts.Action.unblock) { unblock(contact) }
            }
          }
          .cardSurface(padding: 12)
          .cardInteractionShape()
          .contextMenu {
            Button(L10n.Contacts.Contacts.Action.unblock, systemImage: "hand.raised.slash") {
              unblock(contact)
            }
          }
          .accessibilityAction(named: L10n.Contacts.Contacts.Action.unblock) { unblock(contact) }
        }
      }
    }
  }

  // MARK: - Channel Senders

  private var sendersSection: some View {
    CardFormSection(
      L10n.Settings.Blocking.ChannelSenders.title,
      footer: hasLoaded && senders.isEmpty ? L10n.Settings.Blocking.ChannelSenders.Empty.description : nil
    ) {
      if !hasLoaded {
        loadingCard
      } else if senders.isEmpty {
        emptyCard(L10n.Settings.Blocking.ChannelSenders.Empty.title)
      } else {
        ForEach(senders) { sender in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
              Text(sender.name)
                .font(.body)
              Text(sender.dateBlocked, format: .dateTime.month().day().year())
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: L10n.Contacts.Contacts.Action.unblock) { unblockSenders([sender]) }

            Spacer(minLength: 0)

            if isEditing {
              removeButton(L10n.Contacts.Contacts.Action.unblock) { unblockSenders([sender]) }
            }
          }
          .cardSurface(padding: 12)
          .cardInteractionShape()
          .contextMenu {
            Button(L10n.Contacts.Contacts.Action.unblock, systemImage: "hand.raised.slash") {
              unblockSenders([sender])
            }
          }
        }
      }
    }
  }

  // MARK: - Keywords

  private var trimmedNewKeyword: String {
    newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A blank entry, or one already listed (ignoring case), cannot be added.
  private var canAdd: Bool {
    !trimmedNewKeyword.isEmpty
      && BlockedKeywords.normalized(keywords + [trimmedNewKeyword]).count > keywords.count
  }

  private var keywordsSection: some View {
    CardFormSection(L10n.Settings.Blocking.Keywords.title, info: L10n.Settings.Blocking.Keywords.footer) {
      ContentCard {
        HStack {
          TextField(L10n.Settings.Blocking.Keywords.placeholder, text: $newKeyword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFieldFocused)
            .submitLabel(.done)
            .onSubmit(addKeyword)
            .onChange(of: newKeyword) { _, newValue in
              if newValue.count > BlockedKeywords.maxKeywordLength {
                newKeyword = String(newValue.prefix(BlockedKeywords.maxKeywordLength))
              }
            }

          Button(L10n.Settings.Blocking.Keywords.add, action: addKeyword)
            .disabled(!canAdd)
        }
      }

      if keywords.isEmpty {
        emptyCard(L10n.Settings.Blocking.Keywords.empty)
      } else {
        ForEach(keywords, id: \.self) { keyword in
          HStack(spacing: 8) {
            Text(keyword)
              .accessibilityAction(named: L10n.Localizable.Common.delete) { remove(keyword) }
            Spacer(minLength: 0)
            if isEditing {
              removeButton(L10n.Localizable.Common.delete) { remove(keyword) }
            }
          }
          .cardSurface(padding: 12)
          .cardInteractionShape()
          .contextMenu {
            Button(role: .destructive) {
              remove(keyword)
            } label: {
              Label(L10n.Localizable.Common.delete, systemImage: "trash")
            }
          }
        }
      }
    }
  }

  private var loadingCard: some View {
    ProgressView()
      .frame(maxWidth: .infinity)
      .cardSurface(padding: 12)
  }

  private func emptyCard(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)
  }

  /// The edit-mode remove control on an item card.
  private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
    Button(role: .destructive) {
      withAnimation { action() }
    } label: {
      Image(systemName: "minus.circle.fill")
        .font(.title3)
        .foregroundStyle(.white, .red)
        // A full-size target, clear of the card's link and context-menu area beside it.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .transition(.scale.combined(with: .opacity))
  }

  // MARK: - Actions

  private func loadBlocked() async {
    // The offline store keeps the lists readable while the radio is disconnected.
    guard let dataStore = appState.offlineDataStore,
          let radioID = appState.currentRadioID else { return }

    do {
      contacts = try await dataStore.fetchBlockedContacts(radioID: radioID)
    } catch {
      errorMessage = error.userFacingMessage
    }

    do {
      senders = try await dataStore.fetchBlockedChannelSenders(radioID: radioID)
    } catch {
      logger.error("Failed to load blocked channel senders: \(error)")
      senders = []
    }
  }

  private func unblock(_ contact: ContactDTO) {
    contacts.removeAll { $0.id == contact.id }
    Task {
      do {
        try await appState.services?.contactService.updateContactPreferences(
          contactID: contact.id,
          isBlocked: false
        )
      } catch {
        errorMessage = error.userFacingMessage
      }
      // Restores the row if the unblock didn't land (e.g. services unavailable).
      await loadBlocked()
    }
  }

  private func unblockSenders(_ sendersToUnblock: [BlockedChannelSenderDTO]) {
    let ids = Set(sendersToUnblock.map(\.id))
    senders.removeAll { ids.contains($0.id) }

    Task {
      // The same store and radio the list was read from, so an unblock lands while the radio is
      // disconnected too.
      guard let dataStore = appState.offlineDataStore,
            let radioID = appState.currentRadioID else {
        await loadBlocked()
        return
      }

      var failure: Error?
      for sender in sendersToUnblock {
        do {
          try await dataStore.deleteBlockedChannelSender(radioID: radioID, name: sender.name)
        } catch {
          logger.error("Failed to delete blocked sender '\(sender.name)': \(error)")
          failure = error
        }
      }

      // Only a live session holds the in-memory block cache; it reloads from the store on connect.
      if let services = appState.services {
        await services.syncCoordinator.refreshBlockedContactsCache(
          radioID: radioID,
          dataStore: services.dataStore
        )
        services.syncCoordinator.notifyConversationsChanged()
      }

      if let failure {
        errorMessage = failure.userFacingMessage
        // Restores the rows whose unblock didn't land.
        await loadBlocked()
      }
    }
  }

  private func addKeyword() {
    guard canAdd else { return }
    keywords = BlockedKeywords.normalized(keywords + [trimmedNewKeyword])
    BlockedKeywords.save(keywords)
    newKeyword = ""
    isFieldFocused = true
  }

  private func remove(_ keyword: String) {
    keywords.removeAll { $0 == keyword }
    BlockedKeywords.save(keywords)
  }

  // MARK: - Summary

  /// Total of blocked contacts, channel senders, and keywords, for the row that opens this
  /// page. Reads the offline store so the count shows while disconnected.
  @MainActor
  static func totalCount(appState: AppState) async -> Int {
    let keywordCount = BlockedKeywords.load().count
    guard let dataStore = appState.offlineDataStore,
          let radioID = appState.currentRadioID else { return keywordCount }
    let contactCount = (try? await dataStore.fetchBlockedContacts(radioID: radioID).count) ?? 0
    let senderCount = (try? await dataStore.fetchBlockedChannelSenders(radioID: radioID).count) ?? 0
    return contactCount + senderCount + keywordCount
  }
}

#Preview {
  NavigationStack {
    BlockedItemsView()
  }
}
