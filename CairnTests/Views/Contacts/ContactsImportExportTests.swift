import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// The Saved list's file exchange: an export carries each saved node as the nodes file does, a
/// file read back is planned against what is saved (new, already saved, over the limit, the
/// radio's own key), and a confirmation with no radio says so instead of writing anything.
@Suite("ContactsViewModel import and export")
@MainActor
struct ContactsImportExportTests {
  private static func key(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: ProtocolLimits.publicKeySize)
  }

  private func makeContact(
    _ keyByte: UInt8,
    name: String,
    type: ContactType = .repeater,
    latitude: Double = 0,
    longitude: Double = 0,
    lastAdvertTimestamp: UInt32 = 1_700_000_000
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Self.key(keyByte),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0xFF,
      outPath: Data(),
      lastAdvertTimestamp: lastAdvertTimestamp,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: "Nick",
      isBlocked: false,
      isMuted: false,
      isFavorite: true,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private static func node(_ keyByte: UInt8, name: String = "Node") -> DiscoveredNodesFile.Node {
    DiscoveredNodesFile.Node(
      publicKey: key(keyByte),
      name: name,
      type: .repeater,
      latitude: nil,
      longitude: nil,
      lastAdvertTimestamp: 1_700_000_000,
      lastHeard: Date(timeIntervalSince1970: 1_700_000_500)
    )
  }

  private func writeFile(nodes: [DiscoveredNodesFile.Node]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("contacts-import-\(UUID().uuidString).json")
    try DiscoveredNodesFile.encode(nodes).write(to: url)
    return url
  }

  /// Runs `importFile` and waits for the read, validation, and preview to finish.
  private func stageImport(of url: URL, in viewModel: ContactsViewModel, maxContacts: Int? = nil, selfKey: Data? = nil) async {
    viewModel.importFile(at: url, maxContacts: maxContacts, selfPublicKey: selfKey)
    while viewModel.isTransferringFile {
      await Task.yield()
    }
  }

  // MARK: - Export

  /// The file carries the radio's name for the node, not this phone's nickname, and a position
  /// only when the node has one.
  @Test func `export nodes carry name, type, position and last advert`() {
    let located = makeContact(0xA1, name: "Hilltop", latitude: 45.4215, longitude: -75.6972)
    let unlocated = makeContact(0xB2, name: "Valley", type: .chat)

    let nodes = ContactsViewModel.exportNodes(from: [located, unlocated])

    #expect(nodes.map(\.name) == ["Hilltop", "Valley"])
    #expect(nodes.map(\.type) == [.repeater, .chat])
    #expect(nodes[0].latitude == 45.4215)
    #expect(nodes[0].longitude == -75.6972)
    #expect(nodes[1].latitude == nil)
    #expect(nodes[1].longitude == nil)
    #expect(nodes.map(\.lastAdvertTimestamp) == [1_700_000_000, 1_700_000_000])
  }

  @Test func `export stages a file that reads back as the same nodes`() throws {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [makeContact(0xA1, name: "Hilltop"), makeContact(0xB2, name: "Valley")]

    viewModel.exportContacts()

    let file = try #require(viewModel.exportedFile)
    #expect(viewModel.isSharingExport)
    #expect(viewModel.errorMessage == nil)
    #expect(file.recordCount == 2)
    #expect(file.filename.hasPrefix("Cairn-saved-nodes-"))
    #expect(file.filename.hasSuffix(".json"))

    let url = try #require(file.url)
    let contents = try DiscoveredNodesFile.parse(DiscoveredNodesFile.read(contentsOf: url))
    #expect(contents.nodes.map(\.name) == ["Hilltop", "Valley"])
    #expect(contents.nodes.map(\.publicKey) == [Self.key(0xA1), Self.key(0xB2)])

    viewModel.discardExport()
    #expect(viewModel.exportedFile == nil)
    #expect(!viewModel.isSharingExport)
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }

  @Test func `export of an empty list reports that there is nothing to export`() {
    let viewModel = ContactsViewModel()

    viewModel.exportContacts()

    #expect(viewModel.exportedFile == nil)
    #expect(viewModel.errorMessage == L10n.Settings.Settings.DataExport.empty)
  }

  // MARK: - Planning

  @Test func `plan separates new nodes from saved ones and leaves out the radio's own key`() {
    let preview = ContactsViewModel.plan(
      [Self.node(0xA1), Self.node(0xB2), Self.node(0x01), Self.node(0xC3)],
      invalidCount: 2,
      savedKeys: [Self.key(0xB2)],
      selfPublicKey: Self.key(0x01),
      capacityRemaining: nil
    )

    #expect(preview.nodes.map(\.publicKey) == [Self.key(0xA1), Self.key(0xC3)])
    #expect(preview.newCount == 2)
    #expect(preview.fileNodeCount == 3)
    #expect(preview.alreadySavedCount == 1)
    #expect(preview.overCapacityCount == 0)
    #expect(preview.invalidCount == 2)
    #expect(preview.changesAnything)
  }

  @Test func `plan keeps the new nodes to the room the radio has left, in file order`() {
    let preview = ContactsViewModel.plan(
      [Self.node(0xA1), Self.node(0xB2), Self.node(0xC3)],
      invalidCount: 0,
      savedKeys: [],
      selfPublicKey: nil,
      capacityRemaining: 2
    )

    #expect(preview.nodes.map(\.publicKey) == [Self.key(0xA1), Self.key(0xB2)])
    #expect(preview.overCapacityCount == 1)

    let full = ContactsViewModel.plan([Self.node(0xA1)], invalidCount: 0, savedKeys: [], selfPublicKey: nil, capacityRemaining: 0)
    #expect(full.nodes.isEmpty)
    #expect(full.overCapacityCount == 1)
    #expect(!full.changesAnything)
  }

  @Test func `a file with nothing new is previewed as such`() {
    let preview = ContactsViewModel.plan(
      [Self.node(0xA1)],
      invalidCount: 0,
      savedKeys: [Self.key(0xA1)],
      selfPublicKey: nil,
      capacityRemaining: nil
    )

    #expect(!preview.changesAnything)
    #expect(ContactsViewModel.previewMessage(for: preview).hasPrefix(L10n.Contacts.Contacts.Discovery.Import.nothingNew))
  }

  // MARK: - Round Trip

  /// An export read back in plans every exported node as already saved, and a node the file
  /// adds as new.
  @Test func `an export imports back as already saved`() async throws {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [makeContact(0xA1, name: "Hilltop"), makeContact(0xB2, name: "Valley")]
    let url = try writeFile(nodes: ContactsViewModel.exportNodes(from: viewModel.contacts) + [Self.node(0xC3, name: "Ridge")])
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel, maxContacts: 10)

    let preview = try #require(viewModel.importPreview)
    #expect(viewModel.errorMessage == nil)
    #expect(preview.fileNodeCount == 3)
    #expect(preview.alreadySavedCount == 2)
    #expect(preview.nodes.map(\.name) == ["Ridge"])
    #expect(preview.overCapacityCount == 0)

    viewModel.cancelImport()
    #expect(viewModel.importPreview == nil)
  }

  @Test func `the radio's limit counts the nodes already saved`() async throws {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [makeContact(0xA1, name: "Hilltop"), makeContact(0xB2, name: "Valley")]
    let url = try writeFile(nodes: [Self.node(0xC3), Self.node(0xD4)])
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel, maxContacts: 3)

    let preview = try #require(viewModel.importPreview)
    #expect(preview.nodes.map(\.publicKey) == [Self.key(0xC3)])
    #expect(preview.overCapacityCount == 1)
  }

  @Test func `a file of another format is refused`() async throws {
    let viewModel = ContactsViewModel()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("contacts-import-\(UUID().uuidString).json")
    try Data("{\"format\":\"cairn.backup\",\"version\":1,\"nodes\":[]}".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel)

    #expect(viewModel.importPreview == nil)
    #expect(viewModel.errorMessage == L10n.Contacts.Contacts.Discovery.Import.Error.wrongFormat)
  }

  /// Without a radio the nodes have nowhere to go; the preview is dropped and the reason said.
  @Test func `a confirmation without a radio reports it and adds nothing`() async {
    let viewModel = ContactsViewModel()
    let preview = ContactsViewModel.plan([Self.node(0xA1)], invalidCount: 0, savedKeys: [], selfPublicKey: nil, capacityRemaining: nil)
    viewModel.importPreview = preview

    let changed = await viewModel.confirmImport(preview, radioID: nil)

    #expect(!changed)
    #expect(viewModel.importPreview == nil)
    #expect(viewModel.errorMessage == L10n.Contacts.Contacts.Add.Error.notConnected)
    #expect(viewModel.importResult == nil)
  }

  @Test func `a file's node becomes a flood-routed contact frame`() {
    let frame = ContactsViewModel.contactFrame(for: Self.node(0xA1, name: "Hilltop"), now: 42)

    #expect(frame.publicKey == Self.key(0xA1))
    #expect(frame.name == "Hilltop")
    #expect(frame.type == .repeater)
    #expect(frame.outPathLength == PacketBuilder.floodPathSentinel)
    #expect(frame.lastModified == 42)
  }
}
