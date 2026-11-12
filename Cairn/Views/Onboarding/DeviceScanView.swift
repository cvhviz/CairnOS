import CairnServices
import MeshCore
import SwiftUI

struct DeviceScanView: View {
  @Environment(\.appState) private var appState
  @Environment(\.openURL) private var openURL
  @State private var showTroubleshooting = false
  @State private var showingWiFiConnection = false
  @State private var showingNoDeviceSheet = false
  @State private var pairingSuccessTrigger = false
  @State private var failureHapticTrigger = false
  @State private var demoModeUnlockTrigger = false
  @State private var didInitiatePairing = false
  @State private var showDemoModeAlert = false
  @State private var otherAppDeviceID: UUID?
  @State private var savedRadio: DeviceDTO?
  /// The radio's name as the pair step offers to set it: prefilled with its current name, sent
  /// on Continue when changed, by the same path as Device Info's rename.
  @State private var draftName = ""
  @State private var isSavingName = false
  @State private var nameErrorMessage: String?
  private var demoModeManager = DemoModeManager.shared

  private var hasConnectedDevice: Bool {
    appState.connectionState == .ready
  }

  var body: some View {
    VStack(spacing: OnboardingMetrics.largeSpacing) {
      VStack(spacing: OnboardingMetrics.mediumSpacing) {
        PulsingAntenna()

        Text(L10n.Onboarding.DeviceScan.title)
          .font(.largeTitle)
          .bold()
          .accessibilityAddTraits(.isHeader)
          .simultaneousGesture(
            TapGesture(count: 3).onEnded { unlockDemoMode() }
          )

        if !hasConnectedDevice {
          Text(L10n.Onboarding.DeviceScan.subtitle)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
      }

      Spacer()

      if hasConnectedDevice {
        VStack(spacing: OnboardingMetrics.mediumSpacing) {
          if !didInitiatePairing {
            Text(L10n.Onboarding.DeviceScan.alreadyPaired)
              .font(.title2)
              .multilineTextAlignment(.center)
          }
          nameField
        }
        .padding()
      }

      Spacer()

      VStack(spacing: OnboardingMetrics.mediumSpacing) {
        if hasConnectedDevice {
          Button {
            continueFromPairing()
          } label: {
            HStack(spacing: 8) {
              if isSavingName {
                ProgressView().controlSize(.small)
              }
              Text(L10n.Onboarding.DeviceScan.continue)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
          }
          .liquidGlassProminentButtonStyle()
          .disabled(isSavingName)
        } else {
          primaryCTA

          ViewThatFits {
            HStack(spacing: OnboardingMetrics.largeSpacing) {
              secondaryButtons
            }
            VStack(spacing: OnboardingMetrics.mediumSpacing) {
              secondaryButtons
            }
          }
          .frame(minHeight: OnboardingMetrics.minHitTarget)

          Button(L10n.Onboarding.DeviceScan.noDeviceYet) {
            showingNoDeviceSheet = true
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
          .frame(minHeight: OnboardingMetrics.minHitTarget)
        }
      }
      .padding(.horizontal)
      .padding(.bottom)
    }
    .cairnFeedback(.success, trigger: pairingSuccessTrigger)
    .cairnFeedback(.success, trigger: demoModeUnlockTrigger)
    .cairnFeedback(.error, trigger: failureHapticTrigger)
    .errorAlert($nameErrorMessage)
    .onChange(of: hasConnectedDevice) { _, connected in
      guard didInitiatePairing, connected else { return }
      pairingSuccessTrigger.toggle()
    }
    // The name field starts with the radio's own name, once (and again for another radio).
    .onChange(of: appState.connectedDevice?.id, initial: true) { _, _ in
      draftName = appState.connectedDevice?.nodeName ?? ""
    }
    .onChange(of: appState.connectionUI.showingConnectionFailedAlert) { _, showing in
      guard didInitiatePairing, showing else { return }
      failureHapticTrigger.toggle()
    }
    .onChange(of: appState.connectionUI.otherAppWarningDeviceID) { _, newValue in
      // Other-app failures land on ConnectionUIState. Mirror the warning ID so
      // the recovery CTA stays "Retry connection" after the alert is dismissed.
      if let id = newValue {
        otherAppDeviceID = id
        if didInitiatePairing { failureHapticTrigger.toggle() }
      }
    }
    .task(id: appState.connectionManager.lastConnectedDeviceID) {
      savedRadio = await loadSavedRadio()
    }
    .sheet(isPresented: $showTroubleshooting) {
      TroubleshootingSheet()
    }
    .sheet(isPresented: $showingWiFiConnection) {
      WiFiConnectionSheet()
    }
    .sheet(isPresented: $showingNoDeviceSheet) {
      NoDeviceSheet()
    }
    .alert(L10n.Onboarding.DeviceScan.DemoModeAlert.title, isPresented: $showDemoModeAlert) {
      Button(L10n.Localizable.Common.ok) {}
    } message: {
      Text(L10n.Onboarding.DeviceScan.DemoModeAlert.message)
    }
  }

  @ViewBuilder
  private var primaryCTA: some View {
    #if targetEnvironment(simulator)
      Button { connectSimulator() } label: { ctaLabel(systemImage: "laptopcomputer.and.iphone",
                                                      text: L10n.Onboarding.DeviceScan.connectSimulator) }
        .liquidGlassProminentButtonStyle()
        .disabled(appState.connectionUI.isBusy)
    #else
      if demoModeManager.isEnabled {
        Button { connectSimulator() } label: { ctaLabel(systemImage: "play.circle.fill",
                                                        text: L10n.Onboarding.DeviceScan.continueDemo) }
          .liquidGlassProminentButtonStyle()
          .disabled(appState.connectionUI.isBusy)
      } else if appState.connectionManager.bluetoothAvailability == .poweredOff {
        // Scanning can't find anything: say what to fix, with the way there (as the macOS scanner).
        bluetoothRemedy(
          title: L10n.Onboarding.DeviceScanner.BluetoothOff.title,
          message: L10n.Onboarding.DeviceScanner.BluetoothOff.message
        )
      } else if appState.connectionManager.bluetoothAvailability == .unauthorized {
        bluetoothRemedy(
          title: L10n.Onboarding.DeviceScanner.BluetoothUnauthorized.title,
          message: L10n.Onboarding.DeviceScanner.BluetoothUnauthorized.message
        )
      } else if let deviceID = otherAppDeviceID {
        Button { retryConnection(deviceID: deviceID) } label: { ctaLabel(systemImage: "arrow.clockwise.circle.fill",
                                                                         text: L10n.Onboarding.DeviceScan.retryConnection) }
          .liquidGlassProminentButtonStyle()
          .disabled(appState.connectionUI.isBusy)
      } else if let savedRadio {
        // AccessorySetupKit never lists a radio this app already set up ("No Accessory Found"),
        // so a saved radio that dropped reconnects here; the picker is for a different one.
        Button { reconnectSavedRadio(savedRadio) } label: {
          ctaLabel(systemImage: "arrow.clockwise.circle.fill",
                   text: L10n.Onboarding.DeviceScan.reconnectSaved(savedRadio.nodeName))
        }
        .liquidGlassProminentButtonStyle()
        .disabled(appState.connectionUI.isBusy)

        Button(L10n.Onboarding.DeviceScan.addDifferentDevice) { startPairing() }
          .font(.subheadline)
          .disabled(appState.connectionUI.isBusy)
          .frame(minHeight: OnboardingMetrics.minHitTarget)
      } else {
        Button { startPairing() } label: { ctaLabel(systemImage: "plus.circle.fill",
                                                    text: L10n.Onboarding.DeviceScan.addDevice) }
          .liquidGlassProminentButtonStyle()
          .disabled(appState.connectionUI.isBusy)
      }
    #endif
  }

  @ViewBuilder
  private var secondaryButtons: some View {
    Button(L10n.Onboarding.DeviceScan.connectViaWifi) { showingWiFiConnection = true }
      .font(.subheadline)
      .foregroundStyle(.secondary)

    Button(L10n.Onboarding.DeviceScan.deviceNotAppearing) { showTroubleshooting = true }
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }

  /// Bluetooth off or not allowed: the reason and an Open Settings button in the CTA's place.
  private func bluetoothRemedy(title: String, message: String) -> some View {
    VStack(spacing: OnboardingMetrics.mediumSpacing) {
      Label(title, systemImage: "antenna.radiowaves.left.and.right.slash")
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          openURL(url)
        }
      } label: {
        ctaLabel(systemImage: "gear", text: L10n.Onboarding.DeviceScan.openSettings)
      }
      .liquidGlassProminentButtonStyle()
      .accessibilityIdentifier("deviceScan.openSettings")
    }
    .accessibilityElement(children: .contain)
  }

  /// The optional name for the radio under the connected state, prefilled with its own.
  private var nameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(L10n.Onboarding.DeviceScan.Name.title, text: $draftName)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10, style: .continuous))
        .onChange(of: draftName) { _, newValue in
          if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
            draftName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
          }
        }
        .disabled(isSavingName)
        .accessibilityLabel(L10n.Onboarding.DeviceScan.Name.title)
        .accessibilityIdentifier("deviceScan.name")
      Text(L10n.Onboarding.DeviceScan.Name.footer)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Continue: sends the name first when it was changed (Device Info's path), staying here on a
  /// failure so it can be fixed or left as it was.
  private func continueFromPairing() {
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != appState.connectedDevice?.nodeName,
          let settingsService = appState.services?.settingsService else {
      appState.onboarding.onboardingPath.append(.region)
      return
    }
    isSavingName = true
    Task { @MainActor in
      defer { isSavingName = false }
      do {
        _ = try await settingsService.setNodeNameVerified(name)
        appState.onboarding.onboardingPath.append(.region)
      } catch {
        nameErrorMessage = error.userFacingMessage
      }
    }
  }

  private func ctaLabel(systemImage: String, text: String) -> some View {
    HStack(spacing: 8) {
      if appState.connectionUI.isBusy {
        ProgressView().controlSize(.small)
        Text(L10n.Onboarding.DeviceScan.connecting)
      } else {
        Image(systemName: systemImage)
        Text(text)
      }
    }
    .font(.headline)
    .frame(maxWidth: .infinity)
    .padding()
  }

  private func startPairing() {
    didInitiatePairing = true
    appState.startDeviceScan()
  }

  private func retryConnection(deviceID: UUID) {
    appState.connectionUI.isBusy = true
    Task { @MainActor in
      defer { appState.connectionUI.isBusy = false }
      do {
        try await appState.connectionManager.connect(to: deviceID, forceReconnect: true)
        await appState.wireServicesIfConnected()
        appState.onboarding.onboardingPath.append(.region)
      } catch {
        appState.connectionUI.presentSavedDeviceConnectFailure(deviceID: deviceID, error: error)
      }
    }
  }

  /// The radio this install last connected, when it still has a saved record to reconnect to.
  private func loadSavedRadio() async -> DeviceDTO? {
    let connectionManager = appState.connectionManager
    guard let deviceID = connectionManager.lastConnectedDeviceID,
          deviceID != MockDataProvider.simulatorDeviceID else { return nil }
    return try? await connectionManager.persistenceStore.fetchDevice(id: deviceID)
  }

  private func reconnectSavedRadio(_ device: DeviceDTO) {
    didInitiatePairing = true
    appState.connectionUI.isBusy = true
    Task { @MainActor in
      defer { appState.connectionUI.isBusy = false }
      // Failures go to the connection alerts.
      await appState.connectToSavedDevice(device)
      guard appState.services != nil else { return }
      await appState.wireServicesIfConnected()
      appState.onboarding.onboardingPath.append(.region)
    }
  }

  private func connectSimulator() {
    appState.connectionUI.isBusy = true
    didInitiatePairing = true
    Task { @MainActor in
      defer { appState.connectionUI.isBusy = false }
      do {
        try await appState.connectionManager.simulatorConnect()
        await appState.wireServicesIfConnected()
        appState.onboarding.onboardingPath.append(.region)
      } catch {
        appState.connectionUI.presentConnectionFailure(message: error.userFacingMessage)
      }
    }
  }

  /// 3-tap easter egg for App Store reviewers — preserved per CLAUDE.md `demo-mode-is-for-app-store-reviewers`.
  private func unlockDemoMode() {
    demoModeManager.unlock()
    demoModeUnlockTrigger.toggle()
    showDemoModeAlert = true
  }
}

#Preview {
  DeviceScanView()
    .environment(\.appState, AppState())
}
