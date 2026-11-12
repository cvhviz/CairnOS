import Foundation
import MeshCore
import os

/// Holds what this radio sent lately: every transmitting command the session writes
/// (``MeshCoreSessionProtocol/transmissions()``) with the radio's answer to it, the messages the
/// radio's own UI reports sending, and the path discoveries it passes on. The Traffic map, the
/// RX Log list and Scan for Nodes' "hears you" all read their echoes from here
/// (``OwnTransmissionMatcher``), so they agree on which packets were ours.
///
/// In memory only. The ring outlives a reconnect of the same radio (``start(radioID:)`` with the
/// same id keeps it) and is emptied when another radio connects.
public actor OwnTransmissionService {
  /// Enough for a burst of sends and the requests around them; the oldest give way.
  public static let capacity = 256
  /// Path discovery answers kept for drawing a reply's route out and back.
  public static let discoveryCapacity = 8

  private let session: any MeshCoreSessionProtocol
  private let now: @Sendable () -> Date
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "OwnTransmissionService")

  private var radioID: UUID?
  private var sends: [OwnTransmission] = []
  private var discoveries: [OwnPathDiscovery] = []
  private var nextID: UInt64 = 1
  /// The session's write ids of the current subscription, to this service's send ids. The
  /// session counts its writes from the start again on each connection.
  private var sendIDByWrite: [UInt64: UInt64] = [:]
  private var listenTask: Task<Void, Never>?
  /// Bumped on every start and stop, so a stream from an earlier subscription is ignored.
  private var generation = 0

  private nonisolated let snapshots = LatestValueBroadcaster<[OwnTransmission]>(initial: [])
  private nonisolated let discoveryBroadcaster = EventBroadcaster<OwnPathDiscovery>()

  public init(session: any MeshCoreSessionProtocol, now: @escaping @Sendable () -> Date = { Date() }) {
    self.session = session
    self.now = now
  }

  // MARK: - Lifecycle

  /// Starts recording what `radioID` sends. Another radio than the last starts an empty ring;
  /// the same radio keeps what it sent before. The subscription is in place when this returns.
  public func start(radioID: UUID) async {
    listenTask?.cancel()
    listenTask = nil
    generation += 1
    let current = generation
    abandonUnanswered()
    if self.radioID != radioID {
      self.radioID = radioID
      sends = []
      discoveries = []
      publish()
    }
    let stream = await session.transmissions()
    // A later start or a stop while subscribing owns the service now.
    guard current == generation else { return }
    listenTask = Task { [weak self] in
      for await event in stream {
        guard let self, !Task.isCancelled else { return }
        await self.handle(event, generation: current)
      }
      // The session ended the stream (it stopped): no answer is coming for what it still owed
      await self?.streamEnded(generation: current)
    }
  }

  /// Stops listening to the session; what was sent is kept for the next start, and a send still
  /// waiting for the radio's answer is marked unconfirmed.
  public func stop() {
    generation += 1
    listenTask?.cancel()
    listenTask = nil
    abandonUnanswered()
  }

  /// Ends every ``transmissions()`` and ``pathDiscoveryEvents()`` subscriber's loop, on teardown.
  public nonisolated func finishStreams() {
    snapshots.finish()
    discoveryBroadcaster.finish()
  }

  // MARK: - Reading

  /// What this radio sent lately, oldest first: the current list at once, then a new one on
  /// every change (a write, the radio's answer, a proven echo).
  public nonisolated func transmissions() -> AsyncStream<[OwnTransmission]> {
    snapshots.subscribe()
  }

  /// Every path discovery answer recorded after this call.
  public nonisolated func pathDiscoveryEvents() -> AsyncStream<OwnPathDiscovery> {
    discoveryBroadcaster.subscribe(bufferingPolicy: .bufferingNewest(Self.discoveryCapacity))
  }

  /// What this radio sent lately, oldest first.
  public var currentTransmissions: [OwnTransmission] { sends }

  /// The path discovery answers recorded lately, oldest first.
  public var pathDiscoveries: [OwnPathDiscovery] { discoveries }

  /// The send `entry` echoes or answers (``OwnTransmissionMatcher``). An exact match remembers the
  /// entry's packet hash on the send, so copies passed on by other repeaters match by hash.
  ///
  /// - Parameter selfKey: This radio's key; the session's `SELF_INFO` key when nil.
  public func match(_ entry: RxLogEntryDTO, selfKey: Data? = nil) async -> EchoMatch? {
    var key = selfKey
    if key == nil { key = await session.currentSelfInfo?.publicKey }
    guard let match = OwnTransmissionMatcher.match(entry, in: sends, selfKey: key) else { return nil }
    if match.confidence == .exact, let index = sends.firstIndex(where: { $0.id == match.sendID }),
       !sends[index].provenPacketHashes.contains(entry.packetHash) {
      sends[index].provenPacketHashes.insert(entry.packetHash)
      publish()
    }
    return match
  }

  /// The packet hashes proven to be ours among the sends written in the last `interval`.
  public func recentOwnPacketHashes(within interval: TimeInterval = OwnTransmissionMatcher.echoWindow) -> Set<String> {
    let cutoff = now().addingTimeInterval(-interval)
    return sends.reduce(into: Set<String>()) { hashes, send in
      if send.writtenAt >= cutoff { hashes.formUnion(send.provenPacketHashes) }
    }
  }

  // MARK: - Recording

  /// A message sent from the radio's own UI (Cairn 0xC2/0xC3), which the app didn't write.
  /// Returns the send recorded; nil for a delivery update.
  @discardableResult
  public func record(radioSent message: RadioSentMessage, at date: Date? = nil) -> OwnTransmission? {
    guard let send = OwnTransmission(radioSent: message, id: nextID, at: date ?? now()) else { return nil }
    nextID &+= 1
    append(send)
    return send
  }

  /// A path discovery's answer (0x8D): the route out and back, for the reply's laser.
  public func recordDiscovery(_ discovery: OwnPathDiscovery) {
    discoveries.append(discovery)
    if discoveries.count > Self.discoveryCapacity {
      discoveries.removeFirst(discoveries.count - Self.discoveryCapacity)
    }
    discoveryBroadcaster.yield(discovery)
  }

  // MARK: - Session events

  private func handle(_ event: TransmissionEvent, generation current: Int) {
    guard current == generation else { return }
    switch event {
    case let .written(writeID, command, at):
      guard let send = OwnTransmission.parse(command: command, id: nextID, at: at) else { return }
      nextID &+= 1
      sendIDByWrite[writeID] = send.id
      append(send)
    case let .answered(writeID, outcome):
      guard let sendID = sendIDByWrite.removeValue(forKey: writeID),
            let index = sends.firstIndex(where: { $0.id == sendID }) else { return }
      sends[index].apply(outcome)
      if case let .rejected(code) = outcome {
        logger.debug("Radio refused send \(sendID) (code \(code.map(String.init) ?? "none"))")
      }
      publish()
    }
  }

  private func streamEnded(generation current: Int) {
    guard current == generation else { return }
    abandonUnanswered()
  }

  /// Marks every send of the current subscription the radio hasn't answered as unconfirmed: the
  /// session stopped (or a new one began, counting its writes afresh), so its answer is never
  /// coming, and the send must not stay pending.
  private func abandonUnanswered() {
    let unanswered = Set(sendIDByWrite.values)
    sendIDByWrite = [:]
    var changed = false
    for index in sends.indices where unanswered.contains(sends[index].id) && sends[index].outcome == nil {
      sends[index].apply(.unconfirmed)
      changed = true
    }
    if changed {
      publish()
    }
  }

  private func append(_ send: OwnTransmission) {
    sends.append(send)
    if sends.count > Self.capacity {
      let dropped = sends.prefix(sends.count - Self.capacity).map(\.id)
      sends.removeFirst(sends.count - Self.capacity)
      let droppedIDs = Set(dropped)
      sendIDByWrite = sendIDByWrite.filter { !droppedIDs.contains($0.value) }
    }
    publish()
  }

  private func publish() {
    snapshots.yield(sends)
  }
}

/// Multicast of a value that changes: each subscriber gets the current value at once, then every
/// later one. A stalled subscriber keeps only the newest.
final class LatestValueBroadcaster<Value: Sendable>: Sendable {
  private struct State {
    var latest: Value
    var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    var isFinished = false
  }

  private let state: OSAllocatedUnfairLock<State>

  init(initial: Value) {
    state = OSAllocatedUnfairLock(initialState: State(latest: initial))
  }

  func subscribe() -> AsyncStream<Value> {
    let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    // Registering and yielding the current value under one lock keeps a concurrent yield from
    // reaching the subscriber before the value it replaces.
    let isFinished = state.withLock { locked -> Bool in
      guard !locked.isFinished else { return true }
      locked.continuations[id] = continuation
      continuation.yield(locked.latest)
      return false
    }
    if isFinished {
      continuation.finish()
    } else {
      continuation.onTermination = { [state] _ in
        state.withLock { _ = $0.continuations.removeValue(forKey: id) }
      }
    }
    return stream
  }

  func yield(_ value: Value) {
    state.withLock { locked in
      locked.latest = value
      for continuation in locked.continuations.values {
        continuation.yield(value)
      }
    }
  }

  func finish() {
    let continuations = state.withLock { locked -> [AsyncStream<Value>.Continuation] in
      locked.isFinished = true
      let all = Array(locked.continuations.values)
      locked.continuations.removeAll()
      return all
    }
    for continuation in continuations {
      continuation.finish()
    }
  }
}
