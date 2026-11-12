import Foundation
@testable import Cairn
import Testing

@Suite("Firmware update check")
struct FirmwareUpdateCheckTests {
  @Test
  func `a release behind or level with the build is no update`() {
    #expect(FirmwareUpdateCheck.updateAvailable(installedBuild: 127, latestBuild: 127) == false)
    #expect(FirmwareUpdateCheck.updateAvailable(installedBuild: 130, latestBuild: 127) == false)
  }

  @Test
  func `a newer release is an update`() {
    #expect(FirmwareUpdateCheck.updateAvailable(installedBuild: 120, latestBuild: 127) == true)
  }

  @Test
  func `without a build number on either side there is no answer`() {
    #expect(FirmwareUpdateCheck.updateAvailable(installedBuild: nil, latestBuild: 127) == nil)
    #expect(FirmwareUpdateCheck.updateAvailable(installedBuild: 120, latestBuild: nil) == nil)
    #expect(FirmwareUpdateCheck.updateAvailable(installed: "v1.15.0", latestBuild: 127) == nil, "Stock MeshCore has no Cairn build")
    #expect(!FirmwareUpdateCheck.isCairnBuild("v1.15.0"))
  }

  @Test
  func `the cache keeps the build and says when it is stale`() {
    let suite = "FirmwareUpdateCheckTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(LatestFirmwareBuildCache.latestBuild(defaults: defaults) == nil)
    #expect(LatestFirmwareBuildCache.isStale(defaults: defaults))

    let now = Date()
    LatestFirmwareBuildCache.record(build: 127, now: now, defaults: defaults)
    #expect(LatestFirmwareBuildCache.latestBuild(defaults: defaults) == 127)
    #expect(!LatestFirmwareBuildCache.isStale(now: now.addingTimeInterval(3600), defaults: defaults))
    #expect(LatestFirmwareBuildCache.isStale(now: now.addingTimeInterval(LatestFirmwareBuildCache.maxAge + 1), defaults: defaults))

    // A missing build number doesn't wipe what is known.
    LatestFirmwareBuildCache.record(build: nil, now: now, defaults: defaults)
    #expect(LatestFirmwareBuildCache.latestBuild(defaults: defaults) == 127)
  }
}
