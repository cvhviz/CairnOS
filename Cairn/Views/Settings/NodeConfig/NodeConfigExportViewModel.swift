import CairnServices
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class NodeConfigExportViewModel {
  var sections = ConfigSections()
  var isExporting = false
  var exportedDocument: NodeConfigDocument?
  var showFileExporter = false
  var errorMessage: String?

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodeConfigExportVM")

  /// A nil service mirrors a disconnected state and is a no-op.
  func exportConfig(nodeConfigService: NodeConfigService?, deviceNodeName: String?) async {
    guard let service = nodeConfigService else { return }

    isExporting = true
    errorMessage = nil

    do {
      let config = try await service.exportConfig(sections: sections)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(config)

      let nodeName = deviceNodeName ?? config.name ?? "unknown"
      exportedDocument = NodeConfigDocument(data: data, filename: Self.filename(for: nodeName))
      showFileExporter = true
    } catch {
      logger.error("Export failed: \(error.localizedDescription)")
      errorMessage = error.userFacingMessage
    }

    isExporting = false
  }
}

extension NodeConfigExportViewModel {
  /// "Basecamp_meshcore_config_2026-10-13-142501": the export's file name, also used when a
  /// radio config profile is shared, so both land in Files under the same pattern.
  nonisolated static func filename(for name: String, date: Date = .now) -> String {
    let sanitized = name
      .replacing(/[^a-zA-Z0-9_-]/, with: "_")
      .replacing(/^_+|_+$/, with: "")

    let timestamp = date.formatted(
      .verbatim(
        "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .current,
        calendar: .init(identifier: .gregorian)
      )
    )
    return "\(sanitized)_meshcore_config_\(timestamp)"
  }
}

/// Wraps exported JSON data for `.fileExporter`
struct NodeConfigDocument: FileDocument {
  static var readableContentTypes: [UTType] {
    [.json]
  }

  let data: Data
  let filename: String

  init(data: Data, filename: String) {
    self.data = data
    self.filename = filename
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
    filename = "config"
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
