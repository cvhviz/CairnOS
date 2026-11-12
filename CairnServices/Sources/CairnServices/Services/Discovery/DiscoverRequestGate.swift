import Foundation

/// Decides whether a `NODE_DISCOVER_REQ` may go on air now. One instance lives for the whole
/// process (AppState owns it), so it survives service rebuilds and radio switches: the limit it
/// models lives in the repeaters, not in any one radio, and every requester shares it (Scan for
/// Nodes on the phone and in CarPlay, Wardrive, Region discovery).
///
/// Every repeater answers at most 4 discover requests per 120 s fixed window that opens on the
/// first request after the last one expired, shared by everyone in range and spent before the
/// request's filter is checked (`RateLimiter(4, 120)` in simple_repeater). The gate allows a
/// request only if, at send time:
/// - (a) our last request was at least 45 s ago;
/// - (b) at most 1 of ours is in the trailing 120 s;
/// - (c) at most 2 requests, ours plus others' we overheard, are in the trailing 120 s.
///
/// After the send, any sliding 120 s window holds at most 3 requests we know of, so whatever the
/// fixed window's phase, at least one token stays free for other people. A refusal never turns
/// into a retry: there is no retry API, the caller says when it's allowed again and the user
/// presses again.
public actor DiscoverRequestGate {
  /// Why a request has to wait.
  public enum Reason: Sendable, Equatable {
    /// Our last request was less than ``minimumSpacing`` ago.
    case spacing
    /// We already sent our share of the trailing window.
    case ownCap
    /// Others nearby scanned recently; ours would spend a token they may need.
    case othersScanning
  }

  public enum Decision: Sendable, Equatable {
    case allowed
    /// `until` is the earliest instant at which all three rules hold again.
    case coolingDown(until: Date, reason: Reason)
  }

  /// Rule (a): the least time between two of our requests.
  public static let minimumSpacing: TimeInterval = 45
  /// The repeaters' limiter window.
  public static let window: TimeInterval = 120
  /// Rule (b): the most of our requests the trailing window may already hold.
  public static let maximumOwnInWindow = 1
  /// Rule (c): the most requests, ours and overheard, the trailing window may already hold.
  public static let maximumKnownInWindow = 2
  /// An overheard request this close to one already noted is the same request: re-binding to a
  /// rebuilt service replays the requests of the last 120 s with the times they were first heard.
  static let overheardMergeTolerance: TimeInterval = 1

  private let now: @Sendable () -> Date

  /// One of our requests. `reserved` marks a slot that `request()` granted and `recordOwn(at:)`
  /// has not confirmed yet.
  private struct OwnRequest {
    var at: Date
    var reserved: Bool
  }

  /// Our requests in the trailing window, oldest first.
  private var own: [OwnRequest] = []
  /// Others' requests we overheard in the trailing window, oldest first.
  private var overheard: [Date] = []

  /// - Parameter now: The clock every rule is measured against; tests inject a fake one.
  public init(now: @escaping @Sendable () -> Date = { Date() }) {
    self.now = now
  }

  /// Asks to send one request now. When allowed, the slot is reserved at once, so a second caller
  /// that asks before the first one sends is refused instead of both going on air;
  /// ``recordOwn(at:)`` then stamps it with the time it was sent. A reservation that is never sent
  /// stays counted, which can only make the gate more cautious, unless the radio refused the
  /// request before air and ``releaseReservation()`` gives it back.
  public func request() -> Decision {
    let date = now()
    let decision = evaluate(at: date)
    if decision == .allowed {
      own.append(OwnRequest(at: date, reserved: true))
    }
    return decision
  }

  /// What ``request()`` would answer now, without reserving anything: for a countdown or a
  /// disabled button.
  public func status() -> Decision {
    evaluate(at: now())
  }

  /// Records one of our requests as sent at `date` (the gate's clock when `nil`), confirming the
  /// oldest outstanding reservation, or adding the request when there was none.
  public func recordOwn(at date: Date? = nil) {
    let date = date ?? now()
    if let index = own.firstIndex(where: \.reserved) {
      own[index] = OwnRequest(at: date, reserved: false)
    } else {
      own.append(OwnRequest(at: date, reserved: false))
    }
    own.sort { $0.at < $1.at }
  }

  /// Gives back the oldest outstanding reservation, for a request the radio refused before it
  /// went on air: official companion firmware before v1.10 answers the discover command with
  /// `ERR_CODE_UNSUPPORTED_CMD` and sends nothing, so no repeater spent a token on it. Does
  /// nothing when no reservation is outstanding.
  public func releaseReservation() {
    guard let index = own.firstIndex(where: \.reserved) else { return }
    own.remove(at: index)
  }

  /// Records a discover request we heard someone else send at `date`.
  public func noteOverheard(at date: Date) {
    guard now().timeIntervalSince(date) < Self.window else { return }
    guard !overheard.contains(where: { abs($0.timeIntervalSince(date)) < Self.overheardMergeTolerance }) else { return }
    overheard.append(date)
    overheard.sort()
  }

  // MARK: - Rules

  private func evaluate(at date: Date) -> Decision {
    prune(at: date)
    // Each rule only gets easier as time passes, since nothing new is in the future, so the
    // earliest instant all three hold is the latest of their individual bounds.
    var until = date
    var reason: Reason?

    func require(_ bound: Date, _ candidate: Reason) {
      if bound > until {
        until = bound
        reason = candidate
      }
    }

    let ownTimes = own.map(\.at)
    if let last = ownTimes.last {
      require(last.addingTimeInterval(Self.minimumSpacing), .spacing)
    }
    // The window drops a request once it is `window` old; it is allowed again when only the
    // newest `maximum` remain.
    if ownTimes.count > Self.maximumOwnInWindow {
      require(ownTimes[ownTimes.count - Self.maximumOwnInWindow - 1].addingTimeInterval(Self.window), .ownCap)
    }
    let known = (ownTimes + overheard).sorted()
    if known.count > Self.maximumKnownInWindow {
      require(known[known.count - Self.maximumKnownInWindow - 1].addingTimeInterval(Self.window), .othersScanning)
    }

    guard let reason else { return .allowed }
    return .coolingDown(until: until, reason: reason)
  }

  /// Forgets requests that have left the trailing window. Spacing is shorter than the window, so
  /// our last request is never needed once it has gone.
  private func prune(at date: Date) {
    own.removeAll { date.timeIntervalSince($0.at) >= Self.window }
    overheard.removeAll { date.timeIntervalSince($0) >= Self.window }
  }
}
