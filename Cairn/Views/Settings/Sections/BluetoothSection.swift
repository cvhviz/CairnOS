import CairnServices
import SwiftUI

/// Firmware BLE pairing PIN protocol values. Only zero means "no PIN of my own": the radio then uses
/// its default, which on a board with a screen is a random PIN it shows there. Any other value,
/// 123456 included, is a PIN someone chose.
private enum BLEPin {
  static let unset: UInt32 = 0
  /// A custom PIN must be exactly six digits.
  static let customRange: ClosedRange<UInt32> = 100_000...999_999
}

/// Bluetooth PIN configuration
struct BluetoothSection: View {
  @Environment(\.appState) private var appState
  @State private var pinType: BluetoothPinType = .default
  @State private var customPin: String = ""
  @State private var showingPinEntry = false
  @State private var showingChangePinEntry = false
  @State private var showingRemoveConfirmation = false
  @State private var isChangingPin = false
  @State private var errorMessage: String?
  @State private var hasInitialized = false
  /// The PIN shows when the page opens, since it's what people come here for; a tap hides it.
  @State private var isPinVisible = true
  /// Validated PIN awaiting the reboot/re-pair confirmation.
  @State private var confirmingPin: UInt32?

  // Track what the user intended before confirmation dialogs
  @State private var pendingPinType: BluetoothPinType?
  @State private var isRenaming = false

  enum BluetoothPinType: String, CaseIterable {
    case `default` = "Default"
    case custom = "Custom PIN"

    var localizedName: String {
      switch self {
      case .default: L10n.Settings.Bluetooth.PinType.default
      case .custom: L10n.Settings.Bluetooth.PinType.custom
      }
    }
  }

  private var currentPinType: BluetoothPinType {
    guard let device = appState.connectedDevice else { return .default }
    return device.blePin == BLEPin.unset ? .default : .custom
  }

  var body: some View {
    // The PIN change's reboot is confirmed in its own alert, so the note can sit behind the "i".
    CardFormSection(
      L10n.Settings.Bluetooth.header,
      info: pinType == .default ? L10n.Settings.Bluetooth.defaultPinFooter : L10n.Settings.Bluetooth.customPinFooter
    ) {
      PickerCard(
        L10n.Settings.Bluetooth.pinType,
        systemImage: "lock.fill",
        color: .blue,
        selection: $pinType
      ) {
        ForEach(BluetoothPinType.allCases, id: \.self) { type in
          Text(type.localizedName).tag(type)
        }
      }
      .onChange(of: pinType) { oldValue, newValue in
        guard hasInitialized else { return }
        handlePinTypeChange(from: oldValue, to: newValue)
      }
      .dimmedWhenDisabled()
      .radioDisabled(for: appState.connectionState, or: isChangingPin)

      if pinType == .custom, let device = appState.connectedDevice, device.blePin > 0 {
        Button {
          isPinVisible.toggle()
        } label: {
          HStack(spacing: 8) {
            SettingCardLabel(L10n.Settings.Bluetooth.currentPin, systemImage: "key.fill", color: .gray)
            Spacer(minLength: 8)
            Group {
              if isPinVisible {
                Text(device.blePin, format: .number.grouping(.never))
              } else {
                Text("••••••")
              }
            }
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)

            Image(systemName: isPinVisible ? "eye" : "eye.slash")
              .foregroundStyle(.tertiary)
              .imageScale(.small)
              .accessibilityHidden(true)
          }
          .cardSurface(padding: 12)
          .cardInteractionShape()
        }
        .buttonStyle(.plain)
        // One element: the title, then the PIN or "Hidden" rather than the mask's bullet characters.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Settings.Bluetooth.currentPin)
        .accessibilityValue(isPinVisible
          ? BLEPinInput.display(device.blePin)
          : L10n.Settings.Bluetooth.pinHidden)
        .accessibilityHint(isPinVisible
          ? L10n.Settings.Bluetooth.hidePinHint
          : L10n.Settings.Bluetooth.showPinHint)
        .accessibilityAddTraits(.isButton)

        ActionCard(L10n.Settings.Bluetooth.changePin, systemImage: "lock.rotation", color: .blue) {
          customPin = ""
          showingChangePinEntry = true
        }
        .dimmedWhenDisabled()
        .radioDisabled(for: appState.connectionState)
      }

      if appState.connectionState == .ready,
         let deviceID = appState.connectedDevice?.id,
         appState.connectionManager.supportsDeviceRename,
         appState.connectionManager.hasAccessory(for: deviceID) {
        ActionCard(L10n.Settings.Bluetooth.changeDisplayName, systemImage: "character.cursor.ibeam", color: .gray) {
          renameDevice()
        }
        .overlay(alignment: .trailing) {
          if isRenaming {
            ProgressView()
              .controlSize(.small)
              .padding(.trailing, 12)
          }
        }
        .dimmedWhenDisabled()
        .radioDisabled(for: appState.connectionState, or: isRenaming)
      }
    }
    .onAppear {
      pinType = currentPinType
      Task { @MainActor in
        hasInitialized = true
      }
    }
    .alert(L10n.Settings.Bluetooth.Alert.SetPin.title, isPresented: $showingPinEntry) {
      TextField(L10n.Settings.Bluetooth.pinPlaceholder, text: $customPin)
        .keyboardType(.numberPad)
        .onChange(of: customPin) { _, newValue in
          let sanitized = BLEPinInput.sanitized(newValue)
          if sanitized != newValue { customPin = sanitized }
        }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        // Revert to previous pin type without triggering onChange loop
        hasInitialized = false
        pinType = currentPinType
        Task { @MainActor in
          hasInitialized = true
        }
      }
      Button(L10n.Settings.Bluetooth.setPin) {
        setCustomPin()
      }
    } message: {
      Text(L10n.Settings.Bluetooth.Alert.SetPin.message)
    }
    .alert(L10n.Settings.Bluetooth.Alert.ChangePin.title, isPresented: $showingChangePinEntry) {
      TextField(L10n.Settings.Bluetooth.pinPlaceholder, text: $customPin)
        .keyboardType(.numberPad)
        .onChange(of: customPin) { _, newValue in
          let sanitized = BLEPinInput.sanitized(newValue)
          if sanitized != newValue { customPin = sanitized }
        }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.Bluetooth.changePin) {
        setCustomPin()
      }
    } message: {
      Text(L10n.Settings.Bluetooth.Alert.ChangePin.message)
    }
    .alert(L10n.Settings.Bluetooth.Alert.ChangePinType.title, isPresented: $showingRemoveConfirmation) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        // Revert to previous pin type without triggering onChange loop
        hasInitialized = false
        pinType = currentPinType
        Task { @MainActor in
          hasInitialized = true
        }
      }
      Button(L10n.Settings.Bluetooth.Alert.change) {
        applyPendingPinType()
      }
    } message: {
      Text(L10n.Settings.Bluetooth.Alert.ChangePinType.message)
    }
    .alert(
      L10n.Settings.Bluetooth.Alert.ConfirmPin.title,
      isPresented: Binding(
        get: { confirmingPin != nil },
        set: { if !$0 { confirmingPin = nil } }
      ),
      presenting: confirmingPin
    ) { pin in
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        customPin = ""
        revertPinTypePicker()
      }
      Button(L10n.Settings.Bluetooth.Alert.ConfirmPin.confirm) {
        applyCustomPin(pin)
      }
    } message: { pin in
      Text(L10n.Settings.Bluetooth.Alert.ConfirmPin.message(BLEPinInput.display(pin)))
    }
    .errorAlert($errorMessage)
    // The radio's own settings can change it too.
    .task { await appState.refreshBLEPin() }
    .onChange(of: appState.connectedDevice?.blePin) { revertPinTypePicker() }
  }

  private func revertPinTypePicker() {
    hasInitialized = false
    pinType = currentPinType
    Task { @MainActor in
      hasInitialized = true
    }
  }

  private func handlePinTypeChange(from oldValue: BluetoothPinType, to newValue: BluetoothPinType) {
    // Skip if picker is being synced to device's current state (handles initialization race condition)
    guard newValue != currentPinType else { return }

    // If changing to custom, show PIN entry
    if newValue == .custom, oldValue != .custom {
      showingPinEntry = true
      return
    }

    // If changing from custom to default, show confirmation
    if oldValue == .custom, newValue == .default {
      pendingPinType = newValue
      showingRemoveConfirmation = true
    }
  }

  private func applyPendingPinType() {
    guard let pending = pendingPinType else { return }
    pendingPinType = nil

    // Back to the radio's own default. Only `.default` gets here: a custom PIN goes through its entry.
    guard pending == .default else { return }
    let pinValue = BLEPin.unset

    isChangingPin = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }

        // Send PIN change command (written to RAM until reboot)
        try await settingsService.setBlePin(pinValue)
        // Saved on the radio: the page and the Dashboard know now, not only after the reconnect.
        appState.connectionManager.updateBLEPin(pinValue)

        // Reboot device to apply PIN change - iOS auto-reconnects
        // Timeout is expected since device disconnects before write callback
        do {
          try await settingsService.reboot()
        } catch BLEError.operationTimeout {
          // Expected - device reboots before BLE write callback arrives
        }
      } catch {
        errorMessage = error.userFacingMessage
        // Revert
        hasInitialized = false
        pinType = currentPinType
        Task { @MainActor in
          hasInitialized = true
        }
      }
      isChangingPin = false
    }
  }

  /// Validates the entered PIN, then asks for confirmation before the reboot.
  private func setCustomPin() {
    guard let pin = BLEPinInput.validatedPin(customPin, allowed: BLEPin.customRange) else {
      errorMessage = L10n.Settings.Bluetooth.Error.invalidPin
      customPin = ""
      // Revert
      hasInitialized = false
      pinType = currentPinType
      Task { @MainActor in
        hasInitialized = true
      }
      return
    }
    confirmingPin = pin
  }

  private func applyCustomPin(_ pin: UInt32) {
    isChangingPin = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }

        // Send PIN change command (written to RAM until reboot)
        try await settingsService.setBlePin(pin)
        // Saved on the radio: the page and the Dashboard know now, not only after the reconnect.
        appState.connectionManager.updateBLEPin(pin)

        // Reboot device to apply PIN change - iOS auto-reconnects
        // Timeout is expected since device disconnects before write callback
        do {
          try await settingsService.reboot()
        } catch BLEError.operationTimeout {
          // Expected - device reboots before BLE write callback arrives
        }
      } catch {
        errorMessage = error.userFacingMessage
        // Revert
        hasInitialized = false
        pinType = currentPinType
        Task { @MainActor in
          hasInitialized = true
        }
      }
      isChangingPin = false
      customPin = ""
    }
  }

  private func renameDevice() {
    isRenaming = true
    Task { @MainActor in
      defer { isRenaming = false }

      do {
        try await appState.connectionManager.renameCurrentDevice()
      } catch DevicePairingError.cancelled {
        // The system sheet was dismissed: nothing to report.
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}
