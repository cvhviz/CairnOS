import CoreLocation
import CairnServices
import CairnUpdateKit
import SwiftUI

/// A logged-in repeater's page: the Dashboard, laid out like Home. The node's map heads it with
/// the controls under it (advert, neighbours, sync time, reboot, access list); then its status,
/// its sensors, its settings as cards that each open in a sheet (as Home's cards open the
/// companion's), and the tools that each open a page, the CLI among them.
struct RepeaterSettingsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: NodeSettingsField?

  let session: RemoteNodeSessionDTO
  /// The last visit's card values (`NodeCardCache`): shown in grey until a sheet or page reads them this visit.
  @State private var cardCache: NodeCardCache.Entry?
  @State private var viewModel = RepeaterSettingsViewModel()
  @State private var statusViewModel = RepeaterStatusViewModel()
  @State private var cliViewModel = NodeCLIViewModel()
  /// The setting whose sheet is open, from its card on the Dashboard.
  @State private var openSettingsPage: NodeSettingsPage?
  @State private var showsCLI = false
  @State private var showsControls = false
  /// Bumped by the Neighbors control to open the Neighbors page on the Dashboard.
  @State private var neighborsPageRequest = 0
  @State private var showRebootConfirmation = false
  @State private var showingLocationPicker = false
  @State private var addRegionParent: RepeaterRegionEntry.Parent?
  @State private var telemetryConfigured = false
  @State private var lifetime = NodePageLifetime()
  @State private var contacts: [ContactDTO] = []
  @State private var discoveredNodes: [DiscoveredNodeDTO] = []
  /// The node's contact, kept live so the Dashboard's route row reflects the path the firmware
  /// learns after a flood login (delivered asynchronously as a contact update).
  @State private var routeContact: ContactDTO?
  /// Refresh the status every so many minutes while the page is open (the bar menu); nil is off.
  @State private var refreshMinutes: Int?
  @AppStorage(AppStorageKey.remoteNodesLoadSettingsOnOpen.rawValue)
  private var loadsSettingsOnOpen = AppStorageKey.defaultRemoteNodesLoadSettingsOnOpen
  /// The battery level a background check notifies at (the bar menu); nil turns the checks off.
  @State private var showsCompare = false
  /// The login sheet again, after a reboot or power-off: a fresh session for the same page.
  @State private var showsReconnect = false
  @State private var logoutError: String?

  var body: some View {
    dashboard
  }

  private var page: some View {
    RepeaterStatusContent(
      viewModel: statusViewModel,
      session: session,
      connectionState: appState.connectionState,
      contacts: contacts,
      discoveredNodes: discoveredNodes,
      userLocation: appState.bestAvailableLocation,
      connectedDeviceID: appState.connectedDevice?.radioID,
      routePathContact: routeContact,
      headerActions: session.isAdmin ? AnyView(headerExtras) : nil,
      headerFacts: session.isAdmin ? { headerFacts(now: $0) } : nil,
      extraLinks: session.isAdmin ? AnyView(Group { controlsTile; cliTile }) : nil,
      adminCards: session.isAdmin ? adminCards : [],
      onEditIdentity: session.isAdmin ? { open(.identity) } : nil,
      neighborsPageRequest: session.isAdmin ? neighborsPageRequest : nil,
      sendCommand: session.isAdmin ? { [viewModel] in try await viewModel.helper.sendAndWait($0) } : nil,
      // Only the status by default: each card reads its settings when opened (its sheet loads on
      // appear), sparing the mesh a dozen requests per visit; the bar menu's switch brings back
      // reading them, and the clock check, right after the status.
      afterStatusLoads: session.isAdmin && loadsSettingsOnOpen ? cardSettingsSteps : [],
      cardCache: session.isAdmin ? cardCache : nil
    )
    // On the host, not the status content: discovery runs for a minute and may end while the
    // settings sheet or a pushed page is showing.
    .discoveryFeedback(statusViewModel)
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Dashboard.title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showsControls) {
      RepeaterControlsPage(settings: viewModel.helper, behavior: behaviorCard)
    }
    .navigationDestination(isPresented: $showsCLI) {
      NodeCLIView(viewModel: cliViewModel)
        .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Settings.Tab.cli)
        .navigationBarTitleDisplayMode(.inline)
    }
    .nodeAccessListDestination()
    .nodeRebootConfirmation(isPresented: $showRebootConfirmation, settings: viewModel.helper)
    .navigationDestination(isPresented: $showsCompare) {
      RepeaterCompareView(primaryPublicKey: session.publicKey)
    }
    .toolbar {
      if session.isAdmin {
        ToolbarItem(placement: .topBarTrailing) {
          NodeDashboardMenu(
            session: session,
            contact: routeContact,
            refreshMinutes: $refreshMinutes,
            onCompare: { showsCompare = true },
            onLogout: { forget in Task { await logOut(forget: forget) } }
          )
        }
      }
    }
    // After a reboot or power-off the page's session is gone: the banner's Reconnect logs in
    // again (automatically, when the node is set to) and the same page carries on.
    .sheet(isPresented: $showsReconnect) {
      if let routeContact {
        NodeAuthenticationSheet(contact: routeContact, role: .repeater) { _ in
          viewModel.helper.markLive()
          Task { await statusViewModel.requestStatus(for: session) }
        }
        .presentationSizing(.page)
      }
    }
    .errorAlert($logoutError)
    // Advert, Sync Time and Reboot from the controls row report here; a settings sheet shows its
    // own while it's open, so this one stands aside then.
    .nodeSettingsSuccessAlert(
      settings: viewModel.helper,
      isPresented: Binding(
        get: { viewModel.helper.showSuccessAlert && openSettingsPage == nil },
        set: { if !$0 { viewModel.helper.showSuccessAlert = false } }
      )
    )
    .onChange(of: refreshMinutes) { _, minutes in
      RemoteNodePreferences.setAutoRefreshMinutes(minutes, for: session.publicKey)
    }
    // The latest release's build, for the Device card's "Update available", when the board is one
    // the app can name and the last fetch is a day old.
    .task(id: viewModel.helper.nordicUpdateTarget?.displayName) {
      guard let target = viewModel.helper.nordicUpdateTarget, LatestFirmwareBuildCache.isStale() else { return }
      if let release = try? await Releases().latest(assetPattern: target.assetPattern, boardName: target.displayName) {
        LatestFirmwareBuildCache.record(build: release.buildNumber)
      }
    }
    .sheet(item: $openSettingsPage) { page in
      settingsSheet(page)
    }
  }

  /// The page with its sheets, alerts and lifecycle: split from `body` so the compiler keeps up.
  private var dashboard: some View {
    page
    // what this visit read, kept for the next one's cards (merged: a value not read keeps the last)
    .onChange(of: freshCardSignature) { _, _ in
      NodeCardCache.save(freshCardEntry, publicKey: session.publicKey)
    }
    .task {
      if cardCache == nil { cardCache = NodeCardCache.load(publicKey: session.publicKey) }
      refreshMinutes = RemoteNodePreferences.autoRefreshMinutes(for: session.publicKey)
      configureTelemetryIfNeeded()
      await viewModel.configure(
        repeaterAdminService: { appState.services?.repeaterAdminService },
        session: session
      )
      // A reboot or power-off ends the session on the node; the store says so too.
      viewModel.helper.onSessionQuiet = { id in
        await appState.services?.remoteNodeService.disconnect(sessionID: id)
      }
      if let send = viewModel.makeNodeCLISendClosure(session: session) {
        cliViewModel.configure(sessionName: session.name, historyKey: session.publicKey, sendRawCommand: send)
      }
      // Names for the Dashboard's route row and neighbours, which resolve hop hashes and key
      // prefixes against these.
      if let radioID = appState.connectedDevice?.radioID,
         let dataStore = appState.services?.dataStore {
        contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
        discoveredNodes = await (try? dataStore.fetchDiscoveredNodes(radioID: radioID)) ?? []
      }
      await refreshRouteContact()
      #if DEBUG
        // UI tests (`-uiTestNodeDashboard`): the mock radio can't log in, so the stored repeaters
        // stand in as this one's neighbours, to show the Neighbors page and a neighbour's page.
        if Self.isUITestDemo {
          statusViewModel.neighbors = contacts
            .filter { $0.type == .repeater && $0.publicKey != session.publicKey }
            .enumerated()
            .map { index, contact in
              Neighbour(
                publicKeyPrefix: contact.publicKey.prefix(6),
                secondsAgo: 60 * (index + 1),
                snr: 10.5 - Double(index) * 3.25
              )
            }
          statusViewModel.neighborsLoaded = true
          // A canned status reply for the store screenshots, after the real request has failed.
          try? await Task.sleep(for: .seconds(3))
          await statusViewModel.helper.handleStatusResponse(
            StatusResponse(
              publicKeyPrefix: statusViewModel.helper.session?.publicKeyPrefix ?? session.publicKeyPrefix,
              battery: 4120, txQueueLength: 0, noiseFloor: -112, lastRSSI: -71,
              packetsReceived: 18_432, packetsSent: 6_215, airtime: 9_850, uptime: 1_036_800,
              sentFlood: 4_102, sentDirect: 2_113, receivedFlood: 12_904, receivedDirect: 5_528,
              fullEvents: 0, lastSNR: 9.75, directDuplicates: 214, floodDuplicates: 3_380,
              rxAirtime: 41_200
            ),
            rxAirtimeSeconds: 41_200,
            receiveErrors: 12
          )
        }
      #endif
    }
    .task(id: appState.servicesVersion) {
      // A reconnect rebuilds the service container; late CLI replies are delivered to a handler
      // held by the admin service, so the new one needs it registered again.
      await viewModel.registerCLIHandler()
    }
    .onChange(of: appState.contactsVersion) {
      Task { await refreshRouteContact() }
    }
    // Hand the latest telemetry GPS fix to the settings so they can offer to apply it.
    .onChange(of: statusViewModel.helper.currentLocationFix) { _, fix in
      viewModel.helper.telemetryFix = fix
    }
    .onChange(of: openSettingsPage) { _, page in
      // Settings are cached after the first read; identity is read again on each opening so a
      // location set elsewhere shows up, unless the user has unsaved edits there.
      if page == .identity, viewModel.helper.identityLoaded, !viewModel.helper.identitySettingsModified {
        Task { await viewModel.helper.fetchIdentity() }
      }
      // The sensors carry the live GPS fix the location offers to apply; the Dashboard no longer reads them.
      if page == .identity, appState.connectionState == .ready,
         !statusViewModel.helper.telemetryLoaded, !statusViewModel.helper.isLoadingTelemetry {
        // Background priority: the sheet's own reads go first.
        Task {
          await RemoteRequestPriority.$current.withValue(.background) {
            await statusViewModel.requestTelemetry(for: session)
          }
        }
      }
    }
    .onAppear {
      // Teardown when the sheet closes; pushing a page over the Dashboard keeps it all running.
      lifetime.onEnd = { [statusViewModel, viewModel] in
        statusViewModel.stopDiscovery()
        Task {
          await statusViewModel.clearStatusHandlers()
          await viewModel.cleanup()
        }
      }
    }
  }

  // MARK: - Dashboard additions

  /// UI tests open this page on a session the mock radio never logged in to (`-uiTestNodeDashboard`).
  private static var isUITestDemo: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: "uiTestNodeDashboard")
    #else
      false
    #endif
  }

  /// Under the map: the rebooting banner while the node is quiet, the action tiles, and the
  /// invisible ticker that refreshes the status while the page is open.
  private var headerExtras: some View {
    VStack(spacing: CardStyle.spacing) {
      NodeRebootBanner(state: viewModel.helper.quietState) { showsReconnect = true }
      actionTiles
      NodeAutoRefreshTicker(
        minutes: refreshMinutes,
        isEnabled: appState.connectionState == .ready && !viewModel.helper.quietState.isQuiet
          && !statusViewModel.helper.isLoadingStatus
      ) {
        await statusViewModel.requestStatus(for: session)
      }
    }
    .animation(.default, value: viewModel.helper.quietState)
  }

  /// Logs out (the saved password stays), or logs out and forgets the node's password and
  /// session; either way the page closes.
  private func logOut(forget: Bool) async {
    guard let service = appState.services?.repeaterAdminService else { return }
    do {
      if forget {
        try await service.disconnect(sessionID: session.id, publicKey: session.publicKey)
        NodeAutoLogin.set(false, for: session.publicKey)
      } else {
        try await service.logout(sessionID: session.id)
      }
      dismiss()
    } catch {
      logoutError = error.userFacingMessage
    }
  }

  /// Send Advert, Neighbors, Sync Time, Reboot and the access list, under the map. Neighbors
  /// scans for the repeater's neighbours (a discovery) and opens their page to watch it.
  private var actionTiles: some View {
    NodeSettingsActionTiles(
      settings: viewModel.helper,
      session: session,
      showRebootConfirmation: $showRebootConfirmation,
      extraTileCount: 1
    ) {
      Button {
        if !Self.isUITestDemo {
          statusViewModel.startDiscovery(for: session)
        }
        neighborsPageRequest += 1
      } label: {
        NodeActionTile(
          NodeSectionPage.neighbors.title,
          systemImage: "point.3.connected.trianglepath.dotted",
          isBusy: statusViewModel.isDiscovering
        )
      }
      .radioDisabled(for: appState.connectionState)
      .accessibilityIdentifier("repeater.neighbors")
    }
  }

  /// Transmit power, tuning, switches and one-tap commands, one of the Dashboard's tools.
  private var controlsTile: some View {
    Button {
      showsControls = true
    } label: {
      NavigationTile(
        L10n.RemoteNodes.RemoteNodes.Controls.title,
        systemImage: "dial.medium.fill",
        color: .orange,
        detail: viewModel.helper.originalTxPower.map {
          TxPowerText.remoteDetail(setting: $0, antenna: viewModel.helper.txAntennaPower)
        } ?? L10n.RemoteNodes.RemoteNodes.Controls.subtitle
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("repeater.controls")
  }

  /// The node's command line, one of the Dashboard's tools.
  private var cliTile: some View {
    Button {
      showsCLI = true
    } label: {
      NavigationTile(
        L10n.RemoteNodes.RemoteNodes.Settings.Tab.cli,
        systemImage: "terminal",
        color: .gray,
        detail: L10n.Tools.Tools.Subtitle.cli
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("repeater.cli")
  }

  // MARK: - Settings

  /// The firmware and the clock in the header's strip (the user, 2026-11-09: they were cards of their
  /// own): the version, short ("Cairn 107"), opens Device Info (an orange glyph when an update is out);
  /// the clock is the repeater's time, read only.
  private func headerFacts(now: Date) -> [NodeHeaderFact] {
    let helper = viewModel.helper
    let version = helper.firmwareVersion ?? cardCache?.firmwareVersion
    let updateAvailable = FirmwareUpdateCheck.updateAvailable(
      installed: version, latestBuild: LatestFirmwareBuildCache.latestBuild()
    ) == true
    let clock = helper.clockCard(now: now) {}
    return [
      NodeHeaderFact(
        id: "firmware", label: L10n.RemoteNodes.RemoteNodes.Settings.firmware,
        value: version.map(FirmwareVersionParts.init).map(\.short) ?? NodeStatusViewModel.emDash,
        systemImage: updateAvailable ? "arrow.down.circle.fill" : "cpu",
        tint: updateAvailable ? .orange : .gray,
        isDim: helper.firmwareVersion == nil,
        action: { open(.deviceInfo) }
      ),
      // The time only (the user, 2026-11-09): Sync Time sets it, and says how far off it was.
      NodeHeaderFact(
        id: "clock", label: clock.title,
        value: clock.value,
        systemImage: "clock", tint: .teal,
        isDim: clock.valueTint != .primary || clock.isPending
      ),
    ]
  }

  /// Radio: the repeater's settings as a Dashboard card showing its values, opening its sheet. Identity,
  /// location and contact info open from the header's pencil; the firmware (Device Info) and the clock
  /// are in the header; Behavior is on the Controls page (the user, 2026-11-09).
  private var adminCards: [NodeDashboardCardItem] {
    // Device Info opens from the header's Firmware; the uptime is on the Battery card.
    [viewModel.helper.radioCard(cached: cardCache) { open(.radio) }]
  }

  /// Repeat mode, flood hops and regions as one card, at the top of the Controls page; it opens the
  /// Behavior sheet.
  private var behaviorCard: NodeDashboardCardItem {
    let fresh = viewModel.behaviorLoaded
    let repeating = viewModel.repeaterEnabled ?? (fresh ? nil : cardCache?.repeatEnabled)
    let floodMax = viewModel.floodMaxHops ?? (fresh ? nil : cardCache?.floodMaxHops)
    let behavior = NodeDashboardCardItem(
      id: "behavior",
      title: L10n.RemoteNodes.RemoteNodes.Settings.behavior,
      systemImage: "slider.horizontal.3",
      tint: .indigo,
      value: repeating.map {
        $0 ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off
      } ?? NodeStatusViewModel.emDash,
      // The last visit's value in grey until its sheet reads it.
      valueTint: fresh ? .primary : .secondary,
      note: repeating == nil ? nil : L10n.RemoteNodes.RemoteNodes.Settings.repeaterMode,
      details: [
        floodMax.map { L10n.RemoteNodes.RemoteNodes.Settings.maxFloodHops + " \($0)" },
        viewModel.regionsLoaded
          ? L10n.RemoteNodes.RemoteNodes.Settings.regions + " \(viewModel.regions.count)"
          : nil,
      ].compactMap(\.self),
      destination: .action { open(.behavior) },
      isPending: !fresh && viewModel.isLoadingBehavior
    )
    return behavior
  }

  /// Edits on a settings sheet that the repeater hasn't been sent, so Done asks before closing.
  private func hasUnsavedChanges(_ page: NodeSettingsPage) -> Bool {
    let helper = viewModel.helper
    switch page {
    case .radio: return helper.radioSettingsModified || helper.txPowerModified
    case .identity, .contactInfo: return helper.identitySettingsModified || helper.contactInfoSettingsModified
    case .behavior, .regions: return viewModel.behaviorSettingsModified || viewModel.hasUnsavedRegionChanges
    case .deviceInfo, .security, .roomAccess: return false
    }
  }

  private func discardChanges(_ page: NodeSettingsPage) {
    let helper = viewModel.helper
    switch page {
    case .radio: helper.revertRadioSettings()
    case .identity, .contactInfo:
      helper.revertIdentitySettings()
      helper.revertContactInfo()
    case .behavior, .regions:
      viewModel.revertBehaviorSettings()
      // Region changes already live on the repeater; only the save to flash is left undone.
      viewModel.hasUnsavedRegionChanges = false
    case .deviceInfo, .security, .roomAccess: break
    }
  }

  /// The one Apply a sheet's Done can run for its unsent edits; nil for the radio, whose Apply
  /// asks its own confirmation first.
  private func saveChanges(_ page: NodeSettingsPage) -> (() async -> Void)? {
    let helper = viewModel.helper
    switch page {
    case .radio: return nil
    case .identity, .contactInfo:
      return {
        if helper.identitySettingsModified { await helper.applyIdentitySettings() }
        if helper.contactInfoSettingsModified, !helper.isOwnerInfoTooLong { await helper.applyContactInfoSettings() }
      }
    case .behavior, .regions:
      return { [viewModel] in
        if viewModel.behaviorSettingsModified { await viewModel.applyBehaviorSettings() }
        if viewModel.hasUnsavedRegionChanges { await viewModel.saveRegions() }
      }
    case .deviceInfo, .security, .roomAccess: return nil
    }
  }

  /// This visit's card values as read from the node (nothing from the cache), for `NodeCardCache`.
  private var freshCardEntry: NodeCardCache.Entry {
    let h = viewModel.helper
    let neighbors = statusViewModel.neighborsLoaded ? statusViewModel.neighbors : nil
    let sensors = NodeDashboardCardItem.sensorSummary(statusViewModel.helper)
    return NodeCardCache.Entry(
      frequency: h.frequency, bandwidth: h.bandwidth, spreadingFactor: h.spreadingFactor,
      codingRate: h.codingRate, txPower: h.originalTxPower, repeatEnabled: viewModel.repeaterEnabled,
      floodMaxHops: viewModel.floodMaxHops, firmwareVersion: h.firmwareVersion,
      neighborCount: neighbors?.count, bestNeighborSNR: neighbors?.max { $0.snr < $1.snr }?.snr,
      temperature: sensors?.temperature, otherSensorCount: sensors?.others
    )
  }

  /// Changes when a fresh value lands (`savedAt` left out), so each arrival is saved once.
  private var freshCardSignature: String {
    let e = freshCardEntry
    return [e.frequency.map { "\($0)" }, e.txPower.map { "\($0)" }, e.repeatEnabled.map { "\($0)" },
            e.floodMaxHops.map { "\($0)" }, e.firmwareVersion, e.spreadingFactor.map { "\($0)" },
            e.neighborCount.map { "\($0)" }, e.bestNeighborSNR.map { "\($0)" }, e.temperature,
            e.otherSensorCount.map { "\($0)" }]
      .map { $0 ?? "-" }.joined(separator: "|")
  }

  private func open(_ page: NodeSettingsPage) {
    switch page {
    case .identity:
      viewModel.helper.expand(.identity)
      viewModel.helper.expand(.contactInfo)
    case .behavior:
      viewModel.isBehaviorExpanded = true
      viewModel.isRegionsExpanded = true
    case .deviceInfo:
      viewModel.helper.expand(.deviceInfo)
    default:
      viewModel.helper.expand(page)
    }
    openSettingsPage = page
  }

  /// What the Dashboard reads once the status is in, so the first request on the mesh is the status
  /// itself: the owner info (firmware, name, contact text), then only the card values no earlier
  /// visit left in `NodeCardCache`. A card shown from the cache is read when its sheet opens (the
  /// sheet's own load), and its reload reads it again. One at a time, so they don't crowd the link;
  /// each named on the page's progress line.
  private var cardSettingsSteps: [NodeLoadStep] {
    let viewModel = viewModel
    let helper = viewModel.helper
    let cached = cardCache
    let needsRadio = { !helper.radioLoaded && cached?.frequency == nil }
    let needsBehavior = { !viewModel.behaviorLoaded && cached?.repeatEnabled == nil }
    return [
      NodeLoadStep(
        title: NodeSettingsPage.deviceInfo.title,
        systemImage: NodeSettingsPage.deviceInfo.systemImage,
        color: NodeSettingsPage.deviceInfo.color
      ) {
        await viewModel.fetchNodeInfoIfNeeded()
      },
      // A Cairn repeater answers the Radio and Behavior cards (and the name and location) in one request;
      // the steps below then find them loaded and send nothing. Any other repeater: one quick unknown-setting
      // reply, remembered across visits (`CairnNodeConfigSupport`), and the single gets as before.
      NodeLoadStep(
        title: NodeSettingsPage.radio.title,
        systemImage: NodeSettingsPage.radio.systemImage,
        color: NodeSettingsPage.radio.color
      ) {
        guard needsRadio() || needsBehavior() else { return }
        if let config = await helper.fetchCairnConfig() { viewModel.applyCairnConfig(config) }
      },
      NodeLoadStep(
        title: NodeSettingsPage.radio.title,
        systemImage: NodeSettingsPage.radio.systemImage,
        color: NodeSettingsPage.radio.color
      ) {
        if needsRadio(), !helper.isLoadingRadio { await helper.fetchRadioSettings() }
      },
      // The firmware only when neither the owner info nor an earlier visit gave it (`ver`; it reads the
      // clock too). Otherwise the clock is read when the Device sheet opens.
      NodeLoadStep(
        title: NodeSettingsPage.deviceInfo.title,
        systemImage: NodeSettingsPage.deviceInfo.systemImage,
        color: NodeSettingsPage.deviceInfo.color
      ) {
        guard helper.firmwareVersion == nil, cached?.firmwareVersion == nil else { return }
        if !helper.deviceInfoLoaded, !helper.isLoadingDeviceInfo { await helper.fetchDeviceInfo() }
      },
      NodeLoadStep(
        title: NodeSettingsPage.behavior.title,
        systemImage: NodeSettingsPage.behavior.systemImage,
        color: NodeSettingsPage.behavior.color
      ) {
        if needsBehavior(), !viewModel.isLoadingBehavior { await viewModel.fetchBehaviorSettings() }
      },
      // The clock, set from the phone when it has drifted: a repeater's clock runs from its last
      // sync, and nothing else on the mesh corrects it.
      NodeLoadStep(
        title: L10n.RemoteNodes.RemoteNodes.Settings.syncTime,
        systemImage: "clock.arrow.2.circlepath",
        color: .blue
      ) {
        await helper.syncTimeIfDrifted()
      },
    ]
  }

  /// Whether a settings sheet's values are still being read from the repeater.
  private func isLoading(_ page: NodeSettingsPage) -> Bool {
    let helper = viewModel.helper
    switch page {
    case .radio: return helper.isLoadingRadio
    case .identity, .contactInfo: return helper.isLoadingIdentity || helper.isLoadingContactInfo
    case .behavior, .regions: return viewModel.isLoadingBehavior || viewModel.isLoadingRegions
    case .deviceInfo, .security: return helper.isLoadingDeviceInfo
    case .roomAccess: return false
    }
  }

  /// One setting in its sheet. The location picker, region sheet and success alert present from
  /// inside it: a sheet can't present over itself from the page below.
  private func settingsSheet(_ page: NodeSettingsPage) -> some View {
    NodeSettingsPageSheet(
      page: page,
      isLoading: isLoading(page),
      hasUnsavedChanges: hasUnsavedChanges(page),
      onDiscard: { discardChanges(page) },
      onSave: saveChanges(page),
      onDone: { openSettingsPage = nil }
    ) {
      Group {
        switch page {
        case .radio:
          makeRadioSettingsSection()
        case .identity, .contactInfo:
          makeIdentitySection()
          makeContactInfoSection()
        case .behavior, .regions:
          makeBehaviorSection()
          makeRegionsSection()
        case .deviceInfo, .security:
          makeDeviceInfoSection()
          makeSecuritySection()
        case .roomAccess:
          EmptyView()
        }
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button(L10n.RemoteNodes.RemoteNodes.Settings.done) {
            focusedField = nil
          }
        }
      }
    }
    .nodeSettingsSuccessAlert(settings: viewModel.helper, isPresented: $viewModel.helper.showSuccessAlert)
    .sheet(isPresented: $showingLocationPicker) {
      LocationPickerView(
        initialCoordinate: CLLocationCoordinate2D(
          latitude: viewModel.helper.latitude ?? 0,
          longitude: viewModel.helper.longitude ?? 0
        )
      ) { coordinate in
        viewModel.helper.setLocationFromPicker(
          latitude: coordinate.latitude,
          longitude: coordinate.longitude
        )
      }
    }
    .sheet(item: $addRegionParent) { parent in
      RepeaterAddRegionSheet(
        parent: parent,
        existingRegions: viewModel.regions,
        otherRegionNames: viewModel.unplacedRegionNames
      ) { name, parent in
        try await viewModel.addFloodAllowedRegion(name: name, parent: parent)
      }
    }
  }

  /// Configures the status view model once: its handlers populate only the status, telemetry and
  /// neighbours slots, leaving the settings view model's CLI handler intact for the CLI page.
  /// Guarded by `telemetryConfigured` so a second `.task` run never duplicates handler registration.
  private func configureTelemetryIfNeeded() {
    guard !telemetryConfigured else { return }
    telemetryConfigured = true
    statusViewModel.configure(
      repeaterAdminService: { appState.services?.repeaterAdminService },
      contactService: { appState.services?.contactService },
      nodeSnapshotService: { appState.services?.nodeSnapshotService },
      deviceHashSize: { appState.connectedDevice?.hashSize }
    )
    Task {
      await statusViewModel.registerHandlers()
      if let radioID = appState.connectedDevice?.radioID {
        await statusViewModel.helper.loadOCVSettings(publicKey: session.publicKey, radioID: radioID)
      }
      // The dashboard asks for status as it appears; this covers it appearing before the
      // configure above took effect. A request on its way, or one that already failed, makes this
      // a no-op.
      if statusViewModel.helper.shouldBackstopAutoLoadStatus(connectionState: appState.connectionState) {
        await statusViewModel.requestStatus(for: session)
      }
    }
  }

  // MARK: - Subviews

  private func makeDeviceInfoSection() -> some View {
    NodeDeviceInfoSection(settings: viewModel.helper)
  }

  private func makeRadioSettingsSection() -> some View {
    NodeRadioSettingsSection(
      settings: viewModel.helper,
      focusedField: $focusedField
    )
  }

  private func makeIdentitySection() -> some View {
    RemoteNodeIdentitySection(
      settings: viewModel.helper,
      focusedField: $focusedField,
      onPickLocation: { showingLocationPicker = true }
    )
  }

  private func makeContactInfoSection() -> some View {
    NodeContactInfoSection(settings: viewModel.helper, focusedField: $focusedField)
  }

  private func makeBehaviorSection() -> some View {
    BehaviorSection(viewModel: viewModel, focusedField: $focusedField)
  }

  private func makeRegionsSection() -> some View {
    RegionsSection(viewModel: viewModel, addRegionParent: $addRegionParent)
  }

  private func makeSecuritySection() -> some View {
    NodeSecuritySection(settings: viewModel.helper)
  }

  private func refreshRouteContact() async {
    guard let dataStore = appState.services?.dataStore else { return }
    if let updated = await (try? dataStore.fetchContact(
      radioID: session.radioID,
      publicKey: session.publicKey
    )).flatMap(\.self) {
      routeContact = updated
    }
  }
}

// MARK: - Behavior Section

private struct BehaviorSection: View {
  @Bindable var viewModel: RepeaterSettingsViewModel
  var focusedField: FocusState<NodeSettingsField?>.Binding

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.behavior,
      icon: "slider.horizontal.3",
      color: .indigo,
      isExpanded: $viewModel.isBehaviorExpanded,
      isLoaded: { viewModel.behaviorLoaded },
      isLoading: $viewModel.isLoadingBehavior,
      hasError: $viewModel.behaviorError,
      onLoad: { await viewModel.fetchBehaviorSettings() }
    ) {
      Toggle(L10n.RemoteNodes.RemoteNodes.Settings.repeaterMode, isOn: Binding(
        get: { viewModel.repeaterEnabled ?? false },
        set: { viewModel.repeaterEnabled = $0 }
      ))
      .disabled(viewModel.repeaterEnabled == nil)
      .accessibilityValue(
        viewModel.repeaterEnabled == nil
          ? (viewModel.isLoadingBehavior ? L10n.RemoteNodes.RemoteNodes.Settings.loading : L10n.RemoteNodes.RemoteNodes.Settings.failedToLoad)
          : (viewModel.repeaterEnabled == true ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off)
      )
      .overlay(alignment: .trailing) {
        if viewModel.repeaterEnabled == nil {
          SettingsLoadPlaceholder(isLoading: viewModel.isLoadingBehavior, hasError: viewModel.behaviorError)
            .padding(.trailing, 60)
            .accessibilityHidden(true)
        }
      }
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["repeat"])

      Divider()
      NodeIntegerFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.advertInterval0Hop,
        unit: L10n.RemoteNodes.RemoteNodes.Settings.min,
        value: viewModel.advertIntervalMinutes,
        onChange: { viewModel.advertIntervalMinutes = $0 },
        field: .advertInterval,
        focusedField: focusedField,
        isLoading: viewModel.isLoadingBehavior,
        hasError: viewModel.behaviorError,
        error: viewModel.advertIntervalError
      )
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["advert.interval"])

      Divider()
      NodeIntegerFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.advertIntervalFlood,
        unit: L10n.RemoteNodes.RemoteNodes.Settings.hrs,
        value: viewModel.floodAdvertIntervalHours,
        onChange: { viewModel.floodAdvertIntervalHours = $0 },
        field: .floodAdvertInterval,
        focusedField: focusedField,
        isLoading: viewModel.isLoadingBehavior,
        hasError: viewModel.behaviorError,
        error: viewModel.floodAdvertIntervalError
      )
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["flood.advert.interval"])

      Divider()
      NodeIntegerFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.maxFloodHops,
        unit: L10n.RemoteNodes.RemoteNodes.Settings.hops,
        value: viewModel.floodMaxHops,
        onChange: { viewModel.floodMaxHops = $0 },
        field: .floodMaxHops,
        focusedField: focusedField,
        isLoading: viewModel.isLoadingBehavior,
        hasError: viewModel.behaviorError,
        error: viewModel.floodMaxHopsError
      )
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["flood.max"])

      Divider()
      HStack(spacing: 12) {
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.Settings.applyBehaviorSettings,
          isLoading: viewModel.helper.isApplying,
          showSuccess: viewModel.behaviorApplySuccess,
          isActive: viewModel.behaviorSettingsModified,
          isDisabled: viewModel.helper.isApplying || viewModel.behaviorApplySuccess || !viewModel.behaviorSettingsModified
        ) {
          await viewModel.applyBehaviorSettings()
        }
        NodeRevertButton(isEnabled: viewModel.behaviorSettingsModified && !viewModel.helper.isApplying) {
          viewModel.revertBehaviorSettings()
        }
      }
    }
  }
}

// MARK: - Regions Section

private struct RegionsSection: View {
  @Bindable var viewModel: RepeaterSettingsViewModel
  @Binding var addRegionParent: RepeaterRegionEntry.Parent?
  @State private var blockedDeleteName: String?
  @State private var pendingDeletion: [RepeaterRegionEntry] = []
  @State private var isEditing = false
  @ScaledMetric(relativeTo: .body) private var indentPerLevel = RegionFloodToggleRow.Layout.indentPerLevel

  private var defaultScopePickerNames: [String] {
    var names = viewModel.regions.filter { !$0.isUnscoped }.map(\.name)
    if let current = viewModel.defaultScopeName,
       current != RepeaterRegionEntry.unscopedName,
       !current.isEmpty,
       !names.contains(current) {
      names.append(current)
    }
    return names
  }

  private func hasChildRegions(_ name: String) -> Bool {
    viewModel.regions.contains { $0.parentName == name }
  }

  private func canRequestDelete(_ region: RepeaterRegionEntry) -> Bool {
    !regionMutationsDisabled && !region.isUnscoped
  }

  /// Deleting is sent to the repeater as soon as it's confirmed, so a tap alone must not do it.
  private func requestDelete(_ regions: [RepeaterRegionEntry]) {
    let deletable = regions.filter(canRequestDelete)
    if let parent = deletable.first(where: { hasChildRegions($0.name) }) {
      blockedDeleteName = parent.name
      return
    }
    pendingDeletion = deletable
  }

  private var regionMutationsDisabled: Bool {
    !viewModel.regionsLoaded || viewModel.isLoadingRegions || viewModel.helper.isApplying
  }

  private var hasDeletableRegions: Bool {
    viewModel.regions.contains { !$0.isUnscoped }
  }

  @ViewBuilder
  private var defaultScopeRow: some View {
    if viewModel.defaultScopeLoaded {
      CardFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.Regions.defaultScope,
        hidesTitleFromAccessibility: true
      ) {
        Picker(
          L10n.RemoteNodes.RemoteNodes.Settings.Regions.defaultScope,
          selection: Binding(
            get: { viewModel.defaultScopeName },
            set: { newValue in
              Task { await viewModel.setDefaultScope(name: newValue) }
            }
          )
        ) {
          Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.noDefault)
            .tag(String?.none)
          ForEach(defaultScopePickerNames, id: \.self) { name in
            Text(name)
              .tag(Optional(name))
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(.primary)
        .disabled(regionMutationsDisabled)
      }
    } else {
      CardFieldRow(title: L10n.RemoteNodes.RemoteNodes.Settings.Regions.defaultScope) {
        if viewModel.isLoadingDefaultScope {
          ProgressView()
        } else {
          Button(L10n.RemoteNodes.RemoteNodes.Settings.Regions.loadDefaultScope) {
            Task { await viewModel.fetchDefaultScope() }
          }
          .buttonStyle(.borderless)
          .disabled(regionMutationsDisabled)
        }
      }
    }
  }

  /// One region's flood switch, indented under its parent, with Add Child and Delete in its
  /// context menu and, while editing, a delete button in front of it.
  private func regionRow(_ region: RepeaterRegionEntry) -> some View {
    HStack(spacing: 10) {
      if isEditing, canRequestDelete(region) {
        Button {
          requestDelete([region])
        } label: {
          Image(systemName: "minus.circle.fill")
            .font(.title3)
            .foregroundStyle(.white, .red)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.Localizable.Common.delete)
        .accessibilityValue(region.name)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }

      RegionFloodToggleRow(
        region: region,
        isOn: Binding(
          get: { region.floodAllowed },
          set: { _ in
            Task { await viewModel.toggleRegionFlood(name: region.name) }
          }
        ),
        hasChildren: hasChildRegions(region.name),
        indentPerLevel: indentPerLevel
      )
      .disabled(regionMutationsDisabled)
    }
    .frame(minHeight: 32)
    .contentShape(.contextMenuPreview, .rect(cornerRadius: 8))
    .contextMenu {
      if !regionMutationsDisabled {
        Button {
          addRegionParent = region.isUnscoped ? .unscoped : .named(region.name)
        } label: {
          Label(L10n.RemoteNodes.RemoteNodes.Settings.Regions.addChild, systemImage: "plus")
        }
      }

      if canRequestDelete(region) {
        Button(role: .destructive) {
          requestDelete([region])
        } label: {
          Label(L10n.Localizable.Common.delete, systemImage: "trash")
        }
      }
    }
  }

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.regions,
      icon: "globe",
      color: .green,
      info: L10n.RemoteNodes.RemoteNodes.Settings.regionsFooter,
      isExpanded: $viewModel.isRegionsExpanded,
      isLoaded: { viewModel.regionsLoaded },
      isLoading: $viewModel.isLoadingRegions,
      hasError: $viewModel.regionsError,
      onLoad: { await viewModel.fetchRegions() }
    ) {
      if viewModel.regionsLoaded, viewModel.regions.isEmpty {
        Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.empty)
          .foregroundStyle(.secondary)
      }

      if !viewModel.regions.isEmpty, viewModel.supportsRegionDefaultScope {
        defaultScopeRow

        Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.defaultScopeCaption)
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()
      }

      ForEach(viewModel.regions) { region in
        regionRow(region)
      }

      if !viewModel.regions.isEmpty {
        Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.floodToggleCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if viewModel.regionsLoaded, viewModel.regionsListPartial {
        Text(
          viewModel.isLoadingRegions
            ? L10n.RemoteNodes.RemoteNodes.Settings.Regions.readingMore
            : L10n.RemoteNodes.RemoteNodes.Settings.Regions.partialList
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Divider()
      HStack {
        Button(L10n.RemoteNodes.RemoteNodes.Settings.Regions.addRegion, systemImage: "plus") {
          addRegionParent = .unscoped
        }
        .buttonStyle(.borderless)
        .disabled(regionMutationsDisabled)

        Spacer()

        // Deleting a region is in each row's context menu; Edit shows a delete button on every
        // row for those who don't know to press and hold (and for a Mac pointer).
        if hasDeletableRegions {
          Button(isEditing ? L10n.Localizable.Common.done : L10n.Localizable.Common.edit) {
            withAnimation { isEditing.toggle() }
          }
          .buttonStyle(.borderless)
          .disabled(regionMutationsDisabled)
        }
      }

      if viewModel.regionsLoaded || viewModel.hasUnsavedRegionChanges {
        Divider()
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.Settings.Regions.saveToDevice,
          isLoading: viewModel.helper.isApplying,
          showSuccess: viewModel.regionsSaveSuccess,
          isActive: viewModel.hasUnsavedRegionChanges,
          isDisabled: viewModel.helper.isApplying || viewModel.regionsSaveSuccess || !viewModel.hasUnsavedRegionChanges
        ) {
          await viewModel.saveRegions()
        }
      }

      if let error = viewModel.helper.errorMessage {
        Text(error)
          .foregroundStyle(.orange)
          .font(.caption)
      }
    }
    .onChange(of: hasDeletableRegions) { _, hasAny in
      if !hasAny { isEditing = false }
    }
    .alert(
      L10n.RemoteNodes.RemoteNodes.Settings.Regions.cannotDelete(blockedDeleteName ?? ""),
      isPresented: Binding(
        get: { blockedDeleteName != nil },
        set: { if !$0 { blockedDeleteName = nil } }
      )
    ) {
      Button(L10n.RemoteNodes.RemoteNodes.Settings.ok, role: .cancel) {}
    } message: {
      Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.notEmpty)
    }
    .confirmationDialog(
      L10n.RemoteNodes.RemoteNodes.Settings.Regions.DeleteConfirm.title,
      isPresented: Binding(
        get: { !pendingDeletion.isEmpty },
        set: { if !$0 { pendingDeletion = [] } }
      ),
      titleVisibility: .visible,
      presenting: pendingDeletion
    ) { regions in
      Button(L10n.Localizable.Common.delete, role: .destructive) {
        Task {
          for region in regions {
            await viewModel.removeRegion(name: region.name)
          }
        }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: { regions in
      Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.DeleteConfirm.message(
        regions.map(\.name).formatted(.list(type: .and))
      ))
    }
  }
}

#Preview("Repeater Settings") {
  NavigationStack {
    RepeaterSettingsView(
      session: RemoteNodeSessionDTO(
        id: UUID(),
        radioID: UUID(),
        publicKey: Data(repeating: 0x42, count: 32),
        name: "Mountain Peak Repeater",
        role: .repeater,
        latitude: 37.7749,
        longitude: -122.4194,
        isConnected: true,
        permissionLevel: .admin
      )
    )
    .environment(\.appState, AppState())
  }
}

#Preview("Region hierarchy") {
  @Previewable @State var viewModel = {
    let vm = RepeaterSettingsViewModel()
    vm.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "gta", parentName: "on", depth: 2, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "downtown", parentName: "gta", depth: 3, floodAllowed: false, isHome: false),
      RepeaterRegionEntry(name: "midtown", parentName: "gta", depth: 3, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "can", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]
    vm.helper.setNodeInfo(firmwareVersion: "v1.15.0", name: nil, ownerInfo: nil)
    vm.defaultScopeName = "on"
    vm.defaultScopeLoaded = true
    vm.isRegionsExpanded = true
    return vm
  }()
  @Previewable @State var addRegionParent: RepeaterRegionEntry.Parent?

  CardForm {
    RegionsSection(viewModel: viewModel, addRegionParent: $addRegionParent)
  }
  .sheet(item: $addRegionParent) { parent in
    RepeaterAddRegionSheet(
      parent: parent,
      existingRegions: viewModel.regions
    ) { _, _ in }
  }
}
