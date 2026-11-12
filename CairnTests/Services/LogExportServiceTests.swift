import Foundation
@testable import Cairn
import Testing

@Suite("LogExportService Tests")
struct LogExportServiceTests {
  /// A scratch directory standing in for the app's temporary directory.
  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "LogExportServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  @Test
  func `Purge removes debug exports and the staged data exports`() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let olderExport = directory.appending(path: "Cairn-Debug-2026-01-01-090000.txt")
    let newerExport = directory.appending(path: "Cairn-Debug-2026-09-27-181500.txt")
    try Data("log".utf8).write(to: olderExport)
    try Data("log".utf8).write(to: newerExport)

    let dataExports = directory.appending(path: "Exports", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dataExports, withIntermediateDirectories: true)
    let stagedExport = dataExports.appending(path: "contacts.csv")
    try Data("name".utf8).write(to: stagedExport)

    LogExportService.purgeStaleExports(in: directory)

    #expect(!exists(olderExport))
    #expect(!exists(newerExport))
    #expect(!exists(stagedExport))
    #expect(!exists(dataExports))
  }

  @Test
  func `Purge leaves unrelated temporary files alone`() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let unrelated = [
      directory.appending(path: "malware-domains-cache.txt"),
      directory.appending(path: "Cairn-Debug-notes.md"),
      directory.appending(path: "Debug-Cairn-Debug-2026-01-01-090000.txt")
    ]
    for url in unrelated {
      try Data("keep".utf8).write(to: url)
    }
    let otherDirectory = directory.appending(path: "Snapshots", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

    LogExportService.purgeStaleExports(in: directory)

    for url in unrelated {
      #expect(exists(url), "\(url.lastPathComponent) should be kept")
    }
    #expect(exists(otherDirectory))
  }

  @Test
  func `Purge of a directory with nothing to remove does nothing`() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    LogExportService.purgeStaleExports(in: directory)

    #expect(exists(directory))
  }
}
