import CoreLocation
import CairnServices
import SwiftUI

/// The nodes list. From iOS 27 on it is a `ScrollView` + `LazyVStack` with the swipe-actions
/// container rather than a `List`: `List` is backed by `UpdateCoalescingCollectionView`, whose
/// batch-consistency assertion is violated when the selected row is deleted; a `LazyVStack` has
/// no collection view, so that crash cannot occur. Before iOS 27 row swipe actions work only in a
/// `List`, so there the same rows go in a plain `List` dressed to match (`NodeListHosting`); it
/// gets no selection binding, which is what tripped the assertion, and selection stays a tap on
/// the row. One view serves both layouts: the compact stack navigates via `NavigationLink`, the
/// iPad split drives a selection binding the detail column reads. In select mode
/// (`ContactsViewModel.isSelecting`) a tap picks the row instead.
struct ContactsListContent: View {
  enum ListMode {
    case selection(Binding<ContactDTO?>)
    case navigation
  }

  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let mode: ListMode
  let displayMode: NodeDisplayMode
  @Binding var selectedSegment: NodeSegment
  @AppStorage(AppStorageKey.nodesFavoritesOnly.rawValue) private var favoritesOnly = false
  @AppStorage(NodeFavoritesGrouping.collapsedKey.rawValue) private var favoritesCollapsed = false
  @AppStorage(NodeFavoritesGrouping.othersCollapsedKey.rawValue) private var othersCollapsed = false
  /// The segment header's height, so the empty state centres in the space under it.
  @State private var headerHeight: CGFloat = 0
  let isSearching: Bool
  @Binding var searchText: String
  let searchPrompt: String
  let filteredContacts: [ContactDTO]
  let hasLoadedOnce: Bool
  let viewModel: ContactsViewModel
  /// The Manual sort: a node can be dragged onto another's place.
  var isReorderable = false
  let onRefresh: () async -> Void

  /// Zero-height `scrollTo` target used after pull-to-refresh.
  private static let topScrollAnchor = "nodesListTop"

  /// Bumped after the search field has been scrolled into view, so the field takes focus (⌘F).
  @State private var searchFocusRequest = 0

  var body: some View {
    Group {
      if !hasLoadedOnce {
        loadingBody
      } else {
        loadedBody
      }
    }
    // Cards are the grouped secondary color; on a plain page they would vanish.
    .cardCanvas(theme)
  }

  private var loadingBody: some View {
    refreshableScroll {
      segmentHeader
        .nodeListRow()
    }
    .overlay { ProgressView() }
  }

  private var loadedBody: some View {
    refreshableScroll {
      segmentHeader
        .nodeListRow()
      loadedItems
    }
    // A node favorited or unfavorited moves between the group and the list below it. Keyed on
    // membership alone, so search, segment, filter and sort changes stay instant.
    .animation(
      reduceMotion ? nil : .snappy,
      value: NodeFavoritesGrouping.favoriteMembership(viewModel.contacts)
    )
  }

  /// The list's rows after the segment header: the empty state, or the nodes in their groups.
  /// Each is its own `List` row before iOS 27 and a `LazyVStack` child after.
  @ViewBuilder
  private var loadedItems: some View {
    let grouping = NodeFavoritesGrouping(filteredContacts, favoritesOnly: favoritesOnly)
    if filteredContacts.isEmpty {
      emptyState
        .nodeListRow()
    } else {
      // The favorites first, in a group that folds away, then the rest under a header of
      // their own that folds the same way; each node is listed once. Without favorites
      // the list is flat, with no headers.
      if grouping.showsFavoritesGroup {
        NodeGroupHeader(kind: .favorites, count: grouping.favorites.count, isCollapsed: $favoritesCollapsed)
          .nodeListRow()
        if !favoritesCollapsed {
          nodes(grouping.favorites)
        }
        if !grouping.others.isEmpty {
          NodeGroupHeader(kind: .others, count: grouping.others.count, isCollapsed: $othersCollapsed)
            .nodeListRow()
          if !othersCollapsed {
            nodes(grouping.others)
          }
        }
      } else {
        nodes(grouping.others)
      }
    }
  }

  /// The rows in their container: the search field, then `content` as the rows. A `ScrollView`
  /// with the swipe container from iOS 27 on, a plain `List` before (`NodeListHosting`).
  private func refreshableScroll(@ViewBuilder content: () -> some View) -> some View {
    let rows = content()
    return ScrollViewReader { proxy in
      Group {
        if NodeListHosting.usesList {
          List {
            PullDownSearchRows(text: $searchText, prompt: searchPrompt, proxy: proxy, focusRequest: searchFocusRequest)
            Color.clear
              .frame(height: 0)
              .id(Self.topScrollAnchor)
              .nodeListRow()
            rows
          }
          .nodeListStyle(spacing: CardStyle.spacing)
        } else {
          ScrollView {
            // Search waits above the list until it's pulled down.
            PullDownSearch(text: $searchText, prompt: searchPrompt, proxy: proxy, focusRequest: searchFocusRequest) {
              // No spacing: the anchor would otherwise push the list 8 pt below where Heard's starts.
              VStack(spacing: 0) {
                Color.clear
                  .frame(height: 0)
                  .id(Self.topScrollAnchor)
                // One card per node in either layout, with the card gap between them.
                LazyVStack(spacing: CardStyle.spacing) {
                  rows
                }
              }
            }
          }
          .swipeActionsContainerIfAvailable()
        }
      }
      .refreshable {
        await onRefresh()
        // `.refreshable` on ScrollView leaves the large title jumped; scrollTo restacks it.
        // https://stackoverflow.com/questions/75718110
        Task { @MainActor in
          proxy.scrollTo(Self.topScrollAnchor, anchor: .top)
        }
      }
      .refreshCommand { await onRefresh() }
      // ⌘F: the field back into view, then focused once it's there.
      .onChange(of: appState.navigation.nodesSearchRequestVersion) { _, version in
        withAnimation(reduceMotion ? nil : .snappy) {
          proxy.scrollTo(PullDownSearch<EmptyView>.fieldID, anchor: .top)
        }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          searchFocusRequest = version
        }
      }
    }
  }

  // MARK: - Selection

  private func selectionState(for contact: ContactDTO) -> DiscoverySelectionState {
    guard viewModel.isSelecting else { return .off }
    return viewModel.isSelected(contact) ? .selected : .unselected
  }

  private func toggleSelection(_ contact: ContactDTO) {
    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { viewModel.toggleSelection(contact) }
  }

  /// Saved | Heard on top, then this list's own filter pills (or the active group's bar).
  private var segmentHeader: some View {
    VStack(spacing: 0) {
      NodesSectionPicker()
      if let group = viewModel.selectedGroup {
        ContactGroupFilterBar(group: group, viewModel: viewModel)
      } else {
        NodeSegmentPicker(selection: $selectedSegment, isSearching: isSearching)
      }
    }
    .frame(maxWidth: .infinity)
    .nodeListHeaderBackground(theme)
    .measuringHeight($headerHeight)
  }

  private var emptyState: some View {
    Group {
      if isSearching {
        ContactsSearchEmptyView(searchText: searchText)
      } else if viewModel.selectedGroup != nil {
        ContentUnavailableView(
          L10n.Contacts.Contacts.Groups.filterEmptyTitle,
          systemImage: "person.3",
          description: Text(L10n.Contacts.Contacts.Groups.filterEmptyDescription)
        )
      } else {
        ContactsEmptyView(selectedSegment: selectedSegment, favoritesOnly: favoritesOnly)
      }
    }
    .emptyStateFrame(below: headerHeight)
  }

  /// A run of nodes in the chosen layout: the Favorites group's, or the list under it.
  @ViewBuilder
  private func nodes(_ contacts: [ContactDTO]) -> some View {
    if contacts.isEmpty {
      EmptyView()
    } else if displayMode == .cards {
      cards(contacts)
    } else {
      rows(contacts)
    }
  }

  /// The list layout: compact rows joined into one inset group with hairline separators (see
  /// `CompactNodeList`). The page inset goes outside the row's swipe actions, so a swipe moves
  /// the row alone.
  private func rows(_ contacts: [ContactDTO]) -> some View {
    let firstID = contacts.first?.id
    let lastID = contacts.last?.id
    return ForEach(contacts) { contact in
      let position = CompactNodeRowPosition(isFirst: contact.id == firstID, isLast: contact.id == lastID)
      rowView(contact, position: position)
        .modifier(reorder(contact))
        .padding(.horizontal, CardStyle.pageInset)
        // The `List` spaces its rows itself; the stack needs the gap after the group's last row.
        .padding(.bottom, position.isLast && !NodeListHosting.usesList ? CardStyle.spacing : 0)
        .transition(.opacity)
        .nodeListRow()
    }
  }

  /// In the Manual sort, the node can be picked up and dropped onto another's place.
  private func reorder(_ contact: ContactDTO) -> NodeReorderModifier {
    NodeReorderModifier(contact: contact, isEnabled: isReorderable) { key in
      withAnimation(reduceMotion ? nil : .snappy) {
        viewModel.moveNode(key, onto: contact.publicKey, shown: filteredContacts)
      }
    }
  }

  /// The card layout: a grid inside the same section, so the segment header stays pinned above
  /// it. Swipe actions are left out here; the context menu carries every one of them.
  private func cards(_ contacts: [ContactDTO]) -> some View {
    LazyCardGrid {
      ForEach(contacts) { contact in
        cardView(contact)
          .modifier(reorder(contact))
          .transition(.opacity)
      }
    }
    .padding(.horizontal, CardStyle.pageInset)
    .padding(.bottom, CardStyle.spacing)
    .nodeListRow()
  }

  @ViewBuilder
  private func cardView(_ contact: ContactDTO) -> some View {
    switch mode {
    case let .selection(selection):
      ContactSelectionCard(
        contact: contact,
        viewModel: viewModel,
        isSearching: isSearching,
        userLocation: appState.bestAvailableLocation,
        isSelected: selection.wrappedValue?.id == contact.id,
        pick: selectionState(for: contact),
        onSelect: { selection.wrappedValue = contact },
        onToggle: { toggleSelection(contact) }
      )
    case .navigation:
      ContactNavigationCard(
        contact: contact,
        viewModel: viewModel,
        isSearching: isSearching,
        userLocation: appState.bestAvailableLocation,
        pick: selectionState(for: contact),
        onToggle: { toggleSelection(contact) }
      )
    }
  }

  @ViewBuilder
  private func rowView(_ contact: ContactDTO, position: CompactNodeRowPosition) -> some View {
    switch mode {
    case let .selection(selection):
      ContactSelectionRow(
        contact: contact,
        viewModel: viewModel,
        isSearching: isSearching,
        userLocation: appState.bestAvailableLocation,
        position: position,
        isSelected: selection.wrappedValue?.id == contact.id,
        pick: selectionState(for: contact),
        onSelect: { selection.wrappedValue = contact },
        onToggle: { toggleSelection(contact) }
      )
    case .navigation:
      ContactNavigationRow(
        contact: contact,
        viewModel: viewModel,
        isSearching: isSearching,
        userLocation: appState.bestAvailableLocation,
        position: position,
        pick: selectionState(for: contact),
        onToggle: { toggleSelection(contact) }
      )
    }
  }
}

// MARK: - Reordering

/// Drag to reorder, for the Manual sort: the node lifts on a long press and drops onto another
/// node, whose place it takes. Carried as its key in hex. Off, the view is left as it is, so the
/// other sorts keep their long press for the context menu alone.
private struct NodeReorderModifier: ViewModifier {
  let contact: ContactDTO
  let isEnabled: Bool
  /// The dropped node's key.
  let onDrop: (Data) -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .draggable(contact.publicKey.uppercaseHexString())
        .dropDestination(for: String.self) { items, _ in
          guard let hex = items.first, let key = Data(hexString: hex), key != contact.publicKey else { return false }
          onDrop(key)
          return true
        }
    } else {
      content
    }
  }
}

// MARK: - Row Layout

/// Renders a node's compact row in its slice of the list group, shared by the selection and
/// navigation rows. The node open in the iPad detail column gets the selected wash and outline.
private struct ContactListRowLabel: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let isSearching: Bool
  let userLocation: CLLocation?
  let position: CompactNodeRowPosition
  var isSelected = false
  /// Select mode's mark, leading the avatar as on the Heard list.
  var pick: DiscoverySelectionState = .off

  var body: some View {
    HStack(spacing: CompactNodeList.avatarSpacing) {
      if pick != .off {
        DiscoverySelectionMark(isSelected: pick == .selected)
      }
      ContactCompactRowView(
        contact: contact,
        showTypeLabel: isSearching,
        userLocation: userLocation,
        isTogglingFavorite: viewModel.togglingFavoriteID == contact.id,
        inboundHopCount: viewModel.inboundHopByKey[contact.publicKey]
      )
    }
    .compactNodeRowBackground(position, isSelected: isSelected || pick == .selected)
  }
}

// MARK: - Extracted Rows

private struct ContactSelectionRow: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let isSearching: Bool
  let userLocation: CLLocation?
  let position: CompactNodeRowPosition
  let isSelected: Bool
  let pick: DiscoverySelectionState
  let onSelect: () -> Void
  let onToggle: () -> Void

  private var isDeleting: Bool {
    viewModel.deletingIDs.contains(contact.id)
  }

  var body: some View {
    Button(action: onSelect) {
      ContactListRowLabel(
        contact: contact,
        viewModel: viewModel,
        isSearching: isSearching,
        userLocation: userLocation,
        position: position,
        isSelected: isSelected,
        pick: pick
      )
    }
    .buttonStyle(.plain)
    .compactNodeRowInteractionShape(position)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .deletingRowOverlay(isDeleting: isDeleting)
    .contactContextMenu(contact: contact, viewModel: viewModel)
    .contactSwipeActions(contact: contact, viewModel: viewModel, isEnabled: pick == .off)
    .discoverySelectable(pick, shape: position.shape, onToggle: onToggle)
  }
}

private struct ContactNavigationRow: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let isSearching: Bool
  let userLocation: CLLocation?
  let position: CompactNodeRowPosition
  let pick: DiscoverySelectionState
  let onToggle: () -> Void

  private var isDeleting: Bool {
    viewModel.deletingIDs.contains(contact.id)
  }

  private var label: some View {
    ContactListRowLabel(
      contact: contact,
      viewModel: viewModel,
      isSearching: isSearching,
      userLocation: userLocation,
      position: position,
      pick: pick
    )
  }

  var body: some View {
    Group {
      if NodeListHosting.usesList {
        // In a `List` a visible link draws a disclosure chevron the cards don't want, so the link
        // sits unseen over the row and the cell's tap opens it. Left out while picking nodes, so
        // the tap picks the row instead.
        label
          .overlay {
            if pick == .off {
              NavigationLink(value: ContactRoute.detail(contact)) { EmptyView() }
                .opacity(0)
            }
          }
      } else {
        NavigationLink(value: ContactRoute.detail(contact)) { label }
          .buttonStyle(.plain)
      }
    }
    .compactNodeRowInteractionShape(position)
    .deletingRowOverlay(isDeleting: isDeleting)
    .contactContextMenu(contact: contact, viewModel: viewModel)
    .contactSwipeActions(contact: contact, viewModel: viewModel, isEnabled: pick == .off)
    .discoverySelectable(pick, shape: position.shape, onToggle: onToggle)
  }
}

// MARK: - Extracted Cards

/// Renders a node's card body, shared by the selection and navigation cards.
private struct ContactListCardLabel: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let isSearching: Bool
  let userLocation: CLLocation?
  var isSelected = false
  /// Select mode's mark, in the card's top trailing corner.
  var pick: DiscoverySelectionState = .off

  var body: some View {
    ContactCardView(
      contact: contact,
      showTypeLabel: isSearching,
      userLocation: userLocation,
      isTogglingFavorite: viewModel.togglingFavoriteID == contact.id,
      inboundHopCount: viewModel.inboundHopByKey[contact.publicKey],
      isSelected: isSelected || pick == .selected
    )
    .overlay(alignment: .topTrailing) {
      if pick != .off {
        DiscoverySelectionMark(isSelected: pick == .selected)
          .padding(8)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ContactSelectionCard: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let isSearching: Bool
  let userLocation: CLLocation?
  let isSelected: Bool
  let pick: DiscoverySelectionState
  let onSelect: () -> Void
  let onToggle: () -> Void

  var body: some View {
    Button(action: onSelect) {
      ContactListCardLabel(
        contact: contact,
        viewModel: viewModel,
        isSearching: isSearching,
        userLocation: userLocation,
        isSelected: isSelected,
        pick: pick
      )
    }
    .buttonStyle(.plain)
    .cardInteractionShape()
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .deletingRowOverlay(isDeleting: viewModel.deletingIDs.contains(contact.id))
    .contactContextMenu(contact: contact, viewModel: viewModel)
    .discoverySelectable(pick, shape: CardStyle.shape, onToggle: onToggle)
  }
}

private struct ContactNavigationCard: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let isSearching: Bool
  let userLocation: CLLocation?
  let pick: DiscoverySelectionState
  let onToggle: () -> Void

  var body: some View {
    NavigationLink(value: ContactRoute.detail(contact)) {
      ContactListCardLabel(contact: contact, viewModel: viewModel, isSearching: isSearching, userLocation: userLocation, pick: pick)
    }
    .buttonStyle(.plain)
    .cardInteractionShape()
    .deletingRowOverlay(isDeleting: viewModel.deletingIDs.contains(contact.id))
    .contactContextMenu(contact: contact, viewModel: viewModel)
    .discoverySelectable(pick, shape: CardStyle.shape, onToggle: onToggle)
  }
}
