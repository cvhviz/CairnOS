import Foundation
@testable import Cairn
import SwiftUI
import Testing

@Suite("AppLifecycleGate Tests")
@MainActor
struct AppLifecycleGateTests {
  // MARK: - Launch

  @Test
  func `Launch runs once for windows opened one after another`() async {
    let gate = AppLifecycleGate()
    let counter = LaunchCounter()

    await gate.runLaunchOnce { counter.count += 1 }
    await gate.runLaunchOnce { counter.count += 1 }

    #expect(counter.count == 1)
  }

  @Test
  func `A window opened mid-launch waits for the run in flight`() async throws {
    let gate = AppLifecycleGate()
    let counter = LaunchCounter()

    let firstWindow = Task { @MainActor in
      await gate.runLaunchOnce {
        counter.count += 1
        try? await Task.sleep(for: .milliseconds(100))
        counter.finished += 1
      }
    }
    try await waitUntil("launch never started") { counter.count == 1 }

    await gate.runLaunchOnce { counter.count += 1 }

    #expect(counter.finished == 1)
    #expect(counter.count == 1)
    await firstWindow.value
  }

  @Test
  func `Closing the window that started launch does not cancel launch`() async throws {
    let gate = AppLifecycleGate()
    let counter = LaunchCounter()

    let firstWindow = Task { @MainActor in
      await gate.runLaunchOnce {
        counter.count += 1
        try? await Task.sleep(for: .milliseconds(100))
        if !Task.isCancelled {
          counter.finished += 1
        }
      }
    }
    try await waitUntil("launch never started") { counter.count == 1 }

    // SwiftUI cancels a window's `.task` when the window goes away.
    firstWindow.cancel()
    await gate.runLaunchOnce {}

    #expect(counter.finished == 1)
  }

  // MARK: - Scene phase

  @Test
  func `Only the first window's report of a transition is handled`() {
    let gate = AppLifecycleGate()
    let now = ContinuousClock.now

    #expect(gate.shouldHandle(.background, at: now))
    #expect(!gate.shouldHandle(.background, at: now + .milliseconds(5)))
    #expect(!gate.shouldHandle(.background, at: now + .milliseconds(10)))
  }

  @Test
  func `Each new phase is handled`() {
    let gate = AppLifecycleGate()
    let now = ContinuousClock.now

    #expect(gate.shouldHandle(.inactive, at: now))
    #expect(gate.shouldHandle(.background, at: now + .milliseconds(1)))
    #expect(gate.shouldHandle(.inactive, at: now + .milliseconds(2)))
    #expect(gate.shouldHandle(.active, at: now + .milliseconds(3)))
  }

  @Test
  func `A quick bounce back to active is handled again`() {
    let gate = AppLifecycleGate()
    let now = ContinuousClock.now

    #expect(gate.shouldHandle(.active, at: now))
    #expect(gate.shouldHandle(.inactive, at: now + .milliseconds(100)))
    #expect(gate.shouldHandle(.active, at: now + .milliseconds(200)))
  }

  @Test
  func `A stale record does not swallow a later transition into the same phase`() {
    let gate = AppLifecycleGate()
    let now = ContinuousClock.now

    // Every window closed without reporting the background transition, then
    // one reopened: its report of `.active` is a new transition.
    #expect(gate.shouldHandle(.active, at: now))
    #expect(gate.shouldHandle(.active, at: now + AppLifecycleGate.duplicateReportWindow))
  }
}

@MainActor
private final class LaunchCounter {
  var count = 0
  var finished = 0
}
