import CryptoKit
import Foundation
import MeshCore
import OSLog

private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "RxLogService")

/// Actor that processes RX log events, decodes channel messages, and persists to database.
///
/// Each entry reaches `entryStream()` as soon as it is decoded. Saves are batched off the event
/// loop: a flush writes up to `RxLogRetention.batchSize` entries in one commit, or a partial batch
/// `RxLogRetention.flushInterval` after its first entry, then hands them to heard repeats in order.
/// An entry a message lookup needs at once (see `needsImmediateSave`) is saved before
/// `process(_:)` returns.
public actor RxLogService {
  /// Label of the RX log's event subscription, under which its dropped events are counted.
  public static let eventLabel = "rxlog"

  /// The RX log's event buffer: room for a burst while the store is busy.
  static let eventBufferSize = 4096

  /// Stored RX_SYNC records remembered on start, so a resume that sends some again stores each once:
  /// twice the most a resume sends (``RxStreamService/resumeMax``).
  static let seededRecordCount = 2 * Int(RxStreamService.resumeMax)

  private let session: any MeshCoreSessionProtocol
  let dataStore: any PersistenceStoreProtocol
  var radioID: UUID?

  /// Writes the batched entries and the RX_SYNC resume cursor: the data store, unless a test
  /// injects another writer.
  private let entryWriter: any RxLogBatchPersisting

  /// The session's RX_SYNC delivery: the contiguous mark the resume cursor is held to, and the
  /// replays asked for when this log's own subscription dropped records. `nil` without RX_SYNC.
  private let rxSync: (any CairnRxSyncSessionOps)?

  // Save batching
  /// Entries yielded but not yet handed to a flush, oldest first.
  private var pendingEntries: [RxLogEntryDTO] = []
  /// Entries handed to a flush whose save hasn't finished, by id. Read-backs merge them in.
  private var writingEntries: [UUID: RxLogEntryDTO] = [:]
  /// The newest flush. Each flush waits for the one before it, so batches are saved, and reach
  /// heard repeats, in the order they were received.
  private var flushTask: Task<Void, Never>?
  /// Flushes a partial batch `RxLogRetention.flushInterval` after its first entry.
  private var flushTimerTask: Task<Void, Never>?
  private var flushTimerGeneration = 0

  // RX_SYNC delivery
  /// Records already taken, so a record delivered again (a replay another consumer asked for)
  /// is stored once.
  private var seenRecords = RxRecordDedup(capacity: RxSequencer.dedupCapacity)
  /// Each radio's resume cursor as last stored. It moves only after the entries behind it saved.
  private var streamCursors: [UUID: RxStreamCursor] = [:]
  /// Each radio's newest record saved. The stored cursor follows it once nothing before it is
  /// still on its way.
  private var savedHighs: [UUID: RxStreamCursor] = [:]
  /// Holes in the live records this log's subscription made, and the replays asked for them.
  private var replayTracker = RxReplayTracker()
  /// Drops counted under ``eventLabel`` when holes were last checked.
  private var knownEventDrops = 0

  // Caches for fast lookup
  private var channelSecrets: [UInt8: Data] = [:] // channelIndex -> secret
  private var channelNames: [UInt8: String] = [:] // channelIndex -> name

  // Crypto keys for direct message decryption
  private var myPrivateKey: Data?
  private var contactPublicKeysByPrefix: [UInt8: [Data]] = [:] // 1-byte prefix -> array of 32-byte public keys
  /// Each converted key's Ed25519 original, so a decrypted DM can name the contact it was with.
  private var contactSigningKeys: [Data: Data] = [:]

  /// Multicast broadcaster for newly received entries, yielded before their batched save.
  /// Consumers subscribe via `entryStream()`; finished by `ServiceContainer.tearDown()`.
  private nonisolated let entryBroadcaster = EventBroadcaster<RxLogEntryDTO>()

  /// Multicast broadcaster for Message IDs whose region fields reprocess
  /// rewrote. Open chats subscribe via `regionUpdateEvents()` to re-bake
  /// region footers.
  nonisolated let regionUpdateBroadcaster = EventBroadcaster<[UUID]>()

  /// Event monitoring
  private var eventMonitorTask: Task<Void, Never>?
  /// Bumped by every start and stop, so a start resuming after its subscription await can tell a
  /// newer start or a stop ran meanwhile and drop its now-stale subscription.
  private var eventMonitorGeneration = 0

  /// Connect-path region reprocess. Cancelled with event monitoring so it
  /// cannot write or yield after teardown finishes the broadcaster.
  private var regionReprocessTask: Task<Void, Never>?

  /// Heard repeats processing.
  /// Injected by `ServiceContainer` at construction.
  private let heardRepeatsService: HeardRepeatsService?

  // Reentrancy guards for reprocessing (separate to avoid mutual blocking)
  private var isReprocessingChannels = false
  private var isReprocessingDMs = false
  var isReprocessingRegions = false

  /// Waiters parked while a region reprocess drain owns the actor.
  /// The owner resumes them in its defer.
  var regionReprocessWaiters: [CheckedContinuation<Void, Never>] = []

  // Region resolution state
  var knownRegions: [String] = []
  var scopeKeyCache: [(name: String, key: Data)] = []
  /// Bumped by region updates so a slower database load does not overwrite them.
  var regionCacheGeneration = 0
  var lastRegionMissLogTime: Date?
  var lastRegionAmbiguousLogTime: Date?

  /// Set when a region back-fill request arrives while one is already in
  /// flight. The in-flight pass re-runs after it completes so rapid
  /// `addKnownRegion` / `removeKnownRegion` sequences do not lose work.
  /// Overlapping callers converge on the final cache; the number of passes
  /// is bounded by the number of overlapping callers that arrive across
  /// pass boundaries.
  var regionReprocessDirty = false

  public init(
    session: any MeshCoreSessionProtocol,
    dataStore: any PersistenceStoreProtocol,
    heardRepeatsService: HeardRepeatsService?,
    entryWriter: (any RxLogBatchPersisting)? = nil,
    rxSync: (any CairnRxSyncSessionOps)? = nil
  ) {
    self.session = session
    self.dataStore = dataStore
    self.heardRepeatsService = heardRepeatsService
    self.entryWriter = entryWriter ?? dataStore
    self.rxSync = rxSync
  }

  /// Whether a heard repeats service was injected at construction.
  var hasHeardRepeatsServiceWired: Bool {
    heardRepeatsService != nil
  }

  /// Whether a device private key is currently held for DM decryption.
  var hasPrivateKey: Bool {
    myPrivateKey != nil
  }

  deinit {
    eventMonitorTask?.cancel()
    regionReprocessTask?.cancel()
    flushTimerTask?.cancel()
  }

  // MARK: - Event Monitoring

  /// Start monitoring for RX log events from MeshCore. Returns once the subscription exists and
  /// the stored secrets are loaded, so a caller that starts RX_SYNC afterwards knows every resumed
  /// record reaches this log and is decoded with the radio's channels and contacts.
  public func startEventMonitoring(radioID: UUID) async {
    self.radioID = radioID
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
    regionReprocessTask?.cancel()
    regionReprocessTask = nil
    eventMonitorGeneration &+= 1
    let monitorGeneration = eventMonitorGeneration
    let generation = regionCacheGeneration

    // Subscribe before the database load and the reprocess. EventDispatcher only buffers for
    // existing subscribers, so packets heard (or resumed by RX_SYNC) while the secrets load
    // would otherwise be dropped. The deep buffer holds them until the loop drains, and rides
    // out a burst while a save or an advert's hop-count write is awaited.
    let events = await session.events(
      filter: .rxLogData,
      buffering: .bufferingNewest(Self.eventBufferSize),
      label: Self.eventLabel
    )
    // A stop or a newer start ran during the await; dropping the stream ends the subscription.
    guard monitorGeneration == eventMonitorGeneration else { return }
    knownEventDrops = await session.eventDropCount(label: Self.eventLabel)

    // Build known-regions cache (and channel/contact secrets) before decoding the backlog.
    await loadSecretsFromDatabase(radioID: radioID, generation: generation)
    guard monitorGeneration == eventMonitorGeneration else { return }
    await seedSeenRecords(radioID: radioID)
    guard monitorGeneration == eventMonitorGeneration else { return }

    eventMonitorTask = Task { [weak self] in
      guard let self else { return }

      // Sibling reprocess so the for-await loop drains while store work runs.
      await self.launchRegionReprocessTask()

      for await event in events {
        guard !Task.isCancelled else { break }
        if case let .rxLogData(parsed) = event {
          await process(parsed)
        }
      }
    }
  }

  /// Remembers the RX_SYNC records already stored. The resume cursor stops below a record still
  /// being fetched, so a resume can send records after it that were saved already.
  private func seedSeenRecords(radioID: UUID) async {
    let stored: [RxLogEntryDTO]
    do {
      stored = try await dataStore.fetchRxLogEntries(radioID: radioID, limit: Self.seededRecordCount)
    } catch {
      logger.error("Failed to load stored RX_SYNC records: \(error.localizedDescription)")
      return
    }
    // oldest first, so the newest stay remembered if the ring fills. Epoch 0 names no journal (a
    // record from before the radio's SUBSCRIBE reply, or one whose reply was lost): its seqs start
    // again at 1 every radio boot, so a stored one would hide the next boot's record with that seq.
    for entry in stored.reversed() {
      if let epoch = entry.radioEpoch, epoch != 0, let seq = entry.radioSeq {
        _ = seenRecords.insert(epoch: epoch, seq: seq)
      }
    }
  }

  /// Store a cancellable handle for connect-path region reprocess.
  private func launchRegionReprocessTask() {
    regionReprocessTask?.cancel()
    regionReprocessTask = Task { await self.reprocessRegionEntries() }
  }

  /// Load channel secrets and contact public keys from database to enable decryption before sync completes.
  private func loadSecretsFromDatabase(radioID: UUID, generation: Int) async {
    do {
      let channels = try await dataStore.fetchChannels(radioID: radioID)
      // Channels arrive sorted by slot index; a corrupt store can hold duplicate
      // indices, so keep the first match for a deterministic choice.
      channelSecrets = Dictionary(channels.map { ($0.index, $0.secret) }, uniquingKeysWith: { first, _ in first })
      channelNames = Dictionary(channels.map { ($0.index, $0.name) }, uniquingKeysWith: { first, _ in first })
      if !channels.isEmpty {
        logger.info("Loaded \(channels.count) channel secrets from database")
      }
    } catch {
      logger.error("Failed to load channel secrets: \(error.localizedDescription)")
    }

    do {
      let publicKeys = try await dataStore.fetchContactPublicKeysByPrefix(radioID: radioID)
      if !publicKeys.isEmpty {
        setContactPublicKeys(publicKeys)
        logger.info("Loaded \(publicKeys.count) contact public key prefixes from database")
      }
    } catch {
      logger.error("Failed to load contact public keys: \(error.localizedDescription)")
    }

    let device = try? await dataStore.fetchDevice(radioID: radioID)
    guard generation == regionCacheGeneration else { return }
    knownRegions = device?.knownRegions ?? []
    scopeKeyCache = Self.buildScopeKeyCache(from: knownRegions)
    if !knownRegions.isEmpty {
      logger.info("Loaded \(knownRegions.count) known regions from database (\(scopeKeyCache.count) resolvable)")
    }
  }

  /// Stop monitoring events, then save every entry still batched.
  public func stopEventMonitoring() async {
    eventMonitorGeneration &+= 1
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
    regionReprocessTask?.cancel()
    regionReprocessTask = nil
    // The radio's identity key is only needed while this connection's packets
    // are being decoded; do not hold it past teardown.
    myPrivateKey = nil
    await flushPendingEntries()
  }

  /// Returns a fresh multicast stream of newly received entries (yielded as each is decoded,
  /// before its batched save; a backfilled RX_SYNC record arrives late with `isBackfill` set).
  /// Registration is synchronous, so entries yielded after this call returns
  /// are never dropped, and coexisting subscribers each receive every entry.
  public nonisolated func entryStream() -> AsyncStream<RxLogEntryDTO> {
    entryBroadcaster.subscribe()
  }

  /// Multicast stream of Message IDs whose region fields reprocess changed.
  /// Open chats reload baked region footers from these IDs.
  public nonisolated func regionUpdateEvents() -> AsyncStream<[UUID]> {
    regionUpdateBroadcaster.subscribe()
  }

  /// Ends every `entryStream()` / `regionUpdateEvents()` subscriber's
  /// for-await loop. Called by `ServiceContainer.tearDown()` so consumer
  /// tasks release their service references.
  nonisolated func finishEntryStream() {
    entryBroadcaster.finish()
    regionUpdateBroadcaster.finish()
  }

  /// Rebuilds the channel cache from a fresh channel list.
  /// `ChannelService` forwards every channel write and sync result here so
  /// captured packets can be decoded with current secrets.
  public func updateChannels(from channels: [ChannelDTO]) async {
    // Same duplicate-index hardening as loadSecretsFromDatabase: keep the first match.
    let secrets: [UInt8: Data] = Dictionary(
      channels.map { ($0.index, $0.secret) },
      uniquingKeysWith: { first, _ in first }
    )
    let names: [UInt8: String] = Dictionary(
      channels.map { ($0.index, $0.name) },
      uniquingKeysWith: { first, _ in first }
    )
    await updateChannels(secrets: secrets, names: names)
  }

  /// Update channel cache (secrets and names).
  /// Re-processes any recent noMatchingKey entries when secrets are provided.
  public func updateChannels(secrets: [UInt8: Data], names: [UInt8: String]) async {
    channelSecrets = secrets
    channelNames = names

    if !secrets.isEmpty {
      await reprocessNoMatchingKeyEntries()
    }
  }

  /// Re-process recent entries that failed decryption due to missing keys.
  /// Uses a reentrancy guard to prevent overlapping reprocessing.
  private func reprocessNoMatchingKeyEntries() async {
    guard !isReprocessingChannels else { return }
    isReprocessingChannels = true
    defer { isReprocessingChannels = false }

    guard let radioID else { return }

    let cutoff = Date().addingTimeInterval(-60)

    do {
      let entries = try await dataStore.fetchRecentEntriesByDecryptStatus(
        radioID: radioID,
        status: .noMatchingKey,
        since: cutoff
      )

      guard !entries.isEmpty else { return }
      logger.info("Re-processing \(entries.count) noMatchingKey entries")

      // Collect successful decryptions for batch update
      var updates: [(id: UUID, channelIndex: UInt8?, channelName: String?, senderTimestamp: UInt32?)] = []
      var decryptedEntries: [RxLogEntryDTO] = []

      for entry in entries {
        guard !Task.isCancelled else { break }

        let decrypted = decryptEntry(entry)
        guard decrypted.decodedText != nil else { continue }

        updates.append((
          id: entry.id,
          channelIndex: decrypted.channelIndex,
          channelName: decrypted.channelName,
          senderTimestamp: decrypted.senderTimestamp
        ))
        decryptedEntries.append(decrypted)
      }

      // Batch update database (decodedText is @Transient, not persisted)
      if !updates.isEmpty {
        try await dataStore.batchUpdateRxLogDecryption(updates)

        // Process for heard repeats after DB update
        if let heardRepeatsService {
          for entry in decryptedEntries {
            guard !Task.isCancelled else { break }
            await heardRepeatsService.processForRepeats(entry)
          }
        }

        logger.info("Successfully re-processed \(updates.count) entries")
      }
    } catch {
      logger.error("Failed to re-process noMatchingKey entries: \(error.localizedDescription)")
    }
  }

  /// Re-process recent DM entries that failed decryption due to missing keys.
  /// Called when contact public keys or the device private key become available.
  private func reprocessDMEntries() async {
    guard !isReprocessingDMs else { return }
    isReprocessingDMs = true
    defer { isReprocessingDMs = false }

    guard let radioID, let myPrivateKey else { return }
    guard !contactPublicKeysByPrefix.isEmpty else { return }

    let cutoff = Date().addingTimeInterval(-60)

    do {
      let entries = try await dataStore.fetchRecentEntriesByDecryptStatus(
        radioID: radioID,
        status: .dmNoMatchingKey,
        since: cutoff
      )

      guard !entries.isEmpty else { return }
      logger.info("Re-processing \(entries.count) DM entries for timestamp extraction")

      var updates: [(id: UUID, channelIndex: UInt8?, channelName: String?, senderTimestamp: UInt32?)] = []

      for entry in entries {
        guard !Task.isCancelled else { break }

        if let dmResult = Self.tryDecryptDM(
          payload: entry.packetPayload,
          myPrivateKey: myPrivateKey,
          contactPublicKeysByPrefix: contactPublicKeysByPrefix
        ) {
          updates.append((
            id: entry.id,
            channelIndex: nil,
            channelName: nil,
            senderTimestamp: dmResult.timestamp
          ))
        }
      }

      if !updates.isEmpty {
        try await dataStore.batchUpdateRxLogDecryption(updates)
        logger.info("Successfully re-processed \(updates.count) DM entries")
      }
    } catch {
      logger.error("Failed to re-process DM entries: \(error.localizedDescription)")
    }
  }

  /// Update device private key for direct message decryption.
  /// The exported key is 64 bytes: `[expanded_scalar:32][nonce:32]`.
  /// DirectMessageCrypto needs the 32-byte Curve25519 scalar (first half).
  public func updatePrivateKey(_ key: Data?) async {
    myPrivateKey = key.flatMap { $0.count >= 32 ? Data($0.prefix(32)) : nil }
    if myPrivateKey != nil {
      await reprocessDMEntries()
    }
  }

  /// Update contact public keys for direct message decryption.
  /// Called when contacts sync completes. Re-processes any recent DM entries.
  /// Input keys are Ed25519 public keys; converted to Curve25519 for ECDH.
  public func updateContactPublicKeys(_ keys: [UInt8: [Data]]) async {
    setContactPublicKeys(keys)
    if !contactPublicKeysByPrefix.isEmpty {
      await reprocessDMEntries()
    }
  }

  private func setContactPublicKeys(_ keys: [UInt8: [Data]]) {
    let converted = Self.convertPublicKeysToX25519(keys)
    contactPublicKeysByPrefix = converted.byPrefix
    contactSigningKeys = converted.signingKeys
  }

  /// Convert Ed25519 contact public keys to Curve25519 for DirectMessageCrypto, keeping each
  /// converted key's original.
  private static func convertPublicKeysToX25519(_ keys: [UInt8: [Data]]) -> (byPrefix: [UInt8: [Data]], signingKeys: [Data: Data]) {
    var converted: [UInt8: [Data]] = [:]
    var signingKeys: [Data: Data] = [:]
    for (prefix, publicKeys) in keys {
      let x25519Keys = publicKeys.compactMap { key in
        Ed25519ToX25519.convertPublicKey(key).map { x25519 in
          signingKeys[x25519] = key
          return x25519
        }
      }
      if !x25519Keys.isEmpty {
        converted[prefix] = x25519Keys
      }
    }
    return (converted, signingKeys)
  }

  /// Process a parsed RX log event: decode it, yield it to `entryStream()` and queue it for
  /// the next batched save.
  public func process(_ parsed: ParsedRxLogData) async {
    guard let radioID else { return }

    // epoch 0: no journal named, so nothing to dedupe or replay against (see seedSeenRecords). The
    // session's sequencer already drops a repeat inside one connection.
    if let epoch = parsed.epoch, epoch != 0, let seq = parsed.seq {
      guard seenRecords.insert(epoch: epoch, seq: seq) else {
        logger.debug("Skipping RX_SYNC record \(seq) delivered again")
        return
      }
      if let skipped = replayTracker.take(epoch: epoch, seq: seq, isBackfill: parsed.isBackfill) {
        await replayIfDropped(skipped, epoch: epoch)
      }
    }

    // Decode channel message if applicable
    var channelIndex: UInt8?
    var channelName: String?
    var decryptStatus = DecryptStatus.notApplicable
    var decodedText: String?
    var senderTimestamp: UInt32?
    var peerPublicKey: Data?

    if parsed.payloadType == .groupText || parsed.payloadType == .groupData {
      let outcome = Self.decryptChannelPayload(
        parsed.packetPayload,
        secrets: channelSecrets,
        names: channelNames
      )
      decryptStatus = outcome.status
      if outcome.status == .success {
        channelIndex = outcome.channelIndex
        channelName = outcome.channelName
        senderTimestamp = outcome.timestamp
        decodedText = outcome.text
      }
    }

    // Decrypt direct text messages to extract senderTimestamp and text.
    // The DM wire format is route-independent, so flood-routed DMs decrypt too.
    if parsed.payloadType == .textMessage {
      if let myPrivateKey,
         let dmResult = Self.tryDecryptDM(
           payload: parsed.packetPayload,
           myPrivateKey: myPrivateKey,
           contactPublicKeysByPrefix: contactPublicKeysByPrefix
         ) {
        senderTimestamp = dmResult.timestamp
        decodedText = dmResult.text
        peerPublicKey = contactSigningKeys[dmResult.publicKey]
        decryptStatus = .success
        logger.debug("Decrypted direct message senderTimestamp: \(dmResult.timestamp)")
      }

      if senderTimestamp == nil {
        decryptStatus = .dmNoMatchingKey
        logger.debug("DM decryption failed, marking as dmNoMatchingKey for reprocessing")
      }
    }

    // The advert payload carries the sender's full pubkey at offset 0, followed by the advert
    // timestamp at offset 32. The inbound hop count is an exact keyed write, not a timing
    // correlation. A reserved or truncated encoding skips the write rather than stamping a
    // wrong value. Only flood-routed adverts accumulate a hop path; a direct-routed advert's
    // path length is the remaining route, not hops traversed, so it is excluded.
    if parsed.payloadType == .advert, parsed.routeType.isFlood {
      let payloadBytes = parsed.packetPayload.count
      if payloadBytes >= ProtocolLimits.publicKeySize, let inboundHops = decodePathLen(parsed.pathLength)?.hopCount {
        let advertiserPubKey = Data(parsed.packetPayload.prefix(ProtocolLimits.publicKeySize))
        let advertTimestamp: UInt32? = payloadBytes >= ProtocolLimits.publicKeySize + ProtocolLimits.advertTimestampSize
          ? parsed.packetPayload.readUInt32LE(at: ProtocolLimits.publicKeySize)
          : nil
        do {
          try await dataStore.setInboundHopCount(
            radioID: radioID,
            publicKey: advertiserPubKey,
            hopCount: inboundHops,
            advertTimestamp: advertTimestamp
          )
        } catch {
          logger.error("Failed to stamp inbound hop count: \(error.localizedDescription)")
        }
      }
    }

    let receivedAt = Self.receivedAt(radioAge: parsed.radioAge, now: Date())

    let regionFields = resolveRegion(for: parsed)

    // The channel stamp comes with `parsed` (`ParsedRxLogData.channel`): the session set it from
    // the radio's SELF_INFO when the frame arrived, so nothing here works it out again.
    let dto = RxLogEntryDTO(
      radioID: radioID,
      receivedAt: receivedAt,
      from: parsed,
      channelIndex: channelIndex,
      channelName: channelName,
      decryptStatus: decryptStatus,
      senderTimestamp: senderTimestamp,
      regionScope: regionFields.regionScope,
      regionScopeMatches: regionFields.regionScopeMatches,
      decodedText: decodedText,
      peerPublicKey: peerPublicKey
    )

    // Emit to stream consumers (RX log screens, Live Activity freshness) before the save
    entryBroadcaster.yield(dto)

    await enqueue(dto)
  }

  /// Asks the radio for `skipped` again when this log's subscription dropped events since the last
  /// check: the session sends each live record once, so the hole is this log's own. A jump with no
  /// drops is a gap the session is already fetching.
  private func replayIfDropped(_ skipped: ClosedRange<UInt32>, epoch: UInt32) async {
    guard let rxSync else { return }
    let drops = await session.eventDropCount(label: Self.eventLabel)
    guard drops > knownEventDrops else { return }
    knownEventDrops = drops
    if await rxSync.requestRxReplay(from: skipped.lowerBound, count: skipped.count) {
      logger.warning("RX log dropped RX_SYNC records \(skipped.lowerBound)-\(skipped.upperBound); asked for them again")
      replayTracker.noteRequested(skipped, epoch: epoch, at: Date())
    }
  }

  /// When the radio received a packet: `now`, less the time an RX_SYNC record waited in the
  /// radio's journal (a backfill, or a record queued behind a busy link).
  static func receivedAt(radioAge: Duration?, now: Date) -> Date {
    guard let radioAge, radioAge > .zero else { return now }
    let components = radioAge.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return now.addingTimeInterval(-seconds)
  }

  // MARK: - Batched Saves

  /// Whether an entry is saved at once rather than batched: a message's path lookup
  /// (`SyncCoordinator.lookupRxLogEntry`) reads it from the store moments after it arrives.
  /// That is a decrypted channel message, or any direct text message (found by sender prefix
  /// before it decrypts).
  static func needsImmediateSave(_ entry: RxLogEntryDTO) -> Bool {
    switch entry.payloadType {
    case .textMessage:
      true
    case .groupText, .groupData:
      entry.decryptStatus == .success
    default:
      false
    }
  }

  /// Queues an entry for saving: at once when a lookup needs it (waiting for that save), with a
  /// full batch, or otherwise by the partial-batch timer.
  private func enqueue(_ entry: RxLogEntryDTO) async {
    pendingEntries.append(entry)
    if Self.needsImmediateSave(entry) {
      scheduleFlush()
      await flushTask?.value
    } else if pendingEntries.count >= RxLogRetention.batchSize {
      scheduleFlush()
    } else {
      scheduleFlushTimer()
    }
  }

  /// Saves every entry still batched and waits for the saves, and heard repeats, to finish.
  /// Called by `stopEventMonitoring()` so a teardown loses nothing.
  public func flushPendingEntries() async {
    scheduleFlush()
    await flushTask?.value
  }

  /// Hands the pending entries to a flush that starts once the previous one has finished.
  private func scheduleFlush() {
    flushTimerTask?.cancel()
    flushTimerTask = nil
    flushTimerGeneration += 1
    guard !pendingEntries.isEmpty else { return }
    let batch = pendingEntries
    pendingEntries = []
    for entry in batch {
      writingEntries[entry.id] = entry
    }
    let previous = flushTask
    flushTask = Task {
      await previous?.value
      await self.write(batch)
    }
  }

  private func scheduleFlushTimer() {
    guard flushTimerTask == nil else { return }
    let generation = flushTimerGeneration
    flushTimerTask = Task { [weak self] in
      try? await Task.sleep(for: RxLogRetention.flushInterval)
      guard !Task.isCancelled else { return }
      await self?.flushTimerFired(generation: generation)
    }
  }

  private func flushTimerFired(generation: Int) {
    // A full batch or an immediate save already took this timer's entries.
    guard generation == flushTimerGeneration else { return }
    flushTimerTask = nil
    scheduleFlush()
  }

  /// Saves one batch in a single commit, advances the RX_SYNC cursor only once it has, then runs
  /// heard repeats over the batch in order.
  private func write(_ batch: [RxLogEntryDTO]) async {
    var saved = false
    do {
      try await entryWriter.saveRxLogEntries(batch)
      saved = true
    } catch {
      logger.error("Failed to save \(batch.count) RX log entries: \(error.localizedDescription)")
    }
    for entry in batch {
      writingEntries[entry.id] = nil
    }
    if saved {
      await advanceStreamCursors(after: batch)
    }

    // Inline awaits keep the backpressure on heard repeats without blocking the event loop
    if let heardRepeatsService {
      for entry in batch {
        await heardRepeatsService.processForRepeats(entry)
      }
    }
  }

  /// Moves each radio's resume cursor past the RX_SYNC records of a saved batch.
  private func advanceStreamCursors(after batch: [RxLogEntryDTO]) async {
    let records = batch.filter { $0.radioSeq != nil }
    for radioID in Set(records.map(\.radioID)) {
      var current = streamCursors[radioID]
      if current == nil {
        current = try? await entryWriter.fetchRxStreamCursor(radioID: radioID)
      }
      let saved = Self.advancedCursor(savedHighs[radioID] ?? current, after: records.filter { $0.radioID == radioID })
      savedHighs[radioID] = saved
      var advanced = saved
      if let epoch = saved?.epoch {
        advanced = Self.cappedCursor(saved, current: current, floor: await resumeFloor(epoch: epoch))
      }
      guard let advanced, advanced != current else { continue }
      do {
        try await entryWriter.saveRxStreamCursor(advanced, radioID: radioID)
        streamCursors[radioID] = advanced
      } catch {
        logger.error("Failed to save the RX_SYNC cursor: \(error.localizedDescription)")
      }
    }
  }

  /// The cursor once `entries` are saved: the newest record of the newest epoch. A record from
  /// another epoch than the cursor's starts it again (the radio rebooted); epoch 0, a record from
  /// before the radio named its journal, never moves it.
  static func advancedCursor(_ cursor: RxStreamCursor?, after entries: [RxLogEntryDTO]) -> RxStreamCursor? {
    var result = cursor
    for entry in entries {
      guard let epoch = entry.radioEpoch, epoch != 0, let seq = entry.radioSeq else { continue }
      if let current = result, current.epoch == epoch, current.seq >= seq { continue }
      result = RxStreamCursor(epoch: epoch, seq: seq)
    }
    return result
  }

  /// The newest record of `epoch` with nothing still on its way before it: the session's
  /// contiguous mark (a record it is still fetching) and the oldest record this log asked to have
  /// again. `nil` when nothing holds the cursor back.
  private func resumeFloor(epoch: UInt32) async -> UInt32? {
    var floor: UInt32?
    if let rxSync {
      let stats = await rxSync.rxDeliveryStats
      if stats.epoch == epoch { floor = stats.contiguousSeq }
    }
    if let pending = replayTracker.lowestPending(epoch: epoch, now: Date()) {
      let belowPending = pending &- 1
      floor = min(floor ?? belowPending, belowPending)
    }
    return floor
  }

  /// `cursor` held at `floor` when it would pass it: a resume after a record still on its way
  /// would skip it for good. A cursor never moves back within its epoch; records sent again after
  /// the floor are dropped by their (epoch, seq).
  static func cappedCursor(_ cursor: RxStreamCursor?, current: RxStreamCursor?, floor: UInt32?) -> RxStreamCursor? {
    guard let cursor, let floor, cursor.seq > floor else { return cursor }
    if let current, current.epoch == cursor.epoch, current.seq >= floor { return current }
    return RxStreamCursor(epoch: cursor.epoch, seq: floor)
  }

  /// `stored` with the radio's entries that aren't saved yet merged in, newest first.
  private func mergingUnsaved(_ stored: [RxLogEntryDTO], radioID: UUID, limit: Int) -> [RxLogEntryDTO] {
    let storedIDs = Set(stored.map(\.id))
    let unsaved = (pendingEntries + writingEntries.values).filter {
      $0.radioID == radioID && !storedIDs.contains($0.id)
    }
    guard !unsaved.isEmpty else { return stored }
    return Array((stored + unsaved).sorted { $0.receivedAt > $1.receivedAt }.prefix(limit))
  }

  /// Load existing entries from database, re-decrypting payloads with current secrets.
  public func loadExistingEntries() async -> [RxLogEntryDTO] {
    guard let radioID else { return [] }
    let limit = 500
    do {
      let stored = try await dataStore.fetchRxLogEntries(radioID: radioID, limit: limit)
      return mergingUnsaved(stored, radioID: radioID, limit: limit).map { decryptEntry($0) }
    } catch {
      logger.error("Failed to load RX log entries: \(error.localizedDescription)")
      return []
    }
  }

  /// Entries received at or after `since`, newest first, as stored: no re-decryption, so a
  /// long read-back for a time chart stays cheap. Names and channels resolved at capture are
  /// kept; pass an entry through `decodedEntries(_:)` to recover its text for display.
  /// Reads the whole retained log (the prune cap bounds it), so the window is never cut short
  /// by the RX Log screen's smaller page. Entries still waiting for a batched save are included.
  public func recentEntries(since: Date) async -> [RxLogEntryDTO] {
    guard let radioID else { return [] }
    let cap = RxLogRetention.keepCount + RxLogRetention.pruneThreshold + RxLogRetention.batchSize
    do {
      let stored = try await dataStore.fetchRxLogEntries(radioID: radioID, limit: cap)
      return mergingUnsaved(stored, radioID: radioID, limit: cap)
        .filter { $0.receivedAt >= since }
    } catch {
      logger.error("Failed to load recent RX log entries: \(error.localizedDescription)")
      return []
    }
  }

  // MARK: - Decryption

  /// Re-decrypt a batch of RX log entries. One hop for coordinator lookup and harvest.
  public func decodedEntries(_ entries: [RxLogEntryDTO]) -> [RxLogEntryDTO] {
    entries.map { decryptEntry($0) }
  }

  /// Attempt to decrypt a channel message entry using current secrets.
  /// Returns a copy of the entry with `decodedText` populated if decryption succeeds.
  /// This is reusable for export and other features that need decrypted content.
  ///
  /// If the entry was previously decrypted (`decryptStatus == .success`),
  /// we use the stored channel index for O(1) secret lookup instead of trying all keys.
  public func decryptEntry(_ entry: RxLogEntryDTO) -> RxLogEntryDTO {
    var result = entry

    // Attempt DM decryption for text messages (any route type)
    if entry.payloadType == .textMessage {
      if let myPrivateKey,
         let dmResult = Self.tryDecryptDM(
           payload: entry.packetPayload,
           myPrivateKey: myPrivateKey,
           contactPublicKeysByPrefix: contactPublicKeysByPrefix
         ) {
        result.senderTimestamp = dmResult.timestamp
        result.decodedText = dmResult.text
        result.peerPublicKey = contactSigningKeys[dmResult.publicKey]
        result.decryptStatus = .success
      }
      return result
    }

    // Only attempt decryption for channel messages
    guard entry.payloadType == .groupText || entry.payloadType == .groupData else {
      return result
    }

    // Fast path: the stored channel index is tried first when the entry was
    // previously decrypted; the rest are tried in index order.
    let outcome = Self.decryptChannelPayload(
      entry.packetPayload,
      secrets: channelSecrets,
      names: channelNames,
      preferredIndex: entry.decryptStatus == .success ? entry.channelIndex : nil
    )
    if outcome.status == .success {
      result.channelIndex = outcome.channelIndex
      result.channelName = outcome.channelName
      result.senderTimestamp = outcome.timestamp
      result.decodedText = outcome.text
      result.decryptStatus = .success
    }
    return result
  }

  /// Result of trying the known channel secrets against a group payload.
  struct ChannelDecryptOutcome: Equatable {
    var status: DecryptStatus
    var channelIndex: UInt8?
    var channelName: String?
    var timestamp: UInt32?
    var text: String?
  }

  /// Decrypts a group (channel) payload `[channelHash:1][MAC:2][ciphertext:N]`
  /// with the known channel secrets.
  ///
  /// The channel hash byte is only a 1-byte hint, so every secret is tried
  /// (preferred index first, then ascending index for a deterministic pick).
  /// When no secret authenticates, a secret whose SHA-256 first byte matches
  /// the hash byte classifies the failure as `.hmacFailed` / `.decryptFailed`
  /// (key known, packet bad); otherwise the result is `.noMatchingKey`.
  static func decryptChannelPayload(
    _ packetPayload: Data,
    secrets: [UInt8: Data],
    names: [UInt8: String],
    preferredIndex: UInt8? = nil
  ) -> ChannelDecryptOutcome {
    // Need at least: 1 (channel hash) + 2 (MAC) + 16 (one AES block)
    guard packetPayload.count >= 1 + ChannelCrypto.macSize + 16 else {
      return ChannelDecryptOutcome(status: secrets.isEmpty ? .noMatchingKey : .decryptFailed)
    }

    let hashByte = packetPayload[packetPayload.startIndex]
    let encryptedPayload = Data(packetPayload.dropFirst(1))
    var ordered = secrets.keys.sorted()
    if let preferredIndex, let position = ordered.firstIndex(of: preferredIndex) {
      ordered.remove(at: position)
      ordered.insert(preferredIndex, at: 0)
    }

    var knownKeyFailure: DecryptStatus?
    for index in ordered {
      guard let secret = secrets[index] else { continue }
      switch ChannelCrypto.decrypt(payload: encryptedPayload, secret: secret) {
      case let .success(timestamp, _, text):
        return ChannelDecryptOutcome(
          status: .success,
          channelIndex: index,
          channelName: names[index] ?? "Channel \(index)",
          timestamp: timestamp,
          text: text
        )
      case .hmacFailed:
        if knownKeyFailure == nil, channelHashByte(for: secret) == hashByte {
          knownKeyFailure = .hmacFailed
        }
      case .decryptFailed, .payloadTooShort:
        if channelHashByte(for: secret) == hashByte {
          knownKeyFailure = .decryptFailed
        }
      }
    }
    return ChannelDecryptOutcome(status: knownKeyFailure ?? .noMatchingKey)
  }

  /// First byte of SHA-256 over the channel secret: the firmware's 1-byte channel hash.
  static func channelHashByte(for secret: Data) -> UInt8 {
    SHA256.hash(data: secret).withUnsafeBytes { $0[0] }
  }

  /// Try decrypting a DM payload by iterating candidate keys for the sender prefix byte,
  /// then the destination prefix byte. The ECDH shared secret is symmetric, so a DM
  /// this radio sent to a contact (heard again via a repeater) decrypts with the
  /// destination contact's key.
  /// Returns the decrypted timestamp and text, and the (Curve25519) key that decrypted it, or nil
  /// if no key matched.
  static func tryDecryptDM(
    payload: Data,
    myPrivateKey: Data,
    contactPublicKeysByPrefix: [UInt8: [Data]]
  ) -> (timestamp: UInt32, text: String?, publicKey: Data)? {
    guard payload.count >= DirectMessageCrypto.minPacketSize else { return nil }
    // DM payload: [destHash:1][srcHash:1][MAC:2][ciphertext:N]
    let destPrefix = payload[payload.startIndex]
    let senderPrefix = payload[payload.startIndex + 1]
    var candidateKeys = contactPublicKeysByPrefix[senderPrefix] ?? []
    if destPrefix != senderPrefix {
      candidateKeys += contactPublicKeysByPrefix[destPrefix] ?? []
    }

    for publicKey in candidateKeys {
      if case let .success(timestamp, _, text) = DirectMessageCrypto.decrypt(
        payload: payload,
        myPrivateKey: myPrivateKey,
        senderPublicKey: publicKey
      ) {
        return (timestamp, text, publicKey)
      }
    }
    return nil
  }

  /// Clear all entries, including those still waiting for a batched save.
  public func clearEntries() async {
    guard let radioID else { return }
    pendingEntries.removeAll { $0.radioID == radioID }
    // A save already under way finishes first, so the clear removes its rows too.
    await flushTask?.value
    do {
      try await dataStore.clearRxLogEntries(radioID: radioID)
    } catch {
      logger.error("Failed to clear RX log entries: \(error.localizedDescription)")
    }
  }
}

// MARK: - RX_SYNC Replay Tracking

/// Spots the holes a consumer's own subscription makes in RX_SYNC's live records. The session sends
/// each record once and live ones in order, so a live record more than one past the last one means
/// the ones between were dropped on the way (or the session is still fetching them). Keeps the
/// replays asked for until their records arrive, or for ``giveUpAfter`` (the journal may no longer
/// hold them).
struct RxReplayTracker {
  /// How long a replay's records are waited for.
  static let giveUpAfter: TimeInterval = 30

  private struct Pending {
    let epoch: UInt32
    var seqs: Set<UInt32>
    let askedAt: Date
  }

  private var lastLive: (epoch: UInt32, seq: UInt32)?
  private var pending: [Pending] = []

  /// Takes the record `seq` of `epoch`. Returns the live records it skips, if any.
  mutating func take(epoch: UInt32, seq: UInt32, isBackfill: Bool) -> ClosedRange<UInt32>? {
    for index in pending.indices where pending[index].epoch == epoch {
      pending[index].seqs.remove(seq)
    }
    pending.removeAll { $0.seqs.isEmpty }
    guard !isBackfill else { return nil }
    guard let last = lastLive, last.epoch == epoch else {
      lastLive = (epoch, seq)
      return nil
    }
    guard seq > last.seq else { return nil }
    lastLive = (epoch, seq)
    return seq > last.seq &+ 1 ? (last.seq + 1)...(seq - 1) : nil
  }

  /// Notes that `range` of `epoch` was asked for again at `date`.
  mutating func noteRequested(_ range: ClosedRange<UInt32>, epoch: UInt32, at date: Date) {
    pending.append(Pending(epoch: epoch, seqs: Set(range), askedAt: date))
  }

  /// The oldest record of `epoch` asked for again and not yet taken; replays older than
  /// ``giveUpAfter`` are given up.
  mutating func lowestPending(epoch: UInt32, now: Date) -> UInt32? {
    pending.removeAll { now.timeIntervalSince($0.askedAt) > Self.giveUpAfter }
    return pending.filter { $0.epoch == epoch }.compactMap { $0.seqs.min() }.min()
  }
}

// MARK: - RX_SYNC Record Dedup

/// The RX_SYNC records a consumer has taken, by (epoch, seq). Past `capacity` the oldest is
/// forgotten.
struct RxRecordDedup {
  private struct Key: Hashable {
    let epoch: UInt32
    let seq: UInt32
  }

  let capacity: Int
  private var seen: Set<Key> = []
  private var order: [Key] = []
  /// The oldest key's slot in `order` once it is full.
  private var oldest = 0

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  /// Records `(epoch, seq)`. Returns `false` when it was already taken.
  mutating func insert(epoch: UInt32, seq: UInt32) -> Bool {
    let key = Key(epoch: epoch, seq: seq)
    guard seen.insert(key).inserted else { return false }
    if order.count < capacity {
      order.append(key)
    } else {
      seen.remove(order[oldest])
      order[oldest] = key
      oldest = (oldest + 1) % capacity
    }
    return true
  }
}
