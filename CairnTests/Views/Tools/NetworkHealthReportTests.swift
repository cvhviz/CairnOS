import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("NetworkHealthReport")
@MainActor
struct NetworkHealthReportTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func repeater(
    _ name: String,
    key: UInt8,
    heardHoursAgo: Double? = 1,
    modifiedHoursAgo: Double? = nil,
    type: UInt8 = 0x02
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: key, count: 32),
      name: name,
      typeRawValue: type,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: modifiedHoursAgo.map { UInt32(now.timeIntervalSince1970 - $0 * 3600) } ?? 0,
      lastHeardTimestamp: heardHoursAgo.map { UInt32(now.timeIntervalSince1970 - $0 * 3600) },
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func snapshot(
    _ key: UInt8,
    hoursAgo: Double,
    millivolts: UInt16? = 3990,
    noise: Int16? = -115,
    uptime: UInt32? = nil
  ) -> NodeStatusSnapshotDTO {
    NodeStatusSnapshotDTO(
      timestamp: now.addingTimeInterval(-hoursAgo * 3600),
      nodePublicKey: Data(repeating: key, count: 32),
      batteryMillivolts: millivolts,
      noiseFloor: noise,
      uptimeSeconds: uptime
    )
  }

  private func node(_ contact: ContactDTO, _ snapshots: [NodeStatusSnapshotDTO]) -> NetworkHealthNode {
    NetworkHealthReport.node(for: contact, snapshots: snapshots, now: now)
  }

  @Test
  func `A repeater that advertised no name reads as its key's first bytes`() {
    #expect(repeater("", key: 0xA3).displayName == "A3A3A3A3")
    #expect(repeater("  ", key: 0x0F).displayName == "0F0F0F0F")
    #expect(repeater("Hilltop", key: 0xA3).displayName == "Hilltop")
  }

  @Test
  func `A check older than the window fills the row but raises no issue`() {
    // 10% battery, ten days ago: shown with its age, not flagged as low today.
    let old = snapshot(1, hoursAgo: 240, millivolts: 3300, noise: -95, uptime: 7200)
    let node = NetworkHealthReport.node(for: repeater("A", key: 1), snapshots: [], latest: old, now: now)
    #expect(node.batteryPercent != nil)
    #expect(node.noiseFloor == -95)
    #expect(node.uptimeSeconds == 7200)
    #expect(node.lastChecked == old.timestamp)
    #expect(node.issues.isEmpty)
  }

  @Test
  func `A check inside the window wins over an older one`() {
    let recent = snapshot(1, hoursAgo: 2, noise: -118)
    let old = snapshot(1, hoursAgo: 240, noise: -95)
    let node = NetworkHealthReport.node(for: repeater("A", key: 1), snapshots: [recent], latest: old, now: now)
    #expect(node.noiseFloor == -118)
    #expect(node.lastChecked == recent.timestamp)
  }

  @Test
  func `a healthy repeater has no issues`() {
    let result = node(repeater("Hill", key: 1), [snapshot(1, hoursAgo: 2)])
    #expect(result.issues.isEmpty)
    #expect(result.batteryPercent == 80)
    #expect(result.noiseFloor == -115)
  }

  @Test
  func `low and critical battery`() {
    let low = node(repeater("A", key: 1), [snapshot(1, hoursAgo: 1, millivolts: 3350)])
    #expect(low.issues.contains { if case .lowBattery = $0 { true } else { false } })
    #expect(!low.isCritical)
    let critical = node(repeater("B", key: 2), [snapshot(2, hoursAgo: 1, millivolts: 3250)])
    #expect(critical.isCritical)
  }

  @Test
  func `battery falling fast within a day`() {
    let result = node(repeater("A", key: 1), [
      snapshot(1, hoursAgo: 20, millivolts: 3990),
      snapshot(1, hoursAgo: 1, millivolts: 3720),
    ])
    #expect(result.issues.contains(.batteryFalling(points: 30)))
  }

  @Test
  func `silence for over two days is critical, never heard is not flagged`() {
    let silent = node(repeater("A", key: 1, heardHoursAgo: 60), [])
    #expect(silent.issues == [.notHeard])
    #expect(silent.isCritical)
    let neverHeard = node(repeater("B", key: 2, heardHoursAgo: nil), [])
    #expect(neverHeard.issues.isEmpty)
    #expect(!neverHeard.hasStatus)
  }

  @Test
  func `a fresh synced advert time clears silence after the phone was disconnected`() {
    let synced = node(repeater("A", key: 1, heardHoursAgo: 60, modifiedHoursAgo: 3), [])
    #expect(synced.issues.isEmpty)
    #expect(synced.lastHeard == now.addingTimeInterval(-3 * 3600))
    let stale = node(repeater("B", key: 2, heardHoursAgo: 60, modifiedHoursAgo: 72), [])
    #expect(stale.issues == [.notHeard])
    #expect(stale.lastHeard == now.addingTimeInterval(-60 * 3600))
    let neverHeard = node(repeater("C", key: 3, heardHoursAgo: nil, modifiedHoursAgo: 72), [])
    #expect(neverHeard.issues.isEmpty)
    #expect(neverHeard.lastHeard == nil)
  }

  @Test
  func `high noise floor`() {
    let result = node(repeater("A", key: 1), [snapshot(1, hoursAgo: 1, noise: -92)])
    #expect(result.issues == [.highNoise(dBm: -92)])
  }

  @Test
  func `an unconverged noise floor of zero is not high noise`() {
    let result = node(repeater("A", key: 1), [snapshot(1, hoursAgo: 1, noise: 0)])
    #expect(result.issues.isEmpty)
  }

  @Test
  func `zero millivolt readings are left out of the battery trend`() {
    let result = node(repeater("A", key: 1), [
      snapshot(1, hoursAgo: 20, millivolts: 3990),
      snapshot(1, hoursAgo: 10, millivolts: 0),
      snapshot(1, hoursAgo: 5, millivolts: nil),
      snapshot(1, hoursAgo: 1, millivolts: 3990)
    ])
    #expect(result.batteryTrend.map(\.percent) == [80, 80])
    #expect(result.issues.isEmpty)
  }

  @Test
  func `a restart stays flagged after a later status check`() {
    let result = node(repeater("A", key: 1), [
      snapshot(1, hoursAgo: 30, uptime: 500_000),
      snapshot(1, hoursAgo: 6, uptime: 1800),
      snapshot(1, hoursAgo: 1, uptime: 19_800)
    ])
    #expect(result.issues.contains(.restarted))
    let outsideWindow = node(repeater("B", key: 2), [
      snapshot(2, hoursAgo: 60, uptime: 500_000),
      snapshot(2, hoursAgo: 30, uptime: 1800),
      snapshot(2, hoursAgo: 1, uptime: 106_200)
    ])
    #expect(!outsideWindow.issues.contains(.restarted))
  }

  @Test
  func `uptime going backwards means a restart`() {
    let result = node(repeater("A", key: 1), [
      snapshot(1, hoursAgo: 10, uptime: 500_000),
      snapshot(1, hoursAgo: 1, uptime: 1800),
    ])
    #expect(result.issues.contains(.restarted))
    let steady = node(repeater("B", key: 2), [
      snapshot(2, hoursAgo: 10, uptime: 500_000),
      snapshot(2, hoursAgo: 1, uptime: 532_400),
    ])
    #expect(!steady.issues.contains(.restarted))
  }

  @Test
  func `report groups and orders nodes and skips non-repeaters`() {
    let contacts = [
      repeater("Zulu", key: 1),
      repeater("Alpha", key: 2, heardHoursAgo: 72),
      repeater("Bravo", key: 3),
      repeater("Chat", key: 4, type: 0x01),
    ]
    let report = NetworkHealthReport(
      contacts: contacts,
      snapshotsByKey: [
        Data(repeating: 1, count: 32): [snapshot(1, hoursAgo: 1, millivolts: 3350)],
        Data(repeating: 3, count: 32): [snapshot(3, hoursAgo: 30)],
      ],
      now: now
    )
    #expect(report.nodes.count == 3)
    #expect(report.needsAttention.map(\.contact.name) == ["Alpha", "Zulu"])
    #expect(report.healthy.map(\.contact.name) == ["Bravo"])
    #expect(report.checkedCount(since: now.addingTimeInterval(-86400)) == 1)
  }
}
