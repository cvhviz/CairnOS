import CoreLocation
import CairnServices
import SwiftUI

/// Stack-free repeater status body hosted by both the guest standalone sheet and the merged admin view.
///
/// The view model is owned as `@State` by the host. This content receives it as a plain `let` and must
/// never create, replace, or reset it; status, loaded/loading/error and discovery state all live on the
/// view model so switching hosts or segments preserves it. The content view does not own the discovery
/// lifecycle either: only the guest host stops discovery on dismiss.
struct RepeaterStatusContent: View {
  @Environment(\.appState) private var appState
  let viewModel: RepeaterStatusViewModel
  let session: RemoteNodeSessionDTO
  let connectionState: DeviceConnectionState
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  let userLocation: CLLocation?
  let connectedDeviceID: UUID?
  /// Contact whose login route the route row shows; nil hides the row.
  var routePathContact: ContactDTO?
  /// Shows the node's map as the header (both hosts do now; kept for a host that wants it compact).
  var showsMap = true
  /// The admin dashboard's action tiles (advert, sync time, reboot, access list) under the header.
  var headerActions: AnyView?
  /// More facts in the header's grid, for the minute shown (the admin dashboard's firmware and clock).
  var headerFacts: ((Date) -> [NodeHeaderFact])?
  /// More tool tiles after the built-in ones, such as the admin dashboard's CLI.
  var extraLinks: AnyView?
  /// The admin dashboard's own cards (Radio, Device, Behavior), each opening its settings in a
  /// sheet; laid into the card grid among the status cards.
  var adminCards: [NodeDashboardCardItem] = []
  /// Opens the identity, location and contact settings from the header's pencil (admin only).
  var onEditIdentity: (() -> Void)?
  /// Bumped by the admin dashboard's Neighbors control, which starts a discovery: opens the
  /// Neighbors page to show it. With that control present, the tools leave Neighbors out.
  var neighborsPageRequest: Int?
  /// The admin's command line to the repeater, for what the Neighbors page can change there
  /// (removing a neighbour); nil for a guest.
  var sendCommand: ((String) async throws -> String)?
  /// Reads after the first status reading, once per visit and in order (the admin Dashboard's
  /// owner info and any card setting not yet known), each named on the progress line.
  var afterStatusLoads: [NodeLoadStep] = []
  /// The last visit's card values (`NodeCardCache`), for the Battery card's sensor line and the
  /// Neighbors card until their pages read them this visit.
  var cardCache: NodeCardCache.Entry?

  @State private var showsLocationMap = false
  /// The battery's last week, for the Battery card's trend line.
  @State private var batteryTrend: [MetricChartView.DataPoint] = []
  /// The follow-up reads have started this visit; a page popping back doesn't send them again.
  @State private var followUpsStarted = false
  /// The section page pushed from the dashboard buttons.
  @State private var openPage: NodeSectionPage?
  /// The automatic reads after login, while they run: how far along and what is loading.
  @State private var loadProgress: NodeLoadProgress?

  var body: some View {
    form
  }



  private var form: some View {
    CardForm {
      // The header and its action tiles as one block; the cards a section's gap under them.
      VStack(spacing: CardStyle.spacing) {
        // Ticks each minute so "Updated 3m ago" after the route keeps up on its own.
        TimelineView(.everyMinute) { context in
        RemoteNodeHeaderSection(
          session: session,
          coordinate: showsMap ? session.coordinate : nil,
          infoLine: RemoteNodeHeaderFormat.infoLine(
            coordinate: session.coordinate,
            userLocation: userLocation
          ),
          route: routeSummary,
          onTapMap: { showsLocationMap = true },
          onEditTitle: onEditIdentity,
          // how fresh the readings are, beside "Repeater · Direct" (the user, 2026-11-09: over the map's
          // corner it took a row of its own)
          trailing: AnyView(NodeFreshnessCapsule(helper: viewModel.helper, now: context.date)),
          facts: headerFacts?(context.date) ?? []
        ) {
          headerActions
        }
        }
        // Laid out like Home: how fresh the readings are (or why there are none), then the cards,
        // each opening the page or sheet behind its reading; then the tools.
        NodeStatusDashboard(
          helper: viewModel.helper,
          role: .repeater,
          connectionState: connectionState,
          receiveErrorsDisplay: viewModel.receiveErrorsDisplay,
          showsCards: false,
          reloadInToolbar: false,
          // How fresh the readings are shows over the map, where there is one; nothing sits over
          // the cards, and the page refreshes with a pull.
          showsFreshness: false,
          showsReload: false,
          onReload: { await viewModel.requestStatus(for: session) }
        )
      }
      NodeDashboardCardGrid(items: cards)
      CardFormSection(L10n.Localizable.Tabs.tools) {
        NodeStatusLinksSection(helper: viewModel.helper, showsHistory: false) {
          // A guest has no settings; the owner's note opens as its own page.
          if onEditIdentity == nil {
            NodeSectionTileButton(page: .ownerInfo, detail: ownerInfoDetail) { openPage = $0 }
          }
        } extra: {
          extraLinks
        }
      }
    }
    // Floats under the navigation bar while the reads after login run, so nothing below moves; on iOS 26
    // the step it is on ("Radio · 4/6") is the navigation subtitle instead of a chip over the map.
    .pageLoadingBar(loadProgress, showsChip: !LoadStepSubtitle.available)
    .modifier(LoadStepSubtitle(text: loadProgress?.stepText ?? ""))
    // Each fresh status is saved to the node's history; read the week again after it.
    .task(id: viewModel.helper.statusUpdatedAt) {
      batteryTrend = await NodeBatteryTrend.load(publicKey: session.publicKey, appState: appState)
    }
    .refreshable {
      // The status is this page's reading; each section page refreshes its own.
      guard connectionState == .ready, !viewModel.helper.isLoadingStatus else { return }
      // SwiftUI cancels a ScrollView's refresh task when observed state changes mid-refresh (the
      // status reply lands); the inner task shields the request from that.
      await Task {
        await viewModel.requestStatus(for: session)
      }.value
    }
    // The page's one automatic request: on first reveal, and after a reconnect while there's
    // still no reading. A segment switch back keeps the reading the view model holds.
    // Background priority, as are the follow-ups: anything the user asks for meanwhile (a clock
    // sync, a setting) goes to the repeater first (`RemoteRequestPriority`).
    .task(id: connectionState == .ready) {
      guard viewModel.helper.shouldAutoLoadStatus(connectionState: connectionState) else { return }
      loadProgress = NodeLoadProgress(
        done: 0,
        total: autoLoadStepCount,
        title: L10n.RemoteNodes.RemoteNodes.Status.statusSection,
        systemImage: "waveform.path.ecg",
        color: .green
      )
      await RemoteRequestPriority.$current.withValue(.background) {
        await viewModel.requestStatus(for: session)
      }
      // No reading, so no follow-ups: nothing more is loading.
      if viewModel.helper.status == nil { loadProgress = nil }
    }
    // After the first status reading, once per visit and one request at a time: the host's own
    // (the admin owner info and card settings). The sensors and the neighbours are read by their
    // pages as they open, each a round trip or more the Dashboard doesn't need; their cards show the
    // last visit's until then. Unstructured, because a page pushed over the Dashboard cancels
    // `.task` while the packet is already on the air.
    .task(id: viewModel.helper.status != nil) {
      guard viewModel.helper.status != nil, !followUpsStarted, connectionState == .ready else { return }
      followUpsStarted = true
      let steps = afterStatusLoads
      // Shown only when this visit loaded the status itself; a return to a page already read
      // runs whatever is missing quietly.
      let showsProgress = loadProgress != nil
      let total = steps.count + 1
      Task {
        await RemoteRequestPriority.$current.withValue(.background) {
          for (index, step) in steps.enumerated() {
            if showsProgress {
              withAnimation {
                loadProgress = NodeLoadProgress(
                  done: index + 1,
                  total: total,
                  title: step.title,
                  systemImage: step.systemImage,
                  color: step.color
                )
              }
            }
            await step.run()
          }
        }
        withAnimation { loadProgress = nil }
      }
    }
    .onChange(of: neighborsPageRequest) { _, _ in
      openPage = .neighbors
    }
    .navigationDestination(item: $openPage) { page in
      sectionPage(page)
    }
    .nodeStatusDestinations(helper: viewModel.helper)
    .remoteNodeLocationMap(isPresented: $showsLocationMap, session: session, coordinate: session.coordinate)
    .scrollDismissesKeyboard(.interactively)
  }

  @ViewBuilder
  private func sectionPage(_ page: NodeSectionPage) -> some View {
    switch page {
    case .neighbors:
      RepeaterNeighborsPage(
        viewModel: viewModel,
        session: session,
        contacts: contacts,
        discoveredNodes: discoveredNodes,
        userLocation: userLocation,
        connectionState: connectionState,
        sendCommand: sendCommand
      )
    case .ownerInfo:
      RepeaterOwnerInfoPage(viewModel: viewModel, session: session, connectionState: connectionState)
    case .batteryCurve:
      NodeBatteryCurvePage(
        helper: viewModel.helper,
        session: session,
        connectionState: connectionState,
        connectedDeviceID: connectedDeviceID,
        onRequestTelemetry: { await viewModel.requestTelemetry(for: session) }
      )
    case .telemetry:
      NodeTelemetryPage(helper: viewModel.helper, connectionState: connectionState) {
        await viewModel.requestTelemetry(for: session)
      }
    }
  }

  /// Status, then the host's own reads.
  private var autoLoadStepCount: Int {
    1 + afterStatusLoads.count
  }

  /// "Direct", "2 hops" or "Flood", for the header beside the role.
  private var routeSummary: String? {
    guard let contact = routePathContact else { return nil }
    if contact.isFloodRouted { return L10n.Contacts.Contacts.Route.flood }
    if contact.pathHopCount == 0 { return L10n.Contacts.Contacts.Route.direct }
    return NodeRouteFormat.hopCount(contact.pathHopCount)
  }

  // MARK: Cards

  /// Battery (with the sensors), Radio, Signal, Packets, Neighbors, Duplicates, then Behavior and Device: the readings
  /// first, the node's own settings after. The admin cards are absent for a guest.
  private var cards: [NodeDashboardCardItem] {
    let helper = viewModel.helper
    let admin = Dictionary(uniqueKeysWithValues: adminCards.map { ($0.id, $0) })
    // Both directions, as Scan & Traffic lists them, when this radio heard the node directly.
    let link = NodeLinkSignal(publicKey: session.publicKey, directory: appState.neighbourDirectory, now: .now)
    let history = historyRoute
    let base: [NodeDashboardCardItem?] = [
      .battery(helper, cached: cardCache, trend: batteryTrend) { openPage = .batteryCurve },
      admin["radio"],
      .signal(helper, history: history, link: link),
      .packets(helper, history: history),
      neighborsCard,
      .duplicates(helper, receiveErrors: viewModel.receiveErrorsDisplay, showsTxQueue: true, history: history),
    ]
    let known: Set<String> = ["radio"]
    // While the page loads: a reading still on its way is dimmed (the admin cards say so themselves)
    let statusPending = helper.status == nil && loadProgress != nil
    let readings: Set<String> = ["battery", "sensors", "signal", "packets", "duplicates"]
    // A refresh that failed leaves the earlier reading on the cards, marked stale with its age.
    let stale = NodeStatusFreshness.staleCaption(helper: helper)
    return (base.compactMap(\.self) + adminCards.filter { !known.contains($0.id) }).map { card in
      var card = card
      if statusPending, readings.contains(card.id) { card.isPending = true }
      if let stale, readings.contains(card.id) { card.details.append(stale) }
      return card
    }
  }

  private var historyRoute: NodeStatusRoute? {
    guard let publicKey = viewModel.helper.effectivePublicKey else { return nil }
    return .history(publicKey: publicKey, radioID: session.radioID, showNeighbors: true)
  }

  /// The neighbour count and the best SNR, this visit's once the page has read them, else the last
  /// visit's in grey.
  private var neighborsCard: NodeDashboardCardItem {
    let loaded = viewModel.neighborsLoaded
    let count = loaded ? viewModel.neighbors.count : cardCache?.neighborCount
    let bestSNR = loaded ? viewModel.neighbors.max { $0.snr < $1.snr }?.snr : cardCache?.bestNeighborSNR
    return NodeDashboardCardItem(
      id: "neighbors",
      title: NodeSectionPage.neighbors.title,
      systemImage: NodeSectionPage.neighbors.systemImage,
      tint: NodeSectionPage.neighbors.color,
      value: count?.formatted() ?? NodeStatusViewModel.emDash,
      valueTint: loaded ? .primary : .secondary,
      note: viewModel.isDiscovering
        ? L10n.RemoteNodes.RemoteNodes.Status.discoveringSeconds(viewModel.discoverySecondsRemaining)
        : nil,
      details: (bestSNR.map { [NodeDiscoveryFormat.snr($0)] } ?? [])
        + (!loaded && count != nil ? [L10n.RemoteNodes.RemoteNodes.Status.fromLastVisit] : []),
      destination: .action { openPage = .neighbors },
      isPending: !loaded && !viewModel.isDiscovering && viewModel.isLoadingNeighbors
    )
  }

  // MARK: Button details

  private var ownerInfoDetail: String {
    NodeSectionTileDetail.state(
      isLoading: viewModel.isLoadingOwnerInfo,
      hasError: viewModel.ownerInfoError != nil,
      loaded: viewModel.ownerInfoLoaded
        ? NodeSectionTileDetail.ownerInfo(viewModel.ownerInfo, firmware: viewModel.firmwareVersion)
        : nil
    )
  }

}

extension View {
  /// Success and error haptics for a neighbour discovery. Applied by each host (the guest sheet and
  /// the admin view around both tabs) rather than the status content, so it fires whichever tab is
  /// showing when the minute-long run ends, and only once.
  func discoveryFeedback(_ viewModel: RepeaterStatusViewModel) -> some View {
    sensoryFeedback(.success, trigger: viewModel.discoveryCompletionCount)
      .sensoryFeedback(.error, trigger: viewModel.discoveryFailureCount)
  }
}

/// The page's load step as its navigation subtitle (iOS 26 and later); earlier systems keep the chip under
/// the loading bar.
private struct LoadStepSubtitle: ViewModifier {
  let text: String

  static var available: Bool {
    if #available(iOS 26, *) { return true }
    return false
  }

  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content.navigationSubtitle(text)
    } else {
      content
    }
  }
}
