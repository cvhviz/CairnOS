import CoreLocation
import Foundation
import CairnServices
import UIKit

// MARK: - Device Actions

extension AppState {
  /// ASK Remove Accessory leaves the scene unable to present `showPicker`.
  /// Retry once after a short delay in case `.active` already fired.
  private static let freshPairingForegroundRetryDelay: Duration = .milliseconds(400)

  /// Start device scan/pairing
  func startDeviceScan() {
    // Hide disconnected pill when starting new connection
    connectionUI.hideDisconnectedPill()
    // Clear any previous pairing failure state
    connectionUI.failedPairingDeviceID = nil
    connectionUI.isBusy = true
    connectionManager.isPairingFlowActive = true

    Task {
      defer {
        connectionUI.isBusy = false
        if connectionUI.pendingSystemPairingSetup == nil,
           connectionUI.queuedSystemPairingSetup == nil,
           !connectionUI.shouldCompleteFreshPairingOnForeground {
          connectionManager.isPairingFlowActive = false
        }
      }
      await withPairingFlowErrorHandling {
        let pending = try await connectionManager.systemAccessoriesMissingDeviceRecord()
        if !pending.isEmpty {
          if connectionUI.pendingSystemPairingSetup == nil {
            connectionUI.pendingSystemPairingSetup = SystemPairingSetupPrompt(
              accessories: pending.map { SystemPairedAccessory(id: $0.id, name: $0.name) }
            )
          }
          return
        }
        try await completeFreshPairing()
      }
    }
  }

  func handleDeviceSelectionSheetDismissed() {
    if connectionUI.queuedDeviceScanAfterSelectionDismiss {
      connectionUI.queuedDeviceScanAfterSelectionDismiss = false
      connectionUI.queuedSystemPairingSetup = nil
      connectionManager.isPairingFlowActive = true
      Task {
        await connectionManager.stopBLEScanning()
        startDeviceScan()
      }
      return
    }
    guard let queued = connectionUI.queuedSystemPairingSetup else { return }
    connectionUI.queuedSystemPairingSetup = nil
    guard connectionUI.pendingSystemPairingSetup == nil else { return }
    connectionManager.isPairingFlowActive = true
    connectionUI.pendingSystemPairingSetup = queued
  }

  func cancelSystemPairingSetup() {
    connectionUI.pendingSystemPairingSetup = nil
    connectionUI.queuedSystemPairingSetup = nil
    connectionUI.shouldCompleteFreshPairingOnForeground = false
    isFreshPairingForegroundRetry = false
    connectionManager.isPairingFlowActive = false
  }

  func handleSystemPairingSetupSheetDismissed() {
    guard !isConfirmingSystemPairingSetup else { return }
    guard connectionUI.pendingSystemPairingSetup == nil else { return }
    cancelSystemPairingSetup()
  }

  /// Forget the pending ASK accessories, then open the picker. Clears pending first so
  /// iOS Remove Accessory is the only dialog; siblings do not re-prompt.
  func confirmSystemPairingSetup() {
    guard let prompt = connectionUI.pendingSystemPairingSetup else { return }
    isConfirmingSystemPairingSetup = true
    connectionManager.isPairingFlowActive = true
    connectionUI.shouldShowPickerOnForeground = false
    connectionUI.pendingSystemPairingSetup = nil
    connectionUI.isBusy = true
    Task {
      defer {
        connectionUI.isBusy = false
        isConfirmingSystemPairingSetup = false
        if !connectionUI.shouldCompleteFreshPairingOnForeground {
          connectionManager.isPairingFlowActive = false
        }
      }
      await withPairingFlowErrorHandling {
        try await connectionManager.removeSystemAccessoriesMissingDeviceRecord(prompt.accessories.map(\.id))
        try await completeFreshPairing()
      }
    }
  }

  private func completeFreshPairing() async throws {
    if connectionState != .disconnected {
      await disconnect(reason: .switchingDevice)
    }
    try await connectionManager.pairNewDevice()
    await wireServicesIfConnected()
    if !onboarding.hasCompletedOnboarding {
      onboarding.onboardingPath.append(.region)
    }
  }

  private func withPairingFlowErrorHandling(_ work: () async throws -> Void) async {
    do {
      try await work()
    } catch DevicePairingError.cancelled {
      // Picker dismissed, or iOS Remove Accessory declined. Do not re-prompt.
      connectionUI.shouldCompleteFreshPairingOnForeground = false
      isFreshPairingForegroundRetry = false
    } catch DevicePairingError.alreadyInProgress {
    } catch DevicePairingError.pickerUnavailable {
      handlePickerUnavailableAfterForget()
    } catch let pairingError as PairingError {
      connectionUI.presentFreshPairingFailure(pairingError)
    } catch {
      connectionUI.presentConnectionFailure(message: error.userFacingMessage)
    }
  }

  /// ASK rejected the picker because Remove Accessory still owns the scene.
  /// Retry `pairNewDevice` on the next `.active` (and once after a short delay
  /// if that transition already happened). A second rejection is a real failure.
  private func handlePickerUnavailableAfterForget() {
    if isFreshPairingForegroundRetry {
      isFreshPairingForegroundRetry = false
      connectionUI.shouldCompleteFreshPairingOnForeground = false
      connectionManager.isPairingFlowActive = false
      connectionUI.presentConnectionFailure(
        message: L10n.Localizable.Error.AccessorySetup.pickerRestricted
      )
      return
    }
    scheduleFreshPairingOnForeground()
  }

  private func scheduleFreshPairingOnForeground() {
    connectionUI.shouldCompleteFreshPairingOnForeground = true
    connectionManager.isPairingFlowActive = true
    Task {
      try? await Task.sleep(for: Self.freshPairingForegroundRetryDelay)
      await resumeFreshPairingIfNeeded()
    }
  }

  private func resumeFreshPairingIfNeeded() async {
    guard connectionUI.shouldCompleteFreshPairingOnForeground else { return }
    connectionUI.shouldCompleteFreshPairingOnForeground = false
    isFreshPairingForegroundRetry = true
    connectionUI.isBusy = true
    connectionManager.isPairingFlowActive = true
    defer {
      connectionUI.isBusy = false
      isFreshPairingForegroundRetry = false
      if !connectionUI.shouldCompleteFreshPairingOnForeground {
        connectionManager.isPairingFlowActive = false
      }
    }
    await withPairingFlowErrorHandling {
      try await completeFreshPairing()
    }
  }

  /// Remove a device that failed pairing (wrong PIN) and automatically retry
  func removeFailedPairingAndRetry() {
    guard let deviceID = connectionUI.failedPairingDeviceID else { return }

    Task {
      await connectionManager.removeFailedPairing(deviceID: deviceID)
      connectionUI.failedPairingDeviceID = nil
      if connectionManager.hasSystemPairingRegistry {
        // Remove Accessory can bounce the scene; wait for `.active`.
        connectionUI.shouldShowPickerOnForeground = true
      } else {
        // No registry confirmation, so `.active` will not re-fire.
        startDeviceScan()
      }
    }
  }

  /// Retry connecting to the device that just failed without removing the bond.
  /// Used for transient pairing failures where the bond is still good — radio out of range,
  /// brief BLE flap, etc. Auth-failure paths route through `removeFailedPairingAndRetry`
  /// because the bond itself needs to be torn down before retrying.
  func retryFailedPairingConnect() async {
    guard let deviceID = connectionUI.failedPairingDeviceID else { return }
    connectionUI.isBusy = true
    defer { connectionUI.isBusy = false }

    do {
      try await connectionManager.connect(to: deviceID, forceReconnect: true)
      connectionUI.failedPairingDeviceID = nil
      await wireServicesIfConnected()
    } catch BLEError.deviceConnectedToOtherApp {
      connectionUI.failedPairingDeviceID = nil
      connectionUI.presentPairingFailure(.deviceConnectedToOtherApp(deviceID: deviceID))
    } catch {
      connectionUI.presentPairingFailure(.connectionFailed(deviceID: deviceID, underlying: error))
    }
  }

  /// Called by View when scenePhase becomes active.
  /// - Parameter presentsConnectionUI: Whether the activating scene hosts the pairing sheet and
  ///   device picker. Only the main window does; a conversation window leaves both pending for it,
  ///   since starting them there would mark the picker presented with nothing on screen to show it.
  func handleBecameActive(presentsConnectionUI: Bool = true) {
    logToolbarResumeProbe(source: "becameActive")
    // Clear the auth-failure latch so a still-invalid bond re-surfaces fresh
    // from the foreground reconnect instead of staying silenced from background.
    connectionManager.clearSurfacedAuthenticationFailure()

    if presentsConnectionUI, connectionUI.shouldCompleteFreshPairingOnForeground {
      Task { await resumeFreshPairingIfNeeded() }
      return
    }

    if presentsConnectionUI,
       connectionUI.shouldShowPickerOnForeground,
       connectionUI.pendingSystemPairingSetup == nil,
       connectionUI.queuedSystemPairingSetup == nil {
      connectionUI.shouldShowPickerOnForeground = false
      startDeviceScan()
    }

    activeRecoveryFallbackTask?.cancel()
    activeRecoveryFallbackTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      // Launch reconciles once itself, and its reconnect may still be running: a second
      // pass now would only race it.
      guard AppLaunchController.current?.hasLaunched != false else { return }
      guard !connectionManager.shouldDeferOpportunisticReconnect,
            connectionUI.pendingSystemPairingSetup == nil,
            connectionUI.queuedSystemPairingSetup == nil else { return }
      guard connectionState == .disconnected,
            connectionManager.lastConnectedDeviceID != nil else { return }

      logger.info("[BLE] Active fallback: disconnected after activation, running foreground reconciliation")
      await handleReturnToForeground()
    }
  }

  /// Disconnect from device
  /// - Parameter reason: The reason for disconnecting (for debugging)
  func disconnect(reason: DisconnectReason = .userInitiated) async {
    // The connection manager's `onDisconnected` callback runs the app-level
    // teardown (`handleDisconnected(reason:)`), so it isn't repeated here.
    await connectionManager.disconnect(reason: reason)
  }

  /// App-level teardown for every `ConnectionManager.disconnect(reason:)`, whether
  /// the app asked for it or the manager disconnected on its own. A disconnect does
  /// not fire onConnectionLost, so this runs the same per-session teardown the loss
  /// path performs in wireServicesIfConnected.
  func handleDisconnected(reason: DisconnectReason) async {
    switch reason {
    case .userInitiated, .statusMenuDisconnectTap, .switchingDevice, .factoryReset,
         .wifiAddressChange, .forgetDevice, .deviceRemovedFromSettings, .firmwareUpdate:
      // A deliberate disconnect ends the Live Activity and isn't announced as a loss.
      await liveActivityManager.endActivity()
      tearDownAppStateSessionState(announcesConnectionLoss: false)
    case .wifiReconnectPrep:
      // A reconnect follows immediately; show the gap without announcing a loss.
      tearDownAppStateSessionState(announcesConnectionLoss: false)
      await liveActivityManager.handleConnectionLost()
    case .resyncFailed, .pairingFailed:
      // The radio dropped out from under the user, so treat it like a link loss.
      tearDownAppStateSessionState(announcesConnectionLoss: true)
      await liveActivityManager.handleConnectionLost()
    }
    publishWidgetSnapshot()
  }

  /// Connect to a device via WiFi/TCP
  func connectViaWiFi(host: String, port: UInt16, forceFullSync: Bool = false) async throws {
    // Hide disconnected pill when starting new connection
    connectionUI.hideDisconnectedPill()
    // Every caller is a connect the user started (adding a radio, connecting a saved one, a new
    // address), so it waits while a radio that doesn't know this phone asks to allow it.
    try await connectionManager.connectViaWiFi(
      host: host,
      port: port,
      forceFullSync: forceFullSync,
      waitsForRadioApproval: true
    )
    await wireServicesIfConnected()
  }

  /// Connects to a saved radio, switching from the one connected if there is one: over `method`
  /// when given (a radio saved with both transports), else over WiFi when it has an address, else
  /// Bluetooth. The device picker and Connections both connect through here; a failure routes to
  /// the connection alerts (`presentSavedDeviceConnectFailure`).
  func connectToSavedDevice(_ device: DeviceDTO, via method: ConnectionMethod? = nil) async {
    let method = method ?? device.primaryConnectionMethod
    // A Bluetooth method names the peripheral to reach, which is the record's ID unless the radio
    // was last saved over WiFi (then the ID is derived from its key).
    let bluetoothID = method?.bluetoothPeripheralID ?? device.id
    do {
      if device.isDemoRadio {
        // No peripheral or address: the demo radio connects the way onboarding connects it, once
        // the radio linked now has let go.
        if connectedDevice != nil {
          await connectionManager.disconnect(reason: .switchingDevice)
        }
        try await connectionManager.simulatorConnect()
      } else if case let .wifi(host, port, _) = method {
        try await connectViaWiFi(host: host, port: port, forceFullSync: true)
      } else {
        try await connectionManager.connect(to: bluetoothID, forceFullSync: true, forceReconnect: true)
      }
    } catch is CancellationError {
      // Superseded by a newer connect, a switch, or a disconnect: not a failure to report.
    } catch {
      connectionUI.presentSavedDeviceConnectFailure(deviceID: bluetoothID, error: error)
    }
  }

  /// What connecting to `device` over `method` would do, judged by the radio's key against the one
  /// connected now (`SavedRadioConnectPlan`).
  func connectPlan(for device: DeviceDTO, via method: ConnectionMethod? = nil) -> SavedRadioConnectPlan {
    SavedRadioConnectPlan.plan(
      targetKey: device.publicKey,
      targetTransport: (method ?? device.primaryConnectionMethod)?.transportType ?? .bluetooth,
      connectedKey: connectedDevice?.publicKey,
      connectedTransport: connectionManager.currentTransportType
    )
  }

  // MARK: - Advertising

  /// Broadcast a self-advertisement from the connected radio, refreshing GPS
  /// location first when the device's policy and the user's per-device
  /// preference allow it. `allowLocationPrompt` is false from the App Intent: a
  /// background Siri context cannot present a location-permission dialog, so the
  /// refresh there uses only already-authorized location instead of stalling on
  /// a prompt that can never resolve.
  func refreshBLEPin() async {
    guard connectionState == .ready, let settings = services?.settingsService,
          let pin = try? await settings.readBlePin() else { return }
    connectionManager.updateBLEPin(pin)
  }

  func sendSelfAdvert(flood: Bool, allowLocationPrompt: Bool = true) async throws {
    if let source = advertGPSSource(device: connectedDevice, store: DevicePreferenceStore()) {
      await updateLocationFromGPS(source: source, allowLocationPrompt: allowLocationPrompt)
    }
    guard let advertisementService = services?.advertisementService else {
      throw AdvertisementError.notConnected
    }
    try await advertisementService.sendSelfAdvertisement(flood: flood)
    // The advert carried the radio's current position (its own GPS keeps it moving, or the phone
    // fix just written): read it back so every map shows what was sent, not the copy from connect.
    try? await services?.settingsService.refreshDeviceInfo()
  }

  /// Once a minute while the app is in the foreground and the radio is ready, re-read its self
  /// info so the maps follow its stored position (a radio with its own GPS updates it
  /// continuously; nothing pushes that to the app). One small read; stopped in the background.
  /// With the phone as the radio's position source, the phone's fix is written first when it
  /// has moved (`syncPhonePositionToRadio()`), whose verified write reads the radio back.
  func startRadioPositionRefresh() {
    radioPositionRefreshTask?.cancel()
    radioPositionRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard let self, !Task.isCancelled else { return }
        guard self.canRunSettingsStartupReads, self.connectedDevice != nil,
              UIApplication.shared.applicationState == .active else { continue }
        if self.advertGPSSource(device: self.connectedDevice, store: DevicePreferenceStore()) == .phone,
           await self.syncPhonePositionToRadio() {
          continue
        }
        try? await self.services?.settingsService.refreshDeviceInfo()
      }
    }
  }

  /// How far the phone has to move from the radio's stored position before it is written again.
  /// Each write saves the radio's preferences to flash, so a phone standing still writes nothing.
  static let phonePositionWriteDistance: CLLocationDistance = 100

  /// Writes the phone's fix to the radio when it is `phonePositionWriteDistance` or more from the
  /// position the radio holds (or the radio holds none), so the maps, and the radio's own timed
  /// adverts, follow the phone between adverts sent from here. Uses already-allowed location
  /// only, never prompting. The caller checks that the phone is the source
  /// (`advertGPSSource`). Returns whether it wrote.
  @discardableResult
  func syncPhonePositionToRadio() async -> Bool {
    guard locationService.isAuthorized,
          let settingsService = services?.settingsService,
          let location = try? await locationService.requestCurrentLocation(),
          let device = connectedDevice else { return false }
    if device.hasLocation {
      let stored = CLLocation(latitude: device.latitude, longitude: device.longitude)
      guard location.distance(from: stored) >= Self.phonePositionWriteDistance else { return false }
    }
    do {
      _ = try await settingsService.setLocationVerified(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude
      )
      return true
    } catch {
      logger.warning("Failed to write the phone's position to the radio: \(error.localizedDescription)")
      return false
    }
  }

  func stopRadioPositionRefresh() {
    radioPositionRefreshTask?.cancel()
    radioPositionRefreshTask = nil
  }

  /// The GPS source to refresh before an advert, or nil when the device's advert
  /// policy or the user's per-device preference disables auto-update. Pure over
  /// its inputs so the privacy gate is testable with an injected store.
  func advertGPSSource(device: DeviceDTO?, store: DevicePreferenceStore) -> GPSSource? {
    guard let device else { return nil }
    return GPSSource.advertRefresh(
      sharesLocationPublicly: device.sharesLocationPublicly,
      autoUpdate: store.isAutoUpdateLocationEnabled(deviceID: device.id),
      source: store.gpsSource(deviceID: device.id)
    )
  }

  private func updateLocationFromGPS(source: GPSSource, allowLocationPrompt: Bool) async {
    let settingsService = services?.settingsService
    do {
      switch source {
      case .phone:
        let location: CLLocation
        if allowLocationPrompt || locationService.isAuthorized {
          do {
            location = try await locationService.requestCurrentLocation()
          } catch {
            guard let cached = locationService.currentLocation else { throw error }
            location = cached
          }
        } else {
          guard let cached = locationService.currentLocation else { return }
          location = cached
        }
        _ = try await settingsService?.setLocationVerified(
          latitude: location.coordinate.latitude,
          longitude: location.coordinate.longitude
        )
      case .device:
        let gpsState = try await settingsService?.getDeviceGPSState()
        if gpsState?.isEnabled != true {
          _ = try await settingsService?.setDeviceGPSEnabledVerified(true)
        }
      }
    } catch {
      logger.warning("Failed to update location from GPS: \(error.localizedDescription)")
      // A failed write or read-back (the radio's own GPS overwrote the phone fix, say) leaves the
      // app's copy stale: re-read what the radio really holds.
      try? await settingsService?.refreshDeviceInfo()
    }
  }
}
