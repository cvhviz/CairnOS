import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("AppState Lifecycle Transition Tests")
@MainActor
struct LifecycleTransitionTests {
  @Test
  func `BLE foreground waits for queued background transition`() async {
    let appState = AppState()
    let recorder = TransitionRecorder()

    appState.setBLELifecycleOverridesForTesting(
      enterBackground: {
        await recorder.record("background-start")
        try? await Task.sleep(for: .milliseconds(150))
        await recorder.record("background-end")
      },
      becomeActive: {
        await recorder.record("foreground-start")
        await recorder.record("foreground-end")
      }
    )

    appState.handleEnterBackground()
    await appState.handleReturnToForeground()

    let events = await recorder.events
    #expect(events == [
      "background-start",
      "background-end",
      "foreground-start",
      "foreground-end"
    ])
  }

  @Test
  func `Explicit disconnect runs the per-session teardown the loss path performs`() async {
    let appState = AppState()
    appState.settingsEventsTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
      }
    }
    await appState.disconnect()

    #expect(appState.settingsEventsTask == nil)
  }

  @Test
  func `Explicit disconnect stops battery monitoring and drops the sync coordinator`() async throws {
    let appState = AppState()
    let services = try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: MockTransport())
    )
    appState.connectionManager.setTestState(connectionState: .ready, services: services)
    await appState.wireServicesIfConnected()
    #expect(appState.syncCoordinator != nil)
    #expect(appState.batteryMonitor.bootstrapTask != nil)
    appState.connectionUI.isNodeStorageFull = true
    // The connection manager clears its own services during a disconnect;
    // what is under test is the app-level state it leaves to AppState.
    appState.connectionManager.setTestState(connectionState: .disconnected, services: .some(nil))

    await appState.disconnect()

    #expect(appState.syncCoordinator == nil)
    #expect(appState.batteryMonitor.bootstrapTask == nil)
    #expect(appState.batteryMonitor.batteryRefreshTask == nil)
    #expect(appState.connectionUI.isNodeStorageFull == false)
  }

  @Test
  func `rapid background-active bounces keep BLE transitions ordered`() async {
    let appState = AppState()
    let recorder = TransitionRecorder()

    appState.setBLELifecycleOverridesForTesting(
      enterBackground: {
        try? await Task.sleep(for: .milliseconds(20))
        await recorder.record("background")
      },
      becomeActive: {
        await recorder.record("foreground")
      }
    )

    for _ in 0..<5 {
      appState.handleEnterBackground()
      await appState.handleReturnToForeground()
    }

    let events = await recorder.events
    #expect(events.count == 10)

    for index in stride(from: 0, to: events.count, by: 2) {
      #expect(events[index] == "background")
      #expect(events[index + 1] == "foreground")
    }
  }

  @Test
  func `toolbar resume probe names chrome without contact identity`() {
    let appState = AppState()
    let secretName = "PII-SHOULD-NOT-LEAK"
    appState.navigation.homePath = [.tool(.lineOfSight)]
    appState.navigation.selectedTab = AppTab.gps.rawValue
    appState.navigation.chatsSelectedRoute = .direct(Self.makeContact(name: secretName))
    appState.navigation.presentSettings()
    appState.navigation.nodesShowingDiscovery = true

    let message = appState.toolbarResumeProbeMessage(
      source: "returnToForeground",
      scene: "background->active"
    )

    #expect(message.contains("[DBG-toolbar-resume]"))
    #expect(message.contains("source=returnToForeground"))
    #expect(message.contains("scene=background->active"))
    #expect(message.contains("tab=gps"))
    #expect(message.contains("chatRoute=direct"))
    #expect(message.contains("nodesDetail=discovery"))
    #expect(message.contains("tool=lineOfSight"))
    #expect(message.contains("settings=true"))
    #expect(message.contains("connection=disconnected"))
    #expect(message.contains("hasDevice=false"))
    #expect(!message.contains(secretName))
  }

  private static func makeContact(name: String) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0xAA, count: 32),
      name: name,
      typeRawValue: 0x01,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }
}

private actor TransitionRecorder {
  private(set) var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }
}
