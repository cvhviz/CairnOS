import CairnServices
import Foundation
import OSLog

/// The noise floor a minute at a time, per radio, kept on disk for a week: what the Spectrum tab
/// averages into its history while it (or Home's card) is open, so a reading taken yesterday is
/// still there to export. One small JSON file per radio under Application Support.
actor SpectrumReadingsStore {
  /// One minute's average floor.
  struct Sample: Codable, Equatable, Sendable {
    /// The middle of the minute.
    let date: Date
    let dBm: Double
  }

  static let shared = SpectrumReadingsStore()
  /// How long readings are kept.
  static let retention: TimeInterval = 7 * 86400
  static let csvHeaders = ["minute_utc", "noise_floor_dbm"]

  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "SpectrumReadingsStore")

  private let directory: URL
  private var cache: [UUID: [Sample]] = [:]

  /// - Parameter directory: Where the files go; the app's Application Support by default, a
  ///   temporary folder in tests.
  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SpectrumReadings", isDirectory: true)
  }

  /// Adds a minute's reading for `radioID`, dropping what is older than ``retention``.
  func append(_ sample: Sample, radioID: UUID, now: Date = Date()) {
    var samples = load(radioID: radioID)
    // A reading for a minute already kept replaces it, so a restart within the minute can't
    // write it twice.
    samples.removeAll { abs($0.date.timeIntervalSince(sample.date)) < 30 }
    samples.append(sample)
    samples = Self.pruned(samples, now: now)
    samples.sort { $0.date < $1.date }
    cache[radioID] = samples
    save(samples, radioID: radioID)
  }

  /// The readings kept for `radioID`, oldest first.
  func samples(radioID: UUID, now: Date = Date()) -> [Sample] {
    Self.pruned(load(radioID: radioID), now: now)
  }

  /// Forgets `radioID`'s readings.
  func clear(radioID: UUID) {
    cache[radioID] = nil
    try? FileManager.default.removeItem(at: fileURL(radioID))
  }

  /// `samples` without the ones older than ``retention``.
  static func pruned(_ samples: [Sample], now: Date) -> [Sample] {
    let cutoff = now.addingTimeInterval(-retention)
    return samples.filter { $0.date >= cutoff }
  }

  /// One row per minute, oldest first.
  static func csvTable(_ samples: [Sample]) -> CSVTable {
    var table = CSVTable(headers: csvHeaders)
    for sample in samples {
      table.append([ExportFormat.timestamp(sample.date), ExportFormat.number(sample.dBm, fractionDigits: 1)])
    }
    return table
  }

  /// The readings' CSV, staged for the file exporter.
  func csvExport(radioID: UUID, now: Date = Date()) -> ExportedFile {
    let table = Self.csvTable(samples(radioID: radioID, now: now))
    return ExportedFile(
      data: table.renderData(),
      filename: "Cairn-noise-floor-\(ExportFormat.filenameStamp(now)).csv",
      contentType: .commaSeparatedText,
      recordCount: table.rows.count
    )
  }

  // MARK: - Files

  private func fileURL(_ radioID: UUID) -> URL {
    directory.appendingPathComponent("\(radioID.uuidString).json")
  }

  private func load(radioID: UUID) -> [Sample] {
    if let cached = cache[radioID] { return cached }
    guard let data = try? Data(contentsOf: fileURL(radioID)) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let samples = (try? decoder.decode([Sample].self, from: data)) ?? []
    cache[radioID] = samples
    return samples
  }

  private func save(_ samples: [Sample], radioID: UUID) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      try encoder.encode(samples).write(to: fileURL(radioID), options: [.atomic])
    } catch {
      Self.logger.error("Failed to save spectrum readings: \(error.localizedDescription)")
    }
  }
}
