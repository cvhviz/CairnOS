import CairnServices
import SwiftUI

/// Settings → Battery: everything about the connected radio's battery in one place, laid out as a
/// repeater's Battery page is (the user, 2026-11-08): the charge and its readings, the battery's
/// history (each chart opening its full graph; `BatteryMonitor` saves a reading a quarter hour
/// under the radio's key), and how the charge is worked out (the discharge curve, editable here).
/// The readings come from `BatteryMonitor`, which polls while connected; opening the page and
/// refreshing ask for a fresh one.
struct BatteryView: View {
  @Environment(\.appState) private var appState

  @State private var selectedOCVPreset: OCVPreset = .liIon
  @State private var ocvValues: [Int] = OCVPreset.liIon.ocvArray
  @State private var isRefreshing = false
  @State private var errorMessage: String?

  private var ocvArray: [Int] {
    appState.batteryMonitor.activeBatteryOCVArray(for: appState.connectedDevice)
  }

  /// The radio answered but reports no battery: 0 mV, a mains-powered board without the pin.
  private var hasNoBattery: Bool {
    appState.isRadioReady && appState.batteryMonitor.deviceBattery?.isBatteryPresent == false
  }

  /// The charge, large, and the readings behind it.
  private var summary: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      BatteryHeroCard(
        percent: appState.radioBatteryPercent,
        voltage: appState.radioBatteryVoltage,
        hasNoBattery: hasNoBattery
      )
      MetricTileGrid {
        readingTiles
      }
    }
  }

  /// The radio's battery history between the readings and the curve; with no radio (no key to
  /// read it by), the readings and the curve alone.
  @ViewBuilder
  private var page: some View {
    if let device = appState.connectedDevice {
      TelemetryHistoryOverviewView(
        publicKey: device.publicKey,
        radioID: appState.currentRadioID ?? device.id,
        showNeighbors: false,
        title: L10n.Settings.DeviceInfo.battery,
        scope: .battery,
        header: AnyView(summary),
        accessory: AnyView(curveSection),
        refreshID: appState.batteryMonitor.historyRecordCount
      )
    } else {
      CardForm {
        summary
        curveSection
      }
      .flashingNavigationTitle(L10n.Settings.DeviceInfo.battery)
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private var curveSection: some View {
    BatteryCurveSection(
      availablePresets: OCVPreset.selectablePresets,
      headerText: L10n.Settings.BatteryCurve.header,
      footerText: "",
      // How the charge is worked out belongs with the curve that works it out.
      infoText: L10n.Settings.Battery.footer + "\n\n" + L10n.Settings.BatteryCurve.footer,
      selectedPreset: $selectedOCVPreset,
      voltageValues: $ocvValues,
      onSave: saveOCVToDevice,
      isDisabled: appState.connectionState != .ready
    )
    // Low-battery warnings are on Settings › Notifications, with every other alert.
  }

  var body: some View {
    page
    .scrollDismissesKeyboard(.interactively)
    .refreshable { await refresh() }
    .refreshCommand { await refresh() }
    .toolbar {
      // Always present so the toolbar item keeps one identity across connection changes.
      ToolbarItem(placement: .primaryAction) {
        Button(L10n.Settings.DeviceSensors.refresh, systemImage: "arrow.clockwise") {
          Task { await refresh() }
        }
        .labelStyle(.iconOnly)
        .radioDisabled(for: appState.connectionState, or: isRefreshing)
      }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button(L10n.Localizable.Common.done) {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
          )
        }
      }
    }
    .task {
      await refresh()
    }
    .task(id: appState.connectedDevice?.id) {
      loadOCVFromDevice()
    }
    .errorAlert($errorMessage)
  }

  // MARK: - Tiles

  @ViewBuilder
  private var readingTiles: some View {
    MetricTile(
      L10n.Settings.Battery.voltage,
      systemImage: "bolt.fill",
      value: appState.radioBatteryVoltage.map(BatteryLevel.formattedVoltage) ?? "—"
    )
    MetricTile(
      L10n.Settings.Battery.lastReading,
      systemImage: "clock",
      value: lastReadingDate?.formatted(date: .omitted, time: .shortened) ?? "—"
    )
    MetricTile(
      L10n.Settings.BatteryCurve.header,
      systemImage: "chart.xyaxis.line",
      value: selectedOCVPreset == .custom ? L10n.Settings.BatteryCurve.custom : selectedOCVPreset.displayName
    )
    MetricTile(
      L10n.Settings.Battery.curveRange,
      systemImage: "arrow.left.and.right",
      value: BatteryLevel.formattedRange(ocvArray: ocvArray) ?? "—",
      caption: L10n.Settings.Battery.curveRangeCaption
    )
  }

  /// Only while the reading on screen is live; after a disconnect the date would date nothing.
  private var lastReadingDate: Date? {
    guard appState.isRadioReady, appState.batteryMonitor.deviceBattery != nil else { return nil }
    return appState.batteryMonitor.lastSuccessfulFetchDate
  }

  // MARK: - Actions

  private func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    await appState.batteryMonitor.fetchDeviceBattery(services: appState.services, device: appState.connectedDevice)
  }

  private func loadOCVFromDevice() {
    guard let device = appState.connectedDevice else { return }

    if let presetName = device.ocvPreset {
      if presetName == OCVPreset.custom.rawValue, let customString = device.customOCVArrayString {
        let parsed = customString.split(separator: ",")
          .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parsed.count == 11 {
          ocvValues = parsed
          selectedOCVPreset = .custom
          return
        }
      }
      if let preset = OCVPreset(rawValue: presetName) {
        selectedOCVPreset = preset
        ocvValues = preset.ocvArray
        return
      }
    }

    selectedOCVPreset = .liIon
    ocvValues = OCVPreset.liIon.ocvArray
  }

  private func saveOCVToDevice(preset: OCVPreset, values: [Int]) async {
    guard let deviceService = appState.services?.deviceService,
          let deviceID = appState.connectedDevice?.id else { return }

    do {
      try await deviceService.updateOCVSettings(
        deviceID: deviceID,
        preset: preset.rawValue,
        customArray: preset == .custom ? values.map(String.init).joined(separator: ",") : nil
      )
    } catch {
      errorMessage = error.userFacingMessage
      // The picker and fields already show the new curve; put back the one that's stored.
      loadOCVFromDevice()
    }
  }
}

// MARK: - Hero Card

/// The charge, large, with its level in words, a meter, and the voltage. One VoiceOver element.
private struct BatteryHeroCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let percent: Int?
  let voltage: Double?
  let hasNoBattery: Bool

  private var level: BatteryLevel? {
    percent.map(BatteryLevel.init(percent:))
  }

  /// The level word and voltage, or why there is no charge to show.
  private var detail: String {
    if hasNoBattery { return L10n.Settings.Battery.notPresent }
    guard let level else { return L10n.Settings.Dashboard.noReading }
    return [level.title, voltage.map(BatteryLevel.formattedVoltage)]
      .compactMap(\.self)
      .joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      let layout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
      layout {
        Image(systemName: BatteryLevel.symbol(for: percent))
          // A text style, so the glyph grows with the percentage beside it.
          .font(.largeTitle)
          .imageScale(.large)
          .foregroundStyle(level?.tint ?? Color.secondary)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(BatteryLevel.formattedPercent(percent))
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      if let percent, let level {
        MeterBar(fraction: Double(percent) / 100, tint: level.tint)
      }
    }
    .cardSurface(padding: 14)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Settings.DeviceInfo.battery)
    .accessibilityValue([BatteryLevel.formattedPercent(percent), detail].joined(separator: ", "))
  }
}
