import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  /// GPX 1.1 track/waypoint exchange format.
  static let gpx = UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml
}

/// A generated CSV or GPX export, written to a temporary file so it can be handed to
/// `ShareLink` (a file URL) and `fileExporter` (the document) alike.
struct ExportedFile: Identifiable, Equatable {
  let id = UUID()
  let data: Data
  let filename: String
  let contentType: UTType
  let recordCount: Int

  /// Temporary copy for sharing; nil if the write failed.
  let url: URL?

  init(data: Data, filename: String, contentType: UTType, recordCount: Int) {
    self.data = data
    self.filename = filename
    self.contentType = contentType
    self.recordCount = recordCount
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(filename)
    url = (try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])) == nil ? nil : fileURL
  }

  /// Deletes the temporary copy. Exports hold plaintext contacts and message history, and the
  /// system only clears the temporary directory when storage runs low.
  func removeTemporaryFile() {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }

  var document: ExportFileDocument {
    ExportFileDocument(data: data, contentType: contentType)
  }
}

/// Write-only document for `fileExporter`.
struct ExportFileDocument: FileDocument {
  static var readableContentTypes: [UTType] {
    [.commaSeparatedText, .gpx]
  }

  static var writableContentTypes: [UTType] {
    [.commaSeparatedText, .gpx]
  }

  let data: Data
  let contentType: UTType

  init(data: Data, contentType: UTType) {
    self.data = data
    self.contentType = contentType
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
    contentType = configuration.contentType
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
