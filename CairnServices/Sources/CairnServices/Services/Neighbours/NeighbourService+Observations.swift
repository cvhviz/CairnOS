import Foundation
import MeshCore

// MARK: - Ledger Changes

/// The ledger rows changed and removed since the last write, for one channel.
struct LedgerChanges: Sendable, Equatable {
  var upserted: [ObservedNode]
  var removed: [ObservedIdentity]

  var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }
}

// MARK: - Observations

extension NeighbourService {
  // MARK: Reading

  /// What this radio observed on `channelKey`: the live ledger for the current channel, else the
  /// stored one. For RX log rows received on an earlier channel, which resolve against that
  /// channel's observations. Read-only. Nil while the service has no radio (not started, or
  /// stopped): it can't say, and an empty answer would be kept as that channel's ledger.
  public func ledgerSnapshot(channelKey: ChannelKey) async -> LedgerSnapshot? {
    let date = now()
    if channelKey == channel?.key, ledger != nil {
      return currentLedgerSnapshot(at: date)
    }
    guard let radioID else { return nil }
    var nodes: [ObservedIdentity: ObservedNode] = [:]
    do {
      for node in try await dataStore.fetchObservedNodes(radioID: radioID, channelKey: channelKey)
        where !node.isOnlyAdvertPush {
        nodes[node.identity] = node
      }
    } catch {
      neighbourLogger.error("Failed to load observed nodes of \(channelKey.rawValue): \(error.localizedDescription)")
    }
    // A batch whose save failed is still the newest word on its rows
    if let unsaved = unsavedLedger[channelKey] {
      for identity in unsaved.removed {
        nodes[identity] = nil
      }
      for node in unsaved.upserted {
        nodes[node.identity] = node
      }
    }
    let rows = Array(nodes.values)
    return LedgerSnapshot(
      radioID: radioID,
      channelKey: channelKey,
      channel: RadioChannelConfig(key: channelKey),
      selfKey: selfKey,
      takenAt: date,
      version: Self.contentVersion(rows),
      nodes: rows
    )
  }

  /// The current channel's ledger as published, or a cold snapshot while there is none. Its
  /// version only grows, across channel switches and reloads.
  func currentLedgerSnapshot(at date: Date) -> LedgerSnapshot {
    guard let ledger else {
      return LedgerSnapshot(
        radioID: radioID,
        channelKey: nil,
        channel: nil,
        selfKey: selfKey,
        takenAt: date,
        version: 0,
        nodes: []
      )
    }
    let version = ledgerVersionBase + ledger.version
    lastPublishedLedgerVersion = max(lastPublishedLedgerVersion, version)
    return ledger.snapshot(takenAt: date, version: version)
  }

  /// A version for stored rows, which carry none: equal rows give equal versions.
  static func contentVersion(_ nodes: [ObservedNode]) -> Int {
    nodes.reduce(into: nodes.count) { hash, node in
      hash = hash &* 31 &+ node.identity.bytes.hashValue
      hash = hash &* 31 &+ Int(node.lastObservedAt.timeIntervalSince1970 * 1000)
    }
  }

  // MARK: Channel

  /// Loads `config`'s stored table and ledger and replays the stored RX log received on it.
  /// - Parameters:
  ///   - overlapFrom: Live frames received after this may also be in the replay.
  ///   - generation: The run this load belongs to.
  func activate(_ config: RadioChannelConfig, overlapFrom: Date, generation: Int) async {
    guard let radioID else { return }
    activation += 1
    let current = activation
    let key = config.key
    channel = config
    ledger = nil
    table = NeighbourTable()

    let startedAt = now()
    var stored: [NeighbourRecord] = []
    do {
      stored = try await dataStore.fetchNeighbourRecords(radioID: radioID, channelKey: key)
    } catch {
      neighbourLogger.error("Failed to load stored neighbours: \(error.localizedDescription)")
    }
    var observed: [ObservedNode] = []
    do {
      observed = try await dataStore.fetchObservedNodes(radioID: radioID, channelKey: key)
    } catch {
      neighbourLogger.error("Failed to load observed nodes: \(error.localizedDescription)")
    }
    let entries = await loadReplayEntries(
      radioID: radioID,
      channelKey: key,
      since: startedAt.addingTimeInterval(-Self.replayWindow)
    )
    guard generation == self.generation, current == activation else { return }

    var loaded = NeighbourTable(records: stored)
    if let lastProbe {
      loaded.noteProbe(tag: lastProbe.tag, at: lastProbe.sentAt)
    }
    table = loaded
    var loadedLedger = ObservationLedger(radioID: radioID, channel: config, selfKey: selfKey, nodes: observed)
    loadedLedger.prune(now: now())
    ledger = loadedLedger
    ledgerVersionBase = lastPublishedLedgerVersion + 1

    // Stored rows already hold everything heard up to their newest reception
    replay(
      entries,
      watermark: stored.map(\.lastHeard).max(),
      overlapStart: overlapFrom.addingTimeInterval(-Self.replayOverlapMargin)
    )
    table.prune(now: now())
    neighbourLogger.info("Loaded \(key.rawValue): \(stored.count) stored rows, \(observed.count) observed, \(entries.count) replayed")
    scheduleUpdate()
  }

  /// Flushes the current channel's table and ledger, then loads `config`'s; nil goes cold until
  /// the radio reports its channel. Probe state belongs to the old channel and is dropped.
  func switchChannel(to config: RadioChannelConfig?) async {
    let generation = generation
    await flush()
    guard generation == self.generation else { return }
    activation += 1
    table = NeighbourTable()
    ledger = nil
    channel = nil
    lastProbe = nil
    replayOverlap = [:]
    scheduleUpdate()
    guard let config else {
      neighbourLogger.info("Radio channel unconfirmed: neighbours cold")
      return
    }
    isWarm = false
    await activate(config, overlapFrom: now(), generation: generation)
    guard generation == self.generation else { return }
    isWarm = true
    resumeBootstrapWaiters()
  }

  /// The channel a live push counts on: the session's current one. A channel the table isn't on
  /// yet is switched to first (the `SELF_INFO` saying so may still be queued); none (a retune
  /// waiting for the radio) goes cold and gives nil.
  func pushChannel() async -> RadioChannelConfig? {
    let generation = generation
    let config = await session.currentChannelConfig
    guard generation == self.generation else { return nil }
    if config?.key != channel?.key {
      await switchChannel(to: config)
    }
    guard generation == self.generation, let config, ledger != nil else { return nil }
    return config
  }

  /// Goes cold when the session no longer vouches for a channel: a radio-parameters write until
  /// the radio confirms its new one.
  func goColdIfRetuning() async {
    let generation = generation
    let config = await session.currentChannelConfig
    guard generation == self.generation, config == nil, channel != nil else { return }
    await switchChannel(to: nil)
  }

  // MARK: Entries

  /// A decoded RX log entry: a direct message decrypted from its peer is an observation, and an
  /// exact echo of our own flood passed on by one relay proves that relay hears us (R8).
  func handleEntry(_ entry: RxLogEntryDTO, generation: Int) async {
    guard generation == self.generation, entry.radioID == radioID,
          let key = entry.channelKey, key == channel?.key, ledger != nil else { return }
    if let observation = ObservationExtractor.decryptedMessageObservation(entry, channelKey: key, selfKey: selfKey) {
      ingestObservations([observation])
    }
    guard let ownTransmissions, hasRecentSends(around: entry.receivedAt) else { return }
    let match = await ownTransmissions.match(entry, selfKey: selfKey)
    guard generation == self.generation, key == channel?.key,
          let match, match.confidence == .exact, match.relation == .echo, entry.isFlood,
          let hops = PathHops.split(pathNodes: entry.pathNodes, pathLength: entry.pathLength),
          hops.count == 1 else { return }
    if table.noteHearsYou(relayHash: hops[0], at: entry.receivedAt) {
      scheduleUpdate()
    }
  }

  // MARK: Own transmissions

  func noteOwnSends(_ sends: [OwnTransmission], generation: Int) {
    guard generation == self.generation else { return }
    ownSends = sends
  }

  /// Whether this radio sent anything an entry received at `date` could echo.
  func hasRecentSends(around date: Date) -> Bool {
    ownSends.contains { send in
      let age = date.timeIntervalSince(send.writtenAt)
      return age >= -OwnTransmissionMatcher.earlyTolerance && age <= OwnTransmissionMatcher.echoWindow
    }
  }

  /// The packet hashes proven to be ours, for a 1-hop flood received at `date`: its relay heard
  /// us when it is one of them (R8). Empty for any other packet, which can't say.
  func ownPacketHashes(for fields: RxPacketFields, at date: Date) -> Set<String> {
    guard fields.routeType.isFlood, !ownSends.isEmpty,
          PathHops.split(pathNodes: fields.pathNodes, pathLength: fields.pathLength)?.count == 1 else { return [] }
    let cutoff = date.addingTimeInterval(-OwnTransmissionMatcher.echoWindow)
    return ownSends.reduce(into: Set<String>()) { hashes, send in
      if send.writtenAt >= cutoff { hashes.formUnion(send.provenPacketHashes) }
    }
  }

  // MARK: Storage

  /// Prunes the ledger and queues what changed on it for the next write.
  func noteLedgerChanges(key: ChannelKey, now date: Date) {
    guard var current = ledger, current.channelKey == key else { return }
    if current.prune(now: date) {
      scheduleUpdate()
    }
    let taken = current.takeChanges()
    ledger = current
    let changes = LedgerChanges(upserted: taken.upserted, removed: taken.removed)
    guard !changes.isEmpty else { return }
    unsavedLedger[key] = unsavedLedger[key].map { Self.combine(older: $0, newer: changes) } ?? changes
  }

  /// Writes every queued ledger batch, one save per channel. A batch that fails is kept.
  func saveLedgerChanges(radioID: UUID) async {
    for (key, changes) in unsavedLedger {
      unsavedLedger[key] = nil
      do {
        try await dataStore.saveObservedNodes(
          radioID: radioID,
          channelKey: key,
          upserting: changes.upserted,
          removing: changes.removed
        )
      } catch {
        neighbourLogger.error("Failed to save \(changes.upserted.count) observed nodes: \(error.localizedDescription)")
        guard radioID == self.radioID else { continue }
        unsavedLedger[key] = unsavedLedger[key].map { Self.combine(older: changes, newer: $0) } ?? changes
      }
    }
  }

  /// Two ledger batches as one; where both touch a row, `newer` wins.
  static func combine(older: LedgerChanges, newer: LedgerChanges) -> LedgerChanges {
    let newerUpserted = Set(newer.upserted.map(\.identity))
    let newerRemoved = Set(newer.removed)
    let upserted = older.upserted.filter { !newerUpserted.contains($0.identity) && !newerRemoved.contains($0.identity) }
      + newer.upserted
    let removed = Set(older.removed).subtracting(newerUpserted).union(newerRemoved)
    return LedgerChanges(upserted: upserted, removed: Array(removed))
  }
}
