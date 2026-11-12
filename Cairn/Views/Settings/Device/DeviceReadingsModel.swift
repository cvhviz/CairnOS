import CairnServices
import MeshCore
import SwiftUI

/// The on-demand readings pulled from the radio: the `CMD_GET_STATS` counters (firmware v8+) and
/// the radio's own LPP sensor telemetry. Each group loads and fails on its own, since older
/// firmware lacks some or all of them. Home reads the uptime, noise floor and sensors; Device Info
/// shows the counters and sensors Spectrum and Battery don't.
@Observable
@MainActor
final class DeviceReadingsModel {
  private(set) var core: CoreStats?
  private(set) var radio: RadioStats?
  private(set) var packets: PacketStats?
  /// Why the last stats read came back short, if it did.
  private(set) var statsIssue: DeviceReadingIssue?

  private(set) var sensors: [LPPDataPoint] = []
  private(set) var sensorsLoaded = false
  private(set) var sensorsIssue: DeviceReadingIssue?

  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var lastUpdated: Date?

  /// Reads every group once. Sequential: the session serializes requests anyway.
  func load(settingsService: SettingsService?, binaryProtocolService: BinaryProtocolService?) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    if let settingsService {
      guard await loadStats(settingsService) else { return }
    } else {
      statsIssue = .unavailable
    }

    if let binaryProtocolService {
      guard await loadSensors(binaryProtocolService) else { return }
    } else {
      sensorsIssue = .unavailable
    }

    hasLoaded = true
    lastUpdated = .now
  }

  /// The simulator radio's readings: its telemetry frame decoded as the radio's own would be. The
  /// mock transport answers no commands, so there are no counters to read.
  func loadSimulated(telemetry: Data) {
    sensors = LPPDecoder.decode(telemetry)
    sensorsLoaded = true
    sensorsIssue = nil
    statsIssue = .unavailable
    hasLoaded = true
    lastUpdated = .now
  }

  /// Returns false when cancelled, so the caller stops without stamping a refresh.
  private func loadStats(_ service: SettingsService) async -> Bool {
    // A read that fails keeps the last good figures; the issue only says the refresh came up short.
    var issues: [DeviceReadingIssue] = []
    do {
      core = try await service.getStatsCore()
    } catch is CancellationError {
      return false
    } catch {
      issues.append(DeviceReadingIssue(error))
    }
    do {
      radio = try await service.getStatsRadio()
    } catch is CancellationError {
      return false
    } catch {
      issues.append(DeviceReadingIssue(error))
    }
    do {
      packets = try await service.getStatsPackets()
    } catch is CancellationError {
      return false
    } catch {
      issues.append(DeviceReadingIssue(error))
    }
    statsIssue = DeviceReadingIssue.worst(of: issues)
    return true
  }

  private func loadSensors(_ service: BinaryProtocolService) async -> Bool {
    do {
      let response = try await service.getSelfTelemetry()
      sensors = LPPDecoder.decode(response.rawData)
      sensorsLoaded = true
      sensorsIssue = nil
    } catch is CancellationError {
      return false
    } catch {
      sensorsIssue = DeviceReadingIssue(error)
    }
    return true
  }
}

// MARK: - Issues

/// Why a reading is missing, reduced to what the page should say about it. Raw error text
/// ("MeshTransportError error 2") means nothing to a reader, so it never reaches the screen.
enum DeviceReadingIssue: Equatable {
  /// The request timed out: the radio may answer if asked again.
  case noAnswer
  /// The firmware doesn't support the request, or it failed in a way a retry won't fix. The page
  /// leaves the group out rather than explaining.
  case unavailable

  init(_ error: Error) {
    self = Self.isTimeout(error) ? .noAnswer : .unavailable
  }

  /// A timeout outranks the rest: one group answering slowly is worth a refresh.
  static func worst(of issues: [DeviceReadingIssue]) -> DeviceReadingIssue? {
    issues.contains(.noAnswer) ? .noAnswer : issues.first
  }

  private static func isTimeout(_ error: Error) -> Bool {
    switch error {
    case MeshCoreError.timeout,
         SettingsServiceError.sessionError(MeshCoreError.timeout),
         BinaryProtocolError.timeout,
         BinaryProtocolError.sessionError(MeshCoreError.timeout):
      true
    default:
      false
    }
  }
}

// MARK: - What Device Info shows

/// The counters the radio keeps since it last booted that no other page shows. Spectrum owns the
/// live radio figures (noise floor, signal, airtime), so only these totals stay on Device Info.
enum DeviceLifetimeCounter: CaseIterable, Equatable {
  case uptime
  case received
  case sent
  case receiveErrors

  /// The counters to lay out: all of them as "—" placeholders until the first read lands, then
  /// only those the radio reported. Empty means the page leaves the group out.
  static func shown(hasCore: Bool, hasPackets: Bool, hasLoaded: Bool) -> [DeviceLifetimeCounter] {
    guard hasLoaded else { return allCases }
    var counters: [DeviceLifetimeCounter] = []
    if hasCore { counters.append(.uptime) }
    if hasPackets { counters += [.received, .sent, .receiveErrors] }
    return counters
  }
}

extension DeviceReadingsModel {
  /// The LPP channel the radio reports its own readings on; its voltage is the battery.
  static let selfTelemetryChannel: UInt8 = 1

  /// Sensor readings grouped by LPP channel, lowest channel first, without the battery voltage,
  /// which has its own page.
  static func displayedSensorGroups(_ sensors: [LPPDataPoint]) -> [(channel: UInt8, dataPoints: [LPPDataPoint])] {
    let shown = sensors.filter { !($0.type == .voltage && $0.channel == selfTelemetryChannel) }
    return Dictionary(grouping: shown, by: \.channel)
      .sorted { $0.key < $1.key }
      .map { (channel: $0.key, dataPoints: $0.value) }
  }

  var displayedSensorGroups: [(channel: UInt8, dataPoints: [LPPDataPoint])] {
    Self.displayedSensorGroups(sensors)
  }

  var lifetimeCounters: [DeviceLifetimeCounter] {
    DeviceLifetimeCounter.shown(hasCore: core != nil, hasPackets: packets != nil, hasLoaded: hasLoaded)
  }

  /// A timed-out read left a group empty, so the page says the radio didn't answer. A group the
  /// firmware doesn't support is simply left out.
  var radioDidNotAnswer: Bool {
    let statsMissing = hasLoaded && core == nil && packets == nil && statsIssue == .noAnswer
    let sensorsMissing = !sensorsLoaded && sensorsIssue == .noAnswer
    return statsMissing || sensorsMissing
  }
}
