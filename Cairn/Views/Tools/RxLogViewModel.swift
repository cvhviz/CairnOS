import Foundation
import CairnServices

@Observable
@MainActor
final class RxLogViewModel {
  enum RouteFilter: String, CaseIterable {
    case all
    case floodOnly
    case directOnly

    var displayName: String {
      switch self {
      case .all: L10n.Tools.Tools.RxLog.Filter.all
      case .floodOnly: L10n.Tools.Tools.RxLog.Filter.floodOnly
      case .directOnly: L10n.Tools.Tools.RxLog.Filter.directOnly
      }
    }
  }

  enum DecryptFilter: String, CaseIterable {
    case all
    case decrypted
    case failed

    var displayName: String {
      switch self {
      case .all: L10n.Tools.Tools.RxLog.Filter.all
      case .decrypted: L10n.Tools.Tools.RxLog.Filter.decrypted
      case .failed: L10n.Tools.Tools.RxLog.Filter.failed
      }
    }
  }

  /// What kind of packet: adverts, messages (direct, channel, data), traces, acks, paths,
  /// requests and replies, or anything else.
  enum TypeFilter: String, CaseIterable {
    case all
    case adverts
    case messages
    case traces
    case acks
    case paths
    case requests
    case other

    var displayName: String {
      switch self {
      case .all: L10n.Tools.Tools.RxLog.Filter.all
      case .adverts: L10n.Tools.Tools.RxLog.PacketType.adverts
      case .messages: L10n.Tools.Tools.RxLog.PacketType.messages
      case .traces: L10n.Tools.Tools.RxLog.PacketType.traces
      case .acks: L10n.Tools.Tools.RxLog.PacketType.acks
      case .paths: L10n.Tools.Tools.RxLog.PacketType.paths
      case .requests: L10n.Tools.Tools.RxLog.PacketType.requests
      case .other: L10n.Tools.Tools.RxLog.PacketType.other
      }
    }

    /// The filter `type` falls under; `.all` matches everything.
    static func matching(_ type: PayloadType) -> TypeFilter {
      switch type {
      case .advert: .adverts
      case .textMessage, .groupText, .groupData: .messages
      case .trace: .traces
      case .ack: .acks
      case .path: .paths
      case .request, .response, .anonRequest: .requests
      case .multipart, .control, .rawCustom, .unknown: .other
      }
    }

    func includes(_ type: PayloadType) -> Bool {
      self == .all || Self.matching(type) == self
    }
  }

  /// A node packets came from, for the From Node filter: its key (or the bytes the packets name
  /// it by) and how it is listed.
  struct SenderOption: Identifiable, Equatable {
    let key: Data
    let name: String
    let count: Int

    var id: Data { key }
  }

  /// The most entries kept; the oldest go first.
  static let entryCap = 1000
  /// The most senders the From Node filter lists, busiest first.
  static let senderOptionLimit = 12

  /// Every entry, oldest first, so a live packet is an append and a prune drops from the front;
  /// slices make both O(1). `displayEntries(groupingDuplicates:)` reads them newest first.
  private(set) var entries: ArraySlice<RxLogEntryDTO> = []
  /// `entries` passing the current filters, oldest first. Kept up to date as packets arrive,
  /// are pruned, or the filters change, so the list never re-filters the whole log per packet.
  private(set) var filteredEntries: ArraySlice<RxLogEntryDTO> = []
  /// `entries` passing the route filter alone, oldest first, kept up to date the same way: the
  /// Traffic map's packets. The decrypt filter is the list's own; the map still draws a packet
  /// the app couldn't read.
  private(set) var mapEntries: ArraySlice<RxLogEntryDTO> = []
  /// `filteredEntries` with only the newest reception of each packet, oldest first.
  private(set) var dedupedEntries: ArraySlice<RxLogEntryDTO> = []
  private(set) var groupCounts: [String: Int] = [:]
  private(set) var routeFilter: RouteFilter = .all
  private(set) var decryptFilter: DecryptFilter = .all
  private(set) var typeFilter: TypeFilter = .all
  /// Only packets from this node (`SenderOption.key`); nil lists every sender.
  private(set) var senderFilter: Data?
  /// What the list is searched for: a sender or recipient's name, a message's text, a hash.
  /// Empty searches nothing.
  var searchText = "" {
    didSet { if searchText != oldValue { rebuildFiltered() } }
  }
  /// The stored log has been read in, so an empty log is really empty rather than still loading.
  private(set) var hasLoadedHistory = false

  /// What this radio observed on its channel, which the rows name senders and hops from and the
  /// Traffic map places them from: one directory for every screen, so none can disagree about
  /// which node a hash is, and none names a node this radio never heard on the packet's channel.
  private(set) var observations: ObservationDirectory
  /// Each entry's nodes as last resolved, against the directory and the sends at
  /// `packetCacheVersion`.
  @ObservationIgnored private var packetCache: [UUID: PacketNodes] = [:]
  @ObservationIgnored private var packetCacheVersion = (observations: 0, sent: 0)
  /// What this radio sent lately, which says who sent its echoes and the replies to it, for the
  /// rows as for the Traffic map (`TrafficRouteResolver.packetNodes`).
  @ObservationIgnored let sentLog: TrafficSentLog

  init(sentLog: TrafficSentLog = .shared, observations: ObservationDirectory = ObservationDirectory()) {
    self.sentLog = sentLog
    self.observations = observations
  }

  /// The current channel's index: what a row with no resolved nodes handed over is resolved
  /// against.
  var nodeIndex: PacketNodeIndex {
    observations.nodeIndex
  }

  /// `entries` as the CSV export writes them. Each entry's sender and recipient bytes are named
  /// only from the channel it was received on, as its row resolves them: the current channel's
  /// observations, another channel's once read in, and none (hex) for an entry no channel was
  /// recorded for or whose channel isn't read in yet.
  func csvTable(for entries: some Sequence<RxLogEntryDTO>) -> CSVTable {
    var namesByChannel: [ChannelKey: [Data: String]] = [:]
    var table = CSVTable(headers: DataExportFormatter.rxLogHeaders)
    for entry in entries {
      var names: [Data: String] = [:]
      if let key = entry.channelKey {
        if let known = namesByChannel[key] {
          names = known
        } else {
          let index = observations.index(for: entry)
          names = index.channelKey == key ? index.uniqueNames() : [:]
          namesByChannel[key] = names
        }
      }
      for row in DataExportFormatter.rxLogCSV([entry], nodeNames: names).rows {
        table.append(row)
      }
    }
    return table
  }

  /// How many nodes this radio has heard on its current channel, for the "Learning this channel"
  /// banner.
  var ledgerNodeCount: Int {
    observations.ledgerNodeCount
  }

  /// Whether the app has only lately started hearing the current channel, so many relays still
  /// show by hash.
  var isLearningChannel: Bool {
    observations.isLearningChannel()
  }

  /// The header's line on how this connection's packets reach the app: Cairn RX_SYNC counts
  /// what was recovered and lost; other firmware is measured with the radio's own packet counter
  /// where it has one, else says packets can be skipped. Nil while the radio hasn't said which it
  /// offers.
  private(set) var deliveryLine: String?
  /// The delivery line reports packets lost, or recovery missing (`deliveryNeedsAttention(for:)`):
  /// Scan & Traffic marks its Packets switch.
  private(set) var deliveryNeedsAttention = false
  /// The second header line on firmware without RX_SYNC: received packets longer than the radio
  /// passes on never reach the app. Also the Traffic map's note. Nil in any other mode.
  private(set) var longPacketNote: String?

  /// How often the delivery line is read again while the log is open.
  static let deliveryRefreshInterval: Duration = .seconds(2)

  private var streamTask: Task<Void, Never>?
  private var deliveryTask: Task<Void, Never>?
  /// The delivery service told to keep stock delivery measured while the log is open, and the
  /// chain of those calls, so a stop and a new start always reach it in order.
  @ObservationIgnored private weak var watchedStreamService: RxStreamService?
  @ObservationIgnored private var watchTask: Task<Void, Never>?

  // MARK: - Dependencies

  private var rxLogServiceProvider: @MainActor () -> RxLogService? = { nil }
  private var rxStreamServiceProvider: @MainActor () -> RxStreamService? = { nil }

  private var rxLogService: RxLogService? {
    rxLogServiceProvider()
  }

  /// The provider reads live state, so change detection needs the instance
  /// seen at the previous subscribe. Weak, so a torn-down container's
  /// deallocated service reads as a change.
  private weak var subscribedService: RxLogService?

  /// Each provider is read live at its point of use; a provider returning
  /// nil mirrors a disconnected state, so unconfigured calls are no-ops.
  func configure(
    rxLogService: @escaping @MainActor () -> RxLogService?,
    rxStreamService: @escaping @MainActor () -> RxStreamService? = { nil },
    observations: ObservationDirectory? = nil
  ) {
    rxLogServiceProvider = rxLogService
    rxStreamServiceProvider = rxStreamService
    if let observations, observations !== self.observations {
      self.observations = observations
      packetCache = [:]
    }
  }

  func setRouteFilter(_ filter: RouteFilter) {
    guard routeFilter != filter else { return }
    routeFilter = filter
    rebuildFiltered()
  }

  func setDecryptFilter(_ filter: DecryptFilter) {
    guard decryptFilter != filter else { return }
    decryptFilter = filter
    rebuildFiltered()
  }

  func setTypeFilter(_ filter: TypeFilter) {
    guard typeFilter != filter else { return }
    typeFilter = filter
    rebuildFiltered()
  }

  func setSenderFilter(_ key: Data?) {
    guard senderFilter != key else { return }
    senderFilter = key
    rebuildFiltered()
  }

  /// The senders of the log's packets, busiest first, at most `senderOptionLimit`: what the
  /// From Node filter offers. Each by the key its packets resolve to, or the bytes they name it
  /// by when no node is known. The sender picked stays listed even when it has gone quiet.
  var senderOptions: [SenderOption] {
    var counts: [Data: (name: String, count: Int)] = [:]
    for entry in entries {
      guard let sender = senderKeyAndName(for: entry) else { continue }
      counts[sender.key, default: (sender.name, 0)].count += 1
    }
    var options = counts.map { SenderOption(key: $0.key, name: $0.value.name, count: $0.value.count) }
      .sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    if options.count > Self.senderOptionLimit {
      let picked = options.first { $0.key == senderFilter }
      options = Array(options.prefix(Self.senderOptionLimit))
      if let picked, !options.contains(picked) { options.append(picked) }
    }
    return options
  }

  /// The key the From Node filter knows `entry`'s sender by, and its name; nil for a packet
  /// that names no sender.
  private func senderKeyAndName(for entry: RxLogEntryDTO) -> (key: Data, name: String)? {
    guard let sender = packetNodes(for: entry).sender else {
      guard let name = entry.fromContactName, !name.isEmpty else { return nil }
      return (Data(name.utf8), name)
    }
    if sender.isRadio { return nil }
    let key = sender.key ?? sender.hash
    guard !key.isEmpty || sender.channelName != nil else { return nil }
    let name = sender.displayName ?? sender.hash.uppercaseHexString()
    return (key.isEmpty ? Data(name.utf8) : key, name)
  }

  /// Whether `entry` matches the search: its sender or recipient's name, its message, its hash,
  /// or its type's name, case-insensitively.
  private func matchesSearch(_ entry: RxLogEntryDTO) -> Bool {
    let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    if entry.packetHash.localizedCaseInsensitiveContains(needle) { return true }
    if entry.payloadType.displayName.localizedCaseInsensitiveContains(needle) { return true }
    if let text = entry.decodedText, text.localizedCaseInsensitiveContains(needle) { return true }
    let nodes = packetNodes(for: entry)
    if let sender = nodes.sender, let name = sender.displayName ?? sender.channelName,
       name.localizedCaseInsensitiveContains(needle) { return true }
    if let from = entry.fromContactName, from.localizedCaseInsensitiveContains(needle) { return true }
    if let to = entry.toContactName, to.localizedCaseInsensitiveContains(needle) { return true }
    if let recipient = nodes.recipient?.entry, let name = recipient.name ?? recipient.advertisedName,
       name.localizedCaseInsensitiveContains(needle) { return true }
    return nodes.hops.contains { ($0.displayName ?? "").localizedCaseInsensitiveContains(needle) }
  }

  /// The entries the list shows, newest first: every filtered reception, or only the newest
  /// reception of each packet when grouping duplicates.
  func displayEntries(groupingDuplicates: Bool) -> ReversedCollection<ArraySlice<RxLogEntryDTO>> {
    (groupingDuplicates ? dedupedEntries : filteredEntries).reversed()
  }

  /// Whether `entry` passes the route filter, which the list and the map share.
  private func matchesRouteFilter(_ entry: RxLogEntryDTO) -> Bool {
    switch routeFilter {
    case .all: true
    case .floodOnly: entry.isFlood
    case .directOnly: !entry.isFlood
    }
  }

  /// Whether `entry` passes the current filter settings.
  private func matchesFilters(_ entry: RxLogEntryDTO) -> Bool {
    guard matchesRouteFilter(entry) else { return false }
    guard typeFilter.includes(entry.payloadType) else { return false }

    // Decrypt filter
    switch decryptFilter {
    case .all: break
    case .decrypted:
      guard entry.decryptStatus == .success else { return false }
    case .failed:
      guard entry.decryptStatus == .hmacFailed
        || entry.decryptStatus == .decryptFailed
        || entry.decryptStatus == .noMatchingKey
        || entry.decryptStatus == .dmNoMatchingKey else { return false }
    }

    if let senderFilter {
      guard senderKeyAndName(for: entry)?.key == senderFilter else { return false }
    }
    return matchesSearch(entry)
  }

  /// Subscribe to the live RxLogService for updates while view is visible.
  func subscribe() async {
    // Cancel any existing stream task so a re-subscribe (a `.task(id:)` re-fire
    // against the same service) can't leave two streams appending each packet twice.
    unsubscribe()

    guard let service = rxLogService else { return }

    // If service changed, reset state
    if subscribedService !== service {
      removeAllEntries()
    }
    subscribedService = service

    // The store hands entries back newest first.
    load(await service.loadExistingEntries().reversed())
    hasLoadedHistory = true

    streamTask = Task {
      for await entry in service.entryStream() {
        guard !Task.isCancelled else { break }
        appendEntry(entry)
      }
    }

    // On stock firmware the radio's packet counter is read while the log is open, so the line
    // can say how many packets never reached the app.
    watchDelivery(on: rxStreamServiceProvider())

    // Polled: the counters change on the services' actors without an event of their own.
    deliveryTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshDeliveryLine()
        try? await Task.sleep(for: Self.deliveryRefreshInterval)
        guard self != nil else { return }
      }
    }
  }

  /// Stop listening to updates.
  func unsubscribe() {
    streamTask?.cancel()
    streamTask = nil
    deliveryTask?.cancel()
    deliveryTask = nil
    watchDelivery(on: nil)
  }

  // MARK: - Delivery

  /// Has `service` keep stock delivery measured while the log is open, and tells the one watched
  /// before to stop. Each change waits for the one before it, so a quick close and reopen leaves
  /// the open log's service watching.
  private func watchDelivery(on service: RxStreamService?) {
    guard service !== watchedStreamService else { return }
    let previous = watchedStreamService
    watchedStreamService = service
    let prior = watchTask
    watchTask = Task {
      await prior?.value
      await previous?.setDeliveryWatching(false)
      await service?.setDeliveryWatching(true)
    }
  }

  /// Reads this connection's delivery again. Leaves no line while disconnected.
  func refreshDeliveryLine() async {
    guard let service = rxStreamServiceProvider() else {
      deliveryLine = nil
      longPacketNote = nil
      deliveryNeedsAttention = false
      return
    }
    let stats = await service.deliveryStats()
    guard !Task.isCancelled else { return }
    deliveryLine = Self.deliveryLine(for: stats)
    longPacketNote = Self.longPacketNote(for: stats)
    deliveryNeedsAttention = Self.deliveryNeedsAttention(for: stats)
  }

  /// Whether the delivery line reports a real problem: packets the radio heard that never reached
  /// the app (lost at the radio, unrecovered, or dropped on the way), or a Cairn build whose
  /// packet recovery is missing or didn't start. All received, or not yet measured, is no problem.
  static func deliveryNeedsAttention(for stats: RxStreamDeliveryStats) -> Bool {
    let appDrops = stats.appDrops.values.reduce(0, +)
    switch stats.mode {
    case .idle, .probing:
      return false
    case .stock:
      if stats.stockReason == .recoveryUnsupported || stats.stockReason == .recoveryFailed { return true }
      guard let loss = stats.radioLoss, loss.heard > 0 else { return appDrops + stats.linkDrops > 0 }
      return loss.missed > 0 || appDrops > 0
    case .synced:
      return stats.radio.lostAtRadio + stats.radio.unrecovered > 0 || appDrops + stats.linkDrops > 0
    }
  }

  /// The delivery line for `stats`, nil until the radio has said whether it offers RX_SYNC.
  ///
  /// With RX_SYNC every packet is numbered, so the line can say all traffic was received, or
  /// how many packets were fetched again and how many the radio overwrote before sending them
  /// (with those FETCH couldn't bring). Packets the app itself dropped (its receive
  /// subscriptions lagging, or the BLE link's buffer full) are added after.
  ///
  /// Without RX_SYNC the line starts with why, for a Cairn radio whose recovery is missing or
  /// didn't start. Where the radio's packet counter measured delivery (companion v1.11+), it says
  /// how many packets the radio heard never reached the app, or that all traffic was received.
  /// Frames the BLE link's buffer refused are already among those, so only the app's own
  /// subscription drops are added. Unmeasured, it says packets can be skipped, and adds every
  /// drop the app counted.
  static func deliveryLine(for stats: RxStreamDeliveryStats) -> String? {
    let appDrops = stats.appDrops.values.reduce(0, +)
    switch stats.mode {
    case .idle, .probing:
      return nil
    case .stock:
      var parts: [String] = []
      switch stats.stockReason {
      case .recoveryUnsupported?:
        parts.append(L10n.Tools.Tools.RxLog.Delivery.recoveryUnsupported)
      case .recoveryFailed?:
        parts.append(L10n.Tools.Tools.RxLog.Delivery.recoveryFailed)
      case .otherFirmware?, nil:
        break
      }
      // Readings that counted no packet yet say nothing about loss.
      if let loss = stats.radioLoss, loss.heard > 0 {
        if loss.missed > 0 {
          parts.append(L10n.Tools.Tools.RxLog.Delivery.radioMissed(loss.missed, loss.heard))
        }
        if appDrops > 0 {
          parts.append(L10n.Tools.Tools.RxLog.Delivery.appDropped(appDrops))
        }
        if loss.missed == 0, appDrops == 0 {
          parts.append(L10n.Tools.Tools.RxLog.Delivery.allReceived)
        }
      } else {
        parts.append(L10n.Tools.Tools.RxLog.Delivery.stockUnmeasured)
        let dropped = appDrops + stats.linkDrops
        if dropped > 0 {
          parts.append(L10n.Tools.Tools.RxLog.Delivery.appDropped(dropped))
        }
      }
      return parts.joined(separator: " · ")
    case .synced:
      let recovered = stats.radio.recovered
      let lost = stats.radio.lostAtRadio + stats.radio.unrecovered
      let appDropped = appDrops + stats.linkDrops
      var parts: [String] = []
      if recovered > 0 || lost > 0 {
        parts.append(L10n.Tools.Tools.RxLog.Delivery.recoveredLost(recovered, lost))
      }
      if appDropped > 0 {
        parts.append(L10n.Tools.Tools.RxLog.Delivery.appDropped(appDropped))
      }
      return parts.isEmpty ? L10n.Tools.Tools.RxLog.Delivery.allReceived : parts.joined(separator: " · ")
    }
  }

  /// The long-packet note for `stats`: without RX_SYNC the radio never passes on a received packet
  /// longer than its frame allows (169 bytes before companion v1.16, 173 from it). Nil in any
  /// other mode.
  static func longPacketNote(for stats: RxStreamDeliveryStats) -> String? {
    guard stats.mode == .stock, let limit = stats.forwardLimit else { return nil }
    return L10n.Tools.Tools.RxLog.Delivery.longPackets(limit)
  }

  /// Clear all log entries.
  func clearLog() async {
    await rxLogService?.clearEntries()
    removeAllEntries()
  }

  // MARK: - Incremental Updates

  /// Replaces the log with `chronological` (oldest first), keeping the newest `entryCap`.
  func load(_ chronological: some Sequence<RxLogEntryDTO>) {
    entries = ArraySlice(Array(chronological).suffix(Self.entryCap))
    rebuildGroupCounts()
    rebuildFiltered()
  }

  /// Adds the newest entry, then drops the oldest past the cap, adjusting the filtered and
  /// grouped lists in place rather than rebuilding them.
  func appendEntry(_ entry: RxLogEntryDTO) {
    entries.append(entry)
    groupCounts[entry.packetHash, default: 0] += 1
    if matchesRouteFilter(entry) {
      mapEntries.append(entry)
    }
    if matchesFilters(entry) {
      filteredEntries.append(entry)
      // The newest reception now stands for the packet. Duplicates arrive close together,
      // so the one it replaces is found near the end.
      if let previous = dedupedEntries.lastIndex(where: { $0.packetHash == entry.packetHash }) {
        dedupedEntries.remove(at: previous)
      }
      dedupedEntries.append(entry)
    }

    if entries.count > Self.entryCap {
      let removed = entries.removeFirst()
      groupCounts[removed.packetHash, default: 1] -= 1
      if groupCounts[removed.packetHash] == 0 {
        groupCounts.removeValue(forKey: removed.packetHash)
      }
      // The oldest entry can only lead any list.
      if mapEntries.first?.id == removed.id {
        mapEntries.removeFirst()
      }
      if filteredEntries.first?.id == removed.id {
        filteredEntries.removeFirst()
      }
      if dedupedEntries.first?.id == removed.id {
        dedupedEntries.removeFirst()
      }
    }
  }

  private func removeAllEntries() {
    entries.removeAll()
    mapEntries.removeAll()
    filteredEntries.removeAll()
    dedupedEntries.removeAll()
    groupCounts.removeAll()
  }

  private func rebuildGroupCounts() {
    groupCounts = Dictionary(grouping: entries, by: \.packetHash)
      .mapValues(\.count)
  }

  private func rebuildFiltered() {
    let routed = entries.filter(matchesRouteFilter)
    // Unchanged by a decrypt filter change, so the map isn't handed a new set for nothing.
    if routed.map(\.id) != mapEntries.map(\.id) {
      mapEntries = routed[...]
    }
    filteredEntries = routed.filter(matchesFilters)[...]
    // Walk newest first so the first reception seen of each packet is its newest.
    var seen = Set<String>()
    var newestFirst: [RxLogEntryDTO] = []
    for entry in filteredEntries.reversed() where seen.insert(entry.packetHash).inserted {
      newestFirst.append(entry)
    }
    dedupedEntries = ArraySlice(newestFirst.reversed())
  }

  // MARK: - Node Resolution

  /// Every node `entry` names (sender, hops, recipient), resolved against what this radio observed
  /// on the channel the entry was received on, with what this radio sent lately settling its
  /// sender: exactly what the Traffic map draws. Kept per entry until either changes, as rows are
  /// drawn again and again.
  func packetNodes(for entry: RxLogEntryDTO) -> PacketNodes {
    let version = (observations: observations.version, sent: sentLog.version)
    if version != packetCacheVersion {
      packetCache = [:]
      packetCacheVersion = version
    }
    if let cached = packetCache[entry.id] { return cached }
    let nodes = TrafficRouteResolver.packetNodes(for: entry, in: observations.index(for: entry), sent: sentLog.snapshot)
    packetCache[entry.id] = nodes
    return nodes
  }

  /// The send `entry` echoes or answers, and how sure the match is; nil when nothing this radio
  /// sent explains it.
  func echo(for entry: RxLogEntryDTO) -> (send: OwnTransmission, match: EchoMatch)? {
    let sent = sentLog.snapshot
    guard let match = sent.echo(of: entry, selfKey: observations.index(for: entry).selfKey),
          let send = sent.send(id: match.sendID) else { return nil }
    return (send, match)
  }

  #if DEBUG
    /// A minute of made-up packets for screenshot runs: the kinds in turn, one with a long route.
    func addDemoPackets(radioID: UUID) {
      let kinds: [PayloadType] = [.advert, .textMessage, .groupText, .ack, .trace, .path]
      for index in 0..<24 {
        let path: [UInt8] = index == 20
          ? [0x1E, 0x0A, 0x14, 0x7F, 0x28, 0xC4, 0x32, 0x88, 0x3C, 0xB2, 0x50, 0xE7]
          : Array([0x1E, 0x0A, 0x14].prefix(index % 4))
        let parsed = ParsedRxLogData(
          snr: Double(index % 12) - 2,
          rssi: -60 - index,
          rawPayload: Data(repeating: UInt8(index), count: 24),
          routeType: .flood,
          payloadType: kinds[index % kinds.count],
          payloadVersion: 0,
          payloadTypeBits: 0,
          transportCode: nil,
          pathLength: UInt8(path.count),
          pathNodes: path,
          packetPayload: Data(repeating: UInt8(index), count: 16)
        )
        appendEntry(RxLogEntryDTO(radioID: radioID, receivedAt: .now.addingTimeInterval(Double(index - 24) * 2.5), from: parsed))
      }
    }
  #endif
}
