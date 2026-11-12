import CoreLocation
import CairnServices
import SwiftUI

/// Segment for the nodes picker
enum NodeSegment: String, CaseIterable {
  case all
  case contacts
  case repeaters
  case rooms

  var localizedTitle: String {
    switch self {
    case .all: L10n.Contacts.Contacts.Discovery.Segment.all
    case .contacts: L10n.Contacts.Contacts.Segment.contacts
    case .repeaters: L10n.Contacts.Contacts.Segment.repeaters
    case .rooms: L10n.Contacts.Contacts.Segment.rooms
    }
  }
}

/// Sort order for nodes list
enum NodeSortOrder: String, CaseIterable {
  case lastHeard
  case name
  case distance
  case hops
  /// The order the user put the nodes in by dragging them (`ContactsViewModel.manualOrder`).
  case manual

  /// The orders the Heard list offers: every one but Manual, which places saved nodes.
  static let heardOrders: [NodeSortOrder] = allCases.filter { $0 != .manual }

  var localizedTitle: String {
    switch self {
    case .lastHeard: L10n.Contacts.Contacts.Sort.lastHeard
    case .name: L10n.Contacts.Contacts.Sort.name
    case .distance: L10n.Contacts.Contacts.Sort.distance
    case .hops: L10n.Contacts.Contacts.Sort.hops
    case .manual: L10n.Contacts.Contacts.Sort.manual
    }
  }
}

extension NodeSortOrder {
  /// Orders nodes as the Nodes list does: most recent first, by name, or nearest first (fewest
  /// hops first for Hops), with an unknown distance or hop count last and the name breaking ties.
  /// Location-aware orders read each item's distance and hops once (decorate-sort-undecorate), so
  /// the comparator allocates nothing. Manual puts each node where the user dragged it
  /// (`manualRank`, lowest first); nodes never placed follow, most recent first.
  func sorted<Item>(
    _ items: [Item],
    recency: (Item) -> TimeInterval,
    name: (Item) -> String,
    distance: (Item) -> Double?,
    hops: (Item) -> Int?,
    manualRank: (Item) -> Int? = { _ in nil }
  ) -> [Item] {
    switch self {
    case .lastHeard:
      return items.sorted { recency($0) > recency($1) }
    case .manual:
      let decorated = items.map { (item: $0, rank: manualRank($0), recency: recency($0)) }
      return decorated.sorted { lhs, rhs in
        switch (lhs.rank, rhs.rank) {
        case let (left?, right?): left < right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.recency > rhs.recency
        }
      }
      .map(\.item)
    case .name:
      return items.sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
    case .distance, .hops:
      let byHops = self == .hops
      let decorated = items.map { item in
        (item: item, name: name(item), distance: distance(item), hops: byHops ? hops(item) : nil)
      }
      return decorated.sorted { lhs, rhs in
        if byHops {
          // A nil hop count (flood-routed and never heard via advert) sorts to the bottom.
          if (lhs.hops == nil) != (rhs.hops == nil) {
            return lhs.hops != nil
          }
          if let lhsHops = lhs.hops, let rhsHops = rhs.hops, lhsHops != rhsHops {
            return lhsHops < rhsHops
          }
        }
        if (lhs.distance == nil) != (rhs.distance == nil) {
          return lhs.distance != nil
        }
        if let lhsDistance = lhs.distance, let rhsDistance = rhs.distance, lhsDistance != rhsDistance {
          return lhsDistance < rhsDistance
        }
        return lhs.name.localizedCompare(rhs.name) == .orderedAscending
      }
      .map(\.item)
    }
  }
}

/// ViewModel for contact management
@Observable
@MainActor
final class ContactsViewModel {
  // MARK: - Properties

  /// All contacts
  var contacts: [ContactDTO] = [] {
    didSet {
      dataRevision &+= 1
      hexByKey = nil
    }
  }

  /// Inbound advert hop count per contact public key, sourced from the volatile discovered-node
  /// table and refreshed on each load. A contact's "Hops" falls back to this when it has no
  /// out-path; absence (evicted or never heard via advert) just leaves the fallback unavailable.
  var inboundHopByKey: [Data: Int] = [:] {
    didSet { dataRevision &+= 1 }
  }

  /// Loading state
  var isLoading = false

  /// Whether data has been loaded at least once (prevents empty state flash)
  var hasLoadedOnce = false

  /// Syncing state
  var isSyncing = false

  /// Sync progress (current, total)
  var syncProgress: (Int, Int)?

  /// Error message if any
  var errorMessage: String?

  /// User's current location for distance sorting (optional)
  var userLocation: CLLocation?

  /// Contact ID currently having its favorite status toggled (for loading UI)
  var togglingFavoriteID: UUID?

  /// Active group filter; when set, the list shows that group's members of every type
  /// instead of the selected segment.
  var selectedGroupID: UUID?

  /// Group editor requested from a row's context menu, presented by the list host.
  var groupEditorRequest: ContactGroupEditorItem?

  /// Presents the Manage Groups sheet.
  var showManageGroups = false

  /// Group whose broadcast sheet is presented.
  var broadcastGroup: ContactGroup?

  /// The active group filter, or nil when unset or the group was deleted.
  var selectedGroup: ContactGroup? {
    selectedGroupID.flatMap { ContactGroupStore.shared.group(id: $0) }
  }

  // MARK: - Row Confirmations and Presentations

  /// A row's Delete waits here for the same confirmation the node's page asks for.
  var deleteConfirmation: ContactDTO?

  /// A row's Block waits here for confirmation, as on the node's page; unblocking is immediate.
  var blockConfirmation: ContactDTO?

  /// The node whose delete timed out, so the alert can offer Retry.
  var deleteTimedOut: ContactDTO?

  /// Row context-menu pages the list host presents: the node on the map, its QR code, its name.
  var mapContact: ContactDTO?
  var shareContact: ContactDTO?
  var renameContact: ContactDTO?

  // MARK: - File Transfer State (see ContactsViewModel+ImportExport)

  /// The staged export. It outlives the share sheet, which can hand the file to an app that
  /// reads it after the sheet has closed, and goes when the screen does.
  var exportedFile: ExportedFile? {
    didSet {
      if let oldValue, oldValue.id != exportedFile?.id {
        oldValue.removeTemporaryFile()
      }
    }
  }

  var isSharingExport = false

  /// True while a file is being written, read, or imported.
  var isTransferringFile = false

  var importPreview: SavedNodesImportPreview?

  /// Summary of the last import, shown once it is done.
  var importResult: String?

  var importTask: Task<Void, Never>?

  // MARK: - Selection State

  /// True while the Saved list is picking nodes for a bulk action rather than acting on one.
  private(set) var isSelecting = false

  /// Picked nodes, by id. A bulk action takes `selectedContacts(in:)`, the picks among the nodes
  /// shown, so it never reaches a node the search or segment has hidden.
  private(set) var selectedContactIDs: Set<UUID> = []

  /// Mask of rows hidden after a confirmed delete, held until a reload sees the row gone so a
  /// racing reload can't resurrect it. Observed because `filteredContacts` reads it during body
  /// evaluation. Distinct from `deletingIDs`, the in-flight presentation set.
  var pendingRemovalIDs: Set<UUID> = [] {
    didSet { dataRevision &+= 1 }
  }

  /// Rows with a delete command in flight, surfaced as a spinner. Distinct from
  /// `pendingRemovalIDs`, the post-confirmation mask.
  var deletingIDs: Set<UUID> = []

  /// Nodes a Remove Nodes run is taking off the radio (`NodeRemovalModel.removingKeys`), by public
  /// key: left out from the moment it starts, rather than one at a time as the radio confirms
  /// each. Cleared when the run ends, so a node it failed to remove shows again.
  var bulkRemovalKeys: Set<Data> = [] {
    didSet { dataRevision &+= 1 }
  }

  /// Bumped whenever an input of `filteredContacts` other than its arguments changes, so the
  /// memoized result is reused across body passes that change nothing it depends on.
  @ObservationIgnored private var dataRevision = 0

  /// Last `filteredContacts` result and the inputs it was computed from.
  @ObservationIgnored private var filterCache: (key: FilterKey, result: [ContactDTO])?

  /// Uppercase hex of each contact's public key, built once per contacts change so search does
  /// not re-encode every key on each keystroke.
  @ObservationIgnored private var hexByKey: [Data: String]?

  /// Bumped at the start of each `loadContacts` so a slower fetch cannot overwrite a newer list.
  private var loadGeneration = 0
  /// The newest load generation whose fetch has been committed (see `loadContacts`).
  private var committedLoadGeneration = 0

  /// Upserted rows held until a fetch includes the same id or public key and radio.
  /// A slower load must not drop a just-added contact.
  private var pendingAdmissions: [UUID: ContactDTO] = [:]

  /// True while a delete for this row is either confirmed-but-unreloaded or in flight.
  func isDeletePending(_ id: UUID) -> Bool {
    pendingRemovalIDs.contains(id) || deletingIDs.contains(id)
  }

  // MARK: - Dependencies

  private var dataStoreProvider: @MainActor () -> PersistenceStore? = { nil }
  private var contactServiceProvider: @MainActor () -> ContactService? = { nil }
  private var advertisementServiceProvider: @MainActor () -> AdvertisementService? = { nil }

  private var dataStore: PersistenceStore? {
    dataStoreProvider()
  }

  /// Internal rather than private: the import extension (`ContactsViewModel+ImportExport`)
  /// writes nodes through it.
  var contactService: ContactService? {
    contactServiceProvider()
  }

  private var advertisementService: AdvertisementService? {
    advertisementServiceProvider()
  }

  // MARK: - Initialization

  init() {}

  /// Configure with the services this view model uses; a provider returning nil mirrors a disconnected state.
  func configure(
    dataStore: @escaping @MainActor () -> PersistenceStore?,
    contactService: @escaping @MainActor () -> ContactService?,
    advertisementService: @escaping @MainActor () -> AdvertisementService?
  ) {
    dataStoreProvider = dataStore
    contactServiceProvider = contactService
    advertisementServiceProvider = advertisementService
  }

  // MARK: - Load Contacts

  /// Load contacts from local database
  ///
  /// Loads overlap: the list reloads on every contact change, and a fetch queues behind sync
  /// writes on the one store actor, so a newer load often starts before an older one finishes.
  /// A finished fetch is committed unless a newer one already committed. Dropping every
  /// superseded fetch (as this did) meant a busy mesh, bumping faster than a fetch completes,
  /// never committed one: the list spun forever or stopped updating.
  func loadContacts(radioID: UUID) async {
    guard let dataStore else {
      // No store until a radio has been paired: the empty list, not a spinner.
      hasLoadedOnce = true
      return
    }

    loadGeneration += 1
    let generation = loadGeneration

    isLoading = true
    errorMessage = nil

    let fetched: [ContactDTO]?
    do {
      fetched = try await dataStore.fetchContacts(radioID: radioID)
    } catch is CancellationError {
      if generation == loadGeneration {
        isLoading = false
      }
      return
    } catch {
      guard generation > committedLoadGeneration else { return }
      errorMessage = error.userFacingMessage
      fetched = nil
    }

    // Best-effort inbound-hop fallback from the volatile discovered-node table; a failure here
    // must not fail the contact load, so it is fetched outside the throwing load path.
    let hops: [Data: Int] = await (try? dataStore.fetchDiscoveredNodes(radioID: radioID))?
      .reduce(into: [:]) { map, node in
        if let inbound = node.inboundHopCount { map[node.publicKey] = inbound }
      } ?? [:]
    guard generation > committedLoadGeneration else { return }
    committedLoadGeneration = generation

    if let fetched {
      contacts = mergeAdmissions(into: fetched)
      // Self-heal the mask: once a deleted row is gone from the fetch, stop masking it.
      pendingRemovalIDs.formIntersection(Set(contacts.map(\.id)))
    }
    inboundHopByKey = hops
    hasLoadedOnce = true
    if generation == loadGeneration {
      isLoading = false
    }
  }

  /// Marks the list loaded with nothing in it, for a caller with no radio to load.
  func showNoRadio() {
    contacts = []
    hasLoadedOnce = true
    isLoading = false
  }

  /// Inserts or replaces by `id`, then public key and `radioID`.
  /// Unmasks `pendingRemovalIDs` so a re-add is visible before the next load.
  func upsert(_ contact: ContactDTO) {
    rememberAdmission(contact)
    applyUpsert(contact)
  }

  private func rememberAdmission(_ contact: ContactDTO) {
    pendingAdmissions = pendingAdmissions.filter { id, existing in
      id != contact.id
        && !(existing.publicKey == contact.publicKey && existing.radioID == contact.radioID)
    }
    pendingAdmissions[contact.id] = contact
  }

  private func applyUpsert(_ contact: ContactDTO) {
    pendingRemovalIDs.remove(contact.id)
    if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
      contacts[index] = contact
      return
    }
    if let index = contacts.firstIndex(where: {
      $0.publicKey == contact.publicKey && $0.radioID == contact.radioID
    }) {
      pendingRemovalIDs.remove(contacts[index].id)
      contacts[index] = contact
      return
    }
    contacts.append(contact)
  }

  private func mergeAdmissions(into fetched: [ContactDTO]) -> [ContactDTO] {
    var result = fetched
    var resolved: [UUID] = []
    for (id, contact) in pendingAdmissions {
      let present = result.contains {
        $0.id == contact.id
          || ($0.publicKey == contact.publicKey && $0.radioID == contact.radioID)
      }
      if present {
        resolved.append(id)
      } else {
        result.append(contact)
      }
    }
    for id in resolved {
      pendingAdmissions.removeValue(forKey: id)
    }
    return result
  }

  // MARK: - Sync Contacts

  /// Sync contacts from device
  func syncContacts(radioID: UUID) async {
    guard let contactService else { return }
    // Claim the sync synchronously so a re-trigger while one is in flight is a no-op.
    guard !isSyncing else { return }

    isSyncing = true
    syncProgress = nil
    errorMessage = nil

    // `setSyncingContacts(true)` then `syncContactsForRefresh` so an advert-driven
    // sync cannot interleave progress events with this refresh.
    if let advertisementService {
      await advertisementService.setSyncingContacts(true)
    }

    // Subscribed synchronously before the sync starts so no progress event
    // is missed; scoped to this sync and cancelled when it completes.
    let events = contactService.events()
    let progressTask = Task { [weak self] in
      for await event in events {
        if case let .syncProgress(received, total) = event {
          self?.syncProgress = (received, total)
        }
      }
    }
    defer { progressTask.cancel() }

    do {
      _ = try await contactService.syncContactsForRefresh(radioID: radioID)

      // Reload from database
      await loadContacts(radioID: radioID)

      // Clear sync progress
      syncProgress = nil
    } catch is CancellationError {
      // Pull-to-refresh interrupted (tab switch, view teardown); not a failure to report.
    } catch {
      errorMessage = error.userFacingMessage
    }

    // Awaited rather than deferred to an unstructured Task so this sync's reset cannot
    // land after a later sync's setSyncingContacts(true) and clear the flag mid-sync.
    if let advertisementService {
      await advertisementService.setSyncingContacts(false)
    }

    isSyncing = false
  }

  // MARK: - Contact Actions

  /// Toggle favorite status on device and update local state
  func toggleFavorite(contact: ContactDTO) async {
    guard let contactService else { return }
    guard let current = contacts.first(where: { $0.id == contact.id }) else { return }

    togglingFavoriteID = contact.id
    defer { togglingFavoriteID = nil }

    do {
      try await contactService.setContactFavorite(contact.id, isFavorite: !current.isFavorite)

      // Reload to get updated state
      if contacts.contains(where: { $0.id == contact.id }) {
        await loadContacts(radioID: contact.radioID)
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Toggle blocked status
  func toggleBlocked(contact: ContactDTO) async {
    guard let contactService else { return }
    guard let current = contacts.first(where: { $0.id == contact.id }) else { return }

    do {
      try await contactService.updateContactPreferences(
        contactID: contact.id,
        isBlocked: !current.isBlocked
      )

      // Update local list
      await loadContacts(radioID: contact.radioID)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Update nickname
  func updateNickname(contact: ContactDTO, nickname: String?) async {
    guard let contactService else { return }

    do {
      try await contactService.updateContactPreferences(
        contactID: contact.id,
        nickname: nickname?.isEmpty == true ? nil : nickname
      )

      // Update local list
      await loadContacts(radioID: contact.radioID)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Delete a contact. Removing a node is a real radio command, so the row stays in place with a
  /// spinner until the radio acks, then is hidden once; a failure or timeout leaves it untouched
  /// with an error rather than bouncing it out and back.
  func deleteContact(_ contact: ContactDTO) async {
    guard let contactService else {
      errorMessage = L10n.Contacts.Contacts.ViewModel.connectToDelete
      return
    }
    guard !isDeletePending(contact.id) else { return }

    deletingIDs.insert(contact.id)
    defer { deletingIDs.remove(contact.id) }

    do {
      try await withTimeout(RadioCommandTimeout.delete, operationName: "removeContact") {
        try await contactService.removeContact(
          radioID: contact.radioID,
          publicKey: contact.publicKey
        )
      }
      hideDeletedContact(contact)
    } catch ContactServiceError.contactNotFound {
      // The radio no longer knows this contact (e.g. a prior attempt's command landed but its
      // local delete was interrupted). Clear the orphaned local row so it stops reappearing.
      do {
        try await contactService.removeLocalContact(contactID: contact.id, publicKey: contact.publicKey)
        hideDeletedContact(contact)
      } catch {
        errorMessage = error.userFacingMessage
      }
    } catch is TimeoutError {
      // Offered Retry by the list's alert rather than a plain error.
      deleteTimedOut = contact
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Runs the delete that timed out again, once the alert's Retry is tapped.
  func retryTimedOutDelete() async {
    guard let contact = deleteTimedOut else { return }
    deleteTimedOut = nil
    await deleteContact(contact)
  }

  // MARK: - Selection

  func beginSelecting() {
    selectedContactIDs = []
    isSelecting = true
  }

  func endSelecting() {
    isSelecting = false
    selectedContactIDs = []
  }

  func isSelected(_ contact: ContactDTO) -> Bool {
    selectedContactIDs.contains(contact.id)
  }

  func toggleSelection(_ contact: ContactDTO) {
    if selectedContactIDs.contains(contact.id) {
      selectedContactIDs.remove(contact.id)
    } else {
      selectedContactIDs.insert(contact.id)
    }
  }

  /// The picked nodes among `visible`, in list order.
  func selectedContacts(in visible: [ContactDTO]) -> [ContactDTO] {
    visible.filter { selectedContactIDs.contains($0.id) }
  }

  /// Whether every node shown is picked, which turns Select All into Deselect All.
  func isAllSelected(in visible: [ContactDTO]) -> Bool {
    !visible.isEmpty && visible.allSatisfy { selectedContactIDs.contains($0.id) }
  }

  func toggleSelectAll(in visible: [ContactDTO]) {
    selectedContactIDs = isAllSelected(in: visible) ? [] : Set(visible.map(\.id))
  }

  // MARK: - Bulk Actions

  /// Deletes the picked nodes one radio command at a time, each as `deleteContact` does it; a
  /// timeout stops the run and offers Retry for the node it stopped on.
  func deleteContacts(_ contacts: [ContactDTO]) async {
    for contact in contacts {
      await deleteContact(contact)
      if deleteTimedOut != nil || errorMessage != nil { return }
    }
  }

  /// Favorites (or unfavorites) every node that isn't already, then reloads once.
  func setFavorite(_ contacts: [ContactDTO], isFavorite: Bool) async {
    guard let contactService else { return }
    let targets = contacts.filter { $0.isFavorite != isFavorite }
    guard let radioID = targets.first?.radioID else { return }
    do {
      for contact in targets {
        togglingFavoriteID = contact.id
        try await contactService.setContactFavorite(contact.id, isFavorite: isFavorite)
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
    togglingFavoriteID = nil
    await loadContacts(radioID: radioID)
  }

  /// Blocks every chat contact picked that isn't blocked yet, then reloads once.
  func blockContacts(_ contacts: [ContactDTO]) async {
    guard let contactService else { return }
    let targets = contacts.filter { $0.type == .chat && !$0.isBlocked }
    guard let radioID = targets.first?.radioID else { return }
    do {
      for contact in targets {
        try await contactService.updateContactPreferences(contactID: contact.id, isBlocked: true)
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
    await loadContacts(radioID: radioID)
  }

  /// Masks and removes a row whose deletion the radio confirmed, in one animation.
  /// The mask insert is observed (read live by `filteredContacts`), so it must land inside
  /// the same transaction as the array removal or it hides the row unanimated first.
  private func hideDeletedContact(_ contact: ContactDTO) {
    withAnimation(.snappy) {
      pendingRemovalIDs.insert(contact.id)
      pendingAdmissions.removeValue(forKey: contact.id)
      contacts.removeAll { $0.id == contact.id }
    }
  }

  // MARK: - Filtering

  /// Everything `filteredContacts` depends on. The location only matters to the location-aware
  /// sorts, so GPS updates do not invalidate a last-heard or name ordering.
  private struct FilterKey: Equatable {
    let revision: Int
    let searchText: String
    let segment: NodeSegment
    let favoritesOnly: Bool
    let sortOrder: NodeSortOrder
    let groupID: UUID?
    let groupMemberKeys: [String]?
    let latitude: Double?
    let longitude: Double?
  }

  /// Returns contacts filtered by segment (and to favorites, when asked) and sorted. Called from
  /// the list hosts' body, so the
  /// result is memoized and only recomputed when contacts, the delete mask, hop data, the group
  /// filter, or the arguments change.
  func filteredContacts(
    searchText: String,
    segment: NodeSegment,
    favoritesOnly: Bool = false,
    sortOrder: NodeSortOrder,
    userLocation: CLLocation?
  ) -> [ContactDTO] {
    // Read the observed inputs on every call (even on a cache hit) so the calling body keeps
    // tracking them and re-evaluates when they change.
    _ = contacts
    _ = pendingRemovalIDs
    _ = bulkRemovalKeys
    _ = inboundHopByKey
    let group = selectedGroup

    let usesLocation = sortOrder == .distance || sortOrder == .hops
    let location = usesLocation ? userLocation?.coordinate : nil
    let key = FilterKey(
      revision: dataRevision,
      searchText: searchText,
      segment: segment,
      favoritesOnly: favoritesOnly,
      sortOrder: sortOrder,
      groupID: group?.id,
      groupMemberKeys: group?.memberKeys,
      latitude: location?.latitude,
      longitude: location?.longitude
    )
    if let filterCache, filterCache.key == key {
      return filterCache.result
    }

    let result = computeFilteredContacts(
      searchText: searchText,
      segment: segment,
      favoritesOnly: favoritesOnly,
      sortOrder: sortOrder,
      group: group,
      userLocation: usesLocation ? userLocation : nil
    )
    filterCache = (key, result)
    return result
  }

  private func computeFilteredContacts(
    searchText: String,
    segment: NodeSegment,
    favoritesOnly: Bool,
    sortOrder: NodeSortOrder,
    group: ContactGroup?,
    userLocation: CLLocation?
  ) -> [ContactDTO] {
    var result = contacts.filter { !pendingRemovalIDs.contains($0.id) && !bulkRemovalKeys.contains($0.publicKey) }

    if let group {
      let keys = Set(group.memberKeys)
      result = result.filter { keys.contains(ContactGroup.memberKey(for: $0.publicKey)) }
    }

    // If searching or filtering by group, show all types (ignore segment)
    if searchText.isEmpty, group == nil {
      // Filter by segment
      switch segment {
      case .all:
        break
      case .contacts:
        result = result.filter { $0.type == .chat }
      case .repeaters:
        result = result.filter { $0.type == .repeater }
      case .rooms:
        result = result.filter { $0.type == .room }
      }
      if favoritesOnly {
        result = result.filter(\.isFavorite)
      }
    } else if !searchText.isEmpty {
      // Filter by search text only
      let hexes = publicKeyHexes()
      let hexQuery = searchText.uppercased()
      result = result.filter { contact in
        contact.displayName.localizedStandardContains(searchText)
          || (hexes[contact.publicKey] ?? contact.publicKey.uppercaseHexString()).hasPrefix(hexQuery)
      }
    }

    return sorted(result, by: sortOrder, userLocation: userLocation)
  }

  private func publicKeyHexes() -> [Data: String] {
    if let hexByKey { return hexByKey }
    var map: [Data: String] = [:]
    map.reserveCapacity(contacts.count)
    for contact in contacts {
      map[contact.publicKey] = contact.publicKey.uppercaseHexString()
    }
    hexByKey = map
    return map
  }

  /// Sort contacts by the given order (`NodeSortOrder.sorted`, which the car's Nodes list shares).
  private func sorted(
    _ contacts: [ContactDTO],
    by order: NodeSortOrder,
    userLocation: CLLocation?
  ) -> [ContactDTO] {
    let ranks = order == .manual ? manualRanks : [:]
    return order.sorted(
      contacts,
      recency: { TimeInterval($0.recencyTimestamp) },
      name: \.displayName,
      distance: { distance(of: $0, from: userLocation) },
      hops: { $0.displayedHopCount(inboundHopCount: inboundHopByKey[$0.publicKey]) },
      manualRank: { ranks[$0.publicKey] }
    )
  }

  // MARK: - Manual Order

  /// The order the user put the nodes in (the Manual sort): public keys, first to last, kept on
  /// this device. Nodes not in it list after the placed ones, most recent first, until they're
  /// dragged somewhere.
  private(set) var manualOrder: [Data] = ContactsViewModel.loadManualOrder() {
    didSet {
      dataRevision &+= 1
      UserDefaults.standard.set(manualOrder.map { $0.uppercaseHexString() }, forKey: AppStorageKey.nodesManualOrder.rawValue)
    }
  }

  private var manualRanks: [Data: Int] {
    Dictionary(manualOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
  }

  private static func loadManualOrder() -> [Data] {
    (UserDefaults.standard.stringArray(forKey: AppStorageKey.nodesManualOrder.rawValue) ?? [])
      .compactMap(Data.init(hexString:))
  }

  /// Puts the node `key` where the user dropped it: on `target`'s place, the rest closing up.
  /// Dragged down the list it lands after the target, dragged up it lands before it, so a node
  /// can go to either end. `shown` is the list as it stands, which seeds the order the first time
  /// (and places any node not yet in it), so nothing else moves.
  func moveNode(_ key: Data, onto target: Data, shown: [ContactDTO]) {
    guard key != target else { return }
    var order = manualOrder
    let known = Set(order)
    order += shown.map(\.publicKey).filter { !known.contains($0) }
    let placed = Set(order)
    order += contacts.map(\.publicKey).filter { !placed.contains($0) }
    guard let from = order.firstIndex(of: key), let to = order.firstIndex(of: target) else { return }
    order.remove(at: from)
    // After removing, the target sits one earlier when it was below the dragged node.
    let insertAt = from < to ? to : to
    order.insert(key, at: min(insertAt, order.count))
    manualOrder = order
  }

  private func distance(of contact: ContactDTO, from userLocation: CLLocation?) -> Double? {
    guard let userLocation, contact.hasLocation else { return nil }
    return CLLocation(latitude: contact.latitude, longitude: contact.longitude).distance(from: userLocation)
  }
}
