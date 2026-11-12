import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("Node status dashboard values")
@MainActor
struct NodeStatusDashboardTests {
  private let testPublicKey = Data(repeating: 0x42, count: 32)

  private func makeHelper() -> NodeStatusViewModel {
    let helper = NodeStatusViewModel()
    helper.session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: testPublicKey,
      name: "Test Repeater",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    return helper
  }

  private func makeStatus(
    layout: StatusResponse.Layout = .repeater,
    battery: Int = 3850,
    txQueueLength: Int = 0,
    noiseFloor: Int = -118,
    lastRSSI: Int = -100,
    airtime: UInt32 = 360,
    uptime: UInt32 = 3600,
    rxAirtime: UInt32 = 720,
    directDuplicates: Int = 3,
    floodDuplicates: Int = 1200
  ) -> StatusResponse {
    StatusResponse(
      layout: layout,
      publicKeyPrefix: testPublicKey.prefix(6),
      battery: battery,
      txQueueLength: txQueueLength,
      noiseFloor: noiseFloor,
      lastRSSI: lastRSSI,
      packetsReceived: 1000,
      packetsSent: 500,
      airtime: airtime,
      uptime: uptime,
      sentFlood: 400,
      sentDirect: 100,
      receivedFlood: 900,
      receivedDirect: 100,
      fullEvents: 0,
      lastSNR: 8.5,
      directDuplicates: directDuplicates,
      floodDuplicates: floodDuplicates,
      rxAirtime: rxAirtime
    )
  }

  // MARK: - Auto-load

  @Test
  func `Auto-load waits for a ready radio`() {
    let helper = makeHelper()
    #expect(helper.shouldAutoLoadStatus(connectionState: .ready))
    #expect(!helper.shouldAutoLoadStatus(connectionState: .syncing))
    #expect(!helper.shouldAutoLoadStatus(connectionState: .disconnected))
  }

  @Test
  func `Auto-load skips while a request is in flight`() {
    let helper = makeHelper()
    helper.isLoadingStatus = true
    #expect(!helper.shouldAutoLoadStatus(connectionState: .ready))
  }

  @Test
  func `Auto-load skips once a reading exists`() {
    let helper = makeHelper()
    helper.status = makeStatus()
    #expect(!helper.shouldAutoLoadStatus(connectionState: .ready))
  }

  @Test
  func `Host backstop leaves a failed first request to Try Again`() {
    let helper = makeHelper()
    #expect(helper.shouldBackstopAutoLoadStatus(connectionState: .ready))
    helper.statusSectionError = "Request timed out"
    #expect(!helper.shouldBackstopAutoLoadStatus(connectionState: .ready))
    // The page's own reconnect retry still goes ahead.
    #expect(helper.shouldAutoLoadStatus(connectionState: .ready))
  }

  @Test
  func `A response stamps when the reading arrived`() async throws {
    let helper = makeHelper()
    #expect(helper.statusUpdatedAt == nil)
    let before = Date.now
    await helper.handleStatusResponse(makeStatus())
    let stamp = try #require(helper.statusUpdatedAt)
    #expect(stamp >= before)
    #expect(helper.statusLoaded)
  }

  // MARK: - Phase

  @Test
  func `Dashboard phase follows reading, request, radio and error`() {
    let helper = makeHelper()
    #expect(helper.dashboardPhase(connectionState: .ready) == .loading)
    #expect(helper.dashboardPhase(connectionState: .disconnected) == .disconnected)
    #expect(helper.dashboardPhase(connectionState: .connecting) == .disconnected)
    // Linked but still syncing: the placeholders hold until the automatic request at `.ready`.
    #expect(helper.dashboardPhase(connectionState: .syncing) == .loading)

    helper.statusSectionError = "Request timed out"
    #expect(helper.dashboardPhase(connectionState: .ready) == .failed("Request timed out"))

    helper.isLoadingStatus = true
    #expect(helper.dashboardPhase(connectionState: .ready) == .loading)

    // A reading stays on screen through a failed refresh or a disconnect.
    helper.isLoadingStatus = false
    helper.status = makeStatus()
    #expect(helper.dashboardPhase(connectionState: .ready) == .loaded)
    #expect(helper.dashboardPhase(connectionState: .disconnected) == .loaded)
  }

  // MARK: - Airtime

  @Test
  func `Airtime shares are fractions of uptime`() {
    let helper = makeHelper()
    helper.status = makeStatus(airtime: 360, uptime: 3600, rxAirtime: 720)
    #expect(helper.txShare == 0.1)
    #expect(helper.rxShare == 0.2)
    #expect(helper.channelUseFraction.map { abs($0 - 0.3) < 1e-9 } == true)
    #expect(helper.channelUseDisplay == (30.0).formatted(.number.precision(.fractionLength(1))) + "%")
  }

  @Test
  func `Airtime shares are nil before a second of uptime`() {
    let helper = makeHelper()
    helper.status = makeStatus(uptime: 0)
    #expect(helper.txShare == nil)
    #expect(helper.rxShare == nil)
    #expect(helper.channelUseFraction == nil)
  }

  @Test
  func `Airtime shares clamp to the whole uptime`() {
    let helper = makeHelper()
    helper.status = makeStatus(airtime: 5000, uptime: 3600, rxAirtime: 3000)
    #expect(helper.txShare == 1)
    #expect(helper.channelUseFraction == 1)
  }

  @Test
  func `Room layout has no receive airtime or channel use`() {
    let helper = makeHelper()
    helper.status = makeStatus(layout: .roomServer, rxAirtime: 0)
    #expect(helper.isRoomLayout)
    #expect(helper.txShare != nil)
    #expect(helper.rxShare == nil)
    #expect(helper.channelUseFraction == nil)

    helper.status = makeStatus()
    #expect(!helper.isRoomLayout)
  }

  // MARK: - Signal

  @Test
  func `Signal margin is RSSI over the noise floor`() {
    let helper = makeHelper()
    helper.status = makeStatus(noiseFloor: -118, lastRSSI: -100)
    #expect(helper.rssiAboveNoise == 18)

    helper.status = makeStatus(noiseFloor: 0)
    #expect(helper.rssiAboveNoise == nil)
  }

  @Test
  func `High noise starts above Network Health's threshold`() {
    let helper = makeHelper()
    helper.status = makeStatus(noiseFloor: NetworkHealthReport.highNoiseFloor)
    #expect(!helper.isNoiseHigh)
    helper.status = makeStatus(noiseFloor: NetworkHealthReport.highNoiseFloor + 1)
    #expect(helper.isNoiseHigh)
    helper.status = makeStatus(noiseFloor: 0)
    #expect(!helper.isNoiseHigh)
  }

  // MARK: - Battery and queue

  @Test
  func `Zero millivolts reads as not measured`() {
    let helper = makeHelper()
    helper.status = makeStatus(battery: 0)
    #expect(!helper.isBatteryMeasured)
    #expect(helper.batteryPercent == nil)
    #expect(helper.batteryLevel == nil)

    helper.status = makeStatus(battery: 4200)
    #expect(helper.isBatteryMeasured)
    #expect(helper.batteryLevel == .good)
  }

  @Test
  func `TX queue warns at Cairn's depth`() {
    let helper = makeHelper()
    helper.status = makeStatus(txQueueLength: NodeStatusViewModel.txQueueWarningLength - 1)
    #expect(!helper.isTxQueueBacklogged)
    helper.status = makeStatus(txQueueLength: NodeStatusViewModel.txQueueWarningLength)
    #expect(helper.isTxQueueBacklogged)
    #expect(helper.txQueueDisplay == NodeStatusViewModel.txQueueWarningLength.formatted())
  }

  // MARK: - Packets

  @Test
  func `Duplicates split into direct and flood`() {
    let helper = makeHelper()
    #expect(helper.directDuplicatesDisplay == NodeStatusViewModel.emDash)
    helper.status = makeStatus(directDuplicates: 3, floodDuplicates: 1200)
    #expect(helper.directDuplicatesDisplay == 3.formatted())
    #expect(helper.floodDuplicatesDisplay == 1200.formatted())
    #expect(helper.duplicatesDisplay == 1203.formatted())
  }

  // MARK: - Freshness

  @Test
  func `Updated text holds to the minute`() {
    let now = Date.now
    let justNow = NodeStatusViewModel.updatedText(since: now.addingTimeInterval(-30), now: now)
    let atZero = NodeStatusViewModel.updatedText(since: now, now: now)
    #expect(justNow == atZero)

    let twoMinutes = NodeStatusViewModel.updatedText(since: now.addingTimeInterval(-150), now: now)
    let exactlyTwo = NodeStatusViewModel.updatedText(since: now.addingTimeInterval(-120), now: now)
    #expect(twoMinutes == exactlyTwo)
    #expect(twoMinutes != justNow)
  }
}
