import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodeStatusViewModel")

/// Shared logic for repeater and room status view models.
/// Owns retry machinery, display formatters, delta properties, OCV settings,
/// telemetry handling, and snapshot persistence.
@Observable
@MainActor
final class NodeStatusViewModel {
  // MARK: - Properties

  /// Current session
  var session: RemoteNodeSessionDTO?

  /// True when `publicKeyPrefix` matches the session this screen is showing.
  func matchesSession(_ publicKeyPrefix: Data) -> Bool {
    guard !publicKeyPrefix.isEmpty, let publicKey = session?.publicKey else { return false }
    return publicKey.prefix(publicKeyPrefix.count) == publicKeyPrefix
  }

  /// Public key for direct telemetry (no remote session).
  /// Used for chat nodes that don't require login.
  private var directPublicKey: Data?

  /// The public key to use for requests and history — prefers session, falls back to direct.
  var effectivePublicKey: Data? {
    session?.publicKey ?? directPublicKey
  }

  /// 6-byte prefix for response matching.
  var effectivePublicKeyPrefix: Data? {
    session?.publicKeyPrefix ?? directPublicKey?.prefix(6)
  }

  /// Last received status
  var status: StatusResponse?

  /// Last received telemetry
  var telemetry: TelemetryResponse?

  /// Cached decoded data points to avoid repeated LPP decoding.
  private(set) var cachedDataPoints: [LPPDataPoint] = []

  /// Loading states
  var isLoadingStatus = false
  var isLoadingTelemetry = false

  /// Whether a status response has been applied since the sheet opened.
  var statusLoaded = false

  /// When the reading on screen arrived, for the dashboard's "Updated 2 min ago" line.
  private(set) var statusUpdatedAt: Date?

  /// Whether telemetry has been loaded at least once (for refresh logic)
  var telemetryLoaded = false

  /// Snapshots this visit has saved (status, neighbours, sensors): a history page open over the
  /// node reloads when it changes, so a reading taken while it's up joins its charts.
  private(set) var snapshotsRecorded = 0

  /// Error text owned by the status counters section, scoped so a status
  /// failure surfaces only under the status section once sections load independently.
  var statusSectionError: String?

  /// Error text owned by the telemetry section, scoped so a telemetry
  /// failure surfaces only under the telemetry section once sections load independently.
  var telemetrySectionError: String?

  // MARK: - OCV Curve Properties

  var selectedOCVPreset: OCVPreset = .liIon
  var ocvValues: [Int] = OCVPreset.liIon.ocvArray
  var ocvError: String?
  private var contactID: UUID?

  // MARK: - Dependencies

  private var contactServiceProvider: @MainActor () -> ContactService? = { nil }
  var contactService: ContactService? {
    contactServiceProvider()
  }

  private var nodeSnapshotServiceProvider: @MainActor () -> NodeSnapshotService? = { nil }
  var nodeSnapshotService: NodeSnapshotService? {
    nodeSnapshotServiceProvider()
  }

  // MARK: - Snapshot State

  /// Previous status-bearing snapshot for the status deltas, sourced from the last
  /// snapshot that actually captured status so a neighbor- or telemetry-only row
  /// can't blank the delta.
  private(set) var previousStatusSnapshot: NodeStatusSnapshotDTO?

  /// Previous neighbor-bearing snapshot for the neighbor SNR delta. Owned by the
  /// neighbor load path so the delta does not depend on the status section being
  /// expanded, and sourced from the last snapshot that actually captured neighbors.
  private(set) var previousNeighborSnapshot: NodeStatusSnapshotDTO?

  /// Every neighbor prefix seen across stored history before the current reading,
  /// for the "New" badge. A prefix absent here means the neighbor is first-seen.
  private(set) var seenNeighborPrefixes: Set<Data> = []

  // MARK: - Initialization

  func configure(
    contactService: @escaping @MainActor () -> ContactService?,
    nodeSnapshotService: @escaping @MainActor () -> NodeSnapshotService?
  ) {
    contactServiceProvider = contactService
    nodeSnapshotServiceProvider = nodeSnapshotService
  }

  /// Configure for direct telemetry access (no login session).
  /// Used for chat nodes that can be queried without authentication.
  func configureForDirectTelemetry(publicKey: Data) {
    directPublicKey = publicKey
  }

  // MARK: - Transient Retry Machinery

  private static let requestTimeout: Duration = RemoteOperationTimeoutPolicy.binaryMaximum

  private static let transientRetryDelays: [Duration] = [
    .milliseconds(500),
    .seconds(1),
    .seconds(2),
  ]

  func isTransientError(_ error: Error) -> Bool {
    let meshError: MeshCoreError
    switch error {
    case let remoteError as RemoteNodeError:
      guard case let .sessionError(inner) = remoteError else { return false }
      meshError = inner
    case let binaryError as BinaryProtocolError:
      guard case let .sessionError(inner) = binaryError else { return false }
      meshError = inner
    default:
      return false
    }
    guard case let .deviceError(code) = meshError else { return false }
    return code == FirmwareDeviceErrorCode.remoteNodeNoResponseYet
  }

  private func remainingBudget(until deadline: ContinuousClock.Instant) -> Duration? {
    let remaining = deadline - .now
    return remaining > .zero ? remaining : nil
  }

  private func waitForRetry(delay: Duration, until deadline: ContinuousClock.Instant) async throws {
    guard let remaining = remainingBudget(until: deadline) else {
      throw RemoteNodeError.timeout
    }
    try await Task.sleep(for: min(delay, remaining))
  }

  func performWithTransientRetries<T>(
    operationName: String,
    operation: @escaping @Sendable (Duration) async throws -> T
  ) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: Self.requestTimeout)
    var delayIterator = Self.transientRetryDelays.makeIterator()

    while true {
      guard let timeout = remainingBudget(until: deadline) else {
        logger.warning("\(operationName, privacy: .public) request exhausted its shared timeout budget")
        throw RemoteNodeError.timeout
      }

      do {
        return try await operation(timeout)
      } catch {
        guard isTransientError(error), let delay = delayIterator.next() else {
          throw error
        }
        try await waitForRetry(delay: delay, until: deadline)
      }
    }
  }

  /// Runs a section request with the shared transient-retry budget, owning that
  /// section's loading and error flags. Timeout and other errors set the section
  /// error immediately; cancellation only clears loading.
  func runRetryingSectionRequest<T>(
    operationName: String,
    setLoading: @escaping @MainActor (Bool) -> Void,
    setError: @escaping @MainActor (String?) -> Void,
    timeoutMessage: String = L10n.RemoteNodes.RemoteNodes.Status.requestTimedOut,
    operation: @escaping @Sendable (Duration) async throws -> T,
    onSuccess: @escaping @MainActor (T) async -> Void
  ) async {
    setLoading(true)
    setError(nil)
    do {
      let response = try await performWithTransientRetries(operationName: operationName, operation: operation)
      await onSuccess(response)
      setLoading(false)
    } catch is CancellationError {
      setLoading(false)
    } catch RemoteNodeError.timeout {
      logger.info("\(operationName, privacy: .public) timed out")
      setError(timeoutMessage)
      setLoading(false)
    } catch {
      setError(error.userFacingMessage)
      setLoading(false)
    }
  }

  // MARK: - Status Response Handling

  /// Handle a status response, saving a snapshot with role-specific fields.
  /// `rxAirtimeSeconds` and `receiveErrors` are present in all wire frames
  /// but rooms pass `nil` to skip persistence of repeater-specific metrics.
  func handleStatusResponse(
    _ response: StatusResponse,
    rxAirtimeSeconds: UInt32? = nil,
    receiveErrors: UInt32? = nil,
    postedCount: UInt16? = nil,
    postPushCount: UInt16? = nil
  ) async {
    guard let expectedPrefix = session?.publicKeyPrefix,
          response.publicKeyPrefix == expectedPrefix else {
      return
    }
    status = response
    statusLoaded = true
    statusUpdatedAt = .now
    isLoadingStatus = false
    statusSectionError = nil

    guard let nodeSnapshotService, let session else { return }

    previousStatusSnapshot = await nodeSnapshotService.previousStatusSnapshot(
      for: session.publicKey,
      before: .now
    )

    let metrics = NodeStatusMetrics(
      status: response,
      rxAirtimeSeconds: rxAirtimeSeconds,
      receiveErrors: receiveErrors,
      postedCount: postedCount,
      postPushCount: postPushCount
    )
    _ = await nodeSnapshotService.recordSnapshot(
      nodePublicKey: session.publicKey,
      status: metrics
    )
    snapshotsRecorded += 1
  }

  /// Capture neighbor data onto the node's current in-window snapshot, creating
  /// one if none exists yet. Safe to call before a status response: the store
  /// enriches the latest in-window row or inserts a neighbor-bearing snapshot.
  func enrichNeighbors(_ entries: [NeighborSnapshotEntry]) async {
    guard let nodeSnapshotService, let nodePublicKey = effectivePublicKey else { return }
    // Capture the prior baseline before persisting this reading, so the delta and
    // the "New" badge reflect history rather than the current capture. Both come
    // from one await so a render never pairs a fresh baseline with a stale seen set.
    let baseline = await nodeSnapshotService.neighborBaseline(for: nodePublicKey)
    previousNeighborSnapshot = baseline.previous
    seenNeighborPrefixes = baseline.seenPrefixes
    _ = await nodeSnapshotService.recordSnapshot(
      nodePublicKey: nodePublicKey,
      neighbors: entries
    )
    snapshotsRecorded += 1
  }

  // MARK: - Telemetry Response Handling

  func handleTelemetryResponse(_ response: TelemetryResponse) async {
    guard let expectedPrefix = effectivePublicKeyPrefix,
          response.publicKeyPrefix == expectedPrefix else {
      return
    }
    telemetry = response
    cachedDataPoints = response.dataPoints.filter { $0.channel != 0 }
    isLoadingTelemetry = false
    telemetryLoaded = true
    telemetrySectionError = nil

    let entries: [TelemetrySnapshotEntry] = cachedDataPoints.compactMap { dp in
      let numericValue: Double? = switch dp.value {
      case let .float(value):
        value
      case let .integer(value):
        Double(value)
      default:
        nil
      }
      guard let value = numericValue else { return nil }
      return TelemetrySnapshotEntry(channel: Int(dp.channel), type: dp.typeName, value: value)
    }

    let location = currentLocationFix

    guard !entries.isEmpty || location != nil,
          let nodeSnapshotService,
          let nodePublicKey = effectivePublicKey else { return }

    _ = await nodeSnapshotService.recordSnapshot(
      nodePublicKey: nodePublicKey,
      telemetry: entries.isEmpty ? nil : entries,
      location: location
    )
    snapshotsRecorded += 1
  }

  // MARK: - Telemetry Grouping

  var hasMultipleChannels: Bool {
    let channels = Set(cachedDataPoints.map(\.channel))
    return channels.count > 1
  }

  var groupedDataPoints: [(channel: UInt8, dataPoints: [LPPDataPoint])] {
    Dictionary(grouping: cachedDataPoints, by: \.channel)
      .sorted { $0.key < $1.key }
      .map { (channel: $0.key, dataPoints: $0.value) }
  }

  /// The node's reported location from the last telemetry response, or nil when it
  /// reports no plottable coordinate. A node without a current GPS lock still reports
  /// its last known or manually set position. Drives the live "View on Map" affordance.
  var currentLocationFix: NodeLocationFix? {
    NodeLocationFix.primaryFix(from: cachedDataPoints)
  }

  // MARK: - Display Formatters

  static let emDash = "—"
  private static let secondsPerMinute: UInt32 = 60
  private static let secondsPerHour: UInt32 = 3600
  private static let secondsPerDay: UInt32 = 86400

  var uptimeDisplay: String {
    guard let uptime = status?.uptimeSeconds else { return Self.emDash }
    return Self.formatDuration(uptime)
  }

  var txAirtimeDisplay: String {
    guard let airtime = status?.airtime else { return Self.emDash }
    return Self.formatDuration(airtime)
  }

  var rxAirtimeDisplay: String {
    guard let airtime = status?.rxAirtime else { return Self.emDash }
    return Self.formatDuration(airtime)
  }

  private static let airtimePercentFractionDigits = 1

  /// Transmit airtime as a share of uptime, or nil before the node has been up a second.
  var txAirtimePercentDisplay: String? {
    guard let status else { return nil }
    return Self.airtimeShare(status.airtime, of: status.uptimeSeconds)
  }

  /// Receive airtime as a share of uptime, or nil before the node has been up a second.
  var rxAirtimePercentDisplay: String? {
    guard let status else { return nil }
    return Self.airtimeShare(status.rxAirtime, of: status.uptimeSeconds)
  }

  private static func airtimeShare(_ airtime: UInt32, of uptime: UInt32) -> String? {
    guard uptime > 0 else { return nil }
    return percentText(Double(airtime) / Double(uptime))
  }

  static func formatDuration(_ seconds: UInt32) -> String {
    let days = Int(seconds / secondsPerDay)
    let hours = Int((seconds % secondsPerDay) / secondsPerHour)
    let minutes = Int((seconds % secondsPerHour) / secondsPerMinute)

    if days > 0 {
      if days == 1 {
        return L10n.RemoteNodes.RemoteNodes.Status.uptime1Day(hours, minutes)
      } else {
        return L10n.RemoteNodes.RemoteNodes.Status.uptimeDays(days, hours, minutes)
      }
    } else if hours > 0 {
      return L10n.RemoteNodes.RemoteNodes.Status.uptimeHours(hours, minutes)
    }
    return L10n.RemoteNodes.RemoteNodes.Status.uptimeMinutes(minutes)
  }

  var batteryVoltageDisplay: String {
    guard let mv = status?.batteryMillivolts else { return Self.emDash }
    let volts = Double(mv) / 1000.0
    return "\(volts.formatted(.number.precision(.fractionLength(3)))) V"
  }

  /// Charge estimated from the voltage through the node's battery curve; nil while there is no
  /// reading or the node reports 0 mV, which means it has no battery measurement.
  var batteryPercent: Int? {
    guard isBatteryMeasured, let mv = status?.batteryMillivolts else { return nil }
    return BatteryInfo(level: Int(mv)).percentage(using: ocvValues)
  }

  /// False before a reading and when the node reports 0 mV: a node on mains power or without a
  /// voltage divider reports nothing rather than an empty battery.
  var isBatteryMeasured: Bool {
    (status?.battery ?? 0) > 0
  }

  /// Good, low or critical, with the same thresholds as the radio's own battery card.
  var batteryLevel: BatteryLevel? {
    batteryPercent.map(BatteryLevel.init(percent:))
  }

  var lastRSSIDisplay: String {
    guard let rssi = status?.lastRSSI else { return Self.emDash }
    return "\(rssi) dBm"
  }

  var lastSNRDisplay: String {
    guard let snr = status?.lastSNR else { return Self.emDash }
    return "\(snr.formatted(.number.precision(.fractionLength(1)))) dB"
  }

  var noiseFloorDisplay: String {
    guard let nf = status?.noiseFloor else { return Self.emDash }
    return "\(nf) dBm"
  }

  var packetsSentDisplay: String {
    guard let count = status?.packetsSent else { return Self.emDash }
    return count.formatted()
  }

  var packetsReceivedDisplay: String {
    guard let count = status?.packetsReceived else { return Self.emDash }
    return count.formatted()
  }

  var sentDirectDisplay: String {
    guard let count = status?.sentDirect else { return Self.emDash }
    return count.formatted()
  }

  var sentFloodDisplay: String {
    guard let count = status?.sentFlood else { return Self.emDash }
    return count.formatted()
  }

  var receivedDirectDisplay: String {
    guard let count = status?.receivedDirect else { return Self.emDash }
    return count.formatted()
  }

  var receivedFloodDisplay: String {
    guard let count = status?.receivedFlood else { return Self.emDash }
    return count.formatted()
  }

  /// Direct and flood duplicates together, the packets table's total.
  var duplicatesDisplay: String {
    guard let status else { return Self.emDash }
    return (status.directDuplicates + status.floodDuplicates).formatted()
  }

  /// Direct duplicates on their own, for the packets table's split.
  var directDuplicatesDisplay: String {
    guard let count = status?.directDuplicates else { return Self.emDash }
    return count.formatted()
  }

  /// Flood duplicates on their own, for the packets table's split.
  var floodDuplicatesDisplay: String {
    guard let count = status?.floodDuplicates else { return Self.emDash }
    return count.formatted()
  }

  // MARK: - Dashboard

  /// Packets waiting to transmit at which Cairn's status screen warns (RemoteAdmin.cpp
  /// `statusRows`): a queue that deep means the node can't get its traffic out.
  static let txQueueWarningLength = 4

  /// The room layout parses RX airtime as 0 (MeshCore Parsers+Status), so a room shows TX only.
  /// Read from the reply, not the host, so a mis-detected layout still shows what it carries.
  var isRoomLayout: Bool {
    status?.layout == .roomServer
  }

  var txQueueDisplay: String {
    guard let count = status?.txQueueLength else { return Self.emDash }
    return count.formatted()
  }

  var isTxQueueBacklogged: Bool {
    (status?.txQueueLength ?? 0) >= Self.txQueueWarningLength
  }

  /// Transmit airtime as a share of uptime, 0 to 1; nil before the node has been up a second.
  var txShare: Double? {
    guard let status else { return nil }
    return Self.share(status.airtime, of: status.uptimeSeconds)
  }

  /// Receive airtime as a share of uptime, 0 to 1; nil before the node has been up a second and
  /// on the room layout, which doesn't report it.
  var rxShare: Double? {
    guard let status, !isRoomLayout else { return nil }
    return Self.share(status.rxAirtime, of: status.uptimeSeconds)
  }

  /// How busy the channel has been around the node, transmit plus receive, capped at the whole
  /// uptime (Cairn's "Channel use"). Nil on the room layout, which has no receive airtime.
  var channelUseFraction: Double? {
    guard let txShare, let rxShare else { return nil }
    return min(txShare + rxShare, 1)
  }

  var channelUseDisplay: String? {
    channelUseFraction.map(Self.percentText)
  }

  /// How far the last packet sat above the noise floor; nil without a noise reading (0 dBm).
  var rssiAboveNoise: Int? {
    guard let status, status.noiseFloor < 0 else { return nil }
    return status.lastRSSI - status.noiseFloor
  }

  /// A noise floor above Network Health's threshold, which suggests local interference.
  var isNoiseHigh: Bool {
    guard let noiseFloor = status?.noiseFloor, noiseFloor < 0 else { return false }
    return noiseFloor > NetworkHealthReport.highNoiseFloor
  }

  /// The one request the dashboard makes on its own: when the radio is ready and there's no
  /// reading yet and none on the way. A reading kept from an earlier visit isn't re-requested on
  /// a segment switch, which saves the mesh the airtime.
  func shouldAutoLoadStatus(connectionState: DeviceConnectionState) -> Bool {
    connectionState == .ready && status == nil && !isLoadingStatus
  }

  /// The hosts' backstop after setup: like `shouldAutoLoadStatus`, but it also leaves a request
  /// that already failed to the user's Try Again, so a quick failure isn't sent a second time.
  func shouldBackstopAutoLoadStatus(connectionState: DeviceConnectionState) -> Bool {
    shouldAutoLoadStatus(connectionState: connectionState) && statusSectionError == nil
  }

  /// What the dashboard shows: the readings once there are any (a later failure or disconnect
  /// keeps them), otherwise the first load, the failure, or the disconnected note. "Disconnected"
  /// means no link at all: while the radio is linked but still syncing, the placeholders hold
  /// until the automatic request fires at `.ready`.
  func dashboardPhase(connectionState: DeviceConnectionState) -> NodeStatusDashboardPhase {
    if status != nil { return .loaded }
    if isLoadingStatus { return .loading }
    if !connectionState.isConnected { return .disconnected }
    if let statusSectionError { return .failed(statusSectionError) }
    return .loading
  }

  /// "Updated 2 min ago", rounded down to the minute so it holds steady between the minute
  /// ticks that redraw it ("Updated now" in the first minute).
  static func updatedText(since date: Date, now: Date = .now) -> String {
    let minutes = max(0, (now.timeIntervalSince(date) / 60).rounded(.down))
    return L10n.Settings.DeviceSensors.updated(updatedFormatter.localizedString(fromTimeInterval: -minutes * 60))
  }

  /// Shared rather than built per call: `updatedText` runs on every minute tick of each card.
  private static let updatedFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .short
    return formatter
  }()

  private static func share(_ airtime: UInt32, of uptime: UInt32) -> Double? {
    guard uptime > 0 else { return nil }
    return min(max(Double(airtime) / Double(uptime), 0), 1)
  }

  private static func percentText(_ fraction: Double) -> String {
    (fraction * 100).formatted(.number.precision(.fractionLength(airtimePercentFractionDigits))) + "%"
  }

  // MARK: - Delta Display

  var previousSnapshotTimestamp: String? {
    guard let prev = previousStatusSnapshot else { return nil }
    let interval = prev.timestamp.distance(to: .now)
    let secondsPerHour = TimeInterval(Self.secondsPerHour)
    let secondsPerDay = TimeInterval(Self.secondsPerDay)
    if interval < secondsPerHour {
      return L10n.RemoteNodes.RemoteNodes.History.vsMinutesAgo(Int(interval / 60))
    } else if interval < secondsPerDay {
      return L10n.RemoteNodes.RemoteNodes.History.vsHoursAgo(Int(interval / secondsPerHour))
    } else {
      return L10n.RemoteNodes.RemoteNodes.History.vsDate(prev.timestamp.formatted(.dateTime.month().day()))
    }
  }

  var batteryDeltaMV: Int? {
    guard let current = status?.batteryMillivolts,
          let previous = previousStatusSnapshot?.batteryMillivolts else { return nil }
    return Int(current) - Int(previous)
  }

  var snrDelta: Double? {
    guard let current = status?.lastSNR,
          let previous = previousStatusSnapshot?.lastSNR else { return nil }
    return current - previous
  }

  var rssiDelta: Int? {
    guard let current = status?.lastRSSI,
          let previous = previousStatusSnapshot?.lastRSSI else { return nil }
    return Int(current) - Int(previous)
  }

  var noiseFloorDelta: Int? {
    guard let current = status?.noiseFloor,
          let previous = previousStatusSnapshot?.noiseFloor else { return nil }
    return Int(current) - Int(previous)
  }

  // MARK: - History

  func fetchHistory() async -> [NodeStatusSnapshotDTO] {
    guard let nodeSnapshotService, let publicKey = effectivePublicKey else {
      logger.warning("fetchHistory: nodeSnapshotService or public key is nil")
      return []
    }
    return await nodeSnapshotService.fetchSnapshots(for: publicKey)
  }

  // MARK: - OCV Settings

  /// Load OCV settings for a contact by public key. Skips reload if already loaded.
  /// The battery curve a contact has chosen: its custom voltages when those are complete, its
  /// preset otherwise, and Li-ion when it has neither. Also used to read stored battery readings
  /// on Contact Detail without a login.
  nonisolated static func batteryCurve(presetName: String?, customString: String?) -> (preset: OCVPreset, values: [Int]) {
    if let presetName {
      if presetName == OCVPreset.custom.rawValue, let customString {
        let parsed = customString.split(separator: ",")
          .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parsed.count == 11 {
          return (.custom, parsed)
        }
      }
      if let preset = OCVPreset(rawValue: presetName) {
        return (preset, preset.ocvArray)
      }
    }
    return (.liIon, OCVPreset.liIon.ocvArray)
  }

  func loadOCVSettings(publicKey: Data, radioID: UUID) async {
    guard contactID == nil else { return }
    guard let contactService else { return }

    do {
      if let contact = try await contactService.getContact(radioID: radioID, publicKey: publicKey) {
        contactID = contact.id

        let curve = Self.batteryCurve(presetName: contact.ocvPreset, customString: contact.customOCVArrayString)
        selectedOCVPreset = curve.preset
        ocvValues = curve.values
      }
    } catch {
      ocvError = L10n.RemoteNodes.RemoteNodes.Status.ocvLoadFailed
    }
  }

  func saveOCVSettings(preset: OCVPreset, values: [Int]) async {
    guard let contactService,
          let contactID else {
      ocvError = L10n.RemoteNodes.RemoteNodes.Status.ocvSaveNoContact
      return
    }

    ocvError = nil

    do {
      if preset == .custom {
        let customString = values.map(String.init).joined(separator: ",")
        try await contactService.updateContactOCVSettings(
          contactID: contactID,
          preset: OCVPreset.custom.rawValue,
          customArray: customString
        )
      } else {
        try await contactService.updateContactOCVSettings(
          contactID: contactID,
          preset: preset.rawValue,
          customArray: nil
        )
      }

      selectedOCVPreset = preset
      ocvValues = values
    } catch {
      ocvError = L10n.RemoteNodes.RemoteNodes.Status.ocvSaveFailed(error.userFacingMessage)
    }
  }
}

/// The state the status dashboard draws.
enum NodeStatusDashboardPhase: Equatable {
  /// A reading is on screen, possibly with a refresh in flight or a failed refresh.
  case loaded
  /// No reading yet; the first request is in flight or about to start.
  case loading
  /// The first request failed. The message is already user-facing.
  case failed(String)
  /// No reading and no radio to ask.
  case disconnected
}
