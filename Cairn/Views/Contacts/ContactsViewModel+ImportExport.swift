import CairnServices
import Foundation
import MeshCore
import UniformTypeIdentifiers

/// A validated nodes file and what importing it into the Saved list would do, held until the
/// user confirms. The file is the same exchange format the Heard list writes
/// (`DiscoveredNodesFile`), so a list can move between the two and between devices.
struct SavedNodesImportPreview: Equatable {
  /// The nodes to add: those in the file that aren't saved on the radio yet, within its limit.
  let nodes: [DiscoveredNodesFile.Node]
  /// Every valid node the file listed.
  let fileNodeCount: Int
  /// Already on the radio, so left as they are.
  let alreadySavedCount: Int
  /// Left out because the radio's node list has no room for them.
  let overCapacityCount: Int
  /// Entries in the file that failed validation and are left out.
  let invalidCount: Int

  var newCount: Int { nodes.count }

  var changesAnything: Bool { !nodes.isEmpty }
}

extension ContactsViewModel {
  // MARK: - Export

  /// Writes the saved nodes to a file (the discovered-nodes exchange format) and stages it for
  /// the share sheet.
  func exportContacts() {
    guard !isTransferringFile else { return }
    let nodes = Self.exportNodes(from: contacts)
    guard !nodes.isEmpty else {
      errorMessage = L10n.Settings.Settings.DataExport.empty
      return
    }
    isTransferringFile = true
    defer { isTransferringFile = false }
    do {
      let data = try DiscoveredNodesFile.encode(nodes)
      let file = ExportedFile(
        data: data,
        filename: "Cairn-saved-nodes-\(ExportFormat.filenameStamp()).\(DiscoveredNodesFile.filenameExtension)",
        contentType: .json,
        recordCount: nodes.count
      )
      guard file.url != nil else {
        throw CocoaError(.fileWriteUnknown)
      }
      exportedFile = file
      isSharingExport = true
    } catch {
      errorMessage = L10n.Settings.Settings.DataExport.error(error.localizedDescription)
    }
  }

  /// The saved nodes as the file carries them: the radio's name for each (not the nickname,
  /// which is this phone's), its type, position and last advert.
  static func exportNodes(from contacts: [ContactDTO]) -> [DiscoveredNodesFile.Node] {
    contacts.compactMap { contact in
      guard contact.publicKey.count == ProtocolLimits.publicKeySize else { return nil }
      return DiscoveredNodesFile.Node(
        publicKey: contact.publicKey,
        name: contact.name,
        type: contact.type,
        latitude: contact.hasLocation ? contact.latitude : nil,
        longitude: contact.hasLocation ? contact.longitude : nil,
        lastAdvertTimestamp: contact.lastAdvertTimestamp,
        lastHeard: contact.recencyDate
      )
    }
  }

  /// Drops the staged export and its temporary file, once the screen that offered it is gone.
  func discardExport() {
    isSharingExport = false
    exportedFile = nil
  }

  // MARK: - Import

  /// Reads and validates a file, then stages what importing it would do. The read runs detached
  /// because the URL can point at an undownloaded iCloud Drive file, where a synchronous read on
  /// the main actor blocks the UI for the whole download.
  /// - Parameters:
  ///   - maxContacts: The radio's node limit, so the preview can say what won't fit; nil when
  ///     unknown, which imports everything new.
  ///   - selfPublicKey: The radio's own key, which is never a node to save.
  func importFile(at url: URL, maxContacts: Int?, selfPublicKey: Data?) {
    guard !isTransferringFile else { return }
    isTransferringFile = true
    let didAccessSecurityScope = url.startAccessingSecurityScopedResource()

    importTask = Task {
      defer { isTransferringFile = false }
      do {
        let contents = try await Task.detached(priority: .userInitiated) {
          defer {
            if didAccessSecurityScope {
              url.stopAccessingSecurityScopedResource()
            }
          }
          return try DiscoveredNodesFile.parse(DiscoveredNodesFile.read(contentsOf: url))
        }.value
        guard !contents.nodes.isEmpty else {
          errorMessage = L10n.Contacts.Contacts.Discovery.Import.Error.noValidNodes
          return
        }
        importPreview = Self.plan(
          contents.nodes,
          invalidCount: contents.rejected.count,
          savedKeys: Set(contacts.map(\.publicKey)),
          selfPublicKey: selfPublicKey,
          capacityRemaining: maxContacts.map { max(0, $0 - contacts.count) }
        )
      } catch {
        errorMessage = DiscoveryViewModel.importErrorMessage(for: error)
      }
    }
  }

  /// What importing `nodes` would do against the nodes saved now: the new ones in file order
  /// up to `capacityRemaining`, the rest counted. Pure, so a test can check it without a file.
  static func plan(
    _ nodes: [DiscoveredNodesFile.Node],
    invalidCount: Int,
    savedKeys: Set<Data>,
    selfPublicKey: Data?,
    capacityRemaining: Int?
  ) -> SavedNodesImportPreview {
    var fresh: [DiscoveredNodesFile.Node] = []
    var alreadySaved = 0
    var fileCount = 0
    for node in nodes {
      if node.publicKey == selfPublicKey { continue }
      fileCount += 1
      if savedKeys.contains(node.publicKey) {
        alreadySaved += 1
      } else {
        fresh.append(node)
      }
    }
    let room = capacityRemaining ?? fresh.count
    let fitting = Array(fresh.prefix(max(0, room)))
    return SavedNodesImportPreview(
      nodes: fitting,
      fileNodeCount: fileCount,
      alreadySavedCount: alreadySaved,
      overCapacityCount: fresh.count - fitting.count,
      invalidCount: invalidCount
    )
  }

  /// Saves the previewed nodes to the radio, one write at a time, then reloads. Returns true
  /// when at least one node was added. Stops at the first failure: a full node list fails every
  /// later add the same way.
  ///
  /// Takes the preview instead of reading `importPreview`: the alert clears that as it closes,
  /// before the task started by its button gets to run.
  func confirmImport(_ preview: SavedNodesImportPreview, radioID: UUID?) async -> Bool {
    guard !isTransferringFile else { return false }
    importPreview = nil
    guard let contactService, let radioID else {
      errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return false
    }
    isTransferringFile = true
    defer { isTransferringFile = false }

    var added = 0
    let now = UInt32(Date.now.timeIntervalSince1970)
    do {
      for node in preview.nodes {
        try await contactService.addOrUpdateContact(radioID: radioID, contact: Self.contactFrame(for: node, now: now))
        added += 1
      }
    } catch ContactServiceError.contactTableFull {
      errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
    } catch {
      errorMessage = error.userFacingMessage
    }
    await loadContacts(radioID: radioID)
    importResult = Self.resultMessage(added: added, leftOut: preview.overCapacityCount + (preview.nodes.count - added))
    return added > 0
  }

  func cancelImport() {
    importPreview = nil
  }

  /// A file's node as the radio stores it: flood-routed until a path is learned, as a node
  /// added by hand is.
  static func contactFrame(for node: DiscoveredNodesFile.Node, now: UInt32) -> ContactFrame {
    ContactFrame(
      publicKey: node.publicKey,
      type: node.type,
      flags: 0,
      outPathLength: PacketBuilder.floodPathSentinel,
      outPath: Data(),
      name: node.name,
      lastAdvertTimestamp: node.lastAdvertTimestamp,
      latitude: node.latitude ?? 0,
      longitude: node.longitude ?? 0,
      lastModified: now
    )
  }

  /// One count per line, so no language has to fit a number into a sentence.
  static func previewMessage(for preview: SavedNodesImportPreview) -> String {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    var lines: [String] = []
    if !preview.changesAnything {
      lines.append(L10n.Contacts.Contacts.Discovery.Import.nothingNew)
    }
    lines.append(Line.inFile(preview.fileNodeCount))
    lines.append(Line.new(preview.newCount))
    if preview.alreadySavedCount > 0 {
      lines.append(Line.alreadyKnown(preview.alreadySavedCount))
    }
    if preview.overCapacityCount > 0 {
      lines.append(Line.overLimit(preview.overCapacityCount))
    }
    if preview.invalidCount > 0 {
      lines.append(Line.invalid(preview.invalidCount))
    }
    return lines.joined(separator: "\n")
  }

  static func resultMessage(added: Int, leftOut: Int) -> String {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    var lines = [Line.new(added)]
    if leftOut > 0 {
      lines.append(Line.overLimit(leftOut))
    }
    return lines.joined(separator: "\n")
  }
}
