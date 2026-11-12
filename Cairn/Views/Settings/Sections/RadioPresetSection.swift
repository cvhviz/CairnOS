import CairnServices
import SwiftUI

/// The radio preset and Repeat Mode as the cards of Settings → Radio's Preset sheet. The preset card
/// opens a menu of the Location's presets, with every other preset apart under "Other regions";
/// picking one applies it at once.
struct RadioPresetSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Binding var radioWriteInFlight: Bool
  /// Runs when the retry alert gives up, in place of dismissing this view; the Radio page passes
  /// one that closes the sheet and leaves the page, as giving up did before the page had sheets.
  var onGiveUp: (() -> Void)?
  @State private var selectedPresetID: String?
  @State private var isApplying = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var isRepeatEnabled: Bool = false
  @State private var isApplyingRepeat = false
  @State private var showRepeatConfirmation = false
  @State private var isProgrammaticRepeatToggle = false

  private var presets: RadioPresets.VisiblePresets {
    RadioPresets.visiblePresets(for: appState.regionSelection)
  }

  private var repeatPresets: [RadioPreset] {
    RadioPresets.repeatPresets
  }

  private var currentPreset: RadioPreset? {
    guard let device = appState.connectedDevice else { return nil }
    return RadioPresets.resolvedPreset(
      frequencyKHz: device.frequency,
      bandwidthKHz: device.bandwidth,
      spreadingFactor: device.spreadingFactor,
      codingRate: device.codingRate,
      preferredID: device.appliedRadioPresetID,
      region: appState.regionSelection
    )
  }

  /// Finds the repeat preset closest to the device's current frequency.
  private var closestRepeatPreset: RadioPreset? {
    guard let device = appState.connectedDevice else { return nil }
    return RadioPresets.nearestRepeatPreset(toFrequencyKHz: device.frequency)
  }

  /// Matches the device's current radio params against repeat presets.
  private var currentRepeatPreset: RadioPreset? {
    guard let device = appState.connectedDevice else { return nil }
    return RadioPresets.matchingRepeatPreset(frequencyKHz: device.frequency)
  }

  private var currentMatchingPresetID: String? {
    isRepeatEnabled ? currentRepeatPreset?.id : currentPreset?.id
  }

  /// The selected preset's name, "Custom" when the radio matches none.
  private var selectedPresetName: String {
    let candidates = isRepeatEnabled ? repeatPresets : presets.all
    return candidates.first { $0.id == selectedPresetID }?.name ?? L10n.Settings.BatteryCurve.custom
  }

  /// Which list the preset came from: the Repeat Mode band, the location the list is filtered
  /// to, or, for a preset from "Other regions", that preset's own region, so a preset for
  /// elsewhere never reads as one for the Location.
  private var presetCaption: String? {
    if isRepeatEnabled {
      return repeatPresets.first { $0.id == selectedPresetID }?.repeatSectionHeader
    }
    if let foreign = presets.otherRegions.first(where: { $0.id == selectedPresetID }) {
      return foreign.region.localizedName
    }
    return appState.regionSelection.map { L10n.Settings.Radio.regionFooter(RegionalAreas.displayName(for: $0)) }
  }

  /// Why the card is dimmed while the radio can't take a preset yet, so a tap that does nothing
  /// isn't a mystery; nil once the radio is ready, unless it has refused radio settings over
  /// this Wi-Fi link.
  private var unavailableReason: String? {
    switch appState.connectionState {
    case .ready: appState.radioRefusesSettingsOverWiFi ? L10n.Localizable.Error.Settings.radioSettingsOverWiFi : nil
    case .syncing: L10n.Settings.Radio.Preset.Unavailable.syncing
    case .connecting, .connected: L10n.Settings.Radio.Preset.Unavailable.connecting
    case .disconnected: L10n.Settings.Radio.Preset.Unavailable.disconnected
    }
  }

  /// Choosing a preset, and what Repeat Mode does when the radio offers it.
  private var presetInfo: String {
    guard appState.connectedDevice?.supportsClientRepeat == true else { return L10n.Settings.Radio.footer }
    return L10n.Settings.Radio.footer + "\n\n"
      + L10n.Settings.Radio.RepeatMode.info(L10n.Settings.Radio.RepeatMode.footer)
  }

  var body: some View {
    // Radio-law compliance stays visible as the footer; the rest is behind the header's "i".
    CardFormSection(L10n.Settings.Radio.preset, info: presetInfo, footer: L10n.Settings.Radio.regulationsFooter) {
      presetCard
      if appState.connectedDevice?.supportsClientRepeat == true {
        repeatCard
      }
    }
    // Only the menu's pick (`presetSelection`) applies a preset; every assignment below just shows
    // what the radio holds, so none of them can write to it.
    .onChange(of: isRepeatEnabled) { _, newValue in
      // A programmatic flip is consumed here so only a user's tap drives confirm/disable.
      if isProgrammaticRepeatToggle {
        isProgrammaticRepeatToggle = false
        return
      }
      if newValue {
        // Hold the toggle off until the user confirms; the revert is programmatic.
        setRepeatToggle(false)
        showRepeatConfirmation = true
      } else {
        disableRepeatMode()
      }
    }
    .onAppear {
      setRepeatToggle(appState.connectedDevice?.clientRepeat ?? false)
      selectedPresetID = currentMatchingPresetID
    }
    .onChange(of: currentPreset?.id) { _, newPresetID in
      guard !isRepeatEnabled else { return }
      if let selected = selectedPresetID,
         let device = appState.connectedDevice,
         RadioPresets.matchingPresets(
           frequencyKHz: device.frequency,
           bandwidthKHz: device.bandwidth,
           spreadingFactor: device.spreadingFactor,
           codingRate: device.codingRate
         ).contains(where: { $0.id == selected }) {
        return
      }
      selectedPresetID = newPresetID
    }
    .onChange(of: currentRepeatPreset?.id) { _, newPresetID in
      guard isRepeatEnabled else { return }
      selectedPresetID = newPresetID
    }
    .onChange(of: appState.connectedDevice?.clientRepeat) { _, newValue in
      let newRepeatEnabled = newValue ?? false
      if newRepeatEnabled != isRepeatEnabled {
        setRepeatToggle(newRepeatEnabled)
        selectedPresetID = currentMatchingPresetID
      }
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
    .alert(L10n.Settings.Radio.RepeatMode.Confirm.title, isPresented: $showRepeatConfirmation) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.Radio.RepeatMode.Confirm.enable) {
        enableRepeatMode()
      }
    } message: {
      Text(L10n.Settings.Radio.RepeatMode.Confirm.message)
    }
  }

  // MARK: - Cards

  /// The menu's selection. Its setter runs only for the user's pick, so a pick is the one thing
  /// that applies a preset: the radio's own updates and a failed write's revert set
  /// `selectedPresetID` directly and never write to the radio. Picking the preset already shown,
  /// or Custom, writes nothing, except a preset whose path hash size didn't land: picking it again
  /// is the retry its error offers.
  private var presetSelection: Binding<String?> {
    Binding(
      get: { selectedPresetID },
      set: { newID in
        guard newID != selectedPresetID || hashSizeNotApplied(presetID: newID) else { return }
        selectedPresetID = newID
        if let newID {
          applyPreset(id: newID)
        }
      }
    )
  }

  /// Whether the radio is on this preset's channel without its path hash size: the hash write
  /// failed after the frequency settings landed. The card shows the preset, so picking it again
  /// is the retry. Read from the radio, not view state, so it holds after the sheet closes. A
  /// radio without path hash sizes never takes one, so re-picking there writes nothing.
  private func hashSizeNotApplied(presetID: String?) -> Bool {
    guard !isRepeatEnabled,
          let presetID,
          let mode = presets.all.first(where: { $0.id == presetID })?.pathHashMode,
          let device = appState.connectedDevice,
          device.supportsPathHashMode else { return false }
    return device.pathHashMode != mode
  }

  /// The preset as a card that opens the preset menu: picking one applies it to the radio at once.
  private var presetCard: some View {
    Menu {
      Picker(L10n.Settings.Radio.preset, selection: presetSelection) {
        if isRepeatEnabled {
          Text(L10n.Settings.BatteryCurve.custom).tag(nil as String?)
          ForEach(repeatPresets) { preset in
            Section(preset.repeatSectionHeader ?? "") {
              Text(preset.name).tag(preset.id as String?)
            }
          }
        } else {
          // Only show Custom when device is not using a preset
          if currentPreset == nil {
            Text(L10n.Settings.BatteryCurve.custom).tag(nil as String?)
          }

          ForEach(RadioRegion.allCases, id: \.self) { region in
            let regionPresets = presets.regional.filter { $0.region == region }
            if !regionPresets.isEmpty {
              Section(region.localizedName) {
                ForEach(regionPresets) { preset in
                  Text(preset.name).tag(preset.id as String?)
                }
              }
            }
          }

          // Presets for elsewhere, last and under their own heading so none passes for local.
          if !presets.otherRegions.isEmpty {
            Section(L10n.Settings.Radio.Preset.otherRegions) {
              ForEach(presets.otherRegions) { preset in
                Text(preset.name).tag(preset.id as String?)
              }
            }
          }
        }
      }
    } label: {
      HStack(spacing: 12) {
        IconTile(systemImage: "dial.medium.fill", color: .blue)
          .accessibilityHidden(true)
        // The section header names the card, so it leads with the preset itself.
        VStack(alignment: .leading, spacing: 2) {
          Text(selectedPresetName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          if let presetCaption {
            Text(presetCaption)
              .font(.caption)
              .foregroundStyle(Color.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let unavailableReason {
            Text(unavailableReason)
              .font(.caption)
              .foregroundStyle(Color.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
        if isApplying {
          ProgressView()
        }
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
      .dimmedWhenDisabled()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(L10n.Settings.Radio.preset)
      .accessibilityValue(
        [selectedPresetName, presetCaption, unavailableReason].compactMap(\.self).joined(separator: ", ")
      )
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Settings.Radio.Preset.hint)
    .radioDisabled(for: appState.connectionState, or: isWriteBlocked)
  }

  /// A write is under way, or the radio has refused radio settings over this Wi-Fi link (the
  /// card's caption says so) and would refuse the next one too.
  private var isWriteBlocked: Bool {
    isApplying || isApplyingRepeat || radioWriteInFlight || appState.radioRefusesSettingsOverWiFi
  }

  /// Repeat Mode as a card-sized switch, beside the preset it swaps the menu's list for.
  private var repeatCard: some View {
    ToggleCard(
      L10n.Settings.Radio.repeatMode,
      systemImage: "repeat",
      color: AppColors.Radio.repeatMode,
      isOn: $isRepeatEnabled
    )
    .accessibilityHint(L10n.Settings.Radio.RepeatMode.accessibilityHint)
    .dimmedWhenDisabled()
    // Like the preset card: live only while the radio can take a write.
    .radioDisabled(for: appState.connectionState, or: isWriteBlocked)
  }

  private func applyPreset(id: String) {
    let allPresets = isRepeatEnabled ? repeatPresets : presets.all
    guard let preset = allPresets.first(where: { $0.id == id }) else {
      radioWriteInFlight = false
      return
    }

    isApplying = true
    radioWriteInFlight = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }
        if isRepeatEnabled {
          guard let device = appState.connectedDevice else {
            throw ConnectionError.notConnected
          }
          // Repeat Mode changes only the frequency; bandwidth/SF/CR stay as the device's current values.
          _ = try await settingsService.setRadioParamsVerified(
            frequencyKHz: preset.frequencyKHz,
            bandwidthKHz: device.bandwidth,
            spreadingFactor: device.spreadingFactor,
            codingRate: device.codingRate,
            clientRepeat: true
          )
        } else {
          _ = try await settingsService.applyRadioPresetVerified(preset)
        }
        retryAlert.reset()
      } catch {
        // A failed Repeat Mode switch-on leaves the radio on its normal params: put the switch
        // back off and drop the saved pre-repeat settings, so the page doesn't claim Repeat Mode.
        let wasEnablingRepeat = isRepeatEnabled && appState.connectedDevice?.clientRepeat != true
        if wasEnablingRepeat {
          setRepeatToggle(false)
          appState.connectionManager.clearPreRepeatSettings()
        }
        // Back to what the radio holds. When the radio took part of the preset (its frequency
        // settings but not its path hash size), the device update already sent moves this on to
        // the new settings through onChange(of: currentPreset?.id), whichever lands first.
        selectedPresetID = currentMatchingPresetID
        if let retryable = error as? SettingsServiceError, retryable.isRetryable {
          retryAlert.show(
            message: retryable.userFacingMessage,
            onRetry: { wasEnablingRepeat ? enableRepeatMode() : applyPreset(id: id) },
            onMaxRetriesExceeded: { onGiveUp?() ?? dismiss() }
          )
        } else {
          errorMessage = RadioWriteErrorMessage.message(for: error, appState: appState)
        }
      }
      isApplying = false
      radioWriteInFlight = false
    }
  }

  private func enableRepeatMode() {
    guard let preset = closestRepeatPreset else { return }

    radioWriteInFlight = true

    // Persist current radio settings to Device model before switching
    appState.connectionManager.savePreRepeatSettings()

    // Swap picker to repeat presets and select closest frequency, then write it once the toggle's
    // programmatic flip has been consumed.
    setRepeatToggle(true)
    selectedPresetID = preset.id
    Task { @MainActor in
      applyPreset(id: preset.id)
    }
  }

  /// Flips the Repeat Mode toggle programmatically. The toggle's onChange consumes the flag
  /// so the confirm/disable handler runs only for a user's tap, never for our own writes.
  private func setRepeatToggle(_ value: Bool) {
    guard isRepeatEnabled != value else { return }
    isProgrammaticRepeatToggle = true
    isRepeatEnabled = value
  }

  private func disableRepeatMode() {
    guard let device = appState.connectedDevice else { return }
    isApplyingRepeat = true
    radioWriteInFlight = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }

        // Restore saved radio settings, or fall back to current params
        let freq = device.preRepeatFrequency ?? device.frequency
        let bw = device.preRepeatBandwidth ?? device.bandwidth
        let sf = device.preRepeatSpreadingFactor ?? device.spreadingFactor
        let cr = device.preRepeatCodingRate ?? device.codingRate

        _ = try await settingsService.setRadioParamsVerified(
          frequencyKHz: freq,
          bandwidthKHz: bw,
          spreadingFactor: sf,
          codingRate: cr,
          clientRepeat: false
        )

        // Clear persisted pre-repeat settings
        appState.connectionManager.clearPreRepeatSettings()

        // Swap picker back to normal presets
        selectedPresetID = currentPreset?.id
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        setRepeatToggle(true) // Revert
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { disableRepeatMode() },
          onMaxRetriesExceeded: { onGiveUp?() ?? dismiss() }
        )
      } catch {
        errorMessage = RadioWriteErrorMessage.message(for: error, appState: appState)
        setRepeatToggle(true) // Revert
      }
      isApplyingRepeat = false
      radioWriteInFlight = false
    }
  }
}

extension RadioPresetSection {
  /// Re-read when the radio or its sync state changes. The page runs the read, not the section, so
  /// it happens on arrival rather than only once the Preset sheet opens.
  static func startupTaskID(_ appState: AppState) -> String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    let syncPhase = appState.connectionUI.currentSyncPhase.map { String(describing: $0) } ?? "none"
    return "\(deviceID)-\(String(describing: appState.connectionState))-\(syncPhase)"
  }

  /// Reads the radio's self info and publishes it, so the preset and parameters show what the
  /// radio holds: after a change made on the radio itself, or a write it took that the app
  /// counted as failed. The device keeps its stamped preset id while the settings still match it.
  /// - Returns: Whether the read failed, so the page can say its values are the last known ones
  ///   (`RadioReadFootnote`); false too when there was nothing to read.
  @discardableResult
  static func startupRead(_ appState: AppState) async -> Bool {
    guard appState.canRunSettingsStartupReads,
          let settingsService = appState.services?.settingsService else { return false }
    do {
      try await settingsService.refreshDeviceInfo()
      return false
    } catch {
      return true
    }
  }
}

private extension RadioRegion {
  /// The region's name in the user's language; the raw value is a fixed English identifier.
  var localizedName: String {
    switch self {
    case .northAmerica: L10n.Settings.Radio.Region.northAmerica
    case .southAmerica: L10n.Settings.Radio.Region.southAmerica
    case .europe: L10n.Settings.Radio.Region.europe
    case .oceania: L10n.Settings.Radio.Region.oceania
    case .asia: L10n.Settings.Radio.Region.asia
    }
  }
}
