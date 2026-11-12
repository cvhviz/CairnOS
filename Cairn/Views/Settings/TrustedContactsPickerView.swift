import CairnServices
import SwiftUI

/// Who may request this radio's telemetry when it shares with trusted contacts only. All or
/// Favorites above the list; each contact a row with its avatar, short id and when it was last
/// heard, and a check to trust it. Choices are staged until Apply.
struct TrustedContactsPickerView: View {
  @Environment(\.appState) private var appState
  @State private var contacts: [ContactDTO] = []
  @State private var searchText = ""
  @State private var showFavoritesOnly = false
  @State private var pendingTrustedIDs: Set<UUID> = []
  @State private var initialTrustedIDs: Set<UUID> = []
  @State private var isApplying = false
  @State private var errorMessage: String?
  @State private var successTrigger = 0
  @State private var loadFailed = false

  private var settingsModified: Bool {
    pendingTrustedIDs != initialTrustedIDs
  }

  private var canApply: Bool {
    appState.connectionState == .ready && settingsModified && !isApplying
  }

  /// The contacts trusted when the page opened come first, then by name. Fixed for the visit, so a
  /// row doesn't move from under the finger when tapped.
  private var filteredContacts: [ContactDTO] {
    var result = contacts.sorted { lhs, rhs in
      let lhsTrusted = initialTrustedIDs.contains(lhs.id)
      if lhsTrusted != initialTrustedIDs.contains(rhs.id) { return lhsTrusted }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
    if showFavoritesOnly {
      result = result.filter(\.isFavorite)
    }
    if !searchText.isEmpty {
      result = result.filter { $0.displayName.localizedStandardContains(searchText) }
    }
    return result
  }

  var body: some View {
    CardForm {
      // All or Favorites, as one control rather than a full switch card.
      Picker(L10n.Settings.TrustedContacts.favoritesOnly, selection: $showFavoritesOnly) {
        Text(L10n.Contacts.Contacts.Discovery.Segment.all).tag(false)
        Text(L10n.Contacts.Contacts.Segment.favorites).tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      CardFormSection {
        if loadFailed {
          // The error itself is in the alert; this keeps a way back to the list.
          ActionCard(L10n.Localizable.Common.tryAgain, systemImage: "arrow.clockwise", color: .blue) {
            Task { await loadContacts() }
          }
        } else if filteredContacts.isEmpty {
          emptyState
            .cardSurface(padding: 12)
        } else {
          // One card per contact, lazily: a radio can hold hundreds.
          LazyVStack(spacing: CardStyle.spacing) {
            ForEach(filteredContacts) { contact in
              trustedContactCard(contact)
            }
          }
        }
      }
    }
    .disabled(isApplying)
    .searchable(text: $searchText, prompt: L10n.Settings.TrustedContacts.searchPrompt)
    .flashingNavigationTitle(L10n.Settings.TrustedContacts.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        // Filled once there's something to apply, so a staged change isn't left unsaved.
        Button { applyChanges() } label: {
          Text(L10n.Settings.TrustedContacts.apply)
            .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canApply)
      }
    }
    .cairnFeedback(.success, trigger: successTrigger)
    .errorAlert($errorMessage)
    .task {
      await loadContacts()
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if !searchText.isEmpty {
      ContentUnavailableView(
        L10n.Settings.TrustedContacts.noResults,
        systemImage: "magnifyingglass",
        description: Text(L10n.Settings.TrustedContacts.noResultsDescription(searchText))
      )
    } else if showFavoritesOnly {
      ContentUnavailableView(
        L10n.Settings.TrustedContacts.noResults,
        systemImage: "star.slash",
        description: Text(L10n.Settings.TrustedContacts.noFavorites)
      )
    } else {
      ContentUnavailableView(
        L10n.Settings.TrustedContacts.noContacts,
        systemImage: "person.2.slash",
        description: Text(L10n.Settings.TrustedContacts.noContactsDescription)
      )
    }
  }

  /// A contact as a selectable card: its avatar, name, short id and when it was last heard, and a
  /// check circle, filled when trusted. Tap to trust or untrust; staged until Apply.
  private func trustedContactCard(_ contact: ContactDTO) -> some View {
    let isTrusted = pendingTrustedIDs.contains(contact.id)
    let hashSize = max(1, appState.connectedDevice?.hashSize ?? 1)
    let heard = contact.recencyTimestamp > 0
      ? Date(timeIntervalSince1970: TimeInterval(contact.recencyTimestamp)).formatted(.relative(presentation: .named))
      : nil
    return Button {
      if isTrusted {
        pendingTrustedIDs.remove(contact.id)
      } else {
        pendingTrustedIDs.insert(contact.id)
      }
    } label: {
      HStack(spacing: 12) {
        ContactTypeAvatar(contact: contact, size: 36)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(contact.displayName)
              .font(.body.weight(.medium))
              .foregroundStyle(Color.primary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
            FavoriteStar(isFavorite: contact.isFavorite, label: L10n.Contacts.Contacts.Row.favorite)
          }
          Text(NodeRouteFormat.joined([contact.publicKey.prefix(hashSize).uppercaseHexString(), heard]))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: isTrusted ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isTrusted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
          .contentTransition(.symbolEffect(.replace))
          .accessibilityHidden(true)
      }
      .cardSurface(isSelected: isTrusted, padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isTrusted ? .isSelected : [])
  }

  private func loadContacts() async {
    guard let radioID = appState.connectedDevice?.radioID,
          let contactService = appState.services?.contactService else { return }
    do {
      loadFailed = false
      contacts = try await contactService.getContacts(radioID: radioID)
        .filter { $0.type == .chat }
      let trusted = Set(
        contacts
          .filter { ContactService.hasTelemetryPermissions(flags: $0.flags) }
          .map(\.id)
      )
      initialTrustedIDs = trusted
      pendingTrustedIDs = trusted
    } catch {
      loadFailed = true
      errorMessage = error.userFacingMessage
    }
  }

  private func applyChanges() {
    guard !isApplying else { return }
    guard let contactService = appState.services?.contactService else { return }

    isApplying = true
    Task {
      do {
        let toGrant = pendingTrustedIDs.subtracting(initialTrustedIDs)
        let toRevoke = initialTrustedIDs.subtracting(pendingTrustedIDs)

        for id in toGrant {
          try await contactService.setTelemetryPermissions(id, granted: true)
        }
        for id in toRevoke {
          try await contactService.setTelemetryPermissions(id, granted: false)
        }

        initialTrustedIDs = pendingTrustedIDs
        successTrigger += 1
      } catch {
        errorMessage = error.userFacingMessage
      }
      isApplying = false
    }
  }
}
