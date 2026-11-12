import CoreLocation
import MapKit
import CairnServices
import MeshCore
import MessagingUI
import OSLog
import SwiftData
import SwiftUI

/// Simplified app-wide state management.
/// Composes ConnectionManager for connection lifecycle.
/// Handles only UI state, navigation, and notification wiring.
@Observable
@MainActor
final class AppState {
  // MARK: - Logging

  let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "AppState")

  // MARK: - Location

  /// App-wide location service for permission management
  let locationService = LocationService()

  /// Where the phone has been, for the Map tab's Trips page (`TripRecorder`): every fix the app gets
  /// passes through it.
  let tripRecorder: TripRecorder

  // MARK: - Offline Maps

  /// Offline map pack management and network monitoring
  let offlineMapService = OfflineMapService()

  // MARK: - Chat Drafts

  /// Disk-backed store for unsent chat-composer text. Recreated on
  /// before-first-unlock, but reads the same `UserDefaults` key, so the fresh
  /// instance recovers every persisted draft — no in-memory-lifetime dependency.
  let draftStore = DraftStore()

  /// Best available location for proximity-based disambiguation.
  var bestAvailableLocation: CLLocation? {
    if let phoneLocation = locationService.currentLocation {
      return phoneLocation
    }
    guard let device = connectedDevice, device.hasLocation else {
      return nil
    }
    return CLLocation(latitude: device.latitude, longitude: device.longitude)
  }

  /// The span a map shows around the user's position when it centers there: the location
  /// buttons' recenter, and Scan for Nodes' opening camera.
  nonisolated static let userLocationSpan: CLLocationDegrees = 0.02

  /// Centers the map on the best available location if one is known, otherwise requests one.
  /// Returns whether the camera was moved, so callers can drive their `isCenteredOnUser` flag.
  @discardableResult
  func centerOnUserLocation(
    span: CLLocationDegrees = AppState.userLocationSpan,
    setRegion: (MKCoordinateRegion) -> Void
  ) -> Bool {
    guard let location = bestAvailableLocation else {
      locationService.requestLocation()
      return false
    }
    setRegion(MKCoordinateRegion(
      center: location.coordinate,
      span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
    ))
    return true
  }

  // MARK: - Region preference

  @ObservationIgnored lazy var regionResolver = RegionResolver(location: locationService)

  /// Suppresses the `regionSelection` `didSet` write-back during cold-start load. Without
  /// this, `loadPersistedRegionSelection()` would re-encode the just-read JSON and rewrite
  /// the same bytes to UserDefaults on every launch.
  @ObservationIgnored private var suppressRegionPersist = false

  var regionSelection: RegionSelection? {
    didSet {
      guard !suppressRegionPersist else { return }
      persistRegionSelection()
    }
  }

  private func persistRegionSelection() {
    BackupUserDefaults.persistRegionSelection(regionSelection)
  }

  private func loadPersistedRegionSelection() {
    guard UserDefaults.standard.data(forKey: BackupUserDefaults.regionSelectionKey) != nil else { return }
    guard let decoded = BackupUserDefaults.loadRegionSelection() else {
      logger.warning("Failed to decode persisted region selection — clearing key")
      UserDefaults.standard.removeObject(forKey: BackupUserDefaults.regionSelectionKey)
      return
    }
    suppressRegionPersist = true
    defer { suppressRegionPersist = false }
    regionSelection = decoded
  }

  // MARK: - Connection (via ConnectionManager)

  /// The connection manager for device lifecycle
  let connectionManager: ConnectionManager
  let themeService: ThemeService
  private let bootstrapDebugLogBuffer: DebugLogBuffer

  /// Convenience accessors
  var connectionState: CairnServices.DeviceConnectionState {
    connectionManager.connectionState
  }

  var connectedDevice: DeviceDTO? {
    connectionManager.connectedDevice
  }

  var services: ServiceContainer? {
    connectionManager.services
  }

  /// The sync coordinator for data synchronization
  private(set) var syncCoordinator: SyncCoordinator?

  /// Incremented when services change (device switch, reconnect). Views observe this to reload.
  /// Every services change (connect, radio switch) also rebuilds `nodeAppearance`, whose name
  /// tables (`names`) name senders on every surface: a connect with no contact change must not
  /// leave them empty or naming the previous radio's contacts.
  private(set) var servicesVersion: Int = 0 {
    didSet { scheduleNodeAppearanceRefresh() }
  }

  /// Identity of the `ServiceContainer` the last `servicesVersion` bump was for,
  /// so redundant re-wires of the same container don't bump it again.
  private var lastBumpedServicesID: ObjectIdentifier?

  // MARK: - Offline Data Access

  /// Process-lifetime coordinator registry. Never nil'd after create — that
  /// would strand a bound view model via `bindCoordinator`'s guard.
  private(set) var chatCoordinatorRegistry: ChatCoordinatorRegistry?

  /// Bumped per channel slot when its occupant changes so an open
  /// `ChatConversationView` can leave and drop its composer.
  private(set) var channelSlotGenerations: [ChatConversationID: Int] = [:]

  /// Re-primes warm chat coordinators when messages arrive for closed
  /// conversations, so a reopen renders the fresh tail on the first frame.
  /// Built lazily by `ensureChatPrewarmRefresher()`.
  @ObservationIgnored var chatPrewarmRefresher: ChatPrewarmRefresher?

  /// Latest view-environment values seen by `chatEnvInputs`, reused when a
  /// background coordinator refresh must bake items with no view in hand.
  @ObservationIgnored var lastChatEnvSnapshot: ChatEnvSnapshot?

  /// Link-preview cache for the background prime paths (navigation prefetch,
  /// arrival-time refresh), which run without a view's environment. Instance
  /// identity is not load-bearing: durable preview state lives in the DB tier
  /// and the shared decoded caches, same as the `\.linkPreviewCache` default.
  @ObservationIgnored lazy var backgroundLinkPreviewCache: any LinkPreviewCaching = LinkPreviewCache()

  /// Measured chat message heights, kept across conversation views so a
  /// reopen skips measuring unchanged messages. Message IDs are unique
  /// across conversations, so one cache serves them all.
  @ObservationIgnored let chatSizeCache = TiledSizeCache<MessageItem>()

  /// Radio ID for data access - returns connected device's radio ID or last-connected radio ID for offline browsing
  var currentRadioID: UUID? {
    connectedDevice?.radioID ?? connectionManager.lastConnectedRadioID
  }

  /// Process-lifetime store after a radio has been paired. Nil until then
  /// so never-paired browsing stays empty.
  var offlineDataStore: PersistenceStore? {
    guard connectionManager.lastConnectedDeviceID != nil else { return nil }
    return connectionManager.persistenceStore
  }

  /// Sole lazy factory for the process-lifetime registry. Bound to the
  /// process store; `wireServicesIfConnected` neither creates nor rebinds it.
  func ensureChatCoordinatorRegistry() -> ChatCoordinatorRegistry? {
    if let chatCoordinatorRegistry { return chatCoordinatorRegistry }
    guard let store = offlineDataStore else { return nil }
    chatCoordinatorRegistry = ChatCoordinatorRegistry(dataStore: store)
    return chatCoordinatorRegistry
  }

  /// Incremented when contacts data changes. Views observe this to reload contact lists.
  var contactsVersion: Int = 0 {
    didSet { scheduleNodeAppearanceRefresh() }
  }

  /// Paces the event-driven `contactsVersion` and `conversationsVersion` bumps. Every advert and
  /// every stored message bumped them, and each bump restarts the lists' reloads; on a busy mesh
  /// that is many per second. At most one bump per interval, the last always delivered.
  let contactsBumpThrottle = VersionBumpThrottle(interval: .milliseconds(300))
  let conversationsBumpThrottle = VersionBumpThrottle(interval: .milliseconds(300))

  /// Discovered-node rows changed outside the advert path: a name Scan for Nodes resolved, nodes
  /// removed from Contacts > Heard. Bumps `contactsVersion` through the same throttle as adverts,
  /// so Home, Heard and CarPlay reload.
  func noteDiscoveredNodesChanged() {
    contactsBumpThrottle.request { [weak self] in self?.contactsVersion += 1 }
  }

  // MARK: - Neighbours and Scan for Nodes

  /// Decides when a discover request may go on air. One for the whole process: the limit it
  /// models lives in the repeaters, so it outlives service rebuilds and radio switches, and Scan
  /// for Nodes, CarPlay, Wardrive and Region discovery all share it.
  let discoverGate = DiscoverRequestGate()

  /// The connected radio's direct neighbours, re-bound to each connection's `NeighbourService`
  /// and kept, stale, across a disconnect.
  let neighbourDirectory = NeighbourDirectory()

  /// What this radio observed on its channel, the one index the RX Log list, the Traffic map and
  /// the traffic layer resolve packets against (`followObservations()` keeps it current).
  let observationDirectory = ObservationDirectory()
  /// The radio's channel, for every screen that shows it.
  let spectrumFeed = SpectrumFeed()

  /// Runs every discover probe (phone, CarPlay, Wardrive) through `discoverGate`. Lazy because it
  /// reads `locationService`.
  @ObservationIgnored lazy var probeCoordinator = DiscoveryProbeCoordinator(
    gate: discoverGate,
    location: .live(locationService)
  )

  // MARK: - Node avatars

  /// The photo and colour picked for each of the user's own radios.
  let radioAvatars = RadioAvatarStore()

  /// Every node's picked photo and colour on the current radio, for views that know only a key or
  /// a name.
  let nodeAppearance = NodeAppearanceIndex()

  /// The pending debounced rebuild of `nodeAppearance`.
  @ObservationIgnored private var nodeAppearanceRefreshTask: Task<Void, Never>?

  /// Rebuilds `nodeAppearance` once per burst of contact changes. Adverts bump `contactsVersion`
  /// in bursts, so a short debounce keeps this to one fetch per burst.
  func scheduleNodeAppearanceRefresh(delay: Duration = .milliseconds(300)) {
    nodeAppearanceRefreshTask?.cancel()
    nodeAppearanceRefreshTask = Task { @MainActor [weak self] in
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled else { return }
      await self?.refreshNodeAppearance()
    }
  }

  private func refreshNodeAppearance() async {
    let radioID = currentRadioID
    let selfName = connectedDevice?.nodeName
    let selfColor = radioAvatars.color(for: radioID)
    guard let radioID, let store = services?.dataStore ?? offlineDataStore else {
      nodeAppearance.rebuild(contacts: [], selfName: selfName, selfColor: selfColor)
      return
    }
    guard let contacts = try? await store.fetchContacts(radioID: radioID), !Task.isCancelled else { return }
    nodeAppearance.rebuild(contacts: contacts, selfName: selfName, selfColor: selfColor)
  }

  /// Saves the photo picked for one of the user's own radios, or removes it when `data` is nil.
  func setRadioAvatarPhoto(_ data: Data?, radioID: UUID) {
    radioAvatars.setPhoto(data, for: radioID)
  }

  /// Saves the colour picked for one of the user's own radios, or Automatic when nil.
  func setRadioAvatarColor(_ color: NodeAvatarColor?, radioID: UUID) {
    radioAvatars.setColor(color, for: radioID)
    scheduleNodeAppearanceRefresh(delay: .zero)
  }
  /// Adverts heard since the Nodes tab was last open: its tab badge and Home's Nodes card pill.
  /// Reset on a radio switch and a disconnect, so it never counts another session's adverts.
  var unseenAdvertCount = 0

  /// Incremented when conversations data changes. Views observe this to reload chat lists.
  private(set) var conversationsVersion: Int = 0

  /// Incremented when a remote-node session changes connection state.
  /// `RoomConversationView` observes this counter via `.onChange` to refresh
  /// its session DTO when re-authentication completes.
  private(set) var sessionStateChangeCount: Int = 0

  /// Called by `MessageEventDispatcher` when a remote-node session changes
  /// connection state. Bundles refreshing conversations and bumping the
  /// state-change counter so the dispatcher only needs one entry point.
  func handleSessionStateChange() {
    refreshConversations()
    sessionStateChangeCount += 1
  }

  /// Bumps `conversationsVersion` and drives
  /// `liveActivityManager.handleUnreadCountChanged`. Used by both the sync
  /// coordinator's data event stream and the session-state events
  /// (`RemoteNodeEvent.sessionStateChanged` / `RoomServerEvent.connectionRecovered`)
  /// to keep the conversations list and unread badge in lockstep.
  func refreshConversations() {
    conversationsVersion += 1
    Task { @MainActor [weak self] in
      guard let self, let services else { return }
      let total = await totalUnreadCount(from: services)
      await liveActivityManager.handleUnreadCountChanged(unreadCount: total)
      widgetSnapshotPublisher.unreadCount = total
      publishWidgetSnapshot()
    }
  }

  /// Bumps observer versions after a store-direct backup import so mounted
  /// tabs reload. Also re-reads `regionSelection`, which `init` loads once.
  func notifyDataRestored() {
    radioAvatars.reload()
    contactsVersion += 1
    conversationsVersion += 1
    loadPersistedRegionSelection()
    themeService.refreshFromUserDefaults()
    // Restore is refused while connected, so this cannot race a live session.
    // Empties entries; the registry stays so later opens mint fresh coordinators.
    chatCoordinatorRegistry?.clear()
    bumpServicesVersion()
  }

  /// Bumps `servicesVersion` so observing views re-run `performInitialLoad`.
  func bumpServicesVersion() {
    servicesVersion += 1
  }

  // MARK: - Connection UI State

  /// Connection UI state (status pills, sync activity, alerts, pairing)
  let connectionUI = ConnectionUIState()

  /// True while `confirmSystemPairingSetup` is in flight so sheet `onDismiss` does not cancel the flow.
  var isConfirmingSystemPairingSetup = false

  /// True while the foreground retry of `completeFreshPairing` is running, so a
  /// second `pickerUnavailable` is presented instead of rescheduled.
  var isFreshPairingForegroundRetry = false

  /// Battery monitoring (polling, thresholds, low-battery notifications)
  let batteryMonitor = BatteryMonitor()

  /// Live Activity lifecycle (start/update/stop on Lock Screen and Dynamic Island)
  let liveActivityManager = LiveActivityManager()
  /// Feeds the home-screen widget (see `publishWidgetSnapshot`).
  let widgetSnapshotPublisher = WidgetSnapshotPublisher()
  /// Packets heard and sent, for the activity line across the top of the app.
  let radioActivity = RadioActivity()

  /// Settings → Nodes → Remove Nodes, held here so a removal outlives the sheet it started from.
  let nodeRemoval: NodeRemovalModel

  /// Task chain that serializes BLE lifecycle transitions across scene-phase changes.
  /// Do not cancel this task externally -- cancelling breaks the serialization
  /// guarantee because Task<Void, Never>.value returns immediately on cancellation.
  var bleLifecycleTransitionTask: Task<Void, Never>?

  /// Fallback task that re-runs foreground recovery shortly after activation when the
  /// app is still disconnected. Covers edge cases where scene-phase callbacks are missed.
  var activeRecoveryFallbackTask: Task<Void, Never>?
  /// Re-reads the radio's self info (its stored position) once a minute while the app is open,
  /// so the maps follow a radio whose own GPS keeps moving it. See `startRadioPositionRefresh()`.
  var radioPositionRefreshTask: Task<Void, Never>?

  /// Task consuming SettingsService event stream, canceled on disconnect
  var settingsEventsTask: Task<Void, Never>?

  /// Task consuming SyncCoordinator's data event stream, canceled on disconnect
  var syncDataEventsTask: Task<Void, Never>?

  /// Task consuming AdvertisementService's event stream, canceled on disconnect
  var advertisementEventsTask: Task<Void, Never>?

  /// Task consuming RxLogService's entry stream for Live Activity freshness, canceled on disconnect
  var rxLogEventsTask: Task<Void, Never>?

  /// Task watching the session for packets the radio sends, for the activity line; canceled on
  /// disconnect
  var sentPacketEventsTask: Task<Void, Never>?

  #if DEBUG
    /// Optional test-only hooks for deterministic lifecycle ordering tests.
    var bleEnterBackgroundOverride: (@MainActor () async -> Void)?
    var bleBecomeActiveOverride: (@MainActor () async -> Void)?
  #endif

  // MARK: - Onboarding State

  /// Onboarding state (completion flag, navigation path)
  let onboarding = OnboardingState()

  // MARK: - What's New

  /// What's New presentation gate (device-local baseline, pending release)
  let whatsNew = WhatsNewState()

  // MARK: - Navigation State

  /// Navigation coordinator (tab selection, pending targets, cross-tab navigation)
  let navigation = NavigationCoordinator()

  // MARK: - UI Coordination

  /// AsyncStream-based distribution of `MessageEvent` to chat and room
  /// consumers. Fed by the service event streams wired in `wireMessageEvents`.
  let messageEventStream = MessageEventStream()

  /// Routes service event streams to `messageEventStream` and the
  /// session-state counter. Lazy because it captures `self` and
  /// `messageEventStream`.
  @ObservationIgnored
  lazy var messageEventDispatcher = MessageEventDispatcher(
    appState: self,
    stream: messageEventStream
  )

  // MARK: - CLI Tool

  /// Persistent CLI tool view model (survives tab switches, reset on device disconnect)
  var cliToolViewModel: CLIToolViewModel?

  /// Tracks the device ID for CLI state - reset CLI when device changes
  private var lastConnectedDeviceIDForCLI: UUID?

  // MARK: - Status Pill

  /// The current status pill state, computed from all relevant conditions
  /// Priority: failed > syncing > ready > connecting > disconnected > hidden
  var statusPillState: StatusPillState {
    if connectionUI.syncFailedPillVisible {
      return .failed(message: L10n.Localizable.StatusPill.syncFailed)
    }
    if connectionUI.syncActivityCount > 0 || connectionState == .syncing {
      return .syncing
    }
    if connectionUI.showReadyToast {
      return .ready
    }
    if connectionState == .connecting {
      return .connecting
    }
    if connectionUI.disconnectedPillVisible {
      return .disconnected
    }
    return .hidden
  }

  /// Whether Settings startup reads should run right now.
  var canRunSettingsStartupReads: Bool {
    if connectionState == .ready { return true }
    return connectionState == .connected && connectionUI.currentSyncPhase == .messages
  }

  // MARK: - Initialization

  init(
    modelContainer: ModelContainer,
    isPlaceholder: Bool = false,
    defaults: UserDefaults = .standard,
    injectedConnectionManager: ConnectionManager? = nil
  ) {
    themeService = ThemeService(defaults: defaults)

    connectionManager = injectedConnectionManager
      ?? ConnectionManager(modelContainer: modelContainer, defaults: defaults)
    tripRecorder = TripRecorder(store: connectionManager.persistenceStore)
    nodeRemoval = NodeRemovalModel(remover: connectionManager)
    connectionUI.hasSystemPairingRegistry = connectionManager.hasSystemPairingRegistry

    let bootstrapBuffer = DebugLogBuffer(dataStore: connectionManager.persistenceStore)
    bootstrapDebugLogBuffer = bootstrapBuffer
    // The inert environment-default placeholder must not publish the process-global buffer,
    // or it would displace the live one and route logs into a discarded in-memory store.
    if !isPlaceholder {
      DebugLogBuffer.shared = bootstrapBuffer
    }

    // Provide LiveActivityManager with current radio connection state so
    // its restart/recovery/stale paths consult ground truth instead of
    // the LA's last cached `isConnected`. Read from connectionState (a
    // transport-link predicate) rather than connectedDevice: during iOS
    // auto-reconnect connectedDevice is intentionally retained while the
    // transport link is down, and using identity as a liveness signal
    // would resurrect a "Connected" LA mid-reconnect.
    // The radio's trip recorder (Record Trip, the trips on its card) talks to the connected radio.
    tripRecorder.connection = { [weak self] in
      guard let self, self.connectionState.isConnected, let device = self.connectedDevice,
            let session = self.services?.session else { return nil }
      return (session, device)
    }

    liveActivityManager.connectionStateProvider = { [weak self] in
      self?.connectionState.isConnected ?? false
    }

    // Live radioID for the stale-activity self-heal. Gated on the same
    // transport-link predicate as `connectionStateProvider`, so it returns a
    // radioID only while genuinely connected, never mid-reconnect.
    liveActivityManager.connectedRadioIDProvider = { [weak self] in
      guard let self, self.connectionState.isConnected else { return nil }
      return self.connectedDevice?.radioID
    }

    // Wire app state provider for incremental sync support
    connectionManager.appStateProvider = AppStateProviderImpl()

    // "Cairn may not be receiving" / "Bluetooth is off": a backgrounded app that stops hearing from
    // its radio (closed by the user, Bluetooth off, phone restarted) can't store messages, so the
    // user is told while the radio still holds them.
    connectionManager.listeningReminder = ListeningReminder(strings: NotificationStringProviderImpl())

    // A Bluetooth wake gives the app about ten seconds; a session rebuild and its drain, or a
    // resync, get a background task so suspension doesn't cut them off halfway.
    connectionManager.beginBackgroundRuntime = { name in
      let assertion = BackgroundTaskAssertion(name: name)
      return { assertion.end() }
    }

    // Wire connection ready callback - automatically updates UI when connection completes
    connectionManager.onConnectionReady = { [weak self] in
      await self?.wireServicesIfConnected()
    }

    // Wire connection lost callback - updates UI when connection is lost
    connectionManager.onConnectionLost = { [weak self] in
      await self?.wireServicesIfConnected()
    }

    // Wire disconnect callback - every `disconnect(reason:)`, including the
    // internal resync-exhaustion, forget-device, and pairing-failure paths that
    // never fire onConnectionLost, runs the app-level teardown exactly once.
    connectionManager.onDisconnected = { [weak self] reason in
      await self?.handleDisconnected(reason: reason)
    }

    connectionManager.onLastConnectedDeviceCleared = { [weak self] in
      guard let self else { return }
      chatCoordinatorRegistry?.clear()
      refreshConversations()
      bumpServicesVersion()
    }

    // Wire auto-reconnect entry callback - reflects an out-of-range drop on the
    // Live Activity immediately, while connectionState is still .connecting.
    connectionManager.onAutoReconnectStarted = { [weak self] in
      await self?.liveActivityManager.handleConnectionLost()
      self?.publishWidgetSnapshot()
    }

    // Wire background auth-failure callback - surfaces guided pairing-failure
    // recovery when an opportunistic reconnect finds the bond invalidated, but
    // only while active so a backgrounded failure can't latch a stale alert.
    connectionManager.onAuthenticationFailure = { [weak self] deviceID in
      self?.handleAuthenticationFailure(
        deviceID: deviceID,
        isAppActive: UIApplication.shared.applicationState == .active
      )
    }

    // Wire device synced callback - runs after sync completes and state is .ready
    connectionManager.onDeviceSynced = { [weak self] in
      self?.performStaleNodeCleanup()
    }

    loadPersistedRegionSelection()
    followObservations()

    // The path suggestion drives real navigation; the placeholder has no scene to navigate,
    // so skip the work and the strong self-capture it would keep alive.
    if !isPlaceholder {
      Task { [regionAlreadySet = regionSelection != nil] in
        let suggested = await onboarding.suggestedStartingPath(
          connectionManager: connectionManager,
          locationAuthorizationStatus: locationService.authorizationStatus,
          regionAlreadySet: regionAlreadySet
        )
        if !suggested.isEmpty {
          onboarding.onboardingPath = suggested
        }
      }
    }
  }

  // MARK: - Lifecycle

  /// The first `initialize()` call's launch work. Every window's launch task
  /// calls `initialize()`, so later callers await this instead of re-activating
  /// the connection manager over a live connection.
  @ObservationIgnored private var initializeTask: Task<Void, Never>?

  #if DEBUG
    /// Optional test-only stand-in for the launch work, for run-once tests.
    var initializeOverride: (@MainActor () async -> Void)?
  #endif

  /// Initialize on app launch. Safe to call from every window: the launch work
  /// runs once per instance and later callers wait for that run to finish.
  func initialize() async {
    if let initializeTask {
      await initializeTask.value
      return
    }
    let task = Task { @MainActor in
      await performInitialize()
    }
    initializeTask = task
    await task.value
  }

  private func performInitialize() async {
    #if DEBUG
      if let initializeOverride {
        await initializeOverride()
        return
      }
    #endif

    // Detached so launch does not wait on file I/O.
    Task.detached(priority: .utility) {
      LogExportService.purgeStaleExports()
    }

    // The last radio's contacts name senders offline too (Home, search, rooms, reactions).
    scheduleNodeAppearanceRefresh()

    // Decide What's New before activate() can drive any connection alert. The
    // value of `hasCompletedOnboarding` read here is the "was onboarded at
    // launch" signal that distinguishes a brand-new install from an upgrader.
    #if DEBUG
      let isScreenshotMode = ProcessInfo.processInfo.isScreenshotMode
    #else
      let isScreenshotMode = false
    #endif
    whatsNew.evaluate(
      isOnboarded: onboarding.hasCompletedOnboarding,
      isScreenshotMode: isScreenshotMode
    )

    // Recover any existing Live Activity before activate() so that onConnectionReady
    // (which fires during activate) finds currentActivity populated and can update it.
    await liveActivityManager.recoverExistingActivity()
    liveActivityManager.startObservingEnablement()
    startRadioPositionRefresh()
    await connectionManager.activate()
    // The widget's first picture of this launch (a radio that was forgotten reads as none).
    publishWidgetSnapshot()
    // Check if disconnected pill should show (for fresh launch after termination)
    connectionUI.updateDisconnectedPillState(
      connectionState: connectionState,
      lastConnectedDeviceID: connectionManager.lastConnectedDeviceID,
      shouldSuppressDisconnectedPill: connectionManager.shouldSuppressDisconnectedPill
    )
  }

  /// Per-session teardown for connection-loss and explicit disconnect, kept in
  /// one place so neither path leaves battery polling, the sync coordinator, or
  /// CLI state behind. The coordinator registry stays so an open chat keeps its
  /// timeline. The Live Activity is left to the caller: a loss shows it as
  /// disconnected, an explicit disconnect ends it.
  func tearDownAppStateSessionState(announcesConnectionLoss: Bool) {
    settingsEventsTask?.cancel()
    settingsEventsTask = nil
    syncDataEventsTask?.cancel()
    syncDataEventsTask = nil
    advertisementEventsTask?.cancel()
    advertisementEventsTask = nil
    rxLogEventsTask?.cancel()
    rxLogEventsTask = nil
    sentPacketEventsTask?.cancel()
    sentPacketEventsTask = nil
    messageEventDispatcher.cancelAll()
    navigation.clearPendingLinks()
    syncCoordinator = nil
    connectionUI.handleDisconnect(
      connectionState: connectionState,
      lastConnectedDeviceID: connectionManager.lastConnectedDeviceID,
      shouldSuppressDisconnectedPill: connectionManager.shouldSuppressDisconnectedPill,
      announcesConnectionLoss: announcesConnectionLoss
    )
    cliToolViewModel?.reset()
    batteryMonitor.stop()
    batteryMonitor.clearThresholds()
    neighbourDirectory.markDisconnected()
    probeCoordinator.handleDisconnect()
    unseenAdvertCount = 0
    lastBumpedServicesID = nil
  }

  /// Presents the guided pairing-failure recovery for an invalidated bond, only
  /// while the app is active: a backgrounded failure must not latch a stale alert
  /// for the next foreground, where the reconnect re-surfaces it fresh if still bad.
  func handleAuthenticationFailure(deviceID: UUID, isAppActive: Bool) {
    guard isAppActive else { return }
    connectionUI.presentPairingFailure(.connectionFailed(deviceID: deviceID, underlying: BLEError.authenticationFailed))
  }

  /// Drops per-slot drafts, cached `ChatCoordinator`s, and the selected route.
  /// Coordinators outlive the connection, so without eviction the next occupant renders the prior timeline.
  func handleChannelSlotOccupantChanged(radioID: UUID, indices: Set<UInt8>) {
    draftStore.clearChannelDrafts(radioID: radioID, indices: indices)
    for channelIndex in indices {
      let id = ChatConversationID.channel(radioID: radioID, channelIndex: channelIndex)
      chatCoordinatorRegistry?.remove(for: id)
      channelSlotGenerations[id, default: 0] += 1
    }
    if case let .channel(selected) = navigation.chatsSelectedRoute,
       selected.radioID == radioID,
       indices.contains(selected.index) {
      navigation.chatsSelectedRoute = nil
    }
    refreshConversations()
  }

  /// Wire services-dependent callbacks after a successful connection.
  ///
  /// Every await below can resume after the link dropped or a newer connection
  /// installed a different container. `isCurrent` is re-checked after each one so
  /// a stale run stops instead of wiring a dead container over the teardown (or
  /// the newer wiring) that ran in the meantime.
  func wireServicesIfConnected() async {
    guard let services else {
      tearDownAppStateSessionState(announcesConnectionLoss: true)
      await liveActivityManager.handleConnectionLost()
      publishWidgetSnapshot()
      return
    }
    let isCurrent = { [weak self] in self?.services === services }

    // The link is up, so drop any pairing-failure alert latched while
    // backgrounded before it can present over a working connection.
    connectionUI.clearPairingFailure()

    // Wire ConnectionUI callbacks (sync activity, node storage, pills, VoiceOver)
    // Must be set before onConnectionEstablished to avoid a race condition
    await connectionUI.wireCallbacks(
      syncCoordinator: services.syncCoordinator,
      advertisementService: services.advertisementService,
      contactService: services.contactService,
      connectionManager: connectionManager,
      session: services.session
    )
    guard isCurrent() else { return }

    // On a device switch onConnectionLost doesn't fire, so the disconnect teardown that
    // resets per-radio UI state is skipped. Reset the CLI and every per-radio detail selection
    // here so neither carries the previous radio's state into the new session.
    if let newDeviceID = connectedDevice?.id,
       let oldDeviceID = lastConnectedDeviceIDForCLI,
       newDeviceID != oldDeviceID {
      cliToolViewModel?.reset()
      navigation.clearPerRadioSelection()
      unseenAdvertCount = 0
    }
    lastConnectedDeviceIDForCLI = connectedDevice?.id

    // Store syncCoordinator reference
    syncCoordinator = services.syncCoordinator

    // Process-wide inline image cache learns where to persist probed dims.
    await InlineImageCache.shared.attachDimensionsStore(services.inlineImageDimensionsStore)
    guard isCurrent() else { return }

    // Demo mode ships an inline image whose bytes are embedded offline; pre-seed the
    // process-wide cache so the seeded DM renders it without a network fetch.
    if connectedDevice?.id == MockDataProvider.simulatorDeviceID {
      DemoInlineImageSeeder.seed()
    }

    wireSyncDataEvents(services: services)
    wireNeighbours(services: services)
    await wireSettingsEventStream(services: services)
    guard isCurrent() else { return }
    await wireDeviceUpdateCallbacks(services: services)
    guard isCurrent() else { return }
    wireMessageEvents(services: services)
    await wireLiveActivityCallbacks(services: services)
    guard isCurrent() else { return }

    await services.channelService.setSlotOccupantChangedHandler { [weak self] radioID, indices in
      await self?.handleChannelSlotOccupantChanged(radioID: radioID, indices: indices)
    }
    guard isCurrent() else { return }

    // Bump the version (which drives `.task(id:)` reloads in chat, tools, and
    // room views) only when the services container actually changed. A single
    // connect both fires `onConnectionReady` and is followed by an explicit
    // `wireServicesIfConnected()` call, and the Live Activity toggle re-wires the
    // same container — none of those are a services change, so they must not
    // trigger a reload.
    let servicesID = ObjectIdentifier(services)
    if lastBumpedServicesID != servicesID {
      lastBumpedServicesID = servicesID
      servicesVersion += 1

      // A real services change is the one moment the addressable contact/channel
      // set can differ from what saved shortcuts were resolved against, so re-resolve
      // the App Intents parameter queries here (debounced by this same guard, and past
      // the connection-lost early return so it never fires on disconnect).
      refreshAppShortcutParameters()
    }

    // Wire localized strings, then register categories. The notification center's
    // delegate is the app-lifetime `NotificationResponseRelay`, which forwards to
    // this service while it is the connected one.
    services.notificationService.setStringProvider(NotificationStringProviderImpl())
    await services.notificationService.setup()
    guard isCurrent() else { return }

    // Configure badge count callback
    services.notificationService.getBadgeCount = { [weak self, dataStore = services.dataStore] in
      let radioID = await MainActor.run { self?.currentRadioID }
      guard let radioID else {
        return (contacts: 0, channels: 0, rooms: 0)
      }
      do {
        return try await dataStore.getTotalUnreadCounts(radioID: radioID)
      } catch {
        return (contacts: 0, channels: 0, rooms: 0)
      }
    }

    // Seed the badge from persisted unread messages now that the callback is wired; otherwise
    // badgeCount stays 0 until a message arrives or a chat opens and recomputes it.
    await services.notificationService.updateBadgeCount()
    guard isCurrent() else { return }

    // Configure notification interaction handlers
    configureNotificationHandlers()

    // Defer battery bootstrap so connection setup is not blocked by device request timeouts.
    batteryMonitor.start(services: services) { [weak self] in self?.connectedDevice }
  }

  // MARK: - Stale Node Cleanup

  /// Runs automatic cleanup of stale non-favorite nodes if the threshold is configured.
  /// - Parameter force: When `true`, skips the 6-hour cooldown (used when the user changes the setting).
  func performStaleNodeCleanup(force: Bool = false) {
    let threshold = UserDefaults.standard.integer(forKey: AppStorageKey.autoDeleteStaleNodesDays.rawValue)
    guard threshold > 0 else { return }

    if !force {
      let lastRunTimestamp = UserDefaults.standard.double(forKey: AppStorageKey.lastStaleCleanupDate.rawValue)
      let lastRun = lastRunTimestamp > 0 ? Date(timeIntervalSinceReferenceDate: lastRunTimestamp) : Date.distantPast
      guard Date().timeIntervalSince(lastRun) >= 3 * 3600 else {
        logger.debug("Stale node cleanup skipped — cooldown not expired")
        return
      }
    }

    Task {
      do {
        let result = try await connectionManager.removeStaleNodes(olderThanDays: threshold)
        if let failure = result.failure {
          // Not stamped as run: the next sync tries the rest instead of waiting out the cooldown.
          logger.warning(
            "Stale node cleanup stopped: removed \(result.removed) of \(result.total) nodes older than \(threshold) days: \(failure.localizedDescription)"
          )
          return
        }
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: AppStorageKey.lastStaleCleanupDate.rawValue)
        if result.removed < result.total {
          logger.warning("Stale node cleanup: removed \(result.removed) of \(result.total) nodes older than \(threshold) days; the rest could not be deleted from the app")
        } else if result.total > 0 {
          logger.info("Stale node cleanup: removed \(result.removed) of \(result.total) nodes older than \(threshold) days")
        } else {
          logger.debug("Stale node cleanup: no stale nodes found")
        }
      } catch {
        logger.warning("Stale node cleanup failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Onboarding

  func completeOnboarding() {
    onboarding.completeOnboarding()
    // Setup on the phone is where Siri permission belongs: CarPlay messaging depends on it, and
    // the car can't ask. Asked once, as the app opens; Settings → CarPlay & Siri can ask later.
    SiriAuthorization.requestIfNeeded()
  }

  #if DEBUG
    /// Test helper: Overrides BLE lifecycle operations for deterministic ordering tests.
    func setBLELifecycleOverridesForTesting(
      enterBackground: (@MainActor () async -> Void)? = nil,
      becomeActive: (@MainActor () async -> Void)? = nil
    ) {
      bleEnterBackgroundOverride = enterBackground
      bleBecomeActiveOverride = becomeActive
    }

    /// Test helper: Replaces the launch work `initialize()` runs.
    func setInitializeOverrideForTesting(_ override: (@MainActor () async -> Void)?) {
      initializeOverride = override
    }
  #endif
}

// MARK: - Preview Support

extension AppState {
  /// Creates an AppState for previews using an in-memory container
  @MainActor
  convenience init(defaults: UserDefaults = .standard) {
    self.init(modelContainer: Self.makeInMemoryContainer(), defaults: defaults)
  }

  /// In-memory container over the canonical `PersistenceStore.schema`, shared by preview and
  /// placeholder instances. Built directly rather than via `createContainer(inMemory:)`, which
  /// interns its container and would share one store across otherwise independent instances.
  private static func makeInMemoryContainer() -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    // swiftlint:disable:next force_try
    return try! ModelContainer(for: PersistenceStore.schema, configurations: [config])
  }

  /// Shared inert stand-in backing the `appState` environment default. Built once and never
  /// wired to a connection: its services are nil, and it publishes no process-global state.
  static let placeholder = makePlaceholder()

  private static func makePlaceholder() -> AppState {
    AppState(modelContainer: makeInMemoryContainer(), isPlaceholder: true)
  }
}

// A hand-written key rather than `@Entry`: the macro expands `defaultValue` into a computed
// property, which for a class type SwiftUI flags as reallocating on every read. A stored
// `static let` returns the one shared placeholder and silences that diagnostic.
// swiftformat:disable environmentEntry
private struct AppStateKey: EnvironmentKey {
  static let defaultValue = MainActor.assumeIsolated { AppState.placeholder }
}

extension EnvironmentValues {
  /// Inert stand-in returned when a view reads `appState` outside a configured scene, such as
  /// an app-switcher snapshot. `AppState.placeholder` is shared and never wired to a connection.
  var appState: AppState {
    get { self[AppStateKey.self] }
    set { self[AppStateKey.self] = newValue }
  }
}

// swiftformat:enable environmentEntry
