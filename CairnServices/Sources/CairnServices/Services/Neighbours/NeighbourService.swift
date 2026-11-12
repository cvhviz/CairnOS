import Foundation
import MeshCore

let neighbourLogger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "NeighbourService")

/// Keeps, for the channel the radio is on, the table of its direct neighbours and the ledger of
/// every node it observed (``ObservationLedger``), and publishes both in one ``NeighbourSnapshot``.
///
/// The table is built passively from the RX log (relays, 0-hop adverts, discover replies to
/// anyone) plus discover replies and 1-hop traces. The ledger holds only what this radio proved it
/// heard on the channel (``ObservationExtractor``): signed adverts, 0-hop discover replies,
/// decrypted direct messages from known peers, the radio's own decrypt pushes, and its
/// own traces' 8-byte hashes. Scan for Nodes, CarPlay, Home, the RX Log list and the Traffic map
/// resolve every hash against that ledger, so they can never disagree, and none uses a saved
/// contact this radio never heard on the channel.
///
/// Each channel (``ChannelKey``, as the radio reports it in `SELF_INFO`) has its own table and
/// ledger. Every frame is stamped with its channel by the session; a frame with no stamp or
/// another channel's is never evidence. A `SELF_INFO` with a new channel, or the channel dropping
/// while a retune waits for the radio, flushes the current pair and loads the new one.
///
/// `start(radioID:)` runs in this order, so nothing heard while it loads is missed:
/// 1. subscribe to the session with a deep buffer (labelled ``subscriptionLabel``);
/// 2. delete rows stored before channels were recorded, prune old rows;
/// 3. when the radio has reported its channel, load that channel's stored rows and ledger and
///    replay the last 24 hours of the RX log stamped with it; until then the snapshot is cold;
/// 4. drain the live stream.
///
/// All work happens in memory. Changed rows are written in one batch every ``defaultFlushInterval``
/// and on stop, never once per packet; updates go out at most once per ``defaultUpdateInterval``.
public actor NeighbourService {
  /// The label the session counts this subscription's drops under.
  public static let subscriptionLabel = "neighbours"
  /// Events the subscription holds while the table is busy: a long advert burst fits.
  public static let subscriptionBufferSize = 4096
  /// How far back the stored RX log is replayed when a channel's table and ledger are loaded.
  public static let replayWindow: TimeInterval = 24 * 60 * 60
  /// How long an overheard discover request stays relevant (the repeaters' limiter window).
  public static let overheardRequestWindow: TimeInterval = 120
  /// How often changed rows are written while the app is in front. The table is derived from
  /// traffic and rebuilds, so a minute lost to a crash costs little; it was 10 s, which on a busy
  /// mesh meant a database write nearly every time a packet woke the app.
  public static let defaultFlushInterval: Duration = .seconds(60)
  /// ... and while it is in the background (`AppActivity`), where each write is a wake kept longer.
  /// The app also flushes as it goes to the background.
  public static let backgroundFlushInterval: Duration = .seconds(300)
  public static let defaultUpdateInterval: Duration = .seconds(1)
  /// Oldest phone fix that still says where evidence was heard (NodeDiscoveryReception.maxFixAge).
  static let maximumFixAge: TimeInterval = 30
  /// Least precise phone fix worth keeping as a heard-from position.
  static let maximumFixAccuracy: Double = 100
  /// Stored entries this close before the subscription may also be waiting in its buffer.
  static let replayOverlapMargin: TimeInterval = 2
  /// RX_SYNC positions remembered to drop a re-delivered packet.
  static let rxSyncDedupCapacity = 4096

  /// The session events that carry neighbour evidence, observations, or the radio's channel.
  /// Never the radio's contact table, nor its advert pushes (0x80, 0x8A): a contact sync proves
  /// nothing was heard, and the radio pushes an imported advert as if it had heard it.
  static let eventFilter = EventFilter { event in
    switch event {
    case .rxLogData, .discoverResponse, .traceData, .selfInfo,
         .pathUpdate, .loginSuccess, .statusResponse, .telemetryResponse, .pathResponse:
      true
    default:
      false
    }
  }

  let session: any MeshCoreSessionProtocol
  let dataStore: any PersistenceStoreProtocol & NeighbourPersisting & ObservationPersisting
  /// The session's RX_SYNC delivery, asked to replay records this subscription dropped.
  private let rxSync: (any CairnRxSyncSessionOps)?
  /// Whether this radio sent the trace with a tag: only our own trace measures how a neighbour
  /// hears us, and only its 8-byte hashes are observations.
  let isOwnTrace: @Sendable (UInt32) async -> Bool
  /// Every decoded RX log entry (`RxLogService.entryStream()`): decrypted direct messages are
  /// observations, and proven echoes of our own packets say which relay heard us.
  private let entries: (@Sendable () -> AsyncStream<RxLogEntryDTO>)?
  /// What this radio sent, for proving echoes of our own packets.
  let ownTransmissions: OwnTransmissionService?
  let now: @Sendable () -> Date
  private let flushInterval: Duration
  private let updateInterval: Duration

  /// The radio the table belongs to, nil while stopped.
  public private(set) var radioID: UUID?
  var table = NeighbourTable()
  /// The channel the table and ledger belong to; nil while cold.
  var channel: RadioChannelConfig?
  /// What this radio observed on ``channel``; nil while cold or loading.
  var ledger: ObservationLedger?
  /// Added to the ledger's own version when published, so published versions only grow across
  /// channel switches and reloads.
  var ledgerVersionBase = 0
  var lastPublishedLedgerVersion = 0
  /// Bumped by every load of a channel, so a load overtaken by a newer one is dropped.
  var activation = 0
  var selfKey: Data?
  var lastProbe: NeighbourProbe?
  var isWarm = false
  private var locationFix: NeighbourFix?
  /// Discover requests overheard in the last ``overheardRequestWindow``, oldest first.
  private var overheard: [(at: Date, packetHash: String)] = []
  /// Replayed entries that may also be waiting in the subscription buffer, by reception.
  var replayOverlap: [Reception: Int] = [:]
  var rxSyncSeen = RxRecordDedup(capacity: NeighbourService.rxSyncDedupCapacity)
  /// Holes in the live records this subscription made, and the replays asked for them.
  private var replayTracker = RxReplayTracker()
  /// Drops counted under ``subscriptionLabel`` when holes were last checked.
  private var knownEventDrops = 0
  /// Batches whose save failed, by channel, written with the next one.
  var unsavedTable: [ChannelKey: NeighbourTable.Changes] = [:]
  var unsavedLedger: [ChannelKey: LedgerChanges] = [:]
  /// What this radio sent lately, as ``OwnTransmissionService`` last published it.
  var ownSends: [OwnTransmission] = []

  /// Bumped by start and stop, so work begun for an earlier run never touches a later one.
  var generation = 0
  private var monitorTask: Task<Void, Never>?
  private var flushTask: Task<Void, Never>?
  private var updateTask: Task<Void, Never>?
  private var entriesTask: Task<Void, Never>?
  private var ownSendsTask: Task<Void, Never>?
  var bootstrapWaiters: [CheckedContinuation<Void, Never>] = []

  private var updateSubscribers: [UUID: AsyncStream<NeighbourSnapshot>.Continuation] = [:]
  private var overheardSubscribers: [UUID: AsyncStream<Date>.Continuation] = [:]
  private var snapshotIsDirty = false
  private var lastUpdateAt: ContinuousClock.Instant?

  /// One received frame, to tell a replayed entry from the same packet still in the buffer.
  struct Reception: Hashable {
    let packetHash: String
    let pathLength: UInt8
    let pathNodes: Data

    init(_ fields: RxPacketFields) {
      packetHash = fields.packetHash
      pathLength = fields.pathLength
      pathNodes = fields.pathNodes
    }
  }

  /// - Parameters:
  ///   - rxSync: The session's RX_SYNC delivery, for replays of records this service dropped.
  ///   - isOwnTrace: Whether this radio sent the trace with a tag (`MeshCoreSession.sentTrace(tag:)`).
  ///   - entries: Every decoded RX log entry (`RxLogService.entryStream`).
  ///   - ownTransmissions: What this radio sent, for proving echoes of our own packets.
  ///   - now: The clock evidence is stamped and aged with; tests inject a fake one.
  ///   - flushInterval: How often changed rows are written.
  ///   - updateInterval: The least time between two ``updates()`` values.
  public init(
    session: any MeshCoreSessionProtocol,
    dataStore: any PersistenceStoreProtocol & NeighbourPersisting & ObservationPersisting,
    rxSync: (any CairnRxSyncSessionOps)? = nil,
    isOwnTrace: @escaping @Sendable (UInt32) async -> Bool = { _ in false },
    entries: (@Sendable () -> AsyncStream<RxLogEntryDTO>)? = nil,
    ownTransmissions: OwnTransmissionService? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    flushInterval: Duration = NeighbourService.defaultFlushInterval,
    updateInterval: Duration = NeighbourService.defaultUpdateInterval
  ) {
    self.session = session
    self.dataStore = dataStore
    self.rxSync = rxSync
    self.isOwnTrace = isOwnTrace
    self.entries = entries
    self.ownTransmissions = ownTransmissions
    self.now = now
    self.flushInterval = flushInterval
    self.updateInterval = updateInterval
  }

  deinit {
    monitorTask?.cancel()
    flushTask?.cancel()
    updateTask?.cancel()
    entriesTask?.cancel()
    ownSendsTask?.cancel()
  }

  // MARK: - Lifecycle

  /// Starts collecting for `radioID`. Returns once the subscriptions exist, so a service started
  /// after this one can't receive a packet this one misses; loading and replay continue behind.
  /// Starting while running for a radio stops (and flushes) that run first.
  public func start(radioID: UUID) async {
    if self.radioID != nil {
      await stop()
    }
    generation += 1
    let generation = generation
    self.radioID = radioID
    resetState()

    let subscribedAt = now()
    let events = await session.events(
      filter: Self.eventFilter,
      buffering: .bufferingNewest(Self.subscriptionBufferSize),
      label: Self.subscriptionLabel
    )
    guard generation == self.generation else { return }
    knownEventDrops = await session.eventDropCount(label: Self.subscriptionLabel)
    guard generation == self.generation else { return }

    if let entryStream = entries?() {
      entriesTask = Task { [weak self] in
        for await entry in entryStream {
          guard !Task.isCancelled else { break }
          await self?.handleEntry(entry, generation: generation)
        }
      }
    }
    if let sends = ownTransmissions?.transmissions() {
      ownSendsTask = Task { [weak self] in
        for await snapshot in sends {
          guard !Task.isCancelled else { break }
          await self?.noteOwnSends(snapshot, generation: generation)
        }
      }
    }
    monitorTask = Task { [weak self] in
      guard let self else { return }
      await bootstrap(radioID: radioID, subscribedAt: subscribedAt, generation: generation)
      for await event in events {
        guard !Task.isCancelled else { break }
        await handle(event)
      }
    }
    let interval = flushInterval
    let backgroundInterval = max(flushInterval, Self.backgroundFlushInterval)
    flushTask = Task { [weak self] in
      let clock = ContinuousClock()
      var lastFlush = clock.now
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        // in the background only every `backgroundInterval`; back in front, the next tick writes
        if AppActivity.isBackground, clock.now - lastFlush < backgroundInterval { continue }
        await self?.flush()
        lastFlush = clock.now
      }
    }
  }

  /// Stops collecting and writes every changed row. Subscribers of ``updates()`` and
  /// ``overheardRequests()`` stay subscribed for the next start; ``finishStreams()`` ends them.
  public func stop() async {
    generation += 1
    for task in [monitorTask, flushTask, updateTask, entriesTask, ownSendsTask] {
      task?.cancel()
    }
    monitorTask = nil
    flushTask = nil
    updateTask = nil
    entriesTask = nil
    ownSendsTask = nil
    resumeBootstrapWaiters()
    await flush()
    radioID = nil
    resetState()
  }

  /// Ends every ``updates()`` and ``overheardRequests()`` stream, at teardown.
  public func finishStreams() {
    for continuation in updateSubscribers.values {
      continuation.finish()
    }
    for continuation in overheardSubscribers.values {
      continuation.finish()
    }
    updateSubscribers.removeAll()
    overheardSubscribers.removeAll()
  }

  // MARK: - Reading

  /// The neighbours of `radioID` now, or nil when the service isn't running for that radio.
  public func snapshot(radioID: UUID) -> NeighbourSnapshot? {
    guard radioID == self.radioID else { return nil }
    return makeSnapshot()
  }

  /// A snapshot now (when running), then one after each change, at most once per update interval.
  /// A consumer that lags gets the newest.
  public func updates() -> AsyncStream<NeighbourSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: NeighbourSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    if radioID != nil {
      continuation.yield(makeSnapshot())
    }
    let id = UUID()
    updateSubscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeUpdateSubscriber(id) }
    }
    return stream
  }

  /// When each discover request someone else sent was heard: first those of the last
  /// ``overheardRequestWindow`` (from the live stream or the replayed log), then each new one.
  /// Every request spends a token of the repeaters' shared limiter, so the request gate counts them.
  public func overheardRequests() -> AsyncStream<Date> {
    let (stream, continuation) = AsyncStream.makeStream(of: Date.self, bufferingPolicy: .bufferingNewest(32))
    pruneOverheard()
    for request in overheard {
      continuation.yield(request.at)
    }
    let id = UUID()
    overheardSubscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeOverheardSubscriber(id) }
    }
    return stream
  }

  /// Events this service's subscription dropped because it lagged.
  public func deliveryDrops() async -> Int {
    await session.eventDropCount(label: Self.subscriptionLabel)
  }

  // MARK: - Input

  /// Records our own discover request, so replies carrying `tag` count as answers to our scan and
  /// say how each neighbour hears us.
  public func noteProbe(tag: UInt32, filter: UInt8, at date: Date) {
    table.noteProbe(tag: tag, at: date)
    lastProbe = NeighbourProbe(tag: tag, filter: filter, sentAt: date)
    scheduleUpdate()
  }

  /// The phone's latest fix. Evidence arriving while it is fresh and precise records where it was
  /// heard from; each row keeps the best-SNR position.
  public func updateLocationFix(_ fix: NeighbourFix?) {
    locationFix = fix
  }

  // MARK: - Bootstrap

  /// Steps 2 and 3 of start: stored rows cleaned, then the current channel's table and ledger.
  private func bootstrap(radioID: UUID, subscribedAt: Date, generation: Int) async {
    let startedAt = now()
    do {
      try await dataStore.pruneNeighbourRecords(
        radioID: radioID,
        channelKey: nil,
        notHeardSince: startedAt.addingTimeInterval(-NeighbourTable.maximumAge)
      )
      // Rows stored before channels were recorded can't say which channel they were heard on
      try await dataStore.deleteUnstampedNeighbourRecords(radioID: radioID)
      try await dataStore.pruneObservedNodes(
        radioID: radioID,
        notObservedSince: startedAt.addingTimeInterval(-ObservationLedger.retention)
      )
    } catch {
      neighbourLogger.warning("Failed to prune stored neighbours: \(error.localizedDescription)")
    }
    let selfInfo = await session.currentSelfInfo
    var device: DeviceDTO?
    if selfInfo == nil {
      device = try? await dataStore.fetchDevice(radioID: radioID)
    }
    let config = await session.currentChannelConfig
    guard generation == self.generation else { return }
    selfKey = selfInfo?.publicKey ?? device?.publicKey

    // No channel yet: the snapshot stays cold until the radio reports one
    if let config {
      await activate(config, overlapFrom: subscribedAt, generation: generation)
      guard generation == self.generation else { return }
    }
    isWarm = true
    resumeBootstrapWaiters()
    neighbourLogger.info("Neighbours warm on \(config?.key.rawValue ?? "no channel"): \(table.count) rows, \(ledger?.count ?? 0) observed")
    scheduleUpdate()
  }

  /// Replays stored entries of the channel being loaded through the table and the ledger.
  /// - Parameters:
  ///   - entries: The stored entries of the channel, oldest first.
  ///   - watermark: The newest reception the stored rows already hold: older entries only feed
  ///     the ledger (which counts each observation once) and the limiter window.
  ///   - overlapStart: Entries received at or after this may also be waiting in the subscription.
  func replay(_ entries: [NeighbourReplayEntry], watermark: Date?, overlapStart: Date) {
    for entry in entries {
      let fields = entry.fields
      // a resume can send stored records again: each RX_SYNC position counts once. Epoch 0 names
      // no journal and its seqs restart every radio boot, so it is no position (RxLogService too).
      if let epoch = entry.radioEpoch, epoch != 0, let seq = entry.radioSeq {
        _ = admitRxSync(epoch: epoch, seq: seq)
      }
      if entry.receivedAt >= overlapStart {
        replayOverlap[Reception(fields), default: 0] += 1
      }
      let isNew = watermark.map { entry.receivedAt > $0 } ?? true
      ingestPacket(fields, at: entry.receivedAt, fix: nil, recordEvidence: isNew)
    }
  }

  /// The stored RX log of `channelKey` since `since`, oldest first: the window
  /// `RxLogService.recentEntries(since:)` reads, but straight from the store and only the fields
  /// evidence needs. This service starts before RxLogService has a radio, and the replay must not
  /// wait on its saves.
  func loadReplayEntries(radioID: UUID, channelKey: ChannelKey, since: Date) async -> [NeighbourReplayEntry] {
    let cap = RxLogRetention.keepCount + RxLogRetention.pruneThreshold + RxLogRetention.batchSize
    do {
      return try await dataStore.fetchNeighbourReplay(radioID: radioID, channelKey: channelKey, since: since, limit: cap)
    } catch {
      neighbourLogger.error("Failed to load the RX log for neighbour replay: \(error.localizedDescription)")
      return []
    }
  }

  /// Waits until the stored state has been read in, or the run stopped. For tests.
  func waitUntilWarm() async {
    guard !isWarm, monitorTask != nil else { return }
    await withCheckedContinuation { bootstrapWaiters.append($0) }
  }

  func resumeBootstrapWaiters() {
    let waiters = bootstrapWaiters
    bootstrapWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  // MARK: - Live Events

  private func handle(_ event: MeshEvent) async {
    switch event {
    case let .selfInfo(info):
      if !info.publicKey.isEmpty { selfKey = info.publicKey }
      let config = RadioChannelConfig(selfInfo: info)
      if config?.key != channel?.key {
        await switchChannel(to: config)
      } else if let config {
        // The same channel at another coding rate
        channel = config
      }
    case let .rxLogData(parsed):
      if let epoch = parsed.epoch, epoch != 0, let seq = parsed.seq {
        guard admitRxSync(epoch: epoch, seq: seq) else { return }
        if let skipped = replayTracker.take(epoch: epoch, seq: seq, isBackfill: parsed.isBackfill) {
          await replayIfDropped(skipped, epoch: epoch)
        }
      }
      let fields = RxPacketFields(parsed)
      guard !consumeReplayOverlap(fields) else { return }
      guard let stamp = parsed.channel else {
        // A live frame the session couldn't stamp: the radio is being retuned
        if channel != nil, parsed.radioAge == nil, !parsed.isBackfill {
          await goColdIfRetuning()
        }
        return
      }
      let age = parsed.radioAge.map(Self.seconds) ?? 0
      let receivedAt = now().addingTimeInterval(-age)
      // A record the radio held a while (a resume's backlog, a fetch) was heard somewhere else
      let isLate = parsed.isBackfill || age > Self.maximumFixAge
      if stamp.key != channel?.key, !isLate {
        // A live frame stamped with a channel the table isn't on, or while it is cold: the session
        // vouches for that channel now (a refused retune restored it, or the SELF_INFO saying so
        // was dropped from the buffer), so follow it as a push would
        _ = await pushChannel()
        // The load just replayed the stored RX log, which may hold this frame already
        guard !consumeReplayOverlap(fields) else { return }
      }
      // Heard on another channel than the table's (an RX_SYNC backlog): never evidence here
      guard stamp.key == channel?.key, ledger != nil else { return }
      ingestPacket(fields, at: receivedAt, fix: isLate ? nil : currentFix(at: receivedAt))
    case let .discoverResponse(response):
      guard let config = await pushChannel() else { return }
      let date = now()
      ingest(NeighbourEvidence.extract(response, selfHash: selfKey), at: date, fix: currentFix(at: date))
      ingestObservations(ObservationExtractor.observations(from: event, channel: config, at: date, selfKey: selfKey))
    case let .traceData(trace):
      let generation = generation
      let isOwn = await isOwnTrace(trace.tag)
      guard generation == self.generation, let config = await pushChannel() else { return }
      let date = now()
      ingest(NeighbourEvidence.extract(trace, isOwn: isOwn), at: date, fix: currentFix(at: date))
      ingestObservations(ObservationExtractor.observations(
        from: event,
        channel: config,
        at: date,
        selfKey: selfKey,
        isOwnTrace: { _ in isOwn }
      ))
    case .pathUpdate, .loginSuccess, .statusResponse, .telemetryResponse, .pathResponse:
      guard let config = await pushChannel() else { return }
      ingestObservations(ObservationExtractor.observations(from: event, channel: config, at: now(), selfKey: selfKey))
    default:
      break
    }
  }

  /// Asks the radio for `skipped` again when this subscription dropped events since the last
  /// check: the session sends each live record once, so the hole is this service's own. A jump
  /// with no drops is a gap the session is already fetching.
  private func replayIfDropped(_ skipped: ClosedRange<UInt32>, epoch: UInt32) async {
    guard let rxSync else { return }
    let generation = generation
    let drops = await session.eventDropCount(label: Self.subscriptionLabel)
    guard generation == self.generation, drops > knownEventDrops else { return }
    knownEventDrops = drops
    if await rxSync.requestRxReplay(from: skipped.lowerBound, count: skipped.count) {
      replayTracker.noteRequested(skipped, epoch: epoch, at: now())
    }
  }

  /// The evidence, observations and any discover request in one packet received on the table's
  /// channel.
  /// - Parameter recordEvidence: False for a replayed entry the stored rows already hold; its
  ///   observations (counted once by the ledger) and its discover request still count.
  func ingestPacket(_ fields: RxPacketFields, at date: Date, fix: NeighbourFix?, recordEvidence: Bool = true) {
    if let request = NeighbourEvidence.overheardDiscoverRequest(in: fields) {
      noteOverheard(packetHash: request.packetHash, at: date)
    }
    if let key = channel?.key {
      ingestObservations(ObservationExtractor.observations(
        from: fields,
        channelKey: key,
        receivedAt: date,
        selfKey: selfKey,
        entryID: nil
      ))
    }
    guard recordEvidence else { return }
    let evidence = NeighbourEvidence.extract(fields, selfHash: selfKey, ownPacketHashes: ownPacketHashes(for: fields, at: date))
      // An advert names its sender only when its signature holds
      .filter { $0.source != .advert || Self.isVerifiedAdvert(fields) }
    ingest(evidence, at: date, fix: fix)
  }

  private func ingest(_ evidence: [NeighbourEvidence], at date: Date, fix: NeighbourFix?) {
    var changed = false
    for item in evidence {
      if case .recorded = table.ingest(item, at: date, fix: fix) {
        changed = true
      }
    }
    if changed {
      scheduleUpdate()
    }
  }

  /// Folds observations into the ledger; ignored while it is loading or cold.
  func ingestObservations(_ observations: [NodeObservation]) {
    guard !observations.isEmpty, ledger?.ingest(observations) == true else { return }
    scheduleUpdate()
  }

  private static func isVerifiedAdvert(_ fields: RxPacketFields) -> Bool {
    if case .verified = ObservationExtractor.advertCheck(in: fields) { true } else { false }
  }

  /// Whether this RX_SYNC position is new. The session already delivers each one once; a replay
  /// a subscriber asked for repeats them, and so does a resume of records already stored.
  private func admitRxSync(epoch: UInt32, seq: UInt32) -> Bool {
    rxSyncSeen.insert(epoch: epoch, seq: seq)
  }

  /// Whether this live packet is one the replay already read from the store.
  private func consumeReplayOverlap(_ fields: RxPacketFields) -> Bool {
    guard !replayOverlap.isEmpty else { return false }
    let reception = Reception(fields)
    guard let count = replayOverlap[reception] else { return false }
    replayOverlap[reception] = count > 1 ? count - 1 : nil
    return true
  }

  /// The phone's fix when it was taken within ``maximumFixAge`` of `date`, either side: evidence
  /// received long before the fix (a record the radio held) wasn't heard where the phone is now.
  private func currentFix(at date: Date) -> NeighbourFix? {
    guard let fix = locationFix,
          fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maximumFixAccuracy,
          abs(date.timeIntervalSince(fix.timestamp)) <= Self.maximumFixAge else { return nil }
    return fix
  }

  // MARK: - Overheard Requests

  private func noteOverheard(packetHash: String, at date: Date) {
    pruneOverheard()
    guard now().timeIntervalSince(date) < Self.overheardRequestWindow,
          !overheard.contains(where: { $0.packetHash == packetHash }) else { return }
    overheard.append((date, packetHash))
    overheard.sort { $0.at < $1.at }
    for continuation in overheardSubscribers.values {
      continuation.yield(date)
    }
  }

  private func pruneOverheard() {
    let cutoff = now().addingTimeInterval(-Self.overheardRequestWindow)
    overheard.removeAll { $0.at < cutoff }
  }

  private func removeOverheardSubscriber(_ id: UUID) {
    overheardSubscribers[id] = nil
  }

  // MARK: - Updates

  private func makeSnapshot() -> NeighbourSnapshot {
    let date = now()
    let probe = lastProbe.flatMap { probe in
      date.timeIntervalSince(probe.sentAt) <= NeighbourTable.probeTagLifetime ? probe : nil
    }
    let observed = currentLedgerSnapshot(at: date)
    // Nicknames are the app's to apply: the snapshot names nodes as they advertised themselves
    let index = PacketNodeIndex(ledger: observed, selfKey: selfKey)
    return NeighbourSnapshot(
      radioID: radioID ?? UUID(),
      takenAt: date,
      neighbours: NeighbourResolver.resolveAll(table, index: index, now: date),
      lastProbe: probe,
      isWarm: isWarm,
      ledger: observed
    )
  }

  /// Sends a snapshot now if none went out in the last update interval, else once it has passed.
  func scheduleUpdate() {
    snapshotIsDirty = true
    guard updateTask == nil, radioID != nil else { return }
    var wait = Duration.zero
    if let lastUpdateAt {
      let elapsed = ContinuousClock.now - lastUpdateAt
      if elapsed < updateInterval { wait = updateInterval - elapsed }
    }
    let generation = generation
    updateTask = Task { [weak self] in
      if wait > .zero {
        try? await Task.sleep(for: wait)
      }
      guard !Task.isCancelled else { return }
      await self?.emitUpdate(generation: generation)
    }
  }

  private func emitUpdate(generation: Int) {
    guard generation == self.generation else { return }
    updateTask = nil
    guard snapshotIsDirty, radioID != nil else { return }
    snapshotIsDirty = false
    lastUpdateAt = ContinuousClock.now
    guard !updateSubscribers.isEmpty else { return }
    let snapshot = makeSnapshot()
    for continuation in updateSubscribers.values {
      continuation.yield(snapshot)
    }
  }

  private func removeUpdateSubscriber(_ id: UUID) {
    updateSubscribers[id] = nil
  }

  // MARK: - Storage

  /// Prunes the table and the ledger and writes every row changed since the last write, one save
  /// for each. A batch that fails is kept and written with the next one. Runs every
  /// ``defaultFlushInterval``, on stop and before a channel switch; the app also calls it as it
  /// goes to the background.
  public func flush() async {
    guard let radioID else { return }
    if let key = channel?.key {
      let date = now()
      table.prune(now: date)
      let changes = table.takeChanges()
      if !changes.isEmpty {
        unsavedTable[key] = unsavedTable[key].map { Self.combine(older: $0, newer: changes) } ?? changes
        if !changes.removed.isEmpty { scheduleUpdate() }
      }
      noteLedgerChanges(key: key, now: date)
    }
    for (key, changes) in unsavedTable {
      unsavedTable[key] = nil
      do {
        try await dataStore.saveNeighbourRecords(
          radioID: radioID,
          channelKey: key,
          upserting: changes.upserted,
          removing: changes.removed
        )
      } catch {
        neighbourLogger.error("Failed to save \(changes.upserted.count) neighbour rows: \(error.localizedDescription)")
        guard radioID == self.radioID else { continue }
        unsavedTable[key] = Self.combine(older: changes, newer: unsavedTable[key])
      }
    }
    await saveLedgerChanges(radioID: radioID)
  }

  /// Two batches as one; where both touch a row, `newer` wins.
  static func combine(older: NeighbourTable.Changes, newer: NeighbourTable.Changes?) -> NeighbourTable.Changes {
    guard let newer else { return older }
    let newerUpserted = Set(newer.upserted.map(\.identity))
    let newerRemoved = Set(newer.removed)
    let upserted = older.upserted.filter { !newerUpserted.contains($0.identity) && !newerRemoved.contains($0.identity) }
      + newer.upserted
    let removed = Set(older.removed).subtracting(newerUpserted).union(newerRemoved)
    return NeighbourTable.Changes(upserted: upserted, removed: Array(removed))
  }

  func resetState() {
    table = NeighbourTable()
    channel = nil
    ledger = nil
    activation += 1
    selfKey = nil
    lastProbe = nil
    isWarm = false
    overheard = []
    replayOverlap = [:]
    rxSyncSeen = RxRecordDedup(capacity: Self.rxSyncDedupCapacity)
    replayTracker = RxReplayTracker()
    knownEventDrops = 0
    unsavedTable = [:]
    unsavedLedger = [:]
    ownSends = []
    snapshotIsDirty = false
    lastUpdateAt = nil
  }

  static func seconds(_ duration: Duration) -> TimeInterval {
    let (seconds, attoseconds) = duration.components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
