import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let cairnBackup = UTType(exportedAs: "cvhvisuals.Cairn.backup")
}

struct AppBackupDocument: FileDocument {
  static var readableContentTypes: [UTType] {
    [.cairnBackup]
  }

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
