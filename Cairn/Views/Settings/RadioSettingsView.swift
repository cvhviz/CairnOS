import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RadioSettingsView")

/// Settings → Radio as a dashboard, like a repeater's: a header naming the radio, a row of its
/// actions (advert, regions), then a card per setting that opens the sheet editing it. The
/// sheets hold the sections that used to fill the page, unchanged: the preset applies on pick, the
/// parameters are staged and sent by Apply, and the path hash size and default scope apply on pick.
struct RadioSettingsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.openURL) private var openURL
  @Environment(\.dismiss) private var dismiss
  @State private var radioWriteInFlight = false
  @State private var session = PresetLocationSession()
  @State private var regionPickerSheet: RegionPickerRows.Sheet?
  @State private var openSheet: RadioSettingsSheet?
  /// The Parameters sheet holds a staged edit not yet applied, so closing it asks first.
  @State private var parametersPending = false
  @State private var showDiscardConfirmation = false
  /// The Path Hash or Default Scope sheet's write is in flight or its alert is up, so the sheet
  /// stays open until its outcome has been seen.
  @State private var sheetWriteBusy = false
  /// The radio's flood timing, read when the page opens on a ready radio.
  @State private var tuning: RadioTuning?
  @State private var tuningReadState = RadioTuningReadState.loading
  /// The radio's receive-gain switches (firmware v14+): nil until read, a nil field for one it lacks.
  @State private var receiveGain: ReceiveGain?
  /// The switch whose change is being sent (its spinner), if any.
  @State private var receiveWriting: WritableKeyPath<ReceiveGain, Bool?>?
  /// Bumped by every change sent, so a read that started before it never puts the old value back.
  @State private var receiveWriteGeneration = 0
  @State private var receiveError: String?
  @State private var isSendingAdvert = false
  @State private var advertSucceeded = false
  @State private var advertFailed = false
  /// The arrival read failed: the cards show the last known values (`RadioReadFootnote`).
  @State private var readFailed = false

  private var device: DeviceDTO? { appState.connectedDevice }
  private var isRepeat: Bool { device?.clientRepeat == true }

  private var appearTaskID: String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    let syncPhase = appState.connectionUI.currentSyncPhase.map { String(describing: $0) } ?? "none"
    let authorized = appState.locationService.isAuthorized
    return "\(deviceID)-\(String(describing: appState.connectionState))-\(syncPhase)-\(authorized)"
  }

  var body: some View {
    CardForm {
      header
      controls
      // Not radio-disabled as a whole: each sheet's write controls disable themselves, and the
      // Preset sheet's location rows are app-side, so they stay usable in any connection state.
      NodeDashboardCardGrid(items: cards)
      receiveSection
      if readFailed {
        RadioReadFootnote()
      }
      // Radio-law compliance stays on the page as well as in the Preset sheet.
      Text(L10n.Settings.Radio.regulationsFooter)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
    .environment(session)
    // Serves the GPS auto-resolve. Stands aside while a sheet is open: the
    // Preset sheet binds its own copy, and the page can't present over a sheet.
    .presetLocationSessionAlerts(session, openURL: openURL, isActive: openSheet == nil)
    .flashingNavigationTitle(L10n.Settings.Radio.header)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $openSheet, onDismiss: {
      parametersPending = false
      showDiscardConfirmation = false
      sheetWriteBusy = false
    }) { sheet in
      sheetContent(sheet)
    }
    .cairnFeedback(.success, trigger: advertSucceeded)
    .cairnFeedback(.error, trigger: advertFailed)
    .task(id: appearTaskID) {
      session.resolveOnAppear(from: appState)
    }
    // The page reads what the radio holds on arrival, not when a sheet opens.
    .task(id: RadioPresetSection.startupTaskID(appState)) {
      readFailed = await RadioPresetSection.startupRead(appState)
    }
    .task(id: RegionsCardSection.refreshTaskID(appState)) {
      await RegionsCardSection.refreshDefaultScope(appState)
    }
    .task(id: tuningReadID) {
      await readTuning()
      await readReceiveGain()
    }
    .errorAlert($receiveError)
  }

  // MARK: - Receive

  /// The front end's LNA and the SX1262's boosted gain, as the Heltec touch kit's own Radio page
  /// has them, for any radio whose command line answers for them (MeshCore 1.18, v14+). A switch
  /// the radio doesn't have is left out, the section too when it has neither; one whose hardware
  /// turns out not to do it (an SX1276's boost) goes once that is known. Each applies at once and
  /// is saved on the radio; while one is being sent, both wait, and its icon spins.
  @ViewBuilder
  private var receiveSection: some View {
    if let gain = receiveGain, !gain.isEmpty {
      CardFormSection(L10n.Settings.Radio.Receive.header, info: L10n.Settings.Radio.Receive.info) {
        if gain.femLNA != nil {
          ToggleCard(
            L10n.Settings.Radio.Receive.lna,
            systemImage: "dot.radiowaves.left.and.right",
            color: .orange,
            subtitle: L10n.Settings.Radio.Receive.lnaHint,
            isBusy: receiveWriting == \ReceiveGain.femLNA,
            isOn: receiveBinding(\.femLNA) { service, isOn in try await service.setFEMLNA(isOn) }
          )
          .radioDisabled(for: appState.connectionState, or: receiveWriting != nil)
        }
        if gain.boostedRX != nil {
          ToggleCard(
            L10n.Settings.Radio.Receive.boost,
            systemImage: "ear.badge.waveform",
            color: .indigo,
            subtitle: L10n.Settings.Radio.Receive.boostHint,
            isBusy: receiveWriting == \ReceiveGain.boostedRX,
            isOn: receiveBinding(\.boostedRX) { service, isOn in try await service.setBoostedRX(isOn) }
          )
          .radioDisabled(for: appState.connectionState, or: receiveWriting != nil)
        }
      }
    }
  }

  /// A switch shown at its new place at once and sent to the radio. Refused, it goes back; refused
  /// because the hardware can't do it, it goes away (the service has set the radio's value back).
  private func receiveBinding(
    _ field: WritableKeyPath<ReceiveGain, Bool?>,
    write: @escaping (SettingsService, Bool) async throws -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { receiveGain?[keyPath: field] ?? false },
      set: { isOn in
        guard receiveWriting == nil, let settingsService = appState.services?.settingsService else { return }
        let before = receiveGain?[keyPath: field]
        receiveGain?[keyPath: field] = isOn
        receiveWriting = field
        receiveWriteGeneration += 1
        Task {
          defer { receiveWriting = nil }
          do {
            try await write(settingsService, isOn)
          } catch SettingsServiceError.unsupportedSetting {
            receiveGain?[keyPath: field] = nil
            receiveError = SettingsServiceError.unsupportedSetting.userFacingMessage
          } catch {
            receiveGain?[keyPath: field] = before
            receiveError = error.userFacingMessage
          }
        }
      }
    )
  }

  private func readReceiveGain() async {
    guard appState.connectionState == .ready, appState.connectedDevice?.supportsCompanionRemoteCLI == true,
          let settingsService = appState.services?.settingsService else {
      receiveGain = nil
      return
    }
    let generation = receiveWriteGeneration
    let gain = await settingsService.readReceiveGain()
    // a change sent meanwhile is newer than this read: keep what the page shows
    guard !Task.isCancelled, generation == receiveWriteGeneration, receiveWriting == nil else { return }
    receiveGain = gain
  }

  /// A new radio, or the link becoming ready, reads the tuning again.
  private var tuningReadID: String {
    "\(appState.connectedDevice?.id.uuidString ?? "none")-\(appState.connectionState == .ready)-\(appState.servicesVersion)"
  }

  private func readTuning() async {
    guard appState.connectionState == .ready, let settingsService = appState.services?.settingsService else {
      if appState.connectedDevice == nil { tuning = nil }
      return
    }
    tuningReadState = .loading
    do {
      tuning = try await settingsService.getRadioTuning()
      tuningReadState = .loaded
    } catch is CancellationError {
      return
    } catch {
      tuningReadState = RadioTuning.isUnsupported(error) ? .unsupported : .failed
      if tuningReadState == .failed {
        logger.warning("Radio tuning read failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Header

  /// The radio's name, with what the page's settings are for behind the "i". Repeat Mode shows on
  /// the Preset card, which carries the band.
  private var header: some View {
    HStack(spacing: 10) {
      IconTile(systemImage: "antenna.radiowaves.left.and.right", color: .orange)
      Text(device?.nodeName ?? L10n.Localizable.Home.noRadio)
        .font(.title3.weight(.bold))
        .foregroundStyle(device == nil ? Color.secondary : Color.primary)
        .lineLimit(1)
      Spacer(minLength: 8)
      InfoButton(pageInfo, title: L10n.Settings.Radio.header)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 12)
  }

  /// The old sections' info in one place: presets, regions, and the default scope when supported.
  private var pageInfo: String {
    var parts = [L10n.Settings.Radio.footer, L10n.Settings.Regions.footer]
    if device?.supportsDefaultFloodScope == true {
      parts.append(L10n.Settings.DefaultFloodScope.footer)
    }
    return parts.joined(separator: "\n\n")
  }

  /// The Repeat Mode band the radio is on, shown on the Preset card in place of the location.
  private var repeatBand: String? {
    guard let device, device.clientRepeat else { return nil }
    return RadioPresets.matchingRepeatPreset(frequencyKHz: device.frequency)?.repeatSectionHeader
  }

  // MARK: - Controls

  /// Advert and Manage Regions. Use My Location lives in the Preset sheet's location card.
  private var controls: some View {
    let showsRegions = device != nil
    return NodeActionTileRow(count: showsRegions ? 2 : 1) {
      advertControl
      if showsRegions {
        NavigationLink {
          RegionManagementView()
        } label: {
          NodeActionTile(
            L10n.RemoteNodes.RemoteNodes.Settings.regions,
            systemImage: "globe",
            accessibilityTitle: L10n.Chats.Chats.ChannelInfo.Region.manage
          )
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.Chats.Chats.ChannelInfo.Region.manageRegions)
      }
    }
  }

  /// Zero-hop or flood, as Home's Radio card offers them.
  private var advertControl: some View {
    Menu {
      Button {
        sendAdvert(flood: false)
      } label: {
        Label(L10n.Settings.BleStatus.sendZeroHopAdvert, systemImage: "dot.radiowaves.right")
      }
      .accessibilityHint(L10n.Settings.BleStatus.SendZeroHopAdvert.hint)
      Button {
        sendAdvert(flood: true)
      } label: {
        Label(L10n.Settings.BleStatus.sendFloodAdvert, systemImage: "dot.radiowaves.left.and.right")
      }
      .accessibilityHint(L10n.Settings.BleStatus.SendFloodAdvert.hint)
    } label: {
      NodeActionTile(
        L10n.Localizable.CarPlay.Action.advert,
        systemImage: "dot.radiowaves.right",
        isBusy: isSendingAdvert
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState, or: isSendingAdvert)
  }

  /// The same advert Home's Radio card sends, with the same haptics.
  private func sendAdvert(flood: Bool) {
    guard !isSendingAdvert else { return }
    isSendingAdvert = true
    Task {
      do {
        try await appState.sendSelfAdvert(flood: flood)
        advertSucceeded.toggle()
      } catch {
        logger.error("Failed to send advert from Radio (flood=\(flood)): \(error.localizedDescription)")
        advertFailed.toggle()
      }
      isSendingAdvert = false
    }
  }

  // MARK: - Cards

  /// The applied values, read from the radio; edits not yet applied stay in their sheet.
  private var cards: [NodeDashboardCardItem] {
    var items = [presetCard, parametersCard]
    if device?.supportsPathHashMode == true {
      items.append(pathHashCard)
    }
    if device != nil {
      items.append(tuningCard)
    }
    if device?.supportsDefaultFloodScope == true {
      items.append(defaultScopeCard)
    } else if device != nil {
      // Below v11 there's no Default Scope card to carry the known regions, so they get their own.
      items.append(regionsCard)
    }
    return items
  }

  private var presetCard: NodeDashboardCardItem {
    let location = appState.regionSelection.map { RegionalAreas.displayName(for: $0) }
      ?? L10n.Settings.Radio.PresetLocation.notSet
    return NodeDashboardCardItem(
      id: "preset",
      title: L10n.Settings.Radio.preset,
      systemImage: "dial.medium.fill",
      tint: isRepeat ? AppColors.Radio.repeatMode : .orange,
      value: device.map { HomeStatusLines.presetName($0, region: appState.regionSelection) } ?? "—",
      valueTint: device == nil ? .secondary : .primary,
      note: isRepeat ? L10n.Settings.Radio.repeatMode : nil,
      noteTint: AppColors.Radio.repeatMode,
      // Repeat Mode's presets aren't filtered by location, so its band shows in place of it.
      details: isRepeat
        ? [repeatBand].compactMap(\.self)
        : ["\(L10n.Settings.Radio.presetLocation) \(location)"],
      destination: .action { openSheet = .preset }
    )
  }

  private var parametersCard: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "parameters",
      title: L10n.Localizable.CarPlay.Home.modulation,
      systemImage: "waveform",
      tint: .orange,
      value: device.map { L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz($0.frequency)) } ?? "—",
      valueTint: device == nil ? .secondary : .primary,
      details: device.map {
        [
          // The four mesh-compatibility parameters at a glance, as a remote node's Radio card.
          NodeRouteFormat.joined([HomeStatusLines.modulation($0), "CR\($0.codingRate)"]),
          "\(L10n.Settings.Dashboard.txPower) \(TxPowerText.reading(setting: Int($0.txPower), model: $0.manufacturerName))",
        ]
      } ?? [],
      destination: .action { openSheet = .parameters }
    )
  }

  private var pathHashCard: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "pathHash",
      title: L10n.Settings.PathHashMode.header,
      systemImage: "number",
      tint: .indigo,
      value: PathHashModeSection.title(for: device?.pathHashMode ?? 0),
      destination: .action { openSheet = .pathHash }
    )
  }

  /// The airtime factor as the value, with the RX delay beneath; "Not supported" on firmware
  /// without tuning.
  private var tuningCard: NodeDashboardCardItem {
    let isUnsupported = tuningReadState == .unsupported
    return NodeDashboardCardItem(
      id: "tuning",
      title: L10n.Settings.Radio.Tuning.header,
      systemImage: "slider.horizontal.3",
      tint: .teal,
      value: isUnsupported
        ? L10n.RemoteNodes.RemoteNodes.Controls.unsupported
        : tuning.map { RadioTuningSection.format($0.airtimeFactor) } ?? "—",
      valueTint: tuning == nil ? .secondary : .primary,
      note: tuning == nil ? nil : L10n.Settings.Radio.Tuning.airtimeFactor,
      details: tuning.map {
        ["\(L10n.Settings.Radio.Tuning.rxDelay) \(RadioTuningSection.format($0.rxDelayBase))"]
      } ?? [],
      destination: .action { openSheet = .tuning }
    )
  }

  private var defaultScopeCard: NodeDashboardCardItem {
    let scope = device?.defaultFloodScopeName
    return NodeDashboardCardItem(
      id: "defaultScope",
      title: L10n.Settings.Regions.defaultScope,
      systemImage: "dot.radiowaves.left.and.right",
      tint: .green,
      value: scope ?? L10n.Settings.DefaultFloodScope.disabled,
      valueTint: scope == nil ? .secondary : .primary,
      details: [RegionsCardSection.knownRegionsSummary(device)],
      destination: .action { openSheet = .defaultScope }
    )
  }

  private var regionsCard: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "regions",
      title: L10n.Settings.Regions.known,
      systemImage: "globe",
      tint: .green,
      value: RegionsCardSection.sortedKnownRegions(device).count.formatted(),
      details: [RegionsCardSection.knownRegionsSummary(device)],
      destination: .page(AnyView(RegionManagementView()))
    )
  }

  // MARK: - Sheets

  /// Giving up after the retry alert's last try leaves the page, as it did before the sheets.
  private func giveUp() {
    openSheet = nil
    dismiss()
  }

  /// A sheet holding one tile opens just tall enough for it, and can still be pulled up.
  private static let singleTileDetents: Set<PresentationDetent> = [.fraction(0.3), .large]

  @ViewBuilder
  private func sheetContent(_ sheet: RadioSettingsSheet) -> some View {
    switch sheet {
    case .preset:
      RadioSettingsPageSheet(
        isBusy: radioWriteInFlight,
        detents: [.large],
        onDone: { openSheet = nil }
      ) {
        if !isRepeat {
          PresetLocationSection(activeSheet: $regionPickerSheet)
        }
        RadioPresetSection(radioWriteInFlight: $radioWriteInFlight, onGiveUp: giveUp)
      }
      .environment(session)
      .presetLocationSessionAlerts(session, openURL: openURL)
      .regionPickerSheet(
        $regionPickerSheet,
        selection: Bindable(appState).regionSelection
      )

    case .parameters:
      RadioSettingsPageSheet(
        isBusy: radioWriteInFlight,
        detents: [.large],
        blocksSwipeDismiss: parametersPending,
        onDone: {
          if parametersPending {
            showDiscardConfirmation = true
          } else {
            openSheet = nil
          }
        }
      ) {
        AdvancedRadioSection(
          radioWriteInFlight: $radioWriteInFlight,
          hasPendingChanges: $parametersPending,
          onGiveUp: giveUp
        )
      }
      .confirmationDialog(
        L10n.Settings.Radio.Parameters.Discard.title,
        isPresented: $showDiscardConfirmation,
        titleVisibility: .visible
      ) {
        Button(L10n.Settings.Radio.Parameters.Discard.confirm, role: .destructive) {
          openSheet = nil
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Settings.Radio.Parameters.Discard.message)
      }

    case .pathHash:
      RadioSettingsPageSheet(
        isBusy: sheetWriteBusy,
        detents: Self.singleTileDetents,
        onDone: { openSheet = nil }
      ) {
        PathHashModeSection(onGiveUp: giveUp, onBusyChange: { sheetWriteBusy = $0 })
      }

    case .tuning:
      RadioSettingsPageSheet(
        isBusy: sheetWriteBusy,
        detents: [.medium, .large],
        onDone: { openSheet = nil }
      ) {
        RadioTuningSection(
          tuning: $tuning,
          readState: tuningReadState,
          onReload: { await readTuning() },
          onGiveUp: giveUp,
          onBusyChange: { sheetWriteBusy = $0 }
        )
      }

    case .defaultScope:
      // Medium, not one tile's height: the sheet pushes Manage Regions and its Add sheet.
      RadioSettingsPageSheet(
        isBusy: sheetWriteBusy,
        detents: [.medium, .large],
        onDone: { openSheet = nil }
      ) {
        RegionsCardSection(
          showsKnownRegions: false,
          onGiveUp: giveUp,
          onBusyChange: { sheetWriteBusy = $0 }
        )
      }
    }
  }
}

/// The setting a card on Settings → Radio opens.
private enum RadioSettingsSheet: String, Identifiable {
  case preset
  case parameters
  case pathHash
  case tuning
  case defaultScope

  var id: Self { self }
}

/// A Radio setting's sheet: its section on its own, with Done. Like `NodeSettingsPageSheet`, but
/// held open while a write is in flight, so a write's alerts land here. Untitled: the section's
/// own header names it, so a title would repeat it.
private struct RadioSettingsPageSheet<Content: View>: View {
  var isBusy = false
  var detents: Set<PresentationDetent> = [.medium, .large]
  /// Keeps a swipe from closing the sheet, so Done can ask first (unapplied edits).
  var blocksSwipeDismiss = false
  let onDone: () -> Void
  @ViewBuilder let content: () -> Content

  var body: some View {
    NavigationStack {
      CardForm {
        content()
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done, action: onDone)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
        }
      }
    }
    .presentationDetents(detents)
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(isBusy || blocksSwipeDismiss)
  }
}
