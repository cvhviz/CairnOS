@testable import CairnServices
import MeshCore
import Testing

@Suite("SettingsService applyRadioPresetVerified path hash")
struct SettingsServiceApplyPresetTests {
  @Test
  @MainActor
  func `Hungary on v10 writes RF and hash then stamps catalog id`() async throws {
    let mock = MockConfigurationSession(firmwareVersion: 10)
    let service = SettingsService(session: mock)
    let preset = try #require(RadioPresets.all.first(where: { $0.id == "hu" }))
    let (collector, collectTask) = await collectSettingsEvents(from: service)
    defer { collectTask.cancel() }

    _ = try await service.applyRadioPresetVerified(preset)

    let radios = await mock.setRadioCalls
    #expect(radios.count == 1)
    #expect(radios[0].frequency == 869.618)
    #expect(await mock.setPathHashModeCalls == [1])
    try await waitUntil("apply should publish path hash then catalog id") {
      await collector.catalogIDs == ["hu"]
    }
    let events = await collector.events
    let pathHash = try #require(events.firstIndex {
      if case .pathHashModeUpdated(1) = $0 { return true }
      return false
    })
    let catalog = try #require(events.firstIndex {
      if case let .deviceUpdated(_, id) = $0 { return id == "hu" }
      return false
    })
    #expect(pathHash < catalog)
    // The RF settings go out first, without an id, so the app shows them even if the hash fails.
    let rfFirst = try #require(events.firstIndex {
      if case let .deviceUpdated(_, id) = $0 { return id == nil }
      return false
    })
    #expect(rfFirst < pathHash)
    #expect(await collector.deviceUpdatedCount == 2)
  }

  @Test
  @MainActor
  func `Hungary path-hash failure publishes the new RF but does not stamp catalog id`() async throws {
    let mock = MockConfigurationSession(firmwareVersion: 10)
    let service = SettingsService(session: mock)
    let preset = try #require(RadioPresets.all.first(where: { $0.id == "hu" }))
    let (collector, collectTask) = await collectSettingsEvents(from: service)
    defer { collectTask.cancel() }

    await mock.failNextSetPathHashMode(code: ErrorCode.illegalArgument.rawValue)
    do {
      _ = try await service.applyRadioPresetVerified(preset)
      Issue.record("expected the path-hash step to fail")
    } catch let SettingsServiceError.presetPathHashNotApplied(presetName) {
      #expect(presetName == "Hungary")
    }
    #expect(await mock.setRadioCalls.count == 1)
    #expect(await mock.setPathHashModeCalls == [1])
    // The radio is on Hungary's RF now, so the device model must hear about it.
    try await waitUntil("the RF settings are published before the failure") {
      await collector.deviceUpdatedCount >= 1
    }
    let rf = await collector.events.compactMap { event -> MeshCore.SelfInfo? in
      if case let .deviceUpdated(info, nil) = event { return info }
      return nil
    }
    #expect(rf.first?.radioFrequency == 869.618)
    #expect(rf.first?.radioSpreadingFactor == 7)

    try await service.refreshDeviceInfo()
    try await waitUntil("refreshDeviceInfo flushes the event stream") {
      await collector.deviceUpdatedCount >= 1
    }
    #expect(await collector.catalogIDs.isEmpty)
  }

  @Test
  @MainActor
  func `USA writes RF, skips hash, and stamps catalog id`() async throws {
    let mock = MockConfigurationSession(firmwareVersion: 10)
    let service = SettingsService(session: mock)
    let preset = try #require(RadioPresets.all.first(where: { $0.id == "us-ca" }))
    let (collector, collectTask) = await collectSettingsEvents(from: service)
    defer { collectTask.cancel() }

    _ = try await service.applyRadioPresetVerified(preset)

    #expect(await mock.setRadioCalls.count == 1)
    #expect(await mock.setPathHashModeCalls.isEmpty)
    try await waitUntil("apply should publish the catalog id") {
      await collector.catalogIDs == ["us-ca"]
    }
    #expect(await collector.deviceUpdatedCount == 1)
  }

  @Test
  @MainActor
  func `Hungary on v9 writes RF and skips hash`() async throws {
    let mock = MockConfigurationSession(firmwareVersion: 9)
    let service = SettingsService(session: mock)
    let preset = try #require(RadioPresets.all.first(where: { $0.id == "hu" }))

    _ = try await service.applyRadioPresetVerified(preset)

    #expect(await mock.setRadioCalls.count == 1)
    #expect(await mock.setPathHashModeCalls.isEmpty)
  }
}

private actor SettingsEventCollector {
  private(set) var events: [SettingsEvent] = []

  func record(_ event: SettingsEvent) {
    events.append(event)
  }

  var catalogIDs: [String] {
    events.compactMap { event in
      guard case let .deviceUpdated(_, id) = event else { return nil }
      return id
    }
  }

  var deviceUpdatedCount: Int {
    events.reduce(into: 0) { count, event in
      if case .deviceUpdated = event { count += 1 }
    }
  }
}

@MainActor
private func collectSettingsEvents(
  from service: SettingsService
) async -> (SettingsEventCollector, Task<Void, Never>) {
  let stream = await service.events()
  let collector = SettingsEventCollector()
  let task = Task {
    for await event in stream {
      await collector.record(event)
    }
  }
  return (collector, task)
}
