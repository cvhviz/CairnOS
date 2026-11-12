import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Quiet node state after reboot and power-off")
@MainActor
struct NodeQuietStateTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func `live is not quiet and needs no wait`() {
    #expect(!NodeQuietState.live.isQuiet)
    #expect(NodeQuietState.live.secondsUntilReconnect(now: start) == 0)
    #expect(NodeQuietState.live.message(now: start) == nil)
  }

  @Test
  func `rebooting counts down the reboot wait, then allows a reconnect`() {
    let state = NodeQuietState.rebooting(since: start)
    #expect(state.isQuiet)
    #expect(state.secondsUntilReconnect(now: start) == Int(NodeQuietState.rebootWait))
    #expect(!state.canReconnect(now: start))
    #expect(state.secondsUntilReconnect(now: start.addingTimeInterval(10)) == 20)
    #expect(state.canReconnect(now: start.addingTimeInterval(NodeQuietState.rebootWait)))
    #expect(state.secondsUntilReconnect(now: start.addingTimeInterval(90)) == 0)
    #expect(state.message(now: start) != state.message(now: start.addingTimeInterval(90)))
  }

  @Test
  func `powered off allows a reconnect straight away`() {
    let state = NodeQuietState.poweredOff(since: start)
    #expect(state.isQuiet)
    #expect(state.canReconnect(now: start))
    #expect(state.message(now: start) != nil)
  }

  private func makeSettings(reply: @escaping (String) throws -> String) -> (NodeSettingsViewModel, () -> [UUID]) {
    let settings = NodeSettingsViewModel()
    var quietSessions: [UUID] = []
    settings.now = { [start] in start }
    settings.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(), publicKey: Data(repeating: 7, count: 32), name: "R", role: .repeater,
        isConnected: true, permissionLevel: .admin
      ),
      sendCommand: { _, command, _ in try reply(command) },
      sendRawCommand: { _, command, _ in try reply(command) }
    )
    settings.onSessionQuiet = { quietSessions.append($0) }
    return (settings, { quietSessions })
  }

  @Test
  func `a reboot that times out still marks the node rebooting and the session quiet`() async throws {
    let (settings, quiet) = makeSettings { _ in throw RemoteNodeError.timeout }
    await settings.reboot()
    #expect(settings.quietState == .rebooting(since: start))
    #expect(!settings.showSuccessAlert, "The banner replaces the alert")
    try await Task.sleep(for: .milliseconds(50))
    #expect(quiet().count == 1)
  }

  @Test
  func `a power-off marks the node off, and a fresh login brings it back`() async throws {
    let (settings, quiet) = makeSettings { _ in "OK" }
    settings.markPoweredOff()
    #expect(settings.quietState == .poweredOff(since: start))
    try await Task.sleep(for: .milliseconds(50))
    #expect(quiet().count == 1)
    settings.markLive()
    #expect(settings.quietState == .live)
  }

  @Test
  func `the controls' poweroff hands the quiet state on`() async {
    let (settings, _) = makeSettings { _ in throw RemoteNodeError.timeout }
    let controls = RepeaterControlsModel(settings: settings)
    guard let powerOff = RepeaterControlsModel.commands.first(where: { $0.command == "poweroff" }) else {
      Issue.record("No poweroff command")
      return
    }
    await controls.run(powerOff)
    #expect(settings.quietState.isQuiet)
    #expect(controls.outcome?.succeeded == true)
  }
}
