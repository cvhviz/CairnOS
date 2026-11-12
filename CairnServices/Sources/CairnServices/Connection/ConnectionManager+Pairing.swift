import Foundation
import MeshCore

// MARK: - Pairing

public extension ConnectionManager {
  /// Discovers a new device through the platform pairing service (AccessorySetupKit on
  /// iOS, an in-app CoreBluetooth scan picker on macOS), then connects through the shared
  /// `connect(to:)` ceremony. The connect path coordinates with in-flight auto-reconnects,
  /// switch-device handling, and the circuit breaker, which `connectAfterPairing`'s direct
  /// `performConnection` call used to bypass.
  ///
  /// **Cancellation behavior** (per `await`):
  /// - `pairing.discoverDevice()` — `withTaskCancellationHandler` resumes the
  ///   continuation with `CancellationError`. On iOS the system picker may stay visible
  ///   (no public ASK API to dismiss programmatically without invalidating the
  ///   session); if the user completes pairing in the orphaned picker,
  ///   `accessoryAdded` removes the bond immediately. The device is not registered
  ///   when this point is reached, so no cleanup needed here.
  /// - `waitForOtherAppReconnection` — checks `Task.isCancelled` at the top of
  ///   each iteration and short-circuits to `false`. A system-connected result
  ///   proceeds to `connect(to:)` rather than throwing other-app. Cancellation
  ///   is surfaced at `connect(to:)`'s entry-point `Task.checkCancellation()`.
  /// - `connect(to:)` — runs `Task.checkCancellation()` before any state mutation
  ///   so a cancelled task cannot drive a real BLE connect through to success.
  ///   Leftover GATT this app owns is adopted; while pairing, that path waits
  ///   until `isOperational` or throws. Propagates `CancellationError` normally;
  ///   we catch it explicitly and re-throw without re-wrapping so the UI alert
  ///   path stays quiet.
  ///
  /// Hard quit: process death; defer doesn't fire; the in-memory flag resets to
  /// `false` on next launch. No persistent state corruption.
  ///
  /// - Throws:
  ///   - `DevicePairingError.alreadyInProgress` on re-entry.
  ///   - `PairingError.deviceConnectedToOtherApp` when another app holds the radio.
  ///   - `PairingError.connectionFailed` for any other connection failure (auth,
  ///     timeout, transport error). The wrapped `underlying` is checked by
  ///     `PairingError.isAuthenticationFailure` so the auth alert path keeps working.
  ///   - `CancellationError` if the surrounding task is cancelled mid-flight.
  func pairNewDevice() async throws {
    logger.info("Starting device pairing")
    guard !isPairingInProgress else {
      throw DevicePairingError.alreadyInProgress
    }
    isPairingInProgress = true
    defer { isPairingInProgress = false }

    connectionIntent = .wantsConnection()
    persistIntent()

    await stopBLEScanning()

    // ASK's picker is empty until the session is active.
    try await pairing.activate()

    let deviceID = try await pairing.discoverDevice()

    // ASK has just associated this radio. A leftover system GATT link is ours
    // (or the accessory we just set up); `connect(to:)` adopts or connects.
    if await waitForOtherAppReconnection(deviceID) {
      logger.info(
        "[OtherAppCheck] System-connected after pairing \(deviceID.uuidString.prefix(8)); connecting"
      )
    }

    do {
      try await connect(to: deviceID, forceFullSync: true, forceReconnect: true)
    } catch BLEError.deviceConnectedToOtherApp {
      // No `cleanupPartialPairing` here — the bond is good; the user retries
      // after dismissing the other app via the otherAppWarningDeviceID alert.
      // Removing the bond would force a fresh pair instead.
      throw PairingError.deviceConnectedToOtherApp(deviceID: deviceID)
    } catch is CancellationError {
      await cleanupPartialPairing(deviceID: deviceID)
      throw CancellationError()
    } catch {
      // Edge case: a domain error bubbled up while the surrounding task was
      // also cancelled. Without this guard the user sees "Couldn't connect"
      // instead of silent cancellation. Re-throw as CancellationError so the
      // alert path doesn't fire.
      if Task.isCancelled {
        await cleanupPartialPairing(deviceID: deviceID)
        throw CancellationError()
      }
      logger.error("Connection after pairing failed: \(error.localizedDescription)")
      throw PairingError.connectionFailed(deviceID: deviceID, underlying: error)
    }
  }

  /// Removes a partially-paired device from the system registry when pairing is cancelled
  /// mid-flight before a usable connection exists. On iOS the system has the device; we don't.
  /// Without this cleanup, iOS retains a paired bond with no app-level state, surfacing as a
  /// phantom device in Settings → Bluetooth that won't show up in the picker again. No-op on macOS.
  private func cleanupPartialPairing(deviceID: UUID) async {
    logger.info("Removing partially-paired device \(deviceID.uuidString.prefix(8)) from pairing registry")
    try? await pairing.removeDevice(deviceID)
    reconnectionCoordinator.cancelTimeout()
    reconnectionCoordinator.clearReconnectingDevice()
    await transport.disconnect()
    // Defensive backstop — connectWithRetry and switchDevice both reset state
    // on throw, so this is normally a no-op. Kept so a future cancellation
    // path that lands here without doing so still leaves a clean UI.
    connectionState = .disconnected
  }

  /// Pairing leftover-GATT wait. `.syncing` already has a session
  /// (`promoteToReady(syncSucceeded: false)`); `.connected` is still rebuilding.
  func waitForPairingAdoptionToSettle() async throws {
    #if DEBUG
      if let strategy = pairingAdoptionSettleStrategyOverride {
        try await strategy()
        return
      }
    #endif

    let timeout: Duration
    #if DEBUG
      timeout = testPairingAdoptionSettleTimeout ?? Self.pairingAdoptionSettleTimeout
    #else
      timeout = Self.pairingAdoptionSettleTimeout
    #endif
    let deadline = ContinuousClock.now + timeout

    while true {
      try Task.checkCancellation()
      if connectionState.isOperational {
        guard services != nil else {
          throw BLEError.connectionFailed(Self.pairingAdoptionMissingSessionDetail)
        }
        return
      }
      if connectionState == .disconnected {
        throw BLEError.connectionFailed(Self.pairingAdoptionFailedDetail)
      }
      guard ContinuousClock.now < deadline else {
        throw BLEError.connectionFailed(Self.pairingAdoptionTimedOutDetail)
      }
      try await Task.sleep(for: Self.pairingAdoptionSettlePollInterval)
    }
  }

  /// ASK accessories with no `Device` row. Activates the pairing session first.
  /// Omits saved radios (by ID or by a saved Bluetooth method), the live connection, and the
  /// in-flight attempt; a fetch throw skips that id.
  func systemAccessoriesMissingDeviceRecord() async throws -> [(id: UUID, name: String)] {
    guard pairing.hasSystemPairingRegistry else { return [] }
    try await pairing.activate()
    var protectedIDs = Set<UUID>()
    if let connectedID = connectedDevice?.id { protectedIDs.insert(connectedID) }
    if let attemptID = activeConnectionAttemptDeviceID { protectedIDs.insert(attemptID) }
    // A radio reached over WiFi too is saved under its key-derived ID, with its Bluetooth
    // peripheral kept as a connection method: that peripheral has a record, it just isn't the ID.
    if let saved = try? await persistenceStore.fetchDevices() {
      protectedIDs.formUnion(saved.flatMap { $0.connectionMethods.compactMap(\.bluetoothPeripheralID) })
    }
    var result: [(id: UUID, name: String)] = []
    for info in pairing.registeredDeviceInfos() where !protectedIDs.contains(info.id) {
      let existing: DeviceDTO?
      do {
        existing = try await persistenceStore.fetchDevice(id: info.id)
      } catch {
        logger.warning(
          "Skipping association \(info.id.uuidString.prefix(8)); device lookup failed: \(error.localizedDescription)"
        )
        continue
      }
      if existing == nil { result.append(info) }
    }
    return result
  }

  /// Removes ASK accessories that still have no `Device` row, limited to `ids`.
  /// A declined iOS confirmation throws `DevicePairingError.cancelled` and aborts the loop.
  func removeSystemAccessoriesMissingDeviceRecord(_ ids: [UUID]) async throws {
    guard pairing.hasSystemPairingRegistry else { return }
    let allowed = try await Set(systemAccessoriesMissingDeviceRecord().map(\.id))
    for id in ids where allowed.contains(id) {
      try await pairing.removeDevice(id)
    }
  }

  /// Removes a device that failed to connect after pairing, for the guided
  /// "remove and retry" recovery. Demotes the row to a ghost rather than deleting
  /// it, preserving the publicKey ↔ radioID bridge: an established radio that lost
  /// its bond re-pairs onto the same radioID and its contacts, messages, and
  /// channels reattach. A fresh pairing has no row to demote, so this is a no-op there.
  /// - Parameter deviceID: The device ID from `PairingError.connectionFailed`
  func removeFailedPairing(deviceID: UUID) async {
    logger.info("Removing failed pairing for device: \(deviceID)")

    await transport.disconnect()

    do {
      try await pairing.removeDevice(deviceID)
    } catch {
      logger.warning("Failed to remove from pairing registry: \(error.localizedDescription)")
    }

    let dataStore = persistenceStore
    try? await dataStore.demoteDeviceToGhost(id: deviceID)

    // Always clear this device's bond verification; store keys are holder-matched.
    await clearPersistedConnection(for: deviceID)
  }

  // MARK: - Other-App Detection

  /// Polls for other-app reconnection after ASK pairing disrupts existing BLE connections.
  /// ASK pairing severs the other app's BLE link; it auto-reconnects seconds later via
  /// `CBConnectPeripheralOptionEnableAutoReconnect`. This method gives it time to reappear.
  /// - Parameter deviceID: The UUID of the newly paired device
  /// - Returns: `true` if the device was detected as connected to another app
  internal func waitForOtherAppReconnection(_ deviceID: UUID) async -> Bool {
    #if DEBUG
      if let strategy = otherAppWaitStrategyOverride {
        return await strategy(deviceID)
      }
    #endif
    return await defaultWaitForOtherAppReconnection(deviceID)
  }

  private func defaultWaitForOtherAppReconnection(_ deviceID: UUID) async -> Bool {
    let maxChecks = 6
    let interval: Duration = .milliseconds(400)

    for check in 1...maxChecks {
      // Short-circuit on cancellation so the caller's `connect(to:)` checkpoint
      // surfaces the CancellationError without grinding through every iteration.
      if Task.isCancelled {
        logger.info("[OtherAppCheck] Cancelled at check \(check)/\(maxChecks)")
        return false
      }

      let connected = await stateMachine.isDeviceConnectedToSystem(deviceID)
      if connected {
        logger.info("[OtherAppCheck] Detected other-app connection on check \(check)/\(maxChecks)")
        return true
      }

      if check < maxChecks {
        try? await Task.sleep(for: interval)
      }
    }

    logger.info("[OtherAppCheck] No other-app connection detected after \(maxChecks) checks")
    return false
  }

  // MARK: - Forget Device

  /// Forgets the device, removing it from paired accessories and local storage.
  /// - Parameter deleteData: If `true`, also deletes all associated data (contacts, messages, channels, trace paths).
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func forgetDevice(deleteData: Bool) async throws {
    guard let deviceID = connectedDevice?.id else {
      throw ConnectionError.notConnected
    }

    guard pairing.isDeviceConnectable(deviceID) else {
      throw ConnectionError.deviceNotFound
    }

    logger.info("Forgetting device: \(deviceID), deleteData: \(deleteData)")

    // As in deleteDevice: ASK's Remove Accessory can drop the BLE link while it waits,
    // and an opportunistic reconnect (foreground health check, watchdog, power-on) must
    // not race the forget back into a connection to the radio being removed.
    isPairingFlowActive = true
    defer { isPairingFlowActive = false }

    try await pairing.removeDevice(deviceID)
    await disconnect(reason: .forgetDevice)

    let dataStore = persistenceStore
    do {
      if deleteData {
        let radioID = try await dataStore.deleteDeviceAndData(id: deviceID)
        Self.deleteRadioAvatar(radioID: radioID)
      } else {
        try await dataStore.demoteDeviceToGhost(id: deviceID)
      }
    } catch {
      logger.warning("Failed to demote device in SwiftData: \(error.localizedDescription)")
    }

    await clearPersistedConnection(for: deviceID)
    logger.info("Device forgotten")
  }

  /// Forgets a device by ID, removing it from paired accessories and local storage.
  /// Deletes the device record and all associated data (factory reset path), or with
  /// `deleteData` false keeps the phone's copy of its conversations and nodes as a ghost record,
  /// as Forget Device's "keep data" does.
  /// Best-effort cleanup — does not throw.
  func forgetDevice(id: UUID, deleteData: Bool = true) async {
    logger.info("Forgetting device by ID: \(id), deleteData: \(deleteData)")

    await disconnect(reason: .factoryReset)

    do {
      try await pairing.removeDevice(id)
    } catch {
      logger.warning("Failed to remove device from pairing registry: \(error.localizedDescription)")
    }

    let dataStore = persistenceStore
    do {
      if deleteData {
        let radioID = try await dataStore.deleteDeviceAndData(id: id)
        Self.deleteRadioAvatar(radioID: radioID)
      } else {
        try await dataStore.demoteDeviceToGhost(id: id)
      }
    } catch {
      logger.warning("Failed to delete device data from SwiftData: \(error.localizedDescription)")
    }

    // Always clear this device's bond verification; store keys are holder-matched
    // so a non-last-connected forget still drops its in-memory/persistent shield.
    await clearPersistedConnection(for: id)

    logger.info("Device forgotten by ID: \(id)")
  }

  /// Removes the photo and colour picked for a radio whose data was deleted, so they don't
  /// linger on the phone or in later backups.
  private static func deleteRadioAvatar(radioID: UUID?) {
    guard let radioID else { return }
    RadioAvatarStorage.setColor(nil, radioID: radioID)
    try? RadioAvatarStorage.setPhoto(nil, radioID: radioID)
  }

  // MARK: - Node Management

  /// Returns the number of non-favorite contacts `removeUnfavoritedNodes` would remove for the
  /// current device: the same set, so the confirmation never promises more than the removal tries.
  func unfavoritedNodeCount() async throws -> Int {
    guard let device = connectedDevice else {
      throw ConnectionError.notConnected
    }

    let contacts = try await persistenceStore.fetchContacts(radioID: device.radioID)
    return AllNodesRemoval.targets(in: contacts.filter { !$0.isFavorite }, selfPublicKey: device.publicKey).count
  }

  /// Removes all non-favorite contacts from the device and app, along with their messages.
  /// - Parameter onProgress: Called once with `(0, total)` before the first radio command and
  ///   after each removal with the running count.
  /// - Returns: Count of removed vs total non-favorite contacts, and why it stopped early if it did
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func removeUnfavoritedNodes(
    onStart: (_ targets: Set<Data>) -> Void = { _ in },
    onProgress: (_ removed: Int, _ total: Int) -> Void = { _, _ in }
  ) async throws -> RemoveUnfavoritedResult {
    try await removeContacts(matching: { !$0.isFavorite }, onStart: onStart, onProgress: onProgress)
  }

  /// Removes non-favorite contacts whose recency timestamp is older than the given threshold.
  /// - Parameter days: Number of days. Contacts not heard from in this many days are removed.
  /// - Returns: Count of removed vs total stale contacts, and why it stopped early if it did
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func removeStaleNodes(olderThanDays days: Int) async throws -> RemoveUnfavoritedResult {
    let cutoff = UInt32(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
    return try await removeContacts(
      matching: { $0.matchesStaleNodePrune(cutoff: cutoff) },
      onRemove: { contact in
        let ageDays = (Int(Date().timeIntervalSince1970) - Int(contact.recencyTimestamp)) / 86400
        let keyPrefix = contact.publicKeyHex.prefix(8)
        self.logger.info("Auto-removed stale node '\(contact.name)' [\(keyPrefix)] (last heard \(ageDays)d ago)")
      }
    )
  }

  /// Shared implementation for removing contacts matching a predicate, through the same runner as
  /// Remove All Nodes (`AllNodesRemoval`): never the V-contact, a contact the radio no longer has
  /// is cleaned up locally, and any other failure stops the run and is returned with it.
  /// - Parameters:
  ///   - predicate: Filter applied to all contacts to determine which to remove.
  ///   - onProgress: Running count, as `removeUnfavoritedNodes` describes.
  ///   - onRemove: Optional callback invoked after each successful removal (for per-contact logging).
  /// - Returns: Count of removed vs total matching contacts
  private func removeContacts(
    matching predicate: (ContactDTO) -> Bool,
    onStart: (_ targets: Set<Data>) -> Void = { _ in },
    onProgress: (_ removed: Int, _ total: Int) -> Void = { _, _ in },
    onRemove: ((_ contact: ContactDTO) -> Void)? = nil
  ) async throws -> RemoveUnfavoritedResult {
    guard let device = connectedDevice, let services else {
      throw ConnectionError.notConnected
    }

    let radioID = device.radioID
    let contactService = services.contactService
    let allContacts = try await persistenceStore.fetchContacts(radioID: radioID)

    return try await AllNodesRemoval.remove(
      AllNodesRemoval.targets(in: allContacts.filter(predicate), selfPublicKey: device.publicKey),
      removeFromRadio: { contact in
        try await contactService.removeContact(radioID: radioID, publicKey: contact.publicKey)
      },
      removeLocally: { contact in
        try await contactService.removeLocalContact(contactID: contact.id, publicKey: contact.publicKey)
      },
      onStart: onStart,
      onProgress: onProgress,
      onRemoved: onRemove,
      logger: logger
    )
  }

  // MARK: - Stale Pairings

  /// Clears all stale pairings from the system registry (AccessorySetupKit on iOS).
  /// Use when a device has been factory-reset but iOS still has the old pairing. No-op on macOS.
  func clearStalePairings() async {
    logger.info("Clearing stale pairings")
    await pairing.clearStaleRegistrations()
    logger.info("Stale pairings cleared")
  }

  // MARK: - Device Updates

  /// Updates the connected device with new settings from SelfInfo.
  /// Called by SettingsService after device settings are successfully changed.
  /// Also persists to SwiftData so changes appear in Connect Device sheet.
  func updateDevice(from selfInfo: MeshCore.SelfInfo, appliedRadioPresetID: String?) {
    guard let device = connectedDevice else { return }
    var updated = device.updating(from: selfInfo)
    if let appliedRadioPresetID {
      updated.appliedRadioPresetID = appliedRadioPresetID
    } else if !device.clientRepeat {
      // Drop a stale catalog id only when live RF no longer matches it. Repeat Mode
      // keeps the id so restore can still paint the community name.
      let matches = RadioPresets.matchingPresets(
        frequencyKHz: updated.frequency,
        bandwidthKHz: updated.bandwidth,
        spreadingFactor: updated.spreadingFactor,
        codingRate: updated.codingRate
      )
      if let current = updated.appliedRadioPresetID,
         !matches.contains(where: { $0.id == current }) {
        updated.appliedRadioPresetID = nil
      }
    }
    connectedDevice = updated
    Task {
      try? await services?.dataStore.saveDevice(updated)
    }
  }

  /// Updates the connected device with a new DeviceDTO.
  /// Called by DeviceService after local device settings are successfully changed.
  func updateDevice(with deviceDTO: DeviceDTO) {
    connectedDevice = deviceDTO
  }

  /// Updates the connected device's Bluetooth PIN, once the radio has it.
  func updateBLEPin(_ pin: UInt32) {
    guard let device = connectedDevice, device.blePin != pin else { return }
    let updated = device.copy { $0.blePin = pin }
    logger.info("BLE PIN now \(updated.blePinKindForLog) (was \(device.blePinKindForLog))")
    connectedDevice = updated
    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist BLE PIN: \(error)") }
    }
  }

  /// Updates the connected device's auto-add config.
  /// Called by SettingsService after auto-add config is successfully changed.
  func updateAutoAddConfig(_ config: MeshCore.AutoAddConfig) {
    guard let device = connectedDevice else { return }
    let updated = device.copy {
      $0.autoAddConfig = config.bitmask
      $0.autoAddMaxHops = config.maxHops
    }
    connectedDevice = updated

    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist auto-add config: \(error)") }
    }
  }

  /// Updates the connected device's client repeat state.
  /// Called by SettingsService after client repeat is successfully changed.
  func updateClientRepeat(_ enabled: Bool) {
    guard let device = connectedDevice else { return }
    let updated = device.copy { $0.clientRepeat = enabled }
    connectedDevice = updated

    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist client repeat state: \(error)") }
    }
  }

  /// Updates the connected device's path hash mode.
  /// Called by SettingsService after path hash mode is successfully changed.
  func updatePathHashMode(_ mode: UInt8) {
    guard let device = connectedDevice else { return }
    let updated = device.copy { $0.pathHashMode = mode }
    connectedDevice = updated

    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist path hash mode: \(error)") }
    }
  }

  /// Updates the connected device's cached default flood scope name.
  /// Called by SettingsService after a `getDefaultFloodScope` read or a successful write.
  func updateDefaultFloodScopeName(_ name: String?) {
    guard let device = connectedDevice else { return }
    let updated = device.copy { $0.defaultFloodScopeName = name }
    connectedDevice = updated

    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist default flood scope: \(error)") }
    }
  }

  /// Appends a region to the connected device's known-regions list and persists.
  /// No-ops if the region is already present.
  /// - Throws: `ConnectionError.notConnected` with no radio connected, or the store's error when
  ///   the region couldn't be saved. The list then drops it again, so it never shows a region
  ///   that would be gone after a relaunch.
  func addKnownRegion(_ region: String) async throws {
    guard let device = connectedDevice, let services else { throw ConnectionError.notConnected }
    guard !device.knownRegions.contains(region) else { return }
    let updated = device.copy { $0.knownRegions.append(region) }
    connectedDevice = updated

    do {
      try await services.dataStore.addDeviceKnownRegion(radioID: updated.radioID, region: region)
    } catch {
      logger.error("Failed to add known region: \(error)")
      // Taken from the list as it is now: other edits may have landed while the save ran.
      if let current = connectedDevice, current.radioID == updated.radioID {
        connectedDevice = current.copy { $0.knownRegions.removeAll { $0 == region } }
      }
      throw error
    }

    await services.rxLogService.updateKnownRegions(connectedDevice?.knownRegions ?? updated.knownRegions)
  }

  /// Removes a region from the connected device's known-regions list and persists.
  /// If the removed region is the device's current default flood scope, also clears
  /// the scope on the radio so firmware state doesn't dangle on a deleted name.
  func removeKnownRegion(_ region: String) {
    guard let device = connectedDevice else { return }
    let wasDefaultFloodScope = device.defaultFloodScopeName == region
    let updated = device.copy {
      $0.knownRegions.removeAll { $0 == region }
      if wasDefaultFloodScope {
        $0.defaultFloodScopeName = nil
      }
    }
    connectedDevice = updated
    Task {
      do {
        try await services?.dataStore.removeDeviceKnownRegion(radioID: updated.radioID, region: region)
      } catch {
        logger.error("Failed to remove known region: \(error)")
      }

      if wasDefaultFloodScope, let settingsService = services?.settingsService {
        do {
          _ = try await settingsService.setDefaultFloodScopeVerified(name: nil)
        } catch {
          logger.error("Failed to clear default flood scope after region removal: \(error)")
        }
      }

      await services?.rxLogService.updateKnownRegions(updated.knownRegions)
    }
  }

  /// Saves the connected device's current radio settings as pre-repeat settings.
  /// Called before enabling repeat mode so settings can be restored later.
  func savePreRepeatSettings() {
    guard let device = connectedDevice else { return }
    let updated = device.savingPreRepeatSettings()
    connectedDevice = updated

    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist pre-repeat settings: \(error)") }
    }
  }

  /// Clears the connected device's pre-repeat settings after restoration.
  func clearPreRepeatSettings() {
    guard let device = connectedDevice else { return }
    let updated = device.clearingPreRepeatSettings()
    connectedDevice = updated

    Task {
      do { try await services?.dataStore.saveDevice(updated) } catch { logger.error("Failed to persist cleared pre-repeat settings: \(error)") }
    }
  }

  // MARK: - Accessory Management

  /// Checks if a device is registered with the system pairing registry.
  /// - Parameter deviceID: The Bluetooth UUID of the device
  /// - Returns: `true` if the device is available for connection (always `true` on macOS).
  func hasAccessory(for deviceID: UUID) -> Bool {
    pairing.isDeviceConnectable(deviceID)
  }

  /// Fetches all previously paired devices from storage.
  /// Available even when disconnected, for device selection UI.
  func fetchSavedDevices() async throws -> [DeviceDTO] {
    logger.info("fetchSavedDevices called, connectionState: \(String(describing: connectionState))")
    let dataStore = persistenceStore
    let devices = try await dataStore.fetchDevices()
    logger.info("fetchSavedDevices returning \(devices.count) devices")
    return devices
  }

  /// Forgets the system pairing registry entry (no-op if unregistered), then demotes the row to a ghost.
  /// Declining iOS Remove Accessory throws `DevicePairingError.cancelled` and leaves the row listed.
  /// - Parameter id: The device UUID to forget
  func deleteDevice(id: UUID) async throws {
    logger.info("deleteDevice called for device: \(id)")

    // Snapshot before removeDevice: ASK can drop BLE, then handleConnectionLoss
    // nils connectedDevice while wantsConnection stays.
    let shouldTearDownSession =
      connectedDevice?.id == id || activeConnectionAttemptDeviceID == id
    if shouldTearDownSession {
      isPairingFlowActive = true
    }
    defer {
      if shouldTearDownSession {
        isPairingFlowActive = false
      }
    }

    try await pairing.removeDevice(id)
    if shouldTearDownSession {
      await disconnect(reason: .forgetDevice)
    }

    let dataStore = persistenceStore
    try await dataStore.demoteDeviceToGhost(id: id)

    // Always clear this device's bond verification; store keys are holder-matched
    // so a non-last-connected delete still drops its shield.
    await clearPersistedConnection(for: id)

    logger.info("deleteDevice completed for device: \(id)")
  }

  /// Returns devices registered with the system pairing registry (AccessorySetupKit on iOS).
  /// Use as fallback when SwiftData has no device records. Empty on macOS.
  var pairedAccessoryInfos: [(id: UUID, name: String)] {
    pairing.registeredDeviceInfos()
  }

  /// Renames the currently connected device via the system rename UI (AccessorySetupKit on iOS).
  /// No-op on macOS, where there is no system rename surface.
  /// - Throws: `ConnectionError.notConnected` if no device is connected
  func renameCurrentDevice() async throws {
    guard let deviceID = connectedDevice?.id else {
      throw ConnectionError.notConnected
    }

    guard pairing.isDeviceConnectable(deviceID) else {
      throw ConnectionError.deviceNotFound
    }

    try await pairing.renameDevice(deviceID)
  }
}

// MARK: - DevicePairingDelegate

extension ConnectionManager: DevicePairingDelegate {
  public func devicePairing(
    _ service: any DevicePairingService,
    didRemoveDeviceWithID bluetoothID: UUID
  ) {
    logger.info("Device removed from pairing registry: \(bluetoothID)")

    // DevicePairingDelegate is non-async, so bond clear cannot be awaited at the
    // callback signature. Ordered first in the Task so it runs before reconnect-
    // adjacent work; residual race with concurrent classify is accepted here.
    Task {
      await clearPersistedConnection(for: bluetoothID)

      if connectedDevice?.id == bluetoothID {
        await disconnect(reason: .deviceRemovedFromSettings)
      }

      // iOS can fire accessoryRemoved while session.accessories still lists the
      // id. Ghosting then turns a still-authorized radio into a Set Up leftover
      // that blocks Scan. Keep the Device row so Connect still works.
      if pairing.isDeviceConnectable(bluetoothID) {
        logger.info(
          "ASK still lists \(bluetoothID.uuidString.prefix(8)) after removal; keeping Device row"
        )
        return
      }

      let dataStore = persistenceStore
      do {
        try await dataStore.demoteDeviceToGhost(id: bluetoothID)
      } catch {
        logger.warning("Failed to demote device in SwiftData: \(error.localizedDescription)")
      }
    }
  }

  public func devicePairing(
    _ service: any DevicePairingService,
    didFailPairingForDeviceWithID bluetoothID: UUID
  ) {
    // Clean up device record so the device can appear in picker again.
    // No data cascade — failed pairings have no associated data.
    logger.info("Pairing failed for device: \(bluetoothID)")

    // DevicePairingDelegate is non-async; bond clear is ordered first in the Task.
    Task {
      await clearPersistedConnection(for: bluetoothID)

      if connectedDevice?.id == bluetoothID {
        await disconnect(reason: .pairingFailed)
      }

      // Delete device record only — no data exists for a failed pairing
      let dataStore = persistenceStore
      do {
        try await dataStore.deleteDevice(id: bluetoothID)
        logger.info("Deleted device record after failed pairing")
      } catch {
        logger.info("No device record to delete: \(error.localizedDescription)")
      }
    }
  }
}
