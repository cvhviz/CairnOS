import Foundation
import CairnServices
import os

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "DeviceSelectionList")

/// Connectable saved radios plus the caller-supplied needs-setup list.
/// Does not re-diff ASK ids minus saved.
enum DeviceSelectionListBuilder {
  struct Result: Equatable {
    var connectable: [DeviceDTO]
    var needsSetup: [SystemPairedAccessory]
  }

  /// VoiceOver and trailing-control copy for a needs-setup Previously Paired row.
  struct NeedsSetupRowPresentation: Equatable {
    let trailingTitle: String
    let accessibilityLabel: String
    let accessibilityHint: String
  }

  /// `includesDemoRadio` lists the saved demo radio, which no pairing or connection method vouches
  /// for (`offersDemoRadio`).
  static func make(
    saved: [DeviceDTO],
    accessories: [(id: UUID, name: String)],
    needsSetup: [SystemPairedAccessory],
    hasSystemPairingRegistry: Bool,
    includesDemoRadio: Bool = false
  ) -> Result {
    let pairedIDs = Set(accessories.map(\.id))
    let connectable = saved.filter {
      (includesDemoRadio && $0.isDemoRadio) || DeviceSelectionFilter.isConnectable(
        $0,
        pairedAccessoryIDs: pairedIDs,
        hasSystemPairingRegistry: hasSystemPairingRegistry
      )
    }
    return Result(
      connectable: connectable,
      needsSetup: hasSystemPairingRegistry ? needsSetup : []
    )
  }

  /// The saved radios and leftover system pairings, read fresh, plus which Bluetooth radios
  /// another app holds. Read by the device picker and Connections alike.
  struct Loaded: Equatable {
    var list: Result
    var connectedElsewhere: Set<UUID>
  }

  @MainActor
  static func load(from connectionManager: ConnectionManager) async -> Loaded {
    let hasSystemPairingRegistry = connectionManager.hasSystemPairingRegistry
    var needsSetup: [SystemPairedAccessory] = []
    if hasSystemPairingRegistry {
      do {
        let pending = try await connectionManager.systemAccessoriesMissingDeviceRecord()
        needsSetup = pending.map { SystemPairedAccessory(id: $0.id, name: $0.name) }
      } catch {
        logger.error("Failed to query system pairing accessories: \(error.localizedDescription)")
      }
    }

    let savedDevices: [DeviceDTO]
    do {
      savedDevices = try await connectionManager.fetchSavedDevices()
    } catch {
      logger.error("Failed to load devices: \(error.localizedDescription)")
      savedDevices = []
    }

    let result = make(
      saved: savedDevices,
      accessories: connectionManager.pairedAccessoryInfos,
      needsSetup: needsSetup,
      hasSystemPairingRegistry: hasSystemPairingRegistry,
      includesDemoRadio: offersDemoRadio
    )

    var connectedElsewhere: Set<UUID> = []
    for device in result.connectable {
      let hasBluetooth = device.connectionMethods.isEmpty ||
        device.connectionMethods.contains { !$0.isWiFi }
      if hasBluetooth, await connectionManager.isDeviceConnectedToOtherApp(device.id) {
        connectedElsewhere.insert(device.id)
      }
    }
    return Loaded(list: result, connectedElsewhere: connectedElsewhere)
  }

  /// Whether a saved demo radio is listed to connect again, where onboarding offers it: always in
  /// the simulator, and on a device with Demo Mode on.
  @MainActor
  static var offersDemoRadio: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      DemoModeManager.shared.isEnabled
    #endif
  }

  static func needsSetupPresentation(name: String) -> NeedsSetupRowPresentation {
    NeedsSetupRowPresentation(
      trailingTitle: L10n.Settings.DeviceSelection.setup,
      accessibilityLabel: L10n.Settings.DeviceSelection.Accessibility.setupLabel(name),
      accessibilityHint: L10n.Settings.DeviceSelection.Accessibility.setupHint
    )
  }
}

extension DeviceDTO {
  /// How a saved radio is reached: its WiFi address when it has one, else Bluetooth. Shared by
  /// the device picker and Connections so both connect a radio the same way.
  var primaryConnectionMethod: ConnectionMethod? {
    connectionMethods.first { $0.isWiFi } ?? connectionMethods.first
  }

  var connectsViaWiFi: Bool {
    primaryConnectionMethod?.isWiFi == true
  }

  /// The demo radio (`ConnectionManager.simulatorConnect()`): mock data, with no peripheral or
  /// address, so it is always in reach and connects the way onboarding connects it.
  var isDemoRadio: Bool {
    id == MockDataProvider.simulatorDeviceID
  }
}
