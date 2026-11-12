import Foundation
import UIKit
import CairnServices
import MeshCore
import OSLog

/// Manages device battery polling, threshold checks, and low-battery notifications.
@Observable
@MainActor
final class BatteryMonitor {
  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "BatteryMonitor")

  /// Current device battery info (nil if not fetched or disconnected)
  var deviceBattery: BatteryInfo?

  /// Task for initial battery fetch on connect (cancelled on disconnect)
  private(set) var bootstrapTask: Task<Void, Never>?

  /// Task for periodic battery refresh (cancelled on disconnect/background)
  private(set) var batteryRefreshTask: Task<Void, Never>?

  /// Thresholds that have already triggered a notification this session
  private var notifiedBatteryThresholds: Set<Int> = []

  /// Tracks last successful battery fetch for background piggybacking, and dates the reading
  /// on Settings → Battery
  private(set) var lastSuccessfulFetchDate: Date?

  /// Radio the current reading belongs to, so a switch drops the previous radio's reading
  private var readingDeviceID: UUID?

  /// Battery warning threshold levels (percentage)
  private let batteryWarningThresholds = [20, 10, 5]

  /// Called when battery info is updated, for Live Activity
  var onBatteryChanged: ((_ battery: BatteryInfo) -> Void)?

  /// Readings saved to the radio's battery history this session, so Settings › Battery redraws
  /// its charts when one lands.
  private(set) var historyRecordCount = 0

  /// The active OCV array for the connected device
  func activeBatteryOCVArray(for device: DeviceDTO?) -> [Int] {
    device?.activeOCVArray ?? OCVPreset.liIon.ocvArray
  }

  // MARK: - Public API

  /// Fetch device battery level on demand.
  ///
  /// A failed read (cancelled, timed out, or refused) keeps the last good reading: the
  /// radio is still connected, and the session's end is what drops it (`clearThresholds()`).
  func fetchDeviceBattery(services: ServiceContainer?, device: DeviceDTO?) async {
    guard let settingsService = services?.settingsService else { return }

    do {
      deviceBattery = try await settingsService.getBattery()
      lastSuccessfulFetchDate = .now
      if let battery = deviceBattery {
        onBatteryChanged?(battery)
        await recordHistory(battery, services: services, device: device)
      }
      await checkBatteryThresholds(device: device, services: services)
    } catch is CancellationError {
      return
    } catch {
      logger.debug("Battery fetch failed, keeping last reading: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static let backgroundBatteryInterval: TimeInterval = 900

  /// Fetch battery only if enough time has passed since last successful fetch.
  /// Called from packet reception handler to piggyback on active BLE wake-ups.
  func fetchBatteryIfOverdue(services: ServiceContainer?, device: DeviceDTO?) async {
    if let last = lastSuccessfulFetchDate,
       Date.now.timeIntervalSince(last) < Self.backgroundBatteryInterval { return }
    await fetchDeviceBattery(services: services, device: device)
  }

  /// Start battery monitoring for a newly connected device.
  /// Defers bootstrap so connection setup is not blocked by device request timeouts.
  ///
  /// - Parameter currentDevice: Returns the connected device as it is now. It is read on
  ///   every poll, so an OCV preset saved mid-session sets the next percentage and alerts.
  func start(services: ServiceContainer, currentDevice: @escaping @MainActor @Sendable () -> DeviceDTO?) {
    // Services are wired more than once per connection; a bootstrap or refresh
    // loop left running from the previous call would poll and alert in parallel.
    stop()
    let device = currentDevice()
    if device?.id != readingDeviceID {
      deviceBattery = nil
      readingDeviceID = device?.id
    }

    bootstrapTask = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        deviceBattery = try await services.settingsService.getBattery()
        lastSuccessfulFetchDate = .now
        if let battery = deviceBattery {
          onBatteryChanged?(battery)
          await recordHistory(battery, services: services, device: currentDevice())
        }
      } catch {
        // Keep any reading already held for this radio; a switch of radio cleared it above.
        guard !Task.isCancelled else { return }
        logger.debug("Deferred battery bootstrap failed: \(error.localizedDescription, privacy: .public)")
      }

      guard !Task.isCancelled else { return }

      await initializeBatteryThresholds(device: currentDevice(), services: services)
      startRefreshLoop(services: services, currentDevice: currentDevice)
    }
  }

  /// Saves a reading to the radio's own history, under its key, as a repeater's status is: the
  /// snapshot store keeps one a quarter hour (a later reading in the window updates it), so the
  /// two-minute poll doesn't fill it. Settings › Battery charts it. A board without a battery
  /// (0 mV) saves nothing.
  private func recordHistory(_ battery: BatteryInfo, services: ServiceContainer?, device: DeviceDTO?) async {
    guard battery.isBatteryPresent, battery.level > 0, let services, let device else { return }
    let metrics = NodeStatusMetrics(
      batteryMillivolts: UInt16(clamping: battery.level),
      lastSNR: nil, lastRSSI: nil, noiseFloor: nil, uptimeSeconds: nil, rxAirtimeSeconds: nil,
      packetsSent: nil, packetsReceived: nil, receiveErrors: nil,
      sentDirect: nil, sentFlood: nil, receivedDirect: nil, receivedFlood: nil,
      directDuplicates: nil, floodDuplicates: nil
    )
    guard await services.nodeSnapshotService.recordSnapshot(nodePublicKey: device.publicKey, status: metrics) != nil else { return }
    historyRecordCount += 1
  }

  /// Stop battery monitoring (disconnect or background)
  func stop() {
    bootstrapTask?.cancel()
    bootstrapTask = nil
    batteryRefreshTask?.cancel()
    batteryRefreshTask = nil
  }

  /// Clear notification thresholds for a fresh connection. Called only when the
  /// session ends (unlike `stop()`, which also runs on background and re-wire), so
  /// the last reading is dropped here too rather than surviving as a stale value.
  func clearThresholds() {
    notifiedBatteryThresholds = []
    deviceBattery = nil
    readingDeviceID = nil
  }

  /// Check for battery thresholds crossed while app was backgrounded.
  /// Posts a single notification if any thresholds were missed.
  func checkMissedBatteryThreshold(device: DeviceDTO?, services: ServiceContainer?) async {
    guard let device,
          let settingsService = services?.settingsService,
          let notificationService = services?.notificationService else { return }

    do {
      deviceBattery = try await settingsService.getBattery()
      if let battery = deviceBattery {
        onBatteryChanged?(battery)
      }
    } catch {
      return
    }

    guard let battery = deviceBattery else { return }
    guard battery.isBatteryPresent else { return }
    let percentage = battery.percentage(using: device.activeOCVArray)

    let missedThresholds = batteryWarningThresholds.filter { threshold in
      percentage <= threshold && !notifiedBatteryThresholds.contains(threshold)
    }

    guard !missedThresholds.isEmpty else { return }

    for threshold in missedThresholds {
      notifiedBatteryThresholds.insert(threshold)
    }

    await notificationService.postLowBatteryNotification(
      deviceName: device.nodeName,
      batteryPercentage: percentage
    )
  }

  /// Restart the battery refresh loop (e.g., returning to foreground). Every 2 minutes in the
  /// foreground. It runs on in the background only while the Live Activity shows the battery
  /// (`AppState.handleEnterBackground`); there a tick reads the radio only once
  /// `backgroundBatteryInterval` (15 min) has passed since the last reading, so a busy mesh that
  /// keeps waking the app doesn't turn into a radio read every 2 minutes all day.
  ///
  /// - Parameter currentDevice: Read on every tick rather than captured once, so a
  ///   changed OCV preset applies from the next poll without restarting the loop.
  func startRefreshLoop(services: ServiceContainer, currentDevice: @escaping @MainActor @Sendable () -> DeviceDTO?) {
    batteryRefreshTask?.cancel()
    batteryRefreshTask = Task { [weak self] in
      while true {
        do {
          try await Task.sleep(for: .seconds(120))
        } catch {
          break
        }
        guard let self else { break }
        if UIApplication.shared.applicationState == .background {
          await fetchBatteryIfOverdue(services: services, device: currentDevice())
        } else {
          await fetchDeviceBattery(services: services, device: currentDevice())
        }
      }
    }
  }

  /// Initialize battery thresholds based on current level and notify if already below a threshold
  private func initializeBatteryThresholds(device: DeviceDTO?, services: ServiceContainer) async {
    guard let battery = deviceBattery,
          let device else {
      notifiedBatteryThresholds = []
      return
    }

    guard battery.isBatteryPresent else {
      notifiedBatteryThresholds = []
      return
    }

    let percentage = battery.percentage(using: device.activeOCVArray)

    let crossedThresholds = batteryWarningThresholds.filter { percentage <= $0 }
    let unannouncedThresholds = Self.unannouncedThresholds(
      crossed: crossedThresholds,
      alreadyNotified: notifiedBatteryThresholds
    )

    notifiedBatteryThresholds = Set(crossedThresholds)

    if !unannouncedThresholds.isEmpty {
      await services.notificationService.postLowBatteryNotification(
        deviceName: device.nodeName,
        batteryPercentage: percentage
      )
    }
  }

  /// Crossed thresholds that have not alerted yet on this connection. Bootstrap
  /// re-runs each time services are re-wired, and the set is only cleared on
  /// disconnect, so a threshold that already alerted stays quiet.
  nonisolated static func unannouncedThresholds(crossed: [Int], alreadyNotified: Set<Int>) -> [Int] {
    crossed.filter { !alreadyNotified.contains($0) }
  }

  /// Check battery level against thresholds and send notifications
  private func checkBatteryThresholds(device: DeviceDTO?, services: ServiceContainer?) async {
    guard let battery = deviceBattery,
          let device,
          let notificationService = services?.notificationService else { return }

    guard battery.isBatteryPresent else { return }

    let percentage = battery.percentage(using: device.activeOCVArray)

    for threshold in batteryWarningThresholds {
      if percentage <= threshold, !notifiedBatteryThresholds.contains(threshold) {
        notifiedBatteryThresholds.insert(threshold)
        await notificationService.postLowBatteryNotification(
          deviceName: device.nodeName,
          batteryPercentage: percentage
        )
        break
      } else if percentage > threshold, notifiedBatteryThresholds.contains(threshold) {
        notifiedBatteryThresholds.remove(threshold)
      }
    }
  }
}
