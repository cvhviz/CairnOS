import Foundation
@testable import Cairn
import Testing

/// Staged exports hold plaintext history, so their temporary copies must not outlive their use.
@Suite("Data export cleanup")
@MainActor
struct DataExportCleanupTests {
  private func makeFile() -> ExportedFile {
    ExportedFile(
      data: Data("a,b\n1,2\n".utf8),
      filename: "Cairn-cleanup-test-\(UUID().uuidString).csv",
      contentType: .commaSeparatedText,
      recordCount: 1
    )
  }

  private func exists(_ file: ExportedFile) throws -> Bool {
    let url = try #require(file.url)
    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  @Test
  func `removing an export deletes its temporary file`() throws {
    let file = makeFile()
    #expect(try exists(file))

    file.removeTemporaryFile()

    #expect(try !exists(file))
  }

  @Test
  func `replacing the staged export deletes the previous file`() throws {
    let viewModel = DataExportViewModel()
    let first = makeFile()
    let second = makeFile()

    viewModel.exportedFile = first
    viewModel.exportedFile = second

    #expect(try !exists(first))
    #expect(try exists(second))
    viewModel.discardExport()
  }

  @Test
  func `discarding the staged export deletes its file`() throws {
    let viewModel = DataExportViewModel()
    let file = makeFile()
    viewModel.exportedFile = file

    viewModel.discardExport()

    #expect(viewModel.exportedFile == nil)
    #expect(try !exists(file))
  }

  @Test
  func `a failed save is reported and a dismissed picker is not`() {
    let viewModel = DataExportViewModel()

    viewModel.handleSaveResult(.failure(CocoaError(.userCancelled)))
    #expect(viewModel.errorMessage == nil)

    viewModel.handleSaveResult(.failure(CocoaError(.fileWriteOutOfSpace)))
    #expect(viewModel.errorMessage != nil)
  }
}
