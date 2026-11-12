import CairnServices
import SwiftUI

// MARK: - Dashboard

/// A logged-in repeater's or room's status readings as a dashboard of full-width cards, shown as
/// soon as the page opens rather than behind a fold-away card: a line saying how fresh the reading
/// is (with the reload), then Health, Signal, Airtime and Packets, and whatever the host appends
/// (a room's post counters). Until the first reading arrives the cards hold "—" so the page doesn't
/// jump; a failed first request or a missing radio takes their place with one card that says so.
/// The request itself is the host's (see `shouldAutoLoadStatus`), so this view never asks the mesh
/// for anything on its own.
struct NodeStatusDashboard<Extra: View>: View {
  /// Which node kind the page is for, so the placeholders before the first reading match the
  /// cards that follow it (a room has no RX airtime or TX queue to show).
  enum Role {
    case repeater
    case room
  }

  let helper: NodeStatusViewModel
  let role: Role
  let connectionState: DeviceConnectionState
  /// Receive errors (repeater only), nil when there are none to report.
  var receiveErrorsDisplay: String?
  /// False on a Dashboard that shows the readings as its own card grid: this then shows only how
  /// fresh they are, or why there are none.
  var showsCards = true
  /// Puts the reload in the bar's top-left corner (the Dashboards, whose sheet has that corner free).
  var reloadInToolbar = false
  /// False when the page shows how fresh the readings are elsewhere (`NodeStatusFreshnessChip` over
  /// the header's map): the line above the cards is left out.
  var showsFreshness = true
  /// False on a page that refreshes with a pull: no reload button above the cards (nor the line
  /// that would hold it alone), so the cards start right under the header.
  var showsReload = true
  let onReload: () async -> Void
  @ViewBuilder var extra: () -> Extra

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    helper: NodeStatusViewModel,
    role: Role,
    connectionState: DeviceConnectionState,
    receiveErrorsDisplay: String? = nil,
    showsCards: Bool = true,
    reloadInToolbar: Bool = false,
    showsFreshness: Bool = true,
    showsReload: Bool = true,
    onReload: @escaping () async -> Void,
    @ViewBuilder extra: @escaping () -> Extra
  ) {
    self.showsCards = showsCards
    self.reloadInToolbar = reloadInToolbar
    self.showsFreshness = showsFreshness
    self.showsReload = showsReload
    self.helper = helper
    self.role = role
    self.connectionState = connectionState
    self.receiveErrorsDisplay = receiveErrorsDisplay
    self.onReload = onReload
    self.extra = extra
  }

  /// RX airtime and channel use need a repeater reply: the room layout parses RX airtime as 0.
  private var showsReceiveAirtime: Bool {
    role == .repeater && !helper.isRoomLayout
  }

  var body: some View {
    Group {
      switch helper.dashboardPhase(connectionState: connectionState) {
      case .loaded, .loading:
        // the reload sits in the toolbar when asked for, or is left to a pull; the freshness line
        // here unless the page shows it over its map
        let reloadHere = !reloadInToolbar && showsReload
        if showsFreshness || reloadHere || showsCards {
          VStack(alignment: .leading, spacing: CardStyle.spacing) {
            if showsFreshness || reloadHere {
              StatusFreshnessBar(helper: helper, connectionState: connectionState, showsReload: reloadHere,
                                 showsText: showsFreshness, onReload: onReload)
            }
            if showsCards {
              HealthCard(helper: helper, showsTxQueue: role == .repeater)
              SignalCard(helper: helper)
              AirtimeCard(helper: helper, showsReceive: showsReceiveAirtime)
              PacketsCard(helper: helper, receiveErrorsDisplay: role == .repeater ? receiveErrorsDisplay : nil)
            }
            extra()
          }
        } else {
          // Nothing of its own here (the Dashboards): no empty stack, which would still take a
          // spacing slot in the form between the header and the cards.
          extra()
        }
      case let .failed(message):
        DashboardMessageCard {
          // Linked but still syncing: the retry waits for the radio, as the reload button does.
          NodeCardLoadFailure(message: message, onRetry: onReload)
            .disabled(connectionState != .ready)
        }
      case .disconnected:
        DashboardMessageCard {
          VStack(spacing: 4) {
            Label(L10n.Localizable.Common.Status.disconnected, systemImage: "antenna.radiowaves.left.and.right.slash")
              .font(.subheadline.weight(.semibold))
            Text(L10n.Settings.RadioStats.disconnected)
              .font(.footnote)
              .multilineTextAlignment(.center)
          }
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .accessibilityElement(children: .combine)
        }
      }
    }
    .toolbar {
      // Always present when asked for, so the bar keeps its item identity across phases.
      if reloadInToolbar {
        ToolbarItem(placement: .topBarLeading) {
          StatusFreshnessBar(helper: helper, connectionState: connectionState, isCompact: true, onReload: onReload)
        }
      }
    }
    .environment(\.dashboardValueTransition, reduceMotion ? .identity : .numericText())
    .environment(\.dashboardAwaitingReading, helper.status == nil)
    .animation(reduceMotion ? nil : .snappy, value: helper.statusUpdatedAt)
  }
}

// MARK: - Freshness Bar

/// "Updated 2 min ago · Since last visit (3h ago)" with the reload button: not a card, just the
/// line that says how old the readings under it are and what their deltas compare against.
private struct StatusFreshnessBar: View {
  let helper: NodeStatusViewModel
  let connectionState: DeviceConnectionState
  /// The bar-corner form: the reload button alone (the text would be crushed into the bar's pill).
  var isCompact = false
  /// False when the reload lives in the toolbar: the line then carries only the text.
  var showsReload = true
  /// False when the text is shown elsewhere (the map chip): the line is the reload alone.
  var showsText = true
  let onReload: () async -> Void

  var body: some View {
    if isCompact {
      reloadButton
    } else {
      fullBar
    }
  }


  private var reloadButton: some View {
    SectionReloadButton(
      isLoading: helper.isLoadingStatus,
      isLoaded: helper.statusLoaded,
      hasError: helper.statusSectionError != nil,
      isDisabled: connectionState != .ready,
      accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.Accessibility.reloadStatus,
      onReload: onReload
    )
  }

  private var fullBar: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if showsText {
        Group {
          if let updatedAt = helper.statusUpdatedAt {
            TimelineView(.everyMinute) { context in
              Text(NodeStatusFreshness.text(helper: helper, updatedAt: updatedAt, now: context.date))
            }
          } else {
            Text(L10n.RemoteNodes.RemoteNodes.Settings.loading)
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      } else {
        Spacer(minLength: 0)
      }

      if showsReload {
        reloadButton
      }
    }
    .padding(.leading, 4)
    .frame(minHeight: 20)
  }
}

/// How fresh a node's readings are, as words (the view model is main-actor state).
@MainActor
enum NodeStatusFreshness {
  /// "Updated 2 min ago · Since last visit (3h ago)"; a refresh that failed leads with the failure,
  /// so the reading below isn't taken for new. `multiline` puts each part on its own line.
  static func text(helper: NodeStatusViewModel, updatedAt: Date, now: Date, multiline: Bool = false) -> AttributedString {
    let updated = NodeStatusViewModel.updatedText(since: updatedAt, now: now)
    if helper.statusSectionError != nil, !helper.isLoadingStatus {
      var failed = AttributedString(L10n.Localizable.Common.Error.failedToLoad)
      failed.foregroundColor = .orange
      return failed + AttributedString(" · " + updated)
    }
    let parts = [updated, helper.previousSnapshotTimestamp].compactMap(\.self)
    return AttributedString(parts.joined(separator: multiline ? "\n" : " · "))
  }

  /// "stale · last read 12 min ago" for the reading cards while a refresh has failed and the
  /// reading on screen is an earlier one; nil while the reading is current or none has arrived.
  static func staleCaption(helper: NodeStatusViewModel, now: Date = .now) -> String? {
    guard helper.statusSectionError != nil, !helper.isLoadingStatus, let updatedAt = helper.statusUpdatedAt else {
      return nil
    }
    return staleCaption(updatedAt: updatedAt, now: now)
  }

  nonisolated static func staleCaption(updatedAt: Date, now: Date) -> String {
    let minutes = max(0, (now.timeIntervalSince(updatedAt) / 60).rounded(.down))
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .short
    return L10n.RemoteNodes.RemoteNodes.Status.stale(formatter.localizedString(fromTimeInterval: -minutes * 60))
  }
}

/// How fresh a logged-in node's readings are as the header's status capsule (`NodeStatusCapsule`):
/// "Updated 2 min ago" in green, orange once it's past a quarter hour or a refresh failed, grey while
/// the first reading is on its way.
struct NodeFreshnessCapsule: View {
  let helper: NodeStatusViewModel
  let now: Date

  private static let staleAfter: TimeInterval = 15 * 60

  var body: some View {
    if let updatedAt = helper.statusUpdatedAt {
      let failed = helper.statusSectionError != nil && !helper.isLoadingStatus
      let stale = now.timeIntervalSince(updatedAt) > Self.staleAfter
      NodeStatusCapsule(
        text: failed ? L10n.Localizable.Common.Error.failedToLoad : NodeStatusViewModel.updatedText(since: updatedAt, now: now),
        tint: failed || stale ? .orange : AppColors.Radio.readyText
      )
      .accessibilityElement(children: .combine)
    } else if helper.isLoadingStatus {
      NodeStatusCapsule(text: L10n.RemoteNodes.RemoteNodes.Settings.loading, tint: .secondary)
    }
  }
}

/// The freshness as a small chip for the bottom-right corner of the header's map
/// (`RemoteNodeHeaderSection.mapOverlay`): the same words as the line above the cards, each part on
/// its own line, on the material the map's other chip uses. Refreshes by the minute.
struct NodeStatusFreshnessChip: View {
  let helper: NodeStatusViewModel

  var body: some View {
    Group {
      if let updatedAt = helper.statusUpdatedAt {
        TimelineView(.everyMinute) { context in
          Text(NodeStatusFreshness.text(helper: helper, updatedAt: updatedAt, now: context.date, multiline: true))
        }
      } else {
        Text(L10n.RemoteNodes.RemoteNodes.Settings.loading)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.trailing)
    .lineLimit(2)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(.regularMaterial, in: .rect(cornerRadius: 6))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Health

/// Battery and uptime side by side in equal halves, like the Signal columns. At accessibility sizes
/// the two stack.
private struct HealthCard: View {
  let helper: NodeStatusViewModel
  let showsTxQueue: Bool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          battery
          Divider()
          uptime
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          battery
            .frame(maxWidth: .infinity, alignment: .leading)
          Divider()
          uptime
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: DashboardMetrics.cardPadding)
  }

  private var battery: some View {
    VStack(alignment: .leading, spacing: 4) {
      DashboardTitle(
        L10n.RemoteNodes.RemoteNodes.Status.battery,
        systemImage: BatteryLevel.symbol(for: helper.batteryPercent)
      )
      if helper.status == nil {
        // The loaded layout's lines, empty, so the card doesn't grow when the reading lands.
        DashboardValue(NodeStatusViewModel.emDash)
        MeterBar(fraction: 0, tint: .secondary)
          .accessibilityHidden(true)
        Text(NodeStatusViewModel.emDash)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      } else if let percent = helper.batteryPercent, let level = helper.batteryLevel {
        // The level word goes with the figure so the state never rests on the meter's color.
        let warns = level != .good
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          DashboardValue(BatteryLevel.formattedPercent(percent), tint: warns ? level.tint : nil)
          Text(level.title)
            .font(.caption.weight(warns ? .semibold : .regular))
            .foregroundStyle(warns ? level.tint : Color.secondary)
        }
        MeterBar(fraction: Double(percent) / 100, tint: level.tint)
        HStack(spacing: 6) {
          Text(helper.batteryVoltageDisplay)
            .monospacedDigit()
          if let delta = helper.batteryDeltaMV {
            StatusDeltaView(delta: Double(delta) / 1000, higherIsBetter: true, unit: " V", fractionDigits: 3)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        // 0 mV: the node has nothing to measure, not an empty battery.
        DashboardValue(L10n.Tools.Tools.Spectrum.notMeasured, tint: .secondary)
      }
    }
    .accessibilityElement(children: .combine)
    // The card's heading for the rotor: Health has no title row of its own.
    .accessibilityAddTraits(.isHeader)
  }

  private var uptime: some View {
    VStack(alignment: .leading, spacing: 4) {
      DashboardTitle(L10n.RemoteNodes.RemoteNodes.Status.uptime, systemImage: "clock")
      DashboardValue(helper.uptimeDisplay)
      if showsTxQueue {
        HStack(spacing: 4) {
          if helper.isTxQueueBacklogged {
            // Read out, so the backlog doesn't rest on the orange alone.
            Image(systemName: "exclamationmark.circle.fill")
              .accessibilityLabel(L10n.Tools.Tools.Spectrum.warning)
          }
          Text(L10n.RemoteNodes.RemoteNodes.Status.txQueue(helper.txQueueDisplay))
            .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(helper.isTxQueueBacklogged ? Color.orange : Color.secondary)
        // Before the first reading the uptime value already says it's loading.
        .accessibilityHidden(helper.status == nil)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Signal

/// The last packet's RSSI and SNR and the noise floor in three columns, each with its change since
/// the last visit, and a footer with how far the signal sat above the noise.
private struct SignalCard: View {
  let helper: NodeStatusViewModel

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    DashboardCard(
      L10n.RemoteNodes.RemoteNodes.Status.signal,
      systemImage: "antenna.radiowaves.left.and.right"
    ) {
      InfoButton(
        L10n.RemoteNodes.RemoteNodes.Status.signalInfo,
        title: L10n.RemoteNodes.RemoteNodes.Status.signal
      )
    } content: {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          rssi
          Divider()
          snr
          Divider()
          noise
        }
      } else {
        HStack(alignment: .top, spacing: 8) {
          rssi
          snr
          noise
        }
      }
      footer
    }
  }

  private var rssi: some View {
    SignalColumn(
      title: L10n.RemoteNodes.RemoteNodes.Status.lastRssi,
      value: helper.lastRSSIDisplay,
      delta: helper.rssiDelta.map {
        StatusDeltaView(delta: Double($0), higherIsBetter: true, unit: " dBm", fractionDigits: 0)
      }
    )
  }

  private var snr: some View {
    SignalColumn(
      title: L10n.RemoteNodes.RemoteNodes.Status.lastSnr,
      value: helper.lastSNRDisplay,
      quality: helper.status.map { SNRQuality(snr: $0.lastSNR) },
      delta: helper.snrDelta.map {
        StatusDeltaView(delta: $0, higherIsBetter: true, unit: " dB", fractionDigits: 1)
      }
    )
  }

  private var noise: some View {
    SignalColumn(
      title: L10n.RemoteNodes.RemoteNodes.Status.noiseFloor,
      value: helper.noiseFloorDisplay,
      delta: helper.noiseFloorDelta.map {
        StatusDeltaView(delta: Double($0), higherIsBetter: false, unit: " dBm", fractionDigits: 0)
      }
    )
  }

  @ViewBuilder
  private var footer: some View {
    if helper.status == nil {
      // Holds the footer's line until the first reading, so the cards below don't shift.
      Divider()
      Text(NodeStatusViewModel.emDash)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    } else if helper.rssiAboveNoise != nil || helper.isNoiseHigh {
      Divider()
      HStack(spacing: 6) {
        if let margin = helper.rssiAboveNoise {
          Text(L10n.RemoteNodes.RemoteNodes.Status.aboveNoise(margin.formatted()))
            .foregroundStyle(.secondary)
        }
        if helper.isNoiseHigh {
          if helper.rssiAboveNoise != nil {
            Text(verbatim: "·")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          Label(L10n.Tools.Tools.NetworkHealth.Issue.highNoise, systemImage: "exclamationmark.triangle.fill")
            .labelStyle(DashboardInlineLabelStyle())
            .foregroundStyle(.orange)
        }
      }
      .font(.caption)
      .accessibilityElement(children: .combine)
    }
  }
}

/// One signal reading: title, value, the SNR's quality word and the change since last visit. Every
/// column has the same lines (title, value, quality, delta), blank where a column has nothing to
/// say, so the three line up top and bottom. At accessibility sizes the column is the full width.
private struct SignalColumn: View {
  let title: String
  let value: String
  var quality: SNRQuality?
  let delta: StatusDeltaView?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 2) {
          titleText
          DashboardValue(value)
          qualityLabel
          delta
        }
      } else {
        VStack(alignment: .leading, spacing: 2) {
          titleText
          DashboardValue(value)
          qualityLabel
          if let delta {
            delta
          } else {
            blankCaptionLine
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var titleText: some View {
    Text(title)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
      .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
  }

  private var blankCaptionLine: some View {
    Text(verbatim: " ")
      .font(.caption)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var qualityLabel: some View {
    if let quality, quality != .unknown {
      HStack(spacing: 3) {
        Circle()
          .fill(quality.color)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
        Text(quality.localizedLabel)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .font(.caption)
    } else if !dynamicTypeSize.isAccessibilitySize {
      blankCaptionLine
    }
  }
}

// MARK: - Airtime

/// Time on air as honest shares of uptime: a quiet node's bars are a dot, never rescaled to look
/// busier. A repeater also gets the channel-use headline; a room has TX only.
private struct AirtimeCard: View {
  let helper: NodeStatusViewModel
  let showsReceive: Bool

  var body: some View {
    DashboardCard(L10n.RemoteNodes.RemoteNodes.Status.airtime, systemImage: "waveform") {
      InfoButton(
        L10n.RemoteNodes.RemoteNodes.Status.airtimeInfo,
        title: L10n.RemoteNodes.RemoteNodes.Status.airtime
      )
    } content: {
      // In the card, not the title row, so the title never has to share its line with it at
      // large text sizes or in longer languages.
      if showsReceive {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(L10n.RemoteNodes.RemoteNodes.Status.channelUse)
            .foregroundStyle(.secondary)
          DashboardFigure(helper.channelUseDisplay ?? NodeStatusViewModel.emDash)
            .fontWeight(.semibold)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
      }
      AirtimeRow(
        title: L10n.RemoteNodes.RemoteNodes.Status.txAirtime,
        systemImage: "arrow.up.circle",
        value: helper.txAirtimeDisplay,
        percent: helper.txAirtimePercentDisplay,
        share: helper.txShare,
        tint: .orange
      )
      if showsReceive {
        AirtimeRow(
          title: L10n.RemoteNodes.RemoteNodes.Status.rxAirtime,
          systemImage: "arrow.down.circle",
          value: helper.rxAirtimeDisplay,
          percent: helper.rxAirtimePercentDisplay,
          share: helper.rxShare,
          tint: .teal
        )
      }
    }
  }
}

/// "TX Airtime  1 h 12 m  2.1%" over a bar of the same share. The share is in the text, so the
/// bar is decoration for VoiceOver.
private struct AirtimeRow: View {
  let title: String
  let systemImage: String
  let value: String
  let percent: String?
  let share: Double?
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          label
          Spacer(minLength: 8)
          figures
        }
        VStack(alignment: .leading, spacing: 2) {
          label
          figures
        }
      }
      // Drawn empty before the first reading, so the row doesn't grow when it lands.
      MeterBar(fraction: share ?? 0, tint: share == nil ? .secondary : tint)
    }
    .accessibilityElement(children: .combine)
  }

  private var label: some View {
    Label(title, systemImage: systemImage)
      .labelStyle(DashboardInlineLabelStyle())
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private var figures: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      DashboardFigure(value)
        .font(.subheadline.weight(.semibold))
      if let percent {
        Text(percent)
          .font(.caption)
          .foregroundStyle(.secondary)
          .contentTransitionForDashboard()
      }
    }
    .monospacedDigit()
    .lineLimit(1)
  }
}

// MARK: - Packets

/// Sent, received and duplicate packets as a small table of total, direct and flood, plus the
/// receive errors on a repeater that has any. The row titles take the spare width so the figures
/// sit on the trailing edge like the other cards'. When the table doesn't fit (accessibility
/// sizes, or a busy node's long counters on a narrow phone) each row stacks its split under its
/// total instead.
private struct PacketsCard: View {
  let helper: NodeStatusViewModel
  let receiveErrorsDisplay: String?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private struct Row: Identifiable {
    let title: String
    let total: String
    let direct: String
    let flood: String
    var id: String { title }
  }

  private var rows: [Row] {
    [
      Row(
        title: L10n.RemoteNodes.RemoteNodes.Status.packetsSent,
        total: helper.packetsSentDisplay,
        direct: helper.sentDirectDisplay,
        flood: helper.sentFloodDisplay
      ),
      Row(
        title: L10n.RemoteNodes.RemoteNodes.Status.packetsReceived,
        total: helper.packetsReceivedDisplay,
        direct: helper.receivedDirectDisplay,
        flood: helper.receivedFloodDisplay
      ),
      Row(
        title: L10n.RemoteNodes.RemoteNodes.Status.duplicates,
        total: helper.duplicatesDisplay,
        direct: helper.directDuplicatesDisplay,
        flood: helper.floodDuplicatesDisplay
      ),
    ]
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        stacked
      } else {
        ViewThatFits(in: .horizontal) {
          table
          stacked
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: DashboardMetrics.cardPadding)
  }

  private var title: some View {
    DashboardTitle(L10n.RemoteNodes.RemoteNodes.Status.packets, systemImage: "tray.full")
      .accessibilityAddTraits(.isHeader)
  }

  private var table: some View {
    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
      GridRow {
        title
          .frame(maxWidth: .infinity, alignment: .leading)
          .gridColumnAlignment(.leading)
        Group {
          Text(L10n.RemoteNodes.RemoteNodes.Status.total)
          Text(L10n.RemoteNodes.RemoteNodes.History.direct)
          Text(L10n.RemoteNodes.RemoteNodes.History.flood)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityHidden(true)
      }
      ForEach(rows) { row in
        Divider()
          .gridCellUnsizedAxes(.horizontal)
        GridRow {
          Text(row.title)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(row.title)
            .accessibilityValue(accessibilityValue(for: row))
          Text(row.total)
            .fontWeight(.semibold)
            .lineLimit(1)
            .contentTransitionForDashboard()
            .accessibilityHidden(true)
          Text(row.direct)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransitionForDashboard()
            .accessibilityHidden(true)
          Text(row.flood)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransitionForDashboard()
            .accessibilityHidden(true)
        }
      }
      if let receiveErrorsDisplay {
        Divider()
          .gridCellUnsizedAxes(.horizontal)
        // Modifiers on a GridRow would turn it into one spanning cell, so each cell is styled.
        GridRow {
          errorsLabel
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Status.receiveErrors)
            .accessibilityValue(receiveErrorsDisplay)
          Text(receiveErrorsDisplay)
            .fontWeight(.semibold)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
        }
      }
    }
    .font(.subheadline)
    .monospacedDigit()
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 10) {
      title
      ForEach(rows) { row in
        Divider()
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline) {
            Text(row.title)
            Spacer(minLength: 8)
            Text(row.total)
              .fontWeight(.semibold)
              .monospacedDigit()
              .lineLimit(1)
              .layoutPriority(1)
          }
          .font(.subheadline)
          Text(L10n.RemoteNodes.RemoteNodes.Status.directFlood(row.direct, row.flood))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(accessibilityValue(for: row))
      }
      if let receiveErrorsDisplay {
        Divider()
        HStack(alignment: .firstTextBaseline) {
          errorsLabel
          Spacer(minLength: 8)
          Text(receiveErrorsDisplay)
            .fontWeight(.semibold)
            .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var errorsLabel: some View {
    Label(L10n.RemoteNodes.RemoteNodes.Status.receiveErrors, systemImage: "exclamationmark.triangle.fill")
      .labelStyle(DashboardInlineLabelStyle())
      .lineLimit(1)
  }

  /// "Total 1,234, Direct 300 · Flood 934": the whole row in one element; "Loading" before the
  /// first reading rather than a run of dashes.
  private func accessibilityValue(for row: Row) -> String {
    if helper.status == nil { return L10n.RemoteNodes.RemoteNodes.Settings.loading }
    return "\(L10n.RemoteNodes.RemoteNodes.Status.total) \(row.total), "
      + L10n.RemoteNodes.RemoteNodes.Status.directFlood(row.direct, row.flood)
  }
}

// MARK: - Building Blocks

/// A full-width dashboard card: a tile-style title row (with an optional trailing accessory such
/// as an "i") over its content. Titles are the tiles' small icon-and-text, not the settings cards'
/// icon tile, so a card stays a line shorter and reads as tiles joined into a row.
private struct DashboardCard<Accessory: View, Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let content: () -> Content

  init(
    _ title: String,
    systemImage: String,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.accessory = accessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        DashboardTitle(title, systemImage: systemImage)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        accessory()
      }
      .frame(minHeight: 22)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: DashboardMetrics.cardPadding)
  }
}

/// A card holding a single message in place of the readings: a failed first load or no radio.
private struct DashboardMessageCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .frame(maxWidth: .infinity)
      .cardSurface(padding: DashboardMetrics.cardPadding)
  }
}

/// The cards' inset, the same as `MetricTile`'s, so a room's post-counter tiles under the
/// dashboard read as the same family.
private enum DashboardMetrics {
  static let cardPadding: CGFloat = 10
}

/// `MetricTile`'s title style: a small symbol and a one-line name in secondary.
private struct DashboardTitle: View {
  let title: String
  let systemImage: String

  init(_ title: String, systemImage: String) {
    self.title = title
    self.systemImage = systemImage
  }

  var body: some View {
    Label(title, systemImage: systemImage)
      .labelStyle(DashboardInlineLabelStyle(spacing: 5))
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

/// A reading's value in the tiles' value font. At accessibility sizes it keeps the reader's size
/// and wraps to a second line rather than shrinking back.
private struct DashboardValue: View {
  let text: String
  var tint: Color?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(_ text: String, tint: Color? = nil) {
    self.text = text
    self.tint = tint
  }

  var body: some View {
    DashboardFigure(text)
      .font(.title3.weight(.semibold))
      .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.primary))
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
      .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
  }
}

/// A figure's text: digits that roll on a refresh, and "Loading" for VoiceOver in place of the
/// "—" placeholder before the first reading.
private struct DashboardFigure: View {
  let text: String

  @Environment(\.dashboardAwaitingReading) private var awaitingReading

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .monospacedDigit()
      .contentTransitionForDashboard()
      .accessibilityLabel(
        awaitingReading && text == NodeStatusViewModel.emDash
          ? L10n.RemoteNodes.RemoteNodes.Settings.loading
          : text
      )
  }
}

/// Icon and title close together, the icon at the text's size, as in the tiles' title rows.
private struct DashboardInlineLabelStyle: LabelStyle {
  var spacing: CGFloat = 4

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: spacing) {
      configuration.icon
      configuration.title
    }
  }
}

// MARK: - Value Transitions

private extension EnvironmentValues {
  /// Numbers roll to their new value on a refresh, unless Reduce Motion is on.
  @Entry var dashboardValueTransition: ContentTransition = .identity
  /// No reading yet: "—" placeholders read as "Loading" to VoiceOver.
  @Entry var dashboardAwaitingReading = false
}

private struct DashboardValueTransition: ViewModifier {
  @Environment(\.dashboardValueTransition) private var transition

  func body(content: Content) -> some View {
    content.contentTransition(transition)
  }
}

private extension View {
  func contentTransitionForDashboard() -> some View {
    modifier(DashboardValueTransition())
  }
}

extension NodeStatusDashboard where Extra == EmptyView {
  /// A dashboard with nothing extra under its cards.
  init(
    helper: NodeStatusViewModel,
    role: Role,
    connectionState: DeviceConnectionState,
    receiveErrorsDisplay: String? = nil,
    showsCards: Bool = true,
    reloadInToolbar: Bool = false,
    showsFreshness: Bool = true,
    showsReload: Bool = true,
    onReload: @escaping () async -> Void
  ) {
    self.init(
      helper: helper,
      role: role,
      connectionState: connectionState,
      receiveErrorsDisplay: receiveErrorsDisplay,
      showsCards: showsCards,
      reloadInToolbar: reloadInToolbar,
      showsFreshness: showsFreshness,
      showsReload: showsReload,
      onReload: onReload
    ) {
      EmptyView()
    }
  }
}
