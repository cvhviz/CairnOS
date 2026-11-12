#if canImport(CarPlay)
  import CarPlay
  import CoreLocation
  import CairnServices
  import MeshCore
  import OSLog

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "CarPlay")

  /// Runs the CarPlay screen for one connected car. Three tabs in the app's order (`AppTab`):
  /// Dashboard, Nodes, Comm, with the app's titles and symbols. The Dashboard is the app's Home for
  /// the car (the radio, its battery, messages, nodes, what the radio hears and GPS as full-width
  /// rows, then the tools worth a tap while driving), and pushes GPS, Spectrum, Scan for Nodes and
  /// Network Health as the app pushes its tools. Every row opens its tab, its screen or a read-only
  /// screen of its lines. It watches the app's state, rebuilds a `CarPlaySnapshot`, and touches
  /// the templates only when the snapshot changed and `CarPlayRefreshGate` allows. Rows and
  /// information screens on every car: iOS 26's cards are too small to read while driving
  /// (`CarPlayTemplates.usesCards`). A Comm row
  /// opens its conversation's screen (Read with Siri, Reply, then its recent messages); messages
  /// are read and sent through Siri, and the screen shows who wrote and when, never the text
  /// (`CarPlayFeatures.messagePreview`). Nothing here offers settings or setup: every screen but
  /// the advert choice is read-only.
  @MainActor
  final class CarPlayController: NSObject {
    private let interfaceController: CPInterfaceController
    private let launch: AppLaunchController
    private var sessionConfiguration: CPSessionConfiguration?

    private let dashboardTemplate: CPListTemplate
    private let nodesTemplate: CPListTemplate
    private let commTemplate: CPListTemplate
    /// Pushed from the Dashboard's Mesh and GPS rows: information screens (card lists only if
    /// `CarPlayTemplates.usesCards` comes back).
    private let spectrumTemplate: CPTemplate
    private let gpsTemplate: CPTemplate
    /// Pushed from the Dashboard's options, as the app pushes its tools from Home.
    private let scanTemplate: CPListTemplate
    private let healthTemplate: CPListTemplate
    private var tabBar: CPTabBarTemplate?
    private var tabs: [CarPlayTab] = []
    private var selectedTab: CarPlayTab = .dashboard

    /// The newest twelve conversations, without ever fetching message text.
    private let dashboard = HomeDashboardModel(conversationLimit: CarPlaySnapshotBuilder.maxListItems, loadsPreviews: false)
    /// The kind the Scan screen lists and last asked for. Probes themselves belong to the app's
    /// one `DiscoveryProbeCoordinator`, shared with the phone and Wardrive.
    private var scanFilter: NodeDiscoveryFilter = .repeaters
    /// The GPS tab's radio reads, the same model the app's GPS tab uses.
    private let gnss = GNSSDashboardModel()
    private var readings = DeviceReadingsModel()
    private var radioGPSState: DeviceGPSState?
    private var nodes: [CarPlayNodesSource.Node] = []
    /// The saved nodes by key, for a ping from a node's screen.
    private var contactsByKey: [Data: ContactDTO] = [:]
    /// The saved nodes' keys, for the Scan screen's New / Contacts split.
    private var contactKeys: Set<Data> = []
    /// Reads the Nodes tab's nodes as Home reads its cards (`HomeReloadCoalescer`): at most one
    /// read a second, none cut short, and the last change always read, so a steady advert burst
    /// can't hold the list back.
    private lazy var nodeReloads = HomeReloadCoalescer { [weak self] in
      await self?.readNodes()
    }
    private var pingTask: Task<Void, Never>?

    /// The node screen last opened, so a ping result or the heard path can be added to it.
    private struct NodeScreen {
      let publicKey: Data
      let template: CPInformationTemplate
      var info: [CarPlaySnapshot.InfoRow]
      var ping: CarPlaySnapshot.InfoRow?
    }

    private var nodeScreen: NodeScreen?

    /// A list pushed on the Nodes tab: one of its groups, Find's letter groups, or a letter group.
    private struct OpenNodeList {
      let list: CarPlaySnapshot.NodeList
      let template: CPListTemplate
    }

    /// The Nodes lists on the stack now, oldest first; each is rebuilt with the snapshot.
    private var openNodeLists: [OpenNodeList] = []

    /// A conversation's screen pushed on the Comm tab, with its newest messages (no text).
    private struct OpenConversation {
      let template: CPListTemplate
      var conversation: CarPlayInputs.OpenConversation
    }

    private var openConversation: OpenConversation?
    /// The conversation screen last dropped from `openConversation`. A tab switch also reports it
    /// disappearing while it stays pushed on Comm, so it is taken back when it shows again.
    private weak var leftConversationTemplate: CPListTemplate?
    private var leftConversation: CarPlayInputs.OpenConversation?
    /// Who wrote last in each listed conversation, and how the user's last message went.
    private var chatActivity: [UUID: CarPlayChatsSource.Activity] = [:]
    private var messageFactsTask: Task<Void, Never>?
    /// The message-event reload scheduled or running now; later events only mark it dirty, so
    /// steady traffic can't keep postponing it.
    private var messageFactsReloadID: UUID?
    private var messageFactsDirty = false
    private var messageEventsTask: Task<Void, Never>?
    /// The app state whose message events `messageEventsTask` follows.
    private var messageEventsStateID: ObjectIdentifier?
    private var healthReport: NetworkHealthReport?
    /// The Spectrum tab's readings; made in `init` once `self` exists, for its fetch.
    private var spectrumSource: CarPlaySpectrumSource!
    /// The phone's Spectrum chart and GPS map for the cards (iOS 26), drawn as pictures.
    private let pictures = CarPlayPictureSource()

    private var gate = CarPlayRefreshGate()
    private var applied: CarPlaySnapshot?
    private var advertNote: CarPlaySnapshot.AdvertNote = .idle
    private var isScanVisible = false
    private var isHealthVisible = false
    /// The Spectrum and GPS screens are on screen now (pushed, and not hidden by another tab or a
    /// screen over them): their readings run only then.
    private var isSpectrumShowing = false
    private var isGPSShowing = false
    /// The radio the Spectrum readings belong to.
    private var spectrumDeviceID: UUID?

    /// What the last observation saw, to tell an edge event (urgent) from routine data.
    private var lastEdgeKey: CarPlayEdgeKey?
    private var lastAppStateID: ObjectIdentifier?
    private var lastSourceKey: String?
    private var lastContactsVersion: Int?
    private var lastConversationsVersion: Int?
    /// The conversations the Comm rows' facts were last read for.
    private var factsLines: [HomeDashboardModel.ConversationLine] = []
    private var lastReadyDeviceID: UUID?

    private var trailingTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var readingsTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var advertNoteTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var gpsTask: Task<Void, Never>?
    /// The phone's live fix while the GPS tab is showing, for its speed: the app-wide location
    /// service only takes occasional one-shot fixes, which carry no useful speed.
    private let liveLocation = GPSLiveLocation(tracksHeading: false)
    private var isRunning = false

    /// Message events (a repeat heard, an ACK) arrive in bursts; one read of the Comm rows' facts
    /// per burst is enough.
    private static let reloadDebounce: Duration = .milliseconds(400)
    /// How often relative ages ("2m") are re-read while nothing else changes.
    private static let ageTick: Duration = .seconds(60)

    /// Whether the ticker runs at the scan pace; see `startAgeTicker()`.
    private var tickIsFast = false
    /// Set while a screen is being pushed, so a quick second tap can't push twice.
    private var isPushing = false

    init(interfaceController: CPInterfaceController, launch: AppLaunchController) {
      self.interfaceController = interfaceController
      self.launch = launch

      dashboardTemplate = CPListTemplate(title: CarPlayTabLayout.title(.dashboard), sections: [])
      nodesTemplate = CPListTemplate(title: CarPlayTabLayout.title(.nodes), sections: [])
      commTemplate = CPListTemplate(title: CarPlayTabLayout.title(.comm), sections: [])
      if CarPlayTemplates.usesCards {
        spectrumTemplate = CPListTemplate(title: CarPlayTabLayout.title(.spectrum), sections: [])
        gpsTemplate = CPListTemplate(title: CarPlayTabLayout.title(.gps), sections: [])
      } else {
        spectrumTemplate = CPInformationTemplate(title: CarPlayTabLayout.title(.spectrum), layout: .twoColumn, items: [], actions: [])
        gpsTemplate = CPInformationTemplate(title: CarPlayTabLayout.title(.gps), layout: .twoColumn, items: [], actions: [])
      }
      // CarPlay scans only: it keeps Scan for Nodes' name, not the phone's Scan & Traffic.
      scanTemplate = CPListTemplate(title: L10n.Tools.Tools.nodeDiscovery, sections: [])
      healthTemplate = CPListTemplate(title: ToolSelection.networkHealth.title, sections: [])

      super.init()

      // The GPS screen's one action: an advert, which carries the radio's position across the mesh.
      if let gpsInfo = gpsTemplate as? CPInformationTemplate {
        gpsInfo.actions = [CPTextButton(title: L10n.Tools.Tools.advert, textStyle: .normal) { [weak self] _ in
          self?.presentAdvertSheet()
        }]
      }

      spectrumSource = CarPlaySpectrumSource(fetch: { [weak self] in
        guard let self else { throw CancellationError() }
        let stats = try await readRadioStats()
        // The same reading feeds the phone's Spectrum model, whose packets give the traffic line.
        pictures.record(stats, at: Date())
        return stats
      })

      for tab in CarPlayTabLayout.tabs() {
        let template = template(for: tab)
        template.tabTitle = CarPlayTabLayout.title(tab)
        template.tabImage = CarPlayTemplates.symbol(CarPlayTabLayout.symbol(tab))
      }
    }

    private var appState: AppState { launch.appState }

    /// The car's traits: images are drawn at its scale and in its appearance, not the phone's.
    private var carTraits: UITraitCollection { interfaceController.carTraitCollection }

    /// Siri reads and sends every message in the car. Not observable, so it is re-read on each
    /// refresh (tab changes and the age ticker included).
    private var isSiriAvailable: Bool {
      SiriAuthorization.isAuthorized
    }

    /// The radio's statistics. Firmware known to lack the stats command (official MeshCore
    /// companion firmware before v1.11) is answered unsupported at once, as the radio would.
    private func readRadioStats() async throws -> RadioStats {
      guard let service = appState.services?.settingsService else { throw CancellationError() }
      if let refusal = CarPlaySpectrumSource.knownRefusal(for: appState.connectedDevice) {
        throw refusal
      }
      return try await service.getStatsRadio()
    }

    private func template(for tab: CarPlayTab) -> CPTemplate {
      switch tab {
      case .dashboard: dashboardTemplate
      case .nodes: nodesTemplate
      case .comm: commTemplate
      case .spectrum: spectrumTemplate
      case .gps: gpsTemplate
      }
    }

    private func tab(for template: CPTemplate) -> CarPlayTab? {
      tabs.first { self.template(for: $0) === template }
    }

    // MARK: - Lifecycle

    func start() {
      guard !isRunning else { return }
      isRunning = true
      // The Dashboard's Mesh row shows the Live Activity's readings.
      appState.liveActivityManager.isCarPlayShowingReadings = true
      CarPlayPictureImage.source = pictures
      pictures.onMapReady = { [weak self] in self?.requestRefresh() }
      sessionConfiguration = CPSessionConfiguration(delegate: self)
      interfaceController.delegate = self

      tabs = CarPlayTabLayout.tabs()
      let tabBar = CPTabBarTemplate(templates: tabs.map(template(for:)))
      tabBar.delegate = self
      self.tabBar = tabBar
      selectedTab = tabs.first ?? .dashboard

      if #available(iOS 18.4, *) {
        for template in [dashboardTemplate, commTemplate, nodesTemplate] {
          template.showsSpinnerWhileEmpty = !launch.hasLaunched
        }
      }
      apply(snapshot(now: .now))
      gate.didApply(at: .now)
      // Always with a completion: CarPlay raises an exception for a failed change without one.
      interfaceController.setRootTemplate(tabBar, animated: false) { ok, error in
        if !ok { logger.error("CarPlay root template failed: \(String(describing: error))") }
      }

      observe()
      followMessageEvents()
      reloadData()
      startAgeTicker()
    }

    func stop() {
      isRunning = false
      appState.liveActivityManager.isCarPlayShowingReadings = false
      spectrumSource.stop()
      pictures.stopPackets()
      pictures.stopMap()
      liveLocation.stop()
      for task in [trailingTask, loadTask, readingsTask, tickTask, advertNoteTask, healthTask, gpsTask, messageFactsTask, messageEventsTask] {
        task?.cancel()
      }
      messageEventsStateID = nil
      messageFactsReloadID = nil
      messageFactsDirty = false
      sessionConfiguration = nil
    }

    // MARK: - Observation

    /// Reads every value the screen shows inside an observation scope, then re-arms after each
    /// change. A change only schedules work; the gate decides when the car's screen redraws.
    private func observe() {
      guard isRunning else { return }
      withObservationTracking {
        _ = inputs(now: .now)
        _ = sourceKey
        _ = appState.contactsVersion
        _ = appState.conversationsVersion
        _ = readyDeviceID
      } onChange: { [weak self] in
        Task { @MainActor in
          guard let self, self.isRunning else { return }
          self.handleChange()
          self.observe()
        }
      }
    }

    private func handleChange() {
      if messageEventsStateID != ObjectIdentifier(appState) {
        followMessageEvents()
      }
      if sourceKey != lastSourceKey {
        reloadData()
      } else {
        if appState.contactsVersion != lastContactsVersion {
          reloadNodes()
        }
        if appState.conversationsVersion != lastConversationsVersion {
          reloadConversations()
        }
      }
      if dashboard.recentConversations != factsLines {
        // New conversation lines: who wrote last in each, read once the lines have landed.
        factsLines = dashboard.recentConversations
        reloadMessageFacts()
      }
      if readyDeviceID != lastReadyDeviceID {
        loadReadings()
        updateLiveSources()
      }
      requestRefresh()
    }

    /// The app state, radio and connection the loaded data is read for: a change reloads it all.
    private var sourceKey: String {
      "\(ObjectIdentifier(appState).hashValue)-\(appState.currentRadioID?.uuidString ?? "none")-\(appState.servicesVersion)"
    }

    /// The order chosen in the app's Nodes settings, which the car's Nodes list follows. With no
    /// choice made, nearest first while the phone or the radio knows where it is (the driver
    /// wants what's around), the app's own default otherwise.
    private var nodeSortOrder: NodeSortOrder {
      Self.nodeSortOrder(
        chosen: UserDefaults.standard.string(forKey: AppStorageKey.nodesSortOrder.rawValue).flatMap(NodeSortOrder.init),
        hasOrigin: appState.bestAvailableLocation != nil
      )
    }

    nonisolated static func nodeSortOrder(chosen: NodeSortOrder?, hasOrigin: Bool) -> NodeSortOrder {
      chosen ?? (hasOrigin ? .distance : .lastHeard)
    }

    private var readyDeviceID: UUID? {
      appState.isRadioReady ? appState.connectedDevice?.id : nil
    }

    /// Edge events (`CarPlayEdgeKey`, or a new app state) redraw within a second; anything else
    /// waits for the data interval, or the scan interval while a probe runs (`wantsFastTick`).
    private func requestRefresh(urgent forceUrgent: Bool = false) {
      let edge = CarPlaySnapshotBuilder.edgeKey(inputs(now: .now))
      let appStateID = ObjectIdentifier(appState)
      let urgent = forceUrgent || edge != lastEdgeKey || appStateID != lastAppStateID
      if isRunning, appStateID != lastAppStateID {
        // A new app state gathers the Dashboard's readings for the car too.
        appState.liveActivityManager.isCarPlayShowingReadings = true
      }
      lastEdgeKey = edge
      lastAppStateID = appStateID
      if isRunning, wantsFastTick != tickIsFast {
        startAgeTicker()
      }
      let interval = wantsFastTick ? CarPlayRefreshGate.scanInterval : CarPlayRefreshGate.dataInterval
      switch gate.request(at: .now, urgent: urgent, interval: interval) {
      case .applyNow:
        refreshNow()
      case let .schedule(after: delay):
        trailingTask?.cancel()
        trailingTask = Task { [weak self] in
          try? await Task.sleep(for: delay)
          guard !Task.isCancelled else { return }
          self?.refreshNow()
        }
      case .alreadyScheduled:
        break
      }
    }

    private func refreshNow() {
      guard isRunning else { return }
      gate.didApply(at: .now)
      apply(snapshot(now: .now))
    }

    // MARK: - Data

    /// Reads everything from the store for a new radio or connection, as Home's first load does:
    /// the Dashboard's cards, the Nodes tab, then the Comm rows' facts, and Network Health while
    /// it is open. Reads for the radio before are never shown.
    private func reloadData() {
      lastSourceKey = sourceKey
      lastContactsVersion = appState.contactsVersion
      lastConversationsVersion = appState.conversationsVersion
      let store = appState.offlineDataStore
      let radioID = appState.currentRadioID
      // A read still under way for the radio before is dropped, not shown.
      nodeReloads.reset()
      nodeReloads.request()
      loadTask?.cancel()
      loadTask = Task { [weak self] in
        guard let self else { return }
        await dashboard.load(dataStore: store, radioID: radioID)
        guard !Task.isCancelled else { return }
        await loadMessageFacts(store: store, radioID: radioID)
        guard !Task.isCancelled else { return }
        requestRefresh()
      }
    }

    /// The contacts or heard nodes changed (`contactsVersion`): the Dashboard's Nodes card and the
    /// Nodes tab re-read, each paced by its coalescer, so a steady advert burst still lands about
    /// once a second rather than waiting for the burst to end.
    private func reloadNodes() {
      lastContactsVersion = appState.contactsVersion
      dashboard.requestNodes(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
      nodeReloads.request()
    }

    /// The conversations changed (`conversationsVersion`): the Dashboard re-reads them, paced; the
    /// Comm rows' facts follow once the new lines land (`handleChange`).
    private func reloadConversations() {
      lastConversationsVersion = appState.conversationsVersion
      dashboard.requestConversations(dataStore: appState.offlineDataStore, radioID: appState.currentRadioID)
    }

    /// One read of the Nodes tab's saved and heard nodes; the returned step shows them, and
    /// Network Health's report re-reads with them while it is open.
    private func readNodes() async -> (@MainActor () -> Void)? {
      guard let store = appState.offlineDataStore, let radioID = appState.currentRadioID else {
        return { [weak self] in
          guard let self else { return }
          nodes = []
          contactsByKey = [:]
          contactKeys = []
          requestRefresh()
        }
      }
      let contacts = (try? await store.fetchContacts(radioID: radioID)) ?? []
      let heard = (try? await store.fetchDiscoveredNodes(radioID: radioID)) ?? []
      let keys = Set(contacts.map(\.publicKey))
      let read = CarPlayNodesSource.nodes(contacts: contacts, discovered: heard)
        + CarPlayNodesSource.heardNodes(discovered: heard, savedKeys: keys)
      let byKey = Dictionary(contacts.map { ($0.publicKey, $0) }, uniquingKeysWith: { first, _ in first })
      return { [weak self] in
        guard let self else { return }
        nodes = read
        contactsByKey = byKey
        contactKeys = keys
        if isHealthVisible {
          loadHealth()
        }
        requestRefresh()
      }
    }

    /// Every message event (one received, a repeat heard, an ACK, a failure) reloads the Comm
    /// rows' facts and the open conversation, coalesced; the gate then decides when the car
    /// redraws. A new message also bumps `conversationsVersion`, which re-reads the conversations.
    private func followMessageEvents() {
      messageEventsTask?.cancel()
      let appState = appState
      messageEventsStateID = ObjectIdentifier(appState)
      let events = appState.messageEventStream.events()
      messageEventsTask = Task { [weak self] in
        for await event in events {
          guard let self, isRunning else { return }
          if Self.changesMessageFacts(event) {
            reloadMessageFacts()
          }
        }
      }
    }

    /// Whether an event can change a Comm row or a message row (who wrote, when, delivery).
    private static func changesMessageFacts(_ event: MessageEvent) -> Bool {
      switch event {
      case .directMessageReceived, .channelMessageReceived, .roomMessageReceived, .messageStatusResolved,
           .messageResent, .messageFailed, .messageRetrying, .heardRepeatRecorded, .roomMessageStatusUpdated,
           .roomMessageFailed:
        true
      case .reactionReceived, .messagesRegionUpdated, .routingChanged:
        false
      }
    }

    /// At most one reload per debounce interval: events arriving while one is pending fold into
    /// it, or into one more right after it if they came while it was reading.
    private func reloadMessageFacts() {
      guard messageFactsReloadID == nil else {
        messageFactsDirty = true
        return
      }
      let id = UUID()
      messageFactsReloadID = id
      messageFactsDirty = false
      messageFactsTask?.cancel()
      messageFactsTask = Task { [weak self] in
        try? await Task.sleep(for: Self.reloadDebounce)
        guard let self, messageFactsReloadID == id else { return }
        if !Task.isCancelled {
          await loadMessageFacts(store: appState.offlineDataStore, radioID: appState.currentRadioID)
          if !Task.isCancelled {
            requestRefresh()
          }
        }
        guard messageFactsReloadID == id else { return }
        messageFactsReloadID = nil
        if messageFactsDirty, !Task.isCancelled, isRunning {
          reloadMessageFacts()
        }
      }
    }

    /// Replaces any pending message-event reload with a direct read (a conversation opening).
    private func loadMessageFactsNow() {
      messageFactsReloadID = nil
      messageFactsDirty = false
      messageFactsTask?.cancel()
      messageFactsTask = Task { [weak self] in
        guard let self else { return }
        await loadMessageFacts(store: appState.offlineDataStore, radioID: appState.currentRadioID)
        guard !Task.isCancelled else { return }
        requestRefresh(urgent: true)
      }
    }

    /// The listed conversations' row facts and the open conversation's newest messages, read the
    /// way the phone's chat view reads them, without their text.
    private func loadMessageFacts(store: PersistenceStore?, radioID: UUID?) async {
      let lines = dashboard.recentConversations
      factsLines = lines
      guard let store, let radioID else {
        chatActivity = [:]
        openConversation?.conversation.messages = []
        return
      }
      let activity = await CarPlayChatsSource.activities(for: lines, radioID: radioID, store: store)
      guard !Task.isCancelled else { return }
      chatActivity = activity
      guard let open = openConversation else { return }
      let line = lines.first { $0.id == open.conversation.line.id } ?? open.conversation.line
      let messages = await CarPlayChatsSource.messages(
        for: line,
        radioID: radioID,
        store: store,
        limit: CarPlaySnapshotBuilder.maxListItems
      )
      guard !Task.isCancelled, openConversation?.template === open.template else { return }
      openConversation?.conversation = .init(line: line, messages: messages)
    }

    /// One read of the radio's stats, sensors and GPS state each time a radio becomes ready, as
    /// Home does. The Dashboard never polls the radio; the battery monitor already does.
    private func loadReadings() {
      lastReadyDeviceID = readyDeviceID
      readingsTask?.cancel()
      guard readyDeviceID != nil else {
        radioGPSState = nil
        return
      }
      readingsTask = Task { [weak self] in
        guard let self else { return }
        let fresh = DeviceReadingsModel()
        await fresh.load(
          settingsService: appState.services?.settingsService,
          binaryProtocolService: appState.services?.binaryProtocolService
        )
        guard !Task.isCancelled else { return }
        readings = fresh
        radioGPSState = try? await appState.services?.settingsService.getDeviceGPSState()
        requestRefresh()
      }
    }

    private func loadHealth() {
      healthTask?.cancel()
      let store = appState.offlineDataStore
      let radioID = appState.currentRadioID
      healthTask = Task { [weak self] in
        let report = await NetworkHealthReport.load(dataStore: store, radioID: radioID)
        guard !Task.isCancelled, let self, isHealthVisible else { return }
        healthReport = report
        requestRefresh(urgent: true)
      }
    }

    /// Spectrum's readings and GPS's reads run only while their screen is showing and a radio is
    /// ready: one small request every data interval, nothing at all otherwise.
    private func updateLiveSources() {
      guard isRunning else { return }
      let device = readyDeviceID
      if spectrumDeviceID != device {
        spectrumSource.reset()
        pictures.resetSpectrum()
        spectrumDeviceID = device
      }
      if isSpectrumShowing, device != nil {
        spectrumSource.onUpdate = { [weak self] in self?.requestRefresh() }
        spectrumSource.start()
        pictures.followPackets(appState.services?.rxLogService)
      } else {
        spectrumSource.stop()
        pictures.stopPackets()
      }

      if isGPSShowing {
        liveLocation.start()
        guard gpsTask == nil else { return }
        gpsTask = Task { [weak self] in
          while !Task.isCancelled {
            guard let self else { return }
            await gnss.refresh(appState: appState, isActive: true)
            guard !Task.isCancelled else { return }
            requestRefresh()
            try? await Task.sleep(for: CarPlayRefreshGate.dataInterval)
          }
        }
      } else {
        liveLocation.stop()
        pictures.stopMap()
        gpsTask?.cancel()
        gpsTask = nil
      }
    }

    /// A probe's countdown ticks at the scan pace, whoever asked for it (the coordinator is shared
    /// and observed), and so does the wait for the next scan while the Scan screen shows it. A
    /// scan that only listens doesn't show in the car (`CarPlayScanBuilder.source`), so it doesn't.
    private var wantsFastTick: Bool {
      switch appState.probeCoordinator.state {
      case let .probing(probe), let .interrupted(probe): !probe.listensOnly
      case .coolingDown: isScanVisible
      case .idle: false
      }
    }

    /// Relative ages move on with the clock; re-reading is a no-op when nothing changed. While a
    /// probe runs it ticks at the scan pace. `requestRefresh` restarts it when the pace should
    /// change, so a probe never waits out a 60-second sleep.
    private func startAgeTicker() {
      tickTask?.cancel()
      tickIsFast = wantsFastTick
      tickTask = Task { [weak self] in
        while !Task.isCancelled {
          let fast = self?.tickIsFast ?? false
          try? await Task.sleep(for: fast ? CarPlayRefreshGate.scanInterval : Self.ageTick)
          guard !Task.isCancelled, let self else { return }
          tickIsFast = wantsFastTick
          requestRefresh()
        }
      }
    }

    // MARK: - Snapshot

    private func snapshot(now: Date) -> CarPlaySnapshot {
      let inputs = inputs(now: now, includesPictures: true)
      var snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
      CarPlayScanBuilder.complete(&snapshot, inputs: inputs, source: scanSource(now: now))
      return snapshot
    }

    /// The values the car shows. `includesPictures` adds what the Spectrum and GPS pictures are
    /// drawn from, only for a snapshot that will be applied: it moves their revisions on and may
    /// start a map snapshot, and it reads the chart's readings, which change with every packet
    /// and so stay out of the observation.
    private func inputs(now: Date, includesPictures: Bool = false) -> CarPlayInputs {
      var inputs = CarPlayInputs()
      inputs.isStarting = !launch.hasLaunched
      let appState = appState
      // The colours picked on the phone, for every avatar the builders draw.
      let pickedColors = appState.nodeAppearance.colorByLoweredName
      CarPlayAvatar.pickedColors.withLock { $0 = pickedColors }
      inputs.connectionState = appState.connectionState
      inputs.isRadioReady = appState.isRadioReady
      inputs.bluetooth = appState.connectionManager.bluetoothAvailability
      inputs.isSiriAvailable = isSiriAvailable
      inputs.advertNote = advertNote
      inputs.tabs = tabs.isEmpty ? CarPlayTab.allCases : tabs
      inputs.selectedTab = selectedTab
      inputs.listLimit = CarPlayTemplates.listLimit
      inputs.usesCards = CarPlayTemplates.usesCards

      if let device = appState.connectedDevice {
        let gpsStatus: RadioGPSStatus = appState.isRadioReady
          ? RadioGPSReading.status(receiver: radioGPSState, telemetry: RadioGPSReading.telemetryPosition(in: readings.sensors))
          : .unknown
        let isWiFi = appState.connectionManager.currentTransportType == .wifi
        inputs.radio = .init(
          name: device.nodeName,
          model: HomeStatusLines.modelLine(device),
          frequency: L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz(device.frequency)),
          presetName: HomeStatusLines.presetName(device, region: appState.regionSelection),
          txPower: appState.radioTxPower.map { L10n.Settings.DeviceInfo.txPowerFormat($0.formatted()) },
          clientRepeat: device.clientRepeat,
          isWiFi: isWiFi,
          transportDetail: HomeStatusLines.transportDetail(device, isWiFi: isWiFi),
          gpsStatus: GNSSStatus.radio(isConnected: true, status: gpsStatus),
          locationSharing: device.locationSharingSummary
        )
      } else if appState.connectionManager.lastConnectedDeviceID != nil {
        inputs.lastRadioName = appState.connectionManager.lastConnectedDeviceName
      }

      inputs.batteryPercent = appState.radioBatteryPercent
      inputs.batteryDetail = HomeStatusLines.batteryDetail(
        hasDevice: appState.connectedDevice != nil,
        voltage: appState.radioBatteryVoltage,
        isReady: appState.isRadioReady,
        batteryPresent: appState.batteryMonitor.deviceBattery?.isBatteryPresent
      )

      inputs.live = liveReadings(now: now)

      let origin = appState.bestAvailableLocation
      inputs.contactCount = dashboard.contactCount
      // Counted against the clock, as Home counts it, so a node heard a day ago drops out with
      // the age tick rather than at the next reload.
      inputs.newNodeCount = dashboard.newNodeCount(now: now)
      inputs.lastHeard = dashboard.lastHeard.map { node in
        .init(
          name: node.name,
          line: HomeStatusLines.lastHeardLine(lastHeard: node.lastHeard, coordinate: node.coordinate, origin: origin, now: now)
        )
      }
      // Home's count, from the store: the app badge reads 0 with badges off and leaves out the
      // kinds whose notifications are off, while the rows below still show their unread dots.
      inputs.unread = dashboard.unreadTotal
      inputs.conversations = dashboard.recentConversations
      inputs.chatActivity = chatActivity
      inputs.openConversation = openConversation?.conversation
      let groups = ContactGroupStore.shared.groups
      let heardKeys = appState.liveActivityManager.nodesHeardKeys(now: now)
      inputs.nodeCategories = CarPlayNodesSource.categories(nodes, heardKeys: heardKeys, origin: origin, now: now)
      inputs.nodeGroups = CarPlayNodesSource.groups(nodes, groups: groups, now: now)
      let openLists = openNodeLists.map(\.list)
      if openLists.contains(.find) {
        inputs.letterGroups = CarPlayNodesSource.letterGroups(nodes, now: now)
      }
      inputs.nodePages = openLists.filter { $0 != .find }.map { list in
        CarPlayNodesSource.page(
          list,
          nodes: nodes,
          groups: groups,
          sortOrder: nodeSortOrder,
          heardKeys: heardKeys,
          origin: origin,
          now: now,
          hashSize: appState.connectedDevice?.hashSize ?? 1,
          limit: inputs.listLimit
        )
      }
      inputs.scan = scanState(now: now)
      if isHealthVisible, let report = healthReport {
        inputs.health = healthState(report)
      }
      if isSpectrumShowing {
        // The traffic line's rate, count and peak come from the same model as the chart.
        inputs.spectrum = spectrumState(now: now, includesPictures: includesPictures && inputs.isRadioReady)
      }
      if isGPSShowing {
        inputs.gps = gpsState(now: now, includesPictures: includesPictures && inputs.usesCards)
      }
      return inputs
    }

    /// The Live Activity's readings, which it keeps for the car whether or not an activity runs:
    /// the last packet's signal, noise floor, packet rate, the radio's position and altitude (in
    /// the app's units), and the last message that would notify. The per-packet ones (signal,
    /// packet rate, and the nodes heard the Nodes groups read) are not observed, so a busy mesh never rebuilds
    /// the inputs per packet; they move on with the next refresh or the age tick.
    private func liveReadings(now: Date) -> CarPlayInputs.LiveReadings {
      let live = appState.liveActivityManager
      let signal = live.signal(now: now)
      let position = LiveActivityManager.positionTexts(advertised: appState.connectedDevice, fix: live.radioGPSFix)
      return .init(
        lastRSSI: signal?.rssi,
        lastSNR: signal?.snr,
        noiseFloor: live.lastNoiseFloor,
        packetsPerMinute: live.packetsPerMinute(now: now),
        positionText: position.position,
        altitudeText: position.altitude,
        lastMessage: live.lastMessage
      )
    }

    /// What `CarPlayInputs` carries of the probe: whether one listens (an edge for the refresh
    /// gate), for how long, and why the last failed. The rows come from `scanSource`.
    private func scanState(now: Date) -> CarPlayInputs.ScanState {
      let source = scanSource(now: now)
      var state = CarPlayInputs.ScanState()
      state.filter = source.filter
      if case let .probing(secondsLeft) = source.phase {
        state.isScanning = true
        state.secondsLeft = secondsLeft ?? 0
      }
      state.message = source.message
      state.canScan = source.canScan
      return state
    }

    /// The Scan screen's nodes and probe: the app's neighbour directory, which lists what the
    /// radio hears without a scan, and its one probe coordinator, so a probe asked on the phone or
    /// by Wardrive shows here as it runs, and its cooldown holds the car's controls too.
    private func scanSource(now: Date) -> CarPlayScanBuilder.Source {
      let coordinator = appState.probeCoordinator
      return CarPlayScanBuilder.source(
        directory: appState.neighbourDirectory,
        probeState: coordinator.state,
        lastSummary: coordinator.lastSummary,
        filter: scanFilter,
        contactKeys: contactKeys,
        nicknames: contactsByKey.mapValues(\.displayName),
        message: Self.carSafeMessage(coordinator.lastError, maxContacts: appState.connectedDevice.map { Int($0.maxContacts) }),
        isWardriving: coordinator.isWardriving,
        canScan: coordinator.isDiscoverSupported,
        now: now
      )
    }

    /// The scanner's error, but only in words safe for a car: a full node list is a condition the
    /// driver can understand, while any other error text might talk about the phone.
    nonisolated static func carSafeMessage(_ message: String?, maxContacts: Int?) -> String? {
      guard let message else { return nil }
      let fullList = [
        maxContacts.map { L10n.Contacts.Contacts.Add.Error.nodeListFull($0) },
        L10n.Contacts.Contacts.Add.Error.nodeListFullSimple,
      ]
      return fullList.contains(message) ? message : L10n.Localizable.CarPlay.Scan.failed
    }

    private func healthState(_ report: NetworkHealthReport) -> CarPlayInputs.HealthState {
      let node = { (node: NetworkHealthNode) in
        CarPlayInputs.HealthNode(
          id: node.id.uuidString,
          name: node.contact.displayName,
          issues: node.issues,
          lastHeard: node.lastHeard,
          isCritical: node.isCritical
        )
      }
      return .init(
        repeaterCount: report.nodes.count,
        attention: report.needsAttention.map(node),
        healthy: report.healthy.map(node)
      )
    }

    private func spectrumState(now: Date, includesPictures: Bool) -> CarPlayInputs.SpectrumState {
      let samples = spectrumSource.samples
      var state = CarPlayInputs.SpectrumState()
      state.noiseFloor = samples.noiseFloor
      state.isCalibrating = samples.isCalibrating
      state.statsUnsupported = spectrumSource.isUnsupported
      state.trend = samples.trend
      state.lastRSSI = samples.lastRSSI
      state.lastSNR = samples.lastSNR
      state.fillLastPacket(from: pictures.spectrum.latestPacket)
      state.airtime = samples.airtimeShare
      if let device = appState.connectedDevice {
        // The same channel figures the Spectrum tab works from.
        state.channel = LoRaChannelMath(
          frequencyHz: Double(device.frequency) * 1000,
          bandwidthHz: Double(device.bandwidth),
          spreadingFactor: Int(device.spreadingFactor),
          codingRate: Int(device.codingRate)
        )
        state.presetName = HomeStatusLines.presetName(device, region: appState.regionSelection)
        state.frequency = L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz(device.frequency))
        state.modulation = NodeRouteFormat.joined([
          HomeStatusLines.modulation(device),
          L10n.Tools.Tools.Spectrum.Header.codingRate(Int(device.codingRate)),
        ])
        // The header band's power and airtime, as the phone's Spectrum tab works them out.
        let power = RadioAmplifier.effectiveTxPower(reported: Int(device.txPower), model: device.manufacturerName)
        state.txPower = SpectrumFormat.dBm(Double(power))
        if let channel = state.channel {
          let milliseconds = (channel.timeOnAir(payloadBytes: LoRaChannelMath.airtimeHintBytes) * 1000).rounded()
          state.airtimePerPacket = L10n.Tools.Tools.Spectrum.Header.airtimeShort(milliseconds.formatted(.number.precision(.fractionLength(0))))
        }
      }
      if includesPictures {
        addSpectrumPictures(to: &state, now: now)
      }
      return state
    }

    /// The phone's NOW, FLOOR history and PKT/MIN from the readings the chart is drawn from,
    /// over the window the phone's Spectrum Settings picked, and the chart's revision.
    private func addSpectrumPictures(to state: inout CarPlayInputs.SpectrumState, now: Date) {
      pictures.channel = state.channel
      let model = pictures.spectrum
      let window = pictures.spectrumWindow
      let packets = model.packets.elements
      state.nowRSSI = model.latestPacket?.rssi ?? state.lastRSSI.map(Double.init)
      state.history = model.noise.elements.suffix(CarPlayCardBuilder.historyLength).map(\.dBm)
      let start = now.addingTimeInterval(-window.statsDuration)
      state.packetCount = packets.count - packets.firstIndex(atOrAfter: start, date: \.date)
      state.packetsPerMinute = SpectrumStats.packetsPerMinute(
        count: state.packetCount,
        window: window.statsDuration,
        observedSince: model.packetsObservedSince,
        now: now
      )
      state.peak = SpectrumStats.peak(packets, since: now.addingTimeInterval(-window.duration))
      state.chartRevision = pictures.spectrumRevision(now: now)
    }

    private func gpsState(now: Date, includesPictures: Bool) -> CarPlayInputs.GPSState {
      let device = appState.connectedDevice
      let location = appState.locationService
      let radioLocation = device.flatMap { device in
        device.hasLocation ? CLLocation(latitude: device.latitude, longitude: device.longitude) : nil
      }
      let latest = liveLocation.location ?? location.currentLocation
      let phoneStatus = GNSSStatus.phone(authorization: location.authorizationStatus, location: latest, now: now)
      let phoneFix = location.isAuthorized ? latest : nil
      var state = CarPlayInputs.GPSState(
        phoneStatus: phoneStatus == .searching ? L10n.Localizable.Home.Gps.noFix : phoneStatus.text,
        sharing: GNSSSettingsSummary.text(
          isConnected: device != nil,
          receiver: gnss.radio.receiver,
          advert: device?.advertLocationPolicyMode ?? .none,
          usesPhoneLocation: gnss.usesPhoneLocation
        )
      )
      if device != nil {
        state.radioStatus = GNSSStatus.radio(isConnected: true, status: gnss.radio.status)
        state.radioPosition = radioLocation.map { GPSFormat.coordinatePairText($0.coordinate) }
        state.source = RadioPositionSource.derive(
          status: gnss.radio.status,
          hasPosition: radioLocation != nil,
          sharesLocationPublicly: device?.sharesLocationPublicly ?? false,
          autoUpdate: gnss.autoUpdate,
          gpsSource: gnss.gpsSource
        ).text
      }
      if phoneStatus == .fix, let fix = latest {
        state.phoneHasFix = true
        state.phoneAccuracy = GNSSAccuracyGrade(meters: fix.horizontalAccuracy).text
      }
      state.readings = GNSSReadings.combined(radio: gnss.radio, radioPosition: radioLocation, phone: phoneFix, now: now)

      // The phone's device cards, compass and map.
      state.radioName = device?.nodeName
      state.radioLatitude = radioLocation?.coordinate.latitude
      state.radioLongitude = radioLocation?.coordinate.longitude
      state.advert = device?.advertLocationPolicyMode.gnssText
      state.phoneGNSSStatus = phoneStatus
      state.phoneLatitude = phoneFix?.coordinate.latitude
      state.phoneLongitude = phoneFix?.coordinate.longitude
      state.phoneAccuracyMeters = phoneFix.flatMap { $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil }
      state.isApproximate = location.isAuthorized && liveLocation.accuracyAuthorization == .reducedAccuracy
      if [.denied, .restricted].contains(location.authorizationStatus) {
        state.phoneNote = L10n.Map.Map.Gps.Denied.message
      }
      state.course = GNSSReadings.course(of: phoneFix)
      if let fix = phoneFix, fix.speed >= 0 {
        state.speed = GPSFormat.speedText(fix.speed >= GNSSReadings.movingSpeed ? fix.speed : 0)
      }
      if includesPictures, #available(iOS 26.0, *) {
        pictures.updateMap(
          radio: radioLocation?.coordinate,
          radioName: device?.nodeName,
          phone: phoneFix?.coordinate,
          nodes: nodes,
          size: CarPlayTemplates.panelImageSize,
          scale: carTraits.displayScale > 0 ? carTraits.displayScale : 2,
          now: now
        )
        state.mapRevision = pictures.mapRevision
      }
      return state
    }

    // MARK: - Apply

    private func apply(_ snapshot: CarPlaySnapshot) {
      let previous = applied
      applied = snapshot

      if #available(iOS 26.0, *), CarPlayTemplates.usesCards {
        if previous?.dashboard.header != snapshot.dashboard.header || previous?.dashboard.subtitle != snapshot.dashboard.subtitle {
          CarPlayTemplates.applyEmpty(.init(title: snapshot.dashboard.header, subtitle: snapshot.dashboard.subtitle), to: dashboardTemplate)
        }
        if previous?.dashboardTiles != snapshot.dashboardTiles {
          CarPlayTemplates.applyCards(snapshot.dashboardTiles, to: dashboardTemplate, traits: carTraits) { [weak self] row, index in
            self?.tileTapped(self?.applied?.dashboardTiles, row: row, index: index)
          }
        }
      } else if previous?.dashboard != snapshot.dashboard {
        CarPlayTemplates.applyDashboard(
          snapshot.dashboard,
          to: dashboardTemplate,
          traits: carTraits,
          onOption: { [weak self] kind in self?.perform(kind) },
          onCard: { [weak self] action in self?.cardTapped(action) }
        )
      }

      if previous?.chats.rows != snapshot.chats.rows {
        CarPlayTemplates.applyChats(snapshot.chats.rows, to: commTemplate, traits: carTraits) { [weak self] id in
          self?.showConversation(id)
        }
      }
      if previous?.chats.empty != snapshot.chats.empty {
        CarPlayTemplates.applyEmpty(snapshot.chats.empty, to: commTemplate)
      }
      if let open = openConversation, let page = snapshot.chats.page,
         previous?.chats.page != page || open.template.sections.isEmpty {
        CarPlayTemplates.applyConversation(page, to: open.template, traits: carTraits)
      }
      let showsBadge = snapshot.chats.unread > 0
      if commTemplate.showsTabBadge != showsBadge, let tabBar {
        commTemplate.showsTabBadge = showsBadge
        tabBar.updateTemplates(tabBar.templates)
      }

      applyNodes(snapshot.nodes, previous: previous?.nodes)

      if CarPlayFeatures.radioTools, previous?.scan != snapshot.scan {
        CarPlayTemplates.applyScan(
          snapshot.scan,
          to: scanTemplate,
          traits: carTraits,
          onControl: { [weak self] filter, stops in self?.scanControlTapped(filter, stops: stops) },
          onResult: { [weak self] key in self?.showScanResult(key) }
        )
      }

      if let health = snapshot.health, previous?.health != health {
        if #available(iOS 18.4, *) {
          healthTemplate.showsSpinnerWhileEmpty = false
        }
        CarPlayTemplates.applyHealth(health, to: healthTemplate, traits: carTraits) { [weak self] id in
          self?.showHealthNode(id)
        }
      }
      if #available(iOS 26.0, *), CarPlayTemplates.usesCards, let spectrumList = spectrumTemplate as? CPListTemplate, let gpsList = gpsTemplate as? CPListTemplate {
        if let tiles = snapshot.spectrumTiles, previous?.spectrumTiles != tiles {
          CarPlayTemplates.applyCards(tiles, to: spectrumList, traits: carTraits) { _, _ in }
        }
        if let tiles = snapshot.gpsTiles, previous?.gpsTiles != tiles {
          CarPlayTemplates.applyCards(tiles, to: gpsList, traits: carTraits) { _, _ in }
        }
      } else if let spectrumInfo = spectrumTemplate as? CPInformationTemplate, let gpsInfo = gpsTemplate as? CPInformationTemplate {
        if let rows = snapshot.spectrum, previous?.spectrum != rows {
          CarPlayTemplates.applyInfo(rows, to: spectrumInfo)
        }
        if let rows = snapshot.gps, previous?.gps != rows {
          CarPlayTemplates.applyInfo(rows, to: gpsInfo)
        }
      }

      if #available(iOS 18.4, *), launch.hasLaunched {
        dashboardTemplate.showsSpinnerWhileEmpty = false
        commTemplate.showsSpinnerWhileEmpty = false
        nodesTemplate.showsSpinnerWhileEmpty = false
      }
    }

    // MARK: - Actions

    private func perform(_ option: CarPlaySnapshot.OptionKind) {
      switch option {
      case .health: showHealth()
      case .advert: presentAdvertSheet()
      case .scan: showScan()
      }
    }

    /// A card opens its tab, as the app's card does, or its lines on a read-only screen.
    private func cardTapped(_ action: CarPlayTemplates.CardAction) {
      switch action {
      case let .openTab(tab):
        openTab(tab)
      case let .showInfo(kind):
        guard let card = applied?.dashboard.cards.first(where: { $0.kind == kind }), !card.info.isEmpty else { return }
        push(CarPlayTemplates.infoDetail(title: card.title, rows: card.info))
      }
    }

    /// A card on the Dashboard: it opens its tab, runs its tool, or shows its lines read-only.
    /// Looked up in the snapshot applied last, by row and index.
    private func tileTapped(_ sections: [CarPlaySnapshot.TileSection]?, row id: String, index: Int) {
      guard let row = sections?.flatMap(\.rows).first(where: { $0.id == id }), row.tiles.indices.contains(index) else { return }
      let tile = row.tiles[index]
      guard tile.isEnabled else { return }
      switch tile.action {
      case let .openTab(tab): openTab(tab)
      case let .option(kind): perform(kind)
      case let .info(title, rows): push(CarPlayTemplates.infoDetail(title: title, rows: rows))
      case let .nodes(category): showNodes(category: category)
      case let .nodeList(list): openNodeList(list)
      case nil: break
      }
    }

    /// The Nodes tab, for a Dashboard card that counts nodes, opened at the group the card counted
    /// (the nodes heard in the hour, or one of the tab's groups) over the tab's root; nil opens the
    /// root. Whatever the driver had pushed on the tab is popped first, so Back leads to the root.
    func showNodes(category: CarPlaySnapshot.NodeCategory?) {
      guard tabs.contains(.nodes) else { return }
      openTab(.nodes)
      // The tab bar alone: nothing pushed over the tabs.
      let showsRoot = interfaceController.templates.count <= 1
      let open = { [weak self] in
        guard let self, let category else { return }
        openNodeList(.category(category))
      }
      guard !showsRoot else {
        open()
        return
      }
      interfaceController.popToRootTemplate(animated: false) { [weak self] ok, error in
        if !ok { logger.error("CarPlay pop to Nodes failed: \(String(describing: error))") }
        Task { @MainActor in
          guard let self else { return }
          // The popped lists may not report disappearing before the next push.
          self.openNodeLists.removeAll { list in !self.interfaceController.templates.contains { $0 === list.template } }
          open()
        }
      }
    }

    /// Pushes a conversation's screen: its Siri rows at once, its messages once read, then kept
    /// current with the snapshot and the message events. Two deep with the tab bar.
    private func showConversation(_ id: UUID) {
      if let open = openConversation, !interfaceController.templates.contains(where: { $0 === open.template }) {
        // Popped without a disappearance reaching us (another tab's root, say).
        openConversation = nil
      }
      guard !isPushing, openConversation == nil,
            let line = dashboard.recentConversations.first(where: { $0.id == id }) else { return }
      let template = CPListTemplate(title: line.name, sections: [])
      openConversation = .init(template: template, conversation: .init(line: line))
      let pushed = push(template, onFailure: { [weak self] in
        guard self?.openConversation?.template === template else { return }
        self?.openConversation = nil
      })
      guard pushed else {
        openConversation = nil
        return
      }
      refreshNow()
      loadMessageFactsNow()
    }

    /// Pushes one of the Nodes tab's lists, filled at once from the nodes already loaded, then
    /// kept current with the snapshot like the tab's root.
    private func openNodeList(_ list: CarPlaySnapshot.NodeList) {
      guard !isPushing, !openNodeLists.contains(where: { $0.list == list }) else { return }
      let template = CPListTemplate(title: nodeListTitle(list), sections: [])
      openNodeLists.append(.init(list: list, template: template))
      let pushed = push(template, onFailure: { [weak self] in
        self?.openNodeLists.removeAll { $0.template === template }
      })
      guard pushed else {
        openNodeLists.removeAll { $0.template === template }
        return
      }
      // Built now rather than at the next refresh, so the list never opens empty.
      refreshNow()
    }

    private func nodeListTitle(_ list: CarPlaySnapshot.NodeList) -> String {
      switch list {
      case let .category(category): CarPlayNodesSource.title(category)
      case let .group(id): ContactGroupStore.shared.group(id: id)?.name ?? L10n.Contacts.Contacts.Groups.title
      case .find: L10n.Localizable.CarPlay.Nodes.find
      case let .letters(letters): CarPlayNodesSource.lettersTitle(letters)
      }
    }

    /// The Nodes tab's root and every list open on it, each touched only when its part of the
    /// snapshot changed. On iOS 26 the root and Find are condensed cards, several to a line, so
    /// every group shows at once; before, they are rows.
    private func applyNodes(_ nodes: CarPlaySnapshot.Nodes, previous: CarPlaySnapshot.Nodes?) {
      if previous?.emptyTitle != nodes.emptyTitle {
        CarPlayTemplates.applyEmpty(.init(title: nodes.emptyTitle, subtitle: nil), to: nodesTemplate)
      }
      if previous?.categories != nodes.categories || previous?.groups != nodes.groups {
        if #available(iOS 26.0, *), CarPlayTemplates.usesCards {
          CarPlayTemplates.applyCards(CarPlayNodesSource.tileSections(nodes), to: nodesTemplate, traits: carTraits) { [weak self] row, index in
            guard let self, let applied else { return }
            tileTapped(CarPlayNodesSource.tileSections(applied.nodes), row: row, index: index)
          }
        } else {
          CarPlayTemplates.applyNodeGroups(
            [.init(header: nil, rows: nodes.categories), .init(header: L10n.Contacts.Contacts.Groups.title, rows: nodes.groups)],
            to: nodesTemplate,
            traits: carTraits
          ) { [weak self] list in self?.openNodeList(list) }
        }
      }
      for open in openNodeLists {
        if open.list == .find {
          guard previous?.letterGroups != nodes.letterGroups || open.template.sections.isEmpty else { continue }
          CarPlayTemplates.applyEmpty(.init(title: nodes.emptyTitle, subtitle: nil), to: open.template)
          if #available(iOS 26.0, *), CarPlayTemplates.usesCards {
            CarPlayTemplates.applyCards(CarPlayNodesSource.letterTileSections(nodes), to: open.template, traits: carTraits) { [weak self] row, index in
              guard let self, let applied else { return }
              tileTapped(CarPlayNodesSource.letterTileSections(applied.nodes), row: row, index: index)
            }
          } else {
            CarPlayTemplates.applyNodeGroups([.init(header: nil, rows: nodes.letterGroups)], to: open.template, traits: carTraits) { [weak self] list in
              self?.openNodeList(list)
            }
          }
        } else if let page = nodes.pages.first(where: { $0.list == open.list }),
                  previous?.pages.first(where: { $0.list == open.list }) != page || open.template.sections.isEmpty {
          CarPlayTemplates.applyNodePage(page, to: open.template, traits: carTraits) { [weak self] key in
            self?.showNode(key)
          }
        }
      }
    }

    /// Selects a tab, or pushes GPS or Spectrum, which have no tab of their own.
    private func openTab(_ tab: CarPlayTab) {
      if CarPlayTabLayout.pushedScreens(radioTools: CarPlayFeatures.radioTools).contains(tab) {
        showScreen(tab)
        return
      }
      guard let tabBar, tabs.contains(tab) else { return }
      tabBar.select(template(for: tab))
      didSelect(tab)
    }

    /// Pushes the GPS or Spectrum screen over the Dashboard; its readings start as it shows.
    private func showScreen(_ tab: CarPlayTab) {
      let template = template(for: tab)
      let pushed = push(template, onFailure: { [weak self] in
        self?.screenShowing(tab, false)
      })
      guard pushed else { return }
      screenShowing(tab, true)
    }

    /// The GPS or Spectrum screen came into view or left it (popped, another tab chosen, or a
    /// screen pushed over it): its radio reads and location updates follow.
    private func screenShowing(_ tab: CarPlayTab, _ showing: Bool) {
      switch tab {
      case .spectrum:
        guard isSpectrumShowing != showing else { return }
        isSpectrumShowing = showing
      case .gps:
        guard isGPSShowing != showing else { return }
        isGPSShowing = showing
      default:
        return
      }
      updateLiveSources()
      requestRefresh(urgent: true)
    }

    private func didSelect(_ tab: CarPlayTab) {
      selectedTab = tab
      if tab == .comm {
        readoptConversationIfShown()
      }
      updateLiveSources()
      // A tab the driver just opened should be current, not up to ten seconds old. The ticker
      // restarts too, so a scan begun on the phone is picked up at the scan pace.
      startAgeTicker()
      requestRefresh(urgent: true)
    }

    /// Zero-hop or flood, the app's advert choice; the result shows on the Send Advert row.
    private func presentAdvertSheet() {
      guard appState.isRadioReady, advertNote != .sending else { return }
      present(CarPlayTemplates.advertSheet(
        onSend: { [weak self] flood in
          self?.dismissModal()
          self?.sendAdvert(flood: flood)
        },
        onCancel: { [weak self] in self?.dismissModal() }
      ))
    }

    private func sendAdvert(flood: Bool) {
      guard advertNote != .sending, appState.isRadioReady else { return }
      advertNoteTask?.cancel()
      advertNote = .sending
      requestRefresh(urgent: true)
      let appState = appState
      Task { [weak self] in
        do {
          // No location prompt: it would appear on the phone, which the driver must not need.
          try await appState.sendSelfAdvert(flood: flood, allowLocationPrompt: false)
          self?.noteAdvertResult(sent: true)
        } catch {
          logger.error("CarPlay advert failed (flood=\(flood)): \(error.localizedDescription)")
          self?.noteAdvertResult(sent: false)
        }
      }
    }

    /// "Advert sent" or "Advert not sent" rides on the Send Advert row for one data interval,
    /// where "Sending advert…" was, as the app's tile does; neither is a modal to dismiss.
    private func noteAdvertResult(sent: Bool) {
      advertNote = sent ? .sent : .failed
      requestRefresh(urgent: true)
      advertNoteTask?.cancel()
      advertNoteTask = Task { [weak self] in
        try? await Task.sleep(for: CarPlayRefreshGate.dataInterval)
        guard !Task.isCancelled, let self else { return }
        advertNote = .idle
        requestRefresh(urgent: true)
      }
    }

    /// Opens Scan for Nodes without scanning, as the app's page does: the list is what the radio
    /// already hears, and the driver taps a "Scan for…" row, the app's ring button, to ask for
    /// more. The gate is read again on opening, so a cooldown the phone or others nearby started
    /// shows at once.
    private func showScan() {
      guard CarPlayFeatures.radioTools, !isScanVisible else { return }
      let pushed = push(scanTemplate, onFailure: { [weak self] in
        self?.isScanVisible = false
      })
      guard pushed else { return }
      isScanVisible = true
      requestRefresh(urgent: true)
      let coordinator = appState.probeCoordinator
      Task { [weak self] in
        await coordinator.refreshCooldown()
        self?.requestRefresh(urgent: true)
      }
    }

    private func showHealth() {
      guard CarPlayFeatures.radioTools, !isHealthVisible else { return }
      healthReport = nil
      CarPlayTemplates.applyEmpty(.init(title: ToolSelection.networkHealth.title, subtitle: nil), to: healthTemplate)
      healthTemplate.updateSections([])
      if #available(iOS 18.4, *) {
        healthTemplate.showsSpinnerWhileEmpty = true
      }
      let pushed = push(healthTemplate, onFailure: { [weak self] in
        self?.isHealthVisible = false
        self?.healthTask?.cancel()
        self?.healthReport = nil
      })
      guard pushed else { return }
      isHealthVisible = true
      loadHealth()
    }

    private func showHealthNode(_ id: String) {
      guard let row = applied?.health?.sections.flatMap(\.rows).first(where: { $0.id == id }), !row.info.isEmpty else { return }
      push(CarPlayTemplates.infoDetail(title: row.name, rows: row.info, layout: .twoColumn))
    }

    private func scanControlTapped(_ filter: NodeDiscoveryFilter, stops: Bool) {
      if stops {
        // While Wardrive runs its one row stops it; the probe in its window finishes on its own
        let coordinator = appState.probeCoordinator
        if coordinator.isWardriving {
          coordinator.stopWardrive()
        } else {
          coordinator.stopProbe()
        }
        requestRefresh(urgent: true)
      } else {
        startScan(filter)
      }
    }

    /// Asks the app's probe coordinator for one probe of `filter`. Nothing goes on air while the
    /// gate says wait (the controls are off then too), and the coordinator never retries.
    private func startScan(_ filter: NodeDiscoveryFilter) {
      let coordinator = appState.probeCoordinator
      guard appState.isRadioReady, coordinator.isDiscoverSupported, coordinator.state == .idle else { return }
      scanFilter = filter
      requestRefresh(urgent: true)
      Task { [weak self] in
        await coordinator.requestProbe(filter: filter, origin: .carPlay)
        self?.requestRefresh(urgent: true)
      }
    }

    private func showNode(_ publicKey: Data) {
      guard let row = applied?.nodes.rows.first(where: { $0.publicKey == publicKey }) else { return }
      let template = CarPlayTemplates.nodeDetail(row)
      if let contact = contactsByKey[publicKey] {
        var actions = [CarPlayTemplates.pingButton { [weak self, weak template] button in
          guard let self, let template else { return }
          ping(publicKey, template: template, button: button)
        }]
        // A chat contact with a conversation: straight to it, Siri reading and sending there.
        if contact.type == .chat, dashboard.recentConversations.contains(where: { $0.id == contact.id }) {
          actions.append(CPTextButton(title: L10n.Localizable.CarPlay.Nodes.openChat, textStyle: .normal) { [weak self] _ in
            self?.showConversation(contact.id)
          })
        }
        template.actions = actions
      }
      nodeScreen = NodeScreen(publicKey: publicKey, template: template, info: row.info)
      push(template)
      loadHeard(publicKey, template: template)
    }

    /// Adds how the node was last heard (the path in, its signal) once the RX log is read, so the
    /// screen opens at once.
    private func loadHeard(_ publicKey: Data, template: CPInformationTemplate) {
      guard contactsByKey[publicKey] != nil, let node = nodes.first(where: { $0.publicKey == publicKey }),
            let rxLog = appState.services?.rxLogService else { return }
      let selfKey = appState.connectedDevice?.publicKey
      Task { [weak self] in
        let entries = await rxLog.recentEntries(since: .distantPast)
        guard let self, let entry = NodeHeardSignal.latest(in: entries, publicKey: publicKey, selfKey: selfKey) else { return }
        let heard = CarPlayNodesSource.Heard(
          // Relays named only by what this radio heard on the packet's channel, as the RX Log
          // list and the Traffic map name them: a saved repeater sharing a hash never names it
          path: NodeHeardSignal.heardPath(
            of: entry,
            in: appState.observationDirectory.index(for: entry),
            shorten: CarPlaySnapshotBuilder.glanceName
          ),
          snr: entry.snr,
          rssi: entry.rssi,
          date: entry.receivedAt
        )
        let row = CarPlayNodesSource.row(
          node,
          origin: appState.bestAvailableLocation,
          now: .now,
          hashSize: appState.connectedDevice?.hashSize ?? 1,
          heard: heard
        )
        guard nodeScreen?.template === template else { return }
        nodeScreen?.info = row.info
        showNodeScreen()
      }
    }

    /// A zero-hop ping from a node's screen, as its app page sends one. The result goes above the
    /// details; one ping at a time.
    private func ping(_ publicKey: Data, template: CPInformationTemplate, button: CPTextButton) {
      guard pingTask == nil, let contact = contactsByKey[publicKey] else { return }
      CarPlayTemplates.setPinging(button, true)
      pingTask = Task { [weak self] in
        guard let self else { return }
        let result = await PingHelper.zeroHopPing(contact: contact, appState: appState)
        pingTask = nil
        CarPlayTemplates.setPinging(button, false)
        guard nodeScreen?.template === template else { return }
        nodeScreen?.ping = CarPlayNodesSource.pingRow(result)
        showNodeScreen()
      }
    }

    /// The node screen's lines: the latest ping first, then the details.
    private func showNodeScreen() {
      guard let screen = nodeScreen else { return }
      screen.template.items = CarPlayTemplates.infoItems((screen.ping.map { [$0] } ?? []) + screen.info)
    }

    private func showScanResult(_ publicKey: Data) {
      guard let row = applied?.scan.results.first(where: { $0.publicKey == publicKey }) else { return }
      push(CarPlayTemplates.infoDetail(title: row.name, rows: row.info, layout: .twoColumn))
    }

    /// Pushes a screen: at most a tool under a tab and a detail under that, four deep with the
    /// tab bar, inside CarPlay's five. A quick second tap can't push twice. Returns false when the
    /// push was dropped (another is under way, or the screen is already up); `onFailure` runs if
    /// CarPlay then reports the push failed, so a caller can undo what it set up for the screen.
    @discardableResult
    private func push(_ template: CPTemplate, onFailure: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
      guard !isPushing, !interfaceController.templates.contains(where: { $0 === template }) else { return false }
      isPushing = true
      interfaceController.pushTemplate(template, animated: true) { [weak self] ok, error in
        if !ok { logger.error("CarPlay push failed: \(String(describing: error))") }
        Task { @MainActor in
          self?.isPushing = false
          if !ok { onFailure?() }
        }
      }
      return true
    }

    // MARK: - Presentation

    /// Every modal goes through here. CarPlay shows one modal at a time and raises an exception
    /// for a failed presentation without a completion, so a modal already up is dismissed first
    /// and every call passes a completion.
    private func present(_ template: CPTemplate) {
      let interfaceController = interfaceController
      let show = {
        interfaceController.presentTemplate(template, animated: true) { ok, error in
          if !ok { logger.error("CarPlay present failed: \(String(describing: error))") }
        }
      }
      guard interfaceController.presentedTemplate != nil else {
        show()
        return
      }
      interfaceController.dismissTemplate(animated: false) { _, _ in
        Task { @MainActor in show() }
      }
    }

    private func dismissModal() {
      guard interfaceController.presentedTemplate != nil else { return }
      interfaceController.dismissTemplate(animated: true) { ok, error in
        if !ok { logger.error("CarPlay dismiss failed: \(String(describing: error))") }
      }
    }

    /// A pushed tool screen was popped: Network Health forgets its report until it is opened
    /// again. A probe runs on, as it does when the phone's page is left: the coordinator owns it.
    /// A detail pushed on top keeps the screen below it.
    fileprivate func templateDisappeared(_ template: CPTemplate) {
      let isOnStack = interfaceController.templates.contains { $0 === template }
      if template === spectrumTemplate || template === gpsTemplate {
        screenShowing(template === spectrumTemplate ? .spectrum : .gps, false)
      } else if template === scanTemplate, !isOnStack {
        isScanVisible = false
        requestRefresh(urgent: true)
      } else if template === healthTemplate, !isOnStack {
        isHealthVisible = false
        healthTask?.cancel()
        healthReport = nil
      } else if !isOnStack, let open = openConversation, open.template === template {
        // The conversation's screen popped, or another tab hid it: its messages stop being read
        // until it shows again (`templateAppeared`).
        leftConversationTemplate = open.template
        leftConversation = open.conversation
        openConversation = nil
      } else if !isOnStack, openNodeLists.contains(where: { $0.template === template }) {
        // A Nodes list popped (Back, or another tab's root): it stops being rebuilt.
        openNodeLists.removeAll { list in !interfaceController.templates.contains { $0 === list.template } }
      }
    }
  }

  extension CarPlayController {
    /// A conversation screen left behind by a tab switch shows again: it is read and kept
    /// current once more, in place.
    fileprivate func templateAppeared(_ template: CPTemplate) {
      if template === spectrumTemplate || template === gpsTemplate {
        screenShowing(template === spectrumTemplate ? .spectrum : .gps, true)
        return
      }
      guard openConversation == nil, let left = leftConversationTemplate, left === template,
            let conversation = leftConversation else { return }
      readoptConversation(template: left, conversation: conversation)
    }

    /// The Comm tab was selected with its conversation screen still pushed, in case the car
    /// reports no appearance for it.
    fileprivate func readoptConversationIfShown() {
      guard openConversation == nil, let left = leftConversationTemplate, let conversation = leftConversation,
            interfaceController.templates.contains(where: { $0 === left }) else { return }
      readoptConversation(template: left, conversation: conversation)
    }

    private func readoptConversation(template: CPListTemplate, conversation: CarPlayInputs.OpenConversation) {
      leftConversationTemplate = nil
      leftConversation = nil
      openConversation = .init(template: template, conversation: conversation)
      refreshNow()
      loadMessageFactsNow()
    }
  }

  // MARK: - Delegates

  extension CarPlayController: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
      guard let tab = tab(for: selectedTemplate) else { return }
      didSelect(tab)
    }
  }

  extension CarPlayController: CPInterfaceControllerDelegate {
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
      templateDisappeared(aTemplate)
    }

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
      templateAppeared(aTemplate)
    }
  }

  extension CarPlayController: CPSessionConfigurationDelegate {
    func sessionConfiguration(
      _ sessionConfiguration: CPSessionConfiguration,
      limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
      // A limited car can allow fewer list rows or sections than before. Re-apply everything
      // against the current limits now rather than when the data next changes.
      logger.info("CarPlay limited interfaces changed: \(limitedUserInterfaces.rawValue)")
      guard isRunning else { return }
      applied = nil
      refreshNow()
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, contentStyleChanged contentStyle: CPContentStyle) {
      // Card tints are resolved for one appearance when a row is built, so a switch between day
      // and night rebuilds every row, even one whose values have not changed.
      logger.info("CarPlay content style changed: \(contentStyle.rawValue)")
      guard isRunning else { return }
      applied = nil
      refreshNow()
    }
  }
#endif
