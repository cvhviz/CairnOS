import CairnServices
import SwiftUI

/// The manual radio parameters as tiles in Settings → Radio's Parameters sheet: frequency, bandwidth, spreading
/// factor, coding rate and TX power. Edits are staged on the tiles and sent together by Apply.
struct AdvancedRadioSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Binding var radioWriteInFlight: Bool
  /// Whether a staged edit hasn't been applied yet, so the sheet can ask before closing on it.
  @Binding var hasPendingChanges: Bool
  /// Runs when the retry alert gives up, in place of dismissing this view.
  var onGiveUp: (() -> Void)?
  @State private var frequency: Double? // MHz
  @State private var bandwidth: UInt32? // Hz
  @State private var spreadingFactor: Int?
  @State private var codingRate: Int?
  @State private var txPower: Int? // dBm
  @State private var hasLoaded = false
  @State private var isApplying = false
  @State private var showSuccess = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var editor: RadioValueEditor?

  private var settingsModified: Bool {
    guard let device = appState.connectedDevice else { return false }
    return frequency != Double(device.frequency) / 1000.0 ||
      bandwidth != RadioOptions.nearestBandwidth(to: device.bandwidth) ||
      spreadingFactor != Int(device.spreadingFactor) ||
      codingRate != Int(device.codingRate) ||
      txPower != Int(device.txPower)
  }

  private var canApply: Bool {
    appState.connectionState == .ready && settingsModified && !isApplying && !showSuccess
      && !radioWriteInFlight && !appState.radioRefusesSettingsOverWiFi
  }

  /// Combined hash of all radio settings for change detection
  private var deviceRadioSettingsHash: Int {
    var hasher = Hasher()
    hasher.combine(appState.connectedDevice?.frequency)
    hasher.combine(appState.connectedDevice?.bandwidth)
    hasher.combine(appState.connectedDevice?.spreadingFactor)
    hasher.combine(appState.connectedDevice?.codingRate)
    hasher.combine(appState.connectedDevice?.txPower)
    hasher.combine(appState.connectedDevice?.clientRepeat)
    return hasher.finalize()
  }

  var body: some View {
    CardFormSection(L10n.Settings.Radio.Parameters.header, footer: L10n.Settings.AdvancedRadio.footer) {
      if !hasLoaded {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
      } else {
        // Balanced rows: five tiles on a phone are 2 + 2 + a full-width TX Power, not a hole.
        MetricTileGrid {
          tiles
        }
        applyCard
        // Apply always sends the frequency settings, which this radio has refused over Wi-Fi.
        if appState.radioRefusesSettingsOverWiFi {
          Text(L10n.Localizable.Error.Settings.radioSettingsOverWiFi)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .sheet(item: $editor) { editor in
      switch editor {
      case .frequency:
        RadioFrequencyEditor(frequency: frequency) { frequency = $0 }
      case .txPower:
        RadioTxPowerEditor(
          txPower: txPower ?? Int(appState.connectedDevice?.txPower ?? 0),
          maximum: Int(appState.connectedDevice?.maxTxPower ?? PacketBuilder.txPowerFloor),
          model: appState.connectedDevice?.manufacturerName ?? ""
        ) { txPower = $0 }
      }
    }
    .onAppear {
      loadCurrentSettings()
      hasPendingChanges = settingsModified
    }
    .onChange(of: settingsModified) { _, modified in
      hasPendingChanges = modified
    }
    .onChange(of: deviceRadioSettingsHash) { _, _ in
      // Skip reloads only while this apply is in flight. Frequency and clientRepeat
      // arrive as separate events; reloading that intermediate state flickers the field.
      guard !isApplying else { return }
      if showSuccess, settingsModified {
        withAnimation {
          showSuccess = false
        }
      }
      loadCurrentSettings()
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  /// Sends every staged tile value together.
  private var applyCard: some View {
    ApplyCard(
      title: L10n.Settings.AdvancedRadio.apply,
      isLoading: isApplying,
      showSuccess: showSuccess,
      canApply: canApply,
      action: applySettings
    )
    .radioDisabled(
      for: appState.connectionState,
      or: isApplying || showSuccess || !settingsModified || radioWriteInFlight
        || appState.radioRefusesSettingsOverWiFi
    )
  }

  // MARK: - Tiles

  /// Each setting's current value as a tile. Edits are staged here and sent together by Apply,
  /// so a tile showing a staged value says it isn't applied yet.
  @ViewBuilder
  private var tiles: some View {
    let device = appState.connectedDevice
    let isRepeat = device?.clientRepeat == true

    Button {
      editor = .frequency
    } label: {
      RadioSettingTile(
        L10n.Settings.Radio.Tile.frequency,
        systemImage: "waveform",
        value: frequency.map { L10n.Settings.Dashboard.frequency($0.formatted(.number.precision(.fractionLength(3)))) } ?? "—",
        captions: isRepeat ? [L10n.Settings.Radio.Tile.setByRepeatMode] : [],
        editStyle: .sheet,
        isPending: device.map { frequency != Double($0.frequency) / 1000.0 } ?? false,
        accessibilityHint: L10n.Settings.Radio.Tile.stagedHint
      )
    }
    .buttonStyle(.plain)
    .disabled(isRepeat)
    .radioDisabled(for: appState.connectionState, or: isApplying)

    Menu {
      Picker(L10n.Settings.AdvancedRadio.bandwidth, selection: $bandwidth) {
        ForEach(RadioOptions.bandwidthsHz, id: \.self) { bwHz in
          Text(L10n.Settings.Radio.Tile.bandwidthValue(RadioOptions.formatBandwidth(bwHz)))
            .tag(bwHz as UInt32?)
            .accessibilityLabel(L10n.Settings.AdvancedRadio.Accessibility.bandwidthLabel(RadioOptions.formatBandwidth(bwHz)))
        }
      }
    } label: {
      RadioSettingTile(
        L10n.Settings.Radio.Tile.bandwidth,
        systemImage: "arrow.left.and.right",
        value: bandwidth.map { L10n.Settings.Radio.Tile.bandwidthValue(RadioOptions.formatBandwidth($0)) } ?? "—",
        editStyle: .menu,
        isPending: device.map { bandwidth != RadioOptions.nearestBandwidth(to: $0.bandwidth) } ?? false,
        accessibilityHint: L10n.Settings.AdvancedRadio.Accessibility.bandwidthHint
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState, or: isApplying)

    Menu {
      Picker(L10n.Settings.AdvancedRadio.spreadingFactor, selection: $spreadingFactor) {
        ForEach(RadioOptions.spreadingFactors, id: \.self) { spreadFactorOption in
          Text(spreadFactorOption, format: .number)
            .tag(spreadFactorOption as Int?)
            .accessibilityLabel(L10n.Settings.AdvancedRadio.Accessibility.spreadingFactorLabel(spreadFactorOption))
        }
      }
    } label: {
      RadioSettingTile(
        L10n.Settings.AdvancedRadio.spreadingFactor,
        systemImage: "chart.bar.fill",
        value: spreadingFactor.map { "SF\($0)" } ?? "—",
        editStyle: .menu,
        isPending: device.map { spreadingFactor != Int($0.spreadingFactor) } ?? false,
        accessibilityHint: L10n.Settings.AdvancedRadio.Accessibility.spreadingFactorHint
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState, or: isApplying)

    Menu {
      Picker(L10n.Settings.AdvancedRadio.codingRate, selection: $codingRate) {
        ForEach(RadioOptions.codingRates, id: \.self) { codeRateOption in
          Text("4/\(codeRateOption)")
            .tag(codeRateOption as Int?)
            .accessibilityLabel(L10n.Settings.AdvancedRadio.Accessibility.codingRateLabel(codeRateOption))
        }
      }
    } label: {
      RadioSettingTile(
        L10n.Settings.AdvancedRadio.codingRate,
        systemImage: "checkmark.shield",
        value: codingRate.map { "4/\($0)" } ?? "—",
        editStyle: .menu,
        isPending: device.map { codingRate != Int($0.codingRate) } ?? false,
        accessibilityHint: L10n.Settings.AdvancedRadio.Accessibility.codingRateHint
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState, or: isApplying)

    Button {
      editor = .txPower
    } label: {
      txPowerTile(device: device)
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState, or: isApplying)
  }

  /// TX power: on a board with a known amplifier (`RadioAmplifier`) the headline is the power at the
  /// antenna and the radio chip's setting (what is sent, what the radio reports) is the caption; on
  /// any other board the two are the same and the setting shows alone.
  private func txPowerTile(device: DeviceDTO?) -> some View {
    let maximum = device.map { Int($0.maxTxPower) }
    let model = device?.manufacturerName ?? ""
    let amplified = RadioAmplifier.hasAmplifier(model: model)
    let dBm = { (value: Int) in L10n.Settings.DeviceInfo.txPowerFormat(value.formatted()) }
    var captions: [String] = []
    if amplified, let txPower {
      captions.append(L10n.Settings.Radio.TxPower.antennaCaption(dBm(txPower)))
    }
    if let maximum {
      captions.append(L10n.Settings.Dashboard.maxTxPower(dBm(RadioAmplifier.antennaMaxTxPower(reportedMax: maximum, model: model))))
    }
    let floor = Int(PacketBuilder.txPowerFloor)
    return RadioSettingTile(
      L10n.Settings.Dashboard.txPower,
      systemImage: "bolt.fill",
      value: txPower.map { dBm(RadioAmplifier.effectiveTxPower(reported: $0, model: model)) } ?? "—",
      captions: captions,
      editStyle: .sheet,
      isPending: device.map { txPower != Int($0.txPower) } ?? false,
      accessibilityHint: L10n.Settings.Radio.Tile.stagedHint
    ) {
      if let txPower, let maximum, maximum > floor {
        // the setting's place between the chip's floor (-9) and the radio's maximum
        MeterBar(fraction: Double(txPower - floor) / Double(maximum - floor), tint: .accentColor)
      }
    }
  }

  private func loadCurrentSettings() {
    guard let device = appState.connectedDevice else { return }
    frequency = Double(device.frequency) / 1000.0
    // Use nearestBandwidth to handle devices with non-standard bandwidth values
    // or firmware float precision issues (e.g., 7799 Hz instead of 7800 Hz)
    bandwidth = RadioOptions.nearestBandwidth(to: device.bandwidth)
    spreadingFactor = Int(device.spreadingFactor)
    codingRate = Int(device.codingRate)
    txPower = Int(device.txPower)
    hasLoaded = true
  }

  private func applySettings() {
    guard !radioWriteInFlight else { return }
    guard let freqMHz = frequency,
          let bandwidthHz = bandwidth,
          let spreadFactor = spreadingFactor,
          let codeRate = codingRate,
          let power = txPower,
          let settingsService = appState.services?.settingsService else {
      errorMessage = L10n.Settings.AdvancedRadio.invalidInput
      return
    }

    // Pickers enforce bandwidth, SF, and CR; frequency and TX power are free-text, so
    // validate them with non-trapping conversions before scaling into the wire fields.
    let scaledFreqKHz = (freqMHz * 1000).rounded()
    let freqInRange = freqMHz.isFinite
      && scaledFreqKHz >= Double(PacketBuilder.frequencyRangeKHz.lowerBound)
      && scaledFreqKHz <= Double(PacketBuilder.frequencyRangeKHz.upperBound)
    let maxTxPower = appState.connectedDevice?.maxTxPower ?? PacketBuilder.txPowerFloor
    guard freqInRange,
          let frequencyKHz = UInt32(exactly: scaledFreqKHz),
          let spreadFactorByte = UInt8(exactly: spreadFactor),
          let codeRateByte = UInt8(exactly: codeRate),
          let powerLevel = Int8(exactly: power),
          powerLevel >= PacketBuilder.txPowerFloor,
          powerLevel <= maxTxPower else {
      errorMessage = L10n.Settings.AdvancedRadio.invalidInput
      return
    }

    isApplying = true
    radioWriteInFlight = true
    Task {
      var failedStep: String?
      do {
        guard let device = appState.connectedDevice else {
          throw ConnectionError.notConnected
        }

        // Firmware treats an omitted repeat byte as Repeat Mode off. Read clientRepeat
        // and frequency from the radio at this call, not before the Task.
        let frequencyKHzToSend = device.clientRepeat ? device.frequency : frequencyKHz

        // Each write is named in its error, so a failure says which step the radio refused.
        failedStep = L10n.Settings.Radio.Parameters.header
        _ = try await settingsService.setRadioParamsVerified(
          frequencyKHz: frequencyKHzToSend,
          // Note: Parameter is misleadingly named "bandwidthKHz" but expects Hz.
          // bandwidthHz is already UInt32 Hz from the picker, pass directly.
          bandwidthKHz: bandwidthHz,
          spreadingFactor: spreadFactorByte,
          codingRate: codeRateByte,
          clientRepeat: device.clientRepeat
        )

        // Then set TX power
        failedStep = L10n.Settings.Dashboard.txPower
        _ = try await settingsService.setTxPowerVerified(powerLevel)
        failedStep = nil

        retryAlert.reset()
        isApplying = false
        radioWriteInFlight = false
        hasPendingChanges = false

        // Show success checkmark briefly
        withAnimation {
          showSuccess = true
        }
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation {
          showSuccess = false
        }
        return // Skip the isApplying = false at the end
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: Self.stepMessage(failedStep, error.userFacingMessage),
          onRetry: { applySettings() },
          onMaxRetriesExceeded: { onGiveUp?() ?? dismiss() }
        )
      } catch {
        errorMessage = Self.stepMessage(
          failedStep,
          RadioWriteErrorMessage.message(for: error, appState: appState)
        )
      }
      isApplying = false
      radioWriteInFlight = false
    }
  }

  /// "TX Power: Command not supported by device firmware." — the step the radio refused, before
  /// its reason.
  private static func stepMessage(_ step: String?, _ message: String) -> String {
    guard let step else { return message }
    return L10n.Settings.AdvancedRadio.stepError(step, message)
  }
}
