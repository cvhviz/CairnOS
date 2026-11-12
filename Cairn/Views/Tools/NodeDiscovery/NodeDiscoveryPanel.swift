import CoreLocation
import CairnServices
import MeshCore
import SwiftUI

/// The results side of Scan & Traffic. Pinned at the top, the header (what the scan is doing, Scan
/// and Wardrive, the mini spectrum; tapped, what it found so far) and the Nodes | Packets switch
/// with one Filter button for the list shown; under them the list. When the sheet is lowered only
/// the header (with its buttons) shows. The nodes: a compact card per neighbour the current scan heard, opening in
/// place for the rest, then a row that adds the ones heard before it, under their own heading and
/// faded. The packets: the Traffic list, every packet the radio hears, newest first, one line each,
/// each opening its sheet. Selection is shared with the map through the view model, so a card
/// tapped here is centered there and a pin tapped there opens its card here.
struct NodeDiscoveryPanel: View {
  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var viewModel: NodeDiscoveryViewModel
  /// The radio's packets, shared with the map, which the page subscribes for.
  let traffic: RxLogViewModel
  /// Which list shows under the header; the map's camera follows it.
  @Binding var section: NodeDiscoverySection
  /// The sheet is lowered: the header alone, the map gets the screen.
  var isCollapsed = false
  /// The map's traffic, for the packet now flying under the lowered sheet's mini spectrum; nil
  /// beside the map (iPad, Mac), where the map's own ticker says it.
  var trafficMap: TrafficMapModel?
  /// Opens the Packets list from the lowered sheet's packet line.
  var onOpenPackets: (() -> Void)?
  /// A tap on the lowered sheet's header area, which raises it.
  var onExpandSheet: (() -> Void)?
  /// The phone sheet's drag, which its header takes as well as its grabber; nil beside the map
  /// (iPad, Mac).
  var headerDrag: AnyGesture<Void>?

  /// The header shows what the scan found so far.
  @State private var isHeaderExpanded = false

  #if DEBUG
    /// The list's last row, for screenshot runs that scroll to it.
    private static let endAnchor = "nodeDiscovery.panel.end"
  #endif
  @State private var listFilter: NodeDiscoveryListFilter = .all
  @State private var linkChecks: [Data: NodeDiscoveryLinkCheck] = [:]
  /// The row whose link is being checked; one check is in flight at a time.
  @State private var checkingKey: Data?
  @State private var contactForDetail: ContactDTO?
  @State private var discoveredForDetail: DiscoveredNodeDTO?
  /// The packet whose details are open in a sheet.
  @State private var packetForDetail: RxLogEntryDTO?
  @State private var groupDuplicates = false
  @State private var csvExport: ExportedFile?
  @State private var showsDeleteConfirmation = false
  /// Add All New's confirmation, with the contact slots it states.
  @State private var showsAddAllConfirmation = false
  /// The packets held still while scrolled away from the top (`PacketListFreeze`).
  @State private var packetFreeze = PacketListFreeze<RxLogEntryDTO>()
  /// The nodes' order, kept between visits; the view model sorts by it.
  @AppStorage(AppStorageKey.scanNodesSortOrder.rawValue) private var sortOrderRaw = NodeDiscoverySortOrder.snr.rawValue

  private static let topAnchor = "nodeDiscovery.panel.top"

  /// Every row of the kind listed, positioned and measured, in the chosen order: the current
  /// scan's first, then the earlier ones.
  private var entries: [NodeDiscoveryEntry] {
    NodeDiscoveryEntries.sorted(
      NodeDiscoveryEntries.make(
        results: viewModel.results,
        contacts: viewModel.contactsByKey,
        discovered: viewModel.discoveredByKey
      ),
      by: viewModel.sortOrder
    )
  }

  var body: some View {
    let entries = entries
    let chipsVisible = NodeDiscoveryEntries.chipsVisible(entries)
    // With the chips gone, everything shows whatever was picked last.
    let visible = NodeDiscoveryEntries.filtered(entries, by: listFilter, chipsVisible: chipsVisible)
    let current = entries.filter { !$0.result.isEarlier }
    let visibleEarlier = visible.filter(\.result.isEarlier)
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: CardStyle.spacing) {
        NodeDiscoveryHeader(
          viewModel: viewModel,
          traffic: traffic,
          summary: current.isEmpty ? nil : NodeDiscoverySummary(entries: current),
          isExpanded: $isHeaderExpanded,
          onSelect: { key in
            viewModel.selectedKey = key
            onExpandSheet?()
          }
        )
        // A vertical drag on the header moves the sheet; taps on its buttons still land, since
        // the drag only starts once the finger has moved.
        .modifier(OptionalHighPriorityGesture(gesture: headerDrag))
        // Lowered, the map has the screen and its lasers fly: the packet now flying, under the
        // mini spectrum, in place of a ticker card over the map.
        if isCollapsed, let trafficMap {
          TrafficTickerCard(
            flights: trafficMap.flights,
            lastFinished: trafficMap.lastFinished,
            onOpenList: onOpenPackets,
            isInline: true
          )
        }
        if !isCollapsed {
          sectionRow(nodeCount: current.count, packetCount: packetEntries.count, chipsVisible: chipsVisible, entries: entries)
        }
      }
      .padding(.horizontal, CardStyle.pageInset)
      .padding(.top, 4)
      .padding(.bottom, isCollapsed ? CardStyle.pageInset : CardStyle.spacing)

      if !isCollapsed {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: CardStyle.spacing) {
              Color.clear.frame(height: 0).id(Self.topAnchor)
              switch section {
              case .packets:
                packetList
              case .nodes:
                if let session = viewModel.wardriveSession {
                  NodeDiscoveryWardriveCard(
                    session: session,
                    nodeCount: current.count,
                    onStop: viewModel.stopWardrive,
                    onDismiss: viewModel.dismissWardriveSummary
                  )
                }
                if current.isEmpty {
                  nothingHeard
                }
                ForEach(visible.filter { !$0.result.isEarlier }) { entry in
                  card(for: entry)
                    .id(entry.id)
                }
                if !visibleEarlier.isEmpty {
                  earlierHeader
                  ForEach(visibleEarlier) { entry in
                    card(for: entry)
                      .id(entry.id)
                  }
                }
                showOlderRow
              }
              #if DEBUG
                Color.clear.frame(height: 1).id(Self.endAnchor)
              #endif
            }
            .padding(.horizontal, CardStyle.pageInset)
            .padding(.bottom, CardStyle.pageInset)
            .animation(reduceMotion ? nil : .default, value: viewModel.selectedKey)
          }
          // Scrolled away from the top, the packets hold still; back at it, they go live again.
          .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > RxLogView.freezeOffset } action: { _, away in
            if away, section == .packets {
              packetFreeze.freeze(Array(packetEntries))
            } else {
              packetFreeze.release()
            }
          }
          .overlay(alignment: .top) {
            let newCount = section == .packets ? packetFreeze.newCount(live: Array(packetEntries)) : 0
            if newCount > 0 {
              NewPacketsPill(count: newCount) {
                withAnimation(reduceMotion ? nil : .snappy) {
                  proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
                packetFreeze.release()
              }
              .padding(.top, 8)
              .transition(.move(edge: .top).combined(with: .opacity))
            }
          }
          .onChange(of: section) { packetFreeze.release() }
          // Back from the lowered sheet with a node picked on the map: open on its card.
          .onAppear {
            if let key = viewModel.selectedKey { proxy.scrollTo(key) }
          }
          #if DEBUG
          // Screenshot runs scroll the list to its end: `-uiTestScrollToEnd YES`.
          .task {
            guard UserDefaults.standard.bool(forKey: "uiTestScrollToEnd") else { return }
            try? await Task.sleep(for: .seconds(4))
            proxy.scrollTo(Self.endAnchor, anchor: .bottom)
          }
          #endif
          .onChange(of: viewModel.selectedKey) { _, key in
            guard let key else { return }
            // A pin's card is in the nodes.
            section = .nodes
            // A pin tapped on the map may belong to a card the current filter hides.
            if !visible.contains(where: { $0.id == key }) { listFilter = .all }
            withAnimation(reduceMotion ? nil : .default) {
              proxy.scrollTo(key)
            }
          }
        }
      }
    }
    #if DEBUG
    // Screenshot runs: `-uiTestPacketDetail YES` opens the packet with the longest route once the
    // log is in.
    .onChange(of: traffic.hasLoadedHistory, initial: true) { _, loaded in
      guard loaded, UserDefaults.standard.bool(forKey: "uiTestPacketDetail"), packetForDetail == nil else { return }
      packetForDetail = traffic.entries.max { $0.hopCount < $1.hopCount }
    }
    #endif
    .modifier(SpectrumFeedViewer())
    .sensoryFeedback(.selection, trigger: packetForDetail) { _, entry in entry != nil }
    .fileExporter(
      isPresented: Binding(
        get: { csvExport != nil },
        set: { if !$0 { discardCSVExport() } }
      ),
      document: csvExport?.document,
      contentType: .commaSeparatedText,
      defaultFilename: csvExport?.filename
    ) { _ in
      discardCSVExport()
    }
    .modifier(DeleteLogsConfirmation(isPresented: $showsDeleteConfirmation, delete: deleteLog))
    .confirmationDialog(
      L10n.Tools.Tools.NodeDiscovery.addAllNew(newResults.count),
      isPresented: $showsAddAllConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Tools.Tools.NodeDiscovery.AddAllNew.confirm(newResults.count)) {
        viewModel.addAllNew(newResults)
      }
    } message: {
      if let limit = viewModel.contactSlotLimit {
        Text(L10n.Tools.Tools.NodeDiscovery.AddAllNew.message(newResults.count, limit, viewModel.contactCount))
      } else {
        Text(L10n.Tools.Tools.NodeDiscovery.AddAllNew.messageNoLimit(newResults.count))
      }
    }
    .sheet(item: $packetForDetail) { entry in
      RxPacketDetailSheet(
        entry: entry,
        groupCount: groupCount(for: entry),
        nodeIndex: traffic.nodeIndex,
        packet: traffic.packetNodes(for: entry),
        origin: appState.bestAvailableLocation,
        currentChannelKey: traffic.nodeIndex.channelKey,
        echo: traffic.echo(for: entry),
        actions: packetActions(closingSheet: true)
      )
    }
    // The order kept between visits is the view model's, and a change on either side is kept.
    .onAppear {
      viewModel.sortOrder = NodeDiscoverySortOrder(rawValue: sortOrderRaw) ?? .snr
    }
    .onChange(of: sortOrderRaw) { _, raw in
      viewModel.sortOrder = NodeDiscoverySortOrder(rawValue: raw) ?? .snr
    }
    // The chips went away: their filter goes with them, so it can't come back stuck when they return.
    .onChange(of: chipsVisible) { _, isVisible in
      listFilter = NodeDiscoveryEntries.listFilter(listFilter, chipsVisible: isVisible)
    }
    // A new scan starts a new list: what the last one's link checks found goes with it.
    .onChange(of: viewModel.scanStartedAt) {
      linkChecks.removeAll()
    }
    .detailPresentation(item: $contactForDetail, route: { .contact(id: $0.id, canHideFromMap: false) }) { contact in
      ContactDetailSheet(
        contact: contact,
        onMessage: {
          contactForDetail = nil
          appState.navigation.navigateToChat(with: contact)
        },
        onDelete: { Task { await viewModel.refreshStoredRecords() } }
      )
      .presentationDetents([.large])
    }
    .detailPresentation(item: $discoveredForDetail, route: {
      .discoveredNode(id: $0.id, radioID: $0.radioID, canHideFromMap: false)
    }) { node in
      DiscoveredNodeDetailSheet(
        node: node,
        isAdding: viewModel.addingPublicKey == node.publicKey,
        onAdd: {
          discoveredForDetail = nil
          if let result = viewModel.results.first(where: { $0.publicKey == node.publicKey }) {
            viewModel.addNode(result)
          }
        }
      )
      .presentationDetents([.medium, .large])
    }
    // The stored names and contacts the rows are labelled with change under this list: a
    // neighbour's advert arrives by another relay and is stored as a discovered node, a node is
    // saved or deleted on another page (on a Mac, in another window). Reloading on each bump
    // (throttled by the app) names the row and settles its New / Contact chip in place, rather
    // than on the next visit.
    .onChange(of: appState.contactsVersion) {
      Task { await viewModel.refreshStoredRecords() }
    }
  }

  // MARK: - Packets

  /// The Traffic list as filtered, and grouped when Group Duplicates is on, newest first.
  private var packetEntries: ReversedCollection<ArraySlice<RxLogEntryDTO>> {
    traffic.displayEntries(groupingDuplicates: groupDuplicates)
  }

  private func groupCount(for entry: RxLogEntryDTO) -> Int {
    groupDuplicates ? traffic.groupCounts[entry.packetHash, default: 1] : 1
  }

  /// The current scan's rows that could be added and aren't contacts yet: what Add All New adds.
  private var newResults: [NodeDiscoveryResult] {
    viewModel.currentResults.filter { result in
      guard let key = result.publicKey, result.hasFullKey, ContactType(rawValue: result.nodeType) != nil else { return false }
      return viewModel.contactsByKey[key] == nil && !viewModel.isAdded(publicKey: key)
    }
  }

  /// What a packet's menu can do from this page: open a node's page (the scan's stored records
  /// first, then the store), show its sender on the map, build Trace Path on its route. From
  /// the detail sheet the sheet closes first, so the page under it can present or navigate.
  private func packetActions(closingSheet: Bool) -> RxPacketActionHandlers {
    RxPacketActionHandlers(
      openNode: { node in
        if closingSheet { packetForDetail = nil }
        let key = node.publicKey
        if let contact = viewModel.contactsByKey[key] {
          contactForDetail = contact
        } else if let discovered = viewModel.discoveredByKey[key] {
          discoveredForDetail = discovered
        } else {
          Task {
            let stored = await PacketNodeLookup.stored(key: key, appState: appState)
            if let contact = stored.contact {
              contactForDetail = contact
            } else if let discovered = stored.discovered {
              discoveredForDetail = discovered
            }
          }
        }
      },
      showOnMap: { coordinate in
        if closingSheet { packetForDetail = nil }
        appState.navigation.navigateToMap(coordinate: coordinate)
      },
      traceRoute: { route in
        if closingSheet { packetForDetail = nil }
        appState.navigation.navigateToTraceRoute(route)
      }
    )
  }

  /// The Nodes | Packets switch, with the one Filter button for the list shown beside it, always
  /// in the same place.
  private func sectionRow(nodeCount: Int, packetCount: Int, chipsVisible: Bool, entries: [NodeDiscoveryEntry]) -> some View {
    HStack(spacing: 8) {
      Picker(selection: $section) {
        Text("\(L10n.Localizable.Tabs.nodes) \(nodeCount.formatted())").tag(NodeDiscoverySection.nodes)
        // Packets lost on the way, or recovery missing: a mark on the switch, the details in the
        // header's open part.
        if traffic.deliveryNeedsAttention {
          Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(L10n.Tools.Tools.NodeDiscovery.Section.packets) \(packetCount.formatted())")
            .accessibilityLabel(NodeRouteFormat.joined([
              "\(L10n.Tools.Tools.NodeDiscovery.Section.packets) \(packetCount.formatted())",
              traffic.deliveryLine,
            ].compactMap(\.self)))
            .tag(NodeDiscoverySection.packets)
        } else {
          Text("\(L10n.Tools.Tools.NodeDiscovery.Section.packets) \(packetCount.formatted())").tag(NodeDiscoverySection.packets)
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("nodeDiscovery.section")
      switch section {
      case .nodes: nodeFilterMenu(chipsVisible: chipsVisible, entries: entries)
      case .packets: packetFilterMenu
      }
    }
  }

  /// The Traffic list: every packet newest first, a line each, each opening its details (where its
  /// notes are). How packets reach the app is in the header's details; a problem marks the switch.
  private var packetList: some View {
    let entries = packetFreeze.entries(live: Array(packetEntries))
    return Group {
      if entries.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.Tools.Tools.RxLog.listening)
            .font(.headline)
          Text(L10n.Tools.Tools.RxLog.listeningDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nodeDiscovery.packets.listening")
      }
      ForEach(entries, id: \.id) { entry in
        let packet = traffic.packetNodes(for: entry)
        RxLogRowView(
          entry: entry,
          onOpen: { packetForDetail = entry },
          groupCount: groupCount(for: entry),
          nodeIndex: traffic.nodeIndex,
          packet: packet,
          origin: appState.bestAvailableLocation,
          currentChannelKey: traffic.nodeIndex.channelKey,
          echo: traffic.echo(for: entry),
          isCompact: true
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // A little taller than the one-line content needs: easier to hit, easier to tell apart.
        .frame(minHeight: 30)
        .cardSurface(padding: 12)
        .contextMenu {
          RxPacketActionsMenu(entry: entry, packet: packet, handlers: packetActions(closingSheet: false))
        }
      }
    }
  }

  // MARK: - Filter

  /// The nodes' one Filter button: which kind to list and ask for (only repeaters and sensors
  /// answer a discovery request, and switching never stops a probe or Wardrive), then All / New /
  /// Contacts while the list holds both new nodes and contacts. Its badge counts what differs from
  /// the default.
  private func nodeFilterMenu(chipsVisible: Bool, entries: [NodeDiscoveryEntry]) -> some View {
    Menu {
      Picker(selection: $viewModel.filter) {
        ForEach(NodeDiscoveryFilter.allCases, id: \.self) { kind in
          Label(kind.localizedTitle, systemImage: kind.systemImage).tag(kind)
        }
      } label: {
        Text(L10n.Tools.Tools.NodeDiscovery.askFor)
      }
      .pickerStyle(.inline)
      .accessibilityIdentifier("nodeDiscovery.scanTarget")
      if chipsVisible {
        Picker(selection: $listFilter) {
          ForEach(NodeDiscoveryListFilter.allCases, id: \.self) { filter in
            Text("\(filter.localizedTitle) \(NodeDiscoveryEntries.count(entries, matching: filter).formatted())").tag(filter)
          }
        } label: {
          Text(L10n.Tools.Tools.RxLog.filter)
        }
        .pickerStyle(.inline)
      }
      Picker(selection: $sortOrderRaw) {
        ForEach(NodeDiscoverySortOrder.allCases, id: \.self) { order in
          Label(order.localizedTitle, systemImage: order.systemImage).tag(order.rawValue)
        }
      } label: {
        Text(L10n.Tools.Tools.NodeDiscovery.sortBy)
      }
      .pickerStyle(.inline)
      .accessibilityIdentifier("nodeDiscovery.sortOrder")
      Section {
        let newCount = newResults.count
        Button {
          showsAddAllConfirmation = true
        } label: {
          Label(L10n.Tools.Tools.NodeDiscovery.addAllNew(newCount), systemImage: "person.crop.circle.badge.plus")
        }
        .disabled(newCount == 0 || !viewModel.isConnected || viewModel.addingPublicKey != nil)
        Button {
          csvExport = NodeDiscoveryExport.csvExport(for: entries)
        } label: {
          Label(L10n.Tools.Tools.NodeDiscovery.exportNodes, systemImage: "square.and.arrow.up")
        }
        .disabled(entries.isEmpty)
      }
    } label: {
      filterLabel(count: NodeDiscoveryFilterBadge.nodes(
        kind: viewModel.filter,
        listFilter: listFilter,
        chipsVisible: chipsVisible,
        sortOrder: viewModel.sortOrder
      ))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("nodeDiscovery.filter")
  }

  /// The packets' one Filter button: the Traffic list's route and decrypt filters (the map follows
  /// the route one), Group Duplicates, then the CSV export and Delete Logs. Its badge counts the
  /// filters and grouping that are on.
  private var packetFilterMenu: some View {
    Menu {
      RxLogFilterSections(viewModel: traffic)
      Section {
        Toggle(L10n.Tools.Tools.RxLog.groupDuplicates, isOn: $groupDuplicates)
      }
      Section {
        Button {
          csvExport = traffic.csvExport(for: packetEntries)
        } label: {
          Label(L10n.Tools.Tools.RxLog.exportCSV, systemImage: "square.and.arrow.up")
        }
        .disabled(traffic.entries.isEmpty)
        Button(role: .destructive) {
          showsDeleteConfirmation = true
        } label: {
          Label(L10n.Tools.Tools.RxLog.deleteLogs, systemImage: "trash")
        }
      }
    } label: {
      filterLabel(count: NodeDiscoveryFilterBadge.packets(
        route: traffic.routeFilter,
        decrypt: traffic.decryptFilter,
        groupsDuplicates: groupDuplicates,
        type: traffic.typeFilter,
        hasSender: traffic.senderFilter != nil
      ))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("nodeDiscovery.packets.filter")
  }

  /// The Filter button's face: the glyph on the card surface, filled with a count while anything
  /// is on. Always the same size, so the switch beside it never moves.
  private func filterLabel(count: Int) -> some View {
    Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
      .font(.body.weight(.medium))
      .foregroundStyle(count > 0 ? Color.accentColor : Color.primary)
      .frame(width: 44, height: 32)
      .background { CardBackground(shape: Capsule()) }
      .overlay(alignment: .topTrailing) {
        if count > 0 {
          Text(count.formatted())
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 16, minHeight: 16)
            .background(Circle().fill(Color.accentColor))
            .offset(x: 4, y: -4)
        }
      }
      .contentShape(.capsule)
      .accessibilityLabel(L10n.Tools.Tools.RxLog.filter)
      .accessibilityValue(count > 0 ? L10n.Tools.Tools.NodeDiscovery.Filter.active(count) : "")
  }

  /// The exporter saves from the document, so the staged temporary copy goes as soon as it closes.
  private func discardCSVExport() {
    csvExport?.removeTemporaryFile()
    csvExport = nil
  }

  private func deleteLog() {
    Task { await traffic.clearLog() }
    packetForDetail = nil
  }

  /// At the end of the nodes: adds the ones heard before the current scan (up to 24 hours ago),
  /// with how many there are, or takes them away again.
  @ViewBuilder
  private var showOlderRow: some View {
    let olderCount = viewModel.olderCount
    if viewModel.showsOlder || olderCount > 0 {
      Button {
        viewModel.showsOlder.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: viewModel.showsOlder ? "chevron.up" : "clock.arrow.circlepath")
            .foregroundStyle(.secondary)
          Text(viewModel.showsOlder
            ? L10n.Tools.Tools.NodeDiscovery.hideOlder
            : L10n.Tools.Tools.NodeDiscovery.showOlderCount(olderCount))
            .font(.subheadline.weight(.medium))
          Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHint(L10n.Tools.Tools.NodeDiscovery.showOlderHint)
      .accessibilityIdentifier("nodeDiscovery.showOlder")
    }
  }

  /// The current scan's list is empty: before the first scan, a prompt to tap Scan with a line on
  /// what a scan does; since one started, that nothing of the kind has been heard yet.
  private var nothingHeard: some View {
    let hasScanned = viewModel.scanStartedAt != nil
    let title = hasScanned ? L10n.Tools.Tools.NodeDiscovery.NothingHeard.title : L10n.Tools.Tools.NodeDiscovery.FirstUse.title
    let description = if !hasScanned {
      L10n.Tools.Tools.NodeDiscovery.FirstUse.description
    } else if viewModel.filter == .sensors {
      L10n.Tools.Tools.NodeDiscovery.NothingHeard.sensorsDescription
    } else {
      L10n.Tools.Tools.NodeDiscovery.NothingHeard.description
    }
    return VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.headline)
      Text(description)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(hasScanned ? "nodeDiscovery.nothingHeard" : "nodeDiscovery.notScanned")
  }

  /// Over the rows Show Older adds: they were heard before the current scan started.
  private var earlierHeader: some View {
    Text(L10n.Tools.Tools.NodeDiscovery.earlierSection)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.top, 8)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("nodeDiscovery.earlierSection")
  }

  // MARK: - Cards

  private func card(for entry: NodeDiscoveryEntry) -> some View {
    let key = entry.id
    let result = entry.result
    let publicKey = result.hasFullKey ? result.publicKey : nil
    let contact = publicKey.flatMap { viewModel.contactsByKey[$0] }
    let discovered = publicKey.flatMap { viewModel.discoveredByKey[$0] }
    var requestName: (() -> Void)?
    if viewModel.canRequestNames, let publicKey {
      requestName = { viewModel.requestName(for: publicKey) }
    }
    return NodeDiscoveryResultCard(
      entry: entry,
      isSelected: viewModel.selectedKey == key,
      isAdding: publicKey != nil && viewModel.addingPublicKey == publicKey,
      isResolvingName: publicKey.map { viewModel.resolvingNameKeys.contains($0) } ?? false,
      linkCheck: linkChecks[key],
      isCheckingLink: checkingKey == key,
      onSelect: { viewModel.selectedKey = viewModel.selectedKey == key ? nil : key },
      onAdd: publicKey != nil && ContactType(rawValue: result.nodeType) != nil
        ? { viewModel.addNode(result) }
        : nil,
      onRequestName: requestName,
      onCheckLink: canCheckLink(result) ? { checkLink(result, contact: contact) } : nil,
      // A relay known only by a hash: the Traffic map draws the traffic it carries.
      onShowOnTrafficMap: publicKey == nil ? { section = .packets } : nil,
      onDetails: detailsAction(contact: contact, discovered: discovered)
    )
  }

  private func detailsAction(contact: ContactDTO?, discovered: DiscoveredNodeDTO?) -> (() -> Void)? {
    if let contact {
      return { contactForDetail = contact }
    }
    if let discovered {
      return { discoveredForDetail = discovered }
    }
    return nil
  }

  // MARK: - Check Link

  /// A confirmed repeater a zero-hop trace can name: enough of its key or hash is known for the
  /// radio's trace paths, and the hash is its alone. On a row that could be several nodes, every
  /// one of them in range would answer the same trace, and the replies would collide. One check is
  /// in flight at a time.
  private func canCheckLink(_ result: NodeDiscoveryResult) -> Bool {
    guard result.isConfirmed, result.scanFilter == .repeaters, result.candidates == nil, viewModel.isConnected,
          let hashSize = viewModel.traceHashSize, result.key.count >= hashSize else { return false }
    return checkingKey == nil || checkingKey == result.key
  }

  /// Sends one zero-hop trace through PingHelper. It spends none of the repeaters' scan budget, and
  /// its answer also reaches the neighbour table as a link confirmation (SNR both ways).
  private func checkLink(_ result: NodeDiscoveryResult, contact: ContactDTO?) {
    let key = result.key
    guard checkingKey == nil else { return }
    guard appState.services != nil, let radioID = appState.connectedDevice?.radioID else {
      linkChecks[key] = .failed
      return
    }
    checkingKey = key
    linkChecks[key] = nil
    let target = contact ?? Self.traceTarget(key: key, name: result.name, nodeType: result.nodeType, radioID: radioID)
    Task {
      let outcome = await PingHelper.zeroHopPing(contact: target, appState: appState)
      let check: NodeDiscoveryLinkCheck = switch outcome {
      case let .success(latencyMs, snrThere, snrBack): .answered(latencyMs: latencyMs, snrThere: snrThere, snrBack: snrBack)
      case .error: .noAnswer
      }
      linkChecks[key] = check
      checkingKey = nil
    }
  }

  /// PingHelper addresses its trace by a contact's key. A neighbour that isn't a contact gets a
  /// stand-in carrying only what the trace needs, the start of its key or hash; nothing stores it.
  private static func traceTarget(key: Data, name: String, nodeType: UInt8, radioID: UUID) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: key,
      name: name,
      typeRawValue: nodeType,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }
}

/// Adds `gesture` with priority over the content's own, when there is one.
private struct OptionalHighPriorityGesture: ViewModifier {
  let gesture: AnyGesture<Void>?

  func body(content: Content) -> some View {
    if let gesture {
      content.highPriorityGesture(gesture)
    } else {
      content
    }
  }
}
