import Charts
import CairnServices
import SwiftUI

/// Tools → Network Health: every repeater's battery, noise, and liveness at a glance, with the ones
/// needing attention first. Built from stored status checks and adverts, so it also works offline.
struct NetworkHealthView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var report: NetworkHealthReport?
  /// Check All's run: how far it is, and the task to cancel.
  @State private var checkAll: CheckAllRun?
  /// The CSV staged for the share sheet.
  @State private var csvExport: ExportedFile?
  @AppStorage(AppStorageKey.networkHealthSort.rawValue) private var sortRaw = NetworkHealthSort.issues.rawValue

  private var sort: NetworkHealthSort {
    NetworkHealthSort(rawValue: sortRaw) ?? .issues
  }

  /// One Check All: status asked of each repeater needing attention in turn, with how far it is.
  struct CheckAllRun: Equatable {
    let total: Int
    var done = 0
    var task: Task<Void, Never>?

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.total == rhs.total && lhs.done == rhs.done
    }
  }

  var body: some View {
    Group {
      if let report {
        if report.nodes.isEmpty {
          ContentUnavailableView {
            Label(L10n.Tools.Tools.NetworkHealth.Empty.title, systemImage: "antenna.radiowaves.left.and.right")
          } description: {
            Text(L10n.Tools.Tools.NetworkHealth.Empty.description)
          }
        } else {
          content(report)
        }
      } else {
        ProgressView()
      }
    }
    .flashingNavigationTitle(L10n.Tools.Tools.networkHealth)
    .navigationBarTitleDisplayMode(.inline)
    .pageLoadingBar(reached: checkAll.map {
      (done: $0.done, total: $0.total, title: L10n.Tools.Tools.NetworkHealth.CheckAll.progress($0.done + 1, $0.total))
    })
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        menu
      }
    }
    .task(id: appState.contactsVersion) { await load() }
    .refreshable { await load() }
    .refreshCommand { await load() }
    .onDisappear {
      checkAll?.task?.cancel()
      checkAll = nil
      csvExport?.removeTemporaryFile()
      csvExport = nil
    }
  }

  /// Check All (or its cancel while it runs), the sort, and the report's share.
  private var menu: some View {
    Menu {
      if let checkAll {
        Button(L10n.Tools.Tools.NetworkHealth.CheckAll.cancel, systemImage: "xmark.circle", role: .destructive) {
          checkAll.task?.cancel()
          self.checkAll = nil
        }
      } else {
        Button(L10n.Tools.Tools.NetworkHealth.checkAll, systemImage: "stethoscope", action: startCheckAll)
          .disabled(report?.needsAttention.isEmpty ?? true || appState.services?.binaryProtocolService == nil)
      }
      Picker(selection: $sortRaw) {
        ForEach(NetworkHealthSort.allCases, id: \.self) { sort in
          Label(sort.title, systemImage: sort.systemImage).tag(sort.rawValue)
        }
      } label: {
        Text(L10n.Tools.Tools.NetworkHealth.sort)
      }
      .pickerStyle(.inline)
      if let report, !report.nodes.isEmpty {
        Section(L10n.Tools.Tools.NetworkHealth.share) {
          ShareLink(item: report.text()) {
            Label(L10n.Tools.Tools.NetworkHealth.Share.text, systemImage: "doc.plaintext")
          }
          if let url = csvExport?.url {
            ShareLink(item: url) {
              Label(L10n.Tools.Tools.NetworkHealth.Share.csv, systemImage: "tablecells")
            }
          }
        }
      }
    } label: {
      Label(L10n.Tools.Tools.RxLog.more, systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier("networkHealth.more")
  }

  /// Asks each repeater needing attention for its status, one after another, recording each
  /// answer as a status check, then reloads. A repeater that doesn't answer is skipped.
  private func startCheckAll() {
    guard checkAll == nil, let report, let services = appState.services else { return }
    let targets = report.needsAttention.map(\.contact)
    guard !targets.isEmpty else { return }
    let binary = services.binaryProtocolService
    let snapshots = services.nodeSnapshotService
    checkAll = CheckAllRun(total: targets.count)
    checkAll?.task = Task {
      for contact in targets {
        guard !Task.isCancelled else { break }
        if let response = try? await binary.requestStatus(from: contact.publicKey, type: .repeater) {
          let metrics = NodeStatusMetrics(
            status: response,
            rxAirtimeSeconds: response.repeaterRxAirtimeSeconds,
            receiveErrors: response.receiveErrors
          )
          _ = await snapshots.recordSnapshot(nodePublicKey: contact.publicKey, status: metrics)
        }
        guard !Task.isCancelled else { break }
        checkAll?.done += 1
      }
      checkAll = nil
      await load()
    }
  }

  private func content(_ report: NetworkHealthReport) -> some View {
    List {
      // A row rather than a `MetricTileSection` header: plain-list headers pin while scrolling,
      // and the summary should scroll away with the page. One card, three figures in a line.
      SummaryCard(report: report)
      .listRowInsets(EdgeInsets(
        top: CardStyle.spacing, leading: CardStyle.pageInset, bottom: CardStyle.spacing, trailing: CardStyle.pageInset
      ))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)

      // The explanations sit behind "i" buttons on the group headers rather than as footer
      // paragraphs under the cards. The first group carries the page-wide one.
      let groups: [(title: String, nodes: [NetworkHealthNode], info: String?)] = [
        (L10n.Tools.Tools.NetworkHealth.Section.attention, sort.apply(report.needsAttention), nil),
        (L10n.Tools.Tools.NetworkHealth.Section.healthy, sort.apply(report.healthy), nil),
        (L10n.Tools.Tools.NetworkHealth.Section.noStatus, sort.apply(report.withoutStatus), L10n.Tools.Tools.NetworkHealth.noStatusFooter),
      ].filter { !$0.nodes.isEmpty }
      ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
        Section {
          ForEach(group.nodes) { row($0) }
        } header: {
          header(group.title, info: index == 0
            ? [L10n.Tools.Tools.NetworkHealth.footer, group.info].compactMap { $0 }.joined(separator: "\n\n")
            : group.info)
        }
      }
    }
    .cardListCanvas(theme)
    // Sections sit as close as the cards in them: no extra gap between sections, and headers
    // only as tall as their text.
    .listSectionSpacing(0)
    .environment(\.defaultMinListHeaderHeight, 0)
  }

  @ViewBuilder
  private func header(_ title: String, info: String?) -> some View {
    Group {
      if let info {
        InfoHeader(title, info: info)
      } else {
        Text(title)
      }
    }
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(Color.secondary)
    .textCase(nil)
    .accessibilityAddTraits(.isHeader)
    // Close above its first card, with a card gap's worth of space after the last section.
    .listRowInsets(EdgeInsets(top: CardStyle.spacing, leading: CardStyle.pageInset + 4, bottom: 2, trailing: CardStyle.pageInset))
  }

  /// Each repeater is its own card row, opening the repeater's page: its map, route, Ping and
  /// reading cards, each opening its figures in full, with the history one tap further. It reads
  /// what's stored, so it works offline like the rest of this tool.
  private func row(_ node: NetworkHealthNode) -> some View {
    NavigationLink {
      ContactDetailView(contact: node.contact)
    } label: {
      NetworkHealthRow(node: node)
    }
    .cardListRow(theme)
  }

  private func load() async {
    let loaded = await NetworkHealthReport.load(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
    report = loaded
    // The CSV is staged with the report, so the share sheet has a file ready.
    csvExport?.removeTemporaryFile()
    csvExport = loaded.nodes.isEmpty ? nil : loaded.csvExport()
  }
}

// MARK: - Summary

/// The fleet in three numbers on one card: how many repeaters, how many need attention (orange,
/// with a warning, or a green check when none do), and how many were checked today.
private struct SummaryCard: View {
  let report: NetworkHealthReport

  var body: some View {
    let attention = report.needsAttention.count
    HStack(spacing: 0) {
      stat(
        L10n.Tools.Tools.NetworkHealth.Summary.repeaters,
        systemImage: "antenna.radiowaves.left.and.right",
        tint: .secondary,
        value: report.nodes.count.formatted()
      )
      divider
      stat(
        L10n.Tools.Tools.NetworkHealth.Summary.attention,
        systemImage: attention > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
        tint: attention > 0 ? .orange : .green,
        value: attention.formatted(),
        valueTint: attention > 0 ? .orange : .primary
      )
      divider
      stat(
        L10n.Tools.Tools.NetworkHealth.Summary.checkedToday,
        systemImage: "clock.arrow.circlepath",
        tint: .secondary,
        value: report.checkedCount(since: Date().addingTimeInterval(-86400)).formatted()
      )
    }
    .cardSurface(padding: 12)
  }

  private var divider: some View {
    Divider()
      .frame(height: 36)
      .padding(.horizontal, 4)
  }

  /// One figure: large, with its glyph and label under it, centred in its third.
  private func stat(
    _ title: String,
    systemImage: String,
    tint: Color,
    value: String,
    valueTint: Color = .primary
  ) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.title2.weight(.bold))
        .fontDesign(.rounded)
        .monospacedDigit()
        .foregroundStyle(valueTint)
      Label(title, systemImage: systemImage)
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Row

struct NetworkHealthRow: View {
  @Environment(\.appState) private var appState
  let node: NetworkHealthNode

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(node.contact.displayName)
            .font(.body.weight(.medium))
            .lineLimit(1)
          // The radio's short id, as routes show it: tells apart two repeaters of one name.
          Text(shortID)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .accessibilityHidden(true)
        }
        if !node.issues.isEmpty {
          IssueBadges(issues: node.issues)
        }
        line(activityLine)
        if let checkLine {
          line(checkLine)
        }
      }
      Spacer(minLength: 8)
      if let percent = node.batteryPercent {
        VStack(alignment: .trailing, spacing: 2) {
          Text(L10n.Tools.Tools.NetworkHealth.batteryPercent(percent))
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(percent < NetworkHealthReport.lowBatteryPercent ? Color.orange : .primary)
          let trend = node.batteryTrend
          if trend.count >= 2 {
            BatterySparkline(points: trend)
              .frame(width: 64, height: 22)
              .accessibilityHidden(true)
          }
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func line(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(2)
  }

  private var shortID: String {
    node.contact.publicKey.prefix(max(1, appState.connectedDevice?.hashSize ?? 1)).uppercaseHexString()
  }

  /// How the repeater is doing on the air: when it was heard (or, never heard live, when it last
  /// advertised), the route to it, and how far away it is.
  private var activityLine: String {
    let contact = node.contact
    var parts: [String] = []
    if let lastHeard = node.lastHeard {
      parts.append(L10n.Tools.Tools.NetworkHealth.heard(lastHeard.formatted(.relative(presentation: .named))))
    } else if let lastAdvert = node.lastAdvert {
      parts.append("\(L10n.Contacts.Contacts.Detail.lastAdvert) \(lastAdvert.formatted(.relative(presentation: .named)))")
    }
    parts.append(NodeRouteFormat.routeLabel(
      isFloodRouted: contact.isFloodRouted,
      pathHopCount: contact.pathHopCount,
      displayedHopCount: contact.displayedHopCount(inboundHopCount: nil)
    ))
    if contact.hasLocation,
       let distance = NodeRouteFormat.distanceAway(
         from: appState.bestAvailableLocation,
         latitude: contact.latitude,
         longitude: contact.longitude
       ) {
      parts.append(distance)
    }
    return parts.joined(separator: " · ")
  }

  /// What its last status check said: the signal it hears, its noise floor, how long it has been
  /// up, and how old that check is. Nil before its first check.
  private var checkLine: String? {
    guard let lastChecked = node.lastChecked else { return nil }
    var parts: [String] = []
    if let snr = node.lastSNR {
      parts.append("\(L10n.Chats.Chats.Message.Info.Title.snr) \(L10n.Tools.Tools.Spectrum.Value.db(SpectrumPacketFormat.snr(snr)))")
    }
    if let noise = node.noiseFloor {
      parts.append(L10n.Tools.Tools.NetworkHealth.noise(noise))
    }
    if let uptime = node.uptimeSeconds {
      parts.append("\(L10n.RemoteNodes.RemoteNodes.Status.uptime) \(NodeStatusViewModel.formatDuration(uptime))")
    }
    parts.append(L10n.Tools.Tools.NetworkHealth.checked(lastChecked.formatted(.relative(presentation: .named))))
    return parts.joined(separator: " · ")
  }
}

/// Status carries an icon and a label, never color alone.
private struct IssueBadges: View {
  let issues: [NetworkHealthIssue]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) { badges }
      VStack(alignment: .leading, spacing: 4) { badges }
    }
  }

  @ViewBuilder private var badges: some View {
    ForEach(issues, id: \.self) { issue in
      Label(issue.title, systemImage: issue.systemImage)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(issue.isCritical ? .red : .orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((issue.isCritical ? Color.red : Color.orange).opacity(0.12), in: .capsule)
        .lineLimit(1)
    }
  }
}

/// Seven-day battery trend: one thin line, no axes, fixed 0–100 scale so rows compare fairly.
private struct BatterySparkline: View {
  let points: [(date: Date, percent: Int)]

  var body: some View {
    Chart {
      ForEach(Array(points.enumerated()), id: \.offset) { _, point in
        LineMark(x: .value("Time", point.date), y: .value("Battery", point.percent))
          .interpolationMethod(.monotone)
          .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
          .foregroundStyle(.mint)
      }
    }
    .chartYScale(domain: 0...100)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
  }
}
