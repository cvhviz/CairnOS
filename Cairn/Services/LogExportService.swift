import Foundation
import CairnServices
import MeshCore
import OSLog
import UIKit

/// Service for exporting debug logs and app state for troubleshooting
enum LogExportService {
  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "LogExportService")

  private static let exportFilenamePrefix = "Cairn-Debug-"
  private static let exportFilenameExtension = "txt"

  /// Temporary-directory folder `ExportedFile` stages CSV and GPX data exports in.
  private static let dataExportDirectoryName = "Exports"

  /// Generates a debug export containing app logs and current state
  @MainActor
  static func generateExport(appState: AppState, persistenceStore: PersistenceStore) async -> String {
    // Flush buffered logs first so the export includes the latest lifecycle events.
    if let debugLogBuffer = DebugLogBuffer.shared {
      await debugLogBuffer.flush()
    }

    let isConnected = appState.connectedDevice != nil
    let device: DeviceDTO?
    if let connectedDevice = appState.connectedDevice {
      device = connectedDevice
    } else {
      do {
        device = try await persistenceStore.fetchActiveDevice()
      } catch {
        logger.error("Failed to fetch active device for export: \(error.localizedDescription)")
        device = nil
      }
    }

    var sections: [String] = []

    // Header
    sections.append(generateHeader())

    // Connection info
    await sections.append(generateConnectionSection(appState: appState, device: device))

    // Device info (connected or last-connected from persistence)
    if let device {
      sections.append(generateDeviceSection(device: device, isConnected: isConnected))
    }

    // Battery info
    if let battery = appState.batteryMonitor.deviceBattery {
      sections.append(generateBatterySection(battery: battery))
    }

    // Logs
    await sections.append(generateLogsSection(persistenceStore: persistenceStore))

    return sections.joined(separator: "\n\n")
  }

  /// Creates a temporary file with the export content and returns its URL
  @MainActor
  static func createExportFile(appState: AppState, persistenceStore: PersistenceStore) async -> URL? {
    let content = await generateExport(appState: appState, persistenceStore: persistenceStore)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let timestamp = formatter.string(from: Date())
    let filename = "\(exportFilenamePrefix)\(timestamp).\(exportFilenameExtension)"

    let tempURL = FileManager.default.temporaryDirectory.appending(path: filename)

    do {
      try Data(content.utf8).write(to: tempURL, options: [.atomic, .completeFileProtection])
      return tempURL
    } catch {
      logger.error("Failed to write export file: \(error.localizedDescription)")
      return nil
    }
  }

  /// Deletes the debug exports and staged data exports earlier launches left
  /// in the temporary directory. They hold logs, contacts, and message
  /// history, and the system only clears that directory when storage runs
  /// low. Called at launch, when no share of one can still be in flight.
  static func purgeStaleExports(in directory: URL = FileManager.default.temporaryDirectory) {
    let fileManager = FileManager.default
    let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for url in contents where url.lastPathComponent.hasPrefix(exportFilenamePrefix)
      && url.pathExtension == exportFilenameExtension {
      removeStaleExport(at: url)
    }

    let dataExports = directory.appending(path: dataExportDirectoryName, directoryHint: .isDirectory)
    if fileManager.fileExists(atPath: dataExports.path(percentEncoded: false)) {
      removeStaleExport(at: dataExports)
    }
  }

  private static func removeStaleExport(at url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      logger.warning("Failed to remove stale export: \(error.localizedDescription)")
    }
  }

  // MARK: - Section Generators

  @MainActor
  private static func generateHeader() -> String {
    let appVersion = Bundle.main.appVersion
    let buildNumber = Bundle.main.appBuild
    let deviceModel = UIDevice.current.model
    let systemVersion = UIDevice.current.systemVersion

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let exportedAt = formatter.string(from: Date())

    return """
    === Cairn Debug Export ===
    Exported: \(exportedAt)
    App Version: \(appVersion) (\(buildNumber))
    Device: \(deviceModel), iOS \(systemVersion)
    """
  }

  @MainActor
  private static func generateConnectionSection(appState: AppState, device: DeviceDTO?) async -> String {
    let state = appState.connectionState
    let stateString = switch state {
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .syncing: "syncing"
    case .ready: "ready"
    }

    var lines = [
      "=== Connection ===",
      "State: \(stateString)",
      "Intent: \(appState.connectionManager.connectionIntentSummary)"
    ]

    let disconnectDiagnostic =
      appState.connectionManager.lastDisconnectDiagnostic ??
      "Unavailable (no disconnect callback captured; app may have been suspended)"
    lines.append("Last Disconnect Diagnostic: \(disconnectDiagnostic)")
    await lines.append(appState.connectionManager.currentBLEDiagnosticsSummary())

    if let device {
      lines.append("Device: \(device.nodeName) (\(device.id.uuidString.prefix(8))...)")

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      lines.append("Last Connected: \(formatter.string(from: device.lastConnected))")
    }

    return lines.joined(separator: "\n")
  }

  private static func generateDeviceSection(device: DeviceDTO, isConnected: Bool) -> String {
    let frequencyMHz = Double(device.frequency) / 1000.0
    let bandwidthKHz = device.bandwidth
    let header = isConnected ? "=== Device Info ===" : "=== Device Info (Last Connected) ==="

    return """
    \(header)
    Name: \(device.nodeName)
    Firmware: \(device.firmwareVersionString) (v\(device.firmwareVersion))
    Cairn Build: \(device.cairnBuild.map(String.init) ?? "none")
    Manufacturer: \(device.manufacturerName)
    Build Date: \(device.buildDate)
    Radio: \(frequencyMHz.formatted(.number.precision(.fractionLength(3)))) MHz, BW \(bandwidthKHz) kHz, SF\(device.spreadingFactor), CR\(device.codingRate)
    TX Power: \(Self.txPowerLine(setting: Int(device.txPower), max: Int(device.maxTxPower), model: device.manufacturerName))
    Max Nodes: \(device.maxContacts)
    Max Channels: \(device.maxChannels)
    Manual Add Nodes: \(device.manualAddContacts)
    Multi-ACKs: \(device.multiAcks)
    """
  }

  /// "9 dBm setting (23 dBm at antenna), max 16 (28 dBm at antenna)" on a board with a known
  /// amplifier, "22 dBm (max 22)" on any other: both figures, so a log never mistakes one for the other.
  static func txPowerLine(setting: Int, max: Int, model: String) -> String {
    guard RadioAmplifier.hasAmplifier(model: model) else { return "\(setting) dBm (max \(max))" }
    let antenna = RadioAmplifier.effectiveTxPower(reported: setting, model: model)
    let antennaMax = RadioAmplifier.antennaMaxTxPower(reportedMax: max, model: model)
    return "\(setting) dBm setting (\(antenna) dBm at antenna), max \(max) (\(antennaMax) dBm at antenna)"
  }

  private static func generateBatterySection(battery: BatteryInfo) -> String {
    """
    === Battery ===
    Level: \(battery.percentage)%
    Voltage: \(battery.voltage.formatted(.number.precision(.fractionLength(2)))) V
    Raw: \(battery.level) mV
    """
  }

  private static func generateLogsSection(persistenceStore: PersistenceStore) async -> String {
    var lines = ["=== Logs (Last 7 Days) ==="]

    do {
      let retentionStart = Date().addingTimeInterval(-DebugLogRetention.window)
      let entries = try await persistenceStore.fetchDebugLogEntries(
        since: retentionStart,
        limit: DebugLogRetention.maxEntries
      )

      if entries.isEmpty {
        lines.append("(No logs found)")
      } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        for entry in entries {
          let timestamp = formatter.string(from: entry.timestamp)
          lines.append("\(timestamp) [\(entry.level.label)] \(entry.category): \(entry.message)")
        }

        lines.append("")
        lines.append("Total entries: \(entries.count)")
      }
    } catch {
      lines.append("(Failed to fetch logs: \(error.localizedDescription))")
      logger.error("Debug log fetch failed: \(error.localizedDescription)")
    }

    return lines.joined(separator: "\n")
  }
}
