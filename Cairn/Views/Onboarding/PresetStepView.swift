import CairnServices
import SwiftUI

/// Onboarding step 5. Lists presets for the selected place (locale-sorted alternatives when
/// `regionSelection` is nil), with every other preset apart under "Other regions".
struct PresetStepView: View {
  @Environment(\.appState) private var appState

  @State private var selectedID: String?
  @State private var isApplying = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var commitTrigger = false
  @State private var showsOtherRegions = false

  private var region: RegionSelection? {
    appState.regionSelection
  }

  /// The same lists Settings → Radio offers, each sorted by name.
  private var visiblePresets: RadioPresets.VisiblePresets {
    RadioPresets.visiblePresets(for: region)
  }

  private var regionalPresets: [RadioPreset] {
    visiblePresets.regional.sorted { $0.name < $1.name }
  }

  private var otherRegionPresets: [RadioPreset] {
    visiblePresets.otherRegions.sorted { $0.name < $1.name }
  }

  /// The radio's current preset, when its settings match one.
  private var activePresetID: String? {
    guard let device = appState.connectedDevice else { return nil }
    return RadioPresets.resolvedPreset(
      frequencyKHz: device.frequency,
      bandwidthKHz: device.bandwidth,
      spreadingFactor: device.spreadingFactor,
      codingRate: device.codingRate,
      preferredID: device.appliedRadioPresetID,
      region: region
    )?.id
  }

  /// The radio link as this step reports it. A preset can only be written over a live session.
  enum LinkStatus: Equatable, Sendable {
    /// Services are up: the preset can be applied.
    case live
    /// A connect or session rebuild is under way.
    case connecting
    /// Not connected, with a saved radio to reconnect to.
    case disconnected
    /// Not connected and no radio saved: back to the pair step.
    case unpaired
  }

  /// A connect in flight reads as connecting even once services appear, so the Use button
  /// waits for the reconnect that applies the pending preset instead of racing it.
  static func linkStatus(
    hasServices: Bool,
    connectionState: DeviceConnectionState,
    isBusy: Bool,
    hasSavedRadio: Bool
  ) -> LinkStatus {
    if isBusy { return .connecting }
    if hasServices { return .live }
    switch connectionState {
    case .connecting, .connected:
      return .connecting
    case .disconnected, .syncing, .ready:
      return hasSavedRadio ? .disconnected : .unpaired
    }
  }

  /// The Use button never sits dim with nothing said: it stays live once a preset is picked,
  /// and a tap while disconnected reconnects first. Only an apply or a connect already under
  /// way holds it, and the status line above it says which. A radio that has refused radio
  /// settings over this Wi-Fi link would refuse again, so then it holds too, with that said.
  static func isApplyDisabled(
    selectedID: String?,
    isApplying: Bool,
    linkStatus: LinkStatus,
    refusesOverWiFi: Bool = false
  ) -> Bool {
    isApplying || selectedID == nil || linkStatus == .connecting || refusesOverWiFi
  }

  /// Set Up Later finishes without writing: offered whenever the link isn't live, and always over
  /// Wi-Fi, where Cairn firmware refuses radio settings, so setup never depends on a write the
  /// radio may not take over that link.
  static func showsSetUpLater(linkStatus: LinkStatus, isWiFi: Bool) -> Bool {
    linkStatus != .live || isWiFi
  }

  private var isWiFi: Bool {
    appState.connectionManager.currentTransportType == .wifi
  }

  private var linkStatus: LinkStatus {
    Self.linkStatus(
      hasServices: appState.services != nil,
      connectionState: appState.connectionState,
      isBusy: appState.connectionUI.isBusy,
      hasSavedRadio: appState.connectionManager.lastConnectedDeviceID != nil
    )
  }

  var body: some View {
    pickerState
      .cairnFeedback(.success, trigger: commitTrigger)
      .errorAlert($errorMessage)
      .retryAlert(retryAlert)
      .onAppear {
        // A radio already on a preset for elsewhere finds it without opening the group.
        showsOtherRegions = otherRegionPresets.contains { $0.id == activePresetID }
      }
  }

  private var pickerState: some View {
    VStack(spacing: OnboardingMetrics.cardSpacing) {
      VStack(spacing: OnboardingMetrics.titleStackSpacing) {
        Text(L10n.Onboarding.Preset.title)
          .font(.largeTitle)
          .bold()
          .accessibilityHeading(.h1)
        if let region {
          Text(L10n.Onboarding.Preset.Subtitle.recommended(RegionalAreas.displayName(for: region)))
            .font(.body)
            .foregroundStyle(.secondary)
        } else {
          Text(L10n.Onboarding.Preset.Subtitle.locale)
            .font(.body)
            .foregroundStyle(.secondary)
        }
        Text(L10n.Settings.Radio.regulationsFooter)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      .padding(.top, OnboardingMetrics.headerTopPadding)

      ScrollView {
        VStack(spacing: OnboardingMetrics.mediumSpacing) {
          ForEach(regionalPresets) { preset in
            rowCard(preset)
          }
          if !otherRegionPresets.isEmpty {
            otherRegionsGroup
          }
          if visiblePresets.all.count > 1 {
            Text(
              (try? AttributedString(markdown: L10n.Onboarding.Preset.discordHelp))
                ?? AttributedString(L10n.Onboarding.Preset.discordHelp)
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, OnboardingMetrics.mediumSpacing)
          }
        }
        .padding(.horizontal)
      }

      Spacer()

      VStack(spacing: OnboardingMetrics.mediumSpacing) {
        linkStatusRow

        Button {
          if let id = selectedID {
            apply(id: id)
          }
        } label: {
          Text(applyCTAText)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .liquidGlassProminentButtonStyle()
        .disabled(
          Self.isApplyDisabled(
            selectedID: selectedID,
            isApplying: isApplying,
            linkStatus: linkStatus,
            refusesOverWiFi: appState.radioRefusesSettingsOverWiFi
          )
        )
        .accessibilityIdentifier("onboarding.preset.apply")

        if Self.showsSetUpLater(linkStatus: linkStatus, isWiFi: isWiFi) {
          // Settings → Radio offers the same presets, so a link problem never traps setup here.
          Button(L10n.Onboarding.Preset.setUpLater) {
            appState.completeOnboarding()
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(minHeight: OnboardingMetrics.minHitTarget)
          .accessibilityHint(L10n.Onboarding.Preset.SetUpLater.accessibilityHint)
          .accessibilityIdentifier("onboarding.preset.setUpLater")
        }
      }
      .padding(.horizontal)
      .padding(.bottom)
    }
  }

  /// Why the Use button can't write yet, and the way back to a live radio.
  @ViewBuilder
  private var linkStatusRow: some View {
    switch linkStatus {
    case .live:
      if appState.radioRefusesSettingsOverWiFi {
        // The radio said no over Wi-Fi: Set Up Later below finishes without the write.
        Label(L10n.Localizable.Error.Settings.radioSettingsOverWiFi, systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("onboarding.preset.status")
      }
    case .connecting:
      HStack(spacing: OnboardingMetrics.titleStackSpacing) {
        ProgressView()
          .controlSize(.small)
        Text(L10n.Onboarding.Preset.Status.connecting)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("onboarding.preset.status")
    case .disconnected:
      linkProblemRow(
        message: L10n.Onboarding.Preset.Status.disconnected,
        action: L10n.Onboarding.Preset.reconnect,
        identifier: "onboarding.preset.reconnect"
      ) {
        reconnect()
      }
    case .unpaired:
      linkProblemRow(
        message: L10n.Onboarding.Preset.Status.unpaired,
        action: L10n.Onboarding.Preset.pairAgain,
        identifier: "onboarding.preset.pairAgain"
      ) {
        returnToPairStep()
      }
    }
  }

  private func linkProblemRow(
    message: String,
    action: String,
    identifier: String,
    perform: @escaping () -> Void
  ) -> some View {
    VStack(spacing: OnboardingMetrics.titleStackSpacing) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("onboarding.preset.status")
      Button(action, action: perform)
        .buttonStyle(.bordered)
        .frame(minHeight: OnboardingMetrics.minHitTarget)
        .accessibilityIdentifier(identifier)
    }
  }

  private var applyCTAText: String {
    guard let preset = preset(id: selectedID) else {
      return L10n.Onboarding.Preset.continue
    }
    return L10n.Onboarding.Preset.use(preset.name)
  }

  /// Presets for elsewhere, collapsed under their own heading so none passes for local.
  private var otherRegionsGroup: some View {
    DisclosureGroup(isExpanded: $showsOtherRegions) {
      VStack(spacing: OnboardingMetrics.mediumSpacing) {
        ForEach(otherRegionPresets) { preset in
          rowCard(preset)
        }
      }
      .padding(.top, OnboardingMetrics.mediumSpacing)
    } label: {
      // Inset like the rows' titles; the rows carry their own padding.
      Text(L10n.Settings.Radio.Preset.otherRegions)
        .font(.headline)
        .padding(.leading)
        .frame(minHeight: OnboardingMetrics.minHitTarget)
    }
  }

  private func rowCard(_ preset: RadioPreset) -> some View {
    Button {
      selectedID = preset.id
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: OnboardingMetrics.compactSpacing) {
          Text(preset.name)
            .font(.body)
          Text("\(preset.frequencyMHz, format: .number.precision(.fractionLength(3)).locale(.posix)) MHz")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if selectedID == preset.id {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, minHeight: OnboardingMetrics.minHitTarget)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint(L10n.Onboarding.Preset.Row.accessibilityHint)
  }

  private func preset(id: String?) -> RadioPreset? {
    guard let id else { return nil }
    return visiblePresets.all.first { $0.id == id }
  }

  private func apply(id: String) {
    guard let preset = preset(id: id) else { return }
    // The simulator's radio takes the preset like a real one (SimulatorMockTransport), so the
    // demo radio goes through the same write and read-back.
    guard let settingsService = appState.services?.settingsService else {
      // The link dropped after pairing (or never came back after a relaunch): reconnect the
      // saved radio and apply once it is up. With none saved, say so; the status row offers
      // Pair Again.
      if appState.connectionManager.lastConnectedDeviceID != nil {
        reconnect(thenApply: id)
      } else {
        errorMessage = L10n.Onboarding.Preset.Error.notConnected
      }
      return
    }
    isApplying = true
    Task {
      do {
        _ = try await settingsService.applyRadioPresetVerified(preset)
        retryAlert.reset()
        commitTrigger.toggle()
        appState.completeOnboarding()
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { apply(id: id) },
          onMaxRetriesExceeded: {
            errorMessage = L10n.Settings.Alert.Retry.fallbackMessage
          }
        )
      } catch {
        errorMessage = RadioWriteErrorMessage.message(for: error, appState: appState)
      }
      isApplying = false
    }
  }

  /// Reconnects the saved radio the way the device picker does (WiFi or Bluetooth, failures to
  /// the connection alerts), then applies `pendingID` if the session came back and the user is
  /// still on this step.
  private func reconnect(thenApply pendingID: String? = nil) {
    guard let deviceID = appState.connectionManager.lastConnectedDeviceID else {
      returnToPairStep()
      return
    }
    appState.connectionUI.isBusy = true
    Task { @MainActor in
      await reconnectSavedRadio(deviceID)
      appState.connectionUI.isBusy = false
      guard let pendingID,
            Self.shouldApplyAfterReconnect(
              hasServices: appState.services != nil,
              isApplying: isApplying,
              hasCompletedOnboarding: appState.onboarding.hasCompletedOnboarding,
              onboardingPath: appState.onboarding.onboardingPath
            ) else { return }
      apply(id: pendingID)
    }
  }

  /// Set Up Later (or Back) while the reconnect spinner shows means the user chose not to apply
  /// the preset, so the pending write is dropped: it would change the radio after "Finishes setup
  /// without changing your device", with its error alerts on a step no longer on screen.
  static func shouldApplyAfterReconnect(
    hasServices: Bool,
    isApplying: Bool,
    hasCompletedOnboarding: Bool,
    onboardingPath: [OnboardingStep]
  ) -> Bool {
    hasServices && !isApplying && !hasCompletedOnboarding && onboardingPath.last == .preset
  }

  private func reconnectSavedRadio(_ deviceID: UUID) async {
    let connectionManager = appState.connectionManager
    if deviceID == MockDataProvider.simulatorDeviceID {
      // The mock radio has no peripheral; it reconnects the way the pair step connects it.
      do {
        try await connectionManager.simulatorConnect()
      } catch {
        appState.connectionUI.presentConnectionFailure(message: error.userFacingMessage)
      }
    } else if let device = try? await connectionManager.persistenceStore.fetchDevice(id: deviceID) {
      await appState.connectToSavedDevice(device)
    } else {
      do {
        try await connectionManager.connect(to: deviceID, forceFullSync: true, forceReconnect: true)
      } catch is CancellationError {
        // Superseded by a newer connect or a disconnect: not a failure to report.
      } catch {
        appState.connectionUI.presentSavedDeviceConnectFailure(deviceID: deviceID, error: error)
      }
    }
    if appState.services != nil {
      await appState.wireServicesIfConnected()
    }
  }

  private func returnToPairStep() {
    appState.onboarding.onboardingPath = Self.pathBackToPairStep(appState.onboarding.onboardingPath)
  }

  /// `path` cut back to the pair step, keeping the steps before it (a relaunch resumes without
  /// `.region`); a path with no pair step gets one.
  static func pathBackToPairStep(_ path: [OnboardingStep]) -> [OnboardingStep] {
    guard let pairIndex = path.lastIndex(of: .pair) else { return [.permissions, .pair] }
    return Array(path.prefix(through: pairIndex))
  }
}

#Preview {
  PresetStepView()
    .environment(\.appState, AppState())
}
