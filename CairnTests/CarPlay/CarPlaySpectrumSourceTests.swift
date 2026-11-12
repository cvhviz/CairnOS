import CairnServices
import Foundation
@testable import Cairn
import MeshCore
import Testing

@Suite("CarPlaySpectrumSource")
struct CarPlaySpectrumSourceTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func stats(floor: Int16 = -110, rssi: Int8 = -80, snr: Double = 6, tx: UInt32 = 0, rx: UInt32 = 0) -> RadioStats {
    RadioStats(noiseFloor: floor, lastRSSI: rssi, lastSNR: snr, txAirtimeSeconds: tx, rxAirtimeSeconds: rx)
  }

  @Test
  func `The busy share comes from the counters' deltas`() {
    var samples = CarPlaySpectrumSamples()
    samples.append(stats(tx: 100, rx: 200), at: start)
    samples.append(stats(tx: 103, rx: 212), at: start.addingTimeInterval(20))
    #expect(samples.airtimeShare == nil, "under 30 seconds")
    samples.append(stats(tx: 106, rx: 224), at: start.addingTimeInterval(40))
    let share = samples.airtimeShare
    #expect(share.map { ($0.rx * 100).rounded() } == 60)
    #expect(share.map { ($0.tx * 100).rounded() } == 15)
  }

  @Test
  func `A radio restart drops the busy share until it has 30 seconds again`() {
    var samples = CarPlaySpectrumSamples()
    samples.append(stats(tx: 100, rx: 200), at: start)
    samples.append(stats(tx: 110, rx: 220), at: start.addingTimeInterval(40))
    #expect(samples.airtimeShare != nil)
    samples.append(stats(tx: 1, rx: 2), at: start.addingTimeInterval(50))
    #expect(samples.airtimeShare == nil)
  }

  @Test
  func `Old readings fall out of the window`() {
    var samples = CarPlaySpectrumSamples()
    samples.append(stats(floor: -100), at: start)
    samples.append(stats(floor: -110), at: start.addingTimeInterval(CarPlaySpectrumSamples.window + 10))
    #expect(samples.noise.count == 1)
    #expect(samples.noiseFloor == -110)
  }

  @Test
  func `The trend follows the app's rule`() {
    func trend(_ floors: [Int16]) -> NoiseTrend? {
      var samples = CarPlaySpectrumSamples()
      for (index, floor) in floors.enumerated() {
        samples.append(stats(floor: floor), at: start.addingTimeInterval(Double(index) * 10))
      }
      return samples.trend
    }
    #expect(trend([-110, -110, -110, -110]) == .steady)
    #expect(trend([-115, -115, -105, -105]) == .rising)
    #expect(trend([-100, -100, -112, -112]) == .falling)
    #expect(trend([]) == nil)
  }

  @Test
  func `An unconverged floor reads as calibrating and keeps the last packet`() {
    var samples = CarPlaySpectrumSamples()
    samples.append(stats(floor: 0, rssi: -70, snr: 4.5), at: start)
    #expect(samples.isCalibrating)
    #expect(samples.noiseFloor == nil)
    #expect(samples.lastRSSI == -70)
    samples.append(stats(floor: -112, rssi: 0), at: start.addingTimeInterval(10))
    #expect(!samples.isCalibrating)
    #expect(samples.lastRSSI == -70, "a zero RSSI means no packet yet")
  }

  @Test
  func `Only a floor under -40 dBm counts, as on Cairn`() {
    var samples = CarPlaySpectrumSamples()
    samples.append(stats(floor: -40), at: start)
    #expect(samples.isCalibrating)
    #expect(samples.noiseFloor == nil)
    samples.append(stats(floor: -41), at: start.addingTimeInterval(10))
    #expect(!samples.isCalibrating)
    #expect(samples.noiseFloor == -41)
  }

  @Test
  func `The condition steps at 3 and 10 dB above thermal noise`() {
    #expect(ChannelCondition(desensitization: 2.9) == .quiet)
    #expect(ChannelCondition(desensitization: 3) == .someInterference)
    #expect(ChannelCondition(desensitization: 10) == .heavyInterference)
  }

  @Test
  @MainActor
  func `The radio is read only between start and stop`() async {
    var fetches = 0
    let source = CarPlaySpectrumSource(
      interval: .seconds(10),
      fetch: {
        fetches += 1
        return RadioStats(noiseFloor: -110, lastRSSI: -80, lastSNR: 5, txAirtimeSeconds: 0, rxAirtimeSeconds: 0)
      },
      // The test's clock never moves: one read per start, then the wait.
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    await Task.yield()
    #expect(fetches == 0)

    var updates = 0
    source.onUpdate = { updates += 1 }
    source.start()
    for _ in 0 ..< 50 where fetches == 0 {
      await Task.yield()
    }
    #expect(fetches == 1)
    #expect(updates == 1)
    #expect(source.samples.noiseFloor == -110)

    source.stop()
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    #expect(fetches == 1)
    #expect(!source.isRunning)
  }

  @Test
  @MainActor
  func `Firmware without the stats command stops the reads until reset`() async {
    // Official companion firmware before v1.11 answers CMD_GET_STATS with [0x01][0x01]
    var fetches = 0
    var unsupported = true
    let source = CarPlaySpectrumSource(
      interval: .seconds(10),
      fetch: {
        fetches += 1
        if unsupported { throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue) }
        return RadioStats(noiseFloor: -110, lastRSSI: -80, lastSNR: 5, txAirtimeSeconds: 0, rxAirtimeSeconds: 0)
      },
      // Any further read would come straight after the wait, so a loop still running would show
      sleep: { _ in await Task.yield() },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    var updates = 0
    source.onUpdate = { updates += 1 }
    source.start()
    for _ in 0 ..< 50 where !source.isUnsupported {
      await Task.yield()
    }
    #expect(source.isUnsupported)
    #expect(!source.isRunning)
    #expect(updates == 1, "the screen hears once that nothing will come")
    for _ in 0 ..< 50 {
      await Task.yield()
    }
    #expect(fetches == 1)

    // Opening the tab again asks nothing of the same radio
    source.start()
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    #expect(fetches == 1)
    #expect(!source.isRunning)

    // Another radio or a new link asks again
    unsupported = false
    source.reset()
    #expect(!source.isUnsupported)
    source.start()
    for _ in 0 ..< 50 where fetches == 1 {
      await Task.yield()
    }
    #expect(fetches >= 2)
    #expect(source.samples.noiseFloor == -110)
    source.stop()
  }

  @Test
  @MainActor
  func `A read that fails for another reason keeps reading`() async {
    var fetches = 0
    let source = CarPlaySpectrumSource(
      interval: .seconds(10),
      fetch: {
        fetches += 1
        throw MeshCoreError.timeout
      },
      sleep: { _ in await Task.yield() },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    source.start()
    for _ in 0 ..< 200 where fetches < 3 {
      await Task.yield()
    }
    #expect(fetches >= 3)
    #expect(!source.isUnsupported)
    #expect(source.isRunning)
    source.stop()
  }

  // MARK: - Firmware without statistics

  private func readyInputs() -> CarPlayInputs {
    var inputs = CarPlayInputs()
    inputs.connectionState = .ready
    inputs.isRadioReady = true
    return inputs
  }

  /// A packet the RX log recorded, as official firmware's 0x88 frame reports it.
  private func rxLogPacket(rssi: Int?, snr: Double?) -> SpectrumPacket {
    let parsed = ParsedRxLogData(
      snr: snr,
      rssi: rssi,
      rawPayload: Data([0x11, 0x00, 0x01, 0x02]),
      routeType: .flood,
      payloadType: .advert,
      payloadVersion: 0,
      payloadTypeBits: PayloadType.advert.rawValue,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data([0x01, 0x02])
    )
    return SpectrumPacket(entry: RxLogEntryDTO(radioID: UUID(), receivedAt: start, from: parsed))
  }

  /// A connected radio as official companion firmware reports itself in DEVICE_INFO.
  private func device(firmwareVersion: UInt8, firmwareVersionString: String) -> DeviceDTO {
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

  @Test
  func `Without statistics the readings they fill say so, but the last packet comes from the RX log`() {
    var state = CarPlayInputs.SpectrumState()
    state.statsUnsupported = true
    // The controller's step: v1.7 to v1.10 still push each packet's RSSI and SNR as 0x88
    state.fillLastPacket(from: rxLogPacket(rssi: -97, snr: 7.5))
    #expect(state.lastRSSI == -97)
    #expect(state.lastSNR == 7.5)

    let rows = CarPlaySnapshotBuilder.spectrum(state, inputs: readyInputs())
    let unsupported = L10n.Localizable.CarPlay.Spectrum.unsupported
    #expect(rows[0].title == L10n.Localizable.CarPlay.Spectrum.condition)
    #expect(rows[0].detail == unsupported)
    #expect(rows[1].title == L10n.Tools.Tools.Spectrum.Figure.noiseFloor)
    #expect(rows[1].detail == unsupported)
    #expect(rows[2].title == L10n.Tools.Tools.Spectrum.Figure.lastPacket)
    #expect(rows[2].detail.contains(L10n.Tools.Tools.Spectrum.Value.dbm((-97.0).formatted(.number.precision(.fractionLength(0))))))
    #expect(rows[2].detail.contains(L10n.Tools.Tools.Spectrum.Detail.snr(7.5.formatted(.number.precision(.fractionLength(1))))))
    #expect(rows[3].title == L10n.Tools.Tools.Spectrum.Figure.airtime)
    #expect(rows[3].detail == unsupported)
    #expect(CarPlayCardBuilder.spectrumHeader(state).condition == unsupported)
  }

  @Test
  func `Without statistics or a packet yet the last packet waits, never blaming the firmware`() {
    var state = CarPlayInputs.SpectrumState()
    state.statsUnsupported = true
    state.fillLastPacket(from: nil)
    let rows = CarPlaySnapshotBuilder.spectrum(state, inputs: readyInputs())
    #expect(rows[2].detail == L10n.Tools.Tools.Spectrum.waitingForPacket)

    // With statistics the header measures instead
    state.statsUnsupported = false
    #expect(CarPlayCardBuilder.spectrumHeader(state).condition == L10n.Tools.Tools.Spectrum.measuring)
  }

  @Test
  func `The statistics' own last packet comes first`() {
    var state = CarPlayInputs.SpectrumState()
    state.lastRSSI = -80
    state.lastSNR = 5
    state.fillLastPacket(from: rxLogPacket(rssi: -97, snr: 7.25))
    #expect(state.lastRSSI == -80)
    #expect(state.lastSNR == 5)

    // A packet without a signal reading fills nothing
    var empty = CarPlayInputs.SpectrumState()
    empty.fillLastPacket(from: rxLogPacket(rssi: nil, snr: nil))
    #expect(empty.lastRSSI == nil)
  }

  @Test
  func `Firmware known to lack the stats command is refused before anything is sent`() {
    // FIRMWARE_VER_CODE 8 covers both v1.10.0 (no CMD_GET_STATS) and v1.11.0 (has it)
    let refusal = CarPlaySpectrumSource.knownRefusal(for: device(firmwareVersion: 8, firmwareVersionString: "v1.10.0"))
    guard case let .deviceError(code) = refusal else {
      Issue.record("v1.10 should be refused as unsupported, got \(String(describing: refusal))")
      return
    }
    #expect(code == ErrorCode.unsupportedCommand.rawValue)
    #expect(CarPlaySpectrumSource.knownRefusal(for: device(firmwareVersion: 5, firmwareVersionString: "v1.7.0")) != nil)
    #expect(CarPlaySpectrumSource.knownRefusal(for: device(firmwareVersion: 8, firmwareVersionString: "v1.11.0")) == nil)
    #expect(CarPlaySpectrumSource.knownRefusal(for: device(firmwareVersion: 14, firmwareVersionString: "v1.18.0")) == nil)
    #expect(CarPlaySpectrumSource.knownRefusal(for: nil) == nil, "no radio known: the read decides")
  }
}
