import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The Controls page reads a repeater's settings a group at a time, only when the group is opened:
/// each read is a request and a reply over the mesh.
@Suite("RepeaterControlsModel groups")
@MainActor
struct RepeaterControlsGroupsTests {
  @Test
  func `every setting is in exactly one group`() {
    let grouped = RepeaterControlsModel.groups.flatMap(\.keys)
    let all = (RepeaterControlsModel.tuning + RepeaterControlsModel.switches).map(\.key)
    #expect(grouped.count == Set(grouped).count, "A key in two groups")
    #expect(Set(grouped) == Set(all), "A setting no group shows, or a group key with no setting")
    for group in RepeaterControlsModel.groups {
      #expect(RepeaterControlsModel.tunables(in: group).count == group.keys.count, "\(group.id)")
      #expect(group.keys.count <= 5, "\(group.id): a group stays a few reads")
    }
  }

  /// What the model sent, in order.
  final class Sent: @unchecked Sendable {
    var commands: [String] = []
  }

  private func makeModel() -> (RepeaterControlsModel, Sent) {
    let settings = NodeSettingsViewModel()
    let sent = Sent()
    settings.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(), publicKey: Data(repeating: 9, count: 32), name: "R", role: .repeater,
        isConnected: true, permissionLevel: .admin
      ),
      sendCommand: { _, command, _ in sent.commands.append(command); return "> 1.0" },
      sendRawCommand: { _, command, _ in sent.commands.append(command); return "> 1.0" }
    )
    return (RepeaterControlsModel(settings: settings), sent)
  }

  @Test
  func `nothing is read until a group is opened, then only that group`() async {
    let (model, sent) = makeModel()
    for group in RepeaterControlsModel.groups { #expect(model.progress(of: group) == .notRead) }
    let timing = RepeaterControlsModel.groups[0]
    await model.load(timing)
    #expect(sent.commands == timing.keys.map { "get \($0)" })
    #expect(model.progress(of: timing) == .read)
    #expect(model.progress(of: RepeaterControlsModel.groups[1]) == .notRead)
  }

  @Test
  func `opening a group again sends nothing, a refresh reads it again`() async {
    let (model, sent) = makeModel()
    let timing = RepeaterControlsModel.groups[0]
    await model.load(timing)
    let first = sent.commands.count
    await model.load(timing)
    #expect(sent.commands.count == first, "Read this visit already")
    await model.load(timing, again: true)
    #expect(sent.commands.count == first * 2)
  }
}
