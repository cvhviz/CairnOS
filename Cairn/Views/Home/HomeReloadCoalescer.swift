import Foundation

/// Runs one of the Home dashboard's reloads as often as its data changes, but never more than one
/// at a time and at most one start per `interval`, and never cancels one under way. A request while
/// a run is under way, or soon after one started, queues a single trailing run instead, which
/// starts at whichever is later of that run's end and its start plus `interval` and reads the
/// newest inputs. So on a busy mesh the cards still refresh about once a second, each read
/// finishes and is shown, and the last change is always read.
///
/// Each run reads first and returns the step that shows what it read; the step is skipped only
/// when `reset()` (another radio) came while the run was under way, so another radio's data never
/// lands on the cards.
@MainActor
final class HomeReloadCoalescer {
  /// One run: reads what it needs, then returns the step that puts it on screen in one go, or nil
  /// when there is nothing to show (no radio, or the read failed).
  typealias Load = @MainActor () async -> (@MainActor () -> Void)?

  private let interval: Duration
  /// Time on the injected clock since this coalescer was made.
  private let elapsed: @Sendable () -> Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let load: Load

  /// Bumped by `reset()`; a run started under an older one finishes without being shown.
  private var generation = 0
  private var isRunning = false
  /// A request came while a run was under way: one more run follows it.
  private var isDirty = false
  private var lastStart: Duration?
  /// The trailing run, waiting out `interval` before it starts.
  private var trailingRun: Task<Void, Never>?
  /// Callers of `run()` waiting on the next run to start, resumed when it ends.
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init<C: Clock>(
    interval: Duration = .seconds(1),
    clock: C = ContinuousClock(),
    load: @escaping Load
  ) where C.Duration == Duration {
    let origin = clock.now
    self.interval = interval
    elapsed = { origin.duration(to: clock.now) }
    sleep = { try await clock.sleep(for: $0) }
    self.load = load
  }

  /// Whether a run is under way or queued, for the tests.
  var isBusy: Bool {
    isRunning || trailingRun != nil
  }

  /// Asks for a run: at once when idle and the last start was `interval` ago or more, otherwise
  /// as the one trailing run.
  func request() {
    if isRunning {
      isDirty = true
    } else if trailingRun == nil {
      startWhenAllowed()
    }
  }

  /// Asks for a run and returns once a run that started after this call has ended and been shown,
  /// or `reset()` dropped the request: pull to refresh, and CarPlay.
  func run() async {
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
      request()
    }
  }

  /// Another radio: forgets the queued run and the pacing, so the next request starts at once, and
  /// marks a run still under way as stale. That run is left to finish, unseen.
  func reset() {
    generation += 1
    trailingRun?.cancel()
    trailingRun = nil
    isRunning = false
    isDirty = false
    lastStart = nil
    let dropped = waiting
    waiting = []
    for continuation in dropped {
      continuation.resume()
    }
  }

  private func startWhenAllowed() {
    let wait = lastStart.map { $0 + interval - elapsed() } ?? .zero
    guard wait > .zero else {
      start()
      return
    }
    let generation = generation
    trailingRun = Task { [weak self, sleep] in
      // Cancelled only by `reset()`, which has already moved on.
      do { try await sleep(wait) } catch { return }
      guard let self, self.generation == generation else { return }
      trailingRun = nil
      start()
    }
  }

  private func start() {
    isRunning = true
    isDirty = false
    lastStart = elapsed()
    let generation = generation
    let waiters = waiting
    waiting = []
    Task { [weak self, load] in
      let show = await load()
      self?.finish(generation: generation, show: show, waiters: waiters)
    }
  }

  private func finish(generation: Int, show: (@MainActor () -> Void)?, waiters: [CheckedContinuation<Void, Never>]) {
    if generation == self.generation {
      show?()
      isRunning = false
      if isDirty {
        isDirty = false
        startWhenAllowed()
      }
    }
    for continuation in waiters {
      continuation.resume()
    }
  }
}
