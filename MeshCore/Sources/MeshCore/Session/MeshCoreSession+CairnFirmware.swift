import Foundation

public extension MeshCoreSession {
  // MARK: - Cairn Firmware Update

  /// Reads a Cairn touch board's build, Wi-Fi and Updater mode state.
  ///
  /// - Returns: The board's update status.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on firmware
  ///   that can't be updated from the app; ``MeshCoreError/timeout`` if no reply arrives.
  func getCairnFirmwareStatus() async throws -> CairnFirmwareStatus {
    try await sendAndMatch(PacketBuilder.cairnFirmware(.status)) { event in
      switch event {
      case let .cairnFirmwareStatus(status):
        .success(status)
      case let .error(code):
        .failure(MeshCoreError.deviceError(code: code ?? 0))
      default:
        .ignore
      }
    }
  }

  /// Asks the board to start Updater mode. On ``CairnFirmwareStartReply/asking`` the board shows its
  /// user a prompt, and the answer arrives as a push: wait for it with
  /// ``waitForCairnFirmwareStartResult(timeout:)``.
  ///
  /// - Returns: The board's immediate answer.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` or ``MeshCoreError/timeout``.
  func startCairnFirmwareUpdate() async throws -> CairnFirmwareStartReply {
    try await sendAndMatch(PacketBuilder.cairnFirmware(.start)) { event in
      switch event {
      case let .cairnFirmwareStartReply(reply):
        .success(reply)
      case let .error(code):
        .failure(MeshCoreError.deviceError(code: code ?? 0))
      default:
        .ignore
      }
    }
  }

  /// Withdraws a start the board is still asking about; its prompt closes and no push follows.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` or ``MeshCoreError/timeout``.
  func cancelCairnFirmwareUpdate() async throws {
    let _: Bool = try await sendAndMatch(PacketBuilder.cairnFirmware(.cancel)) { event in
      switch event {
      case .cairnFirmwareCancelled:
        .success(true)
      case let .error(code):
        .failure(MeshCoreError.deviceError(code: code ?? 0))
      default:
        .ignore
      }
    }
  }

  /// Waits for the board's answer to a start: its user allowed or declined it, or 60 s passed.
  ///
  /// Start waiting before sending the start when the answer could come quickly; the board's own
  /// prompt keeps this short of a race in practice.
  ///
  /// - Parameter timeout: How long to wait; the board answers within 60 s.
  /// - Returns: The answer, or `nil` on timeout or when the link went away.
  func waitForCairnFirmwareStartResult(timeout: TimeInterval = 70) async -> CairnFirmwareStartResult? {
    let event = await waitForEvent(filter: .cairnFirmwareStartResult, timeout: timeout)
    if case let .cairnFirmwareStartResult(result) = event {
      return result
    }
    return nil
  }

  /// Turns the echo of messages sent from the board's own UI on or off for this link and session.
  ///
  /// While on, the board pushes each message its user sends (``MeshEvent/radioSentMessage(_:)``,
  /// live) and queues them for ``getMessage()`` while no opted-in app is linked. Send it after
  /// every connect, before draining messages: the board forgets it when the link drops or on
  /// `APP_START`. Once on, ``sendAppStart()`` renews it after each later `APP_START`.
  ///
  /// - Parameters:
  ///   - on: `true` to opt in, `false` to opt out (which also drops the board's queued echoes).
  ///   - timeout: Optional timeout override in seconds.
  /// - Returns: The state in force and how many echo records the board has queued.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without the feature; ``MeshCoreError/timeout`` if no reply arrives.
  func setCairnSyncSent(on: Bool, timeout: TimeInterval? = nil) async throws -> CairnSyncSentState {
    do {
      let state: CairnSyncSentState = try await sendAndMatch(
        PacketBuilder.cairnFirmware(.syncSent, on: on), timeout: timeout
      ) { event in
        switch event {
        case let .cairnSyncSentState(state):
          .success(state)
        case let .error(code):
          .failure(MeshCoreError.deviceError(code: code ?? 0))
        default:
          .ignore
        }
      }
      // Remembered so sendAppStart() renews it: the board opts a link out on every APP_START.
      cairnSyncSentOptedIn = state.isOn
      return state
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      cairnSyncSentOptedIn = false
      throw MeshCoreError.deviceError(code: code)
    }
  }
}

public extension MeshCoreSession {
  // MARK: - Cairn Chat History

  /// Asks a Cairn touch board how much chat history it holds (firmware's `net/HIST_SYNC.md`).
  ///
  /// - Returns: The board's store id and how many records it holds (``CairnHistoryPageReply/total``).
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without the feature; ``MeshCoreError/timeout`` if no reply arrives.
  func queryCairnHistory() async throws -> CairnHistoryPageReply {
    try await sendAndMatch(PacketBuilder.cairnHistoryQuery()) { event in
      switch event {
      case let .cairnHistoryPageReply(reply):
        .success(reply)
      case let .error(code):
        .failure(MeshCoreError.deviceError(code: code ?? 0))
      default:
        .ignore
      }
    }
  }

  /// Fetches one page of a Cairn touch board's chat history: the records numbered past `sinceSeq`,
  /// oldest first, at most `max` walked.
  ///
  /// The pushes are collected from before the request goes out. A record split over two frames is
  /// joined by its `seq`; one whose second frame never comes is left out, so ``CairnHistoryPage/nextSince(after:)``
  /// asks for it again. The page ends with its ``CairnHistoryEnd``, or after `inactivity` seconds
  /// without a frame (the link went quiet: ``CairnHistoryPage/end`` is nil).
  ///
  /// - Parameters:
  ///   - sinceSeq: The last record this app has under the board's current store id (0 = start).
  ///   - max: Records the page walks, 1...32.
  ///   - inactivity: Seconds without a frame that end the page.
  /// - Returns: The reply (check ``CairnHistoryPageReply/status`` for BUSY and its store id), the
  ///   records and the end.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` (unsupported, malformed) or
  ///   ``MeshCoreError/timeout`` when the reply itself never comes.
  func fetchCairnHistoryPage(
    sinceSeq: UInt32, max: UInt8 = 16, inactivity: TimeInterval = 3
  ) async throws -> CairnHistoryPage {
    let sessionDispatcher = dispatcher
    let sessionClock = clock
    let (subscriptionID, events) = await dispatcher.subscribeTracked()
    do {
      let reply: CairnHistoryPageReply = try await sendAndMatch(
        PacketBuilder.cairnHistoryPage(sinceSeq: sinceSeq, max: max)
      ) { event in
        switch event {
        case let .cairnHistoryPageReply(reply):
          .success(reply)
        case let .error(code):
          .failure(MeshCoreError.deviceError(code: code ?? 0))
        default:
          .ignore
        }
      }
      guard reply.status == .ok, reply.page > 0 else {
        await sessionDispatcher.finishSubscription(id: subscriptionID)
        return CairnHistoryPage(reply: reply, records: [], end: nil)
      }
      let tracker = StreamProgressTracker()
      // a page is at most 32 records of two frames, one frame per ~60 ms: a minute is far past it
      let hardTimeout: TimeInterval = 60
      let collected: ([CairnHistoryRecord], CairnHistoryEnd?) = await withTaskGroup(
        of: ([CairnHistoryRecord], CairnHistoryEnd?)?.self
      ) { group in
        group.addTask {
          var records: [CairnHistoryRecord] = []
          var head: CairnHistoryRecord?   // a first frame waiting for its continuation
          for await event in events {
            switch event {
            case let .cairnHistoryRecord(frame):
              await tracker.markProgress()
              if frame.flags.contains(.continuation) {
                if let first = head, first.seq == frame.seq { records.append(first.appending(frame)) }
                head = nil
              } else {
                head = nil   // a head whose tail never came is dropped: asked for again
                if frame.flags.contains(.more) { head = frame } else { records.append(frame) }
              }
            case let .cairnHistoryEnd(end):
              return (records, end)
            default:
              continue
            }
          }
          return (records, nil)
        }
        group.addTask {
          while true {
            if Task.isCancelled { return nil }
            let before = await tracker.snapshot()
            try? await sessionClock.sleep(for: .seconds(inactivity))
            if Task.isCancelled { return nil }
            let after = await tracker.snapshot()
            if after.generation == before.generation || after.elapsed >= hardTimeout {
              await sessionDispatcher.finishSubscription(id: subscriptionID)
              return nil
            }
          }
        }
        var out: ([CairnHistoryRecord], CairnHistoryEnd?) = ([], nil)
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
      return CairnHistoryPage(reply: reply, records: collected.0, end: collected.1)
    } catch {
      await sessionDispatcher.finishSubscription(id: subscriptionID)
      throw error
    }
  }
}
