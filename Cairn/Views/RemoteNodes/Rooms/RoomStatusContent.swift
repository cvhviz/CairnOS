import CoreLocation
import CairnServices
import SwiftUI

/// Stack-free room status body hosted by both the guest standalone sheet and the merged admin view.
///
/// The view model is owned as `@State` by the host. This content receives it as a plain `let` and must
/// never create, replace, or reset it; loaded/loading/error state all live on the view model so
/// switching hosts or segments preserves it.
struct RoomStatusContent: View {
  @Environment(\.appState) private var appState
  let viewModel: RoomStatusViewModel
  let session: RemoteNodeSessionDTO
  let connectionState: DeviceConnectionState
  let connectedDeviceID: UUID?
  /// The phone's location, for the header's distance; nil leaves the distance out.
  var userLocation: CLLocation?
  /// Shows the node's map as the header (both hosts do now; kept for a host that wants it compact).
  var showsMap = true
  /// The admin dashboard's action tiles (advert, sync time, reboot, access list) under the header.
  var headerActions: AnyView?
  /// More tool tiles after the built-in ones, such as the admin dashboard's CLI.
  var extraLinks: AnyView?
  /// The admin dashboard's own cards (Radio, Device, Behavior), each opening its settings in a
  /// sheet; laid into the card grid among the status cards.
  var adminCards: [NodeDashboardCardItem] = []
  /// Opens the identity, location and contact settings from the header's pencil (admin only).
  var onEditIdentity: (() -> Void)?
  /// Runs after the first status reading, once per visit (the admin Dashboard's card settings).
  var afterStatusLoads: (() async -> Void)?

  @State private var showsLocationMap = false
  /// The battery's last week, for the Battery card's trend line.
  @State private var batteryTrend: [MetricChartView.DataPoint] = []
  /// The follow-up reads have started this visit; a page popping back doesn't send them again.
  @State private var followUpsStarted = false
  /// The reads after login are running (status, sensors, the host's own): the loading bar shows.
  @State private var isAutoLoading = false
  /// The section page pushed from the dashboard buttons.
  @State private var openPage: NodeSectionPage?

  /// The header has a map to carry the freshness chip.
  private var freshnessOnMap: Bool { showsMap && session.coordinate != nil }

  var body: some View {
    CardForm {
      // The header and its action tiles as one block; the cards a section's gap under them.
      VStack(spacing: CardStyle.spacing) {
        RemoteNodeHeaderSection(
          session: session,
          coordinate: showsMap ? session.coordinate : nil,
          infoLine: RemoteNodeHeaderFormat.infoLine(
            coordinate: session.coordinate,
            userLocation: userLocation
          ),
          onTapMap: { showsLocationMap = true },
          onEditTitle: onEditIdentity,
          // how fresh the readings are, beside "Room · Direct", as on a repeater's page
          trailing: AnyView(TimelineView(.everyMinute) { context in
            NodeFreshnessCapsule(helper: viewModel.helper, now: context.date)
          })
        ) {
          headerActions
        }
        // Laid out like Home: how fresh the readings are (or why there are none), then the cards,
        // each opening the page or sheet behind its reading; then the tools.
        NodeStatusDashboard(
          helper: viewModel.helper,
          role: .room,
          connectionState: connectionState,
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
          EmptyView()
        } extra: {
          extraLinks
        }
      }
    }
    // Floats over the top of the page while the reads after login run, so nothing below moves.
    .pageLoadingBar(isLoading: isAutoLoading, title: autoLoadTitle)
    // After the first status reading, once per visit and one request at a time: the sensors, then
    // the host's own (the admin card settings). Unstructured, because a page pushed over the
    // Dashboard cancels `.task` while the packet is already on the air.
    .task(id: viewModel.helper.status != nil) {
      guard viewModel.helper.status != nil, !followUpsStarted, connectionState == .ready else { return }
      followUpsStarted = true
      let viewModel = viewModel, session = session, afterStatusLoads = afterStatusLoads
      // Background priority: a user's action on the room goes first (`RemoteRequestPriority`).
      Task {
        await RemoteRequestPriority.$current.withValue(.background) {
          if !viewModel.helper.telemetryLoaded, !viewModel.helper.isLoadingTelemetry {
            await viewModel.requestTelemetry(for: session)
          }
          await afterStatusLoads?()
        }
        isAutoLoading = false
      }
    }
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
    .task(id: connectionState == .ready) {
      guard viewModel.helper.shouldAutoLoadStatus(connectionState: connectionState) else { return }
      isAutoLoading = true
      await RemoteRequestPriority.$current.withValue(.background) {
        await viewModel.requestStatus(for: session)
      }
      // No reading, so no follow-ups: nothing more is loading.
      if viewModel.helper.status == nil { isAutoLoading = false }
    }
    .navigationDestination(item: $openPage) { page in
      sectionPage(page)
    }
    .nodeStatusDestinations(helper: viewModel.helper)
    .remoteNodeLocationMap(isPresented: $showsLocationMap, session: session, coordinate: session.coordinate)
    .scrollDismissesKeyboard(.interactively)
  }

  /// A room has no neighbours or contact info, so only the shared pages open from here.

  /// What the bar's chip names while the reads after login run.
  private var autoLoadTitle: String {
    let helper = viewModel.helper
    if helper.isLoadingStatus { return L10n.RemoteNodes.RemoteNodes.Status.statusSection }
    if helper.isLoadingTelemetry { return NodeSectionPage.telemetry.title }
    return L10n.RemoteNodes.RemoteNodes.Settings.loading
  }
  @ViewBuilder
  private func sectionPage(_ page: NodeSectionPage) -> some View {
    switch page {
    case .telemetry:
      NodeTelemetryPage(helper: viewModel.helper, connectionState: connectionState) {
        await viewModel.requestTelemetry(for: session)
      }
    case .batteryCurve:
      NodeBatteryCurvePage(
        helper: viewModel.helper,
        session: session,
        connectionState: connectionState,
        connectedDeviceID: connectedDeviceID,
        onRequestTelemetry: { await viewModel.requestTelemetry(for: session) }
      )
    case .neighbors, .ownerInfo:
      // No button opens these on a room.
      EmptyView()
    }
  }

  // MARK: Button details

  // MARK: Cards

  /// Battery (with the sensors), Radio, Signal, Packets, Posts, Duplicates, then Behavior and Device: the readings first,
  /// the room's own settings after. The admin cards are absent for a guest.
  private var cards: [NodeDashboardCardItem] {
    let helper = viewModel.helper
    let admin = Dictionary(uniqueKeysWithValues: adminCards.map { ($0.id, $0) })
    // Both directions, as Scan & Traffic lists them, when this radio heard the node directly.
    let link = NodeLinkSignal(publicKey: session.publicKey, directory: appState.neighbourDirectory, now: .now)
    let history = helper.effectivePublicKey.map {
      NodeStatusRoute.history(publicKey: $0, radioID: session.radioID, showNeighbors: false)
    }
    let posts = NodeDashboardCardItem(
      id: "posts",
      title: L10n.RemoteNodes.RemoteNodes.RoomStatus.postsReceived,
      systemImage: "text.bubble",
      tint: .teal,
      value: viewModel.postsReceivedDisplay,
      details: ["\(L10n.RemoteNodes.RemoteNodes.RoomStatus.postsPushed) \(viewModel.postsPushedDisplay)"],
      destination: history.map(NodeDashboardCardItem.Destination.route) ?? .none
    )
    let base: [NodeDashboardCardItem?] = [
      .battery(helper, trend: batteryTrend) { openPage = .batteryCurve },
      admin["radio"],
      .signal(helper, history: history, link: link),
      .packets(helper, history: history),
      posts,
      .duplicates(helper, receiveErrors: nil, showsTxQueue: false, history: history),
    ]
    // A refresh that failed leaves the earlier reading on the cards, marked stale with its age.
    let stale = NodeStatusFreshness.staleCaption(helper: helper)
    let readings: Set<String> = ["battery", "signal", "packets", "posts", "duplicates"]
    return (base.compactMap(\.self) + adminCards.filter { $0.id != "radio" }).map { card in
      var card = card
      if let stale, readings.contains(card.id) { card.details.append(stale) }
      return card
    }
  }
}
