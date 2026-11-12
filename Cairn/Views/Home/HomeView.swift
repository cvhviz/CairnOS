import CairnServices
import MeshCore
import OSLog
import StoreKit
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "HomeAdvert")

/// The Home tab, after Cairn's Home screen on the L2 Pro and Heltec radios: a header with the
/// radio, the day and the sun, and status cards that each open their page. Every tool is behind the
/// one button at the top (`HomeToolsButton`).
/// The cards open the radio's pages (Device Info, Radio, Battery, Connection, Location & Sharing) in
/// Settings, their one home, over Home.
/// Reads what the app already holds; the radio traffic it adds is one stats and sensor read when
/// the radio becomes ready and on pull to refresh, and the Traffic card's spectrum readings while
/// Home is on screen.
struct HomeView: View {
  private struct LoadID: Equatable {
    let radioID: UUID?
    let servicesVersion: Int
  }

  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase

  /// Three chats at most on the Chats card, one line each (the user, 2026-11-09): the Chats tab has
  /// the rest, so the card never grows with the number of conversations.
  @State private var dashboard = HomeDashboardModel(conversationLimit: 3)
  @State private var readings = DeviceReadingsModel()
  @State private var showingDeviceSelection = false
  /// The occasional support pop-up (`SupportPromptSchedule`), with Apple's review prompt after it.
  @State private var showingSupportPrompt = false
  @Environment(\.requestReview) private var requestReview
  /// The radio and connection the header's readings were read from, so coming back to the tab
  /// (a pushed page popping, a tab switch) keeps them rather than blanking and re-reading. Set
  /// only once a read completes: a read cut short is tried again on the next appearance, and a
  /// reconnect while Home was hidden (a new connection, so a new key) is read afresh on return.
  @State private var readingsKey: ReadingsKey?
  /// What the page shows above the tab bar, for the iPad's layouts that fill it.
  @State private var visibleSize: CGSize = .zero

  private struct ReadingsKey: Equatable {
    let deviceID: UUID
    let servicesVersion: Int
  }

  /// Readings older than this are read again when Home comes back into view or the app returns
  /// to the foreground, so the noise floor, steps and uptime don't sit hours old.
  private static let readingsMaximumAge: TimeInterval = 5 * 60

  var body: some View {
    // The path lives on the coordinator so a tool opened from another tab (`navigateToTool`) lands
    // here.
    @Bindable var navigation = appState.navigation
    NavigationStack(path: $navigation.homePath) {
      content
        // The bar's backdrop always drawn, as the Nodes list's shows it, so every tab's top reads alike
        // (the user, 2026-11-08).
        .tabTopBarBackdrop()
        .navigationDestination(for: HomeRoute.self) { route in
          switch route {
          case let .tool(tool):
            ToolDestinationView(tool: tool) { LineOfSightView() }
              .navigationTitle(tool.pageTitle)
              .navigationBarTitleDisplayMode(.inline)
          }
        }
        // The cards below already show the radio's name, battery and power, so Dashboard's bar
        // names the app instead of repeating them (the other tabs keep `deviceNameTitle`). The
        // page title stays the navigation title for back buttons and VoiceOver.
        .navigationTitle(L10n.Localizable.Tabs.home)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .principal) {
            HomeAppTitle()
          }
        }
        // Settings, every setting's one home; the cards below open the radio's pages in it, the
        // header card Device Info, which the other tabs' titles open.
        .toolbar {
          settingsGearToolbarItem()
        }
        .toolbar {
          ToolbarItemGroup(placement: .topBarTrailing) {
            // Send Advert in the bar, one tap: the Radio card's long press was hard to find.
            HomeAdvertButton()
            HomeToolsButton()
          }
        }
    }
    .sheet(isPresented: $showingDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showingSupportPrompt, onDismiss: { requestReview() }) {
      SupportPromptSheet()
    }
  }

  /// Each new connection counts toward the pop-up, which waits a moment and never covers anything:
  /// a Home that's been left, or a sheet already up, puts it off to a later connection.
  private func considerSupportPrompt() async {
    #if DEBUG
      // Screenshot runs show it at once: `-uiTestSupportPrompt YES`; other runs never see it.
      if UserDefaults.standard.bool(forKey: "uiTestSupportPrompt") {
        await TipJarStore.shared.loadProducts()
        showingSupportPrompt = true
        return
      }
      if ProcessInfo.processInfo.isScreenshotMode { return }
    #endif
    guard SupportPromptSchedule.noteConnection() else { return }
    try? await Task.sleep(for: .seconds(3))
    guard !Task.isCancelled, !showingDeviceSelection, !appState.navigation.isSettingsPresented else { return }
    SupportPromptSchedule.markShown()
    // No tips to offer (offline, say): the pop-up would have nothing to do, so only Apple's prompt.
    await TipJarStore.shared.loadProducts()
    if TipJarStore.shared.loadState == .loaded {
      showingSupportPrompt = true
    } else {
      requestReview()
    }
  }

  /// The phone's one column, and on iPad at regular width a page that fills the screen above the tab
  /// bar: upright, the Traffic card grows to the bottom; sideways (a window clearly wider than tall),
  /// the header and tiles on the left and Traffic full height on the right. Accessibility text sizes
  /// keep the column, which scrolls.
  private var arrangement: HomeDashboardArrangement {
    guard TabSplitLayout.usesSplit(
      horizontalSizeClass: horizontalSizeClass,
      verticalSizeClass: verticalSizeClass,
      idiom: UIDevice.current.userInterfaceIdiom
    ), !dynamicTypeSize.isAccessibilitySize else { return .stacked }
    return visibleSize.width > visibleSize.height * 1.2 ? .sideBySide : .tall
  }

  private var content: some View {
    ScrollView {
      // Relative ages, the uptime and the date move on with the clock; nothing else polls.
      TimelineView(.everyMinute) { context in
        let arrangement = arrangement
        if arrangement != .stacked {
          // The header sits among the cards, which stretch to the bottom of the screen.
          HomeStatusCards(
            dashboard: dashboard,
            readings: readings,
            now: context.date,
            showsRadioCards: !(appState.connectedDevice == nil && appState.connectionState == .disconnected),
            arrangement: arrangement
          ) {
            showingDeviceSelection = true
          }
          .padding(CardStyle.pageInset)
          .fillingScrollHeight(visibleSize.height)
        } else {
          VStack(alignment: .leading, spacing: CardStyle.spacing) {
            // No radio, and none on the way: the banner says so once, and the cards that would
            // each repeat it stand aside for what the app keeps by itself.
            let hasNoRadio = appState.connectedDevice == nil && appState.connectionState == .disconnected
            if hasNoRadio {
              HomeConnectCard { showingDeviceSelection = true }
            } else {
              HomeHeaderCard(
                readings: readings, now: context.date,
                onOpen: { openDevicePage(.deviceInfo) },
                onOpenConnection: { openDevicePage(.connection) }
              )
            }

            HomeWardriveBar()

            HomeStatusCards(dashboard: dashboard, readings: readings, now: context.date, showsRadioCards: !hasNoRadio) {
              showingDeviceSelection = true
            }
          }
          .padding(CardStyle.pageInset)
        }
      }
    }
    .measuringVisibleScrollSize($visibleSize)
    .cardCanvas(theme)
    .refreshable { await refresh() }
    // Everything is read when Home appears and for each radio and connection; after that each
    // card re-reads on its own changes, paced by the model so a read under way always lands: an
    // advert burst re-reads the nodes only, a message the chats only.
    .task(id: loadID) {
      await dashboard.load(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
    }
    .onChange(of: appState.contactsVersion) {
      dashboard.requestNodes(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
    }
    .onChange(of: appState.conversationsVersion) {
      dashboard.requestConversations(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
    }
    // One read of the radio's stats and sensors each time a radio becomes ready, and again when
    // the last read has gone stale.
    .task(id: readyReadingsKey) {
      guard let key = readyReadingsKey else {
        // Gone or not ready: the next ready radio (even the same one) is read afresh.
        readingsKey = nil
        return
      }
      // The PIN the Connection card names, which the radio's own settings can change.
      await appState.refreshBLEPin()
      if key == readingsKey {
        await refreshReadingsIfStale()
        return
      }
      readings = DeviceReadingsModel()
      await loadReadings()
      if readings.hasLoaded {
        readingsKey = key
      }
      await considerSupportPrompt()
      #if DEBUG
        // Screenshot runs open Device Info once the radio is ready: `-uiTestDeviceInfo YES`.
        if UserDefaults.standard.bool(forKey: "uiTestDeviceInfo") {
          appState.navigation.navigateToSettingOverHub(.deviceInfo)
        }
        // And Connections: `-uiTestConnections YES`.
        if UserDefaults.standard.bool(forKey: "uiTestConnections") {
          appState.navigation.navigateToSetting(.connections)
        }
        // And Settings: `-uiTestSettings hub`, or a page by its case name (`-uiTestSettings radio`).
        if let name = UserDefaults.standard.string(forKey: "uiTestSettings") {
          if let page = SettingsDetail.allCases.first(where: { "\($0)" == name }) {
            appState.navigation.navigateToSetting(page)
          } else {
            appState.navigation.presentSettings()
          }
        }
        // And Scan & Traffic: `-uiTestScan YES` (or `-uiTestScanPackets YES`, which also adds a
        // minute of packets) on its nodes, `-uiTestTraffic YES` on its packets, as the Traffic
        // page opened before the two became one page.
        if UserDefaults.standard.bool(forKey: "uiTestTraffic") {
          appState.navigation.navigateToScan(section: .packets)
        } else if UserDefaults.standard.bool(forKey: "uiTestScan") || UserDefaults.standard.bool(forKey: "uiTestScanPackets") {
          appState.navigation.navigateToScan(section: .nodes)
        }
        // And Trace Path: `-uiTestTracePath YES`.
        if UserDefaults.standard.bool(forKey: "uiTestTracePath") {
          appState.navigation.navigateToTool(.tracePath)
        }
        // And Line of Sight: `-uiTestLineOfSight YES`.
        if UserDefaults.standard.bool(forKey: "uiTestLineOfSight") {
          appState.navigation.navigateToTool(.lineOfSight)
        }
      #endif
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await refreshReadingsIfStale() }
    }
    .task {
      // One location request for the sun times and distances, only if already allowed.
      let location = appState.locationService
      if location.isAuthorized, location.currentLocation == nil {
        location.requestLocation()
      }
    }
  }

  /// The radio's pages only exist with a radio; without one, the header offers to connect instead,
  /// as the status cards do.
  private func openDevicePage(_ detail: SettingsDetail) {
    if appState.connectedDevice == nil {
      showingDeviceSelection = true
    } else {
      appState.navigation.navigateToSetting(detail)
    }
  }

  private var loadID: LoadID {
    LoadID(
      radioID: appState.currentRadioID,
      servicesVersion: appState.servicesVersion
    )
  }

  private var readyDeviceID: UUID? {
    appState.isRadioReady ? appState.connectedDevice?.id : nil
  }

  private var readyReadingsKey: ReadingsKey? {
    readyDeviceID.map { ReadingsKey(deviceID: $0, servicesVersion: appState.servicesVersion) }
  }

  /// Reads the radio again, keeping the old readings on screen meanwhile, when the last read is
  /// older than `readingsMaximumAge`.
  private func refreshReadingsIfStale() async {
    guard appState.isRadioReady, readyReadingsKey == readingsKey, !readings.isLoading else { return }
    if let lastUpdated = readings.lastUpdated, Date.now.timeIntervalSince(lastUpdated) < Self.readingsMaximumAge {
      return
    }
    await loadReadings()
  }

  private func loadReadings() async {
    if appState.connectedDevice?.id == MockDataProvider.simulatorDeviceID {
      readings.loadSimulated(telemetry: MockDataProvider.selfTelemetryFrame)
      return
    }
    await readings.load(
      settingsService: appState.services?.settingsService,
      binaryProtocolService: appState.services?.binaryProtocolService
    )
    await recordReadingsHistory()
    // a Cairn radio's step count, kept as the day's total for the Trips page
    if let device = appState.connectedDevice, readings.sensorsLoaded {
      appState.tripRecorder.noteSensors(readings.sensors, radioID: device.radioID, cairnFirmware: device.isCairnFirmware)
    }
  }

  /// Saves this read to the radio's own history under its key, as a repeater's status and telemetry are
  /// (one row a quarter hour, `NodeSnapshotPolicy`): its noise floor, signal and uptime, and its
  /// sensors, so Home's tiles can draw their trends. The battery goes with them: a row's status is
  /// written once, and without it this would leave the row's battery empty (`BatteryMonitor` saves the
  /// battery on its own between reads).
  private func recordReadingsHistory() async {
    guard let device = appState.connectedDevice,
          let snapshots = appState.services?.nodeSnapshotService else { return }
    let batteryMV = readings.core.map(\.batteryMV).flatMap { $0 > 0 ? $0 : nil }
      ?? appState.batteryMonitor.deviceBattery.flatMap { $0.isBatteryPresent && $0.level > 0 ? UInt16(clamping: $0.level) : nil }
    let status = readings.radio.map { radio in
      NodeStatusMetrics(
        batteryMillivolts: batteryMV,
        lastSNR: radio.lastSNR, lastRSSI: Int16(radio.lastRSSI), noiseFloor: radio.noiseFloor,
        uptimeSeconds: readings.core?.uptimeSeconds, rxAirtimeSeconds: radio.rxAirtimeSeconds,
        packetsSent: nil, packetsReceived: nil, receiveErrors: nil,
        sentDirect: nil, sentFlood: nil, receivedDirect: nil, receivedFlood: nil,
        directDuplicates: nil, floodDuplicates: nil
      )
    }
    let telemetry: [TelemetrySnapshotEntry] = readings.sensorsLoaded ? readings.sensors.compactMap { point in
      let value: Double? = switch point.value {
      case let .float(value): value
      case let .integer(value): Double(value)
      default: nil
      }
      return value.map { TelemetrySnapshotEntry(channel: Int(point.channel), type: point.typeName, value: $0) }
    } : []
    guard status != nil || !telemetry.isEmpty else { return }
    _ = await snapshots.recordSnapshot(
      nodePublicKey: device.publicKey,
      status: status,
      telemetry: telemetry.isEmpty ? nil : telemetry
    )
  }

  /// Pull to refresh: the battery, the radio's stats and sensors, and the chat and node summaries.
  private func refresh() async {
    await dashboard.load(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
    guard appState.isRadioReady else { return }
    await appState.batteryMonitor.fetchDeviceBattery(services: appState.services, device: appState.connectedDevice)
    await loadReadings()
  }
}

/// Dashboard's bar title: the app's name, centred, lit behind by the radio's RX/TX LED as packets
/// are heard and sent (`radioActivityFlash`). The Cairn mark in the leading corner opens Device
/// Info. Fixed content with no branches, so the hosted toolbar item keeps one identity (see
/// `DeviceNameTitleModifier`). Over the user's background image or gradient it sits on a glass
/// capsule, as the device-name title does.
private struct HomeAppTitle: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @ScaledMetric(relativeTo: .title3) private var markSize: CGFloat = 22

  private static let tracking: CGFloat = 3

  /// Tapping the title opens Settings › About: support, the website, the version.
  var body: some View {
    Button { appState.navigation.navigateToSetting(.about) } label: { title }
      .buttonStyle(.plain)
      .offset(x: MarkedBarTitle<EmptyView>.centeringOffset(markSize: markSize))
      .accessibilityHint(L10n.Settings.About.header)
      #if DEBUG
        // Screenshot runs open About: `-uiTestAbout YES`.
        .onAppear {
          if UserDefaults.standard.bool(forKey: "uiTestAbout") { appState.navigation.navigateToSetting(.about) }
        }
      #endif
  }

  private var title: some View {
    MarkedBarTitle(markSize: markSize) {
      Text(AppIdentity.name)
        .font(.title3.weight(.semibold))
        // spaced capitals, as the CAIRN wordmark on the boards and the logo
        .tracking(Self.tracking)
        .lineLimit(1)
        // The tracking trails the last letter: left out, the capsule's sides match.
        .padding(.trailing, -Self.tracking)
    }
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
    .padding(.horizontal, theme.hasBackdrop ? 10 : 0)
    .padding(.vertical, theme.hasBackdrop ? 2 : 0)
    // The LED fills the glass capsule when there is one, and reaches a little past bare text.
    .radioActivityFlash(horizontalOutset: theme.hasBackdrop ? 0 : 12, verticalOutset: theme.hasBackdrop ? 0 : 4)
    .background {
      Capsule()
        .fill(.regularMaterial)
        .opacity(theme.hasBackdrop ? 1 : 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AppIdentity.spokenName)
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("home.appTitle")
  }
}

/// Wardrive keeps scanning after Scan for Nodes is left, following the phone's location in the
/// background, until it is stopped or the radio disconnects. While it runs Home says so above the
/// cards, with Stop beside it, so it's never left running unseen; the label opens Scan for Nodes.
struct HomeWardriveBar: View {
  @Environment(\.appState) private var appState

  var body: some View {
    let coordinator = appState.probeCoordinator
    if coordinator.isWardriving {
      HStack(spacing: 10) {
        NavigationLink(value: HomeRoute.tool(.nodeDiscovery)) {
          Label(L10n.Tools.Tools.NodeDiscovery.wardriveRunning, systemImage: "car.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(HomeToolColors.lead)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.wardrive.open")
        Button(L10n.Tools.Tools.NodeDiscovery.wardriveStop, systemImage: "stop.fill") {
          coordinator.stopWardrive()
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityIdentifier("home.wardrive.stop")
      }
      .cardSurface(padding: 12)
    }
  }
}

/// Send Advert in Dashboard's bar: a tap asks zero-hop or flood through the same choice sheet as
/// the Tools picker, so neither reach is sent by accident. The glyph answers with a checkmark or a
/// warning for a moment, with the matching haptic.
struct HomeAdvertButton: View {
  @Environment(\.appState) private var appState
  @State private var isSending = false
  @State private var isChoosing = false
  /// nil while idle; the last send's outcome for a moment after it.
  @State private var result: Bool?

  private var systemImage: String {
    switch result {
    case true?: "checkmark"
    case false?: "exclamationmark.triangle.fill"
    case nil: "megaphone.fill"
    }
  }

  var body: some View {
    Button {
      isChoosing = true
    } label: {
      Label(L10n.Tools.Tools.advert, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
    }
    .radioDisabled(for: appState.connectionState, or: isSending)
    .help(L10n.Tools.Tools.advert)
    .accessibilityLabel(L10n.Tools.Tools.advert)
    .accessibilityHint(L10n.Tools.Tools.Subtitle.advert)
    .accessibilityIdentifier("home.sendAdvert")
    .sheet(isPresented: $isChoosing) {
      AdvertChoiceSheet { flood in send(flood: flood) }
    }
    .sensoryFeedback(trigger: result) { _, outcome in
      outcome.map { $0 ? .success : .error }
    }
  }

  private func send(flood: Bool) {
    guard !isSending else { return }
    isSending = true
    Task {
      let succeeded: Bool
      do {
        try await appState.sendSelfAdvert(flood: flood)
        succeeded = true
      } catch {
        logger.error("Failed to send advert from the Dashboard bar (flood=\(flood)): \(error.localizedDescription)")
        succeeded = false
      }
      isSending = false
      result = succeeded
      try? await Task.sleep(for: .seconds(succeeded ? 2 : 3))
      result = nil
    }
  }
}

#Preview {
  HomeView()
    .environment(\.appState, AppState())
}

/// Which advert to send, zero-hop to the nodes in range or flooded across the mesh, as a small
/// sheet with a button for each: the system's choice dialog draws them as faint text on glass.
/// Zero-hop leads, filled in Send Advert's colour; Flood is tinted orange, since every repeater
/// passes it on with everyone's airtime. Shared by Home's Send Advert and Spectrum's.
struct AdvertChoiceSheet: View {
  let onSend: (_ flood: Bool) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "megaphone.fill")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(HomeToolColors.lead.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)

      Text(L10n.Tools.Tools.advert)
        .font(.title3.weight(.bold))
        .accessibilityAddTraits(.isHeader)

      Text(L10n.Tools.Tools.Advert.FloodConfirm.message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 10) {
        Button {
          choose(flood: false)
        } label: {
          Label(L10n.Tools.Intent.Advert.Reach.zeroHop, systemImage: "dot.radiowaves.left.and.right")
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(HomeToolColors.lead)
        .accessibilityHint(L10n.Settings.BleStatus.SendZeroHopAdvert.hint)

        Button {
          choose(flood: true)
        } label: {
          Label(L10n.Tools.Tools.Advert.FloodConfirm.send, systemImage: "dot.radiowaves.up.forward")
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .accessibilityHint(L10n.Settings.BleStatus.SendFloodAdvert.hint)
      }
      .controlSize(.large)
      .padding(.top, 4)
    }
    .padding(.horizontal, 24)
    .padding(.top, 28)
    .padding(.bottom, 16)
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  private func choose(flood: Bool) {
    dismiss()
    onSend(flood)
  }
}
