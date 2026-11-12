import CairnUpdateKit
import Foundation

/// Whether a board's build is behind the latest Cairn release: the one comparison the Bluetooth
/// update sheet, the Wi-Fi updater and a repeater's Device card all make.
enum FirmwareUpdateCheck {
  /// Nil when either side has no build number (a stock MeshCore version string, no release known).
  static func updateAvailable(installed: String?, latestBuild: Int?) -> Bool? {
    updateAvailable(installedBuild: installed.flatMap(cairnBuildNumber), latestBuild: latestBuild)
  }

  static func updateAvailable(installedBuild: Int?, latestBuild: Int?) -> Bool? {
    guard let installedBuild, let latestBuild else { return nil }
    return latestBuild > installedBuild
  }

  /// Whether `version` is a Cairn build at all (has a build number), as against stock MeshCore.
  static func isCairnBuild(_ version: String?) -> Bool {
    version.flatMap(cairnBuildNumber) != nil
  }
}

/// The latest Cairn release's build number, kept from the last time any update page fetched it, so
/// a repeater's Device card can say "Update available" without a request of its own.
enum LatestFirmwareBuildCache {
  private static let buildKey = "latestCairnReleaseBuild"
  private static let dateKey = "latestCairnReleaseBuild.fetchedAt"

  /// A fetch older than this is worth repeating when a page has the chance.
  static let maxAge: TimeInterval = 24 * 3600

  static func latestBuild(defaults: UserDefaults = .standard) -> Int? {
    let build = defaults.integer(forKey: buildKey)
    return build > 0 ? build : nil
  }

  static func fetchedAt(defaults: UserDefaults = .standard) -> Date? {
    defaults.object(forKey: dateKey) as? Date
  }

  static func isStale(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
    guard let fetchedAt = fetchedAt(defaults: defaults) else { return true }
    return now.timeIntervalSince(fetchedAt) > maxAge
  }

  static func record(build: Int?, now: Date = .now, defaults: UserDefaults = .standard) {
    guard let build, build > 0 else { return }
    defaults.set(build, forKey: buildKey)
    defaults.set(now, forKey: dateKey)
  }
}

/// A node's firmware version string taken apart for display: "v1.10.0-cairn107 (Build: 07-Nov-2026)"
/// reads "Cairn 107", based on "MeshCore v1.10.0", built "07-Nov-2026". A stock version has no Cairn
/// build, so its short form is the MeshCore version.
struct FirmwareVersionParts: Equatable {
  let raw: String
  /// The Cairn build number, nil on stock MeshCore.
  let cairnBuild: Int?
  /// "v1.10.0", the MeshCore release it is (or is based on).
  let meshCore: String?
  /// What the firmware says about when it was built, as it says it.
  let buildDate: String?

  init(_ raw: String) {
    self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    cairnBuild = cairnBuildNumber(self.raw)
    meshCore = self.raw.firstMatch(of: /v\d+(?:\.\d+)+/).map { String($0.output) }
    buildDate = self.raw.firstMatch(of: /\((?:[Bb]uild:?\s*)?([^)]+)\)/).map {
      String($0.output.1).trimmingCharacters(in: .whitespaces)
    }
  }

  /// "Cairn 107", else "v1.10.0", else the string as given.
  var short: String {
    if let cairnBuild { return "Cairn \(cairnBuild)" }
    return meshCore ?? raw
  }

  /// "MeshCore v1.10.0 · 07-Nov-2026": what the short form leaves out.
  var detail: String? {
    let base = cairnBuild == nil ? nil : meshCore.map { "MeshCore \($0)" }
    let parts = [base, buildDate].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
