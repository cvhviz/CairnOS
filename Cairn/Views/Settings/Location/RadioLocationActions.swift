import CairnServices
import SwiftUI

/// The radio-position changes that Location & Sharing and the GPS tab both make, kept in one place
/// so the two pages can't drift apart: which advert policy "share" means for the current setup,
/// writing that policy, what has to follow when the radio's GPS receiver goes off, and making the
/// phone the radio's position source.
///
/// Each call does the radio writes and the per-device preference writes; the page around it owns
/// its own saving state, alerts and retries.
@MainActor
struct RadioLocationActions {
  let appState: AppState
  var store = DevicePreferenceStore()

  /// The advert policy that "share my location" means for the current setup: the live GPS
  /// position while the radio's own receiver keeps the position current, otherwise the saved one.
  nonisolated static func advertPolicy(
    share: Bool,
    autoUpdate: Bool,
    deviceHasGPS: Bool,
    gpsSource: GPSSource
  ) -> AdvertLocationPolicy {
    guard share else { return .none }
    if autoUpdate, deviceHasGPS, gpsSource == .device {
      return .share
    }
    return .prefs
  }

  /// Writes the advert location policy, verified, unless the radio already holds it.
  func applyAdvertPolicy(_ policy: AdvertLocationPolicy) async throws {
    guard let device = appState.connectedDevice,
          let settingsService = appState.services?.settingsService else {
      throw SettingsServiceError.notConnected
    }
    guard device.advertLocationPolicyMode != policy else { return }
    _ = try await settingsService.setOtherParamsVerified(from: device, advertLocationPolicy: policy)
  }

  /// What has to follow the receiver going off: if auto-update was taking the position from it,
  /// auto-update stops, and an advert carrying the live GPS position moves to the saved one so
  /// it doesn't keep a stale fix. Returns whether auto-update was turned off.
  @discardableResult
  func settleAfterReceiverOff() async throws -> Bool {
    guard let device = appState.connectedDevice,
          store.isAutoUpdateLocationEnabled(deviceID: device.id),
          store.gpsSource(deviceID: device.id) == .device else { return false }
    store.setAutoUpdateLocationEnabled(false, deviceID: device.id)
    if device.advertLocationPolicyMode == .share {
      try await applyAdvertPolicy(.prefs)
    }
    return true
  }

  /// Makes the phone the radio's position source (Location & Sharing's Auto-Update with Phone GPS),
  /// or stops it. Turning it on also turns the radio's receiver off, as choosing Phone GPS there
  /// does, so the two don't overwrite each other; a public advert then carries the saved position
  /// the phone keeps current. Returns the receiver's state when it was changed.
  ///
  /// The caller checks location permission first: with location denied this would only save a
  /// preference the advert can't act on.
  func usePhoneLocation(_ enabled: Bool, receiverEnabled: Bool) async throws -> DeviceGPSState? {
    guard let device = appState.connectedDevice,
          let settingsService = appState.services?.settingsService else {
      throw SettingsServiceError.notConnected
    }
    var receiver: DeviceGPSState?
    if enabled {
      store.setGPSSource(.phone, deviceID: device.id)
      store.setAutoUpdateLocationEnabled(true, deviceID: device.id)
      appState.locationService.requestPermissionIfNeeded()
      if receiverEnabled {
        receiver = try await settingsService.setDeviceGPSEnabledVerified(false)
      }
    } else {
      store.setAutoUpdateLocationEnabled(false, deviceID: device.id)
    }
    if let current = appState.connectedDevice, current.sharesLocationPublicly {
      try await applyAdvertPolicy(Self.advertPolicy(
        share: true,
        autoUpdate: enabled,
        deviceHasGPS: receiver?.isSupported ?? receiverEnabled,
        gpsSource: .phone
      ))
    }
    // Put the radio where the phone is now, rather than waiting for the next advert or the
    // minute's position refresh.
    if enabled, appState.advertGPSSource(device: appState.connectedDevice, store: store) == .phone {
      await appState.syncPhonePositionToRadio()
    }
    return receiver
  }
}
