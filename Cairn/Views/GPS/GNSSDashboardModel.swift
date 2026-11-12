import CoreLocation
import CairnServices
import MeshCore
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "GPS")

/// The GPS tab's radio side: what the radio last said about its GPS, the position preferences
/// stored for it, and the changes its card makes. The writes go through `RadioLocationActions`,
/// the same calls Location & Sharing makes, so the two pages agree.
@Observable
@MainActor
final class GNSSDashboardModel {
  /// What the radio last said about its GPS.
  private(set) var radio = RadioGPSReading()
  /// The radio's own sensor readings from the same telemetry read (temperature, and on Cairn
  /// firmware its heading, motion, tilt and steps), for the top card under the altitude.
  private(set) var sensors: [LPPDataPoint] = []
  /// The device `radio` was read from, so another radio never shows its reading.
  private var radioDeviceID: UUID?
  /// Auto-update and its source, from the per-device preferences.
  private(set) var autoUpdate = false
  private(set) var gpsSource: GPSSource = .phone
  private(set) var isSaving = false
  var errorMessage: String?
  /// Set when "Use for Radio Position" is turned on with location refused.
  var showLocationDeniedAlert = false

  private var isReading = false
  private let store = DevicePreferenceStore()

  /// The phone is the radio's position source.
  var usesPhoneLocation: Bool { autoUpdate && gpsSource == .phone }

  /// What keeps the radio's position current. The receiver being on is the radio GPS source
  /// whatever the stored preference says: the radio copies its own fix into its position.
  enum PositionUpdates: Hashable {
    case off
    case phone
    case radioGPS
  }

  var positionUpdates: PositionUpdates {
    if radio.receiver?.isEnabled == true { return .radioGPS }
    return usesPhoneLocation ? .phone : .off
  }

  /// Re-reads the per-device preferences, which Location & Sharing or the manual picker may have
  /// changed since.
  func loadPreferences(for device: DeviceDTO?) {
    if device?.id != radioDeviceID {
      radioDeviceID = nil
      if radio != RadioGPSReading() { radio = RadioGPSReading() }
    }
    guard let device else {
      autoUpdate = false
      gpsSource = .phone
      return
    }
    autoUpdate = store.isAutoUpdateLocationEnabled(deviceID: device.id)
    gpsSource = store.gpsSource(deviceID: device.id)
  }

  // MARK: - Reads

  /// One round of radio reads: the receiver's state, the self telemetry (its sensors, and while the
  /// receiver is on its GPS point), and while it is on the self info (the position moves with the fix).
  /// All of it asks the connected radio over its own link: nothing goes out over the mesh.
  func refresh(appState: AppState, isActive: Bool) async {
    loadPreferences(for: appState.connectedDevice)
    guard let deviceID = appState.connectedDevice?.id else {
      radio = RadioGPSReading()
      sensors = []
      return
    }
    guard isActive,
          appState.canRunSettingsStartupReads,
          !isReading,
          let services = appState.services else { return }
    isReading = true
    defer { isReading = false }

    let receiver: DeviceGPSState
    do {
      receiver = try await services.settingsService.getDeviceGPSState()
    } catch {
      if !(error is CancellationError) {
        logger.warning("Radio GPS state read failed: \(error.localizedDescription)")
      }
      return
    }
    var telemetry: RadioGPSReading.TelemetryPosition?
    var points: [LPPDataPoint]?
    if deviceID == MockDataProvider.simulatorDeviceID {
      points = LPPDecoder.decode(MockDataProvider.selfTelemetryFrame)
    } else if let response = try? await services.binaryProtocolService.getSelfTelemetry() {
      points = LPPDecoder.decode(response.rawData)
    }
    if receiver.isEnabled {
      telemetry = points.flatMap { RadioGPSReading.telemetryPosition(in: $0) }
      try? await services.settingsService.refreshDeviceInfo()
    }
    guard !Task.isCancelled, appState.connectedDevice?.id == deviceID else { return }
    if let points { sensors = points }   // a missed read keeps the last readings on screen
    // the Trips page's step chart: the radio's step count
    if let device = appState.connectedDevice, let points {
      appState.tripRecorder.noteSensors(points, radioID: device.radioID, cairnFirmware: device.isCairnFirmware)
    }
    radio = RadioGPSReading(receiver: receiver, telemetry: telemetry, readAt: .now)
    radioDeviceID = deviceID
  }

  // MARK: - Radio controls

  /// Chooses what keeps the radio's position current. Phone and radio GPS exclude each other (the
  /// phone source turns the receiver off, as `RadioLocationActions.usePhoneLocation` does), and
  /// Off stops both. The advert's location setting is left alone, except that a Live advert
  /// moves to Saved once the receiver goes off (`settleAfterReceiverOff`).
  func setPositionUpdates(_ updates: PositionUpdates, appState: AppState) {
    guard updates != positionUpdates,
          let device = appState.connectedDevice,
          let settingsService = appState.services?.settingsService else { return }
    switch updates {
    case .phone:
      setUsesPhoneLocation(true, appState: appState)
    case .radioGPS:
      perform(appState: appState) {
        self.store.setGPSSource(.device, deviceID: device.id)
        self.store.setAutoUpdateLocationEnabled(true, deviceID: device.id)
        self.radio.receiver = try await settingsService.setDeviceGPSEnabledVerified(true)
      }
    case .off:
      if radio.receiver?.isEnabled == true {
        perform(appState: appState) {
          self.radio.receiver = try await settingsService.setDeviceGPSEnabledVerified(false)
          try await RadioLocationActions(appState: appState).settleAfterReceiverOff()
          self.store.setAutoUpdateLocationEnabled(false, deviceID: device.id)
        }
      } else {
        setUsesPhoneLocation(false, appState: appState)
      }
    }
  }

  /// Switches the receiver between Eco and always-on, on firmware that offers Eco.
  func setEco(_ eco: Bool, appState: AppState) {
    guard let settingsService = appState.services?.settingsService else { return }
    perform(appState: appState) {
      self.radio.receiver = try await settingsService.setDeviceGPSEcoVerified(eco)
    }
  }

  /// Which position the radio's adverts carry: none, the saved one, or the receiver's live fix.
  func setAdvertPolicy(_ policy: AdvertLocationPolicy, appState: AppState) {
    perform(appState: appState, reload: false) {
      try await RadioLocationActions(appState: appState).applyAdvertPolicy(policy)
    }
  }

  /// Makes the phone the radio's position source, or stops it, as Location & Sharing's
  /// Auto-Update with Phone GPS does.
  func setUsesPhoneLocation(_ enabled: Bool, appState: AppState) {
    if enabled, appState.locationService.isLocationDenied {
      showLocationDeniedAlert = true
      return
    }
    let receiverEnabled = radio.receiver?.isEnabled ?? false
    perform(appState: appState) {
      if let state = try await RadioLocationActions(appState: appState)
        .usePhoneLocation(enabled, receiverEnabled: receiverEnabled) {
        self.radio.receiver = state
      }
    }
  }

  /// Runs one change with the saving state held, reports a failure, then re-reads the
  /// preferences and, when the change touched the receiver, the radio.
  private func perform(
    appState: AppState,
    reload: Bool = true,
    _ change: @escaping @MainActor () async throws -> Void
  ) {
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        try await change()
      } catch {
        logger.error("GPS change failed: \(error.localizedDescription)")
        errorMessage = error.userFacingMessage
      }
      loadPreferences(for: appState.connectedDevice)
      if reload {
        await refresh(appState: appState, isActive: true)
      }
    }
  }
}
