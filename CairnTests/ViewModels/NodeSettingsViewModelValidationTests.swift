import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("NodeSettingsViewModel identity validation")
@MainActor
struct NodeSettingsIdentityValidationTests {
  // MARK: - In-range passes

  @Test
  func `in range coordinates produce no errors`() {
    let errors = NodeSettingsViewModel.validateIdentityFields(
      name: "Repeater One", latitude: 37.7749, longitude: -122.4194
    )
    #expect(errors.name == nil)
    #expect(errors.latitude == nil)
    #expect(errors.longitude == nil)
    #expect(errors.hasErrors == false)
  }

  @Test
  func `zero coordinates are valid`() {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: 0, longitude: 0)
    #expect(errors.hasErrors == false)
  }

  @Test
  func `nil fields are skipped not flagged`() {
    // nil means the field was never loaded/edited; the apply path skips it, so validation must not flag it.
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: nil, longitude: nil)
    #expect(errors.hasErrors == false)
  }

  // MARK: - Inclusive boundaries pass

  @Test(arguments: [-90.0, 90.0])
  func `latitude boundaries are inclusive`(lat: Double) {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: lat, longitude: 0)
    #expect(errors.latitude == nil, "Latitude \(lat) is a valid boundary and must pass")
  }

  @Test(arguments: [-180.0, 180.0])
  func `longitude boundaries are inclusive`(lon: Double) {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: 0, longitude: lon)
    #expect(errors.longitude == nil, "Longitude \(lon) is a valid boundary and must pass")
  }

  // MARK: - Out-of-range rejected

  @Test(arguments: [-90.0001, 90.0001, -91, 91, 322.2, -1000])
  func `out of range latitude is rejected`(lat: Double) {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: lat, longitude: 0)
    #expect(errors.latitude != nil, "Latitude \(lat) is out of range and must be flagged")
    #expect(errors.longitude == nil, "In-range longitude must stay valid")
  }

  @Test(arguments: [-180.0001, 180.0001, -181, 181, 5000, -5000])
  func `out of range longitude is rejected`(lon: Double) {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: 0, longitude: lon)
    #expect(errors.longitude != nil, "Longitude \(lon) is out of range and must be flagged")
    #expect(errors.latitude == nil, "In-range latitude must stay valid")
  }

  @Test
  func `ranges are not swapped`() {
    // 150 is a legal longitude but an illegal latitude; a swapped-range bug would pass this.
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: 150, longitude: 150)
    #expect(errors.latitude != nil, "150 exceeds the latitude range")
    #expect(errors.longitude == nil, "150 is within the longitude range")
  }

  // MARK: - Non-finite rejected

  @Test(arguments: [Double.nan, .infinity, -.infinity])
  func `non finite latitude is rejected`(lat: Double) {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: lat, longitude: 0)
    #expect(errors.latitude != nil, "Non-finite latitude \(lat) must be flagged")
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity])
  func `non finite longitude is rejected`(lon: Double) {
    let errors = NodeSettingsViewModel.validateIdentityFields(name: nil, latitude: 0, longitude: lon)
    #expect(errors.longitude != nil, "Non-finite longitude \(lon) must be flagged")
  }

  // MARK: - Name length

  @Test
  func `name at byte cap is valid`() {
    let name = String(repeating: "a", count: ProtocolLimits.maxUsableNameBytes)
    let errors = NodeSettingsViewModel.validateIdentityFields(name: name, latitude: nil, longitude: nil)
    #expect(errors.name == nil, "A name at the byte cap must pass")
  }

  @Test
  func `name over byte cap is rejected`() {
    let name = String(repeating: "a", count: ProtocolLimits.maxUsableNameBytes + 1)
    let errors = NodeSettingsViewModel.validateIdentityFields(name: name, latitude: nil, longitude: nil)
    #expect(errors.name != nil, "A name over the byte cap must be flagged")
  }

  @Test
  func `name byte cap counts UTF 8 bytes not characters`() {
    // Each emoji is 4 UTF-8 bytes, so 8 of them exceed the 31-byte cap despite being 8 characters.
    let name = String(repeating: "😀", count: 8)
    let errors = NodeSettingsViewModel.validateIdentityFields(name: name, latitude: nil, longitude: nil)
    #expect(errors.name != nil, "Name length must be measured in UTF-8 bytes")
  }

  @Test
  func `all three invalid reports all three`() {
    let name = String(repeating: "a", count: ProtocolLimits.maxUsableNameBytes + 1)
    let errors = NodeSettingsViewModel.validateIdentityFields(name: name, latitude: 200, longitude: 400)
    #expect(errors.name != nil)
    #expect(errors.latitude != nil)
    #expect(errors.longitude != nil)
    #expect(errors.hasErrors)
  }
}

@Suite("NodeSettingsViewModel identity apply guard")
@MainActor
struct NodeSettingsIdentityApplyGuardTests {
  /// Records every CLI command the view model emits and replies "OK" to each.
  @MainActor
  final class CommandRecorder {
    private(set) var commands: [String] = []
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      return "OK"
    }
  }

  private func makeConfiguredViewModel(recorder: CommandRecorder) -> NodeSettingsViewModel {
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Node",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    let viewModel = NodeSettingsViewModel()
    viewModel.configure(session: session, sendCommand: recorder.send, sendRawCommand: recorder.send)
    return viewModel
  }

  @Test
  func `out of range latitude blocks set lat`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.latitude = 999

    await viewModel.applyIdentitySettings()

    #expect(recorder.commands.isEmpty, "No command may be sent when a field is out of range")
    #expect(viewModel.latitudeError != nil, "The out-of-range field must be flagged inline")
    #expect(viewModel.identityApplySuccess == false)
  }

  @Test
  func `out of range longitude blocks set lon`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.longitude = -400

    await viewModel.applyIdentitySettings()

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.longitudeError != nil)
  }

  @Test
  func `over long name blocks set name`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.name = String(repeating: "a", count: ProtocolLimits.maxUsableNameBytes + 1)

    await viewModel.applyIdentitySettings()

    #expect(recorder.commands.isEmpty)
    #expect(viewModel.nameError != nil)
  }

  @Test
  func `valid coordinates are sent over the transport`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.latitude = 37.7749
    viewModel.longitude = -122.4194

    await viewModel.applyIdentitySettings()

    #expect(recorder.commands.contains { $0.hasPrefix("set lat 37.7749") })
    #expect(recorder.commands.contains { $0.hasPrefix("set lon -122.4194") })
    #expect(viewModel.latitudeError == nil)
    #expect(viewModel.longitudeError == nil)
  }

  @Test
  func `reapply clears stale errors once corrected`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)

    viewModel.latitude = 999
    await viewModel.applyIdentitySettings()
    #expect(viewModel.latitudeError != nil)

    viewModel.latitude = 45
    await viewModel.applyIdentitySettings()
    #expect(viewModel.latitudeError == nil, "Correcting the value must clear the stale inline error")
    #expect(recorder.commands.contains { $0.hasPrefix("set lat 45") })
  }
}

@Suite("NodeSettingsViewModel radio apply")
@MainActor
struct NodeSettingsRadioApplyTests {
  @MainActor
  final class CommandRecorder {
    private(set) var commands: [String] = []
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      return "OK"
    }
  }

  private func makeConfiguredViewModel(recorder: CommandRecorder) -> NodeSettingsViewModel {
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Node",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    let viewModel = NodeSettingsViewModel()
    viewModel.configure(session: session, sendCommand: recorder.send, sendRawCommand: recorder.send)
    return viewModel
  }

  @Test
  func `apply radio settings sends only set radio and clears modified flag`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.frequency = 915.0
    viewModel.bandwidth = 250.0
    viewModel.spreadingFactor = 10
    viewModel.codingRate = 5
    viewModel.radioSettingsModified = true

    await viewModel.applyRadioSettings()

    #expect(recorder.commands == ["set radio 915.0,250.0,10,5"])
    #expect(recorder.commands.contains { $0.contains("set tx") } == false)
    #expect(viewModel.radioSettingsModified == false)
  }

  @Test
  func `fetch radio settings reads the radio, then the TX power`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)

    await viewModel.fetchRadioSettings()

    #expect(recorder.commands == ["get radio", "get tx"])
  }
}

@Suite("NodeSettingsViewModel clock sync")
@MainActor
struct NodeSettingsClockSyncTests {
  @MainActor
  final class CommandRecorder {
    private(set) var commands: [String] = []
    var reply = "OK - clock set: 15:35 - 14/8/2026 UTC"
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      return reply
    }
  }

  private func makeConfiguredViewModel(recorder: CommandRecorder) -> NodeSettingsViewModel {
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Node",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    let viewModel = NodeSettingsViewModel()
    viewModel.configure(session: session, sendCommand: recorder.send, sendRawCommand: recorder.send)
    return viewModel
  }

  @Test
  func `syncTime sends clock sync for the service to stamp as it goes out`() async throws {
    // The service rewrites it to `time <epoch>` at send time, so a wait in the CLI queue can't
    // leave the time stale (covered by RemoteNodeCLICorrelationTests on the wire).
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)

    await viewModel.syncTime()

    #expect(recorder.commands == ["clock sync"])
  }

  @Test
  func `fetchDeviceInfo records drift from clock against a fixed now`() async throws {
    let recorder = CommandRecorder()
    recorder.reply = "06:40 - 18/4/2025 UTC"
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    let node = try #require(NodeSettingsResponseParser.utcDate(fromClockResponse: recorder.reply))
    viewModel.now = { node.addingTimeInterval(3600) }

    await viewModel.fetchDeviceInfo()

    #expect(viewModel.clockDrift == -3600)
  }

  @Test
  func `syncTime on OK with clock text updates device time and drift`() async throws {
    let recorder = CommandRecorder()
    recorder.reply = "OK - clock set: 15:35 - 14/8/2026 UTC"
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    let node = try #require(NodeSettingsResponseParser.utcDate(fromClockResponse: recorder.reply))
    viewModel.now = { node }

    await viewModel.syncTime()

    #expect(recorder.commands.count == 1)
    #expect(viewModel.clockDrift == 0)
    #expect(viewModel.deviceTime != nil)
  }

  @Test
  func `syncTime on bare OK hides the warning without a second command`() async {
    let recorder = CommandRecorder()
    recorder.reply = "OK - clock set"
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.clockDrift = -10000

    await viewModel.syncTime()

    #expect(recorder.commands.count == 1)
    #expect(viewModel.clockDrift == nil)
  }
}

@Suite("NodeSettingsViewModel contact info")
@MainActor
struct NodeSettingsContactInfoTests {
  @MainActor
  final class CommandRecorder {
    private(set) var commands: [String] = []
    var reply = "OK"
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      return reply
    }
  }

  private func makeConfiguredViewModel(recorder: CommandRecorder) -> NodeSettingsViewModel {
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Node",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    let viewModel = NodeSettingsViewModel()
    viewModel.configure(session: session, sendCommand: recorder.send, sendRawCommand: recorder.send)
    return viewModel
  }

  @Test
  func `apply converts display newlines to the pipe wire form`() async {
    let recorder = CommandRecorder()
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.setNodeInfo(firmwareVersion: "v1.17.1", name: "Repeater", ownerInfo: "KD7ABC")
    viewModel.ownerInfo = "KD7ABC\nch 31"

    await viewModel.applyContactInfoSettings()

    #expect(recorder.commands == ["set owner.info KD7ABC|ch 31"])
  }

  @Test
  func `apply failure sets errorMessage`() async {
    let recorder = CommandRecorder()
    recorder.reply = "ERR: not allowed"
    let viewModel = makeConfiguredViewModel(recorder: recorder)
    viewModel.setNodeInfo(firmwareVersion: "v1.17.1", name: "Repeater", ownerInfo: "old")
    viewModel.ownerInfo = "new"

    await viewModel.applyContactInfoSettings()

    #expect(viewModel.errorMessage != nil)
    #expect(viewModel.contactInfoApplySuccess == false)
    #expect(viewModel.originalOwnerInfo == "old")
  }
}

@Suite("NodeSettingsViewModel refused clock sync")
@MainActor
struct NodeSettingsRefusedClockSyncTests {
  /// Replies per command, in order; a command with none left times out.
  @MainActor
  final class ScriptedNode {
    private(set) var commands: [String] = []
    var replies: [String: [String]] = [:]
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      guard var queue = replies[command], !queue.isEmpty else { throw RemoteNodeError.timeout }
      let reply = queue.removeFirst()
      replies[command] = queue
      return reply
    }
  }

  private static let refused = "(ERR: clock cannot go backwards)"
  private static let clockReply = "15:35 - 14/8/2026 UTC"

  private func makeViewModel(_ node: ScriptedNode) -> NodeSettingsViewModel {
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Node",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    let viewModel = NodeSettingsViewModel()
    viewModel.configure(session: session, sendCommand: node.send, sendRawCommand: node.send)
    return viewModel
  }

  @Test
  func `a refusal from a clock read moments ago as right is a sync, without another command`() async {
    let node = ScriptedNode()
    node.replies["clock sync"] = [Self.refused]
    let viewModel = makeViewModel(node)
    viewModel.clockDrift = 3

    await viewModel.syncTime()

    #expect(node.commands == ["clock sync"])
    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.showSuccessAlert)
  }

  @Test
  func `a refusal from a clock read far ahead keeps the clock-ahead warning`() async {
    let node = ScriptedNode()
    node.replies["clock sync"] = [Self.refused]
    let viewModel = makeViewModel(node)
    viewModel.clockDrift = 3600

    await viewModel.syncTime()

    #expect(node.commands == ["clock sync"])
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.clockAheadError)
    #expect(!viewModel.showSuccessAlert)
  }

  @Test
  func `a refusal after an unanswered sync is a sync`() async {
    let node = ScriptedNode()
    node.replies["clock sync"] = [] // the first times out
    let viewModel = makeViewModel(node)

    await viewModel.syncTime()
    #expect(viewModel.lastClockSyncUnanswered)
    #expect(viewModel.errorMessage != nil)

    node.replies["clock sync"] = [Self.refused]
    await viewModel.syncTime()

    #expect(node.commands == ["clock sync", "clock sync"])
    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.showSuccessAlert)
    #expect(!viewModel.lastClockSyncUnanswered)
  }

  @Test
  func `an unread clock is read to decide, and a close one is a sync`() async throws {
    let node = ScriptedNode()
    node.replies["clock sync"] = [Self.refused]
    node.replies["clock"] = [Self.clockReply]
    let viewModel = makeViewModel(node)
    let nodeTime = try #require(NodeSettingsResponseParser.utcDate(fromClockResponse: Self.clockReply))
    viewModel.now = { nodeTime.addingTimeInterval(20) }

    await viewModel.syncTime()

    #expect(node.commands == ["clock sync", "clock"])
    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.showSuccessAlert)
    #expect(viewModel.clockDrift == -20)
  }

  @Test
  func `an unread clock read far ahead keeps the clock-ahead warning`() async throws {
    let node = ScriptedNode()
    node.replies["clock sync"] = [Self.refused]
    node.replies["clock"] = [Self.clockReply]
    let viewModel = makeViewModel(node)
    let nodeTime = try #require(NodeSettingsResponseParser.utcDate(fromClockResponse: Self.clockReply))
    viewModel.now = { nodeTime.addingTimeInterval(-3600) }

    await viewModel.syncTime()

    #expect(node.commands == ["clock sync", "clock"])
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.clockAheadError)
  }

  @Test
  func `an unread clock that can't be read keeps the clock-ahead warning`() async {
    let node = ScriptedNode()
    node.replies["clock sync"] = [Self.refused]
    let viewModel = makeViewModel(node)

    await viewModel.syncTime()

    #expect(node.commands == ["clock sync", "clock"])
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.clockAheadError)
  }
}

@Suite("NodeSettingsViewModel cairn.cfg memory")
@MainActor
struct NodeSettingsCairnConfigMemoryTests {
  @MainActor
  final class CommandRecorder {
    private(set) var commands: [String] = []
    var reply = "> ??: cairn.cfg"
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String {
      commands.append(command)
      return reply
    }
  }

  private let publicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

  private func defaults() -> UserDefaults {
    let name = "NodeSettingsCairnConfigMemoryTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  private func makeViewModel(_ recorder: CommandRecorder, defaults: UserDefaults) -> NodeSettingsViewModel {
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: publicKey,
      name: "Test Node",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
    let viewModel = NodeSettingsViewModel()
    viewModel.cairnConfigSupportDefaults = defaults
    viewModel.configure(session: session, sendCommand: recorder.send, sendRawCommand: recorder.send)
    return viewModel
  }

  @Test
  func `a stock repeater is asked once, not again on the next visit`() async {
    let d = defaults()
    let recorder = CommandRecorder()

    let first = makeViewModel(recorder, defaults: d)
    #expect(await first.fetchCairnConfig() == nil)
    #expect(first.cairnConfigUnsupported)

    let next = makeViewModel(recorder, defaults: d)
    #expect(await next.fetchCairnConfig() == nil)
    #expect(next.cairnConfigUnsupported)
    #expect(recorder.commands == [CairnNodeConfig.query])
  }

  @Test
  func `a reply that isn't a clear unknown setting is asked again next visit`() async {
    let d = defaults()
    let recorder = CommandRecorder()
    recorder.reply = "> 910.525,62.5,7,5"

    _ = await makeViewModel(recorder, defaults: d).fetchCairnConfig()
    _ = await makeViewModel(recorder, defaults: d).fetchCairnConfig()

    #expect(recorder.commands == [CairnNodeConfig.query, CairnNodeConfig.query])
  }

  @Test
  func `a firmware change asks again`() async {
    let d = defaults()
    let recorder = CommandRecorder()
    let first = makeViewModel(recorder, defaults: d)
    first.setNodeInfo(firmwareVersion: "v1.17.1", name: nil, ownerInfo: nil)
    _ = await first.fetchCairnConfig()

    recorder.reply = "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=18|rp=on|ai=240|fai=12|fm=64|n=Hilltop"
    let next = makeViewModel(recorder, defaults: d)
    next.setNodeInfo(firmwareVersion: "Cairn v118", name: nil, ownerInfo: nil)
    #expect(await next.fetchCairnConfig() != nil)
    #expect(recorder.commands == [CairnNodeConfig.query, CairnNodeConfig.query])
  }

  /// A T096 repeater on newer Cairn firmware: the TX controls stop at its cap (16), not the old 30,
  /// and its antenna figures mark it as amplified.
  @Test
  func `a node reporting its TX limits bounds the controls by them`() async {
    let recorder = CommandRecorder()
    recorder.reply = "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=9|txm=16|txa=23,28|rp=on|ai=240|fai=12|fm=64|n=T096"
    let viewModel = makeViewModel(recorder, defaults: defaults())
    #expect(await viewModel.fetchCairnConfig() != nil)
    #expect(viewModel.txPowerRange == -9...16)
    #expect(viewModel.txPowerMax == 16)
    #expect(viewModel.txAntennaPower == 23)
    #expect(viewModel.txAntennaMax == 28)
    #expect(viewModel.txIsAmplified)
    #expect(!viewModel.txSettingIsAntennaPower)   // the picker says "Radio setting"
  }

  @Test
  func `older firmware gets the chip's range and no amplifier claim`() async {
    let recorder = CommandRecorder()
    recorder.reply = "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=30|rp=on|ai=240|fai=12|fm=64|n=Old"
    let viewModel = makeViewModel(recorder, defaults: defaults())
    #expect(await viewModel.fetchCairnConfig() != nil)
    // The chip's 22: an old unchecked "set tx 30" is shown on its own, never offered (nor 23...29).
    #expect(viewModel.txPowerRange == -9...22)
    #expect(viewModel.originalTxPower == 30)
    #expect(!viewModel.txIsAmplified)
    #expect(!viewModel.txSettingIsAntennaPower)   // unknown board: labelled as the setting it is
  }

  /// A node whose `get cairn.cfg` was lost offers the chip's 22. When it refuses a pick past its cap
  /// ("Error: range -9..16"), the controls narrow to that, the pick comes into it, and the error
  /// names the range. Both apply paths: TX alone, and TX with the other radio parameters.
  @Test(arguments: [false, true])
  func `a refused set tx narrows the controls to the node's range`(withRadio: Bool) async {
    let recorder = CommandRecorder()
    recorder.reply = "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=9|rp=on|ai=240|fai=12|fm=64|n=T096"
    let viewModel = makeViewModel(recorder, defaults: defaults())
    #expect(await viewModel.fetchCairnConfig() != nil)
    #expect(viewModel.txPowerRange == -9...22)

    recorder.reply = "> Error: range -9..16"
    viewModel.txPower = 20
    viewModel.txPowerModified = true
    if withRadio { viewModel.radioSettingsModified = true }
    await viewModel.applyRadioSettings()

    #expect(recorder.commands.last == "set tx 20")
    #expect(viewModel.txPowerMax == 16)
    #expect(viewModel.txPowerRange == -9...16)
    #expect(viewModel.txPower == 16)
    #expect(viewModel.originalTxPower == 9)
    #expect(viewModel.txPowerModified)
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.txPowerOutOfRange(-9, 16))
  }

  @Test
  func `a refused set tx without a range keeps the generic failure`() async {
    let recorder = CommandRecorder()
    recorder.reply = "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=9|rp=on|ai=240|fai=12|fm=64|n=Old"
    let viewModel = makeViewModel(recorder, defaults: defaults())
    #expect(await viewModel.fetchCairnConfig() != nil)

    recorder.reply = "> Error: busy"
    viewModel.txPower = 20
    viewModel.txPowerModified = true
    await viewModel.applyRadioSettings()

    #expect(viewModel.txPowerRange == -9...22)
    #expect(viewModel.txPower == 20)
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Settings.radioApplyFailed)
  }

  @Test
  func `a bare board's equal antenna figures are not an amplifier`() async {
    let recorder = CommandRecorder()
    recorder.reply = "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=22|txm=22|txa=22,22|rp=on|ai=240|fai=12|fm=64|n=V3"
    let viewModel = makeViewModel(recorder, defaults: defaults())
    #expect(await viewModel.fetchCairnConfig() != nil)
    #expect(viewModel.txPowerRange == -9...22)
    #expect(!viewModel.txIsAmplified)
    #expect(viewModel.txSettingIsAntennaPower)
  }
}

@Suite("RepeaterControlsModel front-end LNA")
@MainActor
struct RepeaterControlsLNATests {
  @MainActor
  final class Replier {
    var reply = "Error: unsupported"
    func send(_ id: UUID, _ command: String, _ timeout: Duration) async throws -> String { reply }
  }

  private var lna: RepeaterTunable {
    RepeaterControlsModel.switches.first { $0.key == "radio.fem.rxgain" }!
  }

  @Test
  func `a repeater with a front end shows its LNA as on or off`() {
    #expect(RepeaterControlsModel.readState("> on", for: lna) == .value("on"))
    #expect(RepeaterControlsModel.readState("> off", for: lna) == .value("off"))
  }

  @Test
  func `a board without one reads as not supported, not as off`() {
    // what a repeater's CommonCLI answers for a setting it doesn't know, and a Heltec V4.2
    #expect(RepeaterControlsModel.readState("??: radio.fem.rxgain", for: lna) == .unsupported)
    #expect(RepeaterControlsModel.readState("> ??: radio.fem.rxgain", for: lna) == .unsupported)
    #expect(RepeaterControlsModel.readState("Error: unsupported", for: lna) == .unsupported)
    #expect(RepeaterControlsModel.readState("Error: unknown command", for: lna) == .unsupported)
    #expect(RepeaterControlsModel.readState("Error: busy", for: lna) == .failed)
  }

  @Test
  func `a setting the repeater doesn't have is left off the page`() async {
    let replier = Replier()
    let settings = NodeSettingsViewModel()
    settings.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(), publicKey: Data(repeating: 0x42, count: 32), name: "Test Node",
        role: .repeater, isConnected: true, permissionLevel: .admin
      ),
      sendCommand: replier.send,
      sendRawCommand: replier.send
    )
    let model = RepeaterControlsModel(settings: settings)
    #expect(model.shown(RepeaterControlsModel.switches).contains { $0.key == lna.key }, "shown while it loads")

    await model.read(lna)
    #expect(model.states[lna.key] == .unsupported)
    #expect(!model.shown(RepeaterControlsModel.switches).contains { $0.key == lna.key })

    replier.reply = "> on"
    await model.read(lna)
    #expect(model.shown(RepeaterControlsModel.switches).contains { $0.key == lna.key })
  }

  @Test
  func `a set the repeater doesn't know is recognised`() {
    #expect(RepeaterControlsModel.isNoSuchSetting("unknown config: radio.fem.rxgain on"))
    #expect(!RepeaterControlsModel.isNoSuchSetting("OK"))
    #expect(!RepeaterControlsModel.isNoSuchSetting("> on"))
  }
}

@Suite("RepeaterControlsModel command outcome")
@MainActor
struct RepeaterControlsCommandOutcomeTests {
  private var gpsSync: RepeaterCommand {
    RepeaterControlsModel.commands.first { $0.command == "gps sync" }!
  }

  @Test
  func `gps sync succeeds only on an OK`() {
    #expect(RepeaterControlsModel.succeeded(gpsSync, reply: "> ok"))
    #expect(RepeaterControlsModel.succeeded(gpsSync, reply: "OK"))
    #expect(!RepeaterControlsModel.succeeded(gpsSync, reply: "> gps provider not found"))
    #expect(!RepeaterControlsModel.succeeded(gpsSync, reply: "ERR: busy"))
  }

  @Test
  func `other commands still succeed on any reply but an error`() {
    let erase = RepeaterControlsModel.commands.first { $0.command == "log erase" }!
    #expect(RepeaterControlsModel.succeeded(erase, reply: "   log erased"))
    #expect(!RepeaterControlsModel.succeeded(erase, reply: "Error: unknown command"))
  }
}
