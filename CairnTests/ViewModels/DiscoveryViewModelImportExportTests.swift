import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("DiscoveryViewModel import and export")
@MainActor
struct DiscoveryViewModelImportExportTests {
  private let selfPublicKey = Data(repeating: 0x01, count: ProtocolLimits.publicKeySize)

  /// The radio the view model treats as current; tests switch it to stand in for a reconnect.
  @MainActor
  private final class CurrentRadio {
    var id: UUID? = UUID()
  }

  private static func key(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: ProtocolLimits.publicKeySize)
  }

  private static func node(
    _ keyByte: UInt8,
    name: String = "Node",
    advert: UInt32 = 1_700_000_000
  ) -> DiscoveredNodesFile.Node {
    DiscoveredNodesFile.Node(
      publicKey: key(keyByte),
      name: name,
      type: .repeater,
      latitude: 45.4215,
      longitude: -75.6972,
      lastAdvertTimestamp: advert,
      lastHeard: Date(timeIntervalSince1970: 1_700_000_500)
    )
  }

  private func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  private func makeViewModel(store: PersistenceStore, radio: CurrentRadio) -> DiscoveryViewModel {
    let viewModel = DiscoveryViewModel()
    let selfPublicKey = selfPublicKey
    viewModel.configure(
      dataStore: { store },
      radioID: { radio.id },
      selfPublicKey: { selfPublicKey }
    )
    return viewModel
  }

  private func writeFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("discovery-import-\(UUID().uuidString).json")
    try data.write(to: url)
    return url
  }

  private func writeFile(nodes: [DiscoveredNodesFile.Node]) throws -> URL {
    try writeFile(DiscoveredNodesFile.encode(nodes))
  }

  /// Runs `importFile` and waits for the read, validation, and preview to finish.
  private func stageImport(of url: URL, in viewModel: DiscoveryViewModel) async {
    viewModel.importFile(at: url)
    while viewModel.isTransferringFile {
      await Task.yield()
    }
  }

  // MARK: - Export

  @Test
  func `export stages a file that holds the radio's nodes`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let radioID = try #require(radio.id)
    try await store.importDiscoveredNodes(
      [Self.node(0xA1, name: "Hilltop"), Self.node(0xB2, name: "Valley")],
      radioID: radioID,
      selfPublicKey: nil
    )
    try await store.importDiscoveredNodes([Self.node(0xC3, name: "Elsewhere")], radioID: UUID(), selfPublicKey: nil)
    let viewModel = makeViewModel(store: store, radio: radio)

    await viewModel.exportDiscoveredNodes()

    let file = try #require(viewModel.exportedFile)
    #expect(viewModel.isSharingExport)
    #expect(viewModel.errorMessage == nil)
    #expect(file.recordCount == 2)
    #expect(file.filename.hasPrefix("Cairn-discovered-nodes-"))
    #expect(file.filename.hasSuffix(".json"))

    let url = try #require(file.url)
    let contents = try DiscoveredNodesFile.parse(DiscoveredNodesFile.read(contentsOf: url))
    #expect(contents.nodes.map(\.name) == ["Hilltop", "Valley"])

    viewModel.discardExport()
    #expect(viewModel.exportedFile == nil)
    #expect(!viewModel.isSharingExport)
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }

  @Test
  func `export of an empty list reports that there is nothing to export`() async throws {
    let viewModel = try makeViewModel(store: makeStore(), radio: CurrentRadio())

    await viewModel.exportDiscoveredNodes()

    #expect(viewModel.exportedFile == nil)
    #expect(!viewModel.isSharingExport)
    #expect(viewModel.errorMessage == L10n.Settings.Settings.DataExport.empty)
  }

  @Test
  func `export without a radio does nothing`() async throws {
    let radio = CurrentRadio()
    radio.id = nil
    let viewModel = try makeViewModel(store: makeStore(), radio: radio)

    await viewModel.exportDiscoveredNodes()

    #expect(viewModel.exportedFile == nil)
    #expect(viewModel.errorMessage == nil)
  }

  // MARK: - Import

  @Test
  func `a valid file is previewed and imported after confirmation`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let radioID = try #require(radio.id)
    try await store.importDiscoveredNodes([Self.node(0xA1, name: "Old", advert: 100)], radioID: radioID, selfPublicKey: nil)
    try await store.saveContact(ContactDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: Self.key(0xD4),
      name: "Friend",
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0xFF,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    ))
    let viewModel = makeViewModel(store: store, radio: radio)
    let url = try writeFile(nodes: [
      Self.node(0xA1, name: "New", advert: 200),
      Self.node(0xB2, name: "Valley"),
      Self.node(0xD4, name: "Friend")
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel)

    let preview = try #require(viewModel.importPreview)
    #expect(viewModel.errorMessage == nil)
    #expect(preview.summary.fileNodeCount == 3)
    #expect(preview.summary.newCount == 1)
    #expect(preview.summary.updatedCount == 1)
    #expect(preview.summary.alreadyKnownCount == 1)
    let untouched = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(untouched.map(\.name) == ["Old"])

    let changed = await viewModel.confirmImport(preview)

    #expect(changed)
    #expect(viewModel.importPreview == nil)
    #expect(viewModel.importResult == DiscoveryViewModel.resultMessage(for: preview.summary))
    #expect(Set(viewModel.discoveredNodes.map(\.name)) == ["New", "Valley"])
    #expect(!viewModel.isTransferringFile)
  }

  @Test
  func `the import goes on after the alert has cleared the preview`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let viewModel = makeViewModel(store: store, radio: radio)
    let url = try writeFile(nodes: [Self.node(0xA1), Self.node(0xB2)])
    defer { try? FileManager.default.removeItem(at: url) }
    await stageImport(of: url, in: viewModel)
    let preview = try #require(viewModel.importPreview)

    viewModel.cancelImport()
    let changed = await viewModel.confirmImport(preview)

    #expect(changed)
    #expect(viewModel.discoveredNodes.count == 2)
  }

  @Test
  func `nodes are imported into the radio that is current at confirmation`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let firstRadioID = try #require(radio.id)
    let viewModel = makeViewModel(store: store, radio: radio)
    let url = try writeFile(nodes: [Self.node(0xA1)])
    defer { try? FileManager.default.removeItem(at: url) }
    await stageImport(of: url, in: viewModel)
    let preview = try #require(viewModel.importPreview)

    let secondRadioID = UUID()
    radio.id = secondRadioID
    _ = await viewModel.confirmImport(preview)

    let first = try await store.fetchDiscoveredNodes(radioID: firstRadioID)
    let second = try await store.fetchDiscoveredNodes(radioID: secondRadioID)
    #expect(first.isEmpty)
    #expect(second.map(\.publicKey) == [Self.key(0xA1)])
  }

  @Test
  func `a file that changes nothing is previewed as such`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let radioID = try #require(radio.id)
    try await store.importDiscoveredNodes([Self.node(0xA1)], radioID: radioID, selfPublicKey: nil)
    let viewModel = makeViewModel(store: store, radio: radio)
    let url = try writeFile(nodes: [Self.node(0xA1)])
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel)

    let preview = try #require(viewModel.importPreview)
    #expect(!preview.summary.changesAnything)
    #expect(DiscoveryViewModel.previewMessage(for: preview).hasPrefix(L10n.Contacts.Contacts.Discovery.Import.nothingNew))
  }

  @Test
  func `invalid entries are counted in the preview and left out of the import`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let viewModel = makeViewModel(store: store, radio: radio)
    let valid = try #require(
      JSONSerialization.jsonObject(with: DiscoveredNodesFile.encode([Self.node(0xA1)])) as? [String: Any]
    )
    var entries = try #require(valid["nodes"] as? [[String: Any]])
    var invalid = entries[0]
    invalid["publicKey"] = "abc"
    entries.append(invalid)
    var root = valid
    root["nodes"] = entries
    let url = try writeFile(JSONSerialization.data(withJSONObject: root))
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel)

    let preview = try #require(viewModel.importPreview)
    #expect(preview.nodes.map(\.publicKey) == [Self.key(0xA1)])
    #expect(preview.invalidCount == 1)
    #expect(preview.summary.fileNodeCount == 1)
  }

  @Test
  func `import without a radio reports it and reads nothing`() async throws {
    let radio = CurrentRadio()
    radio.id = nil
    let viewModel = try makeViewModel(store: makeStore(), radio: radio)
    let url = try writeFile(nodes: [Self.node(0xA1)])
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel)

    #expect(viewModel.importPreview == nil)
    #expect(viewModel.errorMessage == L10n.Contacts.Contacts.Discovery.Import.Error.noRadio)
  }

  @Test
  func `a confirmation after the radio is gone reports it`() async throws {
    let store = try makeStore()
    let radio = CurrentRadio()
    let viewModel = makeViewModel(store: store, radio: radio)
    let url = try writeFile(nodes: [Self.node(0xA1)])
    defer { try? FileManager.default.removeItem(at: url) }
    await stageImport(of: url, in: viewModel)
    let preview = try #require(viewModel.importPreview)

    radio.id = nil
    let changed = await viewModel.confirmImport(preview)

    #expect(!changed)
    #expect(viewModel.errorMessage == L10n.Contacts.Contacts.Discovery.Import.Error.noRadio)
    #expect(viewModel.importResult == nil)
  }

  // MARK: - Refused Files

  private func importError(for data: Data) async throws -> String? {
    let viewModel = try makeViewModel(store: makeStore(), radio: CurrentRadio())
    let url = try writeFile(data)
    defer { try? FileManager.default.removeItem(at: url) }

    await stageImport(of: url, in: viewModel)

    #expect(viewModel.importPreview == nil)
    return viewModel.errorMessage
  }

  @Test
  func `a file over the size limit is refused`() async throws {
    let data = Data(repeating: UInt8(ascii: " "), count: DiscoveredNodesFile.maxFileBytes + 1)

    let message = try await importError(for: data)

    #expect(message == L10n.Contacts.Contacts.Discovery.Import.Error.tooLarge(5))
  }

  @Test
  func `a file that is not JSON is refused`() async throws {
    let message = try await importError(for: Data("name,key\nHilltop,a1\n".utf8))

    #expect(message == L10n.Contacts.Contacts.Discovery.Import.Error.unreadable)
  }

  @Test
  func `a file of another format is refused`() async throws {
    let message = try await importError(for: Data("{\"format\":\"cairn.backup\",\"version\":1,\"nodes\":[]}".utf8))

    #expect(message == L10n.Contacts.Contacts.Discovery.Import.Error.wrongFormat)
  }

  @Test
  func `a file of an unknown version is refused`() async throws {
    let message = try await importError(
      for: Data("{\"format\":\"cairn.discovered-nodes\",\"version\":2,\"nodes\":[]}".utf8)
    )

    #expect(message == L10n.Contacts.Contacts.Discovery.Import.Error.unsupportedVersion)
  }

  @Test
  func `a file without a valid node is refused`() async throws {
    let empty = try await importError(for: DiscoveredNodesFile.encode([]))
    let allInvalid = try await importError(
      for: Data("{\"format\":\"cairn.discovered-nodes\",\"version\":1,\"nodes\":[{\"name\":\"x\"}]}".utf8)
    )

    #expect(empty == L10n.Contacts.Contacts.Discovery.Import.Error.noValidNodes)
    #expect(allInvalid == L10n.Contacts.Contacts.Discovery.Import.Error.noValidNodes)
  }

  @Test
  func `a file that is not there is reported`() async throws {
    let viewModel = try makeViewModel(store: makeStore(), radio: CurrentRadio())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")

    await stageImport(of: url, in: viewModel)

    #expect(viewModel.importPreview == nil)
    #expect(viewModel.errorMessage != nil)
    #expect(!viewModel.isTransferringFile)
  }

  // MARK: - Messages

  @Test
  func `the preview lists every count that applies, one per line`() {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    var summary = DiscoveredNodesImportPlan.Summary()
    summary.fileNodeCount = 250
    summary.newCount = 120
    summary.updatedCount = 30
    summary.alreadyKnownCount = 40
    summary.unchangedCount = 53
    summary.overCapacityCount = 7
    let preview = DiscoveredNodesImportPreview(nodes: [], invalidCount: 3, summary: summary)

    let lines = DiscoveryViewModel.previewMessage(for: preview).components(separatedBy: "\n")

    #expect(lines == [
      Line.inFile(250),
      Line.new(120),
      Line.updated(30),
      Line.alreadyKnown(40),
      Line.unchanged(53),
      Line.overLimit(7),
      Line.invalid(3)
    ])
  }

  @Test
  func `the preview leaves out counts that are zero`() {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    var summary = DiscoveredNodesImportPlan.Summary()
    summary.fileNodeCount = 2
    summary.newCount = 2
    let preview = DiscoveredNodesImportPreview(nodes: [], invalidCount: 0, summary: summary)

    let lines = DiscoveryViewModel.previewMessage(for: preview).components(separatedBy: "\n")

    #expect(lines == [Line.inFile(2), Line.new(2), Line.updated(0)])
  }

  @Test
  func `the result names what was added, updated, and left out`() {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    var summary = DiscoveredNodesImportPlan.Summary()
    summary.newCount = 3
    summary.updatedCount = 1
    #expect(DiscoveryViewModel.resultMessage(for: summary) == [Line.new(3), Line.updated(1)].joined(separator: "\n"))

    summary.overCapacityCount = 7
    #expect(
      DiscoveryViewModel.resultMessage(for: summary)
        == [Line.new(3), Line.updated(1), Line.overLimit(7)].joined(separator: "\n")
    )
  }
}
