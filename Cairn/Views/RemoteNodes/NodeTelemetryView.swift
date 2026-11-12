import CairnServices
import SwiftUI

/// A person's shared telemetry as a dashboard, laid out like Home and a logged-in node's
/// Dashboard: the contact's map header, the sensor state with its reload control, the readings as
/// Home-style cards (Battery, Location, then each other sensor), and the tools after.
struct NodeTelemetryView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let contact: ContactDTO
  /// Pushed onto the node page's stack (a Mac), rather than a sheet with its own stack and Done.
  var isPushed = false
  @State private var viewModel = NodeTelemetryViewModel()
  @State private var headerHeight: CGFloat = 150
  /// The full map pushed from the header map.
  @State private var headerMapFix: NodeLocationFix?

  var body: some View {
    if isPushed {
      page
    } else {
      NavigationStack {
        page
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button(L10n.RemoteNodes.RemoteNodes.done) { dismiss() }
                .keyboardShortcut(.defaultAction)
            }
          }
      }
      .presentationDetents([.large])
    }
  }

  private var page: some View {
    CardForm {
      NodeMapHeader(
        coordinate: headerFix?.coordinate,
        marker: contact.type.pinStyle,
        markerAvatar: MapPinAvatar(contact: contact),
        title: contact.displayName,
        subtitle: NodeRouteFormat.joined([contact.type.localizedName, routeSummary]),
        infoLine: headerFix.map { fix in
          NodeRouteFormat.joined([
            NodeRouteFormat.distanceAway(
              from: appState.bestAvailableLocation,
              latitude: fix.latitude,
              longitude: fix.longitude
            ),
            RemoteNodeHeaderFormat.coordinateText(fix.coordinate),
          ])
        },
        onTapMap: { headerMapFix = headerFix },
        footer: AnyView(NodeHeaderChips(publicKey: contact.publicKey))
      ) {
        ContactAvatar(contact: contact, size: NodeMapHeader<EmptyView>.avatarSize)
          .accessibilityHidden(true)
      }
      .scrollRevealHeaderHeight(into: $headerHeight)
      // Long press copies the coordinates or opens them in Maps, as the coordinate rows did.
      .contextMenu {
        if let fix = headerFix {
          Button(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc") {
            UIPasteboard.general.string = "\(fix.latitude), \(fix.longitude)"
          }
          Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
            NodeLocation.openInMaps(name: contact.displayName, coordinate: fix.coordinate)
          }
        }
      }

      // The readings' state (loading, error, nothing shared) and the reload control, then the
      // readings as cards, each opening where it's charted or mapped.
      sensorsStatusCard
      if helper.telemetry != nil, !cards.isEmpty {
        NodeDashboardCardGrid(items: cards)
      }

      // Tools: the saved history (sensors and location over time), and the min/avg/max summary
      // the node keeps, which loads only when opened.
      CardFormSection(L10n.Localizable.Tabs.tools) {
        MetricTileGrid {
          NavigationLink(value: historyRoute) {
            NavigationTile(
              L10n.RemoteNodes.RemoteNodes.History.title,
              systemImage: "chart.xyaxis.line",
              color: .blue
            )
          }
          .buttonStyle(.plain)
        }
        NodeTelemetrySummarySection(publicKey: contact.publicKey)
      }
    }
    // The sensors card has its own reload control; pull to refresh does the same, as on the
    // Dashboard.
    .refreshable {
      guard appState.connectionState == .ready, !helper.isLoadingTelemetry else { return }
      // SwiftUI cancels a refresh task when observed state changes mid-refresh (the reply
      // lands); the inner task shields the request from that.
      await Task {
        await viewModel.requestTelemetry()
      }.value
    }
    .nodeStatusDestinations(helper: helper)
    .navigationDestination(item: $headerMapFix) { fix in
      NodeOnMapView(focus: .node(publicKey: contact.publicKey, coordinate: fix.coordinate), title: contact.displayName)
    }
    .navigationBarTitleDisplayMode(.inline)
    .scrollRevealNavigationTitle(contact.displayName, revealAfter: headerHeight)
    .contentMargins(.top, 0, for: .scrollContent)
    .task {
      viewModel.configure(
        binaryProtocolService: { appState.services?.binaryProtocolService },
        contactService: { appState.services?.contactService },
        nodeSnapshotService: { appState.services?.nodeSnapshotService },
        contact: contact
      )
      // The sheet is the sensors page, so it reads them as it opens.
      if !helper.telemetryLoaded, !helper.isLoadingTelemetry {
        Task { await viewModel.requestTelemetry() }
      }

      if let radioID = appState.connectedDevice?.radioID {
        await helper.loadOCVSettings(
          publicKey: contact.publicKey,
          radioID: radioID
        )
      }
    }
  }

  private var helper: NodeStatusViewModel { viewModel.helper }

  /// Where the header centres: the contact's advertised location, or failing that the fix its
  /// telemetry shared.
  private var headerFix: NodeLocationFix? {
    if contact.hasLocation {
      return NodeLocationFix(latitude: contact.latitude, longitude: contact.longitude)
    }
    return helper.currentLocationFix
  }

  /// "Direct", "2 hops" or "Flood", after the type.
  private var routeSummary: String {
    if contact.isFloodRouted { return L10n.Contacts.Contacts.Route.flood }
    if contact.pathHopCount == 0 { return L10n.Contacts.Contacts.Route.direct }
    return NodeRouteFormat.hopCount(contact.pathHopCount)
  }

  private var historyRoute: NodeStatusRoute {
    .history(publicKey: contact.publicKey, radioID: contact.radioID, showNeighbors: false)
  }

  // MARK: Sensors

  private var statusLine: NodeCardStatusLine.Kind? {
    if helper.isLoadingTelemetry, helper.telemetry == nil { return .loading }
    if let errorMessage = helper.telemetrySectionError, helper.telemetry == nil { return .error(errorMessage) }
    if helper.telemetry != nil {
      return helper.cachedDataPoints.isEmpty ? .note(L10n.RemoteNodes.RemoteNodes.Status.noSensorData) : nil
    }
    return .note(L10n.RemoteNodes.RemoteNodes.Status.noTelemetryData)
  }

  /// The Sensors title with its reload control, and the state while there are no cards to show.
  /// A refresh keeps the last cards on screen; the reload control shows the request.
  private var sensorsStatusCard: some View {
    NodeSectionCard(.telemetry, hasContent: statusLine != nil, showsTitle: true) {
      SectionReloadButton(
        isLoading: helper.isLoadingTelemetry,
        isLoaded: helper.telemetryLoaded,
        hasError: helper.telemetrySectionError != nil,
        isDisabled: appState.connectionState != .ready,
        accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.Accessibility.reloadTelemetry,
        onReload: { await viewModel.requestTelemetry() }
      )
    } content: {
      if let statusLine {
        NodeCardStatusLine(kind: statusLine)
      }
    }
  }

  private var cards: [NodeDashboardCardItem] {
    NodeDashboardCardItem.telemetryCards(
      helper.cachedDataPoints,
      ocvValues: helper.ocvValues,
      nodeName: contact.displayName,
      pinStyle: contact.type.pinStyle,
      avatar: MapPinAvatar(contact: contact),
      history: historyRoute
    )
  }
}

@MainActor
extension NodeDashboardCardItem {
  /// A telemetry reply as Home-style cards: the first voltage as Battery (its charge from the
  /// node's battery curve), each location fix as Location (opening its map), then every other
  /// reading as a card of its own, named as the sensor tiles named them. With several channels,
  /// each card says its channel. A reading opens its history (Battery the battery's and sensors',
  /// the rest the sensors'), else its facts in a sheet.
  static func telemetryCards(
    _ points: [LPPDataPoint],
    ocvValues: [Int],
    nodeName: String?,
    pinStyle: MapPoint.PinStyle = .locationFixLatest,
    avatar: MapPinAvatar? = nil,
    history: NodeStatusRoute?
  ) -> [NodeDashboardCardItem] {
    let multiChannel = Set(points.map(\.channel)).count > 1
    // The node's key, so its Location card opens the GPS map on it.
    let publicKey: Data? = if case let .history(publicKey, _, _) = history { publicKey } else { nil }
    let firstVoltage = points.firstIndex { $0.type == .voltage }
    var battery: [NodeDashboardCardItem] = []
    var locations: [NodeDashboardCardItem] = []
    var readings: [NodeDashboardCardItem] = []

    for (index, point) in points.enumerated() {
      let channel = multiChannel ? L10n.RemoteNodes.RemoteNodes.Status.channel(Int(point.channel)) : nil
      // The label is worked out within the channel, so a second temperature reads as the MCU's.
      let channelPoints = points.filter { $0.channel == point.channel }
      let channelIndex = points.prefix(index).filter { $0.channel == point.channel }.count
      // With several channels, the sheet says which one the reading came on.
      let channelFact = channel.map { [NodeReadingDetail.Fact(title: $0, value: "")] } ?? []
      let historyTarget = NodeHistoryTarget(history)

      if case let .gps(latitude, longitude, _) = point.value {
        let fix = NodeLocationFix.primaryFix(from: [point])
        locations.append(NodeDashboardCardItem(
          id: "reading-\(index)",
          title: L10n.Contacts.Contacts.Detail.location,
          systemImage: "location.fill",
          tint: .green,
          value: RemoteNodeHeaderFormat.coordinateText(.init(latitude: latitude, longitude: longitude)),
          details: [point.formattedValue, channel].compactMap(\.self),
          destination: fix.map { .route(.locationMap(fix: $0, name: nodeName, pinStyle: pinStyle, avatar: avatar, publicKey: publicKey)) }
            ?? history.map { .route($0) } ?? .none
        ))
      } else if point.type == .voltage, case let .float(volts) = point.value {
        let percent = BatteryInfo(level: Int(volts * 1000)).percentage(using: ocvValues)
        let level = BatteryLevel(percent: percent)
        let warns = level != .good
        let isBattery = index == firstVoltage
        let card = NodeDashboardCardItem(
          id: "reading-\(index)",
          title: isBattery
            ? L10n.RemoteNodes.RemoteNodes.Status.battery
            : telemetryLabel(for: point, at: channelIndex, in: channelPoints),
          systemImage: isBattery ? BatteryLevel.symbol(for: percent) : point.type.remoteNodeTileSymbol,
          tint: isBattery ? level.tint : .yellow,
          value: BatteryLevel.formattedPercent(percent),
          valueTint: isBattery ? level.tint : (warns ? level.tint : .primary),
          note: level.title,
          noteTint: warns ? level.tint : .secondary,
          details: [point.formattedValue, channel].compactMap(\.self),
          destination: .history(
            historyTarget,
            scope: isBattery ? .battery : .sensors,
            orFacts: [
              .init(
                title: L10n.RemoteNodes.RemoteNodes.Status.battery,
                value: NodeRouteFormat.joined([BatteryLevel.formattedPercent(percent), level.title]),
                tint: level.tint
              ),
              .init(title: L10n.Settings.Battery.voltage, value: point.formattedValue),
            ] + channelFact
          )
        )
        if isBattery { battery.append(card) } else { readings.append(card) }
      } else {
        readings.append(NodeDashboardCardItem(
          id: "reading-\(index)",
          title: telemetryLabel(for: point, at: channelIndex, in: channelPoints),
          systemImage: point.type.remoteNodeTileSymbol,
          tint: tint(for: point.type),
          value: point.formattedValue,
          details: [channel].compactMap(\.self),
          destination: .history(
            historyTarget,
            scope: .sensors,
            orFacts: [.init(title: telemetryLabel(for: point, at: channelIndex, in: channelPoints), value: point.formattedValue)]
              + channelFact
          )
        ))
      }
    }
    return battery + locations + readings
  }

  private static func tint(for type: LPPSensorType) -> Color {
    switch type {
    case .temperature: .orange
    case .humidity: .cyan
    case .barometer: .indigo
    case .illuminance: .yellow
    case .current, .power, .energy: .yellow
    case .altitude, .distance, .direction: .green
    default: .teal
    }
  }
}
