import CoreLocation
import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "Home")

/// Home's six status cards, in pairs that belong together: Battery and Network (the radio's power
/// and link), Radio and GPS (the radio's air and position), Contacts and Chats (the mesh). The radio's
/// sensors are in Home's header, under the sunrise and sunset (`HomeHeaderCard`). Two
/// columns on a phone put each pair on a row; iPad's three columns and the single column at
/// accessibility sizes keep the same sequence, which is also the VoiceOver order. Each card opens
/// the page behind it; the Radio card also sends an advert from its menu, and a chat on the Chats
/// card opens that chat. With no radio only Contacts and Chats stay, while they hold saved data.
///
/// On iPad at regular width the cards fill the screen down to the tab bar (`arrangement`), with
/// Home's header placed among them: upright, Traffic grows to the bottom; sideways, the header and
/// tiles take the left half and Traffic the full height of the right.
struct HomeStatusCards: View {
  @Environment(\.appState) private var appState

  let dashboard: HomeDashboardModel
  let readings: DeviceReadingsModel
  let now: Date
  /// Whether to show the cards that read a radio; off while there is none.
  let showsRadioCards: Bool
  /// How the cards fill the page; `.stacked` (the phone's) leaves the header to the page.
  var arrangement: HomeDashboardArrangement = .stacked
  /// Opens the radio picker, for the device cards while no radio is connected.
  let onConnect: () -> Void

  @State private var isSendingAdvert = false
  @State private var advertSucceeded = false
  @State private var advertFailed = false
  /// The radio's GPS receiver state, read from its custom vars; nil until read.
  @State private var radioGPSState: DeviceGPSState?
  /// The read `radioGPSState` came from, so Home reappearing doesn't ask the radio again.
  @State private var radioGPSStateReadID: String?
  /// The radio's battery over the last day (volts), from its history: the Battery card's trend, drawn
  /// as a repeater's telemetry is (`HistoryMetricCard`). Empty until read, or with too few readings.
  @State private var batteryTrend: [MetricChartView.DataPoint] = []

  /// How far back the Battery card's trend reaches.
  private static let batteryTrendWindow: TimeInterval = 24 * 60 * 60

  /// The Network card's tint; CarPlay's Network card uses it too.
  nonisolated static let cairnTeal = Color(red: 0.08, green: 0.71, blue: 0.65)

  var body: some View {
    arranged
    // The radio's GPS state rides along with each read of its readings (on ready and on pull to
    // refresh), so Home asks for it no more often than it asks for anything else.
    .task(id: radioGPSReadID) {
      await loadRadioGPSState()
    }
    // Re-read as the history grows: each saved battery reading, and each read of the radio.
    .task(id: batteryTrendID) {
      await loadBatteryTrend()
    }
    .sensoryFeedback(.success, trigger: advertSucceeded)
    .sensoryFeedback(.error, trigger: advertFailed)
  }

  @ViewBuilder
  private var arranged: some View {
    switch arrangement {
    case .stacked:
      VStack(spacing: CardStyle.spacing) {
        cards()
        // What the radio hears, across the bottom with the radios' mini spectrum.
        if showsRadioCards {
          trafficCard(fillsHeight: false)
        }
      }
    case .tall:
      VStack(spacing: CardStyle.spacing) {
        header
        cards()
        // Down to the tab bar, with a taller plot and the latest packets.
        if showsRadioCards {
          trafficCard(fillsHeight: true)
        }
      }
    case .sideBySide:
      if showsRadioCards {
        HStack(alignment: .top, spacing: CardStyle.spacing) {
          VStack(spacing: CardStyle.spacing) {
            header
            // Three columns at most, the rows sharing the height so the tiles reach the bottom.
            cards(maxColumns: 3, fillsHeight: true)
          }
          trafficCard(fillsHeight: true)
        }
      } else {
        // No radio, so no Traffic to fill the right: the cards as they stand.
        VStack(spacing: CardStyle.spacing) {
          header
          cards()
        }
      }
    }
  }

  /// Home's header as the page shows it on a phone, for the arrangements that place it among the
  /// cards: the radio's card (which opens Device Info), or Connect without one; then the wardrive bar.
  /// Its own height: the cards below take what the screen has left.
  private var header: some View {
    VStack(spacing: CardStyle.spacing) {
      if showsRadioCards {
        HomeHeaderCard(readings: readings, now: now, onOpen: { openSetting(.deviceInfo) },
                       onOpenConnection: { openSetting(.connection) })
      } else {
        HomeConnectCard(onConnect: onConnect)
      }
      HomeWardriveBar()
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func trafficCard(fillsHeight: Bool) -> some View {
    card(action: { appState.navigation.navigateToScan(section: .packets) }) {
      HomeTrafficCard(fillsHeight: fillsHeight)
    }
  }

  private func cards(maxColumns: Int? = nil, fillsHeight: Bool = false) -> some View {
    MetricTileGrid(maxColumns: maxColumns, fillsHeight: fillsHeight) {
      if showsRadioCards {
        // Dimmed until the radio is ready: what they show is the last radio's, or nothing yet.
        // The link is the header's badge (the user, 2026-11-09: a card of its own for it left the
        // page taller than the screen).
        card(action: { openSetting(.battery) }) { batteryCard.opacity(readingsOpacity) }
        card(action: { openSetting(.radio) }) { radioCard.opacity(readingsOpacity) }
          .contextMenu { if device != nil { advertButtons } }
          .accessibilityActions { if device != nil { advertButtons } }
        card(action: { appState.navigation.selectedTab = AppTab.gps.rawValue }) { gpsCard.opacity(readingsOpacity) }
      }
      if showsRadioCards || (dashboard.contactCount ?? 0) > 0 {
        card(action: { appState.navigation.selectedTab = AppTab.contacts.rawValue }) { nodesCard }
      }
      if showsRadioCards || !dashboard.recentConversations.isEmpty {
        card(action: { appState.navigation.selectedTab = AppTab.chats.rawValue }) { chatsCard }
          .accessibilityActions {
            ForEach(dashboard.recentConversations) { line in
              Button(line.name) { open(line) }
            }
          }
      }
    }
  }

  private var device: DeviceDTO? { appState.connectedDevice }
  private var isReady: Bool { appState.isRadioReady }

  /// The radio's cards fade while it is connecting or gone, so stale readings read as such.
  private var readingsOpacity: Double { isReady ? 1 : 0.55 }

  private func card(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
    Button(action: action, label: label)
      .buttonStyle(.plain)
  }

  /// The radio's pages only exist with a radio; without one, the card offers to connect instead.
  private func openSetting(_ detail: SettingsDetail) {
    if device == nil {
      onConnect()
    } else {
      appState.navigation.navigateToSetting(detail)
    }
  }

  // MARK: - Battery

  /// The charge in the repeaters' telemetry style (the user, 2026-11-09): the percentage and its level,
  /// the last day's trend under it, then the voltage and the day's range. Until there are two readings to
  /// draw, the meter bar takes the trend's place.
  private var batteryCard: some View {
    let percent = appState.radioBatteryPercent
    let level = percent.map(BatteryLevel.init(percent:))
    let detail = batteryDetail
    let trend = batteryTrendMetric
    let range = trend?.contextParts.first
    return HomeCard(
      title: L10n.Settings.DeviceInfo.battery,
      systemImage: BatteryLevel.symbol(for: percent),
      tint: .green,
      accessibilityValue: [BatteryLevel.formattedPercent(percent), level?.title, detail, range]
        .compactMap(\.self).joined(separator: ", "),
      hint: L10n.Localizable.Home.Hint.battery
    ) {
      HomeCardValue(
        value: BatteryLevel.formattedPercent(percent),
        valueTint: level.map { $0 == .good ? Color.primary : $0.tint } ?? .secondary,
        note: level?.title,
        noteTint: level?.tint ?? .secondary
      )
      if let trend, percent != nil {
        MetricSparkline(series: trend.series)
          .frame(height: 28)
          .padding(.vertical, 1)
        HomeCardDetail(parts: [detail, range].compactMap(\.self))
      } else {
        HomeCardDetail(detail)
        if let percent, let level {
          MeterBar(fraction: Double(percent) / 100, tint: level.tint)
        }
      }
    }
  }

  /// The day's battery readings as a telemetry metric, in the charge's colour; nil with fewer than two.
  private var batteryTrendMetric: HistoryMetric? {
    let tint = appState.radioBatteryPercent.map { BatteryLevel(percent: $0).tint } ?? .green
    let metric = HistoryMetric(
      id: "home.battery", title: L10n.Settings.DeviceInfo.battery,
      systemImage: "battery.75percent", tint: tint, unit: "V", dataPoints: batteryTrend
    )
    return metric.canDrawTrend ? metric : nil
  }

  /// Changes with the radio, each battery reading saved and each read of the radio's readings.
  private var batteryTrendID: String {
    let deviceID = device?.id.uuidString ?? "none"
    let readAt = readings.lastUpdated?.timeIntervalSince1970 ?? 0
    return "\(deviceID)-\(appState.batteryMonitor.historyRecordCount)-\(readAt)"
  }

  /// The radio's battery history for the last day, from the snapshots `BatteryMonitor` and Home save
  /// under its key (Settings › Battery charts the same). The simulator's radio has no history, so it
  /// gets a made-up day for the screenshots.
  private func loadBatteryTrend() async {
    guard let device else {
      batteryTrend = []
      return
    }
    if device.id == MockDataProvider.simulatorDeviceID {
      batteryTrend = Self.demoBatteryTrend(now: .now)
      return
    }
    guard let snapshots = appState.services?.nodeSnapshotService else { return }
    let rows = await snapshots.fetchSnapshots(for: device.publicKey, since: .now.addingTimeInterval(-Self.batteryTrendWindow))
    guard !Task.isCancelled else { return }
    batteryTrend = rows.compactMap { row in
      row.batteryMillivolts.flatMap { $0 > 0 ? MetricChartView.DataPoint(id: row.id, date: row.timestamp, value: Double($0) / 1000) : nil }
    }
  }

  /// A day on battery for the simulator: a slow fall with a little noise and a short top-up at midday.
  static func demoBatteryTrend(now: Date) -> [MetricChartView.DataPoint] {
    (0...48).map { step in
      let t = Double(step) / 48
      let charge = t > 0.45 && t < 0.55 ? (t - 0.45) * 0.9 : (t >= 0.55 ? 0.09 : 0)
      let volts = 4.08 - t * 0.21 + charge + 0.006 * sin(Double(step) * 1.3)
      return MetricChartView.DataPoint(
        id: UUID(), date: now.addingTimeInterval(-batteryTrendWindow * (1 - t)), value: volts
      )
    }
  }

  /// The voltage, or why there is no charge to show; see `HomeStatusLines.batteryDetail`.
  private var batteryDetail: String {
    HomeStatusLines.batteryDetail(
      hasDevice: device != nil,
      voltage: appState.radioBatteryVoltage,
      isReady: isReady,
      batteryPresent: appState.batteryMonitor.deviceBattery?.isBatteryPresent
    )
  }

  // MARK: - Chats

  private var chatsCard: some View {
    // The store's own count, not the app badge: the badge reads 0 when it's turned off and
    // leaves out kinds whose notifications are off, while the lines below still show unread.
    let unread = dashboard.unreadTotal
    let lines = dashboard.recentConversations
    let names = appState.nodeAppearance.names
    let spoken = lines.map { line in
      [line.name, HomeFormat.age(now.timeIntervalSince(line.date)), line.previewLine(names: names)]
        .compactMap(\.self).joined(separator: ", ")
    }
    return HomeCard(
      title: L10n.Localizable.Tabs.chats,
      systemImage: "bubble.left.and.bubble.right.fill",
      tint: .blue,
      pill: unread > 0 ? unread.formatted() : nil,
      accessibilityValue: ([unread > 0 ? L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(unread) : nil] + spoken)
        .compactMap(\.self)
        .joined(separator: ". ")
        .nonEmpty ?? L10n.Chats.Chats.Row.noMessages,
      hint: L10n.Localizable.Home.Hint.chats
    ) {
      if lines.isEmpty {
        HomeCardDetail(L10n.Chats.Chats.Row.noMessages)
          .padding(.top, 2)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(lines) { line in
            conversationLine(line)
          }
        }
        .padding(.top, 2)
      }
    }
  }

  private func conversationLine(_ line: HomeDashboardModel.ConversationLine) -> some View {
    // A button within the card's: a chat opens itself, and the rest of the card opens the list.
    Button {
      open(line)
    } label: {
      // One line a chat (the user, 2026-11-09: the card is full width now): its name, the latest
      // message cut to what fits, how long ago.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // the chat's name in blue (bold while unread), a channel's sender in teal, the message in the
        // detail ink, so the names stand apart from the text (the user, 2026-11-09)
        Text(line.name)
          .font(.subheadline.weight(line.isUnread ? .bold : .semibold))
          .foregroundStyle(Color.blue)
          .lineLimit(1)
          .layoutPriority(1)
        if let preview = previewText(line), !preview.characters.isEmpty {
          Text(preview)
            .font(.subheadline)
            .foregroundStyle(HomeCardDetail.ink)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Text(HomeFormat.age(now.timeIntervalSince(line.date)))
          .font(.footnote.monospacedDigit())
          .foregroundStyle(HomeCardDetail.ink)
          .fixedSize()
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  /// "Alice Chen: Net check…" with the sender in teal, in the localized order.
  private func previewText(_ line: HomeDashboardModel.ConversationLine) -> AttributedString? {
    guard let parts = line.previewParts(names: appState.nodeAppearance.names) else { return nil }
    guard let sender = parts.sender else { return AttributedString(parts.text) }
    var text = AttributedString(L10n.Localizable.Home.Chats.preview(sender, parts.text))
    if let range = text.range(of: sender) {
      text[range].foregroundColor = .teal
      text[range].font = .subheadline.weight(.medium)
    }
    return text
  }

  private func open(_ line: HomeDashboardModel.ConversationLine) {
    let navigation = appState.navigation
    switch line.route {
    case let .direct(contact): navigation.navigateToChat(with: contact)
    case let .channel(channel): navigation.navigateToChannel(with: channel)
    case let .room(session): navigation.navigateToRoom(with: session)
    case nil: navigation.showTab(.chats)
    }
  }

  // MARK: - Contacts

  private var nodesCard: some View {
    let count = dashboard.contactCount.map { $0.formatted() } ?? "—"
    // Counted against the card's clock, so a node heard a day ago drops out on its own.
    let newCount = dashboard.newNodeCount(now: now)
    let last = dashboard.lastHeard
    let lastLine = last.map { L10n.Localizable.Home.Nodes.last($0.name) } ?? L10n.Localizable.Home.Nodes.noAdverts
    let whereLine = last.map(lastHeardLine)
    // Read from the directory itself, not through Home's reload key, so it adds no reloads; the
    // card's clock counts it down when the neighbours go quiet.
    let nearby = appState.neighbourDirectory.nearbyNowCount(now: now)
    let nearbyLine = Self.nearbyNowLine(nearby)
    return HomeCard(
      title: L10n.Localizable.Tabs.nodes,
      systemImage: "point.3.filled.connected.trianglepath.dotted",
      tint: AppTab.contacts.accentColor,
      // The node count on the card's badge, as Chats has its unread count (the user, 2026-11-09); the
      // adverts heard since Nodes was last open stay on the Nodes tab's own badge, and new nodes on
      // the pink line under it.
      pill: dashboard.contactCount.map { $0.formatted() },
      accessibilityValue: [
        count,
        newCount > 0 ? L10n.Localizable.Home.Nodes.newAccessibility(newCount) : nil,
        Self.nearbyNowAccessibility(nearby),
        lastLine,
        whereLine,
      ].compactMap(\.self).joined(separator: ", "),
      hint: L10n.Localizable.Home.Hint.nodes
    ) {
      if newCount > 0 {
        HomeCardDetail(L10n.Localizable.Home.Nodes.new(newCount), tint: .pink)
      }
      // Buttons within the card's, as the Chats card's lines are: Nearby opens Scan & Traffic's
      // nodes, the last node its page (or the Heard list for one not saved); the rest of the
      // card opens the Nodes tab.
      if let nearbyLine {
        Button {
          appState.navigation.navigateToScan(section: .nodes)
        } label: {
          HomeCardDetail(nearbyLine, tint: .accentColor)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
      }
      if let last {
        Button {
          open(last)
        } label: {
          VStack(alignment: .leading, spacing: 0) {
            HomeCardDetail(lastLine, tint: .accentColor)
            if let whereLine {
              HomeCardDetail(whereLine)
            }
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
      } else {
        HomeCardDetail(lastLine)
      }
    }
    .accessibilityActions {
      if let nearbyLine {
        Button(nearbyLine) { appState.navigation.navigateToScan(section: .nodes) }
      }
      if let last {
        Button(lastLine) { open(last) }
      }
    }
  }

  /// The node's page when it's saved; the Heard list, where it's listed, when it isn't.
  private func open(_ node: HomeDashboardModel.HeardNode) {
    if let contact = node.contact {
      appState.navigation.navigateToContactDetail(contact)
    } else {
      appState.navigation.navigateToDiscovery()
    }
  }

  /// "Nearby now: 3": the confirmed direct neighbours heard in the last 10 minutes, from
  /// `NeighbourDirectory.nearbyNowCount`; nil, so the line is hidden, while there is no snapshot.
  static func nearbyNowLine(_ count: Int?) -> String? {
    count.map(L10n.Localizable.Home.Nodes.nearbyNow)
  }

  /// ``nearbyNowLine(_:)`` for VoiceOver; nil while there is no snapshot.
  static func nearbyNowAccessibility(_ count: Int?) -> String? {
    count.map(L10n.Localizable.Home.Nodes.nearbyNowAccessibility)
  }

  /// "1m · 3.4 mi NE": how long ago, and how far and which way from you when both have a position.
  private func lastHeardLine(_ node: HomeDashboardModel.HeardNode) -> String {
    HomeStatusLines.lastHeardLine(
      lastHeard: node.lastHeard,
      coordinate: node.coordinate,
      origin: appState.bestAvailableLocation,
      now: now
    )
  }

  // MARK: - GPS

  /// The phone's state in the GPS tab's words, from what the app already has: Home never starts
  /// tracking, so a phone without a recent fix reads "No fix" rather than "Searching…".
  private var phoneStatusText: String {
    let location = appState.locationService
    let status = GNSSStatus.phone(
      authorization: location.authorizationStatus,
      location: location.currentLocation,
      now: now
    )
    return status == .searching ? L10n.Localizable.Home.Gps.noFix : status.text
  }

  /// The radio's GPS, worded as the GPS tab's badge: the receiver's state from its custom vars,
  /// and whether it has had a fix from the GPS point in its self telemetry.
  private var radioGPSStatus: GNSSStatus {
    let status: RadioGPSStatus = device != nil && isReady
      ? RadioGPSReading.status(
        receiver: radioGPSState,
        telemetry: RadioGPSReading.telemetryPosition(in: readings.sensors)
      )
      : .unknown
    return GNSSStatus.radio(isConnected: device != nil, status: status)
  }

  /// The radio's GPS state as the card's badge in its colour (the user, 2026-11-09: as the card's large
  /// value it took a line of its own); then the position, whether
  /// it's shared and the phone's fix, each in a colour that says how it stands: shared green (on
  /// request teal), the phone's fix green, searching orange, refused red.
  private var gpsCard: some View {
    let status = radioGPSStatus
    // Without a radio the title's state already says so; the position line would only repeat it.
    let position = device == nil ? nil : positionLine
    let sharing = device?.locationSharingSummary
    let phoneStatus = phoneGNSSStatus
    let phone = L10n.Localizable.Home.Gps.phone(phoneStatusText)
    return HomeCard(
      title: L10n.Localizable.Tabs.gps,
      systemImage: "location.fill",
      tint: .green,
      // the radio's GPS state as the card's badge, by the chevron, in its colour (the user, 2026-11-09)
      pill: status.text,
      pillTint: status.tint,
      accessibilityValue: [status.text, position, sharing, phone].compactMap(\.self).joined(separator: ", "),
      hint: L10n.Localizable.Home.Hint.gps
    ) {
      if let position {
        Label {
          Text(position)
            .monospacedDigit()
        } icon: {
          Image(systemName: "mappin.and.ellipse")
            .foregroundStyle(.blue)
        }
        .labelStyle(GPSLineLabelStyle())
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(device?.hasLocation == true ? Color.primary : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.top, 2)
      }
      if let sharing {
        HomeCardDetail(sharing, tint: sharingTint, lineLimit: 1)
      }
      HomeCardDetail(phone, tint: phoneStatus.tint == .secondary ? HomeCardDetail.ink : phoneStatus.tint, lineLimit: 1)
    }
  }

  /// Shared publicly green, on request teal, not at all in the detail ink.
  private var sharingTint: Color {
    guard let device else { return HomeCardDetail.ink }
    if device.sharesLocationPublicly { return .green }
    if device.telemetryModeBase > 0, device.telemetryModeLoc > 0 { return .teal }
    return HomeCardDetail.ink
  }

  private var phoneGNSSStatus: GNSSStatus {
    let location = appState.locationService
    return GNSSStatus.phone(authorization: location.authorizationStatus, location: location.currentLocation, now: now)
  }

  /// The radio's position, or that it has none.
  private var positionLine: String {
    guard let device, device.hasLocation else { return L10n.Localizable.Home.Gps.noPosition }
    return HomeFormat.coordinate(latitude: device.latitude, longitude: device.longitude)
  }

  private var radioGPSReadID: String {
    let deviceID = isReady ? appState.connectedDevice?.id.uuidString ?? "none" : "none"
    return "\(deviceID)-\(readings.lastUpdated?.timeIntervalSince1970 ?? 0)"
  }

  /// One custom-vars read: whether the radio has a GPS and has it on.
  private func loadRadioGPSState() async {
    guard isReady, let settingsService = appState.services?.settingsService else {
      radioGPSState = nil
      radioGPSStateReadID = nil
      return
    }
    let readID = radioGPSReadID
    guard readID != radioGPSStateReadID else { return }
    do {
      radioGPSState = try await settingsService.getDeviceGPSState()
      radioGPSStateReadID = readID
    } catch {
      if !(error is CancellationError) {
        logger.warning("Home radio GPS read failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Radio

  private var radioCard: some View {
    let value = device.map { L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz($0.frequency)) } ?? "—"
    let groups = device.map(radioLineGroups) ?? [[L10n.Localizable.Home.noRadio]]
    let lines = groups.map { NodeRouteFormat.joined($0) }
    return HomeCard(
      title: L10n.Settings.Radio.header,
      systemImage: "waveform",
      tint: device?.clientRepeat == true ? AppColors.Radio.repeatMode : .orange,
      accessibilityValue: ([value] + lines).joined(separator: ", "),
      hint: L10n.Localizable.Home.Hint.radio
    ) {
      HomeCardValue(value: value, valueTint: device == nil ? .secondary : .primary, shrinksFraction: true)
      // By position: a group's facts stay together on one line where the card is wide enough.
      ForEach(Array(groups.enumerated()), id: \.offset) { index, parts in
        if index == groups.count - 1, let device, groups.count == 2 {
          presetLine(device, parts: parts)
        } else {
          HomeCardDetail(parts: parts)
        }
      }
    }
  }

  /// "USA · 22 dBm": the preset's name in its country's flag colours, the power in green (the user,
  /// 2026-11-09). On one line where it fits, else one to a line.
  @ViewBuilder
  private func presetLine(_ device: DeviceDTO, parts: [String]) -> some View {
    let preset = HomeStatusLines.preset(device, region: appState.regionSelection)
    let name = Text(parts.first ?? "")
      .font(.subheadline.weight(preset.flatMap(PresetFlag.colors) == nil ? .regular : .bold))
      .foregroundStyle(PresetFlag.style(for: preset))
      // a hairline of shadow keeps a flag's white legible on the light card
      .shadow(color: .black.opacity(PresetFlag.colors(for: preset) == nil ? 0 : 0.35), radius: 0.6)
    let power = parts.count > 1 ? parts[1] : nil
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 4) {
        name
        if let power {
          Text("·").foregroundStyle(HomeCardDetail.ink)
          Text(power).foregroundStyle(.green).fontWeight(.semibold)
        }
      }
      .font(.subheadline)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 0) {
        name.lineLimit(2)
        if let power {
          Text(power).foregroundStyle(.green).fontWeight(.semibold).lineLimit(1)
        }
      }
      .font(.subheadline)
    }
    .monospacedDigit()
  }

  /// The preset's name, "SF7 · 62.5 kHz · CR 4/5", then the transmit power and a packet's time on air,
  /// as groups of facts; see `HomeStatusLines.radioLineGroups`. The noise floor is on the Traffic card.
  private func radioLineGroups(_ device: DeviceDTO) -> [[String]] {
    // Two lines on the card (the user, 2026-11-09): the modulation, then the preset with the power
    // ("Custom · 22 dBm"); a packet's airtime is left to the Radio page and VoiceOver.
    let groups = HomeStatusLines.radioLineGroups(
      device,
      region: appState.regionSelection,
      txPower: appState.radioTxPower
    )
    guard groups.count == 3 else { return groups }
    return [groups[1], [groups[0].first, groups[2].first].compactMap(\.self)]
  }

  @ViewBuilder
  private var advertButtons: some View {
    Button {
      sendAdvert(flood: false)
    } label: {
      Label(L10n.Settings.BleStatus.sendZeroHopAdvert, systemImage: "dot.radiowaves.right")
    }
    .radioDisabled(for: appState.connectionState, or: isSendingAdvert)
    .accessibilityHint(L10n.Settings.BleStatus.SendZeroHopAdvert.hint)

    Button {
      sendAdvert(flood: true)
    } label: {
      Label(L10n.Settings.BleStatus.sendFloodAdvert, systemImage: "dot.radiowaves.left.and.right")
    }
    .radioDisabled(for: appState.connectionState, or: isSendingAdvert)
    .accessibilityHint(L10n.Settings.BleStatus.SendFloodAdvert.hint)
  }

  /// The same advert the status menu sends, with the same haptics.
  private func sendAdvert(flood: Bool) {
    guard !isSendingAdvert else { return }
    isSendingAdvert = true
    Task {
      do {
        try await appState.sendSelfAdvert(flood: flood)
        advertSucceeded.toggle()
      } catch {
        logger.error("Failed to send advert from Home (flood=\(flood)): \(error.localizedDescription)")
        advertFailed.toggle()
      }
      isSendingAdvert = false
    }
  }

  // MARK: - Network
}

/// How the Dashboard lays its cards out (`HomeView`).
enum HomeDashboardArrangement: Equatable {
  /// The phone's, and compact width: one column, Traffic its own height at the bottom.
  case stacked
  /// Upright at regular width: the header and tiles, then Traffic down to the tab bar.
  case tall
  /// Sideways at regular width: the header and tiles on the left, Traffic full height on the right.
  case sideBySide
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

/// A radio preset's country colours, from its flag, for the Radio card's preset name (the user,
/// 2026-11-09: "USA" in red, white and blue). Presets with no one country (custom settings, the repeat
/// bands) keep the detail ink.
enum PresetFlag {
  private static let red = Color(red: 0.80, green: 0.12, blue: 0.16)
  private static let blue = Color(red: 0.10, green: 0.25, blue: 0.62)
  private static let white = Color.white
  private static let green = Color(red: 0.0, green: 0.55, blue: 0.28)
  private static let gold = Color(red: 1.0, green: 0.80, blue: 0.0)
  private static let euBlue = Color(red: 0.0, green: 0.20, blue: 0.60)

  /// The flag's colours in order, by the preset's id.
  static func colors(for preset: RadioPreset?) -> [Color]? {
    guard let id = preset?.id else { return nil }
    if id.hasPrefix("au-") || id.hasPrefix("nz-") { return [blue, white, red] }
    if id.hasPrefix("eu-") { return [euBlue, gold, euBlue] }
    if id.hasPrefix("pt-") { return [green, red] }
    if id.hasPrefix("vn") { return [red, gold] }
    if id.hasPrefix("nl") { return [red, white, blue] }
    switch id {
    case "us-ca", "wcmesh", "lvmesh": return [red, white, blue]
    case "ca": return [red, white, red]
    case "cr", "cl": return [blue, white, red]
    case "cz-narrow", "sk": return [white, blue, red]
    case "ch": return [red, white, red]
    case "hu": return [red, white, green]
    case "br": return [green, gold, blue]
    default: return nil
    }
  }

  /// The name's fill: the flag's colours across it, or the detail ink.
  @MainActor
  static func style(for preset: RadioPreset?) -> AnyShapeStyle {
    guard let colors = colors(for: preset) else { return AnyShapeStyle(HomeCardDetail.ink) }
    return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
  }
}
