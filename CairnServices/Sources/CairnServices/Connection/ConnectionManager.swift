@preconcurrency import CoreBluetooth
import Foundation
import MeshCore
import os
import OSLog
import SwiftData

/// Manages the connection lifecycle for mesh devices.
///
/// `ConnectionManager` owns the transport, session, and services. It handles:
/// - Device pairing via the `DevicePairingService` seam (AccessorySetupKit on iOS, in-app scan picker on macOS)
/// - Connection and disconnection
/// - Auto-reconnect on connection loss
/// - Last-device persistence for app restoration
///
/// ## Connection-state model
///
/// Three distinct enums describe "where are we", at three layers, and they do
/// not collapse into one another:
///
/// - `BLEPhase` (on `BLEStateMachine`): the CoreBluetooth link lifecycle
///   (`idle`, `connecting`, `discoveringServices`, `discoveryComplete`,
///   `connected`, `autoReconnecting`, ...). Driven by CBCentralManager
///   callbacks; every transition routes through `BLEStateMachine.transition(to:)`.
///   Concerns only the BLE transport, and is undefined for WiFi-bridged radios.
/// - `MeshCore.ConnectionState`: the transport-link state the session publishes
///   (`disconnected`, `connecting`, `connected`, `reconnecting`, `failed`).
///   `@_exported import MeshCore` makes its bare name visible app-wide; this one
///   is the lower layer.
/// - `DeviceConnectionState`: the app-facing rung (`disconnected`, `connecting`,
///   `connected`, `syncing`, `ready`). Adds the post-link `syncing`/`ready`
///   distinction the transport layer has no concept of. This is the value
///   `connectionState` holds and the one UI gates on.
///
/// `ConnectionManager` drives `connectionState` directly from the connect, sync,
/// disconnect, and reconnect paths; nothing else writes it. The transport layer
/// reports link events through the lifecycle callbacks wired in `init`
/// (`setDisconnectionHandler`, `setReconnectionHandler`, the auto-reconnect and
/// powered-on handlers), which this class translates into `connectionState`
/// transitions. `ConnectionIntent` is the orthogonal "does the user want to be
/// connected" axis that gates auto-reconnect, and is the only piece persisted
/// across launches. In DEBUG, `assertStateInvariants()` enforces that `.syncing`
/// and `.ready` always carry a live `services`, `session`, and `connectedDevice`,
/// and that `.userDisconnected` intent only coexists with `.disconnected`.
@Observable
@MainActor
public final class ConnectionManager {
  // MARK: - Logging

  let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "ConnectionManager")

  /// Background App Refresh runs and the WiFi approval gate, under their own category so they
  /// read as one story in exported diagnostics.
  let backgroundRefreshLogger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "BackgroundRefresh")

  // MARK: - Observable State

  /// Broadcasts every `connectionState` change. Per-connection consumers
  /// (`ServiceContainer`) subscribe at construction and end their
  /// subscription by task cancellation in `tearDown()`. `ConnectionManager`
  /// never calls `finish()`: it lives for the app lifetime, and the next
  /// connection's container subscribes to this same broadcaster.
  let connectionStateEvents = EventBroadcaster<DeviceConnectionState>()

  /// Current connection state
  public internal(set) var connectionState: DeviceConnectionState = .disconnected {
    didSet {
      connectionStateEvents.yield(connectionState)
      #if DEBUG
        assertStateInvariants()
      #endif
    }
  }

  /// Connected device info (nil when disconnected)
  public internal(set) var connectedDevice: DeviceDTO?

  /// Allowed repeat frequency ranges from connected device (empty when disconnected or unsupported)
  public var allowedRepeatFreqRanges: [MeshCore.FrequencyRange] = []

  /// Services container (nil when disconnected)
  public internal(set) var services: ServiceContainer?

  /// Current transport type (bluetooth or wifi)
  public internal(set) var currentTransportType: TransportType?

  /// Current user-actionable Bluetooth availability, updated as `CBCentralManager` reports state
  /// changes. The macOS scan picker reads this to swap its scanning state for a remedy when
  /// Bluetooth is off or unauthorized; iOS surfaces the same conditions through its system picker.
  public internal(set) var bluetoothAvailability: BluetoothAvailability = .ready

  /// Detected device platform, used for sync throttling config.
  /// Survives reconnects (lives on ConnectionManager, not ServiceContainer).
  private(set) var detectedPlatform: DevicePlatform = .unknown

  /// Records the last fully-clean channel sync, keyed by device.
  /// Only set when channel sync completes with zero errors (including retries), and cleared
  /// when a full read that did not finish cleanly changed the stored table.
  /// Survives transient disconnects; cleared on explicit disconnect or device change.
  /// In memory only: it drives the 300 s skip; `verifiedChannelTableRadioID` is the copy
  /// that outlives the process. Dropped by a backup import (`dropChannelSyncRecordsPredatingImport()`).
  var lastCleanChannelSync: (radioID: UUID, completedAt: Date)?

  /// Records the last attempted channel sync, including partial/failed attempts.
  /// Used to cool down immediate channel-only retry loops. Dropped by a backup import.
  var lastAttemptedChannelSync: (radioID: UUID, attemptedAt: Date)?

  /// The backup import generation (`PersistenceKeys.channelRowsImportGeneration`) the in-memory
  /// channel sync records above were made under.
  var channelSyncRecordsImportGeneration = 0

  /// The user's connection intent. Replaces shouldBeConnected, userExplicitlyDisconnected, and pendingForceFullSync.
  var connectionIntent: ConnectionIntent = .none

  /// The device being actively connected via connect(to:) or switchDevice(to:).
  /// Nil during auto-reconnect (tracked by reconnectionCoordinator.reconnectingDeviceID instead).
  var connectingDeviceID: UUID?

  /// Ownership token for explicit connect attempts: a BLE connect, a device switch, a WiFi
  /// connect, and each WiFi reconnect attempt claim a fresh value through
  /// `beginConnectionAttempt(_:)` before their first await. Any await can let a newer attempt
  /// (or a disconnect, which invalidates) take over, so after each one an attempt checks
  /// `ownsConnectionAttempt(_:)` and, once superseded, tears down only what it built itself.
  var connectionAttemptToken: UInt64 = 0

  /// Transport of the attempt holding `connectionAttemptToken`, nil once it finished or
  /// failed. While set, the opportunistic paths (foreground health checks, the watchdog,
  /// Bluetooth power-on) stand down: a WiFi connect is otherwise read as a stale BLE link.
  var connectionAttemptTransport: TransportType?

  /// The launch reconnect `activate()` starts, nil once it finished. The foreground
  /// reconciliations stand down while it runs: launch already reconciles the link.
  var launchReconnectTask: Task<Void, Never>?

  /// Set from the moment the central may exist ahead of the launch reconnect (created early
  /// by `prepareBluetoothCentral()`, or by `activate()` itself) until `activate()` has handed
  /// the reconnect to `launchReconnectTask`: the launch owns the first attempt, so a power-on
  /// callback in between must not start one of its own.
  var isAwaitingLaunchActivation = false

  /// The ASK session activation, shared by `prepareBluetoothCentral()` and `activate()`:
  /// `AccessorySetupKitService.activateSession()` returns at once to a second caller while
  /// the first is still waiting on the session, so both must await the same run.
  var pairingActivationTask: Task<Void, Never>?

  /// Set once a WiFi connect was refused Local Network access; later automatic connects
  /// then fail fast instead of waiting a minute for a prompt that will not change.
  var hasSeenLocalNetworkDenial = false

  /// WiFi endpoints whose radio left a background attempt unanswered (it is asking whether to
  /// allow this phone); background attempts to them wait for the user. Persisted.
  let backgroundWiFiGate: BackgroundWiFiApprovalGate

  /// When the app last went to the background; a WiFi link older than a few seconds of
  /// suspension is probed before the app shows it as live again.
  var lastBackgroundedAt: Date?

  /// Whether the last lifecycle transition was to the background; nil before the first, when
  /// `appStateProvider` answers instead (a background relaunch sees no transition).
  var lifecycleIsBackground: Bool?

  /// When link activity last restarted a failed sync, so a busy link retries at most once a
  /// minute (backing off while the retries keep failing) while the app runs in the background.
  var lastLinkActivityResyncAt: Date?

  /// Resync loops that failed in the background in a row: each one doubles the wait before link
  /// activity starts the next (``linkActivityResyncDelay(failedLoops:)``). Reset by a successful
  /// resync and by the return to the foreground.
  var backgroundResyncFailedLoops = 0

  /// Session rebuilds that failed in the background in a row, and when the last one did: link
  /// activity waits ``linkActivityRebuildDelay(failures:)`` after it before rebuilding again.
  /// Reset by an operational session (`recordConnectionSuccess`) and by the return to the foreground.
  var backgroundRebuildFailures = 0
  var lastBackgroundRebuildFailureAt: Date?

  /// Called (throttled) whenever the radio sends anything over Bluetooth, the link or app stack
  /// alive or not.
  public var onLinkActivity: (() async -> Void)?

  /// The "may not be receiving" reminder and "Bluetooth is off" notice, driven from the lifecycle,
  /// the link's activity, Bluetooth power and disconnects. Installed by the iOS AppState.
  public var listeningReminder: ListeningReminder?

  /// Asks the OS for extra background run time for work a Bluetooth wake started (a session rebuild
  /// and its sync, a resync loop): a wake alone gives the app about ten seconds, and a sync cut off
  /// by suspension used to fail and give up the link. Returns the call that ends it. Installed by the
  /// iOS AppState (UIApplication background tasks); nil elsewhere.
  public var beginBackgroundRuntime: (@MainActor (String) -> @MainActor () -> Void)?

  /// The device whose MeshCore session is currently being rebuilt after a BLE auto-reconnect.
  /// Used to suppress duplicate reconnect attempts while session startup is still in flight.
  var sessionRebuildDeviceID: UUID?

  /// Device whose pairing-failure recovery has already been surfaced this failure
  /// episode. While the bond stays invalid every watchdog retry fails the same way,
  /// so without this latch the recovery alert would re-interrupt after each retry.
  /// Cleared on ready promotion and on explicit disconnect, opening a new episode.
  var surfacedAuthFailureDeviceID: UUID?

  /// True for the duration of pairNewDevice() — suppresses opportunistic
  /// reconnect paths so they can't race the pairing's `connect(to:)` for the
  /// BLE state machine's single in-flight connect slot.
  var isPairingInProgress = false

  /// True from scan/setup enqueue until cancel or `pairNewDevice` finishes,
  /// and while `deleteDevice` of the live or in-flight radio waits on iOS Remove Accessory.
  /// Distinct from `isPairingInProgress` so setup confirmation is not treated as a live picker.
  public var isPairingFlowActive = false

  /// True while an explicit connect owns the link: the launch reconnect, a user connect or
  /// device switch over Bluetooth, or a WiFi connect or reconnect attempt. Opportunistic
  /// reconnects (foreground health checks, the watchdog, Bluetooth power-on) consult this so
  /// they never cancel or race such a connect.
  var isExplicitConnectInFlight: Bool {
    launchReconnectTask != nil
      || isAwaitingLaunchActivation
      || connectingDeviceID != nil
      || connectionAttemptTransport != nil
  }

  /// Claims a fresh connect attempt over `transport` and marks it as the current transport
  /// right away, so every lifecycle check sees the in-flight attempt for what it is.
  /// - Returns: The token the attempt checks with `ownsConnectionAttempt(_:)` after each await.
  func beginConnectionAttempt(_ transport: TransportType) -> UInt64 {
    connectionAttemptToken &+= 1
    connectionAttemptTransport = transport
    currentTransportType = transport
    return connectionAttemptToken
  }

  /// Whether the attempt that claimed `token` is still the newest one.
  func ownsConnectionAttempt(_ token: UInt64) -> Bool {
    connectionAttemptToken == token
  }

  /// Ends the attempt that claimed `token`, if it is still the newest. A failed attempt
  /// passes `clearingTransport` to undo the current-transport mark it set when it claimed.
  func endConnectionAttempt(_ token: UInt64, clearingTransport: Bool = false) {
    guard ownsConnectionAttempt(token) else { return }
    connectionAttemptTransport = nil
    if clearingTransport {
      currentTransportType = nil
    }
  }

  /// Supersedes whatever attempt is in flight, without starting a new one. Used by
  /// `disconnect(reason:)` so an attempt that resumes afterwards finds it no longer owns the link.
  func invalidateConnectionAttempt() {
    connectionAttemptToken &+= 1
    connectionAttemptTransport = nil
  }

  /// Single source of truth for "stand down, an explicit connect flow is running."
  /// Opportunistic reconnect call sites consult this; or new conditions in here
  /// when the next contention class shows up, so every site picks them up.
  public var shouldDeferOpportunisticReconnect: Bool {
    isPairingInProgress || isPairingFlowActive
  }

  /// Single chokepoint for opportunistic reconnect attempts. Consults the defer
  /// predicate and dispatches to `connect(to:)`. New opportunistic-reconnect
  /// sites must route through this helper rather than duplicating the gate logic.
  /// The auto-reconnect-handler closure (`setAutoReconnectingHandler`) operates
  /// on `.autoReconnecting` phases rather than initiating a `.connecting`, so it
  /// applies the same gate predicate at its own call site instead.
  /// - Parameters:
  ///   - deviceID: device to reconnect to. The caller is responsible for
  ///     vetting that the user wants this device connected before invoking.
  ///   - reason: short string for log correlation across call sites.
  func attemptOpportunisticReconnect(deviceID: UUID, reason: String) async {
    guard !shouldDeferOpportunisticReconnect else {
      logger.info("[BLE] Opportunistic reconnect skipped (\(reason)): pairing in progress")
      return
    }
    // connect(to:) cancels an attempt for a different device, so a background retry must
    // never reach it while a connect the user (or launch) started is still running.
    guard !isExplicitConnectInFlight else {
      logger.info("[BLE] Opportunistic reconnect skipped (\(reason)): an explicit connect is in flight")
      return
    }
    guard currentTransportType != .wifi else {
      logger.info("[BLE] Opportunistic reconnect skipped (\(reason)): the radio is on WiFi")
      return
    }
    do {
      try await connect(to: deviceID)
    } catch {
      logger.warning("[BLE] Opportunistic reconnect (\(reason)) failed: \(error.localizedDescription)")
      // An invalidated bond can't be resolved by retrying in the background;
      // route it to the same guided pairing-failure recovery a fresh connect
      // attempt would show, rather than leaving the user on a silent watchdog loop.
      if case BLEError.authenticationFailed = error {
        surfaceAuthenticationFailure(deviceID: deviceID)
        return
      }
      // A timed connect that failed in the background leaves no wake source behind.
      await ensureWakeSource(context: "opportunistic reconnect failed (\(reason))")
    }
  }

  /// Fires `onAuthenticationFailure` at most once per failure episode, tracked by
  /// `surfacedAuthFailureDeviceID`. All auth-failure surfacing routes through here
  /// so the latch covers every producer path.
  func surfaceAuthenticationFailure(deviceID: UUID) {
    guard surfacedAuthFailureDeviceID != deviceID else {
      logger.info("[BLE] Pairing-failure recovery already surfaced for \(deviceID.uuidString.prefix(8)), suppressing repeat")
      return
    }
    surfacedAuthFailureDeviceID = deviceID
    onAuthenticationFailure?(deviceID)
  }

  /// Clears the auth-failure surfacing latch so the next failure episode for the
  /// same device re-presents the guided recovery.
  public func clearSurfacedAuthenticationFailure() {
    surfacedAuthFailureDeviceID = nil
  }

  // MARK: - Callbacks

  /// Called when connection is ready and services are available.
  /// Use this to wire up UI observation of services.
  /// Installed by `AppState` during initialization.
  public var onConnectionReady: (() async -> Void)?

  /// Called when connection is lost (disconnection, BLE power off, etc).
  /// Use this to update UI state when services become unavailable.
  /// Installed by `AppState` during initialization.
  public var onConnectionLost: (() async -> Void)?

  /// Called at the end of every `disconnect(reason:)`. Internal paths (resync
  /// exhaustion, forget/removed device, failed pairing, WiFi reconnect prep) tear
  /// the session down without firing `onConnectionLost`, so app-level per-session
  /// state (Live Activity, battery polling, sync coordinator) would otherwise hold
  /// the dead container. Fires exactly once per call, after teardown completes.
  /// Installed by `AppState` during initialization.
  public var onDisconnected: ((DisconnectReason) async -> Void)?

  /// Called when a live link drops and iOS auto-reconnect begins;
  /// `connectionState` stays `.connecting` and `onConnectionLost` fires only if
  /// the reconnect is later lost or given up. Fires after the reconnect cycle is
  /// claimed and before session teardown, inside the CoreBluetooth disconnect
  /// wake window, so the Live Activity reflects the loss ahead of the heavy
  /// teardown work and before the app suspends.
  /// Installed by `AppState` during initialization.
  public var onAutoReconnectStarted: (() async -> Void)?

  /// Called when a background reconnect attempt fails because the peer
  /// invalidated its bond. Use this to present guided pairing-failure recovery,
  /// since the watchdog will otherwise keep retrying a bond that can't heal itself.
  /// Fires at most once per failure episode (see `surfacedAuthFailureDeviceID`).
  /// Installed by `AppState` during initialization.
  public var onAuthenticationFailure: ((UUID) -> Void)?

  /// Called after initial sync completes and connectionState becomes `.ready`.
  /// Use this for work that depends on up-to-date synced data (e.g. stale node cleanup).
  /// Installed by `AppState` during initialization.
  public var onDeviceSynced: (() async -> Void)?

  /// Called when `clearPersistedConnection(for:)` clears the last-connected slot.
  /// Installed by `AppState` during initialization.
  public var onLastConnectedDeviceCleared: (@MainActor @Sendable () -> Void)?

  /// Provider for app foreground/background state detection.
  /// Installed by `AppState` during initialization.
  public var appStateProvider: AppStateProvider?

  /// Set when a connection reached a radio already saved over another transport
  /// (`SavedRadioLink`), for the app to tell the user; cleared once shown.
  public internal(set) var linkedRadioNotice: LinkedRadioNotice?

  public func clearLinkedRadioNotice() {
    linkedRadioNotice = nil
  }

  /// Number of devices registered with the system pairing registry (for troubleshooting UI).
  /// iOS reports AccessorySetupKit accessories; macOS reports 0 (no system registry).
  public var pairedAccessoriesCount: Int {
    pairing.registeredDeviceCount
  }

  /// Whether the connected device can be renamed through a system rename surface.
  /// `true` on iOS (AccessorySetupKit rename sheet); `false` on macOS, where the UI must
  /// hide the rename action rather than offer a control that silently does nothing.
  public var supportsDeviceRename: Bool {
    pairing.supportsSystemRename
  }

  /// Whether this platform has an app-visible system pairing registry (AccessorySetupKit).
  /// `true` on iOS; `false` on macOS "Designed for iPad". The device picker uses this to
  /// decide whether registry membership or the stored connection method is the reachability
  /// signal, and the connect path uses it to bound a user-initiated connect's retry budget.
  public var hasSystemPairingRegistry: Bool {
    pairing.hasSystemPairingRegistry
  }

  /// Process-lifetime persistence actor, created once in `init`. Session
  /// services receive this instance; no production path mints a second one.
  public let persistenceStore: PersistenceStore

  // MARK: - Internal Components

  let modelContainer: ModelContainer
  private let defaults: UserDefaults
  private let lastConnectionStore: LastConnectionStore
  let transport: any iOSMeshTransport
  var wifiTransport: WiFiTransport?
  var session: MeshCoreSession?
  /// Device discovery + system pairing-registry seam. Resolves to AccessorySetupKit on
  /// iOS, or an in-app CoreBluetooth scan picker on macOS "Designed for iPad".
  let pairing: any DevicePairingService

  /// Non-nil only on macOS, where the scan picker UI must be presented by the view layer.
  /// nil on iOS, where AccessorySetupKit presents its own system picker.
  public var bluetoothScanPicker: BluetoothScanPairingService? {
    pairing as? BluetoothScanPairingService
  }

  /// Shared BLE state machine to manage connection lifecycle.
  /// This prevents state restoration race conditions that cause "API MISUSE" errors.
  let stateMachine: any BLEStateMachineProtocol

  /// Coordinates iOS auto-reconnect lifecycle (timeouts, teardown, rebuild).
  let reconnectionCoordinator = BLEReconnectionCoordinator()

  // MARK: - WiFi Reconnection

  /// Task handling WiFi reconnection attempts
  var wifiReconnectTask: Task<Void, Never>?

  /// Current reconnection attempt number
  var wifiReconnectAttempt = 0

  /// Duration of the fast WiFi reconnect window (sub-second to 4 s backoff).
  /// When it expires observers are told the link is lost, and the loop drops
  /// to the slow backoff below rather than giving up.
  static let wifiMaxReconnectDuration: Duration = .seconds(30)

  /// Attempts the fast window makes before it may expire. Its duration is wall time, which
  /// runs on while iOS keeps the app suspended (a WiFi socket wakes nothing): a window opened
  /// just before suspension would otherwise read as spent on return, after one attempt, and
  /// leave the user at Disconnected for the slow backoff's first 30 s.
  static let wifiMinFastReconnectAttempts = 4

  /// Start time of the last fast reconnect window (for rate limiting rapid disconnects)
  var lastWiFiReconnectStartTime: Date?

  /// Minimum interval between the starts of two fast reconnect windows. A link
  /// that flaps (reconnects, then drops again at once) would otherwise open a
  /// new window of rapid attempts on every drop; a drop inside the cooldown
  /// defers its window to the end of the cooldown instead.
  static let wifiReconnectCooldown: TimeInterval = 35

  /// First delay of the slow backoff that follows an expired fast window
  static let wifiSlowReconnectInitialDelay: Duration = .seconds(30)

  /// Cap on the slow backoff delay
  static let wifiSlowReconnectMaxDelay: Duration = .seconds(300)

  /// Whether the reconnect loop has left its fast window and is in the slow
  /// backoff, where `connectionState` is `.disconnected` between attempts.
  var isWiFiReconnectBackingOff = false

  // MARK: - WiFi Heartbeat

  /// Task for periodic WiFi connection health checks
  var wifiHeartbeatTask: Task<Void, Never>?

  /// Interval between WiFi heartbeat probes (seconds)
  static let wifiHeartbeatInterval: Duration = .seconds(30)

  // MARK: - Background App Refresh

  /// The longest a refresh run's drain of a live link may take.
  static let backgroundRefreshDrainCap: Duration = .seconds(12)

  /// The least time a refresh run must have left to start a WiFi reconnect. TCP gives up after
  /// 10 s and an unanswered APP_START after 5 s, so this lets the attempt reach a verdict inside
  /// the run: the radio answered, or it failed the way a radio awaiting approval fails. A connect
  /// still waiting for APP_START when the run ends is cancelled, not left to be suspended.
  /// Tests shorten it.
  var backgroundRefreshMinimumForConnect: Duration = .seconds(15)

  /// How long a refresh run waits for a connect it cancelled to close its socket.
  static let backgroundRefreshCancelGrace: Duration = .seconds(1)

  /// The longest a WiFi handshake can take to fail while the app runs; a failure seen later
  /// came from a suspension (`handshakeOutlivedItsTimeouts`). Tests shorten it.
  var wifiApprovalHandshakeWindow: Duration = .seconds(15)

  /// Task coordinating BLE scan startup to avoid start/stop races with stream termination.
  var bleScanTask: Task<Void, Never>?

  /// Monotonic token naming each `startBLEScanning()` stream.
  var bleScanRequestID: UInt64 = 0

  /// The open `startBLEScanning()` streams, by token. Each gets every discovery and the scan stops
  /// when the last one ends, so a page opened over another that scans (Device Info over
  /// Connections) shares the scan instead of taking it over and stopping it on Back. Locked
  /// because the discovery handler yields from the state machine's actor.
  let bleScanSubscribers = OSAllocatedUnfairLock<[UInt64: AsyncStream<DiscoveredDevice>.Continuation]>(
    initialState: [:]
  )

  // MARK: - Resync State

  // Stored state for the sync retry loops; the loops themselves live in the
  // SyncRetry extension, which cannot add instance storage.

  /// Current resync attempt count (reset on success or disconnect)
  var resyncAttemptCount = 0

  /// Task managing the resync retry loop
  var resyncTask: Task<Void, Never>?

  /// Task managing delayed channel-only retry after a partial channel phase.
  var channelRetryTask: Task<Void, Never>?

  /// Callback when resync fails after all attempts (triggers "Sync Failed" pill)
  /// Note: @Sendable @MainActor ensures safe cross-isolation callback
  /// Installed by `ConnectionUIState.wireCallbacks`.
  public var onResyncFailed: (@Sendable @MainActor () -> Void)?

  // MARK: - Circuit Breaker

  /// Prevents rapid reconnection loops after repeated failures.
  /// Closed → Open (30s cooldown) → Half-Open (single probe).
  private enum CircuitBreakerState {
    case closed
    case open(since: Date)
    case halfOpen
  }

  private var circuitBreaker: CircuitBreakerState = .closed
  private static let circuitBreakerCooldown: TimeInterval = 30

  /// Connect-retry budget for a single `connect(to:)` call.
  /// `default` applies to every attempt on a platform with a system pairing registry, and to
  /// all background reconnects. `unverified` bounds a *user-initiated* connect on a platform
  /// without a registry (macOS), where CoreBluetooth cannot pre-reject an absent cached
  /// peripheral, so the full budget would otherwise leave the user staring at a ~40s spinner.
  static let defaultConnectAttempts = 4
  static let unverifiedConnectAttempts = 2

  static let pairingAdoptionSettlePollInterval: Duration = .milliseconds(50)
  /// Pairing bound: rebuild can remain `.connected` after reconnect UI timeout stands down.
  static let pairingAdoptionSettleTimeout: Duration = .seconds(15)
  static let pairingAdoptionFailedDetail = "adoption failed"
  static let pairingAdoptionMissingSessionDetail = "adoption rebuilt no session"
  static let pairingAdoptionTimedOutDetail = "adoption timed out"

  /// Consecutive entries into `handleReconnectionFailure` while intent still wants a
  /// connection that are allowed to preserve a live link (not radio handshakes — on the
  /// auto-reconnect path the coordinator's first failed rebuild retries once before
  /// reaching this funnel, so one unit can already cover two handshakes). Uses `<=`
  /// comparison: N preserve attempts then sever on the (N+1)th wanting entry.
  /// Exhaustion severs the link and leaves recovery to the ContinuousClock watchdog
  /// (which only completes when the process is awake), so recovery waits until the
  /// user foregrounds or another wake arrives — do not tighten lightly.
  static let maxRebuildFailuresPreservingLink = 3

  /// Count of consecutive intent-wanting rebuild failures into `handleReconnectionFailure`.
  /// Reset on every operational session via `recordConnectionSuccess`.
  var consecutiveRebuildFailures = 0

  /// Checks whether a connection attempt should proceed.
  /// Returns `true` if the circuit breaker allows it.
  /// - Parameter force: When `true`, bypasses the circuit breaker (user-initiated reconnect)
  func shouldAllowConnection(force: Bool) -> Bool {
    if force { return true }

    switch circuitBreaker {
    case .closed:
      return true
    case let .open(since):
      if Date().timeIntervalSince(since) >= Self.circuitBreakerCooldown {
        circuitBreaker = .halfOpen
        logger.info("[BLE] Circuit breaker: open → halfOpen (cooldown elapsed)")
        return true
      }
      return false
    case .halfOpen:
      // Half-open: allow a single probe attempt to determine if the connection can be restored.
      return true
    }
  }

  /// Records a connection failure for circuit breaker tracking.
  /// Trips the breaker to `.open` when called after all retries are exhausted.
  func recordConnectionFailure() {
    switch circuitBreaker {
    case .closed:
      circuitBreaker = .open(since: Date())
      logger.warning("[BLE] Circuit breaker: closed → open (retries exhausted)")
    case .halfOpen:
      circuitBreaker = .open(since: Date())
      logger.warning("[BLE] Circuit breaker: halfOpen → open (probe failed)")
    case .open:
      break
    }
  }

  /// Records a successful connection, resetting the circuit breaker and the
  /// rebuild-preserve budget. The counter reset sits above the `.closed` early
  /// return so a healthy connection still refills the preserve budget.
  func recordConnectionSuccess() {
    consecutiveRebuildFailures = 0
    backgroundRebuildFailures = 0
    lastBackgroundRebuildFailureAt = nil
    if case .closed = circuitBreaker { return }
    circuitBreaker = .closed
    logger.info("[BLE] Circuit breaker: → closed (connection succeeded)")
  }

  /// Refills the rebuild-preserve budget after a successful device switch.
  /// Sole production call site: `switchDevice` after `promoteToReady`.
  func resetPreserveBudgetAfterDeviceSwitch() {
    recordConnectionSuccess()
  }

  /// Epoch bumped by every `clearPersistedConnection` so a queued bond-refresh
  /// persist hop that already passed `shouldPersistBondRefresh` cannot write
  /// after a forget clears the shield.
  var bondRefreshPersistEpoch: UInt64 = 0

  // MARK: - Reconnection Watchdog

  /// Task managing the reconnection watchdog (retries when stuck disconnected)
  var reconnectionWatchdogTask: Task<Void, Never>?

  /// Generation token so a finishing watchdog Task cannot nil a replacement task.
  var reconnectionWatchdogGeneration = 0

  /// Session IDs that need re-authentication after BLE reconnect.
  /// Populated by `handleBLEDisconnection()`, consumed by `rebuildSession()`.
  /// Empty after app restart, so rooms show "Tap to reconnect" instead of auto-connecting.
  var sessionsAwaitingReauth: Set<UUID> = []

  // MARK: - Simulator Support

  /// Simulator connection mode (used for demo mode on device)
  let simulatorMode = SimulatorConnectionMode()

  // Whether running in simulator mode
  #if targetEnvironment(simulator)
    public var isSimulatorMode: Bool {
      true
    }
  #else
    public var isSimulatorMode: Bool {
      false
    }
  #endif

  // MARK: - Last Device Persistence

  #if DEBUG
    /// Test override for lastConnectedDeviceID
    var testLastConnectedDeviceID: UUID?

    /// When true, `lastConnectedDeviceID` is nil so never-paired tests can
    /// drive `offlineDataStore` without touching the host UserDefaults.
    var testForceNeverPaired = false

    /// When set, the first watchdog sleep uses this instead of 30s so natural-exit
    /// tests can complete without waiting on production backoff.
    var testWatchdogInitialDelay: Duration?

    /// Runs after `shouldPersistBondRefresh` returns true and before the epoch
    /// check in `persistBondRefreshIfStillValid` — tests force clear in that window.
    var bondRefreshPersistAfterShouldPersistHook: (@MainActor () async -> Void)?

    /// True when the BLE reconnection watchdog task is active.
    var isReconnectionWatchdogRunning: Bool {
      reconnectionWatchdogTask != nil
    }

    /// Strategy injection for `waitForOtherAppReconnection`. Tests use this to
    /// signal when pairing is suspended in the wait so they can drive racers
    /// deterministically before releasing the wait.
    typealias OtherAppWaitStrategy = @Sendable (UUID) async -> Bool

    var otherAppWaitStrategyOverride: OtherAppWaitStrategy?

    /// Pairing leftover-GATT tests settle adoption without `rebuildSession`.
    /// Invoked only after adoption started.
    typealias PairingAdoptionSettleStrategy = @MainActor () async throws -> Void

    var pairingAdoptionSettleStrategyOverride: PairingAdoptionSettleStrategy?

    var testPairingAdoptionSettleTimeout: Duration?

    typealias HealthCheckSessionRebuildOverride = @MainActor (UUID) async throws -> Void

    var rebuildSessionForHealthCheckOverride: HealthCheckSessionRebuildOverride?
  #endif

  /// The last connected device ID (for auto-reconnect)
  public var lastConnectedDeviceID: UUID? {
    #if DEBUG
      if testForceNeverPaired { return nil }
      if let testID = testLastConnectedDeviceID {
        return testID
      }
    #endif
    return lastConnectionStore.deviceID
  }

  /// The last connected radio ID (for offline data scoping)
  public var lastConnectedRadioID: UUID? {
    lastConnectionStore.radioID
  }

  /// The last connected device name (for offline display when disconnected)
  public var lastConnectedDeviceName: String? {
    lastConnectionStore.deviceName
  }

  /// Records a successful connection for future restoration
  /// - Parameter transport: The transport the connection used, remembered per radio so the
  ///   next launch tries it first. Nil leaves the radio's recorded transport as it was.
  func persistConnection(deviceID: UUID, radioID: UUID, deviceName: String, transport: TransportType? = nil) {
    lastConnectionStore.persist(deviceID: deviceID, radioID: radioID, deviceName: deviceName)
    if let transport {
      lastConnectionStore.persistTransport(transport, forRadio: radioID)
    }
  }

  /// The transport the radio last connected over, nil when none was recorded.
  func lastTransport(forRadio radioID: UUID) -> TransportType? {
    lastConnectionStore.transport(forRadio: radioID)
  }

  /// Records that the device's BLE bond just completed a verified encrypted
  /// session. Called wherever session traffic flowed over the encrypted UART
  /// link (fresh connect, device switch, auto-reconnect rebuild); the radio
  /// gates that link behind MITM-bonded encryption, so any successful exchange
  /// proves the bond. Never called on the WiFi path, which bypasses the bond.
  /// Also marks the app session live for RSSI bond-shield refresh (awaited).
  func recordBondVerification(deviceID: UUID) async {
    lastConnectionStore.persistBondVerification(deviceID: deviceID)
    await stateMachine.recordBondVerification(deviceID: deviceID, at: Date())
    await stateMachine.setAppSessionLive(deviceID: deviceID)
  }

  /// Clears persisted last-connection / bond-verification state for the forgotten
  /// device. Always clears that device's in-memory bond verification (not the
  /// current bond-slot holder), and holder-matches the store keys so forgetting
  /// A cannot destroy B's shield. Also clears session-live when it matches so a
  /// queued `onBondRefreshed` hop cannot re-persist after the map clear.
  /// Bumps `bondRefreshPersistEpoch` first so an in-flight persist hop that
  /// already observed a true `shouldPersistBondRefresh` still no-ops.
  func clearPersistedConnection(for deviceID: UUID) async {
    bondRefreshPersistEpoch &+= 1
    let wasLastConnected = lastConnectionStore.deviceID == deviceID
    await stateMachine.clearBondVerification(deviceID: deviceID)
    if await stateMachine.isAppSessionLive(deviceID: deviceID) {
      await stateMachine.setAppSessionLive(deviceID: nil)
    }
    lastConnectionStore.clear(for: deviceID)
    // Forget, delete and removal from Settings all land here: the next connect reads every slot.
    verifiedChannelTableRadioID = nil
    if wasLastConnected {
      onLastConnectedDeviceCleared?()
    }
  }

  /// Persist path for RSSI bond refresh: snapshot epoch, re-validate on the SM,
  /// then require the same epoch before writing UserDefaults so a clear that
  /// landed during the await cannot resurrect the cross-launch shield.
  func persistBondRefreshIfStillValid(deviceID: UUID) async {
    let epoch = bondRefreshPersistEpoch
    guard await stateMachine.shouldPersistBondRefresh(deviceID: deviceID) else { return }
    #if DEBUG
      if let bondRefreshPersistAfterShouldPersistHook {
        await bondRefreshPersistAfterShouldPersistHook()
      }
    #endif
    guard epoch == bondRefreshPersistEpoch else { return }
    lastConnectionStore.persistBondVerification(deviceID: deviceID)
  }

  /// Whether the user wants a radio connected, connected now or being reconnected.
  public var isConnectionWanted: Bool {
    connectionIntent.wantsConnection
  }

  /// Whether the disconnected pill should be suppressed (user explicitly disconnected)
  public var shouldSuppressDisconnectedPill: Bool {
    connectionIntent.isUserDisconnected
  }

  /// Settings › Connections › Connect on Launch: whether `activate()` reconnects to the last
  /// radio. Off, launch leaves the intent unset, so neither the foreground return nor the
  /// watchdog reaches for the radio until the user connects; from then on, as ever.
  var connectsOnLaunch: Bool {
    defaults.object(forKey: AppStorageKey.connectOnLaunch.rawValue) as? Bool ?? AppStorageKey.defaultConnectOnLaunch
  }

  /// Most recent disconnect diagnostic summary persisted across app launches.
  public var lastDisconnectDiagnostic: String? {
    lastConnectionStore.disconnectDiagnostic
  }

  /// Current high-level connection intent, exported for diagnostics.
  public var connectionIntentSummary: String {
    switch connectionIntent {
    case .none:
      "none"
    case .userDisconnected:
      "userDisconnected"
    case let .wantsConnection(forceFullSync):
      forceFullSync ? "wantsConnection(forceFullSync: true)" : "wantsConnection"
    }
  }

  /// Whether the last connection was a simulator connection
  public var wasSimulatorConnection: Bool {
    lastConnectedDeviceID == MockDataProvider.simulatorDeviceID
  }

  /// Set when `activate()` begins.
  var launchActivationStarted = false

  /// Whether a WiFi disconnection is currently being handled (prevents interleaving
  /// across await suspension points before wifiReconnectTask is set).
  var isHandlingWiFiDisconnection = false

  // MARK: - Cancellation Helpers

  /// Cancels any in-progress WiFi reconnection attempts
  func cancelWiFiReconnection() {
    wifiReconnectTask?.cancel()
    wifiReconnectTask = nil
    wifiReconnectAttempt = 0
    isWiFiReconnectBackingOff = false
  }

  // MARK: - Initialization

  /// Creates a new connection manager.
  /// - Parameters:
  ///   - modelContainer: The SwiftData model container for persistence
  ///   - stateMachine: Optional BLE state machine for testing. If nil, creates a real BLEStateMachine.
  ///   - transport: Optional iOS mesh transport for testing. If nil, creates an `iOSBLETransport` against the chosen state machine.
  ///   - pairing: Optional pairing service for testing. If nil, `DevicePairingFactory` selects the platform implementation.
  public init(
    modelContainer: ModelContainer,
    defaults: UserDefaults = .standard,
    stateMachine: (any BLEStateMachineProtocol)? = nil,
    transport: (any iOSMeshTransport)? = nil,
    pairing: (any DevicePairingService)? = nil
  ) {
    self.modelContainer = modelContainer
    persistenceStore = PersistenceStore(modelContainer: modelContainer)
    self.defaults = defaults
    channelSyncRecordsImportGeneration = defaults.integer(forKey: PersistenceKeys.channelRowsImportGeneration)
    lastConnectionStore = LastConnectionStore(defaults: defaults)
    backgroundWiFiGate = BackgroundWiFiApprovalGate(defaults: defaults)
    connectionIntent = .restored(from: defaults)

    // Use provided state machine or create default
    let bleStateMachine = stateMachine ?? BLEStateMachine()
    self.stateMachine = bleStateMachine

    if let injected = transport {
      self.transport = injected
    } else if let concrete = bleStateMachine as? BLEStateMachine {
      self.transport = iOSBLETransport(stateMachine: concrete)
    } else {
      // Test mode without an injected transport: create a dummy (unused when mocking BLE)
      self.transport = iOSBLETransport(stateMachine: BLEStateMachine())
    }

    self.pairing = pairing ?? DevicePairingFactory.make()

    self.pairing.delegate = self
    reconnectionCoordinator.delegate = self

    // Best-effort early wiring. activate() awaits the same idempotent
    // method before constructing the CBCentralManager, which is the
    // ordering guarantee; this Task just installs handlers promptly for
    // flows that touch the state machine before activate() runs.
    Task { await self.wireTransportHandlers() }
  }

  /// Wires the transport and state-machine lifecycle handlers.
  ///
  /// Must complete before anything constructs the CBCentralManager:
  /// creating the central can synchronously fire state-restoration
  /// callbacks, and a missed auto-reconnect or reconnection handler at
  /// launch leaves the restored link without a session rebuild. Idempotent;
  /// re-installing the same handlers is harmless.
  func wireTransportHandlers() async {
    let stateMachine = stateMachine
    let transport = transport

    // Handle disconnection events
    await transport.setDisconnectionHandler { [weak self] deviceID, error in
      Task { @MainActor in
        guard let self else { return }
        await self.handleConnectionLoss(deviceID: deviceID, error: error)
      }
    }

    // A bond verified in a previous launch must still shield an exhausted
    // encryption-timeout budget, so seed the persisted verification before
    // any teardown classification can run. Keyed off the bond slot, not the
    // connection slot: a WiFi connection overwrites the latter without
    // touching the bond.
    if let deviceID = lastConnectionStore.bondVerifiedDeviceID,
       let verified = lastConnectionStore.bondVerificationDate(for: deviceID) {
      await stateMachine.recordBondVerification(deviceID: deviceID, at: verified)
    }

    // Handle entering auto-reconnecting phase
    await stateMachine.setAutoReconnectingHandler { [weak self] (deviceID: UUID, errorInfo: String) in
      Task { @MainActor in
        guard let self else { return }

        // A radio on WiFi owns the link: claiming the cycle below would tear the WiFi
        // session down for a BLE link nobody asked for. Cancel the BLE side instead.
        if self.currentTransportType == .wifi {
          guard self.connectionState == .disconnected, self.connectionAttemptTransport == nil else {
            self.logger.info(
              "[BLE] Auto-reconnect entry for \(deviceID.uuidString.prefix(8)) cancelled: WiFi owns the link (state: \(String(describing: self.connectionState)))"
            )
            await self.transport.disconnect()
            return
          }
          // WiFi is waiting between reconnect attempts: the BLE link that came back wins,
          // and the WiFi loop stands down so it cannot stop the BLE session later.
          self.logger.info("[BLE] Auto-reconnect entry for \(deviceID.uuidString.prefix(8)) taking over from the WiFi reconnect backoff")
          await self.releaseWiFiForBLEConnect()
          self.currentTransportType = .bluetooth
        }

        if self.shouldDeferOpportunisticReconnect {
          self.logger.info(
            "[BLE] Auto-reconnect entry suppressed for \(deviceID.uuidString.prefix(8)) (pairing in progress) — tearing down stale session"
          )
          // Skip the reconnect-cycle claim and UI timeout (pairing's
          // connect(to:) ceremony owns the next state transitions),
          // but tear down the prior session so a pairing early-exit
          // path doesn't strand the UI on stale `.ready` state.
          await self.handleConnectionLoss(deviceID: deviceID, error: nil)
          return
        }

        if let manualConnectDeviceID = self.connectingDeviceID {
          guard manualConnectDeviceID == deviceID else {
            self.logger.info(
              "[BLE] Auto-reconnect entry for \(deviceID.uuidString.prefix(8)) standing down: manual connect in flight for \(manualConnectDeviceID.uuidString.prefix(8))"
            )
            return
          }
          // The dropped link belongs to the in-flight manual connect. Release
          // its claim so the retry loop bails out instead of disconnecting the
          // transport — that would cancel the OS pending connect recovering
          // this link and leave a reconnect-cycle claim no completion can ever
          // clear, silently disabling the watchdog, the foreground health
          // check, and power-on recovery. The cycle claimed below owns
          // teardown, the UI timeout, and the session rebuild from here.
          self.logger.info("[BLE] Auto-reconnect entry adopting in-flight manual connect for \(deviceID.uuidString.prefix(8))")
          self.connectingDeviceID = nil
          self.invalidateConnectionAttempt()
        }

        // Snapshot pre-claim state before entering — handleEnteringAutoReconnect
        // mutates connectionState to .connecting before its first await.
        let initialState = String(describing: self.connectionState)
        let transportName = switch self.currentTransportType {
        case .bluetooth: "bluetooth"
        case .wifi: "wifi"
        case nil: "none"
        }

        // Claim before the state-machine queries below. Without this,
        // a state-restoration adoption where iOS callbacks land within
        // microseconds of each other can fire onReconnection while these
        // awaits are still queued, and the strict completion guard would
        // drop the completion since reconnectingDeviceID is still nil.
        await self.reconnectionCoordinator.handleEnteringAutoReconnect(deviceID: deviceID)

        let diagnostics = await self.stateMachine.linkDiagnostics
        let bleState = diagnostics.centralState
        let blePhase = diagnostics.phase
        let blePeripheralState = diagnostics.peripheralState ?? "none"

        self.persistDisconnectDiagnostic(
          "source=bleStateMachine.autoReconnectingHandler, " +
            "device=\(deviceID.uuidString.prefix(8)), " +
            "transport=\(transportName), " +
            "initialState=\(initialState), " +
            "bleState=\(bleState), " +
            "blePhase=\(blePhase), " +
            "blePeripheralState=\(blePeripheralState), " +
            "error=\(errorInfo), " +
            "intent=\(self.connectionIntent)"
        )
      }
    }

    // Handle iOS auto-reconnect completion
    // Using transport.setReconnectionHandler ensures the transport captures
    // the data stream internally before calling our handler
    await transport.setReconnectionHandler { [weak self] deviceID in
      Task { @MainActor in
        guard let self else { return }
        await self.reconnectionCoordinator.handleReconnectionComplete(deviceID: deviceID)
      }
    }

    // RSSI bond refresh runs on the state-machine actor; persist on MainActor
    // via epoch-gated re-validation so a clear between shouldPersist and the
    // UserDefaults write cannot resurrect a forgotten cross-launch shield.
    await stateMachine.setBondRefreshedHandler { [weak self] deviceID in
      Task { @MainActor in
        guard let self else { return }
        await self.persistBondRefreshIfStillValid(deviceID: deviceID)
      }
    }

    // A notification is what wakes a suspended app: use the wake to repair an app stack that
    // died while the link stayed up, or a sync left failed in the background.
    await stateMachine.setLinkActivityHandler { [weak self] in
      Task { @MainActor in
        await self?.handleLinkActivity()
      }
    }

    // Handle Bluetooth power-cycle recovery
    await stateMachine.setBluetoothPoweredOnHandler { [weak self] in
      Task { @MainActor in
        guard let self,
              self.connectionIntent.wantsConnection,
              self.currentTransportType != .wifi else { return }

        if self.shouldDeferOpportunisticReconnect {
          self.logger.info("[BLE] Bluetooth powered on: standing down (pairing in progress)")
          return
        }

        // Launch, a user connect, or a device switch owns the next attempt.
        if self.isExplicitConnectInFlight {
          self.logger.info("[BLE] Bluetooth powered on: standing down (explicit connect in flight)")
          return
        }

        guard let deviceID = await self.lastRadioBluetoothPeripheralID() else { return }

        let blePhase = await self.stateMachine.linkDiagnostics.phase
        let bleConnectedDeviceID = await self.stateMachine.connectedDeviceID
        if blePhase != .idle || bleConnectedDeviceID == deviceID {
          self.logger.info(
            "[BLE] Bluetooth powered on: BLE already owns reconnect flow for \(deviceID.uuidString.prefix(8)) " +
              "(phase: \(blePhase), bleConnectedDevice: \(bleConnectedDeviceID?.uuidString.prefix(8) ?? "none"))"
          )
          return
        }

        if let activeID = self.activeConnectionAttemptDeviceID {
          self.logger.info("[BLE] Bluetooth powered on: reconnect/session rebuild already in progress for \(activeID.uuidString.prefix(8))")
          return
        }

        // Back from a bluetoothd reset the state machine has settled in idle (it tears down
        // a link the stack dropped without a didDisconnect), while the app can still show
        // the old connection as live. Reconcile that before reconnecting.
        if self.connectionState != .disconnected {
          guard self.connectionState.isConnected else { return }
          self.logger.warning(
            "[BLE] Bluetooth powered on: app shows \(String(describing: self.connectionState)) but the BLE link is idle; treating it as lost"
          )
          await self.handleConnectionLoss(deviceID: self.connectedDevice?.id ?? deviceID, error: nil)
          guard self.connectionIntent.wantsConnection, self.connectionState == .disconnected else { return }
        }

        self.logger.info("[BLE] Bluetooth powered on: attempting reconnection to \(deviceID.uuidString.prefix(8))")
        await self.attemptOpportunisticReconnect(deviceID: deviceID, reason: "Bluetooth powered on")
      }
    }

    // Handle Bluetooth state changes for diagnostics
    await stateMachine.setBluetoothStateChangeHandler { [weak self] state in
      Task { @MainActor in
        guard let self else { return }
        self.handleBluetoothStateChange(state)
      }
    }
  }

  /// Wires the transport handlers and creates the Bluetooth central ahead of `activate()`.
  ///
  /// iOS relaunches the app in the background to deliver CoreBluetooth state restoration,
  /// and the restoration callback goes only to a central created with the restore
  /// identifier: one created minutes later, when a scene or the launch sequence first runs,
  /// finds nothing to restore and the radio's messages stop. The app delegate calls this
  /// from `application(_:didFinishLaunchingWithOptions:)`. The central is created only
  /// when Bluetooth access is already granted, so a first launch never shows the system
  /// prompt before onboarding explains it. Idempotent.
  public func prepareBluetoothCentral() async {
    #if !targetEnvironment(simulator)
      guard CBManager.authorization == .allowedAlways else {
        logger.info("[BLE] Early central skipped: Bluetooth access not granted yet")
        return
      }
      // Handlers before the central: creating it can deliver restoration at once.
      await wireTransportHandlers()
      // A late call (after activate() began) must not mark the launch as pending again.
      if !launchActivationStarted {
        isAwaitingLaunchActivation = true
      }
      await activatePairingSession()
      await stateMachine.activate()
      logger.info("[BLE] Central created ahead of launch for state restoration")
    #endif
  }

  /// Activates the pairing session once, awaiting the same run from every caller. On iOS
  /// this is AccessorySetupKit, which must be active before the central for iOS 26 state
  /// restoration; on macOS it is a no-op.
  func activatePairingSession() async {
    if let pairingActivationTask {
      await pairingActivationTask.value
      return
    }
    let task = Task { @MainActor in
      do {
        try await pairing.activate()
      } catch {
        logger.error("Failed to activate pairing session: \(error.localizedDescription)")
      }
    }
    pairingActivationTask = task
    await task.value
  }

  /// The Bluetooth peripheral to reconnect the last radio over. The last connection's device
  /// ID is not always one: a radio last reached over WiFi carries an ID derived from its key,
  /// which CoreBluetooth cannot resolve, so the radio's stored Bluetooth method is preferred.
  /// Nil when the radio has connection methods but no Bluetooth one (a WiFi-only radio);
  /// the device ID itself when no record or methods say otherwise.
  func lastRadioBluetoothPeripheralID() async -> UUID? {
    guard let deviceID = lastConnectedDeviceID else { return nil }
    guard let device = try? await persistenceStore.fetchDevice(id: deviceID),
          !device.connectionMethods.isEmpty else {
      return deviceID
    }
    return device.connectionMethods.compactMap(\.bluetoothPeripheralID).first
  }

  // MARK: - Session Helpers

  /// Starts a session and queries device capabilities.
  /// - Parameter appStartTimeout: How long the opening APP_START waits for the radio's answer;
  ///   nil waits the session's default within a 10 s start.
  func initializeSession(
    _ session: MeshCoreSession,
    appStartTimeout: TimeInterval? = nil
  ) async throws -> (SelfInfo, DeviceCapabilities) {
    // The start covers the transport and the APP_START: a longer APP_START wait stretches it.
    let startLimit = appStartTimeout.map { $0 + 10 } ?? 10
    do {
      try await withTimeout(.seconds(startLimit), operationName: "session.start") {
        try await session.start(appStartTimeout: appStartTimeout)
      }
    } catch {
      logger.warning("[BLE] session.start() timed out or failed: \(error.localizedDescription)")
      throw error
    }

    guard let selfInfo = await session.currentSelfInfo else {
      logger.warning("[BLE] selfInfo is nil after session.start()")
      throw ConnectionError.initializationFailed("Failed to get device self info")
    }
    do {
      let capabilities = try await withTimeout(.seconds(10), operationName: "queryDevice") {
        try await session.queryDevice()
      }
      return (selfInfo, capabilities)
    } catch {
      logger.warning("[BLE] queryDevice() timed out or failed: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Service Wiring Helpers

  /// The radio whose channel table the store holds a complete, clean copy of, kept across
  /// launches (`PersistenceKeys.verifiedChannelTableRadioID`).
  ///
  /// `lastCleanChannelSync` lives in memory, so a process iOS started in the background (Bluetooth
  /// state restoration, the wake source's pending connect, a Background App Refresh run) had no
  /// record and the user's next open read every channel slot, though the stored copy still
  /// matched. With this marker a connect that runs its channel phase in the background, and the
  /// foreground sync it leaves pending, check the stored copy (`verifyChannels`) first. It never
  /// feeds the skip windows, and a foreground connect of a new process still reads every slot.
  /// Removed when a full channel read that did not finish cleanly changed the stored table (set
  /// again only when one finishes cleanly), on explicit disconnects, device switch, forget, and
  /// backup import. A read that threw or changed nothing keeps it: the stored copy is unchanged.
  var verifiedChannelTableRadioID: UUID? {
    get { defaults.string(forKey: PersistenceKeys.verifiedChannelTableRadioID).flatMap(UUID.init(uuidString:)) }
    set {
      if let newValue {
        guard newValue != verifiedChannelTableRadioID else { return }
        defaults.set(newValue.uuidString, forKey: PersistenceKeys.verifiedChannelTableRadioID)
      } else if defaults.object(forKey: PersistenceKeys.verifiedChannelTableRadioID) != nil {
        defaults.removeObject(forKey: PersistenceKeys.verifiedChannelTableRadioID)
      }
    }
  }

  /// Forgets every clean-channel record, in memory and persisted: the next connect reads every slot.
  func clearCleanChannelSyncRecords() {
    lastCleanChannelSync = nil
    lastAttemptedChannelSync = nil
    verifiedChannelTableRadioID = nil
  }

  /// Forgets the in-memory clean and attempted channel sync records when a backup import
  /// (`AppBackupService.importBackup`) rewrote the stored channel rows since they were made: the
  /// import cannot reach this manager, so it bumps `PersistenceKeys.channelRowsImportGeneration`
  /// and removes the persisted marker. Without this, a reconnect inside either skip window would
  /// skip the channel phase and never check the imported rows against the radio.
  func dropChannelSyncRecordsPredatingImport() {
    let importGeneration = defaults.integer(forKey: PersistenceKeys.channelRowsImportGeneration)
    guard importGeneration != channelSyncRecordsImportGeneration else { return }
    channelSyncRecordsImportGeneration = importGeneration
    lastCleanChannelSync = nil
    lastAttemptedChannelSync = nil
  }

  /// A full channel read of `radioID` changed the stored table but did not finish cleanly:
  /// fresh and old rows are mixed, so neither clean record may vouch for it until a clean read.
  func withdrawChannelTableTrust(radioID: UUID) {
    if lastCleanChannelSync?.radioID == radioID {
      lastCleanChannelSync = nil
    }
    if verifiedChannelTableRadioID == radioID {
      verifiedChannelTableRadioID = nil
    }
  }

  /// Wires the clean-channel-sync callback on a new ServiceContainer so that
  /// `lastCleanChannelSync` is updated when a channel phase completes without errors.
  /// Called from every path that creates a new ServiceContainer.
  func wireCleanChannelSyncCallback(on services: ServiceContainer) async {
    await services.syncCoordinator.setCleanChannelSyncCallback { [weak self] radioID in
      await MainActor.run {
        self?.lastCleanChannelSync = (radioID: radioID, completedAt: Date())
        self?.verifiedChannelTableRadioID = radioID
      }
    }
    await services.syncCoordinator.setChannelTableTrustWithdrawnCallback { [weak self] radioID in
      await MainActor.run {
        self?.withdrawChannelTableTrust(radioID: radioID)
      }
    }
    await services.syncCoordinator.setChannelSyncAttemptedCallback { [weak self] radioID in
      await MainActor.run {
        self?.lastAttemptedChannelSync = (radioID: radioID, attemptedAt: Date())
      }
    }
  }

  // MARK: - Connection Ceremony

  /// Builds a fresh ServiceContainer, fetches device configuration from the radio
  /// and database, builds and persists the device record, and updates self.
  ///
  /// Each connection path (BLE, WiFi, reconnect, device switch) calls this after
  /// its transport and session are established. Post-ceremony work (sync, promote,
  /// cleanup) remains in each caller since it genuinely varies.
  ///
  /// - Parameter isStillOwner: Re-checked after the awaits, before the device record is
  ///   written and again before `services`, `session`, and `connectedDevice` are assigned.
  ///   When it fails the container built here is torn down, nothing is assigned, and
  ///   `CancellationError` is thrown: a disconnect or a newer attempt that
  ///   landed during the build must not find this attempt's stack installed over it.
  /// - Returns: The wired `ServiceContainer` for the caller's sync phase.
  func buildServicesAndSaveDevice(
    deviceID: UUID,
    session: MeshCoreSession,
    selfInfo: SelfInfo,
    capabilities: DeviceCapabilities,
    connectionMethods: [ConnectionMethod] = [],
    isStillOwner: () -> Bool = { true }
  ) async throws -> (services: ServiceContainer, radioID: UUID) {
    // Kick off `getAutoAddConfig` up-front so the BLE roundtrip overlaps
    // with the local DB fetches and container wiring below.
    async let autoAddConfigResult = session.getAutoAddConfig()

    // Resolve the radio before constructing the container so the
    // chat send queue can scope its `PendingSend` hydration to the
    // right radio from frame zero. Falls back to publicKey lookup
    // (backup import) and finally to a fresh UUID for first-time
    // pairings.
    let existingDevice = try? await persistenceStore.fetchDevice(id: deviceID)
    let deviceByPublicKey: DeviceDTO? = if existingDevice == nil {
      try? await persistenceStore.fetchDevice(publicKey: selfInfo.publicKey)
    } else {
      nil
    }
    let effectiveExisting = existingDevice ?? deviceByPublicKey
    let resolvedRadioID = effectiveExisting?.radioID ?? UUID()

    let newServices = ServiceContainer(
      session: session,
      dataStore: persistenceStore,
      radioID: resolvedRadioID,
      appStateProvider: appStateProvider,
      connectionStateEvents: connectionStateEvents,
      initialConnectionState: connectionState
    )
    await wireCleanChannelSyncCallback(on: newServices)
    await newServices.nodeConfigService.setOnPostIdentityImport { [weak self, weak newServices] in
      guard let self, let services = newServices else { return nil }
      return try await reconcileIdentity(expectedServices: services, deviceID: deviceID)
    }

    let autoAddConfig = await (try? autoAddConfigResult) ?? MeshCore.AutoAddConfig(bitmask: 0)

    let repeatFreqRanges: [MeshCore.FrequencyRange] = await capabilities.clientRepeat
      ? (try? session.getRepeatFreq()) ?? []
      : []

    let device = createDevice(
      deviceID: deviceID,
      radioID: resolvedRadioID,
      selfInfo: selfInfo,
      capabilities: capabilities,
      autoAddConfig: autoAddConfig,
      existingDevice: effectiveExisting,
      connectionMethods: connectionMethods
    )

    let deviceDTO = DeviceDTO(from: device)
    guard isStillOwner() else {
      await newServices.tearDown()
      throw CancellationError()
    }
    // Persist before warmUp so purgeOrphanPendingSends sees the in-progress
    // radio's Device row and does not classify its PendingSends as orphans.
    logger.info("Radio at connect: BLE PIN \(deviceDTO.blePinKindForLog), app last knew \(effectiveExisting?.blePinKindForLog ?? "nothing")")
    try await newServices.dataStore.saveDevice(deviceDTO)

    // The same radio, first reached over another transport: one record now, and the app says so.
    if let notice = SavedRadioLink.notice(
      existingByID: existingDevice,
      existingByKey: deviceByPublicKey,
      newDeviceID: deviceID,
      newMethods: connectionMethods,
      radioName: selfInfo.name
    ) {
      linkedRadioNotice = notice
    }

    // Clean up orphaned Device row from backup import
    if let oldDevice = deviceByPublicKey, oldDevice.id != deviceID {
      try? await newServices.dataStore.deleteDevice(id: oldDevice.id)
    }

    // Run startup-time DB hygiene before hydrating the send queue.
    // warmUp's purgeOrphanPendingSends is best-effort; failure is non-fatal.
    do {
      try await newServices.warmUp()
    } catch {
      logger.warning("ServiceContainer.warmUp failed: \(error.localizedDescription)")
    }

    // Hydrate the chat send queue before exposing the container so
    // view-model `configure` calls see a hydrated service from the
    // first read.
    await newServices.chatSendQueueService.hydrate()

    guard isStillOwner() else {
      logger.info("Connection superseded while its services were built; discarding them")
      await newServices.tearDown()
      throw CancellationError()
    }

    // Restore `self.session` together with `self.services`: an interleaved
    // `handleConnectionLoss` nils both atomically, and `promoteToReady`'s
    // state invariants require both.
    self.session = session
    services = newServices

    connectedDevice = deviceDTO
    allowedRepeatFreqRanges = repeatFreqRanges

    return (newServices, deviceDTO.radioID)
  }

  // MARK: - Ready Promotion

  /// Promotes connection to `.ready` if the connection is still alive and owned by the expected services.
  /// Skips post-sync work (time sync, onDeviceSynced) when sync failed to avoid BLE pressure.
  /// Returns `true` if `.ready` was set, `false` if promotion was suppressed.
  ///
  /// - Parameter additionalGuard: Caller-specific invariant checked at every guard point,
  ///   including after async operations like `syncDeviceTimeIfNeeded()`. This cannot be an
  ///   inline check at the call site because the invariant must hold both before and after
  ///   the internal awaits — a competing reconnect cycle could start during time sync,
  ///   and promoting a stale session to `.ready` would shadow the new one.
  ///   Currently only `rebuildSession` uses this (reconnect-generation check).
  @discardableResult
  func promoteToReady(
    syncSucceeded: Bool,
    expectedServices: ServiceContainer,
    transportType: TransportType,
    additionalGuard: (() -> Bool)? = nil
  ) async -> Bool {
    guard connectionIntent.wantsConnection else {
      logger.warning("Promotion suppressed: user disconnected")
      return false
    }
    guard services === expectedServices else {
      logger.warning("Promotion suppressed: services replaced or nil")
      return false
    }
    guard additionalGuard?() ?? true else {
      logger.warning("Promotion suppressed: caller guard failed (e.g. reconnect generation)")
      return false
    }

    currentTransportType = transportType
    connectionState = syncSucceeded ? .ready : .syncing
    surfacedAuthFailureDeviceID = nil

    // Skip time sync on BLE failure to avoid pressure on a saturated link.
    // WiFi/TCP has no such constraint, so always correct the clock there.
    if syncSucceeded || transportType == .wifi {
      await syncDeviceTimeIfNeeded()
      guard connectionIntent.wantsConnection else {
        logger.warning("Promotion suppressed after time sync: user disconnected")
        return false
      }
      guard services === expectedServices else {
        logger.warning("Promotion suppressed after time sync: services replaced or nil")
        return false
      }
      guard additionalGuard?() ?? true else {
        logger.warning("Promotion suppressed after time sync: caller guard failed (e.g. reconnect generation)")
        return false
      }
    }

    if syncSucceeded { await onDeviceSynced?() }
    return true
  }

  /// Re-evaluates the connected device's identity after `NodeConfigService.importIdentity`
  /// has restored a privateKey on the radio. If the radio is now reporting a different
  /// `publicKey` than the local Device row, attempts to reconcile against any ghost
  /// carrying that publicKey (left by a prior "remove from Cairn").
  ///
  /// Mirrors the `promoteToReady` lifecycle pattern: takes the `ServiceContainer`
  /// the caller expects to still own, plus the `deviceID` it expects to still be
  /// connected to. Bails out (returns `nil`) if either invariant fails before or
  /// after the `currentSelfInfo` await — a competing reconnect cycle could otherwise
  /// reconcile state onto the wrong connection.
  ///
  /// - Parameters:
  ///   - expectedServices: The `ServiceContainer` captured at the start of the
  ///     config-import operation. If `self.services` no longer points to it, the
  ///     reconcile is silently skipped.
  ///   - deviceID: The BLE peripheral UUID the import was started against.
  /// - Returns: The new `radioID` if reconciliation reassigned the device,
  ///   otherwise `nil` (no publicKey change, no matching ghost, or a guard tripped).
  @discardableResult
  public func reconcileIdentity(
    expectedServices: ServiceContainer,
    deviceID: UUID
  ) async throws -> UUID? {
    guard services === expectedServices else {
      logger.info("reconcileIdentity skipped: services replaced before currentSelfInfo")
      return nil
    }
    guard let preDevice = connectedDevice, preDevice.id == deviceID else {
      logger.info("reconcileIdentity skipped: connectedDevice changed before currentSelfInfo")
      return nil
    }
    let previousSelfPublicKey = preDevice.publicKey
    let previousRadioID = preDevice.radioID

    let selfInfo: MeshCore.SelfInfo
    do {
      guard let info = await expectedServices.session.currentSelfInfo else {
        logger.warning("reconcileIdentity failed: session.currentSelfInfo is nil")
        return nil
      }
      selfInfo = info
    }

    guard services === expectedServices else {
      logger.info("reconcileIdentity skipped: services replaced after currentSelfInfo")
      return nil
    }
    guard connectedDevice?.id == deviceID else {
      logger.info("reconcileIdentity skipped: connectedDevice changed after currentSelfInfo")
      return nil
    }

    // No publicKey-equality short-circuit: after a partial-import + app restart,
    // `buildServicesAndSaveDevice` finds the Device by BLE UUID and overwrites
    // `Device.publicKey` with the restored key via `Device.apply(dto:)`. On the
    // user's retry, `selfInfo.publicKey == connectedDevice.publicKey` even though
    // `radioID` is still stale. Always ask `reconcileGhostIdentity` — its
    // predicate handles the no-ghost case by returning nil, so the cost of an
    // unconditional query is one cheap DB lookup per import.

    let newRadioID: UUID?
    do {
      newRadioID = try await expectedServices.dataStore.reconcileGhostIdentity(
        currentDeviceID: deviceID,
        newPublicKey: selfInfo.publicKey
      )
    } catch {
      logger.warning("reconcileIdentity: reconcileGhostIdentity failed: \(error.localizedDescription)")
      return nil
    }

    // Drop the local ZephCore V-contact derived from the previous self key when
    // identity rotates; the new V-key arrives on the next contact sync. It was synced
    // under the pre-reconcile partition, and ghost reconciliation re-keys only the
    // Device row, never contacts, so it always lives under previousRadioID.
    if previousSelfPublicKey != selfInfo.publicKey {
      await dropStaleVContact(
        dataStore: expectedServices.dataStore,
        radioID: previousRadioID,
        oldSelfPublicKey: previousSelfPublicKey
      )
    }

    guard let newRadioID else {
      logger.info("reconcileIdentity: publicKey changed but no ghost matched")
      return nil
    }

    // Final guard: the DB save just ran on a background actor; the connection
    // could still have churned. Only mutate live state if the captured container
    // is still authoritative.
    guard services === expectedServices, connectedDevice?.id == deviceID else {
      logger.info("reconcileIdentity: state churned after DB save; skipping in-memory refresh")
      return newRadioID
    }
    if let refreshed = try? await expectedServices.dataStore.fetchDevice(id: deviceID),
       services === expectedServices,
       connectedDevice?.id == deviceID {
      connectedDevice = refreshed
      persistConnection(
        deviceID: refreshed.id,
        radioID: refreshed.radioID,
        deviceName: refreshed.nodeName
      )
    }

    logger.info("Reconciled identity to ghost radioID after key import: \(newRadioID)")
    return newRadioID
  }

  /// Removes a local contact row for the V-contact derived from a retired self public key.
  private func dropStaleVContact(
    dataStore: PersistenceStore,
    radioID: UUID,
    oldSelfPublicKey: Data
  ) async {
    guard let oldVKey = VContactIdentity.publicKey(forSelfPublicKey: oldSelfPublicKey) else { return }
    do {
      guard let contact = try await dataStore.fetchContact(radioID: radioID, publicKey: oldVKey) else {
        return
      }
      try await dataStore.deleteContact(id: contact.id)
      logger.info("Dropped stale ZephCore V-contact after identity rotation")
    } catch {
      logger.warning("Failed to drop stale V-contact after identity rotation: \(error.localizedDescription)")
    }
  }

  /// Setting the radio clock backward makes its request timestamps fall below
  /// the `last_timestamp` remote repeaters recorded for it, and their replay
  /// protection then silently drops every packet until the clock re-passes the
  /// stored value. A tight tolerance keeps each backward step, and therefore
  /// each deaf window, no longer than the tolerance itself, while still
  /// recovering radios whose clocks are stuck far in the future.
  private static let deviceClockDriftTolerance: TimeInterval = 5

  /// Syncs the device clock when it drifts beyond `deviceClockDriftTolerance`.
  func syncDeviceTimeIfNeeded() async {
    guard let session else { return }
    do {
      let deviceTime = try await withTimeout(.seconds(5), operationName: "getTime") {
        try await session.getTime()
      }
      let timeDifference = abs(deviceTime.timeIntervalSinceNow)
      if timeDifference > Self.deviceClockDriftTolerance {
        try await withTimeout(.seconds(5), operationName: "setTime") {
          try await session.setTime(Date())
        }
        logger.info("Synced device time (was off by \(Int(timeDifference))s)")
      } else {
        logger.info("Device time in sync (drift: \(Int(timeDifference))s)")
      }
    } catch {
      logger.warning("Failed to sync device time: \(error.localizedDescription)")
    }
    await syncDeviceTimeZoneIfNeeded()
  }

  /// UserDefaults key: the radio's clock zone follows the phone's (default on). Settings › Connection ›
  /// Clock turns it off for a radio that should keep a zone of its own.
  public static let deviceTimeZoneFollowsPhoneKey = "deviceTimeZoneFollowsPhone"

  /// Whether the radio clock's zone follows the phone's zone on every connect.
  public static var deviceTimeZoneFollowsPhone: Bool {
    UserDefaults.standard.object(forKey: deviceTimeZoneFollowsPhoneKey) as? Bool ?? true
  }

  /// Sets the radio clock's zone (`tz.offset`) to the phone's current offset when they differ, so a
  /// board's own screen shows the local time without anyone typing a zone into it. Nothing is sent
  /// when the firmware has no zone setting (stock MeshCore), when the zone already matches (a
  /// touch board's named zone with the same rule stays as chosen), or when following is off.
  func syncDeviceTimeZoneIfNeeded() async {
    guard Self.deviceTimeZoneFollowsPhone, let session else { return }
    let phoneMinutes = DeviceTimeZone.phoneOffsetMinutes()
    do {
      let reply = try await withTimeout(.seconds(5), operationName: "getTimeZone") {
        try await session.runCLICommand("get tz.offset")
      }
      guard let deviceMinutes = DeviceTimeZone.parseReply(reply) else {
        logger.info("Device has no clock zone setting (\(reply)); leaving it")
        return
      }
      guard deviceMinutes != phoneMinutes else { return }
      let setReply = try await withTimeout(.seconds(5), operationName: "setTimeZone") {
        try await session.runCLICommand("set tz.offset \(DeviceTimeZone.commandArgument(minutes: phoneMinutes))")
      }
      if case .ok = CLIResponse.parse(setReply) {
        logger.info("Synced device clock zone to \(DeviceTimeZone.label(minutes: phoneMinutes)) (was \(DeviceTimeZone.label(minutes: deviceMinutes)))")
      } else {
        logger.warning("Device refused clock zone \(phoneMinutes) min: \(setReply)")
      }
    } catch {
      logger.warning("Failed to sync device clock zone: \(error.localizedDescription)")
    }
  }

  /// Creates a Device from MeshCore types
  ///
  /// `radioID` is the resolved partition UUID for this device. Callers in
  /// the connect path must pass the same UUID they used to construct
  /// `ServiceContainer(radioID:)` so the chat send queue's `PendingSend`
  /// scope and the persisted `Device.radioID` cannot diverge on first pair.
  /// A bare `?? UUID()` fallback here would mint a second UUID that the
  /// container would never see.
  func createDevice(
    deviceID: UUID,
    radioID: UUID,
    selfInfo: MeshCore.SelfInfo,
    capabilities: MeshCore.DeviceCapabilities,
    autoAddConfig: MeshCore.AutoAddConfig,
    existingDevice: DeviceDTO? = nil,
    connectionMethods: [ConnectionMethod] = []
  ) -> Device {
    // Merge new connection methods with existing ones. Bluetooth is one peripheral, so a new one
    // replaces it. A radio on WiFi keeps every address it was reached at (a LAN address, a VPN one,
    // a hostname), the one in use now first: Connections offers each, and a launch tries them in
    // turn (`updateSavedWiFiAddresses` adds, changes and removes them from Connections).
    var mergedMethods = existingDevice?.connectionMethods ?? []
    for method in connectionMethods {
      if method.isWiFi {
        mergedMethods.removeAll { $0.id == method.id }
        mergedMethods.insert(method, at: mergedMethods.firstIndex(where: \.isWiFi) ?? mergedMethods.endIndex)
      } else if method.isBluetooth {
        mergedMethods.removeAll { $0.isBluetooth }
        mergedMethods.append(method)
      }
    }

    let device = Device(
      id: deviceID,
      radioID: radioID,
      publicKey: selfInfo.publicKey,
      nodeName: selfInfo.name,
      firmwareVersion: capabilities.firmwareVersion,
      firmwareVersionString: capabilities.version,
      manufacturerName: capabilities.model,
      buildDate: capabilities.firmwareBuild,
      maxContacts: UInt16(capabilities.maxContacts),
      maxChannels: UInt8(min(capabilities.maxChannels, 255)),
      frequency: selfInfo.radioFrequencyKHz,
      bandwidth: selfInfo.radioBandwidthHz,
      spreadingFactor: selfInfo.radioSpreadingFactor,
      codingRate: selfInfo.radioCodingRate,
      txPower: selfInfo.txPower,
      maxTxPower: selfInfo.maxTxPower,
      latitude: selfInfo.latitude,
      longitude: selfInfo.longitude,
      blePin: capabilities.blePin,
      clientRepeat: capabilities.clientRepeat,
      pathHashMode: capabilities.pathHashMode,
      defaultFloodScopeName: existingDevice?.defaultFloodScopeName,
      preRepeatFrequency: existingDevice?.preRepeatFrequency,
      preRepeatBandwidth: existingDevice?.preRepeatBandwidth,
      preRepeatSpreadingFactor: existingDevice?.preRepeatSpreadingFactor,
      preRepeatCodingRate: existingDevice?.preRepeatCodingRate,
      manualAddContacts: selfInfo.manualAddContacts,
      autoAddConfig: autoAddConfig.bitmask,
      autoAddMaxHops: autoAddConfig.maxHops,
      multiAcks: selfInfo.multiAcks,
      telemetryModeBase: selfInfo.telemetryModeBase,
      telemetryModeLoc: selfInfo.telemetryModeLocation,
      telemetryModeEnv: selfInfo.telemetryModeEnvironment,
      advertLocationPolicy: selfInfo.advertisementLocationPolicy,
      lastConnected: Date(),
      lastContactSync: existingDevice?.lastContactSync ?? 0,
      isActive: true,
      ocvPreset: existingDevice?.ocvPreset
        ?? OCVPreset.preset(forManufacturer: capabilities.model)?.rawValue,
      appliedRadioPresetID: existingDevice?.appliedRadioPresetID,
      customOCVArrayString: existingDevice?.customOCVArrayString,
      connectionMethods: mergedMethods,
      knownRegions: existingDevice?.knownRegions ?? []
    )
    device.cairnBuild = capabilities.cairnBuild

    // If repeat mode was disabled externally, clear orphaned pre-repeat settings
    if !capabilities.clientRepeat, existingDevice?.preRepeatFrequency != nil {
      device.preRepeatFrequency = nil
      device.preRepeatBandwidth = nil
      device.preRepeatSpreadingFactor = nil
      device.preRepeatCodingRate = nil
    }

    return device
  }

  /// Configures BLE write pacing based on detected device platform.
  /// - Parameter capabilities: The device capabilities from queryDevice()
  func configureBLEPacing(for capabilities: MeshCore.DeviceCapabilities) async {
    detectAndStorePlatform(model: capabilities.model, transportType: .bluetooth)
    let pacing = DevicePlatform.writePacing(
      for: detectedPlatform, model: capabilities.model, isCairnFirmware: capabilities.cairnBuild != nil
    )
    await stateMachine.setWritePacingDelay(pacing)
    if pacing > 0 {
      logger.info("[BLE] Platform detected: \(capabilities.model) -> \(detectedPlatform), write pacing: \(pacing)s")
    }
  }

  /// Detects and stores the device platform from its model string, used for
  /// channel-sync throttling and (over BLE) write pacing.
  ///
  /// A WiFi radio is always ESP32-class — no nRF52 part ships a WiFi radio, and the
  /// WiFi companion firmware is ESP32-only — so an unrecognized model on WiFi resolves
  /// to `.esp32` rather than `.unknown`. Without this, WiFi radios would keep the
  /// no-skip `.unknown` config and re-read all channels on every sync. BLE keeps the
  /// conservative `.unknown` fallback, which drives its ESP32-safe write pacing.
  ///
  /// Lives here rather than in the BLE/WiFi extensions because `detectedPlatform` has a
  /// `private(set)` setter that only this file can write.
  func detectAndStorePlatform(model: String, transportType: TransportType) {
    var platform = DevicePlatform.detect(from: model)
    if transportType == .wifi, platform == .unknown {
      platform = .esp32
    }
    detectedPlatform = platform
    if transportType == .wifi {
      logger.info("[WiFi] Platform detected: \(model) -> \(platform)")
    }
  }

  // MARK: - Cleanup

  /// Cleans up session and services without changing connection state (used during retries)
  func cleanupResources() async {
    // Capture and clear before the awaits: a connect that claims the link during them
    // installs its own session and services, which re-reading self would stop.
    let oldSession = session
    let oldServices = services
    session = nil
    services = nil
    // stop() at its default disconnects the transport — the explicit-disconnect
    // and device-switch paths rely on this call to sever the link.
    await oldSession?.stop()
    await oldServices?.tearDown()
  }

  /// Full cleanup including state reset (used on explicit disconnect)
  /// Callers on a connect path must still own their attempt: this clears whatever
  /// connection is current, not one particular attempt's objects.
  func cleanupConnection() async {
    logger.info("[BLE] cleanupConnection: state → .disconnected")
    connectionState = .disconnected
    connectingDeviceID = nil
    connectedDevice = nil
    allowedRepeatFreqRanges = []
    await cleanupResources()
  }

  func persistDisconnectDiagnostic(_ summary: String) {
    lastConnectionStore.persistDisconnectDiagnostic(summary)
  }

  func persistIntent() {
    connectionIntent.persist(to: defaults)
  }

  // MARK: - State Invariants

  #if DEBUG
    private var suppressInvariantChecks = false

    private func assertStateInvariants() {
      guard !suppressInvariantChecks else { return }
      switch connectionState {
      case .ready, .syncing:
        assert(services != nil, "Invariant: \(connectionState) requires services")
        assert(session != nil, "Invariant: \(connectionState) requires session")
        assert(connectedDevice != nil, "Invariant: \(connectionState) requires connectedDevice")
      case .connected, .disconnected, .connecting:
        break
      }
      if connectionIntent.isUserDisconnected {
        assert(connectionState == .disconnected, "Invariant: .userDisconnected requires .disconnected state")
      }
    }
  #endif

  // MARK: - Test Helpers

  #if DEBUG
    /// Sets the circuit breaker to `.open` with a chosen timestamp so tests can
    /// cross the cooldown boundary without waiting out the real cooldown.
    func setCircuitBreakerOpenForTesting(since: Date) {
      circuitBreaker = .open(since: since)
    }

    /// Sets internal state for testing. Only available in DEBUG builds.
    func setTestState(
      connectionState: DeviceConnectionState? = nil,
      services: ServiceContainer?? = nil,
      session: MeshCoreSession?? = nil,
      connectedDevice: DeviceDTO?? = nil,
      currentTransportType: TransportType?? = nil,
      connectionIntent: ConnectionIntent? = nil,
      connectingDeviceID: UUID?? = nil,
      sessionRebuildDeviceID: UUID?? = nil,
      isPairingInProgress: Bool? = nil,
      isPairingFlowActive: Bool? = nil,
      detectedPlatform: DevicePlatform? = nil,
      lastCleanChannelSync: (radioID: UUID, completedAt: Date)?? = nil,
      lastAttemptedChannelSync: (radioID: UUID, attemptedAt: Date)?? = nil
    ) {
      suppressInvariantChecks = true
      defer { suppressInvariantChecks = false }

      if let state = connectionState {
        self.connectionState = state
      }
      if let svc = services {
        self.services = svc
      }
      if let sess = session {
        self.session = sess
      }
      if let device = connectedDevice {
        self.connectedDevice = device
      }
      if let transport = currentTransportType {
        self.currentTransportType = transport
      }
      if let intent = connectionIntent {
        self.connectionIntent = intent
      }
      if let deviceID = connectingDeviceID {
        self.connectingDeviceID = deviceID
      }
      if let deviceID = sessionRebuildDeviceID {
        self.sessionRebuildDeviceID = deviceID
      }
      if let pairing = isPairingInProgress {
        self.isPairingInProgress = pairing
      }
      if let pairingFlow = isPairingFlowActive {
        self.isPairingFlowActive = pairingFlow
      }
      if let platform = detectedPlatform {
        self.detectedPlatform = platform
      }
      if let cleanSync = lastCleanChannelSync {
        self.lastCleanChannelSync = cleanSync
      }
      if let attemptedSync = lastAttemptedChannelSync {
        self.lastAttemptedChannelSync = attemptedSync
      }
    }
  #endif
}
