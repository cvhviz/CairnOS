import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// Every window's launch task calls `AppState.initialize()`. Re-running the
/// launch work over a live connection marks sessions disconnected and drops a
/// WiFi radio, so the work must run once however many windows open.
@Suite("AppState initialize run-once")
@MainActor
struct InitializeRunOnceTests {
  @Test
  func `Repeated initialize runs the launch work once`() async {
    let appState = AppState()
    let counter = RunCounter()
    appState.setInitializeOverrideForTesting {
      counter.count += 1
    }

    await appState.initialize()
    await appState.initialize()
    await appState.initialize()

    #expect(counter.count == 1)
  }

  @Test
  func `A call made while launch is in flight shares that run and waits for it`() async throws {
    let appState = AppState()
    let counter = RunCounter()
    appState.setInitializeOverrideForTesting {
      counter.count += 1
      try? await Task.sleep(for: .milliseconds(100))
      counter.finished += 1
    }

    // Two windows restored together: the second launch task starts before
    // the first window's run has finished.
    let firstWindow = Task { @MainActor in
      await appState.initialize()
    }
    try await waitUntil("launch work never started") { counter.count == 1 }

    await appState.initialize()

    // The second caller resumed only once the shared run had completed.
    #expect(counter.finished == 1)
    #expect(counter.count == 1)
    await firstWindow.value
  }
}

@MainActor
private final class RunCounter {
  var count = 0
  var finished = 0
}
