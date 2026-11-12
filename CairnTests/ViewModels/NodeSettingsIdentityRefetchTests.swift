import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// Covers re-reading identity while the user is editing it: the node's answer becomes the new
/// baseline, but it must not replace what was typed while the request was in flight.
@Suite("NodeSettingsViewModel identity re-fetch")
@MainActor
struct NodeSettingsIdentityRefetchTests {
  /// Scripted node replies, with a hook that runs while a command is in flight.
  @MainActor
  private final class ScriptedNode {
    var responses: [String: String] = [:]
    var whileInFlight: [String: @MainActor () -> Void] = [:]
  }

  private func makeViewModel(_ node: ScriptedNode) -> NodeSettingsViewModel {
    let viewModel = NodeSettingsViewModel()
    let send: (UUID, String, Duration) async throws -> String = { _, command, _ in
      node.whileInFlight[command]?()
      guard let response = node.responses[command] else { throw RemoteNodeError.timeout }
      return response
    }
    viewModel.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(),
        publicKey: Data(repeating: 0xCC, count: 32),
        name: "TestNode",
        role: .repeater
      ),
      sendCommand: send,
      sendRawCommand: send
    )
    return viewModel
  }

  private func loadedViewModel(_ node: ScriptedNode) async -> NodeSettingsViewModel {
    node.responses = ["get name": "Alpha Repeater", "get lat": "38.5", "get lon": "-122.4"]
    let viewModel = makeViewModel(node)
    await viewModel.fetchIdentity()
    return viewModel
  }

  @Test
  func `a re-fetch shows the node's new values when nothing was edited`() async {
    let node = ScriptedNode()
    let viewModel = await loadedViewModel(node)

    node.responses["get lat"] = "40.25"
    node.responses["get lon"] = "-120.75"
    await viewModel.fetchIdentity()

    #expect(viewModel.latitude == 40.25)
    #expect(viewModel.longitude == -120.75)
    #expect(!viewModel.identitySettingsModified)
  }

  @Test
  func `an edit made while the re-fetch is in flight is kept and stays pending`() async {
    let node = ScriptedNode()
    let viewModel = await loadedViewModel(node)

    node.whileInFlight["get lat"] = { viewModel.latitude = -37.8 }
    node.whileInFlight["get lon"] = { viewModel.longitude = 144.9 }
    await viewModel.fetchIdentity()

    #expect(viewModel.latitude == -37.8)
    #expect(viewModel.longitude == 144.9)
    #expect(viewModel.originalLatitude == 38.5)
    #expect(viewModel.originalLongitude == -122.4)
    #expect(viewModel.identitySettingsModified)
  }

  @Test
  func `a location picked before the first load survives it`() async {
    let node = ScriptedNode()
    node.responses = ["get name": "Alpha Repeater", "get lat": "38.5", "get lon": "-122.4"]
    let viewModel = makeViewModel(node)
    viewModel.setLocationFromPicker(latitude: -37.8, longitude: 144.9)

    await viewModel.fetchIdentity()

    #expect(viewModel.name == "Alpha Repeater")
    #expect(viewModel.latitude == -37.8)
    #expect(viewModel.longitude == 144.9)
    #expect(viewModel.originalLatitude == 38.5)
    #expect(viewModel.identitySettingsModified)
  }

  @Test
  func `the name seeded from the session is replaced by the node's name`() async {
    let node = ScriptedNode()
    node.responses = ["get name": "Alpha Repeater", "get lat": "38.5", "get lon": "-122.4"]
    let viewModel = makeViewModel(node)
    viewModel.name = "TestNode"

    await viewModel.fetchIdentity()

    #expect(viewModel.name == "Alpha Repeater")
    #expect(!viewModel.identitySettingsModified)
  }

  @Test
  func `a name typed while it is being fetched is kept`() async {
    let node = ScriptedNode()
    node.responses = ["get name": "Alpha Repeater", "get lat": "38.5", "get lon": "-122.4"]
    let viewModel = makeViewModel(node)
    viewModel.name = "TestNode"
    node.whileInFlight["get name"] = { viewModel.name = "Ridge Repeater" }

    await viewModel.fetchIdentity()

    #expect(viewModel.name == "Ridge Repeater")
    #expect(viewModel.originalName == "Alpha Repeater")
    #expect(viewModel.identitySettingsModified)
  }

  @Test
  func `a belated coordinate reply does not replace an edit`() async {
    let node = ScriptedNode()
    let viewModel = await loadedViewModel(node)

    node.responses["get lat"] = nil
    await viewModel.fetchIdentity()
    viewModel.latitude = -37.8

    viewModel.handleCommonLateResponse("40.25")

    #expect(viewModel.latitude == -37.8)
    #expect(viewModel.originalLatitude == 40.25)
  }
}
