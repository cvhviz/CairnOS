import CairnServices
import CoreLocation
import Foundation
import MeshCore
import OSLog

/// Runs every Scan for Nodes probe, for the phone, CarPlay and Wardrive alike. One instance,
/// owned by AppState, so leaving the screen, CarPlay or a rebuilt connection never ends a probe
/// silently, and two screens can never send two requests: a second request while one is in its
/// window attaches to it.
///
/// A probe is optional extra evidence. The neighbour list fills passively from what the radio
/// hears; a probe asks nearby nodes to answer one `NODE_DISCOVER_REQ`:
/// 1. ask the process-wide `DiscoverRequestGate`; when it refuses, nothing goes on air and the
///    state says until when and why;
/// 2. wait up to ``fixWaitLimit`` for a fresh phone fix, so the first replies get a heard-from
///    position;
/// 3. hand the probe's tag to the neighbour service, so replies carrying it count as answers to
///    us even when one lands before the send returns; send, and record the send with the gate;
/// 4. listen for `DiscoverListenWindow` seconds, extended by late replies, then summarize.
///
/// Radio firmware without the discover command (official companion firmware before v1.10, or a
/// radio that refuses the request) can't probe: requests are refused with
/// ``RequestOutcome/unsupported`` and ``isDiscoverSupported`` is false. Scan for Nodes then runs a
/// scan that only listens (``requestListen(filter:origin:)``): nothing goes on air, and the scan's
/// list fills from what the radio hears.
///
/// Every scan that starts, sent or only listening, becomes ``currentScan``: Scan for Nodes lists
/// what was heard from its start on, until the next one starts. Wardrive is one scan from Start
/// to Stop (``wardriveSession``): its probes add to that list rather than starting it over.
///
/// While a probe listens, the session holds back optional traffic such as message fetches, so the
/// replies don't overflow the radio's small send queue; the hold ends with the probe, however it
/// ends. Where the radio can count it, the summary says how many packets it heard from the send to
/// the end of the window that never reached the app, read after the probe has ended so neither
/// the send nor the end waits for it.
///
/// Nothing is ever retried automatically. Wardrive asks again each time the gate allows.
@Observable
@MainActor
final class DiscoveryProbeCoordinator {
  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "DiscoveryProbeCoordinator")
  /// Longest a probe holds its request for a fresh fix. Following starts with the probe, and its
  /// first update is often an old or coarse one; the first replies (the nearest, strongest nodes)
  /// land within seconds, and a reply with no fresh fix gets no heard-from position.
  static let fixWaitLimit: TimeInterval = 5
  static let fixPollInterval: TimeInterval = 0.1
  /// How often the phone's fix goes to the neighbour service while location is followed, so
  /// evidence (relays too) is stamped with where it was heard.
  static let fixFeedInterval: TimeInterval = 1
  /// The coordinator's one claim on the location service's following updates.
  static let locationClient = "nodeDiscovery.probe"
  /// The name probes hold the session's optional traffic under.
  static let trafficHoldOwner = "nodeDiscovery.probe"
  /// The longest a probe's request waits, once its fix is ready, for the delivery reading the
  /// window is measured from. A reading whose reply the radio dropped would otherwise hold the
  /// request for the session's whole timeout; without it the summary has no missed count.
  static let startMarkLimit: TimeInterval = 1

  /// Who asked for a probe.
  enum Origin: Hashable, Sendable {
    case phone
    case carPlay
    case wardrive
  }

  /// One discover request and its listen window.
  struct Probe: Equatable {
    let filter: NodeDiscoveryFilter
    /// The radio it was asked from; a probe never carries over to another radio.
    let radioID: UUID
    /// Everyone waiting on it: the first asker and every request that attached.
    var origins: Set<Origin>
    /// Set once the request went out; nil while the gate is asked and the probe waits for a fix.
    var tag: UInt32?
    var sentAt: Date?
    /// When the listen window ends; late replies move it out.
    var endsAt: Date?
    /// A scan on a radio that can't send a discover request: nothing went on air, it only
    /// listens for its window (``requestListen(filter:origin:)``).
    var listensOnly = false
  }

  /// The scan whose list Scan for Nodes shows: it lists what the radio heard from ``startedAt`` on,
  /// until the next scan starts. Wall-clock, as every neighbour reception is stamped.
  struct Scan: Equatable {
    /// The radio it was started on; a scan never carries over to another radio.
    let radioID: UUID
    let filter: NodeDiscoveryFilter
    /// When the gate let it go (or the listen-only scan began): before the request goes on air,
    /// so every answer, and everything heard while it waited for a fix, counts as this scan's.
    let startedAt: Date
    /// It only listened: the radio can't send a discover request.
    let listensOnly: Bool
  }

  /// One Wardrive run, from Start to Stop: the probes it sent and the ground it covered. Kept
  /// after it ends (``endedAt`` set) until the next one starts or it is dismissed, so its figures
  /// stay on screen. The nodes it found are the list of ``currentScan``, which runs for the
  /// whole drive.
  struct WardriveSession: Equatable {
    /// A fix's place, for the distance between two.
    struct Point: Equatable {
      let latitude: Double
      let longitude: Double
    }

    /// A move shorter than this, or shorter than the fix's own uncertainty, is GPS jitter: it
    /// doesn't count toward the distance.
    static let minimumMove: CLLocationDistance = 10

    let filter: NodeDiscoveryFilter
    let startedAt: Date
    var endedAt: Date?
    var probeCount = 0
    /// Metres driven, from the fixes recorded while it ran.
    var distanceMeters: CLLocationDistance = 0
    /// The last fix that counted.
    var lastPoint: Point?

    var isRunning: Bool { endedAt == nil }

    func elapsed(now: Date) -> TimeInterval {
      max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Adds the distance from the last counted fix to `fix`, when it is a real move.
    mutating func note(fix: NeighbourFix?) {
      guard let fix else { return }
      let point = Point(latitude: fix.latitude, longitude: fix.longitude)
      guard let last = lastPoint else {
        lastPoint = point
        return
      }
      let distance = CLLocation(latitude: last.latitude, longitude: last.longitude)
        .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
      guard distance >= max(Self.minimumMove, fix.horizontalAccuracy) else { return }
      distanceMeters += distance
      lastPoint = point
    }
  }

  enum State: Equatable {
    case idle
    case probing(Probe)
    /// The connection was rebuilt (or dropped) during the probe's window. Nothing is re-sent; the
    /// window runs out and evidence keeps arriving through the new connection.
    case interrupted(Probe)
    /// The gate refuses a request until `until`.
    case coolingDown(until: Date, reason: DiscoverRequestGate.Reason)
  }

  /// What one request for a probe did.
  enum RequestOutcome: Equatable {
    case started
    /// A probe was already running; the request joined it.
    case attached
    case coolingDown(until: Date, reason: DiscoverRequestGate.Reason)
    case notConnected
    /// The radio's firmware can't send a discover request; nothing went on air.
    case unsupported
  }

  /// What a finished probe heard.
  struct Summary: Equatable {
    let filter: NodeDiscoveryFilter
    /// Neighbours whose reply carried the probe's tag.
    let answered: Int
    /// Other neighbours heard relaying in the live band.
    let heardRelaying: Int
    let finishedAt: Date
    /// Packets the radio heard from just before the request to the end of the window that never
    /// reached the app, so some replies may be missing; nil when it couldn't be measured
    /// (firmware without packet counters, a stopped or interrupted probe, a reading too slow)
    /// and until it has been read, just after the probe ends.
    var radioMissed: Int?
  }

  /// Where the connection's delivery stood when a probe was about to go on air
  /// (`RxStreamService.deliveryMark()`).
  struct DeliveryMark: Sendable {
    /// The packets the radio heard since the mark that never reached the app, read after a
    /// quiet link; nil when they can't be counted.
    let packetsMissedSince: @Sendable () async -> Int?
  }

  /// What a probe needs from one connection.
  struct Binding {
    /// The connection's identity: a rebuilt connection is a new binding.
    let id: ObjectIdentifier
    let radioID: UUID
    /// `DiscoverListenWindow.seconds(for:)` of the connected radio.
    var listenWindow: TimeInterval
    /// Sends one full-key `NODE_DISCOVER_REQ` with this filter and tag.
    var sendDiscoverRequest: @Sendable (_ filter: UInt8, _ tag: UInt32) async throws -> Void
    var noteProbe: @Sendable (_ tag: UInt32, _ filter: UInt8, _ at: Date) async -> Void
    /// Discover requests others sent, the last 120 s first.
    var overheardRequests: @Sendable () async -> AsyncStream<Date>
    var updateLocationFix: @Sendable (NeighbourFix?) async -> Void
    /// Whether the radio's firmware can send a discover request (`DeviceDTO.supportsNodeDiscover`,
    /// companion v1.10+). Turned off for this connection when the radio refuses one.
    var canDiscover = true
    /// Holds the session's optional traffic back for a listen window (capped at 30 s by the
    /// session), so message fetches don't compete with the replies for the radio's send queue.
    var holdBackgroundTraffic: @Sendable (Duration) async -> Void = { _ in }
    /// Ends that hold early: the request failed, or the probe was stopped or abandoned.
    var releaseBackgroundTraffic: @Sendable () async -> Void = {}
    /// Where delivery stands now, to count the packets missed over a probe; nil when it can't be
    /// measured.
    var deliveryMark: @Sendable () async -> DeliveryMark? = { nil }
  }

  /// The phone's location, as far as probes need it.
  struct Location {
    /// The newest fix, however old; `NodeDiscoveryReception.fix` decides if it is fresh.
    var latestFix: @MainActor () -> CLLocation?
    /// Whether following can deliver a fix at all (location allowed).
    var canFollow: @MainActor () -> Bool
    /// Starts or stops the coordinator's following claim.
    var setDemand: @MainActor (NodeDiscoveryLocationDemand) -> Void
  }

  // MARK: - State

  private(set) var state: State = .idle
  /// The last finished probe's summary; kept until the next one finishes.
  private(set) var lastSummary: Summary?
  /// The newest scan started on the bound radio this session, kept after it ends until the next
  /// one starts or another radio is bound. Nil before the first scan.
  private(set) var currentScan: Scan?
  /// Why the last probe couldn't be sent; cleared by the next request.
  private(set) var lastError: String?
  /// Probes that went on air, for haptics and tests.
  private(set) var sentProbeCount = 0
  /// Probing each time the gate allows, until switched off or the radio disconnects.
  private(set) var isWardriving = false
  /// The kind Wardrive asks for.
  private(set) var wardriveFilter: NodeDiscoveryFilter = .repeaters
  /// Probes Wardrive has sent since it was switched on.
  private(set) var wardriveProbeCount = 0
  /// When Wardrive asks next, for its countdown; nil while it probes.
  private(set) var nextWardriveProbeAt: Date?
  /// The Wardrive running, or the last one until it is dismissed or the next starts.
  private(set) var wardriveSession: WardriveSession?
  /// Whether the bound radio can be asked to probe: false on firmware without the discover
  /// command (official companion firmware before v1.10) or after the radio refused one. True
  /// while unbound, where requests are refused as not connected instead.
  private(set) var isDiscoverSupported = true

  @ObservationIgnored private let gate: DiscoverRequestGate
  @ObservationIgnored private let location: Location
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private var binding: Binding?
  /// The newest neighbour snapshot of the bound radio, for window extension and the summary.
  @ObservationIgnored private var latestSnapshot: NeighbourSnapshot?
  /// The newest reply to the running probe seen so far.
  @ObservationIgnored private var latestReplyAt: Date?
  /// Bumped whenever a probe ends or is abandoned, so its task can't touch a later one.
  @ObservationIgnored private var probeGeneration = 0
  @ObservationIgnored private var probeTask: Task<Void, Never>?
  /// Callers of ``waitForProbe()`` while a probe has no task yet (the gate is being asked).
  @ObservationIgnored private var probeWaiters: [CheckedContinuation<Void, Never>] = []
  /// The gate slots probes were granted and `recordOwn` hasn't settled yet, by probe generation.
  @ObservationIgnored private var reservations: [Int: Reservation] = [:]
  @ObservationIgnored private var cooldownTask: Task<Void, Never>?
  @ObservationIgnored private var wardriveTask: Task<Void, Never>?
  @ObservationIgnored private var overheardTask: Task<Void, Never>?
  @ObservationIgnored private var fixFeedTask: Task<Void, Never>?
  /// What `location.setDemand` was last told, so it hears only changes.
  @ObservationIgnored private var sentDemand: NodeDiscoveryLocationDemand = .none
  /// Ends the running probe's hold on the session's traffic, on the connection that holds it.
  @ObservationIgnored private var heldTraffic: (@Sendable () async -> Void)?

  /// A slot `DiscoverRequestGate.request()` granted. Every one is settled with `recordOwn` exactly
  /// once, sent or not, so the gate's next confirmation lands on the next probe's own slot.
  private struct Reservation {
    let at: Date
    /// The request is being written: whatever happens next, the send settles it.
    var isSending = false
  }

  /// - Parameters:
  ///   - gate: The process-wide discover gate.
  ///   - now: The clock windows and cooldowns are measured against; tests inject a fake one,
  ///     shared with the gate's.
  ///   - sleep: How the coordinator waits; tests drive it with a test clock.
  init(
    gate: DiscoverRequestGate,
    location: Location,
    now: @escaping () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.gate = gate
    self.location = location
    self.now = now
    self.sleep = sleep
  }

  isolated deinit {
    for waiter in probeWaiters {
      waiter.resume()
    }
    probeTask?.cancel()
    cooldownTask?.cancel()
    wardriveTask?.cancel()
    overheardTask?.cancel()
    fixFeedTask?.cancel()
    if sentDemand != .none { location.setDemand(.none) }
  }

  /// The probe asking, waiting for a fix or listening, interrupted or not.
  var activeProbe: Probe? {
    switch state {
    case let .probing(probe), let .interrupted(probe): probe
    case .idle, .coolingDown: nil
    }
  }

  var isProbing: Bool {
    activeProbe != nil
  }

  /// The location this coordinator needs: following during a probe, and in the background for as
  /// long as Wardrive runs, between its probes too. Nothing while disconnected.
  var locationDemand: NodeDiscoveryLocationDemand {
    guard binding != nil else { return .none }
    if isWardriving { return .wardrive }
    return isProbing ? .scan : .none
  }

  // MARK: - Binding

  /// Binds to the wired connection. Binding the same connection again only refreshes its listen
  /// window. A new connection during a probe's window interrupts it: the window runs out, nothing
  /// is re-sent, and what was heard is kept. A connection to another radio abandons the probe.
  func bind(_ new: Binding) {
    if let current = binding, current.id == new.id {
      var refreshed = new
      // A refusal from this connection's radio outlives re-wiring it
      refreshed.canDiscover = current.canDiscover && new.canDiscover
      binding = refreshed
      isDiscoverSupported = refreshed.canDiscover
      if !refreshed.canDiscover { clearCooldown() }
      return
    }
    binding = new
    isDiscoverSupported = new.canDiscover
    // A radio that can't send a scan never waits on the gate: its scans only listen
    if !new.canDiscover { clearCooldown() }
    overheardTask?.cancel()
    let gate = gate
    let overheardRequests = new.overheardRequests
    overheardTask = Task {
      let requests = await overheardRequests()
      for await date in requests {
        guard !Task.isCancelled else { return }
        await gate.noteOverheard(at: date)
      }
    }
    if latestSnapshot?.radioID != new.radioID {
      latestSnapshot = nil
    }
    if currentScan?.radioID != new.radioID {
      // Another radio's scan lists another radio's neighbours
      currentScan = nil
    }
    if let probe = activeProbe {
      if probe.radioID != new.radioID {
        abandonProbe()
      } else if let tag = probe.tag, let sentAt = probe.sentAt {
        state = .interrupted(probe)
        // The new service hears the rest of the window's replies; they are still answers to us
        let noteProbe = new.noteProbe
        let filter = probe.filter.filterValue
        Task { await noteProbe(tag, filter, sentAt) }
      }
    }
    syncLocationDemand()
  }

  /// The radio disconnected: Wardrive stops, the location claim goes back, and a probe in its
  /// window is interrupted (one not yet sent is abandoned).
  func handleDisconnect() {
    stopWardrive()
    binding = nil
    isDiscoverSupported = true
    overheardTask?.cancel()
    overheardTask = nil
    if let probe = activeProbe {
      if probe.sentAt != nil {
        state = .interrupted(probe)
      } else {
        abandonProbe()
      }
    }
    syncLocationDemand()
  }

  /// Takes the newest neighbour snapshot: a reply to the running probe near the end of its window
  /// pushes the window out (`DiscoverListenWindow.extendedEnd`).
  func noteSnapshot(_ snapshot: NeighbourSnapshot) {
    if let radioID = binding?.radioID ?? activeProbe?.radioID, snapshot.radioID != radioID { return }
    latestSnapshot = snapshot
    guard var probe = activeProbe, !probe.listensOnly, let sentAt = probe.sentAt, let endsAt = probe.endsAt,
          let reply = Self.latestReply(in: snapshot, since: sentAt),
          reply > (latestReplyAt ?? .distantPast) else { return }
    latestReplyAt = reply
    let extended = DiscoverListenWindow.extendedEnd(endsAt, start: sentAt, reply: reply)
    guard extended != endsAt else { return }
    probe.endsAt = extended
    replaceActiveProbe(probe)
    // The hold follows the window out, for the late replies
    if let binding, binding.radioID == probe.radioID {
      let hold = binding.holdBackgroundTraffic
      let release = binding.releaseBackgroundTraffic
      let remaining = max(0, extended.timeIntervalSince(now()))
      let generation = probeGeneration
      heldTraffic = release
      Task { [weak self] in
        await hold(.seconds(remaining))
        // The probe ended while the hold was being placed: it must not outlive it
        if self?.probeGeneration != generation { await release() }
      }
    }
  }

  // MARK: - Probing

  /// Asks for one probe. Attaches to a probe already running; otherwise asks the gate, and when
  /// it allows, starts the probe and returns at once (the probe runs on in the background). A
  /// radio that can't send a discover request is refused before the gate is asked.
  @discardableResult
  func requestProbe(filter: NodeDiscoveryFilter, origin: Origin) async -> RequestOutcome {
    if var probe = activeProbe {
      probe.origins.insert(origin)
      replaceActiveProbe(probe)
      return .attached
    }
    guard let binding else { return .notConnected }
    guard binding.canDiscover else { return .unsupported }
    lastError = nil
    cooldownTask?.cancel()
    cooldownTask = nil
    probeGeneration += 1
    let generation = probeGeneration
    // Probing before the gate answers, so a request arriving meanwhile attaches
    state = .probing(Probe(filter: filter, radioID: binding.radioID, origins: [origin]))
    syncLocationDemand()

    let decision = await gate.request()
    if decision == .allowed {
      reservations[generation] = Reservation(at: now())
    }
    guard generation == probeGeneration else {
      // abandoned while the gate answered: nothing was sent, but the slot stays counted
      settleUnsentReservations()
      return .notConnected
    }
    if case let .coolingDown(until, reason) = decision {
      enterCooldown(until: until, reason: reason)
      syncLocationDemand()
      return .coolingDown(until: until, reason: reason)
    }
    // A new scan: its list starts now. It stands even if the request then fails to go out, since
    // the list still fills with what is heard from here on. Wardrive is one scan from Start to
    // Stop: its probes add to the list rather than starting it over.
    if !isWardriving {
      currentScan = Scan(radioID: binding.radioID, filter: filter, startedAt: now(), listensOnly: false)
    }
    probeTask = Task { [weak self] in
      await self?.runProbe(generation: generation)
    }
    resumeProbeWaiters()
    return .started
  }

  /// Starts a scan that only listens, for a radio whose firmware can't send a discover request
  /// (official companion firmware before v1.10, or one that refused): a new list starts now and
  /// fills with what the radio hears for the listen window and after, as a sent scan's does.
  /// Nothing goes on air, so the gate isn't asked and no cooldown applies. Attaches to a probe
  /// already running.
  @discardableResult
  func requestListen(filter: NodeDiscoveryFilter, origin: Origin) -> RequestOutcome {
    if var probe = activeProbe {
      probe.origins.insert(origin)
      replaceActiveProbe(probe)
      return .attached
    }
    guard let binding else { return .notConnected }
    lastError = nil
    probeGeneration += 1
    let generation = probeGeneration
    let start = now()
    currentScan = Scan(radioID: binding.radioID, filter: filter, startedAt: start, listensOnly: true)
    state = .probing(Probe(
      filter: filter,
      radioID: binding.radioID,
      origins: [origin],
      sentAt: start,
      endsAt: start.addingTimeInterval(binding.listenWindow),
      listensOnly: true
    ))
    syncLocationDemand()
    probeTask = Task { [weak self] in
      await self?.runListen(generation: generation)
    }
    resumeProbeWaiters()
    return .started
  }

  /// Ends the running probe's window now. A request already sent stays sent; one still waiting
  /// for a fix is dropped (its gate slot stays spent).
  func stopProbe() {
    guard let probe = activeProbe else { return }
    if probe.sentAt != nil, !probe.listensOnly {
      lastSummary = summary(for: probe)
    }
    abandonProbe()
    Task { await refreshCooldown() }
  }

  /// Re-reads the gate, for a screen opening: shows a cooldown another screen's probe (or others
  /// nearby) started, or clears one that has run out. A running probe is left alone. A radio
  /// whose firmware can't send a discover request shows none: its scans only listen, so nothing
  /// the gate counts (requests overheard from others, or this app's own from another radio)
  /// holds them back.
  func refreshCooldown() async {
    let decision = await gate.status()
    guard activeProbe == nil else { return }
    if let binding, !binding.canDiscover {
      clearCooldown()
      return
    }
    switch decision {
    case .allowed:
      cooldownTask?.cancel()
      cooldownTask = nil
      state = .idle
    case let .coolingDown(until, reason):
      if state != .coolingDown(until: until, reason: reason) || cooldownTask == nil {
        enterCooldown(until: until, reason: reason)
      }
    }
  }

  func clearError() {
    lastError = nil
  }

  /// Waits until the running probe (if any) has finished. For Wardrive and tests.
  ///
  /// A probe has no task while the gate is being asked; a caller attaching then waits for the
  /// probe to start (or be refused) first, so it always suspends while a probe is active.
  func waitForProbe() async {
    while probeTask == nil, isProbing {
      await withCheckedContinuation { probeWaiters.append($0) }
    }
    await probeTask?.value
  }

  /// Wakes every ``waitForProbe()`` caller parked in the gate phase: the probe started or ended.
  private func resumeProbeWaiters() {
    let waiters = probeWaiters
    probeWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// Settles the gate slot of the probe of `generation` as sent at `date`.
  private func settleReservation(generation: Int, at date: Date) async {
    guard reservations.removeValue(forKey: generation) != nil else { return }
    await gate.recordOwn(at: date)
  }

  /// Settles the slots whose requests never went out, at the times they were granted: the gate
  /// keeps counting them, which only makes it more cautious. One being written is settled by its
  /// send.
  private func settleUnsentReservations() {
    let unsent = reservations.filter { !$0.value.isSending }
    guard !unsent.isEmpty else { return }
    for generation in unsent.keys {
      reservations[generation] = nil
    }
    let gate = gate
    let dates = unsent.values.map(\.at).sorted()
    Task {
      for date in dates {
        await gate.recordOwn(at: date)
      }
    }
  }

  private func runProbe(generation: Int) async {
    await waitForFreshFix()
    guard generation == probeGeneration, var probe = activeProbe else { return }
    guard let binding, binding.radioID == probe.radioID else {
      abandonProbe()
      return
    }
    await binding.updateLocationFix(currentFix())
    // Delivery is read right before the request, so the window measured starts at the send, and
    // before the window's hold would delay the reading; a slow reading doesn't hold the send
    let mark = await readDeliveryMark(binding.deliveryMark, within: Self.startMarkLimit)
    guard generation == probeGeneration else { return }

    // The tag is noted before the send: a close node can answer before the send returns
    let tag = UInt32.random(in: 1...UInt32.max)
    let filter = probe.filter.filterValue
    let sentAt = now()
    await binding.noteProbe(tag, filter, sentAt)
    guard generation == probeGeneration else { return }
    heldTraffic = binding.releaseBackgroundTraffic
    await binding.holdBackgroundTraffic(.seconds(binding.listenWindow))
    guard generation == probeGeneration else {
      // Abandoned while the hold was being placed: it must not outlive the probe
      await binding.releaseBackgroundTraffic()
      return
    }
    reservations[generation]?.isSending = true
    do {
      try await binding.sendDiscoverRequest(filter, tag)
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      // Refused before air (official companion firmware before v1.10): no repeater spent a token
      Self.logger.info("Radio firmware has no discover command; probes are off for this connection")
      if reservations.removeValue(forKey: generation) != nil {
        await gate.releaseReservation()
      }
      markDiscoverUnsupported(bindingID: binding.id)
      guard generation == probeGeneration else { return }
      abandonProbe()
      await refreshCooldown()
      return
    } catch {
      Self.logger.error("Discover request failed: \(error.localizedDescription)")
      // It may still have gone on air (as RegionDiscoveryService counts it)
      await settleReservation(generation: generation, at: sentAt)
      guard generation == probeGeneration else { return }
      lastError = error.userFacingMessage
      abandonProbe()
      await refreshCooldown()
      return
    }
    // It went on air: recorded whatever happened meanwhile
    await settleReservation(generation: generation, at: sentAt)
    sentProbeCount += 1
    guard generation == probeGeneration, let current = activeProbe else { return }
    probe = current
    probe.tag = tag
    probe.sentAt = sentAt
    probe.endsAt = sentAt.addingTimeInterval(binding.listenWindow)
    latestReplyAt = nil
    replaceActiveProbe(probe)
    if let latestSnapshot {
      noteSnapshot(latestSnapshot)
    }

    while let endsAt = activeProbe?.endsAt, now() < endsAt {
      do {
        try await sleep(.seconds(endsAt.timeIntervalSince(now())))
      } catch {
        return
      }
      guard generation == probeGeneration else { return }
    }
    guard generation == probeGeneration, let finished = activeProbe else { return }
    // The probe ends on time; the packets it missed are read after (a quiet link and a stats
    // round trip). A probe the connection was rebuilt under can't compare readings across
    // connections.
    let summary = summary(for: finished)
    lastSummary = summary
    if let mark, case .probing = state {
      Task { [weak self] in
        let missed = await mark.packetsMissedSince()
        guard let self, lastSummary == summary else { return }
        lastSummary?.radioMissed = missed
      }
    }
    abandonProbe()
    await refreshCooldown()
  }

  /// Runs a listen-only scan's window out. It sent nothing, so it has no summary.
  private func runListen(generation: Int) async {
    while generation == probeGeneration, let endsAt = activeProbe?.endsAt, now() < endsAt {
      do {
        try await sleep(.seconds(endsAt.timeIntervalSince(now())))
      } catch {
        return
      }
    }
    guard generation == probeGeneration else { return }
    abandonProbe()
    await refreshCooldown()
  }

  /// `read()`'s delivery mark, or nil when it doesn't come within `limit` seconds (it is then
  /// cancelled) or the calling task is cancelled.
  private func readDeliveryMark(
    _ read: @escaping @Sendable () async -> DeliveryMark?,
    within limit: TimeInterval
  ) async -> DeliveryMark? {
    let race = MarkRace()
    let sleep = sleep
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.continuation = continuation
        race.reading = Task { @MainActor in race.finish(await read()) }
        race.timer = Task { @MainActor in
          guard (try? await sleep(.seconds(limit))) != nil else { return }
          Self.logger.info("Delivery reading took over \(limit) s; probing without a missed count")
          race.finish(nil)
        }
      }
    } onCancel: {
      Task { @MainActor in race.finish(nil) }
    }
  }

  /// The radio of `bindingID` refused a discover request: no more are asked of it, and Wardrive
  /// stops.
  private func markDiscoverUnsupported(bindingID: ObjectIdentifier) {
    guard var current = binding, current.id == bindingID else { return }
    current.canDiscover = false
    binding = current
    isDiscoverSupported = false
  }

  /// Ends the probe state without a summary, cancelling its task and ending its traffic hold.
  private func abandonProbe() {
    probeGeneration += 1
    probeTask?.cancel()
    probeTask = nil
    latestReplyAt = nil
    if let release = heldTraffic {
      heldTraffic = nil
      Task { await release() }
    }
    settleUnsentReservations()
    if activeProbe != nil {
      state = .idle
    }
    syncLocationDemand()
    resumeProbeWaiters()
  }

  private func replaceActiveProbe(_ probe: Probe) {
    switch state {
    case .probing: state = .probing(probe)
    case .interrupted: state = .interrupted(probe)
    case .idle, .coolingDown: break
    }
  }

  /// Shows the cooldown and clears it once it has run out, re-reading the gate then: requests
  /// overheard meanwhile can stretch it.
  /// Ends a cooldown the card shows (the gate keeps counting); any other state is left alone.
  private func clearCooldown() {
    guard case .coolingDown = state else { return }
    cooldownTask?.cancel()
    cooldownTask = nil
    state = .idle
  }

  private func enterCooldown(until: Date, reason: DiscoverRequestGate.Reason) {
    state = .coolingDown(until: until, reason: reason)
    resumeProbeWaiters()
    cooldownTask?.cancel()
    let sleep = sleep
    let wait = max(0, until.timeIntervalSince(now()))
    cooldownTask = Task { [weak self] in
      do {
        try await sleep(.seconds(wait))
      } catch {
        return
      }
      guard let self, state == .coolingDown(until: until, reason: reason) else { return }
      cooldownTask = nil
      await refreshCooldown()
    }
  }

  private func summary(for probe: Probe) -> Summary {
    let date = now()
    let neighbours = latestSnapshot?.neighbours ?? []
    let answered = probe.sentAt.map { sentAt in
      neighbours.filter { ($0.record.sources[.replyToUs]?.lastHeard).map { $0 >= sentAt } ?? false }
    } ?? []
    let answeredIdentities = Set(answered.map(\.record.identity))
    let relaying = neighbours.count { neighbour in
      guard !answeredIdentities.contains(neighbour.record.identity),
            let relay = neighbour.record.sources[.relay] else { return false }
      return NeighbourFreshness(lastHeard: relay.lastHeard, now: date) == .live
    }
    return Summary(filter: probe.filter, answered: answered.count, heardRelaying: relaying, finishedAt: date)
  }

  /// The newest reply to one of our probes heard at or after `sentAt`.
  private static func latestReply(in snapshot: NeighbourSnapshot, since sentAt: Date) -> Date? {
    snapshot.neighbours
      .compactMap { $0.record.sources[.replyToUs]?.lastHeard }
      .filter { $0 >= sentAt }
      .max()
  }

  // MARK: - Wardrive

  /// Probes for `filter` each time the gate allows (never more often than every 45 s), until
  /// switched off or the radio disconnects. Runs whichever screen is open; the phone's location is
  /// followed throughout, in the background too.
  func startWardrive(filter: NodeDiscoveryFilter) {
    guard !isWardriving, let binding, binding.canDiscover else { return }
    isWardriving = true
    wardriveFilter = filter
    wardriveProbeCount = 0
    nextWardriveProbeAt = nil
    let start = now()
    wardriveSession = WardriveSession(filter: filter, startedAt: start)
    // One list for the whole drive: every probe adds to it (`requestProbe`).
    currentScan = Scan(radioID: binding.radioID, filter: filter, startedAt: start, listensOnly: false)
    syncLocationDemand()
    wardriveTask = Task { [weak self] in
      await self?.runWardrive()
    }
  }

  func stopWardrive() {
    wardriveTask?.cancel()
    wardriveTask = nil
    if isWardriving {
      wardriveSession?.endedAt = now()
    }
    isWardriving = false
    nextWardriveProbeAt = nil
    syncLocationDemand()
  }

  /// Takes a finished Wardrive's figures off the screen. A running one is left alone.
  func dismissWardriveSession() {
    guard !isWardriving else { return }
    wardriveSession = nil
  }

  /// Adds a fix to the running Wardrive's distance.
  private func noteWardriveFix(_ fix: NeighbourFix?) {
    guard isWardriving, wardriveSession != nil else { return }
    wardriveSession?.note(fix: fix)
  }

  private func runWardrive() async {
    while isWardriving, !Task.isCancelled {
      // Waiting out a cooldown here keeps the state from flickering to probing and back
      if !isProbing, case let .coolingDown(until, _) = await gate.status() {
        guard isWardriving, !Task.isCancelled else { return }
        nextWardriveProbeAt = until
        await refreshCooldown()
        do {
          try await sleep(.seconds(max(0, until.timeIntervalSince(now()))))
        } catch {
          return
        }
        continue
      }
      guard isWardriving, !Task.isCancelled else { return }
      nextWardriveProbeAt = nil
      switch await requestProbe(filter: wardriveFilter, origin: .wardrive) {
      case .started:
        wardriveProbeCount += 1
        wardriveSession?.probeCount += 1
        await waitForProbe()
      case .attached:
        await waitForProbe()
      case let .coolingDown(until, _):
        guard isWardriving else { return }
        nextWardriveProbeAt = until
        do {
          try await sleep(.seconds(max(0, until.timeIntervalSince(now()))))
        } catch {
          return
        }
      case .notConnected, .unsupported:
        stopWardrive()
        return
      }
      if lastError != nil || !isDiscoverSupported {
        stopWardrive()
        return
      }
    }
  }

  // MARK: - Location

  /// Holds the probe's request until following has a fresh fix, for at most `fixWaitLimit`. A
  /// phone already following (Wardrive, a probe just before) has one and goes at once; with
  /// location refused there is nothing to wait for.
  private func waitForFreshFix() async {
    guard location.canFollow() else { return }
    let deadline = now().addingTimeInterval(Self.fixWaitLimit)
    while currentFix() == nil, now() < deadline {
      do {
        try await sleep(.seconds(Self.fixPollInterval))
      } catch {
        return
      }
    }
  }

  /// The phone's fix when fresh and precise enough to say where evidence was heard.
  private func currentFix() -> NeighbourFix? {
    NodeDiscoveryReception.fix(phone: location.latestFix(), now: now()).map {
      NeighbourFix(
        latitude: $0.latitude,
        longitude: $0.longitude,
        horizontalAccuracy: $0.horizontalAccuracy,
        timestamp: $0.timestamp
      )
    }
  }

  /// Tells the location service about a change of demand, and feeds the neighbour service the
  /// phone's fix for as long as location is followed.
  private func syncLocationDemand() {
    let demand = locationDemand
    if demand != sentDemand {
      sentDemand = demand
      location.setDemand(demand)
    }
    if demand != .none, location.canFollow() {
      startFixFeed()
    } else {
      stopFixFeed()
    }
  }

  private func startFixFeed() {
    guard fixFeedTask == nil else { return }
    let sleep = sleep
    let interval = Self.fixFeedInterval
    fixFeedTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let binding else { return }
        let fix = currentFix()
        noteWardriveFix(fix)
        await binding.updateLocationFix(fix)
        do {
          try await sleep(.seconds(interval))
        } catch {
          return
        }
      }
    }
  }

  private func stopFixFeed() {
    guard let fixFeedTask else { return }
    fixFeedTask.cancel()
    self.fixFeedTask = nil
    if let binding {
      Task { await binding.updateLocationFix(nil) }
    }
  }
}

// MARK: - Mark Race

/// A delivery reading racing its time limit: the first to finish resumes the probe, and the other
/// is cancelled.
@MainActor
private final class MarkRace {
  var continuation: CheckedContinuation<DiscoveryProbeCoordinator.DeliveryMark?, Never>?
  var reading: Task<Void, Never>?
  var timer: Task<Void, Never>?

  func finish(_ mark: DiscoveryProbeCoordinator.DeliveryMark?) {
    guard let continuation else { return }
    self.continuation = nil
    reading?.cancel()
    timer?.cancel()
    continuation.resume(returning: mark)
  }
}

// MARK: - Live Wiring

extension DiscoveryProbeCoordinator.Binding {
  /// The probe's view of a wired connection: its session sends and paces, its neighbour service
  /// records, its RX stream service measures delivery.
  @MainActor
  static func live(services: ServiceContainer, device: DeviceDTO) -> Self {
    let session = services.session
    let neighbours = services.neighbourService
    let rxStream = services.rxStreamService
    return Self(
      id: ObjectIdentifier(services),
      radioID: device.radioID,
      listenWindow: DiscoverListenWindow.seconds(for: device),
      sendDiscoverRequest: { filter, tag in
        _ = try await session.sendNodeDiscoverRequest(filter: filter, prefixOnly: false, tag: tag)
      },
      noteProbe: { tag, filter, date in
        await neighbours.noteProbe(tag: tag, filter: filter, at: date)
      },
      overheardRequests: { await neighbours.overheardRequests() },
      updateLocationFix: { fix in await neighbours.updateLocationFix(fix) },
      canDiscover: device.supportsNodeDiscover,
      holdBackgroundTraffic: { duration in
        await session.holdBackgroundTraffic(for: duration, owner: DiscoveryProbeCoordinator.trafficHoldOwner)
      },
      releaseBackgroundTraffic: {
        await session.releaseBackgroundTraffic(owner: DiscoveryProbeCoordinator.trafficHoldOwner)
      },
      deliveryMark: {
        // Each reading waits for a quiet link first (StockDeliveryMonitor.sample())
        guard let mark = await rxStream.deliveryMark() else { return nil }
        return DiscoveryProbeCoordinator.DeliveryMark { await rxStream.packetsMissed(since: mark) }
      }
    )
  }
}

extension DiscoveryProbeCoordinator.Location {
  /// Reads and claims the app's location service under ``DiscoveryProbeCoordinator/locationClient``.
  static func live(_ locationService: LocationService) -> Self {
    Self(
      latestFix: { [locationService] in locationService.latestFix },
      canFollow: { [locationService] in locationService.isAuthorized },
      setDemand: { [locationService] demand in
        let client = DiscoveryProbeCoordinator.locationClient
        switch demand {
        case .none: locationService.stopFollowing(for: client)
        case .scan: locationService.startFollowing(for: client)
        case .wardrive: locationService.startFollowing(for: client, inBackground: true)
        }
      }
    )
  }
}
