import Foundation

public extension MeshCoreSession {
  // MARK: - Cairn trip logs (firmware's examples/companion_radio/ui-l2/net/TRIP_SYNC.md)

  /// The radio's trip recorder: whether it is recording, and whether it could (card, GPS).
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on firmware
  ///   without trip logs (no card slot, or older); ``MeshCoreError/timeout`` if no reply arrives.
  func cairnTripState(timeout: TimeInterval? = nil) async throws -> CairnTripState {
    let (_, state) = try await tripStateExchange(PacketBuilder.cairnTripState(), op: .state, timeout: timeout)
    return state
  }

  /// Starts recording a trip on the radio. A refused start returns its reason in the status (no card,
  /// GPS off, clock not set); the state is the radio's either way.
  func startCairnTrip(timeout: TimeInterval? = nil) async throws -> (CairnTripStatus, CairnTripState) {
    try await tripStateExchange(PacketBuilder.cairnTripStart(), op: .start, timeout: timeout)
  }

  /// Stops the radio's recording; the log stays on its card.
  func stopCairnTrip(timeout: TimeInterval? = nil) async throws -> (CairnTripStatus, CairnTripState) {
    try await tripStateExchange(PacketBuilder.cairnTripStop(), op: .stop, timeout: timeout)
  }

  /// Every log on the radio's card, newest first (pages of 3, the first re-reading the card).
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` (unsupported, or the card's status as
  ///   ``CairnTripError``), ``MeshCoreError/timeout``.
  func listCairnTrips(timeout: TimeInterval? = nil) async throws -> [CairnTripLogEntry] {
    var entries: [CairnTripLogEntry] = []
    var from = 0
    while true {
      let request = PacketBuilder.cairnTripList(from: UInt16(clamping: from))
      let (status, total, page) = try await tripExchange(request, timeout: timeout) { reply in
        if case let .list(status, total, _, entries) = reply { return (status, total, entries) }
        return nil
      }
      guard status == .ok else { throw CairnTripError(status: status) }
      entries += page
      from += page.count
      if page.isEmpty || from >= total { break }
    }
    return entries
  }

  /// One page of a log's points from `from` on (at most 9), and the log's point count now.
  func fetchCairnTripPoints(name: String, from: Int, timeout: TimeInterval? = nil) async throws
    -> (total: Int, points: [CairnTripPoint]) {
    let request = PacketBuilder.cairnTripPoints(name: name, from: UInt32(clamping: from))
    let (status, total, points) = try await tripExchange(request, timeout: timeout) { reply in
      if case let .points(status, total, _, points) = reply { return (status, total, points) }
      return nil
    }
    guard status == .ok else { throw CairnTripError(status: status) }
    return (total, points)
  }

  /// Deletes a log from the radio's card. The running one is refused (``CairnTripStatus/recording``).
  func deleteCairnTrip(name: String, timeout: TimeInterval? = nil) async throws {
    let status = try await tripExchange(PacketBuilder.cairnTripDelete(name: name), timeout: timeout) { reply in
      if case let .deleted(status) = reply { return status }
      return nil
    }
    guard status == .ok || status == .notFound else { throw CairnTripError(status: status) }
  }

  private func tripStateExchange(_ data: Data, op: CairnTripOp, timeout: TimeInterval?) async throws
    -> (CairnTripStatus, CairnTripState) {
    try await tripExchange(data, timeout: timeout) { reply in
      if case let .state(replyOp, status, state) = reply, replyOp == op { return (status, state) }
      return nil
    }
  }

  private func tripExchange<T: Sendable>(
    _ data: Data,
    timeout: TimeInterval?,
    match: @escaping @Sendable (CairnTripReply) -> T?
  ) async throws -> T {
    try await sendAndMatch(data, timeout: timeout) { event in
      switch event {
      case let .cairnTripReply(reply):
        if let value = match(reply) { return .success(value) }
        return .ignore
      case let .error(code):
        return .failure(.deviceError(code: code ?? 0))
      default:
        return .ignore
      }
    }
  }
}

/// A trip-log request the radio answered with a status other than OK.
public struct CairnTripError: Error, Sendable, Equatable {
  public let status: CairnTripStatus
  public init(status: CairnTripStatus) { self.status = status }
}
