import CairnServices
import SwiftUI

// MARK: - Links Section

/// The pages reachable from a node's status, as navigation cards in one grid: whatever the host
/// puts first (a repeater's or room's section pages), the node's history (radio, sensors, location
/// and neighbours on one page, the same page Contact Detail opens), its last reported location
/// once a telemetry reply carried one, and whatever the host appends (the repeater's neighbour
/// map). History reads stored snapshots, so it opens without a request to the node.
struct NodeStatusLinksSection<Leading: View, Extra: View>: View {
  @Environment(\.appState) private var appState

  let helper: NodeStatusViewModel
  /// False where the page shows History as a card of its own (the Dashboards).
  var showsHistory = true
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var extra: () -> Extra

  init(
    helper: NodeStatusViewModel,
    showsHistory: Bool = true,
    @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
    @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }
  ) {
    self.helper = helper
    self.showsHistory = showsHistory
    self.leading = leading
    self.extra = extra
  }

  /// A logged-in repeater or room has neighbours; a contact read directly has sensors only.
  private var historyRoute: NodeStatusRoute? {
    guard let publicKey = helper.effectivePublicKey,
          let radioID = helper.session?.radioID ?? appState.currentRadioID else { return nil }
    return .history(publicKey: publicKey, radioID: radioID, showNeighbors: helper.session != nil)
  }

  var body: some View {
    MetricTileGrid {
      leading()

      if showsHistory, let historyRoute {
        NavigationLink(value: historyRoute) {
          NavigationTile(
            L10n.RemoteNodes.RemoteNodes.History.title,
            systemImage: "chart.xyaxis.line",
            color: .blue
          )
        }
        .buttonStyle(.plain)
      }

      if let fix = helper.currentLocationFix {
        NavigationLink(value: NodeStatusRoute.locationMap(
          fix: fix,
          name: helper.session?.name,
          pinStyle: helper.session.map { $0.isRoom ? .contactRoom : .contactRepeater } ?? .locationFixLatest,
          publicKey: helper.effectivePublicKey
        )) {
          NavigationTile(
            L10n.RemoteNodes.RemoteNodes.Status.locationMapTitle,
            systemImage: "map.fill",
            color: .green,
            detail: L10n.RemoteNodes.RemoteNodes.Status.viewOnMap
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Status.Accessibility.viewLocationOnMap)
      }

      extra()
    }
  }
}

// MARK: - Telemetry Helpers

extension LPPDataPoint {
  /// A location fix, which the readings show as a Location card rather than a sensor's.
  var isCoordinate: Bool {
    if case .gps = value { return true }
    return false
  }
}

extension LPPSensorType {
  /// Symbol for a reading's tile.
  var remoteNodeTileSymbol: String {
    switch self {
    case .voltage: "bolt.fill"
    case .temperature: "thermometer.medium"
    case .humidity: "humidity.fill"
    case .barometer: "gauge.with.dots.needle.33percent"
    case .illuminance: "sun.max.fill"
    case .current: "bolt.horizontal.fill"
    case .power: "powerplug.fill"
    case .frequency: "waveform"
    case .altitude: "mountain.2.fill"
    case .distance: "ruler"
    case .energy: "bolt.circle"
    case .direction: "location.north.line.fill"
    case .percentage: "percent"
    case .presence: "figure.stand"
    case .digitalInput, .digitalOutput, .switchValue: "switch.2"
    case .analogInput, .analogOutput: "dial.medium"
    case .accelerometer: "move.3d"
    case .gyrometer: "gyroscope"
    case .colour: "paintpalette.fill"
    case .unixTime: "clock"
    case .load: "scalemass"
    case .concentration: "aqi.medium"
    case .gps: "location.fill"
    case .genericSensor: "sensor.fill"
    }
  }
}

/// A second temperature on the same channel is MCU, matching `ChannelGroup`.
/// `index` is the row's position in `points`; occurrence, not value equality.
func telemetryLabel(for dataPoint: LPPDataPoint, at index: Int, in points: [LPPDataPoint]) -> String {
  guard dataPoint.type == .temperature else { return dataPoint.type.localizedName }
  let prior = points.prefix(index).filter {
    $0.channel == dataPoint.channel && $0.type == .temperature
  }.count
  return prior == 0
    ? L10n.RemoteNodes.RemoteNodes.Status.Sensor.temperature
    : L10n.RemoteNodes.RemoteNodes.Status.Sensor.mcuTemperature
}

// MARK: - Battery Curve Section

/// The node's battery curve, which turns its voltage into the charge shown in the readings. The
/// page hosting it reads the stored curve; the curve's own cards follow the title card.
struct NodeBatteryCurveSection: View {
  @Bindable var helper: NodeStatusViewModel
  let connectionState: DeviceConnectionState

  var body: some View {
    NodeSectionCard(.batteryCurve, hasContent: helper.ocvError != nil) {
      InfoButton(
        L10n.RemoteNodes.RemoteNodes.Status.batteryCurveFooter,
        title: L10n.RemoteNodes.RemoteNodes.Status.batteryCurve
      )
    } content: {
      if let error = helper.ocvError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }

    BatteryCurveSection(
      availablePresets: OCVPreset.nodePresets,
      headerText: "",
      footerText: "",
      selectedPreset: $helper.selectedOCVPreset,
      voltageValues: $helper.ocvValues,
      onSave: helper.saveOCVSettings,
      isDisabled: connectionState != .ready
    )
  }
}

// MARK: - Telemetry Section

/// The sensor readings: a title card with the reload control and the loading, error or empty
/// state, then the readings as Dashboard cards (Battery, Location, then each other sensor, each
/// saying its channel when the node reports several), as a person's shared telemetry shows them.
/// A card opens the reading in full, its map, or its history. The host reads the telemetry.
struct NodeTelemetrySection: View {
  @Environment(\.appState) private var appState

  let helper: NodeStatusViewModel
  let connectionState: DeviceConnectionState
  /// Whether the title card names the section; only where the navigation bar doesn't.
  var showsTitle = false
  let onRequestTelemetry: () async -> Void

  private var statusLine: NodeCardStatusLine.Kind? {
    if helper.isLoadingTelemetry, helper.telemetry == nil { return .loading }
    if let errorMessage = helper.telemetrySectionError, helper.telemetry == nil { return .error(errorMessage) }
    if helper.telemetry != nil {
      return helper.cachedDataPoints.isEmpty ? .note(L10n.RemoteNodes.RemoteNodes.Status.noSensorData) : nil
    }
    return .note(L10n.RemoteNodes.RemoteNodes.Status.noTelemetryData)
  }

  /// A logged-in repeater or room has neighbours; a contact read directly has sensors only.
  private var historyRoute: NodeStatusRoute? {
    guard let publicKey = helper.effectivePublicKey,
          let radioID = helper.session?.radioID ?? appState.currentRadioID else { return nil }
    return .history(publicKey: publicKey, radioID: radioID, showNeighbors: helper.session != nil)
  }

  private var cards: [NodeDashboardCardItem] {
    let session = helper.session
    let pinStyle: MapPoint.PinStyle = switch session?.role {
    case .repeater: ContactType.repeater.pinStyle
    case .roomServer: ContactType.room.pinStyle
    case nil: .locationFixLatest
    }
    return NodeDashboardCardItem.telemetryCards(
      helper.cachedDataPoints,
      ocvValues: helper.ocvValues,
      nodeName: session?.name,
      pinStyle: pinStyle,
      avatar: session.map { MapPinAvatar(name: $0.name) },
      history: historyRoute
    )
  }

  var body: some View {
    NodeSectionCard(.telemetry, hasContent: statusLine != nil, showsTitle: showsTitle) {
      SectionReloadButton(
        isLoading: helper.isLoadingTelemetry,
        isLoaded: helper.telemetryLoaded,
        hasError: helper.telemetrySectionError != nil,
        isDisabled: connectionState != .ready,
        accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.Accessibility.reloadTelemetry,
        onReload: onRequestTelemetry
      )
    } content: {
      if let statusLine {
        NodeCardStatusLine(kind: statusLine)
      }
    }

    // A refresh keeps the last readings on screen; the reload button shows the request.
    if helper.telemetry != nil, !helper.cachedDataPoints.isEmpty {
      NodeDashboardCardGrid(items: cards)
    }
  }
}

// MARK: - Back Button

/// The node pages' way out when they open as a sheet: a back chevron at the top left, as a pushed
/// page has, in place of a Done at the right. Escape closes it too (a Mac or a hardware keyboard).
struct NodePageBackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(L10n.Localizable.Common.back, systemImage: "chevron.backward")
    }
    .keyboardShortcut(.cancelAction)
  }
}
