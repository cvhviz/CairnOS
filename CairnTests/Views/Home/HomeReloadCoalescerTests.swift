import Foundation
@testable import Cairn
import Testing

/// What a fake load saw: when each run started and ended on the test clock, how many ran at
/// once, and which request each shown run had read.
@MainActor
private final class LoadRecorder {
  /// The number of the newest request, which a run reads as it starts.
  var latestRequest = 0
  var starts: [Duration] = []
  var finishes: [Duration] = []
  var running = 0
  var maxRunning = 0
  var cancelled = 0
  /// The request each shown run had read, in the order they were shown.
  var shown: [Int] = []
  var runReturned = false
}

@Suite("HomeReloadCoalescer")
@MainActor
struct HomeReloadCoalescerTests {
  private let clock = TestClock()
  private let recorder = LoadRecorder()

  /// A coalescer whose every run takes `duration` on the test clock.
  private func makeCoalescer(loadTaking duration: Duration = .milliseconds(500)) -> HomeReloadCoalescer {
    HomeReloadCoalescer(interval: .seconds(1), clock: clock) { [clock, recorder] in
      let seen = recorder.latestRequest
      recorder.starts.append(clock.now.offset)
      recorder.running += 1
      recorder.maxRunning = max(recorder.maxRunning, recorder.running)
      do {
        try await clock.sleep(for: duration)
      } catch {
        recorder.cancelled += 1
      }
      recorder.running -= 1
      recorder.finishes.append(clock.now.offset)
      return { recorder.shown.append(seen) }
    }
  }

  /// Lets every task the clock just woke run on to its next wait.
  private func settle() async {
    for _ in 0 ..< 50 {
      await Task.yield()
    }
  }

  private func request(_ coalescer: HomeReloadCoalescer) async {
    recorder.latestRequest += 1
    coalescer.request()
    await settle()
  }

  /// Moves the clock on in 100 ms steps, letting woken runs go at each.
  private func advance(by duration: Duration) async {
    var left = duration
    while left > .zero {
      clock.advance(by: .milliseconds(100))
      left -= .milliseconds(100)
      await settle()
    }
  }

  /// Requests every 300 ms for 5 s, as a steady stream of version bumps does, then lets the
  /// queue drain.
  private func requestSteadily(_ coalescer: HomeReloadCoalescer) async {
    for tick in 0 ..< 50 {
      if tick % 3 == 0 {
        await request(coalescer)
      }
      await advance(by: .milliseconds(100))
    }
    await advance(by: .seconds(3))
  }

  @Test
  func `A steady stream runs a load each second and never cancels one`() async {
    let coalescer = makeCoalescer()
    await requestSteadily(coalescer)

    #expect(recorder.cancelled == 0)
    #expect(recorder.maxRunning == 1)
    #expect(recorder.starts == (0 ... 5).map { Duration.seconds($0) })
    #expect(recorder.finishes.count == recorder.starts.count)
    // Every run was shown, the last one with the last request.
    #expect(recorder.shown.count == recorder.starts.count)
    #expect(recorder.shown.last == recorder.latestRequest)
    #expect(!coalescer.isBusy)
  }

  @Test
  func `Loads slower than the interval run back to back`() async {
    let coalescer = makeCoalescer(loadTaking: .milliseconds(1500))
    await requestSteadily(coalescer)

    #expect(recorder.cancelled == 0)
    #expect(recorder.maxRunning == 1)
    // Each run starts the moment the one before it ends.
    #expect(Array(recorder.starts.dropFirst()) == Array(recorder.finishes.dropLast()))
    #expect(recorder.shown.count == recorder.starts.count)
    #expect(recorder.shown.last == recorder.latestRequest)
  }

  @Test
  func `A request after a quiet spell runs at once`() async {
    let coalescer = makeCoalescer()
    await request(coalescer)
    await advance(by: .seconds(3))
    #expect(recorder.starts == [.zero])

    await request(coalescer)
    #expect(recorder.starts == [.zero, .seconds(3)])
  }

  @Test
  func `A request soon after a start waits out the interval`() async {
    let coalescer = makeCoalescer()
    await request(coalescer)
    await advance(by: .milliseconds(700))
    await request(coalescer)
    #expect(recorder.starts == [.zero])
    #expect(coalescer.isBusy)

    // More requests while it waits add no run.
    await request(coalescer)
    await advance(by: .milliseconds(300))
    #expect(recorder.starts == [.zero, .seconds(1)])
    await advance(by: .seconds(2))
    #expect(recorder.starts.count == 2)
    #expect(recorder.shown == [1, 3])
  }

  @Test
  func `A reset drops the load in flight and lets the next start at once`() async {
    let coalescer = makeCoalescer()
    await request(coalescer)
    await advance(by: .milliseconds(200))

    // Another radio: the first run is left to finish, unseen.
    coalescer.reset()
    await request(coalescer)
    #expect(recorder.starts == [.zero, .milliseconds(200)])

    await advance(by: .seconds(1))
    #expect(recorder.cancelled == 0)
    #expect(recorder.finishes.count == 2)
    #expect(recorder.shown == [2])
  }

  @Test
  func `A reset drops the queued run`() async {
    let coalescer = makeCoalescer()
    await request(coalescer)
    await request(coalescer)
    coalescer.reset()
    await advance(by: .seconds(3))

    #expect(recorder.starts == [.zero])
    #expect(recorder.shown.isEmpty)
    #expect(!coalescer.isBusy)
  }

  @Test
  func `run returns once a run started after it has been shown`() async throws {
    let coalescer = makeCoalescer()
    await request(coalescer)
    await advance(by: .milliseconds(200))

    recorder.latestRequest += 1
    let waiter = Task { [recorder] in
      await coalescer.run()
      recorder.runReturned = true
    }
    await settle()

    // The run under way began before the call, so the caller waits for the trailing one.
    await advance(by: .milliseconds(400))
    #expect(recorder.shown == [1])
    #expect(!recorder.runReturned)

    await advance(by: .seconds(1))
    try await waitUntil("run should return after the trailing run is shown") { recorder.runReturned }
    #expect(recorder.starts == [.zero, .seconds(1)])
    #expect(recorder.shown == [1, 2])
    await waiter.value
  }
}
