import Foundation
@testable import Cairn
import MeshCore
import Testing

@Suite("LiveActivityManager packet rate")
@MainActor
struct LiveActivityManagerTests {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  @Test
  func `no packets reads as zero`() {
    #expect(LiveActivityManager.packetsPerMinute(timestamps: [], now: now) == 0)
  }

  @Test
  func `default 60s window returns the exact count, matching the RX Log`() {
    let timestamps = (1...7).map { now.addingTimeInterval(-Double($0) * 5) }
    #expect(LiveActivityManager.packetsPerMinute(timestamps: timestamps, now: now) == 7)
  }

  @Test
  func `packets older than the window are excluded`() {
    let timestamps = [
      now.addingTimeInterval(-10),
      now.addingTimeInterval(-59),
      now.addingTimeInterval(-61),
      now.addingTimeInterval(-120)
    ]
    #expect(LiveActivityManager.packetsPerMinute(timestamps: timestamps, now: now) == 2)
  }

  @Test
  func `a timestamp exactly at the cutoff is included`() {
    let atCutoff = now.addingTimeInterval(-LiveActivityManager.packetWindowSeconds)
    #expect(LiveActivityManager.packetsPerMinute(timestamps: [atCutoff], now: now) == 1)
  }

  @Test
  func `a shorter window still projects to a per-minute rate`() {
    let timestamps = (1...3).map { now.addingTimeInterval(-Double($0)) }
    #expect(LiveActivityManager.packetsPerMinute(timestamps: timestamps, now: now, window: 15) == 12)
  }
}

@Suite("LiveActivityManager content")
@MainActor
struct LiveActivityContentTests {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private var connected: MeshStatusAttributes.ContentState {
    MeshStatusAttributes.ContentState(
      isConnected: true,
      batteryPercent: 80,
      unreadCount: 2,
      disconnectedDate: nil,
      lastPacketDate: now.addingTimeInterval(-30),
      batteryMillivolts: 4000,
      lastRSSI: -90,
      lastSNR: 6.5,
      noiseFloor: -117,
      nodesHeard: 3,
      positionText: "1.0000, 2.0000"
    )
  }

  @Test
  func `nodes heard counts distinct senders within the hour`() {
    let heard: [Data: Date] = [
      Data([1]): now.addingTimeInterval(-10),
      Data([2]): now.addingTimeInterval(-3599),
      Data([3]): now.addingTimeInterval(-3601)
    ]
    #expect(LiveActivityManager.nodesHeard(lastHeard: heard, now: now) == 2)
  }

  @Test
  func `a change keeps unset fields and clears double-optional nils`() {
    let change = LiveActivityManager.StateChange(lastPacketDate: .some(now), lastRSSI: .some(nil))
    let state = change.applied(to: connected)
    #expect(state.lastPacketDate == now)
    #expect(state.lastRSSI == nil)
    #expect(state.lastSNR == 6.5)
    #expect(state.batteryMillivolts == 4000)
    #expect(state.positionText == "1.0000, 2.0000")
  }

  @Test
  func `merging keeps the newer value per field`() {
    var pending = LiveActivityManager.StateChange(lastPacketDate: .some(now.addingTimeInterval(-60)), noiseFloor: .some(-110))
    pending.merge(LiveActivityManager.StateChange(lastPacketDate: .some(now), lastSNR: .some(3)))
    #expect(pending.lastPacketDate == .some(now))
    #expect(pending.noiseFloor == .some(-110))
    #expect(pending.lastSNR == .some(3))
    #expect(pending.unreadCount == nil)
  }

  @Test
  func `a restarted activity keeps what it showed, its last packet included`() {
    var last = connected
    last.isConnected = false
    last.disconnectedDate = now
    let state = LiveActivityManager.restartState(from: last)
    #expect(state.isConnected)
    #expect(state.lastPacketDate == connected.lastPacketDate)
    #expect(state.disconnectedDate == nil)
    #expect(state.nodesHeard == 3)
  }

  @Test
  func `the GPS fix is the first GPS point in the telemetry`() {
    let telemetry = [
      LPPDataPoint(channel: 1, type: .voltage, value: .float(4.1)),
      LPPDataPoint(channel: 1, type: .gps, value: .gps(latitude: 41.5, longitude: -87.25, altitude: 182))
    ]
    let fix = LiveActivityManager.gpsFix(in: telemetry)
    #expect(fix == LiveActivityManager.GPSFix(latitude: 41.5, longitude: -87.25, altitude: 182))
    #expect(LiveActivityManager.gpsFix(in: [telemetry[0]]) == nil)
  }

  @Test
  func `a GPS fix brings an altitude, no position brings nothing`() {
    let fix = LiveActivityManager.GPSFix(latitude: 41.5, longitude: -87.25, altitude: 182)
    let texts = LiveActivityManager.positionTexts(advertised: nil, fix: fix)
    #expect(texts.position != nil)
    #expect(texts.altitude != nil)
    let none = LiveActivityManager.positionTexts(advertised: nil, fix: nil)
    #expect(none.position == nil)
    #expect(none.altitude == nil)
  }

  @Test
  func `the preview collapses whitespace and stops at the limit`() {
    #expect(MeshStatusAttributes.LastMessage.preview(of: "  hi\n\nthere  ") == "hi there")
    let long = String(repeating: "a", count: 200)
    let preview = MeshStatusAttributes.LastMessage.preview(of: long)
    #expect(preview.count == MeshStatusAttributes.LastMessage.previewLimit)
    #expect(preview.hasSuffix("…"))
  }

  @Test
  func `a state from an older build decodes with the new fields empty`() throws {
    let json = Data(#"{"isConnected":true,"batteryPercent":50,"packetsPerMinute":4,"unreadCount":1}"#.utf8)
    let state = try JSONDecoder().decode(MeshStatusAttributes.ContentState.self, from: json)
    #expect(state.isConnected)
    #expect(state.unreadCount == 1)
    #expect(state.lastMessage == nil)
    #expect(state.nodesHeard == nil)
    #expect(state.lastPacketDate == nil)
  }

  // MARK: - Last packet and quiet

  @Test
  func `a packet refreshes the activity only when its last packet is due`() {
    #expect(LiveActivityManager.isPacketRefreshDue(shown: nil, now: now))
    #expect(!LiveActivityManager.isPacketRefreshDue(shown: now.addingTimeInterval(-30), now: now))
    let due = now.addingTimeInterval(-LiveActivityManager.packetRefreshInterval)
    #expect(LiveActivityManager.isPacketRefreshDue(shown: due, now: now))
  }

  @Test
  func `a steady mesh refreshes the activity before it goes quiet`() {
    #expect(LiveActivityManager.quietAfter > LiveActivityManager.packetRefreshInterval)
  }

  @Test
  func `connected, the activity goes quiet a while after its last packet`() {
    var state = connected
    state.lastPacketDate = now.addingTimeInterval(-60)
    #expect(LiveActivityManager.staleDate(for: state, now: now)
      == now.addingTimeInterval(-60 + LiveActivityManager.quietAfter))

    // An update while the mesh is quiet (a message) keeps showing it quiet.
    state.lastPacketDate = now.addingTimeInterval(-3600)
    #expect(LiveActivityManager.staleDate(for: state, now: now) < now)

    // Before any packet, the wait starts now.
    state.lastPacketDate = nil
    #expect(LiveActivityManager.staleDate(for: state, now: now) == now.addingTimeInterval(LiveActivityManager.quietAfter))
  }

  @Test
  func `disconnected, the activity goes stale five minutes on`() {
    var state = connected
    state.isConnected = false
    #expect(LiveActivityManager.staleDate(for: state, now: now) == now.addingTimeInterval(300))
  }

  @Test
  func `a full state stays well under ActivityKit's 4 KB`() throws {
    var state = connected
    state.altitudeText = "12,345 ft"
    state.lastMessage = MeshStatusAttributes.LastMessage(
      sender: String(repeating: "N", count: 32),
      channelName: String(repeating: "C", count: 32),
      preview: MeshStatusAttributes.LastMessage.preview(of: String(repeating: "\u{1F600}", count: 200)),
      date: now
    )
    let size = try JSONEncoder().encode(state).count
    #expect(size < 2048)
  }

  // MARK: - Readings for CarPlay

  @Test
  func `readings are kept for CarPlay with no activity running`() async {
    let manager = LiveActivityManager()
    await manager.handlePacketReceived(rssi: -92, snr: 7.5)
    let message = MeshStatusAttributes.LastMessage(sender: "Alice", channelName: nil, preview: "Hi", date: .now)
    await manager.handleMessageReceived(message)
    #expect(manager.signal(now: .now)?.rssi == -92)
    #expect(manager.signal(now: .now)?.snr == 7.5)
    #expect(manager.packetsPerMinute(now: .now) == 1)
    #expect(manager.lastMessage == message)
  }

  @Test
  func `a last packet's signal ages out, and a dropped link clears it`() async {
    let manager = LiveActivityManager()
    await manager.handlePacketReceived(rssi: -92, snr: 7.5)
    #expect(manager.signal(now: Date.now.addingTimeInterval(LiveActivityManager.signalMaxAge + 1)) == nil)
    await manager.handleConnectionLost()
    #expect(manager.signal(now: .now) == nil)
    #expect(manager.packetsPerMinute(now: .now) == 0)
  }

  @Test
  func `radio reads are due for CarPlay only while a radio is connected`() {
    let manager = LiveActivityManager()
    var connected = false
    manager.connectionStateProvider = { connected }
    #expect(manager.claimDueRadioReads() == (false, false))
    manager.isCarPlayShowingReadings = true
    #expect(manager.claimDueRadioReads() == (false, false))
    connected = true
    #expect(manager.claimDueRadioReads() == (true, true))
    // Claimed: not due again straight away.
    #expect(manager.claimDueRadioReads() == (false, false))
  }
}
