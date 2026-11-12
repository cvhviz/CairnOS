import CairnServices
import SwiftUI

/// Settings → Nodes → Auto-Add: which heard nodes the radio adds to its list by itself (mode,
/// types, hop limit, overwrite when full). Staged here and sent by Apply.
struct AutoAddSettingsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var isApplying = false
  @State private var showSuccess = false

  // Local state for editing
  @State private var autoAddMode: AutoAddMode = .manual
  @State private var autoAddContacts = false
  @State private var autoAddRepeaters = false
  @State private var autoAddRoomServers = false
  @State private var overwriteOldest = false
  @State private var autoAddMaxHops: UInt8 = 0

  private var device: DeviceDTO? {
    appState.connectedDevice
  }

  /// Whether the device supports v1.12+ auto-add config features
  private var supportsAutoAddConfig: Bool {
    device?.supportsAutoAddConfig ?? false
  }

  private var supportsAutoAddMaxHops: Bool {
    device?.supportsAutoAddMaxHops ?? false
  }

  private var settingsModified: Bool {
    guard let device else { return false }
    if device.supportsAutoAddConfig {
      return autoAddMode != device.autoAddMode ||
        autoAddContacts != device.autoAddContacts ||
        autoAddRepeaters != device.autoAddRepeaters ||
        autoAddRoomServers != device.autoAddRoomServers ||
        overwriteOldest != device.overwriteOldest ||
        autoAddMaxHops != device.autoAddMaxHops
    } else {
      let deviceMode: AutoAddMode = device.manualAddContacts ? .manual : .all
      return autoAddMode != deviceMode
    }
  }

  private var canApply: Bool {
    appState.connectionState == .ready && settingsModified && !isApplying && !showSuccess
  }

  /// Combined hash of all node settings for change detection
  private var deviceNodeSettingsHash: Int {
    var hasher = Hasher()
    hasher.combine(appState.connectedDevice?.autoAddMode)
    hasher.combine(appState.connectedDevice?.autoAddContacts)
    hasher.combine(appState.connectedDevice?.autoAddRepeaters)
    hasher.combine(appState.connectedDevice?.autoAddRoomServers)
    hasher.combine(appState.connectedDevice?.overwriteOldest)
    hasher.combine(appState.connectedDevice?.supportsAutoAddConfig)
    hasher.combine(appState.connectedDevice?.autoAddMaxHops)
    hasher.combine(appState.connectedDevice?.supportsAutoAddMaxHops)
    return hasher.finalize()
  }

  var body: some View {
    CardFormSection(L10n.Settings.Nodes.AutoAdd.header, info: infoMessage) {
      PickerCard(
        L10n.Settings.Nodes.autoAddMode,
        systemImage: "person.crop.circle.badge.plus",
        color: .green,
        selection: $autoAddMode
      ) {
        Text(L10n.Settings.Nodes.AutoAddMode.manual).tag(AutoAddMode.manual)
        if supportsAutoAddConfig {
          Text(L10n.Settings.Nodes.AutoAddMode.selectedTypes).tag(AutoAddMode.selectedTypes)
        }
        Text(L10n.Settings.Nodes.AutoAddMode.all).tag(AutoAddMode.all)
      }
      .editableWhenReady(appState.connectionState, isApplying: isApplying)
      .onChange(of: autoAddMode) { _, newValue in
        // Mode changes reveal or hide the type and hop cards below the picker.
        if newValue != .manual {
          AccessibilityNotification.LayoutChanged().post()
        }
      }

      if supportsAutoAddConfig, autoAddMode == .selectedTypes {
        ToggleCard(L10n.Settings.Nodes.autoAddContacts, systemImage: "person.fill", color: .blue, isOn: $autoAddContacts)
          .editableWhenReady(appState.connectionState, isApplying: isApplying)
        ToggleCard(
          L10n.Settings.Nodes.autoAddRepeaters,
          systemImage: "antenna.radiowaves.left.and.right",
          color: .orange,
          isOn: $autoAddRepeaters
        )
        .editableWhenReady(appState.connectionState, isApplying: isApplying)
        ToggleCard(
          L10n.Settings.Nodes.autoAddRoomServers,
          systemImage: "bubble.left.and.bubble.right.fill",
          color: .purple,
          isOn: $autoAddRoomServers
        )
        .editableWhenReady(appState.connectionState, isApplying: isApplying)
      }

      if supportsAutoAddMaxHops, autoAddMode != .manual {
        PickerCard(
          L10n.Settings.Nodes.maxHops,
          systemImage: "point.3.connected.trianglepath.dotted",
          color: .teal,
          selection: $autoAddMaxHops
        ) {
          Text(L10n.Settings.Nodes.MaxHops.noLimit).tag(UInt8(0))
          Text(L10n.Settings.Nodes.MaxHops.directOnly).tag(UInt8(1))
          Text(L10n.Settings.Nodes.MaxHops.oneHop).tag(UInt8(2))
          ForEach(Array(2...6), id: \.self) { hops in
            Text(L10n.Settings.Nodes.MaxHops.hops(hops)).tag(UInt8(hops + 1))
          }
        }
        .editableWhenReady(appState.connectionState, isApplying: isApplying)
      }

      if supportsAutoAddConfig {
        // What it does is behind the header's "i"; the hint keeps it on the switch for VoiceOver.
        ToggleCard(
          L10n.Settings.Nodes.overwriteOldest,
          systemImage: "arrow.triangle.2.circlepath",
          color: .gray,
          isOn: $overwriteOldest
        )
        .accessibilityHint(L10n.Settings.Nodes.overwriteOldestDescription)
        .editableWhenReady(appState.connectionState, isApplying: isApplying)
      }

      ApplyCard(
        title: L10n.Settings.Nodes.AutoAdd.apply,
        isLoading: isApplying,
        showSuccess: showSuccess,
        canApply: canApply,
        action: applySettings
      )
      .radioDisabled(for: appState.connectionState, or: isApplying || showSuccess || !settingsModified)
    }
    .onAppear {
      loadFromDevice()
    }
    .onChange(of: deviceNodeSettingsHash) { _, _ in
      loadFromDevice()
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  /// The chosen mode explained, then the hop limit and Overwrite Oldest when they're showing.
  private var infoMessage: String {
    var parts = [autoAddModeDescription]
    if supportsAutoAddMaxHops, autoAddMode != .manual, autoAddMaxHops > 0 {
      parts.append(L10n.Settings.Nodes.MaxHops.footerActive)
    }
    if supportsAutoAddConfig {
      parts.append(L10n.Settings.Nodes.OverwriteOldest.info(
        L10n.Settings.Nodes.overwriteOldest,
        L10n.Settings.Nodes.overwriteOldestDescription
      ))
    }
    return parts.joined(separator: "\n\n")
  }

  private var autoAddModeDescription: String {
    switch autoAddMode {
    case .manual:
      L10n.Settings.Nodes.AutoAddMode.manualDescription
    case .selectedTypes:
      L10n.Settings.Nodes.AutoAddMode.selectedTypesDescription
    case .all:
      L10n.Settings.Nodes.AutoAddMode.allDescription
    }
  }

  private func loadFromDevice() {
    guard let device else { return }

    if device.supportsAutoAddConfig {
      autoAddMode = device.autoAddMode
      autoAddContacts = device.autoAddContacts
      autoAddRepeaters = device.autoAddRepeaters
      autoAddRoomServers = device.autoAddRoomServers
      overwriteOldest = device.overwriteOldest
      autoAddMaxHops = device.autoAddMaxHops
    } else {
      // Older firmware only supports manual/all toggle via manualAddContacts
      autoAddMode = device.manualAddContacts ? .manual : .all
      autoAddContacts = false
      autoAddRepeaters = false
      autoAddRoomServers = false
      overwriteOldest = false
    }
  }

  private func applySettings() {
    guard !isApplying else { return }
    guard let device, let settingsService = appState.services?.settingsService else { return }

    isApplying = true
    Task {
      do {
        // Protocol: manualAddContacts=true for .manual and .selectedTypes, false only for .all
        let manualAdd = autoAddMode != .all

        // Save manualAddContacts (works on all firmware versions)
        _ = try await settingsService.setOtherParamsVerified(from: device, autoAddContacts: !manualAdd)

        // Save autoAddConfig only on v1.12+ firmware
        if device.supportsAutoAddConfig {
          var config: UInt8 = 0
          if overwriteOldest { config |= AutoAddConfig.overwriteOldestBit }

          switch autoAddMode {
          case .manual:
            break
          case .selectedTypes:
            if autoAddContacts { config |= AutoAddConfig.contactsBit }
            if autoAddRepeaters { config |= AutoAddConfig.repeatersBit }
            if autoAddRoomServers { config |= AutoAddConfig.roomServersBit }
          case .all:
            break
          }

          _ = try await settingsService.setAutoAddConfigVerified(
            AutoAddConfig(bitmask: config, maxHops: autoAddMaxHops)
          )
        }

        retryAlert.reset()
        isApplying = false

        withAnimation {
          showSuccess = true
        }
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation {
          showSuccess = false
        }
        return
      } catch let error as SettingsServiceError where error.isRetryable {
        loadFromDevice()
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { applySettings() },
          onMaxRetriesExceeded: { dismiss() }
        )
      } catch {
        loadFromDevice()
        errorMessage = error.userFacingMessage
      }
      isApplying = false
    }
  }
}

private extension View {
  /// Disables one auto-add card while the radio isn't ready or an Apply is running. Applied per
  /// card rather than to the section, so the header's "i" stays readable while disconnected.
  func editableWhenReady(_ connectionState: DeviceConnectionState, isApplying: Bool) -> some View {
    dimmedWhenDisabled()
      .radioDisabled(for: connectionState, or: isApplying)
  }
}
