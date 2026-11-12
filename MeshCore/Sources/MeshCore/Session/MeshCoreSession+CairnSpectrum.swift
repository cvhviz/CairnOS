import Foundation

public extension MeshCoreSession {
  // MARK: - Cairn Spectrum (firmware's net/SPEC_SYNC.md)

  /// Reads a Cairn touch board's Spectrum readings over a window, without its columns or marks.
  ///
  /// Also the page's probe: an OK sets ``cairnSpectrumSupport`` to `true`, an UNAVAILABLE reply or
  /// `ERR_CODE_UNSUPPORTED_CMD` sets it to `false`.
  ///
  /// - Parameters:
  ///   - window: 0 = 10 s, 1 = 1 min, 2 = 10 min, 3 = 1 h.
  ///   - timeout: Optional timeout override in seconds.
  /// - Returns: The status, and the readings on OK.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without the feature; ``MeshCoreError/timeout`` if no reply arrives.
  func getCairnSpectrumStats(window: UInt8, timeout: TimeInterval? = nil) async throws -> CairnSpectrumStatsReply {
    let reply: CairnSpectrumStatsReply = try await spectrumRequest(
      PacketBuilder.cairnSpectrumStats(window: window), timeout: timeout
    ) { event in
      if case let .cairnSpectrumStats(reply) = event { return reply }
      return nil
    }
    noteSpectrumStatus(reply.status)
    return reply
  }

  /// Reads a Cairn touch board's 24 h noise-floor trend (Cairn's "NF 24h").
  ///
  /// - Parameter points: Points across the day, 1...160.
  /// - Returns: The status, and the trend on OK.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` or ``MeshCoreError/timeout``.
  func fetchCairnSpectrumTrend(points: UInt8 = 160) async throws -> CairnSpectrumTrendReply {
    let reply: CairnSpectrumTrendReply = try await spectrumRequest(
      PacketBuilder.cairnSpectrumTrend(points: points), timeout: nil
    ) { event in
      if case let .cairnSpectrumTrend(reply) = event { return reply }
      return nil
    }
    noteSpectrumStatus(reply.status)
    return reply
  }

  /// Fetches one Spectrum HISTORY: the reply, then the columns and marks the board pushes for it.
  ///
  /// The pushes are collected from before the request goes out, and only those carrying the
  /// reply's transfer id are kept (an earlier transfer's late frames and its aborted end are
  /// passed by). The fetch ends at the transfer's end, or after `inactivity` seconds without one
  /// of its frames, or `hardTimeout` seconds in all; then ``CairnSpectrumHistory/completed`` is
  /// `false` and the caller asks for everything again.
  ///
  /// A non-OK reply (BUSY, TOO_SOON, UNAVAILABLE) returns at once with no columns.
  ///
  /// - Parameters:
  ///   - request: The poll (``CairnSpectrumHistoryRequest``).
  ///   - inactivity: Seconds without a frame that end the fetch.
  ///   - hardTimeout: Seconds after which the fetch ends however it is going.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` (unsupported, malformed) or
  ///   ``MeshCoreError/timeout`` when the reply itself never comes.
  func fetchCairnSpectrumHistory(
    _ request: CairnSpectrumHistoryRequest,
    inactivity: TimeInterval = 2,
    hardTimeout: TimeInterval = 15
  ) async throws -> CairnSpectrumHistory {
    let sessionDispatcher = dispatcher
    let sessionClock = clock
    let (subscriptionID, events) = await dispatcher.subscribeTracked { event in
      switch event {
      case .cairnSpectrumColumns, .cairnSpectrumMarks, .cairnSpectrumEnd: true
      default: false
      }
    }
    do {
      // stamped as the reply is matched, not when the transfer behind it ends: the radio's
      // nowMs is the reply's moment, and a long transfer would otherwise age every mark
      let (reply, receivedAt): (CairnSpectrumHistoryReply, Date) = try await spectrumRequest(
        PacketBuilder.cairnSpectrumHistory(request), timeout: nil
      ) { event in
        guard case let .cairnSpectrumHistoryReply(reply) = event else { return nil }
        // only this request's reply: a cancelled poll's late answer (another window or width,
        // after a switch) echoes its own window and column count and is left for nobody.
        // A short non-OK reply carries neither and is taken as it is.
        if reply.status == .ok,
           reply.stats?.window != request.window || reply.columns != request.columns {
          return nil
        }
        return (reply, Date())
      }
      noteSpectrumStatus(reply.status)
      guard reply.status == .ok else {
        await sessionDispatcher.finishSubscription(id: subscriptionID)
        return CairnSpectrumHistory(reply: reply, columns: [], marks: [], completed: false, receivedAt: receivedAt)
      }
      let tracker = StreamProgressTracker()
      let collected: CairnSpectrumHistory? = await withTaskGroup(of: CairnSpectrumHistory?.self) { group in
        group.addTask {
          var assembly = SpectrumAssembly(reply: reply, receivedAt: receivedAt)
          for await event in events {
            switch assembly.take(event) {
            case .ignored:
              continue
            case .progress:
              await tracker.markProgress()
            case .ended:
              return assembly.result(ended: true)
            }
          }
          return assembly.result(ended: false)
        }
        group.addTask {
          while true {
            if Task.isCancelled { return nil }
            let before = await tracker.snapshot()
            try? await sessionClock.sleep(for: .seconds(inactivity))
            if Task.isCancelled { return nil }
            let after = await tracker.snapshot()
            if after.generation == before.generation || after.elapsed >= hardTimeout {
              // ends the stream: the collector returns what it has
              await sessionDispatcher.finishSubscription(id: subscriptionID)
              return nil
            }
          }
        }
        var out: CairnSpectrumHistory?
        for await result in group {
          if let result {
            out = result
            group.cancelAll()
            break
          }
        }
        return out
      }
      await sessionDispatcher.finishSubscription(id: subscriptionID)
      return collected
        ?? CairnSpectrumHistory(reply: reply, columns: [], marks: [], completed: false, receivedAt: receivedAt)
    } catch {
      await sessionDispatcher.finishSubscription(id: subscriptionID)
      throw error
    }
  }
}

extension MeshCoreSession {
  /// Sends a spectrum request and waits for its reply; `ERR_CODE_UNSUPPORTED_CMD` marks the radio
  /// as without the feature.
  private func spectrumRequest<T: Sendable>(
    _ data: Data,
    timeout: TimeInterval?,
    reply: @escaping @Sendable (MeshEvent) -> T?
  ) async throws -> T {
    do {
      return try await sendAndMatch(data, timeout: timeout) { event in
        if let value = reply(event) { return .success(value) }
        if case let .error(code) = event { return .failure(MeshCoreError.deviceError(code: code ?? 0)) }
        return .ignore
      }
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      cairnSpectrumSupport = false
      throw MeshCoreError.deviceError(code: code)
    }
  }

  private func noteSpectrumStatus(_ status: CairnSpectrumStatus) {
    switch status {
    case .ok: cairnSpectrumSupport = true
    case .unavailable: cairnSpectrumSupport = false
    default: break
    }
  }
}

/// Collects one Spectrum HISTORY transfer's pushes into its columns and marks.
struct SpectrumAssembly {
  enum Step {
    case ignored
    case progress
    case ended
  }

  let reply: CairnSpectrumHistoryReply
  /// When the reply arrived.
  let receivedAt: Date
  private(set) var columns: [CairnSpectrumColumn?]
  private(set) var marks: [CairnSpectrumMark] = []
  private(set) var frames = 0
  private(set) var aborted = false

  init(reply: CairnSpectrumHistoryReply, receivedAt: Date = Date()) {
    self.reply = reply
    self.receivedAt = receivedAt
    columns = Array(repeating: nil, count: Int(reply.count))
  }

  mutating func take(_ event: MeshEvent) -> Step {
    switch event {
    case let .cairnSpectrumColumns(frame) where frame.xfer == reply.xfer:
      frames += 1
      // the frame's first slot is nowSlot - back; index 0 holds slot nowSlot - count + 1
      let start = Int(reply.count) - 1 - Int(frame.back)
      for (offset, column) in frame.columns.enumerated() {
        let index = start + offset
        if columns.indices.contains(index) { columns[index] = column }
      }
      return .progress
    case let .cairnSpectrumMarks(frame) where frame.xfer == reply.xfer:
      frames += 1
      marks.append(contentsOf: frame.marks)
      return .progress
    case let .cairnSpectrumEnd(end) where end.xfer == reply.xfer:
      aborted = end.aborted
      return .ended
    default:
      return .ignored
    }
  }

  func result(ended: Bool) -> CairnSpectrumHistory {
    let whole = ended && !aborted && frames == Int(reply.frames)
      && !columns.contains(where: { $0 == nil }) && marks.count == Int(reply.marks)
    return CairnSpectrumHistory(reply: reply, columns: columns, marks: marks, completed: whole, receivedAt: receivedAt)
  }
}
