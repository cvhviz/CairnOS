import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// A successful `region put` stores `floodAllowed: true`. Firmware sets flags to 0 on put.
@Suite("RepeaterSettingsViewModel add region")
@MainActor
struct RepeaterSettingsRegionTests {
  @MainActor
  final class CommandRecorder {
    private(set) var commands: [String] = []
    var reply: String = "OK - (flood allowed)"
    var repliesByCommand: [String: String] = [:]
    var errorsByCommand: [String: Error] = [:]
    var onSend: ((String) -> Void)?

    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      onSend?(command)
      if let error = errorsByCommand[command] { throw error }
      return repliesByCommand[command] ?? reply
    }

    func resetCommands() {
      commands.removeAll()
    }
  }

  static func makeViewModel(
    recorder: CommandRecorder,
    firmwareVersion: String? = "v1.15.0"
  ) -> RepeaterSettingsViewModel {
    let viewModel = RepeaterSettingsViewModel()
    viewModel.helper.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(),
        publicKey: Data(repeating: 0x42, count: 32),
        name: "Test Repeater",
        role: .repeater,
        isConnected: true,
        permissionLevel: .admin
      ),
      sendCommand: recorder.send,
      sendRawCommand: recorder.send
    )
    viewModel.helper.setNodeInfo(
      firmwareVersion: firmwareVersion,
      name: "Test Repeater",
      ownerInfo: nil
    )
    return viewModel
  }

  @Test
  func `firmware flood-allow put reply adds the region as flood allowed`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    try await viewModel.addRegion(name: "Europe", parent: .unscoped)

    #expect(recorder.commands == ["region", "region put Europe", "region save"])
    #expect(viewModel.helper.errorMessage == nil)
    #expect(viewModel.regions.count == 2)
    #expect(viewModel.regions.last?.name == "Europe")
    #expect(viewModel.regions.last?.parentName == "*")
    #expect(viewModel.regions.last?.depth == 1)
    #expect(viewModel.regions.last?.floodAllowed == true)
    #expect(!viewModel.hasUnsavedRegionChanges)

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.duplicate)) {
      try await viewModel.addRegion(name: "Europe", parent: .unscoped)
    }
  }

  @Test
  func `older-firmware OK put reply still adds the region as flood allowed`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    recorder.reply = "OK"
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    try await viewModel.addRegion(name: "UK", parent: .unscoped)

    #expect(viewModel.regions.last?.name == "UK")
    #expect(viewModel.regions.last?.floodAllowed == true)
  }

  @Test
  func `empty name throws rejected`() async {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: nil)) {
      try await viewModel.addRegion(name: "   ", parent: .unscoped)
    }
    #expect(recorder.commands == ["region"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.helper.errorMessage == nil)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `invalid name reports why and does not send`() async {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.invalidName)) {
      try await viewModel.addRegion(name: "my region", parent: .unscoped)
    }
    #expect(recorder.commands == ["region"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.invalidName)
  }

  @Test
  func `unable-to-put reply reports a full table and does not append`() async {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    recorder.reply = "Err - unable to put"
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    let tableFull = L10n.RemoteNodes.RemoteNodes.Settings.Regions.tableFull(32)

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: tableFull)) {
      try await viewModel.addRegion(name: "Europe", parent: .unscoped)
    }
    #expect(recorder.commands == ["region", "region put Europe"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.helper.errorMessage == tableFull)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `an unrecognised refusal reports addFailed`() async {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    recorder.reply = "Err - ??"
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.addFailed)) {
      try await viewModel.addRegion(name: "Europe", parent: .unscoped)
    }
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.addFailed)
  }

  @Test
  func `a refused automatic save leaves the change marked unsaved`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n", "region save": "Err - flash"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    try await viewModel.addRegion(name: "Europe", parent: .unscoped)

    #expect(recorder.commands == ["region", "region put Europe", "region save"])
    #expect(viewModel.hasUnsavedRegionChanges, "The card's Save to Device stays for a save the repeater refused")
    #expect(viewModel.helper.errorMessage == nil)

    recorder.repliesByCommand["region save"] = "OK"
    await viewModel.saveRegions()
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `addRegion with named parent sends put name parent`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    try await viewModel.addRegion(name: "gta", parent: .named("on"))

    #expect(recorder.commands.last == "region save")
    #expect(viewModel.regions.last?.parentName == "on")
    #expect(viewModel.regions.last?.depth == 2)
    #expect(viewModel.regions.last?.floodAllowed == true)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `named parent missing from tree throws rejected and does not send`() async {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.parentMissing)) {
      try await viewModel.addRegion(name: "gta", parent: .named("nope"))
    }
    #expect(recorder.commands == ["region"])
    #expect(viewModel.regions.map(\.name) == ["*", "on"])
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.parentMissing)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `addRegion under Unscoped with no star row still appends`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    viewModel.regions = []

    try await viewModel.addRegion(name: "Europe", parent: .unscoped)

    #expect(recorder.commands.last == "region save")
    #expect(viewModel.regions.last?.parentName == "*")
    #expect(viewModel.regions.last?.depth == 1)
  }

  @Test
  func `addRegion inserts after grandchildren of the parent`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "gta", parentName: "on", depth: 2, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "downtown", parentName: "gta", depth: 3, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "can", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    try await viewModel.addRegion(name: "ottawa", parent: .named("on"))

    #expect(viewModel.regions.map(\.name) == ["*", "on", "gta", "downtown", "ottawa", "can"])
  }

  @Test
  func `addRegion re-finds the parent after the put reply`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    viewModel.regions = [
      RepeaterRegionEntry(name: "west", parentName: "*", depth: 1, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    try await viewModel.addRegion(name: "gta", parent: .named("on"))

    #expect(viewModel.regions.map(\.name) == ["west", "*", "on", "gta"])
    #expect(viewModel.regions.last?.parentName == "on")
    #expect(viewModel.regions.last?.depth == 2)
  }

  @Test
  func `addRegion uses live parent depth after the put reply`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    recorder.onSend = { command in
      guard command == "region put gta on" else { return }
      viewModel.regions = [
        RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
        RepeaterRegionEntry(name: "can", parentName: "*", depth: 1, floodAllowed: true, isHome: false),
        RepeaterRegionEntry(name: "on", parentName: "can", depth: 2, floodAllowed: true, isHome: false)
      ]
    }

    try await viewModel.addRegion(name: "gta", parent: .named("on"))

    #expect(viewModel.regions.last?.name == "gta")
    #expect(viewModel.regions.last?.parentName == "on")
    #expect(viewModel.regions.last?.depth == 3)
  }

  @Test
  func `saveRegions after a truncated refetch still persists unsaved edits`() async throws {
    let recorder = CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n", "region save": "Err - flash"]
    let viewModel = Self.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    try await viewModel.addRegion(name: "Europe", parent: .unscoped)
    #expect(viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.regionsLoaded)

    // The dump is cut inside Europe's line; the lists and `region get` recover it.
    recorder.repliesByCommand = [
      "region": "* F\n Eur",
      "region list allowed": "*,Europe",
      "region list denied": "-none-",
      "region get Europe": " Europe F"
    ]
    await viewModel.fetchRegions()

    #expect(viewModel.regionsLoaded)
    #expect(!viewModel.regionsError)
    #expect(!viewModel.regionsListPartial)
    #expect(viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.regions.map(\.name) == ["*", "Europe"])

    recorder.resetCommands()
    recorder.repliesByCommand["region save"] = "OK"
    await viewModel.saveRegions()

    #expect(recorder.commands == ["region save"])
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `addRegion sends nothing when not loaded`() async {
    let recorder = CommandRecorder()
    let viewModel = Self.makeViewModel(recorder: recorder)

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: nil)) {
      try await viewModel.addRegion(name: "Europe", parent: .unscoped)
    }
    #expect(recorder.commands.isEmpty)
  }
}

/// Repeater v1.15.0+ answers `region put` with "OK - (flood allowed)" and creates the region
/// flood-allowed. Earlier firmware answers a bare "OK" and creates it flood-denied.
@Suite("RepeaterSettingsViewModel add flood-allowed region")
@MainActor
struct RepeaterSettingsAddFloodAllowedRegionTests {
  private nonisolated static let olderFirmware = "v1.14.1"

  private static func makeLoadedViewModel(
    recorder: RepeaterSettingsRegionTests.CommandRecorder,
    firmwareVersion: String?
  ) async -> RepeaterSettingsViewModel {
    recorder.repliesByCommand["region"] = "* F\n"
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: firmwareVersion
    )
    await viewModel.fetchRegions()
    recorder.resetCommands()
    return viewModel
  }

  @Test
  func `current firmware sends only the put`() async throws {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: "v1.15.0")

    try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)

    #expect(recorder.commands == ["region put Europe", "region save"])
    #expect(viewModel.regions.last?.name == "Europe")
    #expect(viewModel.regions.last?.floodAllowed == true)
    #expect(viewModel.helper.errorMessage == nil)
    #expect(!viewModel.helper.isApplying)
  }

  @Test(arguments: [olderFirmware, nil])
  func `older or unknown firmware follows the put with allowf`(firmwareVersion: String?) async throws {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "OK"
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: firmwareVersion)

    try await viewModel.addFloodAllowedRegion(name: " Europe ", parent: .unscoped)

    #expect(recorder.commands == ["region put Europe", "region save", "region allowf Europe", "region save"])
    #expect(viewModel.regions.last?.name == "Europe")
    #expect(viewModel.regions.last?.floodAllowed == true)
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.helper.errorMessage == nil)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `older firmware allows flood on a child region by name`() async throws {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "OK"
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    try await viewModel.addFloodAllowedRegion(name: "gta", parent: .named("on"))

    #expect(recorder.commands == ["region put gta on", "region save", "region allowf gta", "region save"])
    #expect(viewModel.regions.last?.parentName == "on")
    #expect(viewModel.regions.last?.floodAllowed == true)
  }

  @Test
  func `rejected allowf keeps the region and reports it as off`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "OK"
    recorder.repliesByCommand["region allowf Europe"] = "Err - unknown region"
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)

    await #expect(throws: RepeaterSettingsViewModel.RegionFloodDefaultError.stillDenied) {
      try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    }

    #expect(recorder.commands == ["region put Europe", "region save", "region allowf Europe"])
    #expect(viewModel.regions.map(\.name) == ["*", "Europe"])
    #expect(viewModel.regions.last?.floodAllowed == false)
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.addedFloodOff)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `allowf timeout is reported and not sent again`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "OK"
    recorder.errorsByCommand["region allowf Europe"] = RemoteNodeError.timeout
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)

    await #expect(throws: RepeaterSettingsViewModel.RegionFloodDefaultError.stillDenied) {
      try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    }

    #expect(recorder.commands == ["region put Europe", "region save", "region allowf Europe"])
    #expect(viewModel.regions.last?.name == "Europe")
    #expect(viewModel.regions.last?.floodAllowed == false)
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.addedFloodOff)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `the toggle of a region left off sends allowf`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "OK"
    recorder.errorsByCommand["region allowf Europe"] = RemoteNodeError.timeout
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)
    try? await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    recorder.errorsByCommand = [:]
    recorder.resetCommands()

    await viewModel.toggleRegionFlood(name: "Europe")

    #expect(recorder.commands == ["region allowf Europe", "region save"])
    #expect(viewModel.regions.last?.floodAllowed == true)
    #expect(viewModel.helper.errorMessage == nil)
  }

  @Test(arguments: [olderFirmware, "v1.15.0"])
  func `put timeout is reported and nothing else is sent`(firmwareVersion: String) async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.errorsByCommand["region put Europe"] = RemoteNodeError.timeout
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: firmwareVersion)

    await #expect(throws: RemoteNodeError.self) {
      try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    }

    #expect(recorder.commands == ["region put Europe"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.helper.errorMessage == RemoteNodeError.timeout.userFacingMessage)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `a dropped connection is reported and nothing else is sent`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.errorsByCommand["region put Europe"] = RemoteNodeError.notConnected
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)

    await #expect(throws: RemoteNodeError.self) {
      try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    }

    #expect(recorder.commands == ["region put Europe"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.helper.errorMessage == RemoteNodeError.notConnected.userFacingMessage)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `rejected put does not send allowf`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "Err - unable to put"
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)

    let tableFull = L10n.RemoteNodes.RemoteNodes.Settings.Regions.tableFull(32)
    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: tableFull)) {
      try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    }

    #expect(recorder.commands == ["region put Europe"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.helper.errorMessage == tableFull)
  }

  @Test
  func `unknown parent on the repeater is reported`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand["region put gta on"] = "Err - unknown parent"
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: Self.olderFirmware)
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "on", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.parentMissing)) {
      try await viewModel.addFloodAllowedRegion(name: "gta", parent: .named("on"))
    }

    #expect(recorder.commands == ["region put gta on"])
    #expect(viewModel.regions.map(\.name) == ["*", "on"])
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.parentMissing)
  }

  @Test
  func `regions that are not loaded send nothing`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: Self.olderFirmware
    )

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: nil)) {
      try await viewModel.addFloodAllowedRegion(name: "Europe", parent: .unscoped)
    }

    #expect(recorder.commands.isEmpty)
  }
}

@Suite("RepeaterSettingsViewModel parse region tree")
@MainActor
struct RepeaterSettingsParseRegionTreeTests {
  @Test
  func `parseRegionDump keeps Ontario indent and parents`() throws {
    let dump = """
    * F
     can F
      on F
       gta F
       ottawa F
       hamilton F
    """ + "\n"
    let result = try #require(RepeaterSettingsViewModel.parseRegionDump(dump))
    #expect(!result.isTruncated)
    let parsed = result.entries
    #expect(parsed.map(\.name) == ["*", "can", "on", "gta", "ottawa", "hamilton"])
    #expect(parsed.map(\.parentName) == [nil, "*", "can", "on", "on", "on"])
    #expect(parsed.map(\.depth) == [0, 1, 2, 3, 3, 3])
    #expect(parsed.allSatisfy { region in region.floodAllowed })
  }

  @Test
  func `parseRegionDump strips caret and reads deny-flood`() throws {
    let dump = "* F\n on^ F\n  gta\n"
    let parsed = try #require(RepeaterSettingsViewModel.parseRegionDump(dump)).entries
    #expect(parsed.map(\.name) == ["*", "on", "gta"])
    #expect(parsed[1].floodAllowed)
    #expect(!parsed[2].floodAllowed)
    #expect(parsed[2].parentName == "on")
  }

  @Test
  func `parseRegionDump reads a name ending in a caret as a home marker`() throws {
    // Why a repeater add refuses a trailing '^': "west^" can't be told from home region "west".
    let parsed = try #require(RepeaterSettingsViewModel.parseRegionDump("* F\n west^ F\n")).entries
    #expect(parsed[1].name == "west")
    #expect(parsed[1].isHome)
  }

  @Test
  func `parseRegionDump strips factory Unscoped caret`() throws {
    let parsed = try #require(RepeaterSettingsViewModel.parseRegionDump("*^ F\n")).entries
    #expect(parsed.map(\.name) == ["*"])
    #expect(parsed[0].floodAllowed)
    #expect(parsed[0].parentName == nil)
  }

  @Test
  func `parseRegionDump rejects skipped indent`() {
    let dump = "* F\n   gta F\n"
    #expect(RepeaterSettingsViewModel.parseRegionDump(dump) == nil)
  }

  @Test
  func `fetchRegions does not mark loaded on a malformed dump`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = ["region": "* F\n   gta F\n"]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()

    #expect(!viewModel.regionsLoaded)
    #expect(viewModel.regionsError)
  }

  @Test
  func `parseRegionDump rejects a space in the name`() {
    #expect(RepeaterSettingsViewModel.parseRegionDump("* F\n foo bar F\n") == nil)
  }

  @Test
  func `parseRegionDump CRLF dump matches LF`() {
    let lf = "* F\n on F\n"
    let crlf = "* F\r\n on F\r\n"
    #expect(RepeaterSettingsViewModel.parseRegionDump(lf) != nil)
    #expect(
      RepeaterSettingsViewModel.parseRegionDump(crlf)
        == RepeaterSettingsViewModel.parseRegionDump(lf)
    )
  }

  @Test
  func `parseRegionDump single-line CRLF dump matches LF`() {
    #expect(
      RepeaterSettingsViewModel.parseRegionDump("* F\r\n")
        == RepeaterSettingsViewModel.parseRegionDump("* F\n")
    )
  }

  @Test
  func `parseRegionDump keeps the whole lines of a dump that does not end with a newline`() throws {
    let result = try #require(RepeaterSettingsViewModel.parseRegionDump("* F\n on F\n  gta F\n  ott"))
    #expect(result.isTruncated)
    #expect(result.entries.map(\.name) == ["*", "on", "gta"])
    #expect(result.entries.map(\.parentName) == [nil, "*", "on"])
  }

  @Test
  func `parseRegionDump rejects a reply with no whole line`() {
    #expect(RepeaterSettingsViewModel.parseRegionDump("* F") == nil)
  }

  @Test
  func `parseRegionDump drops a UTF-8 sequence split by the cut`() throws {
    var bytes = Array("* F\n caf".utf8)
    bytes.append(0xC3) // the first byte of "é", cut off by the firmware's cap
    let reply = String(decoding: bytes, as: UTF8.self)
    let result = try #require(RepeaterSettingsViewModel.parseRegionDump(reply))
    #expect(result.isTruncated)
    #expect(result.entries.map(\.name) == ["*"])
  }

  /// One flood-allowed row: `<name> F\n`. `utf8Count` is the full dump size.
  private func lfTerminatedFloodDump(utf8Count: Int) -> String {
    let suffix = " F\n"
    let nameLen = utf8Count - suffix.utf8.count
    let dump = String(repeating: "a", count: nameLen) + suffix
    precondition(dump.utf8.count == utf8Count)
    precondition(dump.unicodeScalars.last == "\n")
    return dump
  }

  @Test
  func `parseRegionDump marks a saturated newline-terminated dump as truncated`() throws {
    let dump = lfTerminatedFloodDump(
      utf8Count: RepeaterSettingsViewModel.firmwareRegionDumpMaxPayloadBytes
    )
    let result = try #require(RepeaterSettingsViewModel.parseRegionDump(dump))
    #expect(result.isTruncated)
    #expect(result.entries.count == 1)
  }

  @Test
  func `parseRegionDump accepts a dump one byte under the firmware cap as whole`() throws {
    let dump = lfTerminatedFloodDump(
      utf8Count: RepeaterSettingsViewModel.firmwareRegionDumpMaxPayloadBytes - 1
    )
    let result = try #require(RepeaterSettingsViewModel.parseRegionDump(dump))
    #expect(!result.isTruncated)
    let parsed = result.entries
    #expect(parsed.count == 1)
    #expect(parsed[0].floodAllowed)
  }

  @Test
  func `fetchRegions malformed dump after a successful load unloads and does not wipe`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    #expect(viewModel.regionsLoaded)
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
    #expect(viewModel.defaultScopeName == "duckburg")

    recorder.repliesByCommand = ["region": "* F\n   gta F\n"]
    await viewModel.fetchRegions()

    #expect(!viewModel.regionsLoaded)
    #expect(viewModel.regionsError)
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
    #expect(viewModel.defaultScopeLoaded)
    #expect(viewModel.defaultScopeName == "duckburg")

    recorder.resetCommands()
    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: nil)) {
      try await viewModel.addRegion(name: "gta", parent: .unscoped)
    }
    await viewModel.setDefaultScope(name: nil)
    await viewModel.removeRegion(name: "duckburg")
    await viewModel.toggleRegionFlood(name: "duckburg")

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.regions.first { $0.name == "duckburg" }?.floodAllowed == true)
  }
}

@Suite("RepeaterSettingsViewModel default scope")
@MainActor
struct RepeaterSettingsDefaultScopeTests {
  @Test
  func `parseDefaultScopeReply reads get and set lines`() {
    #expect(
      RepeaterSettingsViewModel.parseDefaultScopeReply(" default scope is <null>")
        == RepeaterSettingsViewModel.ParsedDefaultScope.cleared
    )
    #expect(
      RepeaterSettingsViewModel.parseDefaultScopeReply(" default scope is duckburg")
        == .named("duckburg")
    )
    #expect(
      RepeaterSettingsViewModel.parseDefaultScopeReply(">  default scope is now duckburg")
        == .named("duckburg")
    )
    #expect(
      RepeaterSettingsViewModel.parseDefaultScopeReply(" default scope is now <null>")
        == RepeaterSettingsViewModel.ParsedDefaultScope.cleared
    )
    #expect(RepeaterSettingsViewModel.parseDefaultScopeReply("OK") == nil)
    #expect(
      RepeaterSettingsViewModel.parseDefaultScopeReply(" default scope is *")
        == RepeaterSettingsViewModel.ParsedDefaultScope.cleared
    )
  }

  @Test
  func `fetchRegions does not send region default`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()

    #expect(recorder.commands == ["region"])
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
    #expect(viewModel.defaultScopeName == nil)
    #expect(!viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)
  }

  @Test
  func `fetchDefaultScope reads the firmware default`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await viewModel.fetchDefaultScope()

    #expect(recorder.commands == ["region default"])
    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)
  }

  @Test
  func `fetchDefaultScope sends nothing before repeater v1_15`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: "v1.14.1"
    )
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await viewModel.fetchDefaultScope()

    #expect(recorder.commands.isEmpty)
    #expect(!viewModel.supportsRegionDefaultScope)
    #expect(!viewModel.defaultScopeLoaded)
    #expect(viewModel.defaultScopeName == nil)
  }

  @Test
  func `fetchDefaultScope sends region default for CLI ver banner at v1_15`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: "MeshCore v1.15.0 (2025-04-18)"
    )
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await viewModel.fetchDefaultScope()

    #expect(recorder.commands == ["region default"])
    #expect(viewModel.supportsRegionDefaultScope)
    #expect(viewModel.defaultScopeLoaded)
    #expect(viewModel.defaultScopeName == "duckburg")
  }

  @Test
  func `fetchDefaultScope sends nothing when firmware version is unknown`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: nil
    )
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await viewModel.fetchDefaultScope()

    #expect(recorder.commands.isEmpty)
    #expect(!viewModel.supportsRegionDefaultScope)
    #expect(!viewModel.defaultScopeLoaded)
  }

  @Test
  func `setDefaultScope sends nothing before repeater v1_15`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default duckburg": " default scope is now duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: "v1.14.1"
    )
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await viewModel.setDefaultScope(name: "duckburg")

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.defaultScopeName == nil)
  }

  @Test
  func `removeRegion of current default skips clear before repeater v1_15`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region remove duckburg": "OK",
      "region default <null>": " default scope is now <null>"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(
      recorder: recorder,
      firmwareVersion: "v1.14.1"
    )
    await viewModel.fetchRegions()
    viewModel.defaultScopeName = "duckburg"
    recorder.resetCommands()

    await viewModel.removeRegion(name: "duckburg")

    #expect(recorder.commands == ["region remove duckburg", "region save"])
    #expect(viewModel.defaultScopeName == "duckburg")
  }

  @Test
  func `fetchDefaultScope treats firmware null as no default scope`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n",
      "region default": " default scope is <null>"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    await viewModel.fetchDefaultScope()

    #expect(viewModel.defaultScopeName == nil)
    #expect(viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)
  }

  @Test
  func `unparsed default reply does not fail the regions section`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n",
      "region default": "OK"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()

    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.defaultScopeName == nil)
    #expect(!viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)

    await viewModel.fetchDefaultScope()

    #expect(viewModel.defaultScopeName == nil)
    #expect(!viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)
  }

  @Test
  func `unparsed default reply keeps the previous default scope`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()

    recorder.repliesByCommand["region default"] = "OK"
    await viewModel.fetchDefaultScope()

    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)
  }

  @Test
  func `default-scope timeout keeps the previous value and does not fail regions`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()

    recorder.errorsByCommand["region default"] = RemoteNodeError.timeout
    await viewModel.fetchDefaultScope()

    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.defaultScopeLoaded)
    #expect(!viewModel.regionsError)
  }

  @Test
  func `setDefaultScope sends nothing when not loaded`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.setDefaultScope(name: "duckburg")

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.defaultScopeName == nil)
  }

  @Test
  func `setDefaultScope sends region default and does not mark unsaved`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg\n",
      "region default": " default scope is <null>",
      "region default duckburg": " default scope is now duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.setDefaultScope(name: "duckburg")

    #expect(recorder.commands == ["region default duckburg", "region save"])
    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.regions.first { $0.name == "duckburg" }?.floodAllowed == true)
    #expect(viewModel.helper.errorMessage == nil)
  }

  @Test
  func `setDefaultScope nil sends firmware null token`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg",
      "region default <null>": " default scope is now <null>"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.setDefaultScope(name: nil)

    #expect(recorder.commands == ["region default <null>", "region save"])
    #expect(viewModel.defaultScopeName == nil)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `setDefaultScope non-matching reply leaves the current value`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg",
      "region default nope": "Err - unknown region"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.setDefaultScope(name: "nope")

    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.unknownRegion)
  }

  @Test
  func `setDefaultScope does not send wildcard`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.setDefaultScope(name: RepeaterRegionEntry.unscopedName)

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.defaultScopeName == "duckburg")
  }

  @Test
  func `setDefaultScope same value is a no-op`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.setDefaultScope(name: "duckburg")

    #expect(recorder.commands.isEmpty)
  }

  @Test
  func `removeRegion sends nothing when not loaded`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "duckburg", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    await viewModel.removeRegion(name: "duckburg")

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
  }

  @Test
  func `toggleRegionFlood re-finds by name after the reply`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is <null>",
      "region denyf duckburg": "OK"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    recorder.resetCommands()

    recorder.onSend = { command in
      guard command == "region denyf duckburg" else { return }
      viewModel.regions = [
        RepeaterRegionEntry(
          name: "duckburg", parentName: "*", depth: 1, floodAllowed: true, isHome: false
        ),
        RepeaterRegionEntry(
          name: "other", parentName: "*", depth: 1, floodAllowed: true, isHome: false
        )
      ]
    }

    await viewModel.toggleRegionFlood(name: "duckburg")

    #expect(viewModel.regions.first { $0.name == "duckburg" }?.floodAllowed == false)
    #expect(viewModel.regions.first { $0.name == "other" }?.floodAllowed == true)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `toggleRegionFlood does not trap when the row is gone after await`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is <null>",
      "region denyf duckburg": "OK"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    recorder.onSend = { command in
      guard command.hasPrefix("region denyf") else { return }
      viewModel.regions = [
        RepeaterRegionEntry(
          name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false
        )
      ]
    }

    await viewModel.toggleRegionFlood(name: "duckburg")

    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.helper.errorMessage == nil)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `toggleRegionFlood sends nothing when not loaded`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    viewModel.regions = [
      RepeaterRegionEntry(name: "*", parentName: nil, depth: 0, floodAllowed: true, isHome: false),
      RepeaterRegionEntry(name: "duckburg", parentName: "*", depth: 1, floodAllowed: true, isHome: false)
    ]

    await viewModel.toggleRegionFlood(name: "duckburg")

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.regions.first { $0.name == "duckburg" }?.floodAllowed == true)
    #expect(!viewModel.hasUnsavedRegionChanges)
  }

  @Test
  func `removeRegion of current default sends remove then default clear`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg",
      "region remove duckburg": "OK",
      "region default <null>": " default scope is now <null>"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.removeRegion(name: "duckburg")

    #expect(recorder.commands == ["region remove duckburg", "region default <null>", "region save"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.defaultScopeName == nil)
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.helper.errorMessage == nil)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `removeRegion of current default keeps the name when trailing clear fails`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg",
      "region remove duckburg": "OK",
      "region default <null>": "Err - save failed"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.removeRegion(name: "duckburg")

    #expect(recorder.commands == ["region remove duckburg", "region default <null>", "region save"])
    #expect(viewModel.regions.map(\.name) == ["*"])
    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.defaultScopeLoaded)
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.unknownRegion)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `removeRegion of current default does not send default clear when remove is rejected`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n",
      "region default": " default scope is duckburg",
      "region remove duckburg": "Err - not empty"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.removeRegion(name: "duckburg")

    #expect(recorder.commands == ["region remove duckburg"])
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.notEmpty)
  }

  @Test
  func `removeRegion of a different region does not send region default`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n duckburg F\n goosetown F\n",
      "region default": " default scope is duckburg",
      "region remove goosetown": "OK"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.removeRegion(name: "goosetown")

    #expect(recorder.commands == ["region remove goosetown", "region save"])
    #expect(viewModel.defaultScopeName == "duckburg")
    #expect(viewModel.regions.map(\.name) == ["*", "duckburg"])
  }

  @Test
  func `removeRegion of a parent maps not empty and does not drop the row`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n on F\n  gta F\n",
      "region default": " default scope is <null>",
      "region remove on": "Err - not empty"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await viewModel.removeRegion(name: "on")

    #expect(recorder.commands == ["region remove on"])
    #expect(viewModel.regions.map(\.name) == ["*", "on", "gta"])
    #expect(viewModel.helper.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.Regions.notEmpty)
  }

  @Test
  func `removeRegion of nested non-default does not send region default`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand = [
      "region": "* F\n on F\n  gta F\n",
      "region default": " default scope is on",
      "region remove gta": "OK"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    await viewModel.fetchDefaultScope()
    recorder.resetCommands()

    await viewModel.removeRegion(name: "gta")

    #expect(recorder.commands == ["region remove gta", "region save"])
    #expect(viewModel.defaultScopeName == "on")
  }
}

/// Firmware cuts the `region` dump at 159 bytes, about a dozen regions of the 32 a repeater holds.
/// The rest are read with `region list allowed|denied` and `region get`, and while any stay
/// unread, each new name is checked with `region get` before `region put`, which would otherwise
/// move a same-named region that isn't shown and turn its flood on.
@Suite("RepeaterSettingsViewModel regions past the dump cap")
@MainActor
struct RepeaterSettingsRegionsPastDumpTests {
  private typealias Recorder = RepeaterSettingsRegionTests.CommandRecorder
  private typealias Strings = L10n.RemoteNodes.RemoteNodes.Settings.Regions

  /// `region01` to `region14` after Unscoped: 127 bytes, so the firmware may have skipped a name.
  private static let longListNames = (1...14).map { String(format: "region%02d", $0) }

  private static func makePartiallyLoadedViewModel(recorder: Recorder) async -> RepeaterSettingsViewModel {
    recorder.repliesByCommand = [
      "region": "* F\n region01 F\n regi",
      "region list allowed": (["*"] + longListNames).joined(separator: ","),
      "region list denied": "-none-"
    ]
    for name in longListNames.dropFirst() {
      recorder.repliesByCommand["region get \(name)"] = " \(name) F"
    }
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    recorder.resetCommands()
    return viewModel
  }

  @Test
  func `a cut dump is completed from the lists and region get`() async throws {
    let recorder = Recorder()
    recorder.repliesByCommand = [
      "region": "* F\n on F\n  gta F\n  ott",
      "region list allowed": "*,on,gta,ottawa,west",
      "region list denied": "east",
      "region get ottawa": " ottawa (on) F",
      "region get west": " west F",
      "region get east": " east (west) "
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()

    #expect(recorder.commands == [
      "region", "region list allowed", "region list denied",
      "region get ottawa", "region get west", "region get east"
    ])
    #expect(viewModel.regionsLoaded)
    #expect(!viewModel.regionsError)
    #expect(!viewModel.regionsListPartial)
    #expect(viewModel.unplacedRegionNames.isEmpty)
    #expect(viewModel.regions.map(\.name) == ["*", "on", "gta", "ottawa", "west", "east"])
    #expect(viewModel.regions.map(\.parentName) == [nil, "*", "on", "on", "*", "west"])
    #expect(viewModel.regions.map(\.depth) == [0, 1, 2, 2, 1, 2])
    #expect(viewModel.regions.map(\.floodAllowed) == [true, true, true, true, true, false])

    // Everything was read, so an add goes straight to the put.
    recorder.resetCommands()
    try await viewModel.addRegion(name: "north", parent: .unscoped)
    #expect(recorder.commands == ["region put north", "region save"])
  }

  @Test
  func `the dumped regions show while the rest are read`() async {
    let recorder = Recorder()
    recorder.repliesByCommand = [
      "region": "* F\n on F\n  gta F\n  ott",
      "region list allowed": "*,on,gta,ottawa",
      "region list denied": "-none-",
      "region get ottawa": " ottawa (on) F"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    var namesDuringRead: [String]?
    var partialDuringRead = false
    var loadingDuringRead = false
    recorder.onSend = { command in
      guard command == "region list allowed" else { return }
      namesDuringRead = viewModel.regionsLoaded ? viewModel.regions.map(\.name) : nil
      partialDuringRead = viewModel.regionsListPartial
      loadingDuringRead = viewModel.isLoadingRegions
    }

    await viewModel.fetchRegions()

    #expect(namesDuringRead == ["*", "on", "gta"])
    #expect(partialDuringRead)
    #expect(loadingDuringRead)
    #expect(viewModel.regions.map(\.name) == ["*", "on", "gta", "ottawa"])
    #expect(!viewModel.regionsListPartial)
    #expect(!viewModel.isLoadingRegions)
  }

  @Test
  func `a list that may have skipped a name leaves the table partial but usable`() async {
    let recorder = Recorder()
    let viewModel = await Self.makePartiallyLoadedViewModel(recorder: recorder)

    #expect(viewModel.regionsLoaded)
    #expect(!viewModel.regionsError)
    #expect(viewModel.regionsListPartial)
    #expect(viewModel.regions.map(\.name) == ["*"] + Self.longListNames)
  }

  @Test
  func `a partial table checks a new name with the repeater before the put`() async throws {
    let recorder = Recorder()
    let viewModel = await Self.makePartiallyLoadedViewModel(recorder: recorder)
    recorder.repliesByCommand["region get north"] = "Err - unknown region"

    try await viewModel.addRegion(name: "north", parent: .named("region01"))

    #expect(recorder.commands == ["region get north", "region put north region01", "region save"])
    #expect(viewModel.regions.contains { $0.name == "north" && $0.parentName == "region01" })
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `a partial table refuses a name the repeater already has`() async {
    let recorder = Recorder()
    let viewModel = await Self.makePartiallyLoadedViewModel(recorder: recorder)
    recorder.repliesByCommand["region get hidden"] = " hidden (region01) F"

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: Strings.existsOnRepeater)) {
      try await viewModel.addRegion(name: "hidden", parent: .unscoped)
    }

    #expect(recorder.commands == ["region get hidden"])
    #expect(viewModel.helper.errorMessage == Strings.existsOnRepeater)
    #expect(viewModel.unplacedRegionNames.contains("hidden"))
    #expect(!viewModel.hasUnsavedRegionChanges)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `a region the name only starts does not block the add`() async throws {
    let recorder = Recorder()
    let viewModel = await Self.makePartiallyLoadedViewModel(recorder: recorder)
    // No exact match: firmware answers with a region whose name starts with the one asked for.
    recorder.repliesByCommand["region get regi"] = " region01 F"

    try await viewModel.addRegion(name: "regi", parent: .unscoped)

    #expect(recorder.commands == ["region get regi", "region put regi", "region save"])
  }

  @Test(arguments: [true, false])
  func `a partial table refuses a name the repeater can't vouch for`(timesOut: Bool) async {
    let recorder = Recorder()
    let viewModel = await Self.makePartiallyLoadedViewModel(recorder: recorder)
    if timesOut {
      recorder.errorsByCommand["region get slow"] = RemoteNodeError.timeout
    } else {
      recorder.repliesByCommand["region get slow"] = "Err - ??"
    }

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: Strings.unconfirmedName)) {
      try await viewModel.addRegion(name: "slow", parent: .unscoped)
    }

    #expect(recorder.commands == ["region get slow"])
    #expect(viewModel.helper.errorMessage == Strings.unconfirmedName)
    #expect(!viewModel.helper.isApplying)
  }

  @Test
  func `a listed region whose parent can't be read blocks its name`() async {
    let recorder = Recorder()
    recorder.repliesByCommand = [
      "region": "* F\n on F\n o",
      "region list allowed": "*,on,orphan",
      "region list denied": "-none-",
      "region get orphan": "Err - ??"
    ]
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()

    #expect(viewModel.regionsLoaded)
    #expect(viewModel.regionsListPartial)
    #expect(viewModel.regions.map(\.name) == ["*", "on"])
    #expect(viewModel.unplacedRegionNames == ["orphan"])

    recorder.resetCommands()
    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(reason: Strings.duplicate)) {
      try await viewModel.addRegion(name: "orphan", parent: .unscoped)
    }
    #expect(recorder.commands.isEmpty)
  }

  @Test
  func `a list timeout keeps the dumped part loaded`() async {
    let recorder = Recorder()
    recorder.repliesByCommand = ["region": "* F\n on F\n o"]
    recorder.errorsByCommand["region list allowed"] = RemoteNodeError.timeout
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()

    #expect(recorder.commands == ["region", "region list allowed"])
    #expect(viewModel.regionsLoaded)
    #expect(!viewModel.regionsError)
    #expect(viewModel.regionsListPartial)
    #expect(viewModel.regions.map(\.name) == ["*", "on"])
  }

  @Test
  func `a region get timeout stops the reads`() async {
    let recorder = Recorder()
    recorder.repliesByCommand = [
      "region": "* F\n on F\n o",
      "region list allowed": "*,on,a,b",
      "region list denied": "-none-"
    ]
    recorder.errorsByCommand["region get a"] = RemoteNodeError.timeout
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)

    await viewModel.fetchRegions()

    #expect(recorder.commands.last == "region get a")
    #expect(viewModel.regionsListPartial)
    #expect(viewModel.unplacedRegionNames == ["a", "b"])
  }

  // MARK: - Parsing

  @Test
  func `parseRegionNameList reads names and whether any could be skipped`() {
    #expect(RepeaterSettingsViewModel.parseRegionNameList("-none-") == .init(names: [], isComplete: true))
    #expect(RepeaterSettingsViewModel.parseRegionNameList("*,on,gta") == .init(names: ["on", "gta"], isComplete: true))
    #expect(RepeaterSettingsViewModel.parseRegionNameList("> on,gta\n") == .init(names: ["on", "gta"], isComplete: true))
    #expect(RepeaterSettingsViewModel.parseRegionNameList("Err - use 'allowed' or 'denied'") == nil)
    #expect(RepeaterSettingsViewModel.parseRegionNameList("OK - (flood allowed)") == nil)

    let limit = RepeaterSettingsViewModel.firmwareRegionNameListCompleteBelowBytes
    #expect(limit == 127)
    let atLimit = (["*"] + Self.longListNames).joined(separator: ",")
    #expect(atLimit.utf8.count == limit)
    #expect(RepeaterSettingsViewModel.parseRegionNameList(atLimit)?.isComplete == false)
    let underLimit = String(atLimit.dropLast())
    #expect(RepeaterSettingsViewModel.parseRegionNameList(underLimit)?.isComplete == true)
  }

  @Test
  func `parseRegionGetReply reads name, parent and flood`() {
    typealias Lookup = RepeaterSettingsViewModel.RegionLookup
    #expect(RepeaterSettingsViewModel.parseRegionGetReply(" gta (on) F") == Lookup.found(name: "gta", parentName: "on", floodAllowed: true))
    #expect(RepeaterSettingsViewModel.parseRegionGetReply(" gta (#on) ") == Lookup.found(name: "gta", parentName: "on", floodAllowed: false))
    #expect(RepeaterSettingsViewModel.parseRegionGetReply(" #gta F") == Lookup.found(name: "gta", parentName: "*", floodAllowed: true))
    #expect(RepeaterSettingsViewModel.parseRegionGetReply(" gta ") == Lookup.found(name: "gta", parentName: "*", floodAllowed: false))
    #expect(RepeaterSettingsViewModel.parseRegionGetReply("Err - unknown region") == Lookup.notFound)
    #expect(RepeaterSettingsViewModel.parseRegionGetReply("Err - ??") == nil)
    #expect(RepeaterSettingsViewModel.parseRegionGetReply(" gta on F x") == nil)
  }

  @Test
  func `mergeRegionTree leaves out a region whose parent is unknown`() throws {
    let dumped = try #require(RepeaterSettingsViewModel.parseRegionDump("* F\n on F\n")).entries
    let merged = RepeaterSettingsViewModel.mergeRegionTree(
      dumped: dumped,
      found: [("gta", "on", true), ("lost", "nowhere", true)]
    )
    #expect(merged.map(\.name) == ["*", "on", "gta"])
    #expect(merged.last?.depth == 2)
  }
}

/// Typed names are sent as firmware `cleanName` stores them: no surrounding spaces or leading '#'.
@Suite("RepeaterSettingsViewModel add region name cleaning")
@MainActor
struct RepeaterSettingsAddRegionNameTests {
  private static func makeLoadedViewModel(
    recorder: RepeaterSettingsRegionTests.CommandRecorder,
    firmwareVersion: String = "v1.15.0"
  ) async -> RepeaterSettingsViewModel {
    recorder.repliesByCommand["region"] = "* F\n"
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder, firmwareVersion: firmwareVersion)
    await viewModel.fetchRegions()
    recorder.resetCommands()
    return viewModel
  }

  @Test(arguments: [("#socal", "socal"), ("  ##so_cal ", "so_cal"), ("Île-de-France", "Île-de-France")])
  func `sends the cleaned name`(typed: String, sent: String) async throws {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder)

    try await viewModel.addRegion(name: typed, parent: .unscoped)

    #expect(recorder.commands == ["region put \(sent)", "region save"])
    #expect(viewModel.regions.last?.name == sent)
  }

  @Test
  func `a hash-prefixed duplicate is refused`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand["region"] = "* F\n socal F\n"
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(
      reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.duplicate
    )) {
      try await viewModel.addRegion(name: "#socal", parent: .unscoped)
    }
    #expect(recorder.commands.isEmpty)
  }

  @Test
  func `a private name is refused without sending`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder)

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(
      reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.privateName
    )) {
      try await viewModel.addRegion(name: "$secret", parent: .unscoped)
    }
    #expect(recorder.commands.isEmpty)
  }

  @Test
  func `a name ending in a caret is refused without sending`() async {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.repliesByCommand["region"] = "* F\n west F\n"
    let viewModel = RepeaterSettingsRegionTests.makeViewModel(recorder: recorder)
    await viewModel.fetchRegions()
    recorder.resetCommands()

    await #expect(throws: RepeaterSettingsViewModel.AddRegionError.rejected(
      reason: L10n.RemoteNodes.RemoteNodes.Settings.Regions.invalidName
    )) {
      try await viewModel.addRegion(name: "west^", parent: .unscoped)
    }
    #expect(recorder.commands.isEmpty)
    #expect(viewModel.regions.map(\.name) == ["*", "west"])
  }

  @Test
  func `older firmware allows flood on the cleaned name`() async throws {
    let recorder = RepeaterSettingsRegionTests.CommandRecorder()
    recorder.reply = "OK"
    let viewModel = await Self.makeLoadedViewModel(recorder: recorder, firmwareVersion: "v1.14.1")

    try await viewModel.addFloodAllowedRegion(name: "#Europe", parent: .unscoped)

    #expect(recorder.commands == ["region put Europe", "region save", "region allowf Europe", "region save"])
    #expect(viewModel.regions.last?.floodAllowed == true)
  }
}
