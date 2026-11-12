@preconcurrency import ActivityKit
import CoreLocation
import Foundation
import CairnServices
import MeshCore
import OSLog

@Observable
@MainActor
final class LiveActivityManager {
  static let enabledKey = AppStorageKey.liveActivityEnabled.rawValue

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "LiveActivityManager")

  /// Returns whether BLE is currently connected at the radio layer. Defaults
  /// to `false` so a missing wiring fails closed.
  var connectionStateProvider: (@MainActor () -> Bool)?

  /// Returns the radioID of the currently connected radio, or `nil` when
  /// disconnected. Lets the stale observer restore a connected activity only
  /// when the live radio still matches the one the activity represents, so a
  /// connection to a different radio can't relabel a stale activity.
  var connectedRadioIDProvider: (@MainActor () -> UUID?)?

  private var currentActivity: Activity<MeshStatusAttributes>?
  private var disconnectTimer: Task<Void, Never>?
  private var enablementTask: Task<Void, Never>?
  private var stateObservationTask: Task<Void, Never>?
  private var throttleTask: Task<Void, Never>?
  /// When `throttleTask` will flush, so a shorter interval can bring it forward.
  private var throttleDeadline: Date?
  private var ocvArray: [Int] = []
  // This, `advertLastHeard` and `lastSignal` change on every packet, so they are not observed:
  // CarPlay reads them on its own clock (`packetsPerMinute(now:)` and the like) rather than
  // rebuilding its screen per packet.
  @ObservationIgnored private var recentPacketTimestamps: [Date] = []
  private var pendingUpdate: StateChange?
  private var lastFlushDate: Date = .distantPast
  /// When each advertising node was last heard, by public key, pruned to `nodesHeardWindow`.
  @ObservationIgnored private var advertLastHeard: [Data: Date] = [:]
  /// The radio's own GPS fix from its telemetry, for the position and altitude line.
  private(set) var radioGPSFix: GPSFix?
  private var lastRadioStatsRead: Date = .distantPast
  private var lastTelemetryRead: Date = .distantPast

  static let packetWindowSeconds: TimeInterval = 60
  static let secondsPerMinute: TimeInterval = 60
  /// While packets keep coming, the activity's `lastPacketDate` (and the signal and nodes heard
  /// riding with it) is refreshed at most this often: not per packet. On a busy mesh every packet
  /// wakes the app, and an update per packet (or per minute) is Lock Screen work nobody needs.
  static let packetRefreshInterval: TimeInterval = 180
  /// A connected activity goes stale this long after its `lastPacketDate`: the system then shows
  /// it as quiet (with a self-updating "quiet for" timer) without the app waking. Longer than
  /// `packetRefreshInterval`, so a steady mesh refreshes it before it goes stale.
  static let quietAfter: TimeInterval = 240
  static let disconnectGracePeriod: TimeInterval = 300
  static let updateInterval: TimeInterval = 15
  /// Least time between updates for a message or an unread change: shown almost at once, while
  /// a burst (the radio's queue drained on reconnect) lands as one update with the newest.
  static let messageUpdateInterval: TimeInterval = 3
  /// How long the last packet's RSSI and SNR stay up with no packet since; after that they say
  /// nothing about the link now.
  static let signalMaxAge: TimeInterval = 600
  /// How far back the nodes-heard count looks.
  static let nodesHeardWindow: TimeInterval = 3600
  /// Least time between noise-floor reads, which ride on the battery poll (every 2 min in the
  /// foreground, at most every 15 min in the background), so the radio is never asked more often.
  static let radioStatsInterval: TimeInterval = 150
  /// Least time between reads of the radio's own telemetry (its GPS fix): position moves slowly.
  static let telemetryInterval: TimeInterval = 600

  struct GPSFix: Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
  }

  /// Packets within `window` ending at `now` as a per-minute rate. Pure so the
  /// rate math is unit-testable without an `Activity`.
  static func packetsPerMinute(
    timestamps: [Date],
    now: Date,
    window: TimeInterval = packetWindowSeconds
  ) -> Int {
    let cutoff = now.addingTimeInterval(-window)
    let count = timestamps.count(where: { $0 >= cutoff })
    return Int((Double(count) * secondsPerMinute / window).rounded())
  }

  /// Distinct nodes heard within `window` ending at `now`. Pure for the same reason.
  static func nodesHeard(
    lastHeard: [Data: Date],
    now: Date,
    window: TimeInterval = nodesHeardWindow
  ) -> Int {
    nodesHeardKeys(lastHeard: lastHeard, now: now, window: window).count
  }

  /// The public keys of the nodes `nodesHeard` counts.
  static func nodesHeardKeys(
    lastHeard: [Data: Date],
    now: Date,
    window: TimeInterval = nodesHeardWindow
  ) -> Set<Data> {
    let cutoff = now.addingTimeInterval(-window)
    return Set(lastHeard.compactMap { $0.value >= cutoff ? $0.key : nil })
  }

  /// The position line's two strings: the radio's GPS fix when it has one, with its altitude,
  /// else the position it advertises (no altitude then), else nothing. Formatted here because
  /// the altitude follows the app's units setting, which the widget can't read. Coordinates
  /// are dotted whatever the locale, so a comma decimal can't blur the pair.
  static func positionTexts(
    advertised device: DeviceDTO?,
    fix: GPSFix?
  ) -> (position: String?, altitude: String?) {
    if let fix {
      return (
        LocationReportFormat.coordinates(CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)),
        LocationReportFormat.altitude(fix.altitude)
      )
    }
    guard let device, device.hasLocation else { return (nil, nil) }
    return (
      LocationReportFormat.coordinates(CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)),
      nil
    )
  }

  /// The first GPS point in the radio's own telemetry, if it reported one.
  static func gpsFix(in telemetry: [LPPDataPoint]) -> GPSFix? {
    for point in telemetry {
      if case let .gps(latitude, longitude, altitude) = point.value {
        return GPSFix(latitude: latitude, longitude: longitude, altitude: altitude)
      }
    }
    return nil
  }

  // MARK: - Readings for CarPlay

  /// The signal of the last packet that carried one, and when it arrived.
  struct PacketSignal: Equatable {
    var rssi: Int?
    var snr: Double?
    var date: Date
  }

  /// The activity's readings, kept whether or not an activity is running, for CarPlay's
  /// Dashboard, which shows the same ones. Observed, but for the per-packet signal: the car
  /// redraws (through its own refresh gate) when one changes. Cleared when the link drops, as
  /// the activity clears them.
  @ObservationIgnored private(set) var lastSignal: PacketSignal?
  private(set) var lastNoiseFloor: Int?
  /// The last message that would notify (muted and mentions-only conversations never get here).
  private(set) var lastMessage: MeshStatusAttributes.LastMessage?
  /// The radio the readings belong to, so another radio's last message never carries over.
  private var readingsRadioID: UUID?

  /// Set while CarPlay shows the readings, so they are gathered (a channel message's lookup, the
  /// noise floor and telemetry reads) with no activity running.
  var isCarPlayShowingReadings = false

  /// Whether anything shows the readings now: an activity, or CarPlay.
  var collectsReadings: Bool {
    hasActiveActivity || isCarPlayShowingReadings
  }

  func packetsPerMinute(now: Date) -> Int {
    Self.packetsPerMinute(timestamps: recentPacketTimestamps, now: now)
  }

  /// The nodes whose adverts arrived in the last hour, for CarPlay's Recently Heard group.
  func nodesHeardKeys(now: Date) -> Set<Data> {
    Self.nodesHeardKeys(lastHeard: advertLastHeard, now: now)
  }

  /// The last packet's signal while it still says something about the link (`signalMaxAge`).
  func signal(now: Date) -> PacketSignal? {
    lastSignal.flatMap { now.timeIntervalSince($0.date) <= Self.signalMaxAge ? $0 : nil }
  }

  /// Drops nodes last heard before the window, then counts the rest.
  private func pruneNodesHeard() -> Int {
    let cutoff = Date.now.addingTimeInterval(-Self.nodesHeardWindow)
    advertLastHeard = advertLastHeard.filter { $0.value >= cutoff }
    return advertLastHeard.count
  }

  var hasActiveActivity: Bool {
    currentActivity != nil
  }

  var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
  }

  init() {
    isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? AppStorageKey.defaultLiveActivityEnabled
  }

  // MARK: - State Change

  /// A partial update to the activity's state. A field left `nil` keeps the current value; a
  /// double optional set to `.some(nil)` clears it.
  struct StateChange {
    var isConnected: Bool?
    var battery: Int??
    var batteryMillivolts: Int??
    var lastPacketDate: Date??
    var unreadCount: Int?
    var disconnectedDate: Date??
    var lastRSSI: Int??
    var lastSNR: Double??
    var noiseFloor: Int??
    var nodesHeard: Int??
    var positionText: String??
    var altitudeText: String??
    var lastMessage: MeshStatusAttributes.LastMessage??

    /// Last writer wins per field.
    mutating func merge(_ newer: StateChange) {
      if let value = newer.isConnected { isConnected = value }
      if let value = newer.battery { battery = value }
      if let value = newer.batteryMillivolts { batteryMillivolts = value }
      if let value = newer.lastPacketDate { lastPacketDate = value }
      if let value = newer.unreadCount { unreadCount = value }
      if let value = newer.disconnectedDate { disconnectedDate = value }
      if let value = newer.lastRSSI { lastRSSI = value }
      if let value = newer.lastSNR { lastSNR = value }
      if let value = newer.noiseFloor { noiseFloor = value }
      if let value = newer.nodesHeard { nodesHeard = value }
      if let value = newer.positionText { positionText = value }
      if let value = newer.altitudeText { altitudeText = value }
      if let value = newer.lastMessage { lastMessage = value }
    }

    func applied(to current: MeshStatusAttributes.ContentState) -> MeshStatusAttributes.ContentState {
      MeshStatusAttributes.ContentState(
        isConnected: isConnected ?? current.isConnected,
        batteryPercent: battery ?? current.batteryPercent,
        unreadCount: unreadCount ?? current.unreadCount,
        disconnectedDate: disconnectedDate ?? current.disconnectedDate,
        lastPacketDate: lastPacketDate ?? current.lastPacketDate,
        batteryMillivolts: batteryMillivolts ?? current.batteryMillivolts,
        lastRSSI: lastRSSI ?? current.lastRSSI,
        lastSNR: lastSNR ?? current.lastSNR,
        noiseFloor: noiseFloor ?? current.noiseFloor,
        nodesHeard: nodesHeard ?? current.nodesHeard,
        positionText: positionText ?? current.positionText,
        altitudeText: altitudeText ?? current.altitudeText,
        lastMessage: lastMessage ?? current.lastMessage
      )
    }
  }

  // MARK: - Lifecycle

  func startObservingEnablement() {
    enablementTask?.cancel()
    enablementTask = Task { [weak self] in
      for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
        guard let self else { break }
        if !enabled {
          await endActivity()
        }
      }
    }
  }

  /// - Parameter isNewLink: `false` when only the activity is restarted on a link that stayed
  ///   up (`restartLiveActivityIfMissing`), so the readings CarPlay shows are kept.
  func handleConnectionReady(
    device: DeviceDTO,
    ocvArray: [Int],
    unreadCount: Int,
    battery: BatteryInfo? = nil,
    isNewLink: Bool = true
  ) async {
    self.ocvArray = ocvArray
    if isNewLink {
      // A new link reads the radio afresh: its fix may have moved while it was away.
      radioGPSFix = nil
      lastSignal = nil
      lastNoiseFloor = nil
      lastRadioStatsRead = .distantPast
      lastTelemetryRead = .distantPast
    }
    // Only another radio clears what was heard: the nodes heard age out on their own.
    if readingsRadioID != device.radioID {
      readingsRadioID = device.radioID
      lastMessage = nil
      advertLastHeard = [:]
    }
    let position = Self.positionTexts(advertised: device, fix: radioGPSFix)

    // If reconnecting to same device within grace period, restore connected state
    if let activity = currentActivity,
       activity.attributes.radioID == device.radioID {
      disconnectTimer?.cancel()
      disconnectTimer = nil
      recentPacketTimestamps = []
      clearPendingUpdate()
      await updateActivity(StateChange(
        isConnected: true,
        battery: .some(battery.map { $0.percentage(using: ocvArray) }),
        batteryMillivolts: .some(battery?.level),
        lastPacketDate: .some(nil),
        unreadCount: unreadCount,
        disconnectedDate: .some(nil),
        lastRSSI: .some(nil),
        lastSNR: .some(nil),
        noiseFloor: .some(nil),
        nodesHeard: .some(pruneNodesHeard()),
        positionText: .some(position.position),
        altitudeText: .some(position.altitude)
      ))
      startObservingActivityState()
      return
    }

    // If reconnecting to a different device, end the old activity first
    if currentActivity != nil {
      await endActivity()
    }

    await startActivity(
      deviceName: device.nodeName,
      radioID: device.radioID,
      initialState: MeshStatusAttributes.ContentState(
        isConnected: true,
        batteryPercent: battery.map { $0.percentage(using: ocvArray) },
        unreadCount: unreadCount,
        disconnectedDate: nil,
        batteryMillivolts: battery?.level,
        noiseFloor: lastNoiseFloor,
        nodesHeard: pruneNodesHeard(),
        positionText: position.position,
        altitudeText: position.altitude
      )
    )
  }

  func handleConnectionLost() async {
    // CarPlay's readings go with the link even with no activity up; the last message stays.
    lastSignal = nil
    lastNoiseFloor = nil
    recentPacketTimestamps = []
    guard currentActivity != nil else { return }

    recentPacketTimestamps = []
    clearPendingUpdate()
    // The last message, nodes heard and position stay: they still say what happened. Live
    // readings go, since nothing is measuring them.
    await updateActivity(StateChange(
      isConnected: false,
      battery: .some(nil),
      batteryMillivolts: .some(nil),
      unreadCount: 0,
      disconnectedDate: .some(.now),
      lastRSSI: .some(nil),
      lastSNR: .some(nil),
      noiseFloor: .some(nil)
    ))

    disconnectTimer?.cancel()
    disconnectTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.disconnectGracePeriod))
      guard !Task.isCancelled else { return }
      await self?.endActivity()
    }
  }

  func handleReturnToForeground() {
    guard hasActiveActivity else { return }
    if pendingUpdate != nil {
      Task { await flushPendingUpdate() }
    }
  }

  /// - Parameters:
  ///   - rssi: The packet's RSSI in dBm, when the RX log carried one.
  ///   - snr: The packet's SNR in dB, likewise.
  func handlePacketReceived(rssi: Int? = nil, snr: Double? = nil) async {
    let now = Date.now
    // CarPlay's rate and signal follow every packet; the activity doesn't need to.
    recentPacketTimestamps.append(now)
    let cutoff = now.addingTimeInterval(-Self.packetWindowSeconds)
    recentPacketTimestamps.removeAll { $0 < cutoff }
    var change = StateChange(lastPacketDate: .some(now))
    if rssi != nil || snr != nil {
      lastSignal = PacketSignal(rssi: rssi, snr: snr, date: now)
      change.lastRSSI = .some(rssi)
      change.lastSNR = .some(snr)
    }
    // An update only when the activity's last-packet date is due (or it shows the mesh as
    // quiet); otherwise the packet's date and signal ride along with the next update.
    if Self.isPacketRefreshDue(shown: currentActivity?.content.state.lastPacketDate, now: now) {
      await scheduleUpdate(change)
    } else {
      stageUpdate(change)
    }
  }

  /// Whether a packet at `now` should refresh an activity showing `shown` as its last packet:
  /// when it shows none, or one `packetRefreshInterval` old (a quiet activity's is older still).
  static func isPacketRefreshDue(shown: Date?, now: Date) -> Bool {
    guard let shown else { return true }
    return now.timeIntervalSince(shown) >= packetRefreshInterval
  }

  /// Battery percent and voltage. Also recounts the nodes heard, so the count ages out on the
  /// battery poll's cadence without a timer of its own. Flushes at once, taking any radio
  /// readings staged just before with it, so a poll costs one update.
  func handleBatteryChanged(battery: BatteryInfo) async {
    let percent = battery.percentage(using: ocvArray)
    await scheduleUpdate(StateChange(
      battery: .some(percent),
      batteryMillivolts: .some(battery.level),
      nodesHeard: .some(pruneNodesHeard())
    ))
    await flushPendingUpdate()
  }

  /// An advert from `publicKey`: counts toward the nodes heard in the last hour.
  func handleAdvertReceived(publicKey: Data) async {
    advertLastHeard[publicKey] = .now
    // Rides along with the next update rather than causing one: a busy mesh adverts constantly.
    stageUpdate(StateChange(nodesHeard: .some(pruneNodesHeard())))
  }

  /// A received message (already filtered for muted and mentions-only conversations). Shown
  /// within `messageUpdateInterval`, like unread.
  func handleMessageReceived(_ message: MeshStatusAttributes.LastMessage) async {
    lastMessage = message
    await scheduleUpdate(StateChange(lastMessage: .some(message)), within: Self.messageUpdateInterval)
  }

  /// Which radio reads the activity is due for, claimed so overlapping callers don't repeat them.
  /// Nothing is due without a connected activity, or CarPlay on a connected radio, to show the
  /// result.
  func claimDueRadioReads(now: Date = .now) -> (stats: Bool, telemetry: Bool) {
    let isActivityConnected = currentActivity?.content.state.isConnected ?? false
    let isCarPlayConnected = isCarPlayShowingReadings && (connectionStateProvider?() ?? false)
    guard isActivityConnected || isCarPlayConnected else { return (false, false) }
    let stats = now.timeIntervalSince(lastRadioStatsRead) >= Self.radioStatsInterval
    let telemetry = now.timeIntervalSince(lastTelemetryRead) >= Self.telemetryInterval
    if stats { lastRadioStatsRead = now }
    if telemetry { lastTelemetryRead = now }
    return (stats, telemetry)
  }

  /// Results of the reads `claimDueRadioReads` allowed. A `nil` argument was not read (or the
  /// read failed) and keeps what the activity shows. Staged, not sent: the battery change that
  /// follows on the same poll carries them in its update.
  ///
  /// - Parameters:
  ///   - device: The connected radio, for the position it advertises.
  ///   - noiseFloor: From the radio's stats.
  ///   - telemetry: The radio's own LPP readings, searched for a GPS fix.
  func handleRadioReadings(device: DeviceDTO?, noiseFloor: Int?, telemetry: [LPPDataPoint]?) async {
    if let telemetry {
      radioGPSFix = Self.gpsFix(in: telemetry)
    }
    var change = StateChange()
    if telemetry != nil {
      let position = Self.positionTexts(advertised: device, fix: radioGPSFix)
      change.positionText = .some(position.position)
      change.altitudeText = .some(position.altitude)
    }
    if let noiseFloor {
      lastNoiseFloor = noiseFloor
      change.noiseFloor = .some(noiseFloor)
    }
    stageUpdate(change)
  }

  func handleUnreadCountChanged(unreadCount: Int) async {
    await scheduleUpdate(StateChange(unreadCount: unreadCount), within: Self.messageUpdateInterval)
  }

  func setEnabled(_ enabled: Bool) async {
    isEnabled = enabled
    if !enabled {
      await endActivity()
    }
  }

  // MARK: - App relaunch recovery

  func recoverExistingActivity() async {
    let allActivities = Activity<MeshStatusAttributes>.activities

    // Clean up ended/dismissed activities still visible per their dismissal policy.
    for activity in allActivities where
      activity.activityState == .ended || activity.activityState == .dismissed {
      await activity.end(nil, dismissalPolicy: .immediate)
    }

    // Adopt the first active/stale activity; immediately end any extras as
    // orphans so the user never sees two LAs at once.
    let activeOrStale = allActivities.filter {
      $0.activityState == .active || $0.activityState == .stale
    }
    for orphan in activeOrStale.dropFirst() {
      logger.warning("Ending duplicate orphan Live Activity on recovery")
      await orphan.end(nil, dismissalPolicy: .immediate)
    }

    currentActivity = activeOrStale.first
    guard let activity = currentActivity else { return }

    startObservingActivityState()

    // If the LA is cached as connected, force re-validation. The radio may
    // actually be disconnected (prior session crashed mid-connection, app
    // was killed during a drop, etc.). handleConnectionReady's same-device
    // branch will restore connected state once auto-reconnect lands.
    if activity.content.state.isConnected {
      logger.info("Recovered Live Activity in cached connected state — forcing re-validation as disconnected")
      await handleConnectionLost()
      return
    }

    // Already disconnected — re-arm the grace timer using the persisted
    // disconnectedDate. If it's missing or already expired, end now.
    guard let disconnectedDate = activity.content.state.disconnectedDate else {
      await endActivity()
      return
    }

    let elapsed = Date.now.timeIntervalSince(disconnectedDate)
    let remaining = Self.disconnectGracePeriod - elapsed

    if remaining > 0 {
      disconnectTimer = Task { [weak self] in
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        await self?.endActivity()
      }
    } else {
      await endActivity()
    }
  }

  // MARK: - Private

  private func clearActivityReference() {
    currentActivity = nil
    stateObservationTask?.cancel()
    stateObservationTask = nil
    // Everything else here is bound to the activity's lifetime: timers
    // that would mutate it, throttled updates queued for it, packet
    // timestamps used to compute its rate. If any of these survive the
    // reference being cleared, they can leak onto the next activity (a
    // stale disconnect timer ending a fresh LA, a queued flush applying
    // old battery/rate, packet-rate carry-over).
    disconnectTimer?.cancel()
    disconnectTimer = nil
    clearPendingUpdate()
    recentPacketTimestamps = []
    // The adverts heard stay: they belong to the radio's link, not the activity, and a
    // restarted activity carries on the count it showed.
  }

  private func startActivity(
    deviceName: String,
    radioID: UUID,
    initialState state: MeshStatusAttributes.ContentState
  ) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      logger.warning("Cannot start Live Activity: not authorized")
      return
    }
    guard isEnabled else {
      logger.debug("Cannot start Live Activity: disabled by user")
      return
    }
    guard !DemoModeManager.shared.isEnabled else { return }

    // Reclaim slots held by ended/dismissed entries before requesting.
    // iOS keeps them in `.activities` for up to 4 hours (Lock Screen
    // dismissal window) and counts them against the per-app activity
    // cap, so `Activity.request` would otherwise throw
    // `ActivityAuthorizationError.targetMaximumExceeded`. Mirrors
    // `recoverExistingActivity`.
    for activity in Activity<MeshStatusAttributes>.activities where
      activity.activityState == .ended || activity.activityState == .dismissed {
      await activity.end(nil, dismissalPolicy: .immediate)
    }

    guard !Activity<MeshStatusAttributes>.activities.contains(where: {
      $0.activityState == .active || $0.activityState == .stale
    }) else {
      logger.warning("Cannot start Live Activity: one already running")
      return
    }

    let attributes = MeshStatusAttributes(deviceName: deviceName, radioID: radioID)
    let staleDate = Calendar.current.date(byAdding: .minute, value: 5, to: .now)
    let content = ActivityContent(state: state, staleDate: staleDate)

    do {
      currentActivity = try Activity.request(
        attributes: attributes,
        content: content,
        pushType: nil
      )
      LiveActivityTip.radioConnected.sendDonation()
      startObservingActivityState()
      logger.info("Started Live Activity for \(deviceName, privacy: .public)")
    } catch {
      logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// The state a system-ended activity restarts with while the radio is still connected: what
  /// it showed, back to connected. Its last-packet date stays: it still says when the radio last
  /// heard something, and the next packet refreshes it.
  static func restartState(from last: MeshStatusAttributes.ContentState) -> MeshStatusAttributes.ContentState {
    var state = last
    state.isConnected = true
    state.disconnectedDate = nil
    return state
  }

  // MARK: - Activity State Observation

  private func startObservingActivityState() {
    stateObservationTask?.cancel()
    guard let activity = currentActivity else { return }
    stateObservationTask = Task { [weak self] in
      for await state in activity.activityStateUpdates {
        guard let self else { break }
        switch state {
        case .ended:
          let lastState = activity.content.state
          let deviceName = activity.attributes.deviceName
          let radioID = activity.attributes.radioID

          // Clear the field synchronously before any await so a
          // re-entrant @MainActor caller (e.g. handleConnectionReady)
          // can't reassign currentActivity to a replacement and have
          // it nulled out when we return.
          clearActivityReference()

          // Dismiss the captured (now-detached) activity immediately
          // so it doesn't linger on screen alongside any replacement
          // (system-ended activities default to ~4h visible dismissal).
          await activity.end(nil, dismissalPolicy: .immediate)

          // Don't resurrect a "connected" LA from cached state —
          // only restart when the radio is actually connected.
          let isCurrentlyConnected = connectionStateProvider?() ?? false
          if isCurrentlyConnected {
            logger.info("System ended Live Activity, restarting (radio still connected)")
            await startActivity(deviceName: deviceName, radioID: radioID, initialState: Self.restartState(from: lastState))
          } else {
            logger.info("System ended Live Activity, not restarting (radio disconnected)")
          }
          return

        case .dismissed:
          clearActivityReference()
          logger.info("Live Activity dismissed by user")
          return

        case .stale:
          let currentState = activity.content.state
          let isCurrentlyConnected = connectionStateProvider?() ?? false

          if currentState.isConnected, !isCurrentlyConnected {
            // LA cached as connected, but the radio is actually
            // disconnected (we missed a notification somewhere).
            // Force the disconnect path instead of refreshing.
            logger.warning("Stale Live Activity cached connected but radio disconnected — forcing handleConnectionLost")
            await handleConnectionLost()
          } else if !currentState.isConnected,
                    let connectedRadioID = connectedRadioIDProvider?(),
                    activity.attributes.radioID == connectedRadioID {
            // LA cached as disconnected, but the same radio is actually
            // connected. A background reconnect restored the link with no
            // runtime to update. Restore connected, since handleConnectionReady
            // may not fire until the app foregrounds.
            logger.warning("Stale Live Activity cached disconnected but radio connected — restoring connected state")
            disconnectTimer?.cancel()
            disconnectTimer = nil
            recentPacketTimestamps = []
            clearPendingUpdate()
            await updateActivity(StateChange(isConnected: true, disconnectedDate: .some(nil)))
          } else if pendingUpdate != nil {
            await flushPendingUpdate()
          }
          // Otherwise stale is what it says: connected, and the mesh has gone quiet since the
          // last packet the activity showed. It stays so (its "quiet for" timer runs by itself)
          // until a packet refreshes it; refreshing it here would hide the quiet.

        case .active:
          break

        case .pending:
          break

        @unknown default:
          break
        }
      }
    }
  }

  // MARK: - Throttled Updates

  /// Queues `change`, flushing it at once when the last flush is `interval` old, else when it
  /// will be. A shorter interval brings a later scheduled flush forward.
  private func scheduleUpdate(_ change: StateChange, within interval: TimeInterval = updateInterval) async {
    guard currentActivity != nil else { return }
    stageUpdate(change)

    // Leading edge: flush immediately if enough time has passed
    if Date.now.timeIntervalSince(lastFlushDate) >= interval {
      await flushPendingUpdate()
      return
    }

    // Trailing edge: schedule a flush unless one is already due by then
    let deadline = lastFlushDate.addingTimeInterval(interval)
    if throttleTask != nil, let throttleDeadline, throttleDeadline <= deadline { return }
    throttleTask?.cancel()
    throttleDeadline = deadline
    throttleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
      guard !Task.isCancelled, let self else { return }
      await flushPendingUpdate()
    }
  }

  /// Merges `change` into the pending update (last writer wins per field) for the next flush.
  private func stageUpdate(_ change: StateChange) {
    guard currentActivity != nil else { return }
    var pending = pendingUpdate ?? StateChange()
    pending.merge(change)
    pendingUpdate = pending
  }

  private func flushPendingUpdate() async {
    guard let pending = pendingUpdate else { return }
    pendingUpdate = nil
    throttleTask?.cancel()
    throttleTask = nil
    throttleDeadline = nil
    lastFlushDate = .now
    await updateActivity(pending)
  }

  private func clearPendingUpdate() {
    pendingUpdate = nil
    throttleTask?.cancel()
    throttleTask = nil
    throttleDeadline = nil
  }

  /// Updates the Live Activity state with `change` (see `StateChange` for keep and clear).
  ///
  /// An update whose state matches the displayed one is skipped (each update
  /// costs an ActivityKit round trip and a widget render) unless the current
  /// stale date is within half its interval, so a steady connected rate still
  /// pushes the stale date out before the stale handler would zero it.
  /// `forceRefresh` always updates (the stale handler re-arming the stale date).
  private func updateActivity(_ change: StateChange, forceRefresh: Bool = false) async {
    guard let currentContent = currentActivity?.content else { return }
    let current = currentContent.state
    let state = change.applied(to: current)
    let staleDate = Self.staleDate(for: state, now: .now)
    if !forceRefresh, state == current, currentContent.staleDate == staleDate {
      return
    }
    let content = ActivityContent(state: state, staleDate: staleDate)
    await currentActivity?.update(content)
  }

  /// When an activity showing `state` goes stale. Connected, that is `quietAfter` past its last
  /// packet (already past for an update while the mesh is quiet, which then shows as quiet at
  /// once), or `quietAfter` from now before any packet has come. Disconnected, five minutes on:
  /// the activity ends after `disconnectGracePeriod` anyway.
  static func staleDate(for state: MeshStatusAttributes.ContentState, now: Date) -> Date {
    if state.isConnected {
      return (state.lastPacketDate ?? now).addingTimeInterval(quietAfter)
    }
    return now.addingTimeInterval(5 * secondsPerMinute)
  }

  /// Checks whether the current activity reference is still valid.
  /// If the activity was ended while suspended (and `activityStateUpdates` didn't fire), this catches it.
  func validateActivityState() async {
    guard let activity = currentActivity else { return }
    switch activity.activityState {
    case .ended:
      let lastState = activity.content.state
      let deviceName = activity.attributes.deviceName
      let radioID = activity.attributes.radioID

      // Clear the field synchronously before the await so a re-entrant
      // main-actor caller can't have its replacement currentActivity
      // nulled out when we resume.
      clearActivityReference()
      await activity.end(nil, dismissalPolicy: .immediate)

      let isCurrentlyConnected = connectionStateProvider?() ?? false
      if isCurrentlyConnected {
        logger.info("Detected ended Live Activity on foreground, restarting (radio still connected)")
        await startActivity(deviceName: deviceName, radioID: radioID, initialState: Self.restartState(from: lastState))
      } else {
        logger.info("Detected ended Live Activity on foreground, not restarting (radio disconnected)")
      }
    case .dismissed:
      clearActivityReference()
    case .active, .stale:
      break
    case .pending:
      break
    @unknown default:
      break
    }
  }

  func endActivity() async {
    stateObservationTask?.cancel()
    stateObservationTask = nil
    disconnectTimer?.cancel()
    disconnectTimer = nil
    clearPendingUpdate()
    recentPacketTimestamps = []
    // The adverts heard stay with the radio's link (`readingsRadioID`), as in
    // `clearActivityReference`.
    for activity in Activity<MeshStatusAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    currentActivity = nil
    logger.info("Ended Live Activity")
  }
}
