import CoreLocation
import CairnServices
import SwiftUI

// The repeater's own section pages, opened from the dashboard buttons on its status page. The
// battery curve and sensor pages are shared with rooms (`NodeSectionPages.swift`).

// MARK: - Contact Info Page

/// The owner's contact text and the firmware version, read from the node when the page first
/// appears; reload or pull to read again.
struct RepeaterOwnerInfoPage: View {
  let viewModel: RepeaterStatusViewModel
  let session: RemoteNodeSessionDTO
  let connectionState: DeviceConnectionState

  var body: some View {
    CardForm {
      NodeSectionCard(.ownerInfo) {
        SectionReloadButton(
          isLoading: viewModel.isLoadingOwnerInfo,
          isLoaded: viewModel.ownerInfoLoaded,
          hasError: viewModel.ownerInfoError != nil,
          isDisabled: connectionState != .ready,
          accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.Accessibility.reloadOwnerInfo,
          onReload: { await viewModel.requestOwnerInfo(for: session) }
        )
      } content: {
        if viewModel.isLoadingOwnerInfo {
          NodeCardStatusLine(kind: .loading)
        } else if let error = viewModel.ownerInfoError {
          NodeCardStatusLine(kind: .error(error))
        } else {
          if let info = viewModel.ownerInfo, !info.isEmpty {
            Text(info)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            NodeCardStatusLine(kind: .note(L10n.RemoteNodes.RemoteNodes.Status.noOwnerInfo))
          }
          // Firmware is a sibling of owner_info in the wire response, so it can be present
          // even when owner_info is empty; keep it out of the owner-text branch.
          if let firmware = viewModel.firmwareVersion {
            Divider()
            LabeledContent(L10n.RemoteNodes.RemoteNodes.Settings.firmware, value: firmware)
          }
        }
      }
    }
    .pageLoadingBar(isLoading: viewModel.isLoadingOwnerInfo)
    .refreshable {
      guard connectionState == .ready, !viewModel.isLoadingOwnerInfo else { return }
      // Shielded from the refresh task's cancellation when the reply lands mid-refresh.
      await Task { await viewModel.requestOwnerInfo(for: session) }.value
    }
    .onAppear {
      guard !viewModel.ownerInfoLoaded, !viewModel.isLoadingOwnerInfo else { return }
      Task { await viewModel.requestOwnerInfo(for: session) }
    }
    .flashingNavigationTitle(NodeSectionPage.ownerInfo.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Neighbors Page

/// The neighbours page. Its title card holds the count, reload, the loading/error/empty state and
/// the discover control; each neighbour then follows as its own card, current ones first and then
/// those missing since the last visit. The cards stack lazily, as a busy repeater can list many.
struct RepeaterNeighborsPage: View {
  let viewModel: RepeaterStatusViewModel
  let session: RemoteNodeSessionDTO
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  let userLocation: CLLocation?
  let connectionState: DeviceConnectionState
  /// The admin's command line, for removing a neighbour from the repeater's list; nil for a guest.
  var sendCommand: ((String) async throws -> String)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The neighbour whose detail page is open. Item-pushed, not a value route: this page is itself
  /// item-pushed, and mixing the two on one stack bounced the push back and forth.
  @State private var openNeighbor: NeighborSelection?
  /// The neighbours' map, pushed the same item-driven way for the same reason.
  @State private var showsMap = false
  /// How the list is ordered; the firmware's order (last heard) until changed.
  @State private var sort: NeighborListSort = .lastHeard
  @State private var searchText = ""

  /// The name a neighbour shows, for sorting and searching.
  private func sortName(_ prefix: Data) -> String {
    displayName(for: prefix)
  }

  private func isNewNeighbor(_ prefix: Data) -> Bool {
    viewModel.helper.previousNeighborSnapshot?.neighborSnapshots != nil
      && !viewModel.helper.seenNeighborPrefixes.contains(prefix)
  }

  /// `neighbors` in the chosen order, cut to the search.
  private func arranged(_ neighbors: [Neighbour]) -> [Neighbour] {
    sort.sorted(
      NeighborListSort.filtered(neighbors, query: searchText, name: sortName),
      name: sortName,
      isNew: isNewNeighbor
    )
  }

  private var showsList: Bool {
    Self.showsList(
      isDiscovering: viewModel.isDiscovering,
      hasNeighbors: !viewModel.neighbors.isEmpty,
      isLoading: viewModel.isLoadingNeighbors,
      hasError: viewModel.neighborsSectionError != nil
    )
  }

  /// Discovery fills the list as replies arrive, so it shows through a running discovery. Outside
  /// one, neighbours already read stay listed through a reload or a failed one: a discovery's last
  /// poll timing out on a busy mesh used to hide every neighbour it had found until the page was
  /// opened again. With nothing to list, the card's own state (loading, the error) stands alone.
  static func showsList(isDiscovering: Bool, hasNeighbors: Bool, isLoading: Bool, hasError: Bool) -> Bool {
    isDiscovering || hasNeighbors || (!isLoading && !hasError)
  }

  private var disappeared: [NeighborSnapshotEntry] {
    guard let previous = viewModel.helper.previousNeighborSnapshot?.neighborSnapshots else { return [] }
    let currentPrefixes = Set(viewModel.neighbors.map(\.publicKeyPrefix))
    return previous.filter { !currentPrefixes.contains($0.publicKeyPrefix) }
  }

  private var statusLine: NodeCardStatusLine.Kind? {
    // A running discovery shows its own ring; only a poll that failed is said, so a list that stops
    // filling says why (the next poll, 5 s on, clears it when it gets through)
    if viewModel.isDiscovering {
      return viewModel.neighborsSectionError.map { .error($0) }
    }
    if viewModel.isLoadingNeighbors { return .loading }
    if let error = viewModel.neighborsSectionError { return .error(error) }
    if viewModel.neighborsLoaded, viewModel.neighbors.isEmpty {
      return .note(L10n.RemoteNodes.RemoteNodes.Status.noNeighbors)
    }
    return nil
  }

  var body: some View {
    CardForm {
      // Laid out like Scan for Nodes: the scan ring is Discover (admins), with where it stands
      // beside it, then a strip of what answered and the way onto the map.
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          if session.isAdmin {
            discoverButton
          } else {
            IconTile(systemImage: NodeSectionPage.neighbors.systemImage, color: NodeSectionPage.neighbors.color)
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(headline)
              .font(.headline)
              .monospacedDigit()
              .contentTransition(.numericText())
            if let discoverySubtitle {
              Text(discoverySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 0)
          // The neighbours on a map, beside the count it plots.
          if !viewModel.neighbors.isEmpty {
            Button {
              showsMap = true
            } label: {
              Image(systemName: "map.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.15), in: .circle)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Status.neighborsMapTitle)
            .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Status.Accessibility.viewNeighborsOnMap)
            .accessibilityIdentifier("neighbors.map")
          }
          InfoButton(
            L10n.RemoteNodes.RemoteNodes.Status.neighborsFooter,
            title: L10n.RemoteNodes.RemoteNodes.Status.neighbors
          )
          SectionReloadButton(
            isLoading: viewModel.isLoadingNeighbors && !viewModel.isDiscovering,
            isLoaded: viewModel.neighborsLoaded,
            hasError: viewModel.neighborsSectionError != nil,
            isDisabled: connectionState != .ready || viewModel.isDiscovering,
            accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.Accessibility.reloadNeighbors,
            onReload: { await viewModel.requestNeighbors(for: session) }
          )
        }
        if let statusLine {
          NodeCardStatusLine(kind: statusLine)
        }
        if !viewModel.neighbors.isEmpty {
          Divider()
          summaryStrip
        }
      }
      .cardSurface(padding: 12)

      if showsList {
        LazyVStack(spacing: CardStyle.spacing) {
          // After a discovery: who was heard since it started, then (faded) who the repeater heard
          // before, so a scan's answers stand out without clearing the repeater's table
          let split = viewModel.neighborsByScan
          let thisScan = arranged(split.thisScan)
          let before = arranged(split.before)
          if split.isSplit {
            scanHeading(L10n.RemoteNodes.RemoteNodes.Status.heardThisScan, count: thisScan.count)
          }
          ForEach(thisScan, id: \.publicKeyPrefix) { neighbor in
            neighborLink(for: neighbor)
          }
          if split.isSplit, !before.isEmpty {
            scanHeading(L10n.RemoteNodes.RemoteNodes.Status.heardBefore, count: before.count)
            ForEach(before, id: \.publicKeyPrefix) { neighbor in
              neighborLink(for: neighbor)
                .opacity(0.6)
            }
          }

          ForEach(disappeared, id: \.publicKeyPrefix) { old in
            let resolution = NeighborNameResolver.resolve(
              for: old.publicKeyPrefix,
              contacts: contacts,
              discoveredNodes: discoveredNodes,
              userLocation: userLocation
            )
            Button {
              openNeighbor = NeighborSelection(
                publicKeyPrefix: old.publicKeyPrefix,
                snr: old.snr,
                secondsAgo: nil,
                previousSNR: nil
              )
            } label: {
              DisappearedNeighborRow(
                neighbor: old,
                displayName: resolution?.displayName ?? NeighborNameResolver.fallbackName(
                  for: old.publicKeyPrefix,
                  byteCount: viewModel.neighborKeyDisplayByteCount
                ),
                matchKind: resolution?.matchKind ?? .unresolved
              )
              .cardSurface()
              .cardInteractionShape()
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    // A discovery shows its own ring; the bar is for the plain read.
    .pageLoadingBar(isLoading: viewModel.isLoadingNeighbors && !viewModel.isDiscovering)
    .refreshable {
      guard connectionState == .ready, !viewModel.isLoadingNeighbors, !viewModel.isDiscovering else { return }
      // Shielded from the refresh task's cancellation when the reply lands mid-refresh.
      await Task { await viewModel.requestNeighbors(for: session) }.value
    }
    // A running discovery loads the neighbours itself, so opening the page for it doesn't also
    // fetch. Unstructured, so opening a neighbour's chart doesn't cancel a read in flight.
    .onAppear {
      guard !viewModel.neighborsLoaded, !viewModel.isLoadingNeighbors, !viewModel.isDiscovering else { return }
      Task { await viewModel.requestNeighbors(for: session) }
    }
    .flashingNavigationTitle(NodeSectionPage.neighbors.title)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L10n.RemoteNodes.RemoteNodes.Neighbors.search)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker(L10n.RemoteNodes.RemoteNodes.Neighbors.sort, selection: $sort) {
            ForEach(NeighborListSort.allCases) { option in
              Label(option.title, systemImage: option.systemImage).tag(option)
            }
          }
        } label: {
          Label(L10n.RemoteNodes.RemoteNodes.Neighbors.sort, systemImage: "arrow.up.arrow.down.circle")
        }
        .accessibilityIdentifier("neighbors.sort")
      }
    }
    .navigationDestination(isPresented: $showsMap) {
      NeighborSNRMapView(
        session: session,
        neighbors: viewModel.neighbors,
        contacts: contacts,
        discoveredNodes: discoveredNodes,
        userLocation: userLocation,
        keyDisplayByteCount: viewModel.neighborKeyDisplayByteCount
      )
    }
    .navigationDestination(item: $openNeighbor) { selection in
      NeighborDetailPage(
        neighbor: selection,
        session: session,
        contacts: contacts,
        discoveredNodes: discoveredNodes,
        userLocation: userLocation,
        keyDisplayByteCount: viewModel.neighborKeyDisplayByteCount,
        maxPlausibleSecondsAgo: viewModel.maxPlausibleNeighborAge,
        fetchSnapshots: viewModel.helper.fetchHistory,
        onRemove: sendCommand.map { send in
          { [viewModel, session] in
            // `neighbor.remove <hex>`: the prefix the repeater lists it by is enough
            let reply = try await send("neighbor.remove \(selection.publicKeyPrefix.uppercaseHexString())")
            if case let .error(message) = CLIResponse.parse(reply) { throw NodeSettingsError.commandFailed(message) }
            await viewModel.requestNeighbors(for: session)
          }
        }
      )
    }
  }

  /// A group's heading over its cards: "Heard this scan · 3". Always shown once a discovery has run,
  /// so the first group keeps its place while it fills.
  private func scanHeading(_ title: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title)
      Text(count.formatted())
        .monospacedDigit()
        .foregroundStyle(.tertiary)
      Spacer(minLength: 0)
    }
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 4)
    .padding(.top, 4)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private func neighborLink(for neighbor: Neighbour) -> some View {
    let resolution = NeighborNameResolver.resolve(
      for: neighbor.publicKeyPrefix,
      contacts: contacts,
      discoveredNodes: discoveredNodes,
      userLocation: userLocation
    )
    // Neighbours report only a key prefix, so one whose advert this phone never heard
    // has no stored name; its prefix is the only identity there is.
    let displayName = resolution?.displayName ?? NeighborNameResolver.fallbackName(
      for: neighbor.publicKeyPrefix,
      byteCount: viewModel.neighborKeyDisplayByteCount
    )
    let previous = viewModel.helper.previousNeighborSnapshot?.neighborSnapshots?.first {
      $0.publicKeyPrefix == neighbor.publicKeyPrefix
    }
    return Button {
      openNeighbor = NeighborSelection(
        publicKeyPrefix: neighbor.publicKeyPrefix,
        snr: neighbor.snr,
        secondsAgo: neighbor.secondsAgo,
        previousSNR: previous?.snr
      )
    } label: {
      HStack(spacing: 8) {
        NeighborRow(
          neighbor: neighbor,
          displayName: displayName,
          matchKind: resolution?.matchKind ?? .unresolved,
          keyDisplayByteCount: viewModel.neighborKeyDisplayByteCount,
          previousNeighbor: previous,
          isNew: viewModel.helper.previousNeighborSnapshot?.neighborSnapshots != nil
            && !viewModel.helper.seenNeighborPrefixes.contains(neighbor.publicKeyPrefix),
          maxPlausibleSecondsAgo: viewModel.maxPlausibleNeighborAge
        )
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .cardSurface()
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
  }

  /// Discover as the scan ring: tap to start a minute's discovery, tap again to stop. The ring
  /// fills with the minute and counts down its seconds.
  private var discoverButton: some View {
    Button {
      if viewModel.isDiscovering {
        viewModel.stopDiscovery()
      } else {
        viewModel.startDiscovery(for: session)
      }
    } label: {
      ScanRingButtonFace(
        progress: viewModel.isDiscovering
          ? 1 - Double(viewModel.discoverySecondsRemaining) / Double(RepeaterStatusViewModel.discoveryDuration)
          : nil,
        secondsLeft: viewModel.isDiscovering ? viewModel.discoverySecondsRemaining : nil,
        isScanning: viewModel.isDiscovering,
        reduceMotion: reduceMotion
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: connectionState, or: viewModel.isLoadingNeighbors && !viewModel.isDiscovering)
    .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Status.discoverNeighbors)
    .accessibilityIdentifier("neighbors.discover")
  }

  /// "12 neighbours", or "Neighbors" before the first list.
  private var headline: String {
    viewModel.neighborsLoaded
      ? L10n.RemoteNodes.RemoteNodes.Status.Tile.neighborCount(viewModel.neighbors.count)
      : NodeSectionPage.neighbors.title
  }

  /// How many answered, the strongest and how many are new since the last list; the strongest
  /// opens its chart.
  private var summaryStrip: some View {
    let newCount = viewModel.neighbors.count {
      viewModel.helper.previousNeighborSnapshot?.neighborSnapshots != nil
        && !viewModel.helper.seenNeighborPrefixes.contains($0.publicKeyPrefix)
    }
    let best = viewModel.neighbors.max { $0.snr < $1.snr }
    return HStack(alignment: .top, spacing: 8) {
      ScanSummaryStat(
        title: L10n.RemoteNodes.RemoteNodes.Status.neighbors,
        systemImage: NodeSectionPage.neighbors.systemImage,
        value: viewModel.neighbors.count.formatted(),
        caption: nil
      )
      if let best {
        ScanSummaryStat(
          title: L10n.Tools.Tools.NodeDiscovery.Summary.bestSignal,
          systemImage: "cellularbars",
          value: L10n.RemoteNodes.RemoteNodes.Status.snrFormat(best.snr.formatted(.number.precision(.fractionLength(1)))),
          caption: displayName(for: best.publicKeyPrefix)
        )
      }
      ScanSummaryStat(
        title: L10n.RemoteNodes.RemoteNodes.History.new,
        systemImage: "sparkles",
        value: newCount.formatted(),
        caption: nil
      )
    }
  }

  private func displayName(for prefix: Data) -> String {
    NeighborNameResolver.resolve(
      for: prefix,
      contacts: contacts,
      discoveredNodes: discoveredNodes,
      userLocation: userLocation
    )?.displayName ?? NeighborNameResolver.fallbackName(for: prefix, byteCount: viewModel.neighborKeyDisplayByteCount)
  }

  /// The countdown while running, then the last run's result.
  private var discoverySubtitle: String? {
    if viewModel.isDiscovering {
      return L10n.RemoteNodes.RemoteNodes.Status.discoveringSeconds(viewModel.discoverySecondsRemaining)
    }
    if let count = viewModel.lastDiscoveryNeighborCount {
      return L10n.RemoteNodes.RemoteNodes.Status.discoveryResult(count)
    }
    // Says what the ring does before it has been used.
    return session.isAdmin ? L10n.RemoteNodes.RemoteNodes.Status.discoverNeighbors : nil
  }
}
