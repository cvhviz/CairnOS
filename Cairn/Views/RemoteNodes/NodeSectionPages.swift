import CairnServices
import SwiftUI

// The repeater and room status pages open each read-on-demand group (neighbours, contact info,
// battery curve, sensors) as a page of its own from a dashboard button under the header, instead
// of folding it open further down a long page. Each page reads its group from the node when it
// first appears, keeps the reading on the view model, and offers the same reload and retry.

/// The groups a node status page opens as their own pages. The host decides which exist: a room
/// has no neighbours or contact info.
enum NodeSectionPage: Hashable, Identifiable {
  case neighbors
  case ownerInfo
  case batteryCurve
  case telemetry

  var id: Self { self }

  var title: String {
    switch self {
    case .neighbors: L10n.RemoteNodes.RemoteNodes.Status.neighbors
    case .ownerInfo: L10n.RemoteNodes.RemoteNodes.Status.ownerInfo
    case .batteryCurve: L10n.RemoteNodes.RemoteNodes.Status.batteryCurve
    case .telemetry: L10n.RemoteNodes.RemoteNodes.Status.telemetry
    }
  }

  var systemImage: String {
    switch self {
    case .neighbors: "point.3.connected.trianglepath.dotted"
    case .ownerInfo: "person.crop.rectangle"
    case .batteryCurve: "battery.100percent"
    case .telemetry: "sensor.fill"
    }
  }

  var color: Color {
    switch self {
    case .neighbors: .orange
    case .ownerInfo: .blue
    case .batteryCurve: .green
    case .telemetry: .teal
    }
  }
}

// MARK: - Tile Details

/// The state line each dashboard button shows under its name, so the page says what's behind a
/// button before it's opened. Pure, for the unit tests.
enum NodeSectionTileDetail {
  /// A section read from the node: loading while a request runs, the summary once there is one,
  /// "Failed to load" after a failed first read, and "Not loaded" before any read.
  static func state(isLoading: Bool, hasError: Bool, loaded: String?) -> String {
    if isLoading { return L10n.RemoteNodes.RemoteNodes.Settings.loading }
    if let loaded { return loaded }
    if hasError { return L10n.Localizable.Common.Error.failedToLoad }
    return L10n.RemoteNodes.RemoteNodes.Status.Tile.notLoaded
  }

  /// The owner text's first line, the firmware version when the owner text is empty (the two
  /// arrive in one reply), or the empty note.
  static func ownerInfo(_ info: String?, firmware: String?) -> String {
    let firstLine = info?
      .split(whereSeparator: \.isNewline)
      .lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
    if let firstLine { return firstLine }
    if let firmware, !firmware.isEmpty { return firmware }
    return L10n.RemoteNodes.RemoteNodes.Status.noOwnerInfo
  }

  /// The charge the curve gives the last voltage, then the curve's name; the name alone without
  /// a reading.
  static func battery(percent: Int?, presetName: String) -> String {
    guard let percent else { return presetName }
    return "\(BatteryLevel.formattedPercent(percent)) · \(presetName)"
  }

  /// How many readings came back, or the empty note when the node has no sensors.
  static func telemetry(readingCount: Int) -> String {
    readingCount == 0
      ? L10n.RemoteNodes.RemoteNodes.Status.noSensorData
      : L10n.RemoteNodes.RemoteNodes.Status.Tile.sensorCount(readingCount)
  }
}

// MARK: - Section Button

/// One dashboard button: the section's tile, which pushes its page.
struct NodeSectionTileButton: View {
  let page: NodeSectionPage
  let detail: String?
  let open: (NodeSectionPage) -> Void

  var body: some View {
    Button {
      open(page)
    } label: {
      NavigationTile(page.title, systemImage: page.systemImage, color: page.color, detail: detail)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Section Card

/// The card at the top of a section page: its reload control (and any count or "i") on the
/// trailing edge, and the loading, error or empty line under it while there's one. The navigation
/// bar already names the page, so the card's own title is only shown where it doesn't — e.g. a
/// sheet titled with the contact's name — via `showsTitle`.
struct NodeSectionCard<Accessory: View, Content: View>: View {
  let page: NodeSectionPage
  let hasContent: Bool
  let showsTitle: Bool
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let content: () -> Content

  init(
    _ page: NodeSectionPage,
    hasContent: Bool = true,
    showsTitle: Bool = false,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.page = page
    self.hasContent = hasContent
    self.showsTitle = showsTitle
    self.accessory = accessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if showsTitle {
          SettingCardLabel(page.title, systemImage: page.systemImage, color: page.color)
            .accessibilityAddTraits(.isHeader)
        }
        Spacer(minLength: 0)
        accessory()
      }
      if hasContent {
        VStack(alignment: .leading, spacing: 10) {
          content()
        }
        .padding(.top, 12)
      }
    }
    .cardSurface(padding: 12)
  }
}

// MARK: - Shared Pages

/// The node's sensor readings as a page. Reads them on first appearance; pull to read again.
struct NodeTelemetryPage: View {
  let helper: NodeStatusViewModel
  let connectionState: DeviceConnectionState
  let onRequestTelemetry: () async -> Void

  var body: some View {
    CardForm {
      NodeTelemetrySection(
        helper: helper,
        connectionState: connectionState,
        onRequestTelemetry: onRequestTelemetry
      )
    }
    .pageLoadingBar(isLoading: helper.isLoadingTelemetry)
    .refreshable {
      guard connectionState == .ready, !helper.isLoadingTelemetry else { return }
      // Shielded from the refresh task's cancellation when the reply lands mid-refresh.
      await Task { await onRequestTelemetry() }.value
    }
    .onAppear {
      // Unstructured, so pushing a page from here (the map) doesn't cancel a read in flight.
      guard !helper.telemetryLoaded, !helper.isLoadingTelemetry else { return }
      Task { await onRequestTelemetry() }
    }
    .flashingNavigationTitle(NodeSectionPage.telemetry.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// The node's battery as one page, opened from the Dashboard's Battery card: the battery's and the
/// sensors' history charts (each opening its full graph), then the battery curve setting (the
/// user, 2026-11-08: no tiles or sheets in between). The sensors are read when it opens, so the
/// Battery card's temperature fills in and the reading joins the charts; the stored curve is read
/// too. Without the node's key there's no history, and the page is the curve alone.
struct NodeBatteryCurvePage: View {
  let helper: NodeStatusViewModel
  let session: RemoteNodeSessionDTO
  let connectionState: DeviceConnectionState
  let connectedDeviceID: UUID?
  var onRequestTelemetry: (() async -> Void)?

  private var curveSection: some View {
    NodeBatteryCurveSection(helper: helper, connectionState: connectionState)
  }

  var body: some View {
    Group {
      if let publicKey = helper.effectivePublicKey {
        TelemetryHistoryOverviewView(
          publicKey: publicKey,
          radioID: session.radioID,
          showNeighbors: false,
          title: L10n.RemoteNodes.RemoteNodes.Status.battery,
          scope: .battery,
          accessory: AnyView(curveSection),
          // A sensor read or a new curve redraws the charts.
          refreshID: helper.snapshotsRecorded &+ helper.ocvValues.hashValue
        )
      } else {
        CardForm { curveSection }
          .flashingNavigationTitle(NodeSectionPage.batteryCurve.title)
          .navigationBarTitleDisplayMode(.inline)
      }
    }
    .refreshable {
      guard let onRequestTelemetry, connectionState == .ready, !helper.isLoadingTelemetry else { return }
      // Shielded from the refresh task's cancellation when the reply lands mid-refresh.
      await Task { await onRequestTelemetry() }.value
    }
    .onAppear {
      // The sensors are read here rather than with the Dashboard; unstructured, as on the sensors page.
      if let onRequestTelemetry, connectionState == .ready, !helper.telemetryLoaded, !helper.isLoadingTelemetry {
        Task { await onRequestTelemetry() }
      }
      guard let connectedDeviceID else { return }
      Task { await helper.loadOCVSettings(publicKey: session.publicKey, radioID: connectedDeviceID) }
    }
  }
}
