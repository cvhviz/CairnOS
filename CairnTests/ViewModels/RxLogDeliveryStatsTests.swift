import Foundation
@testable import Cairn
@testable import CairnServices
@testable import MeshCore
import SwiftUI
import Testing

@MainActor
struct RxLogDeliveryStatsTests {
  // MARK: - Delivery line

  // MARK: - Needs attention (Scan & Traffic's mark on Packets)

  @Test
  func `all received, or not yet measured, needs no attention`() {
    #expect(!RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .idle)))
    #expect(!RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .synced, delivered: 240, missing: 6)))
    #expect(!RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .stock, stockReason: .otherFirmware)))
    let allHeard = StockRadioLoss(heard: 40, missed: 0)
    #expect(!RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .stock, stockReason: .otherFirmware, radioLoss: allHeard)))
  }

  @Test
  func `packets lost on the way, or recovery missing, need attention`() {
    #expect(RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .synced, lostAtRadio: 3)))
    #expect(RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .synced, unrecovered: 1)))
    #expect(RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .synced, linkDrops: 2)))
    let missed = StockRadioLoss(heard: 43, missed: 3)
    #expect(RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .stock, stockReason: .otherFirmware, radioLoss: missed)))
    #expect(RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .stock, stockReason: .recoveryUnsupported)))
    #expect(RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .stock, stockReason: .recoveryFailed)))
    // Packets recovered from the radio arrived after all.
    #expect(!RxLogViewModel.deliveryNeedsAttention(for: makeStats(mode: .synced, recovered: 7)))
  }

  @Test
  func `no line until the radio has said whether it offers RX_SYNC`() {
    #expect(RxLogViewModel.deliveryLine(for: makeStats(mode: .idle)) == nil)
    #expect(RxLogViewModel.deliveryLine(for: makeStats(mode: .probing)) == nil)
  }

  @Test
  func `Cairn firmware with nothing missed says all traffic received`() {
    let stats = makeStats(mode: .synced, delivered: 240, appDrops: ["rxlog": 0, "neighbours": 0])
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.allReceived)
  }

  @Test
  func `Cairn firmware counts recovered packets and those lost at the radio`() {
    let stats = makeStats(mode: .synced, delivered: 240, recovered: 7, lostAtRadio: 3)
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.recoveredLost(7, 3))
  }

  @Test
  func `records FETCH could not bring count as lost`() {
    let stats = makeStats(mode: .synced, recovered: 2, lostAtRadio: 1, unrecovered: 4)
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.recoveredLost(2, 5))
  }

  @Test
  func `records still being fetched are neither recovered nor lost yet`() {
    let stats = makeStats(mode: .synced, missing: 6)
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.allReceived)
  }

  @Test
  func `Cairn firmware adds the app's dispatcher and BLE drops after the radio's counts`() {
    let stats = makeStats(mode: .synced, recovered: 1, appDrops: ["rxlog": 2, "neighbours": 3], linkDrops: 4)
    let expected = [
      L10n.Tools.Tools.RxLog.Delivery.recoveredLost(1, 0),
      L10n.Tools.Tools.RxLog.Delivery.appDropped(9),
    ].joined(separator: " · ")
    #expect(RxLogViewModel.deliveryLine(for: stats) == expected)
  }

  @Test
  func `app drops alone are never shown as all received`() {
    let dispatcher = makeStats(mode: .synced, appDrops: ["rxlog": 1])
    #expect(RxLogViewModel.deliveryLine(for: dispatcher) == L10n.Tools.Tools.RxLog.Delivery.appDropped(1))

    let ble = makeStats(mode: .synced, linkDrops: 2)
    #expect(RxLogViewModel.deliveryLine(for: ble) == L10n.Tools.Tools.RxLog.Delivery.appDropped(2))
  }

  // MARK: - Stock firmware

  @Test
  func `unmeasured stock firmware says packets can be skipped, with every drop the app counted`() {
    let quiet = makeStats(mode: .stock, stockReason: .otherFirmware)
    #expect(RxLogViewModel.deliveryLine(for: quiet) == L10n.Tools.Tools.RxLog.Delivery.stockUnmeasured)

    // v1.7–v1.10 have no packet counter: the BLE drops are all the app can count of the radio's side.
    let dropping = makeStats(mode: .stock, appDrops: ["rxlog": 12], stockReason: .otherFirmware, linkDrops: 5)
    let expected = [
      L10n.Tools.Tools.RxLog.Delivery.stockUnmeasured,
      L10n.Tools.Tools.RxLog.Delivery.appDropped(17),
    ].joined(separator: " · ")
    #expect(RxLogViewModel.deliveryLine(for: dropping) == expected)
    #expect(RxLogViewModel.deliveryLine(for: dropping) != L10n.Tools.Tools.RxLog.Delivery.allReceived)
  }

  @Test
  func `stock firmware whose counter saw every packet arrive says all traffic received`() throws {
    // 40 packets counted, 40 0x88 frames reached the session.
    let loss = try #require(radioLoss(from: (received: 1000, frames: 7), to: (received: 1040, frames: 47)))
    #expect(loss == StockRadioLoss(heard: 40, missed: 0))
    let stats = makeStats(mode: .stock, stockReason: .otherFirmware, radioLoss: loss)
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.allReceived)
  }

  @Test
  func `stock firmware counts the packets the radio heard that never reached the app`() throws {
    // The radio counted 43 packets while 40 0x88 frames arrived: 3 never did.
    let loss = try #require(radioLoss(from: (received: 1000, frames: 0), to: (received: 1043, frames: 40)))
    #expect(loss == StockRadioLoss(heard: 43, missed: 3))
    let stats = makeStats(mode: .stock, stockReason: .otherFirmware, radioLoss: loss)
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.radioMissed(3, 43))
  }

  @Test
  func `measured stock delivery adds the app's own drops but not the BLE drops already in the count`() throws {
    let loss = try #require(radioLoss(from: (received: 1000, frames: 0), to: (received: 1043, frames: 40)))
    let stats = makeStats(mode: .stock, appDrops: ["rxlog": 2], stockReason: .otherFirmware, linkDrops: 3, radioLoss: loss)
    let expected = [
      L10n.Tools.Tools.RxLog.Delivery.radioMissed(3, 43),
      L10n.Tools.Tools.RxLog.Delivery.appDropped(2),
    ].joined(separator: " · ")
    #expect(RxLogViewModel.deliveryLine(for: stats) == expected)

    // Nothing missed at the radio, but the app dropped some: never all received.
    let clean = try #require(radioLoss(from: (received: 1000, frames: 0), to: (received: 1040, frames: 40)))
    let appOnly = makeStats(mode: .stock, appDrops: ["neighbours": 1], stockReason: .otherFirmware, linkDrops: 6, radioLoss: clean)
    #expect(RxLogViewModel.deliveryLine(for: appOnly) == L10n.Tools.Tools.RxLog.Delivery.appDropped(1))
  }

  @Test
  func `a reading that counted no packet yet says nothing about loss`() throws {
    let idle = try #require(radioLoss(from: (received: 500, frames: 3), to: (received: 500, frames: 3)))
    #expect(idle == StockRadioLoss(heard: 0, missed: 0))
    let stats = makeStats(mode: .stock, stockReason: .otherFirmware, radioLoss: idle)
    #expect(RxLogViewModel.deliveryLine(for: stats) == L10n.Tools.Tools.RxLog.Delivery.stockUnmeasured)
  }

  @Test
  func `a Cairn radio without working recovery says why before its delivery`() throws {
    let loss = try #require(radioLoss(from: (received: 1000, frames: 0), to: (received: 1040, frames: 40)))
    let unsupported = makeStats(mode: .stock, stockReason: .recoveryUnsupported, radioLoss: loss)
    #expect(RxLogViewModel.deliveryLine(for: unsupported) == [
      L10n.Tools.Tools.RxLog.Delivery.recoveryUnsupported,
      L10n.Tools.Tools.RxLog.Delivery.allReceived,
    ].joined(separator: " · "))

    let failed = makeStats(mode: .stock, stockReason: .recoveryFailed)
    #expect(RxLogViewModel.deliveryLine(for: failed) == [
      L10n.Tools.Tools.RxLog.Delivery.recoveryFailed,
      L10n.Tools.Tools.RxLog.Delivery.stockUnmeasured,
    ].joined(separator: " · "))

    // Other firmware gets no reason: it's not Cairn.
    let stock = makeStats(mode: .stock, stockReason: .otherFirmware, radioLoss: loss)
    #expect(RxLogViewModel.deliveryLine(for: stock) == L10n.Tools.Tools.RxLog.Delivery.allReceived)
  }

  @Test
  func `stock firmware notes the longest packet it passes on, by firmware version`() {
    // v1.15.0 (VER_CODE 11) has MAX_FRAME_SIZE 172; v1.16.0 (13) and later 176.
    let v115 = makeDevice(firmwareVersion: 11, firmwareVersionString: "v1.15.0").maxForwardedRxPacketLength
    let v118 = makeDevice(firmwareVersion: 14, firmwareVersionString: "v1.18.0").maxForwardedRxPacketLength
    #expect(v115 == 169)
    #expect(v118 == 173)
    #expect(RxLogViewModel.longPacketNote(for: makeStats(mode: .stock, forwardLimit: v115))
      == L10n.Tools.Tools.RxLog.Delivery.longPackets(169))
    #expect(RxLogViewModel.longPacketNote(for: makeStats(mode: .stock, forwardLimit: v118))
      == L10n.Tools.Tools.RxLog.Delivery.longPackets(173))
  }

  @Test
  func `no long-packet note with RX_SYNC or before the mode settles`() {
    #expect(RxLogViewModel.longPacketNote(for: makeStats(mode: .synced)) == nil)
    #expect(RxLogViewModel.longPacketNote(for: makeStats(mode: .probing)) == nil)
    #expect(RxLogViewModel.longPacketNote(for: makeStats(mode: .idle)) == nil)
  }

  @Test
  func `no line while disconnected`() async {
    let model = RxLogViewModel()
    await model.refreshDeliveryLine()
    #expect(model.deliveryLine == nil)
    #expect(model.longPacketNote == nil)
  }

  // MARK: - Recovered rows

  @Test
  func `backfilled rows stay flagged through the filtered and grouped lists`() {
    let model = RxLogViewModel()
    let live = makeDTO(packetPayload: Data([0x01]))
    var recovered = makeDTO(seq: 41, packetPayload: Data([0x02]))
    recovered.isBackfill = true
    model.load([live])
    model.appendEntry(recovered)

    let ungrouped = Array(model.displayEntries(groupingDuplicates: false))
    #expect(ungrouped.map(\.id) == [recovered.id, live.id])
    #expect(ungrouped.map(\.isBackfill) == [true, false])
    #expect(model.displayEntries(groupingDuplicates: true).first?.isBackfill == true)

    #expect(row(for: recovered).isRecovered)
    #expect(!row(for: live).isRecovered)
  }

  @Test
  func `an RX_SYNC record fetched again is flagged, a live one is not`() {
    var fetched = makeDTO(seq: 7, isBackfill: true)
    #expect(row(for: fetched).isRecovered)
    #expect(fetched.radioSeq == 7)

    fetched = makeDTO(seq: 8)
    #expect(!row(for: fetched).isRecovered)
  }

  // MARK: - Helpers

  private func makeStats(
    mode: RxStreamMode,
    delivered: Int = 0,
    recovered: Int = 0,
    lostAtRadio: Int = 0,
    unrecovered: Int = 0,
    missing: Int = 0,
    appDrops: [String: Int] = [:],
    stockReason: RxStockReason? = nil,
    linkDrops: Int = 0,
    radioLoss: StockRadioLoss? = nil,
    forwardLimit: Int? = nil
  ) -> RxStreamDeliveryStats {
    RxStreamDeliveryStats(
      mode: mode,
      radio: RxDeliveryStats(
        isActive: mode == .synced,
        epoch: mode == .synced ? 0x1234_5678 : nil,
        lastSeq: mode == .synced ? UInt32(delivered) : nil,
        delivered: delivered,
        recovered: recovered,
        lostAtRadio: lostAtRadio,
        unrecovered: unrecovered,
        missing: missing,
        duplicates: 0
      ),
      lossReports: 0,
      refusedFrames: 0,
      appDrops: appDrops,
      stockReason: stockReason,
      linkDrops: linkDrops,
      radioLoss: radioLoss,
      forwardLimit: forwardLimit
    )
  }

  /// A `CMD_GET_STATS` / `STATS_TYPE_PACKETS` reply as official companion v1.11.0 writes it
  /// (MyMesh.cpp:1580-1596): `RESP_CODE_STATS` 0x18, the sub-type 0x02, then received, sent,
  /// flood TX, direct TX, flood RX and direct RX as little-endian UInt32 (24 bytes).
  private func statsPacketsFrame(received: UInt32) -> Data {
    var frame = Data([0x18, 0x02])
    for counter in [received, 61, 40, 21, received / 2, received - received / 2] {
      withUnsafeBytes(of: counter.littleEndian) { frame.append(contentsOf: $0) }
    }
    return frame
  }

  /// The loss the stock delivery monitor totals from two of those replies, each stamped with the
  /// 0x88 frames the session had received when it arrived, as `MeshCoreSession` stamps them.
  private func radioLoss(
    from first: (received: UInt32, frames: UInt64),
    to second: (received: UInt32, frames: UInt64)
  ) -> StockRadioLoss? {
    var ledger = StockLossLedger()
    for reading in [first, second] {
      guard case let .statsPackets(stats) = PacketParser.parse(statsPacketsFrame(received: reading.received)),
            let sample = StockBarrierSample(stats.stamped(appRxLogFrames: reading.frames)) else { return nil }
      ledger.ingest(sample)
    }
    return ledger.totals
  }

  private func makeDevice(firmwareVersion: UInt8, firmwareVersionString: String) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "TestDevice",
      firmwareVersion: firmwareVersion,
      firmwareVersionString: firmwareVersionString,
      manufacturerName: "TestMfg",
      buildDate: "01 Jan 2025",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 915_000,
      bandwidth: 250_000,
      spreadingFactor: 10,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 20,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      manualAddContacts: false,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: false,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }

  private func makeDTO(seq: UInt32? = nil, isBackfill: Bool = false, packetPayload: Data = Data()) -> RxLogEntryDTO {
    let parsed = ParsedRxLogData(
      snr: nil,
      rssi: nil,
      rawPayload: Data(),
      routeType: .flood,
      payloadType: .unknown,
      payloadVersion: 0,
      payloadTypeBits: PayloadType.unknown.rawValue & 0x0F,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: packetPayload,
      seq: seq,
      epoch: seq.map { _ in 0x1234_5678 },
      isBackfill: isBackfill
    )
    return RxLogEntryDTO(radioID: UUID(), from: parsed)
  }

  private func row(for entry: RxLogEntryDTO) -> RxLogRowView {
    RxLogRowView(
      entry: entry,
      groupCount: 1,
      nodeIndex: .empty
    )
  }
}
