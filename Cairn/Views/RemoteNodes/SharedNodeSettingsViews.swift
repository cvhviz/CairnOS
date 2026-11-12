import CairnServices
import SwiftUI

// MARK: - Unified Focus Field

enum NodeSettingsField: Hashable {
  case frequency, advertInterval, floodAdvertInterval, floodMaxHops
  case identityName, contactInfo, guestPassword
}

// MARK: - Coordinate Field

/// Latitude/longitude entry that saves on every keystroke. A `TextField(value:format:)` only
/// commits on Return or focus loss, so tapping Apply mid-edit sent the previous value, which is
/// how a typed southern latitude could end up positive on the repeater (#346).
struct CoordinateTextField: View {
  let title: String
  let value: Double
  let onChange: (Double) -> Void

  @State private var text = ""

  var body: some View {
    TextField(title, text: $text)
      .keyboardType(.numbersAndPunctuation)
      .multilineTextAlignment(.trailing)
      .frame(width: 140)
      .onAppear { text = Self.format(value) }
      // Picking on the map changes the value from outside; show it unless it's what was typed.
      .onChange(of: value) { _, newValue in
        if Self.parse(text) != newValue { text = Self.format(newValue) }
      }
      .onChange(of: text) { _, newText in
        if let parsed = Self.parse(newText), parsed != value { onChange(parsed) }
      }
  }

  static func format(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(6)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
  }

  /// Accepts the Unicode minus some keyboards and locales insert, and a comma decimal separator.
  static func parse(_ text: String) -> Double? {
    let normalized = text
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "\u{2212}", with: "-")
      .replacingOccurrences(of: ",", with: ".")
    return Double(normalized)
  }
}

// MARK: - Card Rows

/// A whole-number setting inside a settings card ("Advert interval … 60 min"): the field once the
/// value has loaded, the load placeholder until then, and its validation error under it.
struct NodeIntegerFieldRow: View {
  let title: String
  let unit: String
  let value: Int?
  let onChange: @MainActor (Int) -> Void
  let field: NodeSettingsField
  var focusedField: FocusState<NodeSettingsField?>.Binding
  let isLoading: Bool
  let hasError: Bool
  let error: String?

  var body: some View {
    CardFieldRow(title: title) {
      if let value {
        TextField(unit, value: Binding(get: { value }, set: onChange), format: .number)
          .keyboardType(.numberPad)
          .multilineTextAlignment(.trailing)
          .frame(width: 60)
          .focused(focusedField, equals: field)
        Text(unit)
          .foregroundStyle(.secondary)
      } else {
        SettingsLoadPlaceholder(isLoading: isLoading, hasError: hasError)
      }
    }

    if let error {
      NodeFieldError(error)
    }
  }
}

/// A field's validation error, under the field inside its card.
struct NodeFieldError: View {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var body: some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.red)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// How a field fared in the last Apply (`NodeFieldResult`), under the field: the node's refusal in
/// red (`NodeFieldError`), or a small green "Applied".
struct NodeFieldResultLabel: View {
  let result: NodeFieldResult?

  var body: some View {
    switch result {
    case .none:
      EmptyView()
    case let .failed(message):
      NodeFieldError(L10n.RemoteNodes.RemoteNodes.Settings.fieldFailed(message))
    case .applied:
      Label(L10n.RemoteNodes.RemoteNodes.Settings.fieldApplied, systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// "Revert" at the foot of a settings card, beside Apply: puts the fields back to the node's values.
struct NodeRevertButton: View {
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(L10n.RemoteNodes.RemoteNodes.Settings.revert, systemImage: "arrow.uturn.backward", action: action)
      .buttonStyle(.borderless)
      .font(.subheadline)
      .disabled(!isEnabled)
  }
}

/// The Apply button at the foot of a settings card: accent while there are edits to send, a
/// spinner while sending, a checkmark once sent.
struct NodeApplyButton: View {
  let title: String
  let isLoading: Bool
  let showSuccess: Bool
  /// Draws the title in the accent color; otherwise secondary, as the old rows did.
  let isActive: Bool
  let isDisabled: Bool
  let action: () async -> Void

  var body: some View {
    Button {
      Task { await action() }
    } label: {
      AsyncActionLabel(isLoading: isLoading, showSuccess: showSuccess) {
        Text(title)
          .foregroundStyle(isActive ? Color.accentColor : .secondary)
          .transition(.opacity)
      }
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
  }
}

// MARK: - Device Info Section

/// The node's firmware and clock, as tiles under a fold-away card. The tiles follow the card
/// rather than sitting on it, so they aren't drawn as cards on a card.
struct NodeDeviceInfoSection: View {
  /// Clock drift below this magnitude is normal RTC scatter and not shown.
  private static let clockDriftWarningThreshold: TimeInterval = 300

  @Bindable var settings: NodeSettingsViewModel
  /// The Bluetooth update's sheet, made when opened.
  @State private var nordicUpdate: NordicFirmwareUpdateModel?

  var body: some View {
    let failed = settings.deviceInfoError && !settings.deviceInfoLoaded
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.deviceInfo,
      icon: "info",
      color: .gray,
      hasContent: false,
      isExpanded: $settings.isDeviceInfoExpanded,
      isLoaded: { settings.deviceInfoLoaded },
      isLoading: $settings.isLoadingDeviceInfo,
      hasError: $settings.deviceInfoError,
      onLoad: { await settings.fetchDeviceInfo() }
    ) {
      EmptyView()
    }

    if settings.isDeviceInfoExpanded, !failed {
      firmwareCard
      detailsCard

      // A bootloader that starts new firmware without a reset: say so before an update leaves the
      // node off the mesh until someone presses its button.
      if settings.bootloaderNeedsManualRestart {
        Label(L10n.RemoteNodes.RemoteNodes.Settings.bootloaderNeedsReset, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let drift = significantDrift {
        Label(clockDriftWarning(drift), systemImage: "clock.badge.exclamationmark")
          .font(.footnote)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var parts: FirmwareVersionParts? {
    settings.firmwareVersion.map(FirmwareVersionParts.init)
  }

  /// Whether the latest Cairn release is newer than this build; nil when either isn't known.
  private var updateAvailable: Bool? {
    FirmwareUpdateCheck.updateAvailable(installed: settings.firmwareVersion, latestBuild: LatestFirmwareBuildCache.latestBuild())
  }

  /// The firmware in full (the user, 2026-11-09: the half-width tile cut it short): the build large,
  /// whether it's current at the far end, what it's based on and when it was built under it, then the
  /// way to update it when there is one.
  private var firmwareCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        IconTile(systemImage: "cpu", color: parts?.cairnBuild == nil ? .gray : .teal)
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.RemoteNodes.RemoteNodes.Settings.firmware)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
          Text(parts?.short ?? NodeStatusViewModel.emDash)
            .font(.title2.weight(.bold))
            .foregroundStyle(parts == nil ? Color.secondary : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        Spacer(minLength: 8)
        switch updateAvailable {
        case true?:
          NodeStatusCapsule(text: L10n.RemoteNodes.RemoteNodes.Settings.updateAvailable, tint: .orange)
            .fixedSize()
        case false?:
          NodeStatusCapsule(text: L10n.Settings.FirmwareUpdate.upToDate, tint: AppColors.Radio.readyText)
            .fixedSize()
        case nil:
          EmptyView()
        }
      }
      if let detail = parts?.detail {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if let parts, parts.short != parts.raw {
        // a version string this can't take apart: as the node gave it
        Text(parts.raw)
          .font(.subheadline.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      // An nRF52 repeater the app can update over Bluetooth, from the latest release.
      if let target = settings.nordicUpdateTarget {
        Button {
          nordicUpdate = NordicFirmwareUpdateModel(
            target: target,
            installed: settings.firmwareVersion,
            mode: .repeater(startOTA: { [settings] in try await settings.sendAndWait("start ota") })
          )
        } label: {
          Label(L10n.Settings.FirmwareUpdate.Nordic.updateRepeater, systemImage: "arrow.down.circle")
            .frame(maxWidth: .infinity)
        }
        .liquidGlassSecondaryButtonStyle()
        .accessibilityIdentifier("node.deviceInfo.updateFirmware")
        .sheet(item: $nordicUpdate) { model in
          NordicRepeaterUpdateSheet(model: model)
        }
      } else if updateAvailable == true, settings.isESP32CairnBoard {
        Label(L10n.RemoteNodes.RemoteNodes.Settings.updateViaWebFlasher, systemImage: "globe")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
    .accessibilityElement(children: .contain)
  }

  /// The rest, one fact to a row with a hairline between: the node's clock (and how far off it is)
  /// and its bootloader.
  private var detailsCard: some View {
    VStack(spacing: 0) {
      detailRow(
        L10n.RemoteNodes.RemoteNodes.Settings.deviceTime,
        systemImage: "clock",
        color: .teal,
        value: settings.deviceTime ?? NodeStatusViewModel.emDash,
        caption: significantDrift.map(clockDriftCaption),
        warns: significantDrift != nil
      )
      if let bootloader = settings.bootloaderVersion {
        Divider()
          .padding(.leading, 52)
        detailRow(
          L10n.RemoteNodes.RemoteNodes.Settings.bootloader,
          systemImage: "memorychip",
          color: .gray,
          value: bootloader,
          caption: nil,
          warns: settings.bootloaderNeedsManualRestart
        )
      }
    }
    .cardSurface(padding: 0)
  }

  private func detailRow(
    _ title: String, systemImage: String, color: Color, value: String, caption: String?, warns: Bool
  ) -> some View {
    HStack(spacing: 12) {
      IconTile(systemImage: systemImage, color: color)
      Text(title)
        .font(.body)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 1) {
        HStack(spacing: 4) {
          if warns {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          Text(value)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        if let caption {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }

  /// The clock drift when it's large enough to warn about.
  private var significantDrift: TimeInterval? {
    guard let drift = settings.clockDrift, abs(drift) >= Self.clockDriftWarningThreshold else { return nil }
    return drift
  }

  private func clockDriftCaption(_ drift: TimeInterval) -> String {
    let magnitude = Self.driftMagnitude(drift)
    return drift > 0
      ? L10n.RemoteNodes.RemoteNodes.Settings.clockAheadShort(magnitude)
      : L10n.RemoteNodes.RemoteNodes.Settings.clockBehindShort(magnitude)
  }

  private static func driftMagnitude(_ drift: TimeInterval) -> String {
    Duration.seconds(abs(drift)).formatted(
      .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
    )
  }

  private func clockDriftWarning(_ drift: TimeInterval) -> String {
    let magnitude = Self.driftMagnitude(drift)
    return drift > 0
      ? L10n.RemoteNodes.RemoteNodes.Status.clockAhead(magnitude)
      : L10n.RemoteNodes.RemoteNodes.Status.clockBehind(magnitude)
  }
}

// MARK: - Radio Settings Section

struct NodeRadioSettingsSection: View {
  @Bindable var settings: NodeSettingsViewModel
  var focusedField: FocusState<NodeSettingsField?>.Binding
  var radioRestartWarning: String = L10n.RemoteNodes.RemoteNodes.Settings.radioRestartWarning

  /// The picker holds the radio chip's setting: plain TX power only when the node's antenna figures
  /// say it has no PA; otherwise (a PA, or a node that reports no figures) it is named for what it is.
  private var txPowerTitle: String {
    settings.txSettingIsAntennaPower
      ? L10n.RemoteNodes.RemoteNodes.Settings.txPowerDbm
      : L10n.Settings.Radio.TxPower.radioSettingLabel
  }

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.radioParameters,
      icon: "antenna.radiowaves.left.and.right",
      color: .orange,
      isExpanded: $settings.isRadioExpanded,
      isLoaded: { settings.radioLoaded },
      isLoading: $settings.isLoadingRadio,
      hasError: $settings.radioError,
      onLoad: { await settings.fetchRadioSettings() }
    ) {
      if settings.radioSettingsModified {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
          Text(radioRestartWarning)
            .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))

        Divider()
      }

      CardFieldRow(title: L10n.RemoteNodes.RemoteNodes.Settings.frequencyMHz) {
        if let frequency = settings.frequency {
          DecimalTextField(
            title: L10n.RemoteNodes.RemoteNodes.Settings.mhz,
            value: frequency,
            // A nil frequency means "not loaded" here, so text that isn't a number keeps the last one.
            onChange: { if let newValue = $0 { settings.frequency = newValue } }
          )
          .frame(width: 100)
          .focused(focusedField, equals: .frequency)
          .onChange(of: settings.frequency) { _, _ in
            updateModified()
          }
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingRadio, hasError: settings.radioError)
            .frame(width: 100, alignment: .trailing)
        }
      }

      if let error = settings.radioValidation.frequency {
        NodeFieldError(error)
      }

      Divider()
      CardFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.bandwidthKHz,
        hidesTitleFromAccessibility: settings.bandwidth != nil
      ) {
        if let bandwidth = settings.bandwidth {
          Picker(L10n.RemoteNodes.RemoteNodes.Settings.bandwidthKHz, selection: Binding(
            get: { bandwidth },
            set: { settings.bandwidth = $0 }
          )) {
            ForEach(RadioOptions.bandwidthsKHz, id: \.self) { bwKHz in
              Text(RadioOptions.formatBandwidth(UInt32(bwKHz * 1000)))
                .tag(bwKHz)
                .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Settings.Accessibility.bandwidthLabel(RadioOptions.formatBandwidth(UInt32(bwKHz * 1000))))
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .tint(.primary)
          .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Settings.bandwidthHint)
          .onChange(of: settings.bandwidth) { _, _ in
            updateModified()
          }
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingRadio, hasError: settings.radioError)
        }
      }

      if let error = settings.radioValidation.bandwidth {
        NodeFieldError(error)
      }

      Divider()
      CardFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.spreadingFactor,
        hidesTitleFromAccessibility: settings.spreadingFactor != nil
      ) {
        if let spreadingFactor = settings.spreadingFactor {
          Picker(L10n.RemoteNodes.RemoteNodes.Settings.spreadingFactor, selection: Binding(
            get: { spreadingFactor },
            set: { settings.spreadingFactor = $0 }
          )) {
            ForEach(RadioOptions.spreadingFactors, id: \.self) { sf in
              Text(sf, format: .number)
                .tag(sf)
                .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Settings.Accessibility.spreadingFactorLabel(sf))
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .tint(.primary)
          .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Settings.spreadingFactorHint)
          .onChange(of: settings.spreadingFactor) { _, _ in
            updateModified()
          }
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingRadio, hasError: settings.radioError)
        }
      }

      if let error = settings.radioValidation.spreadingFactor {
        NodeFieldError(error)
      }

      Divider()
      CardFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.codingRate,
        hidesTitleFromAccessibility: settings.codingRate != nil
      ) {
        if let codingRate = settings.codingRate {
          Picker(L10n.RemoteNodes.RemoteNodes.Settings.codingRate, selection: Binding(
            get: { codingRate },
            set: { settings.codingRate = $0 }
          )) {
            ForEach(RadioOptions.codingRates, id: \.self) { cr in
              Text("\(cr)")
                .tag(cr)
                .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Settings.Accessibility.codingRateLabel(cr))
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .tint(.primary)
          .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Settings.codingRateHint)
          .onChange(of: settings.codingRate) { _, _ in
            updateModified()
          }
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingRadio, hasError: settings.radioError)
        }
      }

      if let error = settings.radioValidation.codingRate {
        NodeFieldError(error)
      }

      Divider()
      CardFieldRow(
        title: txPowerTitle,
        hidesTitleFromAccessibility: settings.txPower != nil
      ) {
        if let txPower = settings.txPower {
          Picker(txPowerTitle, selection: Binding(
            get: { txPower },
            set: { settings.txPower = $0 }
          )) {
            // The radio chip settings this node takes: -9 up to its reported maximum (`txm=`, else
            // the chip's 22). A value an older firmware stored outside that (an unchecked 30) is one
            // extra entry, marked as never applied, so it shows without the range stretching to it.
            ForEach(Array(Set(settings.txPowerRange).union([txPower])).sorted(), id: \.self) { dbm in
              Text(settings.txPowerRange.contains(dbm)
                ? "\(dbm)"
                : L10n.RemoteNodes.RemoteNodes.Settings.txPowerNotApplied(dbm)
              ).tag(dbm)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .tint(.primary)
          .onChange(of: settings.txPower) { _, _ in
            settings.txPowerModified = settings.txPower != settings.originalTxPower
          }
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingRadio, hasError: settings.radioError)
        }
      }

      Divider()
      HStack(spacing: 12) {
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.Settings.applyRadioSettings,
          isLoading: settings.isApplying,
          showSuccess: false,
          isActive: settings.radioSettingsModified || settings.txPowerModified,
          isDisabled: !(settings.radioSettingsModified || settings.txPowerModified) || settings.isApplying
        ) {
          settings.requestApplyRadioSettings()
        }
        NodeRevertButton(isEnabled: (settings.radioSettingsModified || settings.txPowerModified) && !settings.isApplying) {
          settings.revertRadioSettings()
        }
      }

      // The parameters take effect on restart: one tap for both, so the node isn't left
      // half-changed until someone remembers.
      if settings.radioSettingsModified {
        Divider()
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.Settings.applyAndReboot,
          isLoading: settings.isApplying || settings.isRebooting,
          showSuccess: false,
          isActive: true,
          isDisabled: settings.isApplying || settings.isRebooting
        ) {
          settings.requestApplyRadioSettings(rebootAfter: true)
        }
      }
    }
    // The last check before a change that can strand the node: what changes, old → new, and a
    // destructive Apply. The pending change is the model's, so the dialog survives a redraw.
    .confirmationDialog(
      L10n.RemoteNodes.RemoteNodes.Settings.Radio.confirmTitle,
      isPresented: Binding(
        get: { settings.pendingRadioChange != nil },
        set: { if !$0 { settings.pendingRadioChange = nil } }
      ),
      titleVisibility: .visible,
      presenting: settings.pendingRadioChange
    ) { change in
      Button(
        change.rebootAfter
          ? L10n.RemoteNodes.RemoteNodes.Settings.Radio.confirmApplyReboot
          : L10n.RemoteNodes.RemoteNodes.Settings.Radio.confirmApply,
        role: .destructive
      ) {
        Task { await settings.applyRadioSettings(rebootAfter: change.rebootAfter) }
      }
      Button(L10n.RemoteNodes.RemoteNodes.cancel, role: .cancel) {}
    } message: { change in
      Text((change.lines + [L10n.RemoteNodes.RemoteNodes.Settings.Radio.confirmStrand]).joined(separator: "\n"))
    }
  }

  /// Modified means different from what the node reported, so a value typed back (or Revert)
  /// clears it. Before the originals are known any change counts.
  private func updateModified() {
    guard settings.originalFrequency != nil else {
      settings.radioSettingsModified = true
      return
    }
    settings.radioSettingsModified = settings.frequency != settings.originalFrequency
      || settings.bandwidth != settings.originalBandwidth
      || settings.spreadingFactor != settings.originalSpreadingFactor
      || settings.codingRate != settings.originalCodingRate
  }
}

// MARK: - Identity Section

struct RemoteNodeIdentitySection: View {
  @Bindable var settings: NodeSettingsViewModel
  var focusedField: FocusState<NodeSettingsField?>.Binding
  var onPickLocation: () -> Void

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.identityLocation,
      icon: "person.text.rectangle",
      color: .blue,
      isExpanded: $settings.isIdentityExpanded,
      isLoaded: { settings.identityLoaded },
      isLoading: $settings.isLoadingIdentity,
      hasError: $settings.identityError,
      onLoad: { await settings.fetchIdentity() }
    ) {
      HStack {
        // The name the node advertises, not the nickname this phone shows for it; the info
        // says where that one is changed.
        Text(L10n.RemoteNodes.RemoteNodes.name)
        InfoButton(L10n.RemoteNodes.RemoteNodes.Settings.nameInfo, title: L10n.RemoteNodes.RemoteNodes.name)
        Spacer()
        if let name = settings.name {
          TextField(L10n.RemoteNodes.RemoteNodes.name, text: Binding(
            get: { name },
            set: { settings.name = $0 }
          ))
          .multilineTextAlignment(.trailing)
          .focused(focusedField, equals: .identityName)
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingIdentity, hasError: settings.identityError)
        }
      }

      if let error = settings.nameError {
        NodeFieldError(error)
      } else {
        NodeFieldResultLabel(result: settings.fieldResults["name"])
      }

      Divider()
      CardFieldRow(title: L10n.RemoteNodes.RemoteNodes.Settings.latitude) {
        if let latitude = settings.latitude {
          CoordinateTextField(
            title: L10n.RemoteNodes.RemoteNodes.Settings.latitude,
            value: latitude,
            onChange: { settings.latitude = $0 }
          )
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingIdentity, hasError: settings.identityError)
        }
      }

      if let error = settings.latitudeError {
        NodeFieldError(error)
      } else {
        NodeFieldResultLabel(result: settings.fieldResults["lat"])
      }

      Divider()
      CardFieldRow(title: L10n.RemoteNodes.RemoteNodes.Settings.longitude) {
        if let longitude = settings.longitude {
          CoordinateTextField(
            title: L10n.RemoteNodes.RemoteNodes.Settings.longitude,
            value: longitude,
            onChange: { settings.longitude = $0 }
          )
        } else {
          SettingsLoadPlaceholder(isLoading: settings.isLoadingIdentity, hasError: settings.identityError)
        }
      }

      if let error = settings.longitudeError {
        NodeFieldError(error)
      } else {
        NodeFieldResultLabel(result: settings.fieldResults["lon"])
      }

      if settings.telemetryFixDiffersFromSettings, let fix = settings.telemetryFix {
        Divider()
        Button {
          settings.setLocationFromPicker(latitude: fix.latitude, longitude: fix.longitude)
        } label: {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(L10n.RemoteNodes.RemoteNodes.Settings.useTelemetryLocation)
              Text(String(format: "%.5f, %.5f", fix.latitude, fix.longitude))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "location")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.borderless)
      }

      Divider()
      Button(L10n.RemoteNodes.RemoteNodes.Settings.pickOnMap, systemImage: "map") {
        onPickLocation()
      }
      .buttonStyle(.borderless)
      .frame(maxWidth: .infinity, alignment: .leading)

      Divider()
      HStack(spacing: 12) {
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.Settings.applyIdentitySettings,
          isLoading: settings.isApplying,
          showSuccess: settings.identityApplySuccess,
          isActive: settings.identitySettingsModified,
          isDisabled: !settings.identitySettingsModified || settings.isApplying
        ) {
          await settings.applyIdentitySettings()
        }
        NodeRevertButton(isEnabled: settings.identitySettingsModified && !settings.isApplying) {
          settings.revertIdentitySettings()
        }
      }
    }
  }
}

// MARK: - Contact Info Section

struct NodeContactInfoSection: View {
  @Bindable var settings: NodeSettingsViewModel
  var focusedField: FocusState<NodeSettingsField?>.Binding

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.contactInfo,
      icon: "person.crop.rectangle",
      color: .teal,
      info: L10n.RemoteNodes.RemoteNodes.Settings.contactInfoFooter,
      isExpanded: $settings.isContactInfoExpanded,
      isLoaded: { settings.contactInfoLoaded },
      isLoading: $settings.isLoadingContactInfo,
      hasError: $settings.contactInfoError,
      onLoad: { await settings.fetchContactInfo() }
    ) {
      Fields(settings: settings, focusedField: focusedField)
    }
  }

  /// Separate view so `errorMessage` invalidates these rows, not only the
  /// stored card content closure.
  private struct Fields: View {
    @Bindable var settings: NodeSettingsViewModel
    var focusedField: FocusState<NodeSettingsField?>.Binding

    var body: some View {
      if settings.ownerInfo != nil {
        VStack(alignment: .trailing, spacing: 4) {
          TextField(
            L10n.RemoteNodes.RemoteNodes.Settings.contactInfoPlaceholder,
            text: Binding(
              get: { settings.ownerInfo ?? "" },
              set: { settings.ownerInfo = $0 }
            ),
            axis: .vertical
          )
          .lineLimit(3...6)
          .focused(focusedField, equals: .contactInfo)

          Text("\(settings.ownerInfoCharCount)/\(NodeSettingsViewModel.ownerInfoMaxLength)")
            .font(.caption2)
            .foregroundStyle(settings.isOwnerInfoTooLong ? .red : .secondary)
        }
      } else {
        SettingsLoadPlaceholder(
          isLoading: settings.isLoadingContactInfo,
          hasError: settings.contactInfoError
        )
      }

      if let applyError = settings.errorMessage {
        Text(applyError)
          .foregroundStyle(.orange)
          .font(.caption)
      }

      Divider()
      NodeApplyButton(
        title: L10n.RemoteNodes.RemoteNodes.Settings.applyContactInfo,
        isLoading: settings.isApplying,
        showSuccess: settings.contactInfoApplySuccess,
        isActive: settings.contactInfoSettingsModified && !settings.isOwnerInfoTooLong,
        isDisabled: !settings.contactInfoSettingsModified || settings.isApplying || settings.isOwnerInfoTooLong
      ) {
        await settings.applyContactInfoSettings()
      }
    }
  }
}

// MARK: - Security Section

struct NodeSecuritySection: View {
  @Bindable var settings: NodeSettingsViewModel

  var body: some View {
    NodeDisclosureCard(
      L10n.RemoteNodes.RemoteNodes.Settings.security,
      systemImage: "lock.fill",
      color: .gray,
      isExpanded: $settings.isSecurityExpanded
    ) {
      SecureField(L10n.RemoteNodes.RemoteNodes.Settings.newPassword, text: $settings.newPassword)
      Divider()
      SecureField(L10n.RemoteNodes.RemoteNodes.Settings.confirmPassword, text: $settings.confirmPassword)
      Divider()
      NodeApplyButton(
        title: L10n.RemoteNodes.RemoteNodes.Settings.changePassword,
        isLoading: settings.isApplying,
        showSuccess: settings.changePasswordSuccess,
        isActive: !settings.newPassword.isEmpty && settings.newPassword == settings.confirmPassword,
        isDisabled: settings.isApplying || settings.changePasswordSuccess || settings.newPassword.isEmpty
          || settings.newPassword != settings.confirmPassword
      ) {
        await settings.changePassword()
      }
    }
  }
}

// MARK: - Action Tiles

/// The node's one-tap actions as a row of action cards under the header (Send Advert, Sync
/// Time, Reboot, and the access list for admins), in place of a Device Actions section at the
/// foot of the form. The last error of any settings request shows under them, where the old
/// section showed it. Reboot asks first: the host attaches `nodeRebootConfirmation`.
/// A host can add role-specific tiles (`extraTiles`, e.g. a repeater's Discover); they sit right
/// after Send Advert, the action they pair with.
struct NodeSettingsActionTiles<ExtraTiles: View>: View {
  @Environment(\.appState) private var appState
  let settings: NodeSettingsViewModel
  let session: RemoteNodeSessionDTO
  @Binding var showRebootConfirmation: Bool
  /// How many tiles `extraTiles` draws, for the row's column count.
  let extraTileCount: Int
  @ViewBuilder let extraTiles: () -> ExtraTiles

  init(
    settings: NodeSettingsViewModel,
    session: RemoteNodeSessionDTO,
    showRebootConfirmation: Binding<Bool>,
    extraTileCount: Int,
    @ViewBuilder extraTiles: @escaping () -> ExtraTiles
  ) {
    self.settings = settings
    self.session = session
    _showRebootConfirmation = showRebootConfirmation
    self.extraTileCount = extraTileCount
    self.extraTiles = extraTiles
  }

  var body: some View {
    NodeActionTileRow(count: (session.isAdmin ? 4 : 3) + extraTileCount) {
      Button {
        Task { await settings.forceAdvert() }
      } label: {
        // "Advert", so five tiles fit a row; VoiceOver reads the full name.
        NodeActionTile(
          L10n.Tools.Tools.Spectrum.advert,
          systemImage: "dot.radiowaves.left.and.right",
          accessibilityTitle: L10n.RemoteNodes.RemoteNodes.Settings.sendAdvert,
          isBusy: settings.isSendingAdvert
        )
      }
      .disabled(settings.isSendingAdvert)

      extraTiles()

      Button {
        Task { await settings.syncTime() }
      } label: {
        NodeActionTile(
          L10n.RemoteNodes.RemoteNodes.Settings.syncTime,
          systemImage: "clock.arrow.2.circlepath",
          isBusy: settings.isApplying
        )
      }
      .disabled(settings.isApplying)

      Button {
        showRebootConfirmation = true
      } label: {
        NodeActionTile(
          L10n.RemoteNodes.RemoteNodes.Settings.reboot,
          systemImage: "restart",
          accessibilityTitle: L10n.RemoteNodes.RemoteNodes.Settings.rebootDevice,
          isBusy: settings.isRebooting
        )
        .tint(.red)
      }
      .disabled(settings.isRebooting)

      if session.isAdmin {
        // Admin-only: the firmware answers the ACL request only for admin logins.
        NavigationLink(value: NodeAccessListRoute(session: session)) {
          NodeActionTile(L10n.RemoteNodes.RemoteNodes.Acl.title, systemImage: "person.badge.key")
        }
        .radioDisabled(for: appState.connectionState)
        .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Acl.linkFooter)
      }
    }
    .buttonStyle(.plain)
    // A node that was just rebooted or powered off can't answer: the tiles wait for the reconnect.
    .disabled(settings.quietState.isQuiet)
    .opacity(settings.quietState.isQuiet ? 0.5 : 1)

    if let error = settings.errorMessage {
      Text(error)
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
  }
}

extension NodeSettingsActionTiles where ExtraTiles == EmptyView {
  init(settings: NodeSettingsViewModel, session: RemoteNodeSessionDTO, showRebootConfirmation: Binding<Bool>) {
    self.init(
      settings: settings,
      session: session,
      showRebootConfirmation: showRebootConfirmation,
      extraTileCount: 0
    ) {
      EmptyView()
    }
  }
}

extension View {
  /// The settings' success alert ("Radio settings applied. Restart device to take effect."). After a
  /// radio change it also offers Reboot Now, so the restart the message asks for is one tap away.
  func nodeSettingsSuccessAlert(settings: NodeSettingsViewModel, isPresented: Binding<Bool>) -> some View {
    alert(L10n.RemoteNodes.RemoteNodes.Settings.success, isPresented: isPresented) {
      if settings.successOffersReboot {
        Button(L10n.RemoteNodes.RemoteNodes.Settings.rebootNow, role: .destructive) {
          settings.successOffersReboot = false
          Task { await settings.reboot() }
        }
      }
      Button(L10n.RemoteNodes.RemoteNodes.Settings.ok, role: .cancel) {
        settings.successOffersReboot = false
      }
    } message: {
      Text(settings.successMessage ?? L10n.RemoteNodes.RemoteNodes.Settings.settingsApplied)
    }
  }

  /// The reboot confirmation for `NodeSettingsActionTiles`, on the page rather than the tile, so
  /// it isn't tied to a view that scrolls away.
  func nodeRebootConfirmation(
    isPresented: Binding<Bool>,
    settings: NodeSettingsViewModel,
    title: String = L10n.RemoteNodes.RemoteNodes.Settings.rebootConfirmTitle,
    message: String = L10n.RemoteNodes.RemoteNodes.Settings.rebootMessage
  ) -> some View {
    confirmationDialog(title, isPresented: isPresented) {
      Button(L10n.RemoteNodes.RemoteNodes.Settings.reboot, role: .destructive) {
        Task { await settings.reboot() }
      }
      Button(L10n.RemoteNodes.RemoteNodes.cancel, role: .cancel) {}
    } message: {
      Text(message)
    }
  }
}
