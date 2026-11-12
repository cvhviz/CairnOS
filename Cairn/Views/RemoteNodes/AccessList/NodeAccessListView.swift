import CairnServices
import MeshCore
import SwiftUI

/// Value-based push to a node's access list.
struct NodeAccessListRoute: Hashable {
  let session: RemoteNodeSessionDTO
}

extension View {
  /// Registers the access list destination on the enclosing navigation stack.
  func nodeAccessListDestination() -> some View {
    navigationDestination(for: NodeAccessListRoute.self) { route in
      NodeAccessListView(session: route.session)
    }
  }
}

/// Lists a repeater or room server's access control list and edits it with `setperm`.
struct NodeAccessListView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let session: RemoteNodeSessionDTO
  @State private var viewModel = NodeAccessListViewModel()
  @State private var pendingRemoval: AccessListItem?
  @State private var showingAddSheet = false

  private var isReady: Bool { appState.connectionState == .ready }

  var body: some View {
    List {
      content
    }
    .overlay {
      if showsPlaceholder {
        placeholder
      }
    }
    .cardListCanvas(theme)
    // Only once the list is showing: before that the placeholder says it's loading.
    .pageLoadingBar(isLoading: viewModel.isLoading && viewModel.hasLoaded)
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Acl.title)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await viewModel.load() }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        // How entries and roles work, in place of a paragraph under the list.
        InfoButton(L10n.RemoteNodes.RemoteNodes.Acl.footer, title: L10n.RemoteNodes.RemoteNodes.Acl.title)

        Button(L10n.RemoteNodes.RemoteNodes.Acl.add, systemImage: "plus") {
          showingAddSheet = true
        }
        .disabled(!isReady || !viewModel.hasLoaded || viewModel.isBusy)

        Button(L10n.RemoteNodes.RemoteNodes.Status.refresh, systemImage: "arrow.clockwise") {
          Task { await viewModel.load() }
        }
        .labelStyle(.iconOnly)
        .radioDisabled(for: appState.connectionState, or: viewModel.isBusy)
      }
    }
    .confirmationDialog(
      L10n.RemoteNodes.RemoteNodes.Acl.RemoveConfirm.title,
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { item in
      Button(L10n.RemoteNodes.RemoteNodes.Acl.remove, role: .destructive) {
        Task { await viewModel.remove(item) }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: { item in
      Text(L10n.RemoteNodes.RemoteNodes.Acl.RemoveConfirm.message(displayName(for: item)))
    }
    .sheet(isPresented: $showingAddSheet) {
      NodeAccessListAddSheet(
        candidates: viewModel.addableCandidates,
        defaultRole: session.isRoom ? .readWrite : .readOnly
      ) { candidate, role in
        Task { await viewModel.add(candidate, role: role) }
      }
    }
    .errorAlert($viewModel.errorMessage)
    .task {
      configureIfNeeded()
      if !viewModel.hasLoaded, isReady {
        await viewModel.load()
      }
    }
  }

  /// Whether the list has no entries to show yet: disconnected, loading, failed or empty. The
  /// state then shows as an overlay, centred on the page rather than as a row at its top.
  private var showsPlaceholder: Bool {
    (!viewModel.hasLoaded && (!isReady || viewModel.isLoading || viewModel.loadError != nil))
      || viewModel.items.isEmpty
  }

  @ViewBuilder
  private var placeholder: some View {
    if !isReady, !viewModel.hasLoaded {
      ContentUnavailableView(
        L10n.RemoteNodes.RemoteNodes.Acl.Disconnected.title,
        systemImage: "antenna.radiowaves.left.and.right.slash",
        description: Text(L10n.RemoteNodes.RemoteNodes.Acl.Disconnected.description)
      )
    } else if viewModel.isLoading, !viewModel.hasLoaded {
      ProgressView()
    } else if let error = viewModel.loadError, !viewModel.hasLoaded {
      ContentUnavailableView {
        Label(L10n.RemoteNodes.RemoteNodes.Acl.LoadFailed.title, systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        Button(L10n.Localizable.Common.tryAgain) {
          Task { await viewModel.load() }
        }
        .radioDisabled(for: appState.connectionState)
      }
    } else if viewModel.items.isEmpty {
      ContentUnavailableView(
        L10n.RemoteNodes.RemoteNodes.Acl.Empty.title,
        systemImage: "person.2.slash",
        description: Text(L10n.RemoteNodes.RemoteNodes.Acl.Empty.description)
      )
    }
  }

  @ViewBuilder
  private var content: some View {
    if !showsPlaceholder {
      // Each entry is its own card; the swipe and context menus stay on the row.
      ForEach(viewModel.items) { item in
        row(for: item)
          .cardListRow(theme)
      }
    }
  }

  private func row(for item: AccessListItem) -> some View {
    let actionsDisabled = !isReady || viewModel.isBusy
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(displayName(for: item))
            .lineLimit(1)
          if item.isSelf {
            Text(L10n.RemoteNodes.RemoteNodes.Acl.you)
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.tint.opacity(0.15), in: .capsule)
          }
        }
        Text(item.keyPrefix.uppercaseHexString(separator: " "))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer()
      if viewModel.pendingPrefix == item.keyPrefix {
        ProgressView()
          .controlSize(.small)
      } else {
        roleMenu(for: item, disabled: actionsDisabled)
      }
    }
    .accessibilityElement(children: .combine)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if item.canRemove {
        Button(L10n.RemoteNodes.RemoteNodes.Acl.remove, systemImage: "trash", role: .destructive) {
          pendingRemoval = item
        }
        .disabled(actionsDisabled)
      }
    }
    .contextMenu {
      if item.canChangeRole {
        roleButtons(for: item)
      }
      if item.canRemove {
        Button(L10n.RemoteNodes.RemoteNodes.Acl.remove, systemImage: "trash", role: .destructive) {
          pendingRemoval = item
        }
        .disabled(actionsDisabled)
      }
      Button(L10n.RemoteNodes.RemoteNodes.Acl.copyKey, systemImage: "doc.on.doc") {
        UIPasteboard.general.string = (item.fullPublicKey ?? item.keyPrefix).uppercaseHexString()
      }
    }
  }

  @ViewBuilder
  private func roleMenu(for item: AccessListItem, disabled: Bool) -> some View {
    let label = Label(item.role.localizedName, systemImage: item.role.systemImage)
      .font(.subheadline)
      .foregroundStyle(item.role == .admin ? Color.accentColor : .secondary)
    if item.canChangeRole {
      Menu {
        roleButtons(for: item)
      } label: {
        label
      }
      .disabled(disabled)
      .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Acl.changeRoleHint)
    } else {
      label
    }
  }

  @ViewBuilder
  private func roleButtons(for item: AccessListItem) -> some View {
    ForEach(AccessListRole.assignable) { role in
      Button {
        guard role != item.role else { return }
        Task { await viewModel.setRole(role, for: item) }
      } label: {
        if role == item.role {
          Label(role.localizedName, systemImage: "checkmark")
        } else {
          Text(role.localizedName)
        }
      }
      .disabled(!isReady || viewModel.isBusy)
    }
  }

  private func displayName(for item: AccessListItem) -> String {
    if item.isSelf, let name = appState.connectedDevice?.nodeName, !name.isEmpty {
      return name
    }
    return item.name ?? L10n.RemoteNodes.RemoteNodes.Acl.unknownNode
  }

  private func configureIfNeeded() {
    let radioID = session.radioID
    viewModel.configure(
      session: session,
      dependencies: .init(
        fetchACL: { [appState] publicKey in
          guard let service = appState.services?.binaryProtocolService else {
            throw ConnectionError.notConnected
          }
          return try await service.requestACL(from: publicKey)
        },
        sendCommand: { [appState] sessionID, command in
          guard let service = appState.services?.remoteNodeService else {
            throw ConnectionError.notConnected
          }
          return try await service.sendRawCLICommand(
            sessionID: sessionID,
            command: command,
            timeout: NodeAccessListViewModel.commandTimeout
          )
        },
        loadCandidates: { [appState] in
          guard let dataStore = appState.services?.dataStore else { return [] }
          let contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
          let discovered = await (try? dataStore.fetchDiscoveredNodes(radioID: radioID)) ?? []
          return contacts.map {
            AccessListCandidate(publicKey: $0.publicKey, name: $0.displayName, isChatContact: $0.type == .chat)
          } + discovered.map {
            AccessListCandidate(publicKey: $0.publicKey, name: $0.resolvableName)
          }
        },
        selfPublicKey: { [appState] in appState.connectedDevice?.publicKey }
      )
    )
  }
}

// MARK: - Add Sheet

/// Picks a saved chat contact and a role to add to the access list.
private struct NodeAccessListAddSheet: View {
  @Environment(\.dismiss) private var dismiss

  let candidates: [AccessListCandidate]
  let onAdd: (AccessListCandidate, AccessListRole) -> Void
  @State private var role: AccessListRole
  @State private var searchText = ""
  @State private var pendingAdmin: AccessListCandidate?

  init(
    candidates: [AccessListCandidate],
    defaultRole: AccessListRole,
    onAdd: @escaping (AccessListCandidate, AccessListRole) -> Void
  ) {
    self.candidates = candidates
    self.onAdd = onAdd
    _role = State(initialValue: defaultRole)
  }

  private var filtered: [AccessListCandidate] {
    let sorted = candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    guard !searchText.isEmpty else { return sorted }
    return sorted.filter { $0.name.localizedStandardContains(searchText) }
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection(footer: L10n.RemoteNodes.RemoteNodes.Acl.addFooter) {
          PickerCard(L10n.RemoteNodes.RemoteNodes.Acl.role, selection: $role) {
            ForEach(AccessListRole.assignable) { role in
              Text(role.localizedName).tag(role)
            }
          }
        }

        CardFormSection {
          if filtered.isEmpty {
            ContentUnavailableView(
              L10n.RemoteNodes.RemoteNodes.Acl.NoContacts.title,
              systemImage: "person.2.slash",
              description: Text(L10n.RemoteNodes.RemoteNodes.Acl.NoContacts.description)
            )
          } else {
            LazyVStack(spacing: CardStyle.spacing) {
              ForEach(filtered) { candidate in
                Button {
                  if role == .admin {
                    pendingAdmin = candidate
                  } else {
                    onAdd(candidate, role)
                    dismiss()
                  }
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                      .foregroundStyle(.primary)
                    Text(candidate.publicKey.prefix(6).uppercaseHexString(separator: " "))
                      .font(.caption.monospaced())
                      .foregroundStyle(.secondary)
                  }
                  .cardSurface()
                  .cardInteractionShape()
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }
      .searchable(text: $searchText)
      .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Acl.add)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        }
      }
      .confirmationDialog(
        L10n.RemoteNodes.RemoteNodes.Acl.AdminConfirm.title,
        isPresented: Binding(
          get: { pendingAdmin != nil },
          set: { if !$0 { pendingAdmin = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingAdmin
      ) { candidate in
        Button(L10n.RemoteNodes.RemoteNodes.Acl.AdminConfirm.grant) {
          onAdd(candidate, .admin)
          dismiss()
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } message: { candidate in
        Text(L10n.RemoteNodes.RemoteNodes.Acl.AdminConfirm.message(candidate.name))
      }
    }
  }
}
