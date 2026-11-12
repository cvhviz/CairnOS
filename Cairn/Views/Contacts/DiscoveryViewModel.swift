import CoreLocation
import CairnServices
import SwiftUI
import UniformTypeIdentifiers

/// Segment for the discovery picker
enum DiscoverSegment: String, CaseIterable {
  case all
  case contacts
  case repeaters
  case rooms

  var localizedTitle: String {
    switch self {
    case .all: L10n.Contacts.Contacts.Discovery.Segment.all
    case .contacts: L10n.Contacts.Contacts.Discovery.Segment.contacts
    case .repeaters: L10n.Contacts.Contacts.Discovery.Segment.repeaters
    case .rooms: L10n.Contacts.Contacts.Discovery.Segment.rooms
    }
  }
}

/// A validated discovered-nodes file and what importing it would do, held until the user confirms.
struct DiscoveredNodesImportPreview: Equatable {
  let nodes: [DiscoveredNodesFile.Node]
  /// Entries in the file that failed validation and are left out.
  let invalidCount: Int
  let summary: DiscoveredNodesImportPlan.Summary
}

/// ViewModel for discovery view
@Observable
@MainActor
final class DiscoveryViewModel {
  // MARK: - Properties

  /// Discovered nodes from the mesh network
  var discoveredNodes: [DiscoveredNodeDTO] = []

  /// Public keys of contacts that have been added
  var addedPublicKeys: Set<Data> = []

  /// Nodes matching the current search/segment/sort, recomputed once per input or data change.
  private(set) var visibleNodes: [DiscoveredNodeDTO] = []

  /// Loading state
  var isLoading = false

  /// Whether data has been loaded at least once (prevents empty state flash)
  var hasLoadedOnce = false

  /// Error message to display
  var errorMessage: String?

  /// The staged export. It outlives the share sheet, which can hand the file to an app that
  /// reads it after the sheet has closed, and goes when the screen does.
  private(set) var exportedFile: ExportedFile? {
    didSet {
      if let oldValue, oldValue.id != exportedFile?.id {
        oldValue.removeTemporaryFile()
      }
    }
  }

  var isSharingExport = false

  /// True while a file is being written, read, or imported.
  private(set) var isTransferringFile = false

  var importPreview: DiscoveredNodesImportPreview?

  /// Summary of the last import, shown once it is done.
  var importResult: String?

  // MARK: - Selection State

  /// True while the page is picking nodes for a bulk action rather than acting on one.
  private(set) var isSelecting = false

  /// Picked nodes. Kept to the visible list, so a bulk action never reaches a node the search
  /// or segment has hidden.
  private(set) var selectedNodeIDs: Set<UUID> = []

  // MARK: - Last Filter Inputs

  /// Last filter inputs, re-applied whenever the underlying data changes.
  private var lastSearchText: String = ""
  private var lastSegment: DiscoverSegment = .all
  private var lastSortOrder: NodeSortOrder = .lastHeard
  private var lastUserLocation: CLLocation?

  // MARK: - Dependencies

  private var dataStoreProvider: @MainActor () -> PersistenceStore? = { nil }
  private var dataStore: PersistenceStore? {
    dataStoreProvider()
  }

  private var radioIDProvider: @MainActor () -> UUID? = { nil }
  private var radioID: UUID? {
    radioIDProvider()
  }

  private var selfPublicKeyProvider: @MainActor () -> Data? = { nil }
  private var selfPublicKey: Data? {
    selfPublicKeyProvider()
  }

  /// Told after nodes are removed from the store, so other screens showing discovered nodes
  /// (Home, CarPlay, a second window) reload too.
  private var nodesChangedHandler: @MainActor () -> Void = {}

  /// Discover reload trace (Logger category `discover-trace`).
  private let discoverTrace = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "discover-trace")

  private static let reloadDebounce: Duration = .milliseconds(50)
  private var reloadTask: Task<Void, Never>?
  private var importTask: Task<Void, Never>?

  // MARK: - Initialization

  init() {}

  /// Configure with the data store and connected radio this view model uses;
  /// providers returning nil mirror a disconnected state.
  func configure(
    dataStore: @escaping @MainActor () -> PersistenceStore?,
    radioID: @escaping @MainActor () -> UUID?,
    selfPublicKey: @escaping @MainActor () -> Data? = { nil },
    onNodesChanged: @escaping @MainActor () -> Void = {}
  ) {
    dataStoreProvider = dataStore
    radioIDProvider = radioID
    selfPublicKeyProvider = selfPublicKey
    nodesChangedHandler = onNodesChanged
  }

  // MARK: - Load Nodes

  func loadDiscoveredNodes() async {
    guard let dataStore, let radioID else {
      // No paired radio yet: the empty list, not a spinner that never ends.
      discoveredNodes = []
      addedPublicKeys = []
      hasLoadedOnce = true
      isLoading = false
      applyFilter()
      return
    }

    isLoading = true
    errorMessage = nil

    do {
      let nodes = try await dataStore.fetchDiscoveredNodes(radioID: radioID)

      // One batch query for all contact public keys (not one round-trip per node).
      let addedKeys = try await dataStore.fetchContactPublicKeys(radioID: radioID)

      discoveredNodes = nodes
      addedPublicKeys = addedKeys
      discoverTrace.debug("B4 view reload loaded=\(nodes.count) addedKeys=\(addedKeys.count) radio=\(radioID)")
    } catch {
      errorMessage = error.userFacingMessage
      discoverTrace.error("B4 view reload FAILED radio=\(radioID): \(error.localizedDescription)")
    }

    hasLoadedOnce = true
    isLoading = false
    applyFilter()
  }

  /// Schedules a debounced reload so bursts of contactsVersion bumps trigger
  /// one load instead of one per event. No-ops if a reload is already pending.
  func scheduleCoalescedReload() {
    guard reloadTask == nil else { return }
    reloadTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.reloadDebounce)
      guard let self else { return }
      reloadTask = nil
      await loadDiscoveredNodes()
    }
  }

  // MARK: - Added State

  /// Check if a node has already been added as a contact
  func isAdded(_ node: DiscoveredNodeDTO) -> Bool {
    addedPublicKeys.contains(node.publicKey)
  }

  /// How many heard nodes aren't saved yet: the Heard list's size before search and filters,
  /// for the count in its search field.
  var heardCount: Int {
    discoveredNodes.reduce(0) { isAdded($1) ? $0 : $0 + 1 }
  }

  /// The Heard list's search placeholder, with the count once there is something to count.
  var searchPrompt: String {
    let count = heardCount
    return count > 0
      ? L10n.Contacts.Contacts.Discovery.searchPromptWithCount(count)
      : L10n.Contacts.Contacts.Discovery.searchPrompt
  }

  // MARK: - Delete

  func deleteDiscoveredNode(_ node: DiscoveredNodeDTO) async {
    guard let dataStore else { return }

    discoveredNodes.removeAll { $0.id == node.id }
    applyFilter()

    do {
      try await dataStore.deleteDiscoveredNode(id: node.id)
      nodesChangedHandler()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Removes several nodes at once. The list drops them up front, like the single delete; a
  /// failed write reports its error and leaves the rest to the next reload.
  func deleteDiscoveredNodes(_ nodes: [DiscoveredNodeDTO]) async {
    guard let dataStore, !nodes.isEmpty else { return }

    let ids = Set(nodes.map(\.id))
    discoveredNodes.removeAll { ids.contains($0.id) }
    applyFilter()
    // Told even when a write fails part way: the ones before it are gone
    defer { nodesChangedHandler() }

    for id in ids {
      do {
        try await dataStore.deleteDiscoveredNode(id: id)
      } catch {
        errorMessage = error.userFacingMessage
        return
      }
    }
  }

  func clearAllDiscoveredNodes() async {
    guard let dataStore, let radioID else { return }

    do {
      try await dataStore.clearDiscoveredNodes(radioID: radioID)
      discoveredNodes = []
      applyFilter()
      nodesChangedHandler()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  // MARK: - Selection

  /// The picked nodes, in list order.
  var selectedNodes: [DiscoveredNodeDTO] {
    visibleNodes.filter { selectedNodeIDs.contains($0.id) }
  }

  /// Whether every visible node is picked, which turns Select All into Deselect All.
  var isAllSelected: Bool {
    !visibleNodes.isEmpty && selectedNodeIDs.count == visibleNodes.count
  }

  func isSelected(_ node: DiscoveredNodeDTO) -> Bool {
    selectedNodeIDs.contains(node.id)
  }

  func beginSelecting() {
    selectedNodeIDs = []
    isSelecting = true
  }

  func endSelecting() {
    isSelecting = false
    selectedNodeIDs = []
  }

  func toggleSelection(_ node: DiscoveredNodeDTO) {
    if selectedNodeIDs.contains(node.id) {
      selectedNodeIDs.remove(node.id)
    } else {
      selectedNodeIDs.insert(node.id)
    }
  }

  func toggleSelectAll() {
    selectedNodeIDs = isAllSelected ? [] : Set(visibleNodes.map(\.id))
  }

  // MARK: - Export

  /// Writes this radio's discovered nodes to a file and stages it for the share sheet.
  func exportDiscoveredNodes() async {
    guard !isTransferringFile, let dataStore, let radioID else { return }
    isTransferringFile = true
    defer { isTransferringFile = false }

    do {
      let export = try await DataExportService(store: dataStore).discoveredNodesJSON(radioID: radioID)
      guard export.count > 0 else {
        errorMessage = L10n.Settings.Settings.DataExport.empty
        return
      }
      let file = ExportedFile(
        data: export.data,
        filename: "Cairn-discovered-nodes-\(ExportFormat.filenameStamp()).\(DiscoveredNodesFile.filenameExtension)",
        contentType: .json,
        recordCount: export.count
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

  /// Drops the staged export and its temporary file, once the screen that offered it is gone.
  func discardExport() {
    isSharingExport = false
    exportedFile = nil
  }

  // MARK: - Import

  /// Reads and validates a file, then stages what importing it would do. The read runs
  /// detached because the URL can point at an undownloaded iCloud Drive file, where a
  /// synchronous read on the main actor blocks the UI for the whole download.
  func importFile(at url: URL) {
    guard !isTransferringFile else { return }
    guard let dataStore, let radioID else {
      errorMessage = L10n.Contacts.Contacts.Discovery.Import.Error.noRadio
      return
    }
    isTransferringFile = true
    let selfPublicKey = selfPublicKey
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
        let summary = try await dataStore.planDiscoveredNodesImport(
          contents.nodes,
          radioID: radioID,
          selfPublicKey: selfPublicKey
        )
        importPreview = DiscoveredNodesImportPreview(
          nodes: contents.nodes,
          invalidCount: contents.rejected.count,
          summary: summary
        )
      } catch {
        errorMessage = Self.importErrorMessage(for: error)
      }
    }
  }

  /// Imports a previewed file into the radio that is current now, whatever radio the file
  /// came from. Returns true when the list changed.
  ///
  /// Takes the preview instead of reading `importPreview`: the alert clears that as it
  /// closes, before the task started by its button gets to run.
  func confirmImport(_ preview: DiscoveredNodesImportPreview) async -> Bool {
    guard !isTransferringFile else { return false }
    importPreview = nil
    guard let dataStore, let radioID else {
      errorMessage = L10n.Contacts.Contacts.Discovery.Import.Error.noRadio
      return false
    }
    isTransferringFile = true
    defer { isTransferringFile = false }

    do {
      let summary = try await dataStore.importDiscoveredNodes(
        preview.nodes,
        radioID: radioID,
        selfPublicKey: selfPublicKey
      )
      await loadDiscoveredNodes()
      importResult = Self.resultMessage(for: summary)
      return summary.changesAnything
    } catch {
      errorMessage = error.userFacingMessage
      return false
    }
  }

  func cancelImport() {
    importPreview = nil
  }

  /// One count per line, so no language has to fit a number into a sentence.
  static func previewMessage(for preview: DiscoveredNodesImportPreview) -> String {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    let summary = preview.summary
    var lines: [String] = []
    if !summary.changesAnything {
      lines.append(L10n.Contacts.Contacts.Discovery.Import.nothingNew)
    }
    lines.append(Line.inFile(summary.fileNodeCount))
    lines.append(Line.new(summary.newCount))
    lines.append(Line.updated(summary.updatedCount))
    if summary.alreadyKnownCount > 0 {
      lines.append(Line.alreadyKnown(summary.alreadyKnownCount))
    }
    if summary.unchangedCount > 0 {
      lines.append(Line.unchanged(summary.unchangedCount))
    }
    if summary.overCapacityCount > 0 {
      lines.append(Line.overLimit(summary.overCapacityCount))
    }
    if preview.invalidCount > 0 {
      lines.append(Line.invalid(preview.invalidCount))
    }
    return lines.joined(separator: "\n")
  }

  static func resultMessage(for summary: DiscoveredNodesImportPlan.Summary) -> String {
    typealias Line = L10n.Contacts.Contacts.Discovery.Import.Line
    var lines = [Line.new(summary.newCount), Line.updated(summary.updatedCount)]
    if summary.overCapacityCount > 0 {
      lines.append(Line.overLimit(summary.overCapacityCount))
    }
    return lines.joined(separator: "\n")
  }

  static func importErrorMessage(for error: Error) -> String {
    typealias Message = L10n.Contacts.Contacts.Discovery.Import.Error
    guard let fileError = error as? DiscoveredNodesFile.FileError else {
      return error.userFacingMessage
    }
    switch fileError {
    case .tooLarge:
      return Message.tooLarge(DiscoveredNodesFile.maxFileBytes / Self.bytesPerMegabyte)
    case .unreadable:
      return Message.unreadable
    case .wrongFormat:
      return Message.wrongFormat
    case .unsupportedVersion:
      return Message.unsupportedVersion
    }
  }

  private static let bytesPerMegabyte = 1024 * 1024

  // MARK: - Filtering

  /// Recomputes `visibleNodes` from the given filter inputs. Called by the view on input changes only.
  func updateVisibleNodes(
    searchText: String,
    segment: DiscoverSegment,
    sortOrder: NodeSortOrder,
    userLocation: CLLocation?
  ) {
    lastSearchText = searchText
    lastSegment = segment
    lastSortOrder = sortOrder
    lastUserLocation = userLocation
    applyFilter()
  }

  private func applyFilter() {
    visibleNodes = filteredNodes(
      searchText: lastSearchText,
      segment: lastSegment,
      sortOrder: lastSortOrder,
      userLocation: lastUserLocation
    )
    if !selectedNodeIDs.isEmpty {
      selectedNodeIDs.formIntersection(visibleNodes.map(\.id))
    }
  }

  func filteredNodes(
    searchText: String,
    segment: DiscoverSegment,
    sortOrder: NodeSortOrder,
    userLocation: CLLocation?
  ) -> [DiscoveredNodeDTO] {
    // Heard lists only what isn't saved yet: a saved node belongs to the Saved list, and adding
    // one from here moves it there.
    var result = discoveredNodes.filter { !isAdded($0) }

    if searchText.isEmpty {
      switch segment {
      case .all:
        break
      case .contacts:
        result = result.filter { $0.nodeType == .chat }
      case .repeaters:
        result = result.filter { $0.nodeType == .repeater }
      case .rooms:
        result = result.filter { $0.nodeType == .room }
      }
    } else {
      let query = searchText.lowercased()
      result = result.filter { node in
        node.name.localizedStandardContains(searchText)
          || node.publicKey.hexString.hasPrefix(query)
      }
    }

    return sorted(result, by: sortOrder, userLocation: userLocation)
  }

  // MARK: - Sorting

  private func sorted(
    _ nodes: [DiscoveredNodeDTO],
    by order: NodeSortOrder,
    userLocation: CLLocation?
  ) -> [DiscoveredNodeDTO] {
    switch order {
    // Manual places saved nodes only; heard nodes keep their recency order under it.
    case .lastHeard, .manual:
      nodes.sorted { $0.lastHeard > $1.lastHeard }
    case .name:
      nodes.sorted {
        $0.name.localizedCompare($1.name) == .orderedAscending
      }
    case .distance:
      sortedByDistanceThenName(nodes, from: userLocation)
    case .hops:
      sortedByHopsThenDistance(nodes, from: userLocation)
    }
  }

  /// Precomputes distances once (decorate-sort-undecorate) so the comparator does not
  /// allocate two `CLLocation`s per comparison.
  private func sortedByDistanceThenName(
    _ nodes: [DiscoveredNodeDTO],
    from userLocation: CLLocation?
  ) -> [DiscoveredNodeDTO] {
    guard let userLocation else {
      return nodes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // Located nodes first (distance finite), unlocated last (distance infinite).
    let decorated: [(node: DiscoveredNodeDTO, distance: Double)] = nodes.map { node in
      if node.hasLocation {
        let distance = CLLocation(latitude: node.latitude, longitude: node.longitude)
          .distance(from: userLocation)
        return (node, distance)
      }
      return (node, .infinity)
    }

    return decorated
      .sorted { lhs, rhs in
        if lhs.distance != rhs.distance {
          return lhs.distance < rhs.distance
        }
        return lhs.node.name.localizedCompare(rhs.node.name) == .orderedAscending
      }
      .map(\.node)
  }

  private func sortedByHopsThenDistance(
    _ nodes: [DiscoveredNodeDTO],
    from userLocation: CLLocation?
  ) -> [DiscoveredNodeDTO] {
    guard let userLocation else {
      return nodes.sorted { lhs, rhs in
        let lhsHops = lhs.displayedHopCount
        let rhsHops = rhs.displayedHopCount
        if (lhsHops == nil) != (rhsHops == nil) {
          return lhsHops != nil
        }
        if let lhsHops, let rhsHops, lhsHops != rhsHops {
          return lhsHops < rhsHops
        }
        return lhs.name.localizedCompare(rhs.name) == .orderedAscending
      }
    }

    let decorated: [(node: DiscoveredNodeDTO, hops: Int?, distance: Double)] = nodes.map { node in
      let distance: Double = if node.hasLocation {
        CLLocation(latitude: node.latitude, longitude: node.longitude)
          .distance(from: userLocation)
      } else {
        .infinity
      }
      return (node, node.displayedHopCount, distance)
    }

    return decorated
      .sorted { lhs, rhs in
        // A nil hop count (flood-routed and never heard via advert) sorts to the bottom.
        if (lhs.hops == nil) != (rhs.hops == nil) {
          return lhs.hops != nil
        }
        if let lhsHops = lhs.hops, let rhsHops = rhs.hops, lhsHops != rhsHops {
          return lhsHops < rhsHops
        }
        if lhs.distance != rhs.distance {
          return lhs.distance < rhs.distance
        }
        return lhs.node.name.localizedCompare(rhs.node.name) == .orderedAscending
      }
      .map(\.node)
  }
}
