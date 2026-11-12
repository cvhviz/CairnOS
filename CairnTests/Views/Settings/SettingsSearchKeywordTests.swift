import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Settings search keywords")
@MainActor
struct SettingsSearchKeywordTests {
  @Test
  func `firmware and update open Firmware Update directly`() {
    #expect(SettingsSearchIndex.results(for: "firmware").contains { $0.page == .firmwareUpdate })
    #expect(SettingsSearchIndex.results(for: "update").contains { $0.page == .firmwareUpdate })
  }

  @Test
  func `name finds Device Info, where the radio is renamed, not Connection`() {
    let pages = SettingsSearchIndex.results(for: "name").map(\.page)
    #expect(pages.contains(.deviceInfo))
    #expect(!pages.contains(.connection))
  }

  @Test
  func `channel finds Chats, where channels are managed`() {
    let pages = SettingsSearchIndex.results(for: "channel").map(\.page)
    #expect(pages.contains(.chats))
  }

  @Test
  func `sounds and badge find Notifications, which now has their switches`() {
    #expect(SettingsSearchIndex.results(for: "sounds").contains { $0.page == .notifications })
    #expect(SettingsSearchIndex.results(for: "badge").contains { $0.page == .notifications })
  }
}

@Suite("Firmware update availability")
struct FirmwareUpdateHubFlagTests {
  @Test
  func `a found update is remembered for that radio only`() throws {
    let suiteName = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let radio = UUID()
    let other = UUID()

    FirmwareUpdateHubFlag.record(available: true, deviceID: radio, defaults: defaults)
    #expect(FirmwareUpdateHubFlag.isAvailable(for: radio, defaults: defaults))
    #expect(!FirmwareUpdateHubFlag.isAvailable(for: other, defaults: defaults))
    #expect(!FirmwareUpdateHubFlag.isAvailable(for: nil, defaults: defaults))

    FirmwareUpdateHubFlag.record(available: false, deviceID: radio, defaults: defaults)
    #expect(!FirmwareUpdateHubFlag.isAvailable(for: radio, defaults: defaults))

    FirmwareUpdateHubFlag.record(available: true, deviceID: radio, defaults: defaults)
    FirmwareUpdateHubFlag.record(available: nil, deviceID: radio, defaults: defaults)
    #expect(!FirmwareUpdateHubFlag.isAvailable(for: radio, defaults: defaults))
  }

  @Test
  func `the Latest tile's caption carries the state and the published date`() throws {
    let published = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 3)))
    let dateText = published.formatted(date: .abbreviated, time: .omitted)
    #expect(FirmwareReleaseCaption.caption(publishedAt: published, updateAvailable: true)
      == "\(L10n.Settings.FirmwareUpdate.available) · \(dateText)")
    #expect(FirmwareReleaseCaption.caption(publishedAt: published, updateAvailable: nil) == dateText)
    #expect(FirmwareReleaseCaption.caption(publishedAt: nil, updateAvailable: false) == L10n.Settings.FirmwareUpdate.upToDate)
    #expect(FirmwareReleaseCaption.caption(publishedAt: nil, updateAvailable: nil) == nil)
  }
}
