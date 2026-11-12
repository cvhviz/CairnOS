@testable import CairnServices
import CryptoKit
import Foundation
import Testing

/// `CairnServices/radio-presets.json` is the preset catalog as data. The Cairn firmware builds its
/// on-device preset pickers from it (tools/gen_radio_presets.py in the firmware repo), so it must say
/// exactly what `RadioPresets.all`, `RadioPresets.repeatPresets` and `RadioRegion.regionsForLocale` say.
/// A preset added, removed, reordered or changed in the Swift fails here until the file follows; and,
/// when the firmware repo sits beside this one, until the firmware's copy and its generated table follow
/// the file (the firmware's own checks keep the table equal to its copy).
@Suite("radio-presets.json matches RadioPresets")
struct RadioPresetCatalogFileTests {
  private struct Catalog: Decodable {
    let schema: Int
    let regions: [String]
    let regionsForLocale: [String: [String]]
    let presets: [Entry]
    let repeatPresets: [Entry]
  }

  private struct Entry: Decodable {
    let id: String
    let name: String
    let region: String
    let frequencyMHz: Double
    let bandwidthKHz: Double
    let spreadingFactor: Int
    let codingRate: Int
    let pathHashSize: Int?
    let repeatSectionHeader: String?
    let recommendationPriority: Int
    let availability: Availability
  }

  private struct Availability: Decodable {
    struct Area: Decodable { let country: String; let areas: [String] }
    struct Counties: Decodable { let country: String; let state: String; let keys: [String] }
    let continent: String?
    let countries: [String]?
    let subRegions: Area?
    let counties: Counties?

    func value() -> PresetAvailability? {
      let set = [continent != nil, countries != nil, subRegions != nil, counties != nil].filter { $0 }
      guard set.count == 1 else { return nil }
      if let continent, let r = RadioRegion(rawValue: continent) { return .continent(r) }
      if let countries { return .countries(Set(countries)) }
      if let subRegions { return .subRegions(country: subRegions.country, areas: Set(subRegions.areas)) }
      if let counties {
        return .counties(country: counties.country, state: counties.state, keys: Set(counties.keys))
      }
      return nil
    }
  }

  private static let fileURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // CairnServicesTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // CairnServices
    .appendingPathComponent("radio-presets.json")

  private static func load() throws -> Catalog {
    try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: fileURL))
  }

  /// The Cairn firmware repo: $CAIRN_FIRMWARE_DIR, else "CAIRN firmware - Meshcore" beside "CAIRN OS";
  /// nil when it is not there (CI, a checkout of the app alone).
  private static let firmwareDir: URL? = {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["CAIRN_FIRMWARE_DIR"], !env.isEmpty {
      return fm.fileExists(atPath: env) ? URL(fileURLWithPath: env) : nil
    }
    let beside = fileURL
      .deletingLastPathComponent() // CairnServices
      .deletingLastPathComponent() // Cairn
      .deletingLastPathComponent() // CAIRN OS
      .deletingLastPathComponent() // the folder both repos sit in
      .appendingPathComponent("CAIRN firmware - Meshcore")
    let copy = beside.appendingPathComponent("examples/companion_radio/radio-presets.json")
    return fm.fileExists(atPath: copy.path) ? beside : nil
  }()

  private static func expectSame(_ file: [Entry], _ swift: [RadioPreset]) {
    #expect(file.map(\.id) == swift.map(\.id), "ids or their order differ")
    for (e, p) in zip(file, swift) {
      #expect(e.id == p.id)
      #expect(e.name == p.name, "\(p.id): name")
      #expect(e.region == p.region.rawValue, "\(p.id): region")
      #expect(e.frequencyMHz == p.frequencyMHz, "\(p.id): frequency")
      #expect(e.bandwidthKHz == p.bandwidthKHz, "\(p.id): bandwidth")
      #expect(e.spreadingFactor == Int(p.spreadingFactor), "\(p.id): SF")
      #expect(e.codingRate == Int(p.codingRate), "\(p.id): CR")
      #expect(e.pathHashSize == p.pathHashSize, "\(p.id): path hash size")
      #expect(e.repeatSectionHeader == p.repeatSectionHeader, "\(p.id): repeat section header")
      #expect(e.recommendationPriority == p.recommendationPriority, "\(p.id): priority")
      #expect(e.availability.value() == p.availability, "\(p.id): availability")
    }
  }

  @Test
  func `the file's presets are RadioPresets.all, in order, field for field`() throws {
    let file = try Self.load()
    #expect(file.schema == 1)
    Self.expectSame(file.presets, RadioPresets.all)
  }

  @Test
  func `the file's repeat presets are RadioPresets.repeatPresets`() throws {
    Self.expectSame(try Self.load().repeatPresets, RadioPresets.repeatPresets)
  }

  @Test
  func `the file's regions are RadioRegion.allCases in order`() throws {
    #expect(try Self.load().regions == RadioRegion.allCases.map(\.rawValue))
  }

  @Test(.enabled(if: firmwareDir != nil, "the Cairn firmware repo is not beside the app"))
  func `the firmware's copy is this file byte for byte, and its preset table was generated from it`() throws {
    let dir = try #require(Self.firmwareDir)
    let mine = try Data(contentsOf: Self.fileURL)
    let copy = try Data(contentsOf: dir.appendingPathComponent("examples/companion_radio/radio-presets.json"))
    #expect(
      copy == mine,
      "the firmware's examples/companion_radio/radio-presets.json differs: run tools/gen_radio_presets.py --from-app there"
    )
    // RadioPresetTable.h names the catalog it was generated from by its SHA-256
    let header = try String(
      contentsOf: dir.appendingPathComponent("examples/companion_radio/RadioPresetTable.h"),
      encoding: .utf8
    )
    let line = try #require(header.split(separator: "\n").first { $0.hasPrefix("constexpr char CATALOG_SHA256[]") })
    let parts = line.split(separator: "\"")
    try #require(parts.count >= 2)
    let sha = SHA256.hash(data: mine).map { String(format: "%02x", $0) }.joined()
    #expect(
      String(parts[1]) == sha,
      "the firmware's RadioPresetTable.h was generated from another catalog: run tools/gen_radio_presets.py --from-app there"
    )
  }

  @Test
  func `the file's locale orders are regionsForLocale's`() throws {
    let file = try Self.load()
    for (code, order) in file.regionsForLocale {
      let swift = RadioRegion.regionsForLocale(Locale(identifier: "en_\(code)")).map(\.rawValue)
      #expect(swift == order, "regionsForLocale(\(code))")
    }
    // every country the Swift gives an order of its own is listed; any other gets allCases (the file's regions)
    for region in Locale.Region.isoRegions where region.identifier.count == 2 {
      let code = region.identifier
      let swift = RadioRegion.regionsForLocale(Locale(identifier: "en_\(code)")).map(\.rawValue)
      if file.regionsForLocale[code] == nil {
        #expect(swift == file.regions, "regionsForLocale(\(code)) has its own order: list it in the file")
      }
    }
  }
}
