import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RepeaterStatusVM")

/// ViewModel for repeater status display
@Observable
@MainActor
final class RepeaterStatusViewModel {
  // MARK: - Shared Helper

  var helper = NodeStatusViewModel()

  // MARK: - Repeater-Only Properties

  /// Neighbor entries
  var neighbors: [Neighbour] = []

  /// When the latest neighbours list arrived: each entry's `secondsAgo` counts back from about then.
  private(set) var neighborsReceivedAt: Date?

  /// When the latest discovery started (kept after it ends), so the page can tell the neighbours that
  /// answered it from the ones the repeater heard before. Nil until a discovery runs on this visit.
  private(set) var lastDiscoveryStartedAt: Date?

  /// The list split by the latest discovery: heard since it started, and heard before. With no
  /// discovery yet, everything is "this scan" and nothing is "before" (the page shows one list).
  var neighborsByScan: NeighborScanSplit {
    NeighborScanSplit(neighbors: neighbors, scanStartedAt: lastDiscoveryStartedAt, receivedAt: neighborsReceivedAt)
  }

  /// A neighbour can't have been heard before the repeater booted. The hour of slack covers the
  /// gap between the status and neighbours replies.
  var maxPlausibleNeighborAge: Int? {
    guard let uptime = helper.status?.uptimeSeconds else { return nil }
    return Int(uptime) + 3600
  }

  /// Loading states
  var isLoadingNeighbors = false

  /// Whether neighbors have been loaded at least once (for refresh logic)
  var neighborsLoaded = false

  /// Error scoped to the neighbors section, kept separate from other sections' errors.
  var neighborsSectionError: String?

  /// Hex width for neighbour identity prefixes. Set with each neighbours response so on-screen
  /// identifiers keep their width if the companion disconnects while the list is shown.
  var neighborKeyDisplayByteCount = NeighborNameResolver.minimumKeyDisplayByteCount

  /// Discovery state
  var isDiscovering: Bool {
    discoverTask != nil
  }

  var discoverySecondsRemaining = 0
  private var discoverTask: Task<Void, Never>?

  static let discoveryDuration = 60
  private static let pollIntervalTicks = 5
  private static let discoverCommand = "discover.neighbors"

  /// How many neighbours the last discovery that ran its full window ended with; nil before one
  /// finishes and while one runs, so the card only reports a result that's current.
  private(set) var lastDiscoveryNeighborCount: Int?

  /// Bumped when a discovery finishes or fails, as haptic triggers for the page showing it.
  private(set) var discoveryCompletionCount = 0
  private(set) var discoveryFailureCount = 0

  /// Owner info text
  var ownerInfo: String?

  /// Firmware version reported by the node's owner-info response; nil when the
  /// node predates owner-info (FIRMWARE_VER_LEVEL < 2) and returns an empty string.
  var firmwareVersion: String?

  /// Owner info loading/state
  var isLoadingOwnerInfo = false
  var ownerInfoLoaded: Bool {
    ownerInfo != nil
  }

  var ownerInfoError: String?

  // MARK: - Dependencies

  private var repeaterAdminServiceProvider: @MainActor () -> RepeaterAdminService? = { nil }
  var repeaterAdminService: RepeaterAdminService? {
    repeaterAdminServiceProvider()
  }

  /// Where neighbour lists go for the Traffic maps; tests hand in their own.
  @ObservationIgnored var trafficSentLog = TrafficSentLog.shared

  private var deviceHashSizeProvider: @MainActor () -> Int? = { nil }
  private var deviceHashSize: Int? {
    deviceHashSizeProvider()
  }

  // MARK: - Initialization

  init() {}

  /// Nil services mirror a disconnected state; requests then no-op.
  func configure(
    repeaterAdminService: @escaping @MainActor () -> RepeaterAdminService?,
    contactService: @escaping @MainActor () -> ContactService?,
    nodeSnapshotService: @escaping @MainActor () -> NodeSnapshotService?,
    deviceHashSize: @escaping @MainActor () -> Int?
  ) {
    repeaterAdminServiceProvider = repeaterAdminService
    deviceHashSizeProvider = deviceHashSize
    helper.configure(
      contactService: contactService,
      nodeSnapshotService: nodeSnapshotService
    )
  }

  /// Reads the live service from the provider so a reconnect-minted instance
  /// is used at call time. Sets only the slots this view model owns; the admin
  /// service is shared with the settings/CLI view model, so clearing here would
  /// drop its CLI handler and silently break late CLI-response delivery.
  func registerHandlers() async {
    guard let repeaterAdminService else { return }

    await repeaterAdminService.setStatusHandler { [weak self] status in
      guard await self?.helper.matchesSession(status.publicKeyPrefix) == true else { return }
      await self?.handleStatusResponse(status)
    }

    await repeaterAdminService.setNeighboursHandler { [weak self] response in
      guard await self?.helper.matchesSession(response.publicKeyPrefix) == true else { return }
      await self?.handleNeighboursResponse(response)
    }

    await repeaterAdminService.setTelemetryHandler { [weak self] response in
      guard await self?.helper.matchesSession(response.publicKeyPrefix) == true else { return }
      await self?.helper.handleTelemetryResponse(response)
    }
  }

  /// Clear every handler slot on the shared admin service. Only for true
  /// surface teardown (sheet dismiss); calling it on a segment switch would
  /// wipe the CLI handler the settings view model relies on.
  func cleanup() async {
    guard let repeaterAdminService else { return }
    await repeaterAdminService.clearHandlers()
  }

  /// Clear only this view model's status/neighbours/telemetry handler slots, leaving the
  /// settings view model's CLI handler intact. For the merged admin surface's status-segment teardown.
  func clearStatusHandlers() async {
    guard let repeaterAdminService else { return }
    await repeaterAdminService.clearStatusHandlers()
  }

  // MARK: - Status

  func requestStatus(for session: RemoteNodeSessionDTO) async {
    guard let repeaterAdminService else { return }
    if helper.session == nil { helper.session = session }

    await helper.runRetryingSectionRequest(
      operationName: "status",
      setLoading: { self.helper.isLoadingStatus = $0 },
      setError: { self.helper.statusSectionError = $0 },
      operation: { [repeaterAdminService] timeout in
        try await repeaterAdminService.requestStatus(sessionID: session.id, timeout: timeout)
      },
      onSuccess: { await self.handleStatusResponse($0) }
    )
  }

  private func handleStatusResponse(_ response: StatusResponse) async {
    await helper.handleStatusResponse(
      response,
      rxAirtimeSeconds: response.repeaterRxAirtimeSeconds,
      receiveErrors: response.receiveErrors
    )
  }

  // MARK: - Neighbors

  func requestNeighbors(for session: RemoteNodeSessionDTO) async {
    guard let repeaterAdminService else { return }
    if helper.session == nil { helper.session = session }

    await helper.runRetryingSectionRequest(
      operationName: "neighbors",
      setLoading: { self.isLoadingNeighbors = $0 },
      setError: { self.neighborsSectionError = $0 },
      operation: { [repeaterAdminService] timeout in
        try await repeaterAdminService.fetchAllNeighbors(sessionID: session.id, timeout: timeout)
      },
      onSuccess: { await self.handleNeighboursResponse($0) }
    )
  }

  func handleNeighboursResponse(_ response: NeighboursResponse, receivedAt: Date = .now) async {
    neighbors = response.neighbours
    neighborsReceivedAt = receivedAt
    neighborKeyDisplayByteCount = NeighborNameResolver.keyDisplayByteCount(deviceHashSize: deviceHashSize)
    isLoadingNeighbors = false
    neighborsLoaded = true
    // The Traffic maps draw each neighbour newly heard (a scan's answers) out from the repeater.
    trafficSentLog.recordNeighbours(
      repeater: helper.session?.publicKey ?? response.publicKeyPrefix,
      neighbours: response.neighbours
    )

    let entries = response.neighbours.map {
      NeighborSnapshotEntry(publicKeyPrefix: $0.publicKeyPrefix, snr: $0.snr, secondsAgo: $0.secondsAgo)
    }
    await helper.enrichNeighbors(entries)
  }

  // MARK: - Discovery

  /// The one-tap Discover action (the status page's card and the Settings segment's tile): asks
  /// the status page to open the Neighbours page, and starts discovery unless one is running, so
  /// a second tap just brings the running one back into view.
  func startDiscovery(for session: RemoteNodeSessionDTO) {
    guard let repeaterAdminService, !isDiscovering else { return }

    discoverySecondsRemaining = Self.discoveryDuration
    lastDiscoveryNeighborCount = nil
    lastDiscoveryStartedAt = .now
    neighborsSectionError = nil

    discoverTask = Task {
      do {
        _ = try await repeaterAdminService.sendCommand(
          sessionID: session.id,
          command: Self.discoverCommand
        )
      } catch {
        // Stopping discovery cancels this task mid-send. That is a normal stop, and
        // `stopDiscovery` has already reset the state, possibly for a newer run.
        guard !(error is CancellationError), !Task.isCancelled else { return }
        neighborsSectionError = error.userFacingMessage
        discoverySecondsRemaining = 0
        discoverTask = nil
        discoveryFailureCount += 1
        return
      }

      // Show what the repeater already knows straight away rather than after the first poll.
      // A fetch already in flight (a manual reload) covers that, and a second one alongside it
      // would double the traffic on the mesh.
      if !neighborsLoaded, !isLoadingNeighbors, !Task.isCancelled {
        await requestNeighbors(for: session)
      }

      let startTime = Date.now
      var tickCount = 0

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }

        let elapsed = Int(Date.now.timeIntervalSince(startTime))
        let remaining = max(0, Self.discoveryDuration - elapsed)
        discoverySecondsRemaining = remaining

        tickCount += 1
        if tickCount.isMultiple(of: Self.pollIntervalTicks) {
          await requestNeighbors(for: session)
        }

        if remaining <= 0 { break }
      }

      // A stop resets the state itself (possibly for a newer run), so only a full run reports.
      guard !Task.isCancelled else { return }
      discoverySecondsRemaining = 0
      discoverTask = nil
      // The loop's last poll lands on the final second. If it failed (the repeater stopped
      // answering, or the companion dropped), the count is stale, so report a failure instead.
      if neighborsSectionError == nil, self.repeaterAdminService != nil {
        finishDiscovery()
      } else {
        discoveryFailureCount += 1
      }
    }
  }

  /// Records the result of a discovery that ran its full window.
  func finishDiscovery() {
    lastDiscoveryNeighborCount = neighborsByScan.thisScan.count   // the ones that answered this run
    discoveryCompletionCount += 1
  }

  func stopDiscovery() {
    discoverTask?.cancel()
    discoverTask = nil
    discoverySecondsRemaining = 0
  }

  // MARK: - Telemetry

  func requestTelemetry(for session: RemoteNodeSessionDTO) async {
    guard let repeaterAdminService else { return }
    if helper.session == nil { helper.session = session }

    await helper.runRetryingSectionRequest(
      operationName: "telemetry",
      setLoading: { self.helper.isLoadingTelemetry = $0 },
      setError: { self.helper.telemetrySectionError = $0 },
      operation: { [repeaterAdminService] timeout in
        try await repeaterAdminService.requestTelemetry(sessionID: session.id, timeout: timeout)
      },
      onSuccess: { await self.helper.handleTelemetryResponse($0) }
    )
  }

  // MARK: - Owner Info

  func requestOwnerInfo(for session: RemoteNodeSessionDTO) async {
    guard let repeaterAdminService else { return }
    if helper.session == nil { helper.session = session }

    await helper.runRetryingSectionRequest(
      operationName: "ownerInfo",
      setLoading: { self.isLoadingOwnerInfo = $0 },
      setError: { self.ownerInfoError = $0 },
      operation: { [repeaterAdminService] timeout in
        try await repeaterAdminService.requestOwnerInfo(sessionID: session.id, timeout: timeout)
      },
      onSuccess: { self.applyOwnerInfo($0) }
    )
  }

  /// Applies an owner-info response to the display state, mapping an empty firmware
  /// string (nodes predating owner-info, FIRMWARE_VER_LEVEL < 2) to nil so the
  /// firmware row stays hidden rather than showing a blank value.
  func applyOwnerInfo(_ response: OwnerInfoResponse) {
    ownerInfo = response.ownerInfo
    firmwareVersion = response.firmwareVersion.isEmpty ? nil : response.firmwareVersion
  }

  // MARK: - Repeater-Only Display

  var receiveErrorsDisplay: String? {
    guard let count = helper.status?.receiveErrors, count > 0 else { return nil }
    return count.formatted()
  }
}

/// A neighbours list split by a discovery: the entries the repeater heard since the scan started
/// (its answers, and anything else heard meanwhile) and the ones it heard before. The repeater
/// reports each entry's age (`secondsAgo`) when it builds the reply, so "heard at" is the reply's
/// arrival less that age; `slack` covers the reply's trip back and the two clocks' second
/// rounding. A list that arrived before the scan started is all "before".
struct NeighborScanSplit: Equatable {
  static let slack: TimeInterval = 3

  let thisScan: [Neighbour]
  let before: [Neighbour]
  /// A discovery has run: the page shows two groups instead of one list.
  let isSplit: Bool

  init(neighbors: [Neighbour], scanStartedAt: Date?, receivedAt: Date?) {
    guard let scanStartedAt, let receivedAt else {
      thisScan = neighbors
      before = []
      isSplit = false
      return
    }
    isSplit = true
    guard receivedAt >= scanStartedAt else {
      thisScan = []
      before = neighbors
      return
    }
    let cutoff = scanStartedAt.addingTimeInterval(-Self.slack)
    var now: [Neighbour] = []
    var old: [Neighbour] = []
    for neighbor in neighbors {
      let heardAt = receivedAt.addingTimeInterval(-TimeInterval(neighbor.secondsAgo))
      if heardAt >= cutoff { now.append(neighbor) } else { old.append(neighbor) }
    }
    thisScan = now
    before = old
  }
}
