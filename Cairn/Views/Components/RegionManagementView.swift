import CairnServices
import SwiftUI

/// Manage Regions: the radio's known regions, with add, delete and Discover Nearby Regions. The
/// one page for them, reached from Settings → Radio and from a channel's Region picker, so both
/// edit the same list the same way. Discovery offers what it finds in
/// `RegionDiscoveryResultsView` instead of adding everything.
struct RegionManagementView: View {
  @Environment(\.appState) private var appState
  @State private var searchText = ""
  @State private var isEditing = false
  @State private var showingAddSheet = false
  @State private var discovery = RegionDiscoveryRunner()
  @State private var discoveryAddError: String?

  private var knownRegions: [String] {
    appState.connectedDevice?.knownRegions ?? []
  }

  private var filteredRegions: [String] {
    let sorted = knownRegions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    guard !searchText.isEmpty else { return sorted }
    return sorted.filter { $0.localizedStandardContains(searchText) }
  }

  var body: some View {
    CardForm {
      if knownRegions.isEmpty {
        RegionManagementEmptyState()
      } else if filteredRegions.isEmpty {
        // A search that matches nothing: say so rather than leave an empty section.
        ContentUnavailableView.search(text: searchText)
          .cardSurface(padding: 12)
      } else {
        KnownRegionsSection(
          regions: filteredRegions,
          isEditing: isEditing,
          onDeleteRegion: removeRegion
        )
      }

      ActionsSection(
        isConnected: appState.connectedDevice != nil,
        isDiscovering: discovery.isDiscovering,
        discoveryMessage: discovery.message,
        onDiscoverTapped: { discovery.run(appState: appState) },
        onAddTapped: { showingAddSheet = true }
      )
    }
    .flashingNavigationTitle(L10n.Chats.Chats.ChannelInfo.Region.manage)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      // A long press alone is undiscoverable, and a Mac mouse can't swipe: Edit puts a remove
      // button on every card.
      if !knownRegions.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button(isEditing ? L10n.Localizable.Common.done : L10n.Localizable.Common.edit) {
            withAnimation { isEditing.toggle() }
          }
        }
      }
    }
    .onChange(of: knownRegions.isEmpty) { _, isEmpty in
      if isEmpty { isEditing = false }
    }
    .modifier(SearchableModifier(searchText: $searchText, isEnabled: isSearchEnabled))
    .onChange(of: isSearchEnabled) { _, enabled in
      // Deleting regions below the threshold hides the search bar; a filter left behind would
      // then hide regions with no way to clear it.
      if !enabled { searchText = "" }
    }
    .sheet(isPresented: $showingAddSheet) {
      RegionAddSheet(knownRegions: knownRegions) { region in
        try await appState.connectionManager.addKnownRegion(region)
      }
    }
    .navigationDestination(isPresented: Binding(
      get: { discovery.discoveredRegions != nil },
      set: { if !$0 { discovery.discoveredRegions = nil } }
    )) {
      RegionDiscoveryResultsView(discoveredRegions: discovery.discoveredRegions ?? [], onAdd: addDiscovered)
    }
    .errorAlert($discoveryAddError)
    // A run ends before its results are pushed, so this only stops one the user walked away from.
    .onDisappear { discovery.cancel() }
  }

  private var isSearchEnabled: Bool {
    knownRegions.count >= 15
  }

  private func removeRegion(_ region: String) {
    appState.connectionManager.removeKnownRegion(region)
  }

  /// The results page closes as soon as Add is tapped, so a region that didn't make it is reported
  /// here, once, rather than left missing from the list without a word.
  private func addDiscovered(_ regions: [String]) {
    Task {
      var failure: RegionAddSubmission.Failure?
      for region in regions {
        do {
          try await appState.connectionManager.addKnownRegion(region)
        } catch {
          failure = RegionAddSubmission.Failure(error)
          // With no radio the rest would fail the same way.
          if failure == .notConnected { break }
        }
      }
      if let failure {
        discoveryAddError = RegionAddSheet.message(for: failure)
      }
    }
  }
}

// MARK: - Extracted Views

/// A sheet, not an alert with a text field: every presentation starts from fresh state, and an
/// invalid name is explained in place instead of by presenting the alert again.
private struct RegionAddSheet: View {
  @Environment(\.dismiss) private var dismiss

  let knownRegions: [String]
  let onAdd: @MainActor (String) async throws -> Void

  @State private var submission = RegionAddSubmission()
  @FocusState private var nameFieldFocused: Bool

  static func message(for failure: RegionAddSubmission.Failure) -> String {
    switch failure {
    case .notConnected:
      L10n.Chats.Chats.ChannelInfo.Region.addFailed
    case .notSaved:
      L10n.Chats.Chats.ChannelInfo.Region.saveFailed
    }
  }

  private var errorText: String? {
    if let failure = submission.failure {
      return Self.message(for: failure)
    }
    switch submission.validationError(existingRegions: knownRegions) {
    case .invalidCharacters:
      return L10n.Chats.Chats.ChannelInfo.Region.invalidName
    case .privateRegion:
      return L10n.Chats.Chats.ChannelInfo.Region.privateName
    case let .tooLong(maxBytes):
      return L10n.Chats.Chats.ChannelInfo.Region.nameTooLong(maxBytes)
    case .duplicate:
      return L10n.Chats.Chats.ChannelInfo.Region.duplicate
    case .empty, nil:
      return nil
    }
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection {
          ContentCard {
            TextField(L10n.Chats.Chats.ChannelInfo.Region.addRegionPlaceholder, text: $submission.name)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused($nameFieldFocused)
              .onSubmit(add)
          }

          if let errorText {
            Text(errorText)
              .foregroundStyle(.red)
              .font(.caption)
              .padding(.horizontal, 4)
          }
        }
      }
      .flashingNavigationTitle(L10n.Chats.Chats.ChannelInfo.Region.addRegionTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Chats.Chats.ChannelInfo.Region.addSelected, action: add)
            .disabled(!submission.canSubmit(existingRegions: knownRegions))
        }
      }
      .onAppear { nameFieldFocused = true }
    }
  }

  private func add() {
    guard let name = submission.submit(existingRegions: knownRegions) else { return }
    Task {
      do {
        try await onAdd(name)
        submission.markAdded()
        dismiss()
      } catch {
        submission.markFailed(RegionAddSubmission.Failure(error))
      }
    }
  }
}

private struct RegionManagementEmptyState: View {
  var body: some View {
    ContentUnavailableView {
      Label(L10n.Chats.Chats.ChannelInfo.Region.noRegions, systemImage: "map")
    } description: {
      Text(L10n.Chats.Chats.ChannelInfo.Region.noRegionsDescription)
    }
    .cardSurface(padding: 12)
  }
}

/// The known regions, one card each. Delete is in each card's context menu, and in Edit mode a
/// remove button leads every card (labelled "Remove, <name>" like a list's edit control).
private struct KnownRegionsSection: View {
  let regions: [String]
  let isEditing: Bool
  let onDeleteRegion: (String) -> Void

  var body: some View {
    CardFormSection {
      ForEach(regions, id: \.self) { region in
        HStack(spacing: 12) {
          if isEditing {
            Button {
              withAnimation { onDeleteRegion(region) }
            } label: {
              Image(systemName: "minus.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Chats.Chats.ChannelInfo.Region.removeRegion(region))
            .transition(.move(edge: .leading).combined(with: .opacity))
          }
          RegionRow(name: region)
        }
        .cardSurface(padding: 12)
        .cardInteractionShape()
        .contextMenu {
          Button(role: .destructive) {
            onDeleteRegion(region)
          } label: {
            Label(L10n.Localizable.Common.delete, systemImage: "trash")
          }
        }
      }
    }
  }
}

private struct RegionRow: View {
  let name: String

  private var isPrivate: Bool {
    name.isPrivateRegion
  }

  var body: some View {
    HStack {
      Text(name)
      Spacer()
      if isPrivate {
        Text(L10n.Chats.Chats.ChannelInfo.Region.private)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

private struct ActionsSection: View {
  /// Known regions belong to a radio, so neither action has anywhere to put a region without one.
  let isConnected: Bool
  let isDiscovering: Bool
  let discoveryMessage: String?
  let onDiscoverTapped: () -> Void
  let onAddTapped: () -> Void

  var body: some View {
    CardFormSection(footer: isConnected ? nil : L10n.Chats.Chats.ChannelInfo.Region.connectRadio) {
      if isDiscovering {
        ContentCard {
          HStack {
            ProgressView()
            Text(L10n.Chats.Chats.ChannelInfo.Region.discovering)
              .foregroundStyle(.secondary)
          }
        }
      }

      // The last run's result sits on the action it reports on.
      ActionCard(
        L10n.Chats.Chats.ChannelInfo.Region.discover,
        systemImage: "antenna.radiowaves.left.and.right",
        color: .blue,
        subtitle: isDiscovering ? nil : discoveryMessage
      ) {
        onDiscoverTapped()
      }
      .dimmedWhenDisabled()
      .disabled(isDiscovering || !isConnected)

      // The naming rule isn't spelled out here: the Add sheet shows it as soon as a name breaks it.
      ActionCard(L10n.Chats.Chats.ChannelInfo.Region.addManually, systemImage: "plus", color: .green) {
        onAddTapped()
      }
      .dimmedWhenDisabled()
      .disabled(!isConnected)
    }
  }
}

/// Conditionally applies `.searchable()` when the region count warrants it
private struct SearchableModifier: ViewModifier {
  @Binding var searchText: String
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content.searchable(text: $searchText)
    } else {
      content
    }
  }
}
