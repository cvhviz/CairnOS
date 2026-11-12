import CairnServices
import Foundation
import MeshCore

// What this radio sent lately, as the Traffic maps and the RX Log list read it: a mirror of
// `OwnTransmissionService`, which records every transmitting command the session writes, the
// radio's answer to each, and what the radio's own UI reports sending. The radio reports nothing
// it transmits (its RX log is receive-only), so these are all there is to start a send's pulse at
// this radio and to recognise a repeater's echo of it (`OwnTransmissionMatcher`).

/// A repeater's neighbour list as it reached the app: each neighbour's signal as the repeater
/// heard it, when, and whether it was heard since the list was last read (a fresh hearing, so
/// worth a laser; the rest only refresh their link's signal).
struct TrafficNeighbourReport {
  struct Neighbour: Equatable {
    let prefix: Data
    let snr: Double
    let heardAt: Date
    let isFresh: Bool
  }

  /// The repeater's key, as much of it as is known.
  let repeater: Data
  let neighbours: [Neighbour]
  let at: Date
}

/// What this radio sent lately, as the route resolver reads it.
struct TrafficSentPackets {
  /// Oldest first, with the radio's answer to each.
  var sends: [OwnTransmission] = []
  /// Traces this app sent (Trace Path, ping), which start at this radio. Every trace's command
  /// carries its tag too.
  var traceTags: Set<UInt32> = []
  var discoveries: [OwnPathDiscovery] = []
  /// Node discoveries a repeater sent when we asked it to scan for neighbours, by tag: the key
  /// prefix of the repeater, so the answers to it can be drawn to it.
  var foreignDiscoveries: [UInt32: Data] = [:]

  static let none = TrafficSentPackets()

  /// The send `entry` echoes or answers, by the rules the RX Log list, the Traffic map and Scan
  /// for Nodes' "hears you" share. A send the radio refused never matches.
  func echo(of entry: RxLogEntryDTO, selfKey: Data?) -> EchoMatch? {
    OwnTransmissionMatcher.match(entry, in: sends, selfKey: selfKey)
  }

  func send(id: UInt64) -> OwnTransmission? {
    sends.last { $0.id == id }
  }

  /// The sends an entry heard at `date` may answer, newest first: none the radio refused.
  func sends(before date: Date) -> some Sequence<OwnTransmission> {
    sends.reversed().lazy.filter {
      !$0.isRejected
        && date.timeIntervalSince($0.writtenAt) >= -OwnTransmissionMatcher.earlyTolerance
        && date.timeIntervalSince($0.writtenAt) <= OwnTransmissionMatcher.echoWindow
    }
  }
}

/// Mirrors what this radio sent lately (`OwnTransmissionService.transmissions()`) for the Traffic
/// maps and the RX Log list, and tells the maps as each send is written and as the radio answers
/// it, so they can show it leaving this radio before any echo comes back, and withdraw it when
/// the radio refuses it.
@MainActor
final class TrafficSentLog {
  static let shared = TrafficSentLog()
  /// Path discovery answers and foreign discovery tags kept.
  static let discoveryCapacity = OwnTransmissionService.discoveryCapacity
  static let traceCapacity = 64

  private(set) var snapshot = TrafficSentPackets() {
    didSet { version &+= 1 }
  }
  /// Bumped with every change to `snapshot`, so what the RX Log list resolved against an older
  /// one is resolved again.
  private(set) var version = 0
  private var traceTags: [UInt32] = []
  private var foreignDiscoveryTags: [UInt32] = []
  /// When each repeater's neighbour (by both their prefixes) was last heard, as its lists said.
  private var neighbourHeard: [Data: Date] = [:]
  private var listeners: [WeakListener] = []
  /// The service mirrored, and the subscription to it.
  private weak var service: OwnTransmissionService?
  private var bindTask: Task<Void, Never>?
  /// The next snapshot is the service's list as it stood when bound: history, not new sends.
  private var awaitsFirstSnapshot = false
  /// Ids for sends recorded with no service bound (tests, previews).
  private var nextLocalID: UInt64 = 1

  /// How recently a neighbour must have been heard for its hearing to be news: polled every few
  /// seconds during a scan, one that answered it shows a few seconds old.
  static let neighbourFreshAge = 30
  /// How far one list's idea of when a neighbour was heard may drift from the next's (seconds
  /// rounding, and each reply's time on the mesh) and still be the same hearing.
  static let neighbourHeardTolerance: TimeInterval = 10

  private struct WeakListener {
    weak var model: TrafficMapModel?
  }

  init() {}

  // MARK: - The service

  /// Mirrors `service`: its sends as they are written and answered, and the path discoveries it
  /// records. Binding the service already mirrored does nothing.
  func bind(to service: OwnTransmissionService) {
    guard service !== self.service else { return }
    self.service = service
    bindTask?.cancel()
    awaitsFirstSnapshot = true
    let sends = service.transmissions()
    let discoveries = service.pathDiscoveryEvents()
    let sendsTask = Task { @MainActor [weak self] in
      for await list in sends {
        guard !Task.isCancelled else { return }
        self?.apply(list)
      }
    }
    let discoveriesTask = Task { @MainActor [weak self] in
      for await discovery in discoveries {
        guard !Task.isCancelled else { return }
        self?.applyDiscovery(discovery)
      }
    }
    bindTask = Task {
      await withTaskCancellationHandler {
        await sendsTask.value
        await discoveriesTask.value
      } onCancel: {
        sendsTask.cancel()
        discoveriesTask.cancel()
      }
    }
  }

  /// Takes the service's list of sends: a send not seen before launches its pulse, and a changed
  /// answer (accepted, refused, unanswered) updates it on the maps.
  func apply(_ sends: [OwnTransmission], now: Date = .now) {
    let previous = Dictionary(snapshot.sends.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let isHistory = awaitsFirstSnapshot
    awaitsFirstSnapshot = false
    snapshot.sends = sends
    for send in sends {
      if send.kind == .trace, let tag = send.tag, !traceTags.contains(tag) { addTraceTag(tag) }
      if let old = previous[send.id] {
        if old.outcome != send.outcome { notify { $0.applyOutcome(send, now: now) } }
      } else if !isHistory {
        notify { $0.launchSent(send, now: now) }
      }
    }
  }

  /// A message sent from the radio's own UI, which the app didn't write: its echoes and its ack
  /// start at this radio as the app's own do.
  func record(radioSent message: RadioSentMessage, at date: Date = .now) {
    if let service {
      Task { await service.record(radioSent: message, at: date) }
      return
    }
    guard let send = OwnTransmission(radioSent: message, id: nextLocalID, at: date) else { return }
    nextLocalID &+= 1
    apply(snapshot.sends + [send], now: date)
  }

  /// A path discovery's answer: the route out and back, for the reply's laser.
  func recordDiscovery(_ discovery: OwnPathDiscovery) {
    if let service {
      Task { await service.recordDiscovery(discovery) }
    } else {
      applyDiscovery(discovery)
    }
  }

  private func applyDiscovery(_ discovery: OwnPathDiscovery) {
    snapshot.discoveries.append(discovery)
    if snapshot.discoveries.count > Self.discoveryCapacity {
      snapshot.discoveries.removeFirst(snapshot.discoveries.count - Self.discoveryCapacity)
    }
    notify { $0.applyDiscovery(discovery, now: discovery.at) }
  }

  // MARK: - Neighbour scans

  /// A repeater's neighbour list: each neighbour heard since its last list (or heard for the
  /// first time) within `neighbourFreshAge` is marked fresh, so a scan polled every few seconds
  /// fires one laser per neighbour as it answers rather than one per poll.
  func recordNeighbours(repeater: Data, neighbours: [Neighbour], at date: Date = .now) {
    guard !repeater.isEmpty else { return }
    let repeaterPrefix = Data(repeater.prefix(6))
    let entries = neighbours.map { neighbour in
      let key = repeaterPrefix + neighbour.publicKeyPrefix
      let heardAt = date.addingTimeInterval(-TimeInterval(max(0, neighbour.secondsAgo)))
      let previous = neighbourHeard[key]
      let isFresh = neighbour.secondsAgo <= Self.neighbourFreshAge
        && previous.map { heardAt.timeIntervalSince($0) > Self.neighbourHeardTolerance } ?? true
      if previous.map({ heardAt > $0 }) ?? true { neighbourHeard[key] = heardAt }
      return TrafficNeighbourReport.Neighbour(prefix: neighbour.publicKeyPrefix, snr: neighbour.snr, heardAt: heardAt, isFresh: isFresh)
    }
    if neighbourHeard.count > Self.traceCapacity * 8 {
      neighbourHeard = neighbourHeard.filter { date.timeIntervalSince($0.value) < 3600 }
    }
    let report = TrafficNeighbourReport(repeater: repeater, neighbours: entries, at: date)
    notify { $0.applyNeighbours(report, now: date) }
  }

  /// A node discovery a repeater sent at our asking (`OwnTransmissionMatcher.discoverRequester`),
  /// so the answers to it, overheard here, are drawn to that repeater.
  func recordForeignDiscovery(tag: UInt32, repeater: Data) {
    if snapshot.foreignDiscoveries[tag] == nil { foreignDiscoveryTags.append(tag) }
    snapshot.foreignDiscoveries[tag] = repeater
    if foreignDiscoveryTags.count > 16 {
      for old in foreignDiscoveryTags.prefix(foreignDiscoveryTags.count - 16) {
        snapshot.foreignDiscoveries[old] = nil
      }
      foreignDiscoveryTags.removeFirst(foreignDiscoveryTags.count - 16)
    }
  }

  /// A trace sent with this tag (also read from its command; Trace Path and ping record theirs).
  func recordTrace(tag: UInt32) {
    guard !traceTags.contains(tag) else { return }
    addTraceTag(tag)
  }

  func addListener(_ model: TrafficMapModel) {
    listeners.removeAll { $0.model == nil || $0.model === model }
    listeners.append(WeakListener(model: model))
  }

  private func addTraceTag(_ tag: UInt32) {
    traceTags.append(tag)
    if traceTags.count > Self.traceCapacity { traceTags.removeFirst(traceTags.count - Self.traceCapacity) }
    snapshot.traceTags = Set(traceTags)
  }

  private func notify(_ body: (TrafficMapModel) -> Void) {
    listeners.removeAll { $0.model == nil }
    for listener in listeners {
      if let model = listener.model { body(model) }
    }
  }
}
