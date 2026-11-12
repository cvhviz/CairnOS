import CairnServices
import os.log
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "PathManagement")

/// Drives `navigationDestination(item:)`/`sheet(item:)` on the path editors.
/// Modeled as an enum (rather than `Bool` or `Void`) so the item binding has a
/// concrete `Identifiable`/`Hashable` type: a hop goes on the end, or in at a position
/// (a hop row's Insert Hop Before), the hops from there on moving up one.
enum AddHopIntent: Hashable, Identifiable {
  case append
  case insert(at: Int)

  var id: Self {
    self
  }
}

/// Sections the Add-Hop picker can narrow to. `.all` shows every section.
enum AddHopFilter: String, CaseIterable, Identifiable {
  case all, favorites, recent, discovered

  var id: String {
    rawValue
  }

  var localizedLabel: String {
    switch self {
    case .all: L10n.Contacts.Contacts.PathEdit.Filter.all
    case .favorites: L10n.Contacts.Contacts.PathEdit.Filter.favorites
    case .recent: L10n.Contacts.Contacts.PathEdit.Filter.recent
    case .discovered: L10n.Contacts.Contacts.PathEdit.Filter.discovered
    }
  }
}

/// Represents a single hop in the routing path with stable identity for SwiftUI
struct PathHop: Identifiable, Equatable {
  let id = UUID()
  var hashBytes: Data // Public key prefix bytes (1–3 bytes depending on hash mode)
  var publicKey: Data? // Full 32-byte key when known (for unambiguous matching)
  var resolvedName: String? // Contact name if resolved, nil if unknown

  var hashHex: String {
    hashBytes.uppercaseHexString()
  }

  var displayText: String {
    if let name = resolvedName {
      return "\(name) (\(hashHex))"
    }
    return hashHex
  }
}

/// Result of a path discovery operation. A discovery reply carries both directions, which can
/// differ: the route out to the node and the one its reply came back by.
enum PathDiscoveryResult: Equatable {
  case success(hopCount: Int, route: [String] = [], back: DiscoveredLeg? = nil)
  case noPathFound
  case failed(String)

  /// The way back from the node: its hop count and the hops, in the order the reply crossed them.
  struct DiscoveredLeg: Equatable {
    let hopCount: Int
    let route: [String]
  }

  var description: String {
    switch self {
    case let .success(hopCount, route, back):
      guard let back else { return Self.hopsPhrase(hopCount) }
      return [
        L10n.Contacts.Contacts.PathDiscovery.outbound(Self.legText(hopCount, route)),
        L10n.Contacts.Contacts.PathDiscovery.back(Self.legText(back.hopCount, back.route))
      ].joined(separator: "\n")
    case .noPathFound:
      return L10n.Contacts.Contacts.PathDiscovery.noResponse
    case let .failed(message):
      return L10n.Contacts.Contacts.PathDiscovery.failed(message)
    }
  }

  private static func hopsPhrase(_ hopCount: Int) -> String {
    if hopCount == 0 {
      L10n.Contacts.Contacts.PathDiscovery.direct
    } else if hopCount == 1 {
      L10n.Contacts.Contacts.PathDiscovery.Hops.singular
    } else {
      L10n.Contacts.Contacts.PathDiscovery.Hops.plural(hopCount)
    }
  }

  /// "2 hops (Hilltop → 7F)", or the count alone for a direct leg.
  private static func legText(_ hopCount: Int, _ route: [String]) -> String {
    route.isEmpty ? hopsPhrase(hopCount) : "\(hopsPhrase(hopCount)) (\(route.joined(separator: " \u{2192} ")))"
  }
}

@Observable
@MainActor
final class PathManagementViewModel {
  // MARK: - State

  var isDiscovering = false
  var isSettingPath = false
  var discoveryResult: PathDiscoveryResult?
  var showDiscoveryResult = false
  var errorMessage: String?

  /// Path editing state
  var showingPathEditor = false
  /// Drives navigationDestination(item:) pushing the Add Hop picker.
  var insertionIntent: AddHopIntent?
  var editablePath: [PathHop] = [] // Current path being edited (stable identifiers)

  /// The hops the editor opened on, so Cancel and a swipe down know whether there is
  /// anything to lose (`hasChanges`).
  private(set) var initialPathHashes: [Data] = []

  /// The editor holds hops that differ from the path it opened on.
  var hasChanges: Bool {
    editablePath.map(\.hashBytes) != initialPathHashes
  }

  /// One level of undo for the editor: the path as it was before the last removal, reorder or
  /// replacement, and what that was, for the toast that offers it.
  struct UndoEntry: Equatable {
    let path: [PathHop]
    let description: String
  }

  /// The last removal, reorder or replacement, until undone or superseded. Nil once undone.
  private(set) var undoEntry: UndoEntry?
  /// Bumped with each new `undoEntry`, so the toast shows again for a second removal.
  private(set) var undoVersion = 0

  /// LRU of recently inserted public keys, most-recent first, capped at 8.
  /// Radio-scoped: cleared and reloaded when `loadContacts(radioID:)` fires.
  var recentPublicKeys: [Data] = []

  /// Captured radio scope for persistence. Set by `loadRecentKeys(for:)`.
  private var currentRadioID: UUID?

  /// Firmware `outPath` budget: 64 bytes. `encodePathLen` also clamps the
  /// hop-count field to 6 bits (0…63). The effective cap is whichever is
  /// smaller.
  private static let pathByteBudget = 64
  private static let pathHopFieldCap = 63

  var availableRepeaters: [ContactDTO] = [] // Known repeaters to add
  var availableRooms: [ContactDTO] = [] // Known rooms (may act as repeaters)
  var allContacts: [ContactDTO] = [] // All contacts for name resolution
  var discoveredNodes: [DiscoveredNodeDTO] = []

  /// Combined repeaters and rooms for resolution
  var availableNodes: [ContactDTO] {
    availableRepeaters + availableRooms
  }

  /// Discovered repeaters available to add
  var discoveredRepeaters: [DiscoveredNodeDTO] {
    discoveredNodes.filter { $0.nodeType == .repeater }
  }

  /// Discovery cancellation
  private var discoveryTask: Task<Void, Never>?

  // Discovery countdown state
  var discoverySecondsRemaining: Int?
  private var countdownTask: Task<Void, Never>?
  private var discoveryStartTime: Date?
  private var discoveryTimeoutSeconds: Double?

  // MARK: - Dependencies

  // Provider closures are re-evaluated at every use so a disconnect (or a
  // container rebuild) between actions is observed live, never a stale snapshot.
  private var dataStoreProvider: @MainActor () -> PersistenceStore? = { nil }
  private var contactServiceProvider: @MainActor () -> ContactService? = { nil }
  private var connectedDeviceProvider: @MainActor () -> DeviceDTO? = { nil }
  private let recents: RecentHopsStore

  init(defaults: UserDefaults = .standard) {
    recents = RecentHopsStore(defaults: defaults)
  }

  /// Current hash size from device configuration (1, 2, or 3 bytes per hop).
  /// Clamped to `1...3` so a firmware `pathHashMode` of 3 (reserved) never trips
  /// `encodePathLen`'s `1...3` precondition on save.
  var hashSize: Int {
    let raw = connectedDeviceProvider()?.hashSize ?? 1
    return min(max(raw, 1), 3)
  }

  /// Maximum number of hops the path can hold under the current `hashSize`.
  /// Bounded by both the 6-bit hop-count field (0…63) and the 64-byte path
  /// payload. Past this cap, firmware silently truncates.
  var maxHopCount: Int {
    min(Self.pathHopFieldCap, Self.pathByteBudget / hashSize)
  }

  /// True when `editablePath.count` has hit `maxHopCount`. Callers (the
  /// Add Hop CTA + picker) disable insert affordances when this is true.
  var isPathFull: Bool {
    editablePath.count >= maxHopCount
  }

  // MARK: - Callbacks

  /// Called when path discovery completes and contact should be refreshed
  var onContactNeedsRefresh: (() -> Void)?

  // MARK: - Configuration

  /// Each provider is read live at its point of use; a provider returning
  /// `nil` mirrors a disconnected state, so unconfigured calls are no-ops.
  func configure(
    dataStore: @escaping @MainActor () -> PersistenceStore?,
    contactService: @escaping @MainActor () -> ContactService?,
    connectedDevice: @escaping @MainActor () -> DeviceDTO?,
    onContactNeedsRefresh: @escaping () -> Void
  ) {
    dataStoreProvider = dataStore
    contactServiceProvider = contactService
    connectedDeviceProvider = connectedDevice
    self.onContactNeedsRefresh = onContactNeedsRefresh
  }

  // MARK: - Name Resolution

  /// Resolve path hash bytes to a contact name if possible
  /// Returns the contact name if exactly one contact matches, otherwise falls back to discovered nodes
  func resolveHashToName(_ hashBytes: Data) -> String? {
    let matches = allContacts.filter { $0.publicKey.prefix(hashBytes.count) == hashBytes }
    if matches.count == 1 {
      return matches[0].resolvableName
    }
    // Fall back to discovered nodes with same single-match rule
    if matches.isEmpty {
      let discoveredMatches = discoveredNodes.filter { $0.publicKey.prefix(hashBytes.count) == hashBytes }
      if discoveredMatches.count == 1 {
        return discoveredMatches[0].resolvableName
      }
    }
    return nil // Ambiguous (multiple matches) or unknown
  }

  /// Resolve path hash bytes to a node's full 32-byte public key if exactly one
  /// match exists. Populating this on hops loaded from storage lets
  /// `saveEditedPath` re-encode the path at the device's current `hashSize`
  /// even if the stored path used a smaller size.
  func resolveHashToPublicKey(_ hashBytes: Data) -> Data? {
    let matches = allContacts.filter { $0.publicKey.prefix(hashBytes.count) == hashBytes }
    if matches.count == 1 {
      return matches[0].publicKey
    }
    if matches.isEmpty {
      let discoveredMatches = discoveredNodes.filter { $0.publicKey.prefix(hashBytes.count) == hashBytes }
      if discoveredMatches.count == 1 {
        return discoveredMatches[0].publicKey
      }
    }
    return nil
  }

  /// Create a PathHop from hash bytes, resolving the name and full public key
  /// when exactly one contact or discovered node matches the prefix.
  func createPathHop(from hashBytes: Data) -> PathHop {
    PathHop(
      hashBytes: hashBytes,
      publicKey: resolveHashToPublicKey(hashBytes),
      resolvedName: resolveHashToName(hashBytes)
    )
  }

  /// Load all contacts for name resolution and filter repeaters for adding.
  /// Always refreshes recents for the given `radioID` so switching radios on
  /// a reused view model picks up the right scope even if the contacts cache
  /// lets us skip the network fetch.
  func loadContacts(radioID: UUID, forceReload: Bool = false) async {
    guard let dataStore = dataStoreProvider() else { return }

    loadRecentKeys(for: radioID)

    // Skip if already loaded
    if !forceReload, !allContacts.isEmpty {
      return
    }

    do {
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      allContacts = contacts
      availableRepeaters = contacts.filter { $0.type == .repeater }
      availableRooms = contacts.filter { $0.type == .room }
      let nodes = try await dataStore.fetchDiscoveredNodes(radioID: radioID)
      discoveredNodes = nodes
    } catch {
      allContacts = []
      availableRepeaters = []
      availableRooms = []
      discoveredNodes = []
    }
  }

  /// Initialize editable path from contact's current path with name resolution.
  /// Resets `insertionIntent` so a stale value from a prior sheet presentation
  /// can't auto-push the Add Hop picker on open.
  ///
  /// Hops are normalized to the device's current ``hashSize`` so the editor
  /// never shows mixed-width hops after a `pathHashMode` change between edits.
  /// Resolvable hops re-slice from their full `publicKey`; unresolvable wider
  /// hops narrow via truncation; unresolvable narrower hops are left as-is so
  /// ``saveRejection`` can flag them on save.
  func initializeEditablePath(from contact: ContactDTO) {
    insertionIntent = nil
    undoEntry = nil
    editablePath = hops(from: contact)
    initialPathHashes = editablePath.map(\.hashBytes)
  }

  /// A contact's stored hops, resolved and normalized to the device's hash size.
  private func hops(from contact: ContactDTO) -> [PathHop] {
    let byteLength = contact.pathByteLength
    let storedHashSize = contact.pathHashSize
    let pathData = contact.outPath.prefix(byteLength)
    let targetHashSize = hashSize
    return stride(from: 0, to: pathData.count, by: storedHashSize).map { start in
      let end = min(start + storedHashSize, pathData.count)
      let bytes = Data(pathData[start..<end])
      let hop = createPathHop(from: bytes)
      return Self.normalizeHop(hop, targetHashSize: targetHashSize)
    }
  }

  // MARK: - Copying another node's path

  /// The other nodes with a stored route (not flood, at least one hop), by name, for Copy Path
  /// From. The node being edited is left out: its own path is what's being edited.
  func copyablePathSources(excluding publicKey: Data) -> [ContactDTO] {
    allContacts
      .filter { $0.publicKey != publicKey && !$0.isFloodRouted && $0.pathHopCount > 0 }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  /// Replaces the hops with `source`'s stored route, undoable. A route longer than the cap is
  /// cut to it, so the editor never holds more than it can save.
  func adoptPath(from source: ContactDTO) {
    let adopted = Array(hops(from: source).prefix(maxHopCount))
    guard adopted.map(\.hashBytes) != editablePath.map(\.hashBytes) else { return }
    rememberForUndo(L10n.Contacts.Contacts.PathEdit.Undo.replaced)
    editablePath = adopted
  }

  // MARK: - Undo

  private func rememberForUndo(_ description: String) {
    undoEntry = UndoEntry(path: editablePath, description: description)
    undoVersion += 1
  }

  /// Puts the path back as it was before the last removal, reorder or replacement.
  func undo() {
    guard let undoEntry else { return }
    editablePath = undoEntry.path
    self.undoEntry = nil
  }

  /// Lets the toast go without undoing.
  func clearUndo() {
    undoEntry = nil
  }

  /// Normalize a hop loaded from storage so its `hashBytes` width matches the
  /// device's current hash size. Three branches:
  ///
  /// 1. **Resolved** → re-slice from the full `publicKey` at the target width.
  /// 2. **Unresolved, wider than target** → truncate stored `hashBytes`.
  /// 3. **Unresolved, same width or narrower than target** → leave as-is. The
  ///    equal-width case is already consistent, and the narrower case has to
  ///    wait for ``saveRejection`` to block the save since we can't safely
  ///    widen an unknown prefix.
  ///
  /// - Precondition: `targetHashSize` is 1, 2, or 3.
  nonisolated static func normalizeHop(_ hop: PathHop, targetHashSize: Int) -> PathHop {
    precondition(1...3 ~= targetHashSize, "targetHashSize must be 1, 2, or 3")
    if let publicKey = hop.publicKey {
      return PathHop(
        hashBytes: Data(publicKey.prefix(targetHashSize)),
        publicKey: publicKey,
        resolvedName: hop.resolvedName
      )
    }
    if hop.hashBytes.count > targetHashSize {
      return PathHop(
        hashBytes: Data(hop.hashBytes.prefix(targetHashSize)),
        publicKey: nil,
        resolvedName: hop.resolvedName
      )
    }
    return hop
  }

  /// Append a node to the path, or put it in at a position. No-op when `isPathFull`, and
  /// when the node is already a hop: a packet never needs the same repeater twice, and the
  /// picker shows such a node as In path. Records the pubkey in recents. The picker stays on
  /// screen so users can add several hops in a row; `insertionIntent` is cleared only when the
  /// user taps back (SwiftUI writes `nil` through the navigation binding).
  func insert(_ node: some RepeaterResolvable, at intent: AddHopIntent) {
    guard !isPathFull else { return }
    let hashBytes = Data(node.publicKey.prefix(hashSize))
    guard !isInPath(hashBytes: hashBytes) else {
      // Picked again all the same: still the most recent pick, just not a second hop.
      recordRecent(node.publicKey)
      return
    }
    let hop = PathHop(
      hashBytes: hashBytes,
      publicKey: node.publicKey,
      resolvedName: node.resolvableName
    )
    switch intent {
    case .append:
      editablePath.append(hop)
    case let .insert(index):
      editablePath.insert(hop, at: min(max(0, index), editablePath.count))
    }
    recordRecent(node.publicKey)
  }

  /// Whether a node is already a hop of the path being edited, by its hash at the device's
  /// current width (what the path stores).
  func isInPath(_ publicKey: Data) -> Bool {
    isInPath(hashBytes: Data(publicKey.prefix(hashSize)))
  }

  private func isInPath(hashBytes: Data) -> Bool {
    editablePath.contains { $0.hashBytes == hashBytes }
  }

  // MARK: - Recents persistence

  /// Internal — tests invoke this directly via `@testable import Cairn` to seed
  /// a specific radio scope without building a full `AppState`.
  func loadRecentKeys(for radioID: UUID) {
    currentRadioID = radioID
    recentPublicKeys = recents.load(for: radioID)
  }

  /// LRU insert via ``RecentHopsStore``, persisting under the captured radio scope.
  func recordRecent(_ publicKey: Data) {
    guard let radioID = currentRadioID else { return }
    recentPublicKeys = recents.record(publicKey, into: recentPublicKeys, for: radioID)
  }

  /// Remove a repeater from the path at index, undoable.
  func removeRepeater(at index: Int) {
    guard editablePath.indices.contains(index) else { return }
    let hop = editablePath[index]
    rememberForUndo(L10n.Contacts.Contacts.PathEdit.Undo.removed(hop.resolvedName ?? hop.hashHex))
    editablePath.remove(at: index)
  }

  /// Move a repeater within the path, undoable when it lands somewhere else.
  func moveRepeater(from source: IndexSet, to destination: Int) {
    var moved = editablePath
    moved.move(fromOffsets: source, toOffset: destination)
    guard moved.map(\.id) != editablePath.map(\.id) else { return }
    rememberForUndo(L10n.Contacts.Contacts.PathEdit.Undo.moved)
    editablePath = moved
  }

  /// Reason a candidate edit cannot be saved, or `nil` if encoding is safe.
  /// Pure so tests can drive every branch without an `AppState`.
  ///
  /// - Precondition: `targetHashSize` is 1, 2, or 3. Matches `encodePathLen`'s
  ///   contract so bypassing the production call site (which clamps via
  ///   `hashSize`) still trips a clear assertion rather than a deep crash.
  nonisolated static func saveRejection(
    for hops: [PathHop],
    targetHashSize: Int,
    maxHopCount: Int
  ) -> String? {
    precondition(1...3 ~= targetHashSize, "targetHashSize must be 1, 2, or 3")
    // `Data.prefix(n)` returns `min(count, n)` bytes — no padding. A hop
    // whose stored `hashBytes` are narrower than `targetHashSize` and has no
    // full `publicKey` to widen from would serialise short, and firmware
    // would mis-parse the path against the declared `pathLength`.
    let hopNeedsResize = hops.contains { hop in
      hop.publicKey == nil && hop.hashBytes.count < targetHashSize
    }
    if hopNeedsResize {
      return L10n.Contacts.Contacts.PathManagement.Error.hopResizeRequired
    }
    if hops.count > maxHopCount {
      return L10n.Contacts.Contacts.PathManagement.Error.tooManyHops(maxHopCount)
    }
    return nil
  }

  /// Encode the path payload at the device's current hash size. Prefers the
  /// full 32-byte public key when available; falls back to stored
  /// `hashBytes`. Callers must have called `saveRejection` first to ensure
  /// the fallback never truncates below `targetHashSize`.
  ///
  /// - Precondition: `targetHashSize` is 1, 2, or 3.
  nonisolated static func encodeEditablePath(
    _ hops: [PathHop],
    targetHashSize: Int
  ) -> (path: Data, length: UInt8) {
    precondition(1...3 ~= targetHashSize, "targetHashSize must be 1, 2, or 3")
    let pathData = Data(hops.flatMap { hop -> Data in
      if let publicKey = hop.publicKey {
        return publicKey.prefix(targetHashSize)
      }
      return hop.hashBytes.prefix(targetHashSize)
    })
    let pathLength = encodePathLen(hashSize: targetHashSize, hopCount: hops.count)
    return (pathData, pathLength)
  }

  /// Save the edited path to the contact. Hops may have been loaded from a
  /// stored path with a smaller `hashSize` than the device currently reports
  /// (user changed `pathHashMode`). `saveRejection` catches the cases where
  /// we can't safely re-encode; otherwise `encodeEditablePath` re-encodes
  /// every hop at the current `hashSize`.
  func saveEditedPath(for contact: ContactDTO) async {
    guard let contactService = contactServiceProvider() else { return }

    errorMessage = nil
    let targetHashSize = hashSize

    if let rejection = Self.saveRejection(
      for: editablePath,
      targetHashSize: targetHashSize,
      maxHopCount: maxHopCount
    ) {
      errorMessage = rejection
      return
    }

    isSettingPath = true

    do {
      let encoded = Self.encodeEditablePath(editablePath, targetHashSize: targetHashSize)
      try await contactService.setPath(
        radioID: contact.radioID,
        publicKey: contact.publicKey,
        path: encoded.path,
        pathLength: encoded.length
      )
      onContactNeedsRefresh?()
    } catch {
      errorMessage = L10n.Contacts.Contacts.PathManagement.Error.saveFailed(error.userFacingMessage)
    }

    isSettingPath = false
  }

  // MARK: - Path Operations

  /// Starts path discovery for a contact. Timeout is terminal for the UI: a
  /// late push after `.noPathFound` does not flip to success.
  func discoverPath(for contact: ContactDTO) async {
    guard let contactService = contactServiceProvider() else { return }

    discoveryTask?.cancel()

    isDiscovering = true
    discoveryResult = nil
    errorMessage = nil

    discoveryTask = Task { @MainActor in
      do {
        let sentResponse = try await contactService.sendPathDiscovery(
          radioID: contact.radioID,
          publicKey: contact.publicKey
        )

        let timeoutSeconds = FirmwareSuggestedTimeout.pathDiscoverySeconds(
          suggestedTimeoutMs: sentResponse.suggestedTimeoutMs
        )
        if sentResponse.suggestedTimeoutMs == 0 {
          logger.warning(
            "Path discovery timeout default applied: firmware suggested no timeout, using \(timeoutSeconds)s"
          )
        } else {
          logger.info(
            "Path discovery timeout: \(timeoutSeconds)s (firmware suggested: \(sentResponse.suggestedTimeoutMs)ms)"
          )
        }

        self.discoveryTimeoutSeconds = timeoutSeconds
        self.discoveryStartTime = Date.now
        self.discoverySecondsRemaining = Int(timeoutSeconds)
        self.startCountdownTask()

        // One send for the whole budget: the radio keeps a single discovery tag and each
        // send clears every other pending request, so a resend floods the mesh again,
        // cancels in-flight logins and requests, and orphans a reply to the first send.
        // `handleDiscoveryResponse` cancels this task on success.
        try await Task.sleep(for: .seconds(timeoutSeconds))

        // Finished sleep does not throw on cancel; re-check so a response that
        // landed at expiry is not overwritten by `.noPathFound`.
        guard !Task.isCancelled else { return }

        discoveryResult = .noPathFound
        showDiscoveryResult = true
      } catch is CancellationError {
        // Cancel, success path, or a fresh `discoverPath` already owns state.
        return
      } catch {
        discoveryResult = .failed(error.userFacingMessage)
        showDiscoveryResult = true
      }

      isDiscovering = false
      cleanupCountdownState()
    }
  }

  /// Start the countdown task that updates remaining seconds every 5 seconds.
  /// Cancels any prior countdown first so a `discoverPath` re-entry can't
  /// leave an orphan task writing `discoverySecondsRemaining` alongside the
  /// new one — the outer `discoveryTask` cancel doesn't propagate to this
  /// sibling.
  private func startCountdownTask() {
    countdownTask?.cancel()
    countdownTask = Task {
      while !Task.isCancelled, let timeout = discoveryTimeoutSeconds, let startTime = discoveryStartTime {
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          break
        }
        // Re-check after sleep: cancellation can fire between iterations
        // without sleep throwing. Without this, a stale task could write
        // a stale remaining value over a fresh discovery's state.
        guard !Task.isCancelled else { break }
        let elapsed = Date.now.timeIntervalSince(startTime)
        let remaining = max(0, Int(timeout - elapsed))
        discoverySecondsRemaining = remaining
      }
    }
  }

  /// Clean up countdown state when discovery ends
  private func cleanupCountdownState() {
    countdownTask?.cancel()
    countdownTask = nil
    discoverySecondsRemaining = nil
    discoveryStartTime = nil
    discoveryTimeoutSeconds = nil
  }

  /// Cancel an in-progress path discovery
  func cancelDiscovery() {
    discoveryTask?.cancel()
    discoveryTask = nil
    isDiscovering = false
    cleanupCountdownState()
  }

  /// Resolves an in-flight discovery from a path-discovery push.
  ///
  /// Requires `isDiscovering`; after timeout or cancel the response is ignored
  /// here (`AdvertisementService` may still persist the path). `hopCount` is
  /// `nil` when `out_path_len` used a reserved hash-size mode and could not be
  /// decoded — treated as no valid path, not a silent direct route.
  func handleDiscoveryResponse(hopCount: Int?) {
    guard isDiscovering else { return }
    finishDiscovery(hopCount.map { .success(hopCount: $0) } ?? .noPathFound)
  }

  private func finishDiscovery(_ result: PathDiscoveryResult) {
    discoveryTask?.cancel()
    isDiscovering = false
    cleanupCountdownState()

    discoveryResult = result
    showDiscoveryResult = true

    onContactNeedsRefresh?()
  }

  /// Routes an advertisement-service push for `contact` to the discovery in flight.
  /// A discovery reply resolves it directly. A path push resolves it too: the radio
  /// stores a reply it no longer holds the tag for (or a route learned another way)
  /// itself and says so only with `PATH_UPDATED`, so the route is read back from it.
  func handleAdvertisementEvent(_ event: AdvertisementEvent, for contact: ContactDTO) async {
    switch event {
    case let .pathDiscoveryResponse(response) where response.matches(publicKey: contact.publicKey):
      handleDiscoveryResponse(response)
    case let .contactPathUpdated(publicKey) where publicKey == contact.publicKey:
      guard isDiscovering, let contactService = contactServiceProvider() else { return }
      do {
        let refreshed = try await contactService.refreshContactFromRadio(
          radioID: contact.radioID,
          publicKey: contact.publicKey
        )
        if let refreshed { handleDiscoveryPathUpdated(outPathLength: refreshed.outPathLength) }
      } catch {
        // The discovery reply or the timeout still ends the attempt.
        logger.warning("Path push during discovery: reading the route back failed: \(error.localizedDescription)")
      }
    default:
      break
    }
  }

  /// The way back the last discovery reply took (`in_path`), kept beside the route out, which
  /// the radio now uses, so an asymmetric route shows. Nil until a reply arrives.
  private(set) var discoveredReturnPath: (length: UInt8, path: Data)?
  /// The route out the last discovery reply found (`out_path`), so it can be stored again by
  /// hand should the radio not have kept it.
  private(set) var discoveredOutboundPath: (length: UInt8, path: Data)?

  /// A discovery reply with a route to offer: Use Discovered Route on the result.
  var canUseDiscoveredRoute: Bool {
    guard case .success = discoveryResult else { return false }
    return discoveredOutboundPath != nil
  }

  /// A discovery reply whose way back had hops of its own: Use Return Route on the result.
  var canUseReturnRoute: Bool {
    guard case let .success(_, _, back) = discoveryResult, let back, back.hopCount > 0 else { return false }
    return discoveredReturnPath != nil
  }

  /// Stores the route out the discovery found as the node's path.
  func applyDiscoveredRoute(for contact: ContactDTO) async {
    guard let route = discoveredOutboundPath else { return }
    await setPath(for: contact, path: route.path, pathLength: route.length)
  }

  /// Stores the way back the discovery reply took as the node's path: the hops in the order a
  /// packet to the node would cross them, which is the reply's order reversed.
  func applyReturnRoute(for contact: ContactDTO) async {
    guard let route = discoveredReturnPath, let decoded = decodePathLen(route.length) else { return }
    let hops = Self.hops(of: route.path, byteLength: decoded.byteLength, hashSize: decoded.hashSize)
    let reversed = Data(hops.reversed().joined())
    await setPath(for: contact, path: reversed, pathLength: route.length)
  }

  /// A path's hops as byte chunks of `hashSize`, `byteLength` bytes in all.
  nonisolated static func hops(of path: Data, byteLength: Int, hashSize: Int) -> [Data] {
    let bytes = Data(path.prefix(byteLength))
    let width = max(1, hashSize)
    return stride(from: 0, to: bytes.count, by: width).map { start in
      Data(bytes[start..<min(start + width, bytes.count)])
    }
  }

  /// Resolves an in-flight discovery from a reply carrying both directions.
  func handleDiscoveryResponse(_ response: PathInfo) {
    guard isDiscovering else { return }
    guard let outHops = response.outHopCount else {
      handleDiscoveryResponse(hopCount: nil)
      return
    }
    discoveredReturnPath = (response.inPathLength, response.inPath)
    discoveredOutboundPath = (response.outPathLength, response.outPath)
    let back = response.inHopCount.map {
      PathDiscoveryResult.DiscoveredLeg(hopCount: $0, route: hopNames(response.inPath, pathLength: response.inPathLength))
    }
    finishDiscovery(.success(
      hopCount: outHops,
      route: hopNames(response.outPath, pathLength: response.outPathLength),
      back: back
    ))
  }

  /// Each hop of a path by name where one node matches it, by hash otherwise.
  private func hopNames(_ path: Data, pathLength: UInt8) -> [String] {
    guard let decoded = decodePathLen(pathLength) else { return [] }
    let bytes = Data(path.prefix(decoded.byteLength))
    return stride(from: 0, to: bytes.count, by: decoded.hashSize).map { start in
      let hop = Data(bytes[start..<min(start + decoded.hashSize, bytes.count)])
      return resolveHashToName(hop) ?? hop.uppercaseHexString()
    }
  }

  /// Resolves an in-flight discovery from the route the radio stored after a path push.
  /// A flood route (`0xFF`) is no answer, so the wait goes on.
  func handleDiscoveryPathUpdated(outPathLength: UInt8) {
    guard isDiscovering, outPathLength != PacketBuilder.floodPathSentinel else { return }
    handleDiscoveryResponse(hopCount: decodePathLen(outPathLength)?.hopCount)
  }

  /// Reset the path for a contact (force flood routing)
  func resetPath(for contact: ContactDTO) async {
    guard let contactService = contactServiceProvider() else { return }

    isSettingPath = true
    errorMessage = nil

    do {
      try await contactService.resetPath(
        radioID: contact.radioID,
        publicKey: contact.publicKey
      )
      onContactNeedsRefresh?()
    } catch {
      errorMessage = L10n.Contacts.Contacts.PathManagement.Error.resetFailed(error.userFacingMessage)
    }

    isSettingPath = false
  }

  /// Set a specific path for a contact
  func setPath(for contact: ContactDTO, path: Data, pathLength: UInt8) async {
    guard let contactService = contactServiceProvider() else { return }

    isSettingPath = true
    errorMessage = nil

    do {
      try await contactService.setPath(
        radioID: contact.radioID,
        publicKey: contact.publicKey,
        path: path,
        pathLength: pathLength
      )
      onContactNeedsRefresh?()
    } catch {
      errorMessage = L10n.Contacts.Contacts.PathManagement.Error.setFailed(error.userFacingMessage)
    }

    isSettingPath = false
  }
}

// MARK: - HopPickerSource

extension PathManagementViewModel: HopPickerSource {
  var currentHopCount: Int {
    editablePath.count
  }

  /// Contact paths are capped; expose the cap so the shared picker can show the
  /// max-hops state and stop bulk-add cleanly.
  var hopLimit: Int? {
    maxHopCount
  }

  func appendHop(_ node: some RepeaterResolvable) {
    insert(node, at: .append)
  }

  func insertHop(_ node: some RepeaterResolvable, at intent: AddHopIntent) {
    insert(node, at: intent)
  }

  func classifyCodes(_ input: String) -> [HopCodeClassification] {
    let existing = Set(editablePath.map(\.hashBytes))
    let remaining = max(0, maxHopCount - editablePath.count)
    return HopCodeParser.classify(
      input: input,
      hashSize: hashSize,
      existingHashes: existing,
      remainingCapacity: remaining
    ) { hash in
      guard let publicKey = resolveHashToPublicKey(hash) else { return nil }
      return (publicKey, resolveHashToName(hash))
    }
  }

  /// Bulk-add resolvable codes, honoring the hop cap. Codes past the cap are
  /// classified `.pathFull` and skipped, so the path stops cleanly at `maxHopCount`.
  @discardableResult
  func addCodes(_ input: String) -> CodeInputResult {
    var result = CodeInputResult()
    for entry in classifyCodes(input) {
      switch entry.status {
      case let .willAdd(hop):
        editablePath.append(hop)
        if let publicKey = hop.publicKey { recordRecent(publicKey) }
        result.added.append(entry.code)
      case .alreadyInPath: result.alreadyInPath.append(entry.code)
      case .notFound: result.notFound.append(entry.code)
      case .invalidFormat: result.invalidFormat.append(entry.code)
      case .pathFull: break
      }
    }
    return result
  }
}
