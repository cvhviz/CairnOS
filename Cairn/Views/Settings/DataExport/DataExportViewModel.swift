import Foundation
import CairnServices
import UniformTypeIdentifiers

/// Drives the Settings > Backup & Restore > Export Data screen.
@Observable
@MainActor
final class DataExportViewModel {
  enum Kind: Hashable {
    case messages
    case contacts
    case nodeStatus
    case rxLog
    case waypoints
  }

  private(set) var conversations: [DataExportService.Conversation] = []
  var selectedScope: DataExportService.MessageScope = .all
  private(set) var exporting: Kind?
  var exportedFile: ExportedFile? {
    didSet {
      if let oldValue, oldValue.id != exportedFile?.id {
        oldValue.removeTemporaryFile()
      }
    }
  }

  var errorMessage: String?

  private var service: DataExportService?
  private var radioID: UUID?
  private var ownName: String?
  private var rxLogService: RxLogService?

  func configure(
    store: PersistenceStore,
    radioID: UUID,
    ownName: String?,
    rxLogService: RxLogService?,
    neighbourService: NeighbourService? = nil
  ) async {
    // The live neighbour service names RX log hops from the ledger in memory; without it the
    // export reads the stored ledger, which can trail the radio by one flush.
    service = DataExportService(store: store, neighbourService: neighbourService)
    self.radioID = radioID
    self.ownName = ownName
    self.rxLogService = rxLogService
    do {
      conversations = try await service?.conversations(radioID: radioID) ?? []
    } catch {
      conversations = []
    }
    if case .all = selectedScope {} else if !conversations.contains(where: { $0.scope == selectedScope }) {
      selectedScope = .all
    }
  }

  func export(_ kind: Kind) {
    guard exporting == nil, let service, let radioID else { return }
    exporting = kind
    exportedFile = nil
    Task {
      defer { exporting = nil }
      do {
        let file = try await makeFile(kind, service: service, radioID: radioID)
        // The radio changed while this ran; the file belongs to the one no longer shown.
        guard self.radioID == radioID else {
          file.removeTemporaryFile()
          return
        }
        if file.recordCount == 0 {
          errorMessage = L10n.Settings.Settings.DataExport.empty
        } else {
          exportedFile = file
        }
      } catch {
        errorMessage = L10n.Settings.Settings.DataExport.error(error.userFacingMessage)
      }
    }
  }

  /// Drops the staged export and its temporary file, once the screen that offered it is gone.
  func discardExport() {
    exportedFile = nil
  }

  /// Reports a failed save to Files. Dismissing the picker is not a failure.
  func handleSaveResult(_ result: Result<URL, Error>) {
    guard case let .failure(error) = result else { return }
    let nsError = error as NSError
    guard nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError else { return }
    errorMessage = L10n.Settings.Settings.DataExport.error(error.userFacingMessage)
  }

  private func makeFile(_ kind: Kind, service: DataExportService, radioID: UUID) async throws -> ExportedFile {
    let stamp = ExportFormat.filenameStamp()
    switch kind {
    case .messages:
      let table = try await service.messagesCSV(radioID: radioID, scope: selectedScope, ownName: ownName)
      return csvFile(table, name: "messages-\(scopeSlug)", stamp: stamp)
    case .contacts:
      return try await csvFile(service.contactsCSV(radioID: radioID), name: "contacts", stamp: stamp)
    case .nodeStatus:
      return try await csvFile(service.nodeStatusCSV(radioID: radioID), name: "node-status", stamp: stamp)
    case .rxLog:
      return try await csvFile(service.rxLogCSV(radioID: radioID, rxLogService: rxLogService), name: "rx-log", stamp: stamp)
    case .waypoints:
      let result = try await service.waypointsGPX(radioID: radioID)
      return ExportedFile(
        data: Data(result.gpx.utf8),
        filename: "Cairn-nodes-\(stamp).gpx",
        contentType: .gpx,
        recordCount: result.count
      )
    }
  }

  private func csvFile(_ table: CSVTable, name: String, stamp: String) -> ExportedFile {
    ExportedFile(
      data: table.renderData(),
      filename: "Cairn-\(name)-\(stamp).csv",
      contentType: .commaSeparatedText,
      recordCount: table.rows.count
    )
  }

  /// Filename-safe slug of the selected conversation.
  private var scopeSlug: String {
    guard let title = conversations.first(where: { $0.scope == selectedScope })?.title else { return "all" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let slug = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "conversation" : String(slug.prefix(40))
  }
}
