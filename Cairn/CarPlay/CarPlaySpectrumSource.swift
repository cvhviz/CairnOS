import CairnServices
import Foundation
import MeshCore

/// The last minute or so of the radio's statistics, enough for the Spectrum tab's glance: the
/// floor and its trend, the last packet, and the channel's airtime share. Pure, so the tests feed it
/// readings and dates. The trend and the airtime share use the app's own rules (`NoiseTrend`,
/// `SpectrumStats.airtimeShare`).
struct CarPlaySpectrumSamples: Equatable {
  /// How far back readings are kept: long enough for the airtime share's 30-second minimum and a
  /// trend over several readings at the car's 10-second pace.
  static let window: TimeInterval = 70

  private(set) var noise: [NoiseSample] = []
  private(set) var airtime: [AirtimeSample] = []
  /// The radio's floor hasn't converged yet (it reports 0 until then, and nothing at or above
  /// -40 dBm counts).
  private(set) var isCalibrating = false
  private(set) var lastRSSI: Int?
  private(set) var lastSNR: Double?
  private(set) var latest: Date?

  mutating func append(_ stats: RadioStats, at date: Date) {
    latest = date
    // Cairn's rule, as the phone's: only a reading under -40 dBm is a floor.
    if SpectrumStats.acceptsFloor(Double(stats.noiseFloor)) {
      isCalibrating = false
      noise.append(NoiseSample(date: date, dBm: Double(stats.noiseFloor)))
    } else {
      isCalibrating = true
    }
    airtime.append(AirtimeSample(date: date, tx: stats.txAirtimeSeconds, rx: stats.rxAirtimeSeconds))
    if stats.lastRSSI != 0 {
      lastRSSI = Int(stats.lastRSSI)
      lastSNR = stats.lastSNR
    }
    let start = date.addingTimeInterval(-Self.window)
    noise.removeAll { $0.date < start }
    airtime.removeAll { $0.date < start }
  }

  mutating func reset() {
    self = CarPlaySpectrumSamples()
  }

  var noiseFloor: Double? {
    noise.last?.dBm
  }

  var trend: NoiseTrend? {
    noise.isEmpty ? nil : NoiseTrend(readings: noise.map(\.dBm))
  }

  /// Share of the window spent receiving and transmitting; nil under 30 seconds of readings or
  /// across a radio restart (a counter going backwards).
  var airtimeShare: (rx: Double, tx: Double)? {
    guard let latest else { return nil }
    return SpectrumStats.airtimeShare(airtime, window: Self.window, now: latest)
  }
}

/// Reads the radio's statistics every `CarPlayRefreshGate.dataInterval` while the Spectrum tab is
/// open, and only then: one small request per interval, the pace a driving screen should change
/// at. Firmware without the stats command (official MeshCore companion firmware before v1.11)
/// answers unsupported: reading stops for that radio and ``isUnsupported`` says so. The fetch and
/// the wait are injected so the tests run it without a radio or a clock.
@MainActor
final class CarPlaySpectrumSource {
  typealias Fetch = @MainActor () async throws -> RadioStats
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private(set) var samples = CarPlaySpectrumSamples()
  private(set) var isRunning = false
  /// The radio answered that it has no stats command: nothing is read again until ``reset()``.
  private(set) var isUnsupported = false
  /// Called on the main actor after each reading, and once when the radio turns out unsupported.
  var onUpdate: (() -> Void)?

  private let fetch: Fetch
  private let sleep: Sleep
  private let now: () -> Date
  private let interval: Duration
  private var task: Task<Void, Never>?

  init(interval: Duration, fetch: @escaping Fetch, sleep: @escaping Sleep, now: @escaping () -> Date) {
    self.interval = interval
    self.fetch = fetch
    self.sleep = sleep
    self.now = now
  }

  /// What the radio would answer `CMD_GET_STATS` with when its firmware is known to lack it
  /// (``DeviceDTO/supportsStats``, official companion firmware before v1.11): the unsupported
  /// error, so nothing is sent. Nil when the radio can be asked or none is known.
  nonisolated static func knownRefusal(for device: DeviceDTO?) -> MeshCoreError? {
    guard let device, !device.supportsStats else { return nil }
    return .deviceError(code: ErrorCode.unsupportedCommand.rawValue)
  }

  /// Reads every data interval on the real clock.
  convenience init(fetch: @escaping Fetch) {
    self.init(
      interval: CarPlayRefreshGate.dataInterval,
      fetch: fetch,
      sleep: { try await Task.sleep(for: $0) },
      now: { Date() }
    )
  }

  func start() {
    guard !isRunning, !isUnsupported else { return }
    isRunning = true
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.isRunning else { return }
        await self.readOnce()
        do {
          try await self.sleep(self.interval)
        } catch {
          return
        }
      }
    }
  }

  func stop() {
    isRunning = false
    task?.cancel()
    task = nil
  }

  /// Forgets the readings and whether the radio has statistics, for a different radio or a new
  /// link.
  func reset() {
    samples.reset()
    isUnsupported = false
  }

  private func readOnce() async {
    guard isRunning else { return }
    let stats: RadioStats
    do {
      stats = try await fetch()
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      guard isRunning, !Task.isCancelled else { return }
      isUnsupported = true
      stop()
      onUpdate?()
      return
    } catch {
      return
    }
    guard isRunning, !Task.isCancelled else { return }
    samples.append(stats, at: now())
    onUpdate?()
  }
}
