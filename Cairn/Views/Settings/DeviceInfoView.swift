import CoreLocation
import CairnServices
import MeshCore
import OSLog
import SwiftUI

private let deviceInfoLogger = Logger(subsystem: "cvhvisuals.Cairn", category: "DeviceInfoView")

/// Device Info, opened from Home's header card and the radio status menu: the connected radio laid
/// out like a repeater's or room's Dashboard. A map header at its position names it ("Companion ·
/// Heltec V3"), renames it from the pencil, and copies the key from its chip; Share in the bar shares
/// the contact (importing or regenerating the key is under Connection & Security). Right under the
/// header, the radio's own sensors as one compact row; then the Clock row and Home-style cards: firmware, storage, the radio's limits and
/// the counters it keeps since boot. Each fact shows once; live radio figures stay in Spectrum and
/// the battery on its own page. Counters and sensors are read once per visit; pull to refresh (or
/// ⌘R, the only way on a Mac) re-reads everything. The header says how the radio is linked
/// (Ready, Connecting…, over Bluetooth or WiFi); Disconnect is on the bar's right, and asks first. With no radio linked the page says so and
/// offers My Radios, so it is never a dead end.
struct DeviceInfoView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var showShareSheet = false
  /// The header map, full screen: where the radio is, when its map is tapped. The sheet is driven
  /// by the position itself, so it never opens before the position is there to show.
  @State private var fullMap: FullMapTarget?
  @State private var confirmsDisconnect = false
  /// Opens Firmware Update from the firmware card. In Settings it is pushed over this page; the
  /// sheet from the toolbar's radio button (`DeviceInfoSheet`) hands it to Settings instead, where
  /// the update holds its pages while the board installs.
  private let onOpenFirmwareUpdate: (() -> Void)?
  /// Opens Connections from the toolbar's Connections button (and the disconnected page's): in
  /// Settings it is pushed over this page (or goes back to the Connections this page was opened
  /// from); the sheet hands it to Settings.
  private let onOpenConnections: (() -> Void)?
  /// Opens one of the radio's settings pages from the Radio Settings rows: in Settings it is pushed
  /// over this page; the sheet hands it to Settings, as Firmware Update and Connections are.
  private let onOpenSetting: ((SettingsDetail) -> Void)?
  @State private var draftName: String = ""
  @State private var isEditingName = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var isSaving = false
  @State private var readings = DeviceReadingsModel()
  /// How far the radio's clock is from the phone's (positive: ahead), read with the readings; nil
  /// until then.
  @State private var radioClockDrift: TimeInterval?
  /// This radio's avatar photo and colour editing; kept on this phone, never sent to the radio.
  @State private var avatarEditor = AvatarEditor()
  /// Read so the header's altitude redraws in the new units when the setting changes.
  @AppStorage(AppStorageKey.measurementSystem.rawValue)
  private var measurementSystem: MeasurementSystemPreference = .system

  private var isReady: Bool { appState.connectionState == .ready }

  init(
    onOpenFirmwareUpdate: (() -> Void)? = nil,
    onOpenConnections: (() -> Void)? = nil,
    onOpenSetting: ((SettingsDetail) -> Void)? = nil
  ) {
    self.onOpenFirmwareUpdate = onOpenFirmwareUpdate
    self.onOpenConnections = onOpenConnections
    self.onOpenSetting = onOpenSetting
  }

  var body: some View {
    Group {
      if let device = appState.connectedDevice {
        ScrollView {
          page(device)
        }
      } else {
        // Not in the scroll view: the empty state fills the page and scrolls its own content when
        // it doesn't fit (the largest text, a landscape phone), which inside a scroll view it can't.
        noDevice
      }
    }
    .cardCanvas(theme)
    .scrollDismissesKeyboard(.interactively)
    .flashingNavigationTitle(L10n.Settings.DeviceInfo.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { disconnectToolbar }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
    .refreshable { await refreshAll() }
    // No Refresh in the bar, even on a Mac: there it is ⌘R.
    .refreshCommand(showsMacToolbarButton: false) { await refreshAll() }
    .task {
      deviceInfoLogger.info("DeviceInfoView: appeared, connectedDevice=\(appState.connectedDevice != nil)")
      await appState.batteryMonitor.fetchDeviceBattery(services: appState.services, device: appState.connectedDevice)
    }
    // Without a radio this page has nothing to show, so it goes on to My Radios, where one is
    // connected or added: at once when opened without one, and when the radio goes (Disconnect
    // here, or the link dropping). The user didn't want the placeholder page (2026-11-07).
    .task(id: appState.connectedDevice == nil) {
      guard appState.connectedDevice == nil else { return }
      openConnections()
    }
    // One read per visit, taken once the radio is ready (now, or after a reconnect mid-visit).
    .task(id: isReady) {
      if isReady, !readings.hasLoaded {
        await loadReadings()
      }
    }
    .modifier(RadioAvatarEditingModifier(editor: avatarEditor))
    .sheet(isPresented: $showShareSheet) {
      if let device = appState.connectedDevice {
        ContactQRShareSheet(
          contactName: device.nodeName,
          publicKey: device.publicKey,
          contactType: .chat
        )
      }
    }
    // Full screen as the GPS tab's map, or on a Mac a push onto this page's stack.
    .nodeMapPresentation(item: $fullMap) { target, presented in
      NodeOnMapView(
        focus: .thisRadio(coordinate: target.coordinate),
        title: appState.connectedDevice?.nodeName ?? "",
        isPresented: presented
      )
    }
  }

  // MARK: - Page

  /// The connected radio's page: the header, the tiles, the sensors and the cards.
  private func page(_ device: DeviceDTO) -> some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      header(device)

      if isEditingName {
        DeviceNameEditor(
          device: device,
          isEditingName: $isEditingName,
          draftName: $draftName,
          isSaving: isSaving,
          canEditName: isReady,
          onSaveName: saveNodeName
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      // The radio's clock as one row above the cards: its time now, opening the Clock page (sync,
      // and the zone the radio's screen shows the time in).
      clockRow

      NodeDashboardCardGrid(items: cards(device))

      if readings.radioDidNotAnswer {
        Label(L10n.Settings.DeviceInfo.noAnswer, systemImage: "exclamationmark.arrow.circlepath")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }

      // The rest of the radio's settings, so this page is where everything about the radio starts.
      radioSettingsRows
    }
    .padding(CardStyle.pageInset)
    .animation(.snappy(duration: 0.2), value: isEditingName)
    .animation(.snappy(duration: 0.2), value: readings.sensorsLoaded)
  }

  // MARK: - Radio settings

  /// The hub's THIS RADIO pages but this one, as its rows: pushed over this page in Settings, handed
  /// to Settings from the sheet.
  private var radioSettingsRows: some View {
    CardFormSection(L10n.Settings.DeviceInfo.Settings.header) {
      ForEach(SettingsDetail.thisRadio.filter { $0 != .deviceInfo }, id: \.self) { detail in
        Button {
          openSetting(detail)
        } label: {
          NavigationTile(detail.title, systemImage: detail.systemImage, color: detail.color)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("deviceInfo.settings.\(detail)")
      }
    }
    .environment(\.isInSettings, true)
  }

  /// Clock: the radio's time (read with the readings) and its zone, opening the Clock page.
  private var clockRow: some View {
    Button {
      openSetting(.clock)
    } label: {
      NavigationTile(
        SettingsDetail.clock.title,
        systemImage: SettingsDetail.clock.systemImage,
        color: SettingsDetail.clock.color,
        detail: clockSummary
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("deviceInfo.clock")
  }

  /// "9:41 PM · in sync": the radio's own time (the phone's plus the drift read with the readings)
  /// and how far it is from the phone; "Not set" for a clock never set; "Reading…" before the read.
  private var clockSummary: String {
    let strings = L10n.Settings.Clock.self
    guard let drift = radioClockDrift else { return strings.reading }
    let radioTime = Date.now.addingTimeInterval(drift)
    guard radioTime.timeIntervalSince1970 > 1_735_689_600 else { return strings.notSet }
    let time = radioTime.formatted(date: .omitted, time: .shortened)
    if abs(drift) <= 5 { return strings.inSync(time) }
    let amount = Duration.seconds(abs(drift).rounded())
      .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    return drift > 0 ? strings.ahead(time, amount) : strings.behind(time, amount)
  }

  private func openSetting(_ detail: SettingsDetail) {
    if let onOpenSetting {
      onOpenSetting(detail)
    } else {
      appState.navigation.settingsPath.append(detail)
    }
  }

  // MARK: - Header

  /// The radio on a map at its position, as every node page starts, then one band that reads
  /// across: the avatar, name (with a small rename pencil while the radio can take a new name) and
  /// "Companion · <model>" on the leading side, how it's linked (Ready, over Bluetooth) opposite;
  /// under them one row of facts: the coordinates, the altitude and the key chip. The position is
  /// the radio's own GPS fix once a sensor read brings one, else the one it advertises (no
  /// altitude then). Without a position it's the band on its own. A long press copies the
  /// coordinates or opens them in Maps, as on a repeater's Dashboard.
  private func header(_ device: DeviceDTO) -> some View {
    let fix = readings.sensorGPSFix
    let coordinate = fix.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
      ?? (device.hasLocation ? CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude) : nil)
    let coordinateText = coordinate.map { HomeFormat.coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    let altitudeText = fix.map { LocationReportFormat.altitude($0.altitude) }
    let canRename = isReady && !isSaving && !isEditingName
    return NodeMapHeader(
      coordinate: coordinate,
      marker: .contactChat,
      markerAvatar: MapPinAvatar(device: device, store: appState.radioAvatars),
      title: device.nodeName,
      subtitle: Self.subtitle(for: device),
      onTapMap: coordinate.map { tapped in { fullMap = FullMapTarget(coordinate: tapped) } },
      onEditTitle: canRename ? {
        draftName = device.nodeName
        isEditingName = true
      } : nil,
      footer: AnyView(factsRow(device, coordinates: coordinateText, altitude: altitudeText)),
      chips: AnyView(DeviceKeyChip(publicKey: device.publicKey, compact: true)),
      showsDistance: false,
      trailing: AnyView(linkStatus)
    ) {
      // A photo and colour for this radio, kept on this phone only.
      AvatarEditButton(
        editor: avatarEditor,
        name: device.nodeName,
        hasPhoto: appState.radioAvatars.photo(for: device.radioID) != nil,
        size: NodeMapHeader<EmptyView>.avatarSize,
        actions: RadioAvatarEditingModifier.actions(appState: appState, radioID: device.radioID)
      ) {
        RadioAvatar(device: device, size: NodeMapHeader<EmptyView>.avatarSize)
      }
    }
    .contextMenu {
      if let coordinate {
        Button(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc") {
          UIPasteboard.general.string = "\(coordinate.latitude), \(coordinate.longitude)"
        }
        Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
          NodeLocation.openInMaps(name: device.nodeName, coordinate: coordinate)
        }
      }
    }
  }

  /// How the radio is linked, at the end of the subtitle line: the state with its dot (green once
  /// ready) and the transport's glyph, on one capsule.
  private var linkStatus: some View {
    let state = appState.connectionState
    let tint: Color = switch state {
    case .ready: AppColors.Radio.readyText
    case .disconnected: .secondary
    case .connecting, .connected, .syncing: .orange
    }
    let transport = appState.connectionManager.currentTransportType
    return HStack(spacing: 5) {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
      Text(HomeStatusLines.linkTitle(state))
      if let transport, state != .disconnected {
        // the Bluetooth or Wi-Fi glyph in the link's colour (green once ready)
        Image(systemName: transport.symbol)
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.12), in: .capsule)
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Settings.DeviceInfo.Connection.header)
    .accessibilityValue(NodeRouteFormat.joined([
      HomeStatusLines.linkTitle(state),
      state == .disconnected ? nil : transport?.displayName,
    ]))
  }

  /// The band's second part, shared with every node page (`NodeHeaderFacts`): where the radio is
  /// (the coordinates and the altitude) with the key chip opposite, then its sensors.
  private func factsRow(_ device: DeviceDTO, coordinates: String?, altitude: String?) -> some View {
    NodeHeaderFacts(coordinates: coordinates, altitude: altitude, sensorGroups: sensorGroups) {
      EmptyView()
    }
  }

  /// "Companion · Heltec V3": the radio's role, then its model, falling back to a generic name
  /// when the radio doesn't report one. The firmware has its own card below.
  static func subtitle(for device: DeviceDTO) -> String {
    let model = device.manufacturerName.isEmpty
      ? L10n.Settings.DeviceInfo.defaultManufacturer
      : device.manufacturerName
    return NodeRouteFormat.joined([L10n.Settings.DeviceInfo.companion, model])
  }

  // MARK: - Sensors

  /// The radio's own readings besides the battery voltage (the Battery page's) and the GPS fix (the
  /// header's GPS line), as the header's sensor row shows them: one group per channel. Empty until
  /// a read brings a reading back.
  private var sensorGroups: [DeviceSensorChipGroup] {
    guard readings.sensorsLoaded else { return [] }
    return readings.sensorChipGroups(cairnFirmware: appState.connectedDevice?.isCairnFirmware == true)
      .compactMap { group -> DeviceSensorChipGroup? in
        let chips = group.chips.filter { if case .gps = $0.kind { false } else { true } }
        return chips.isEmpty ? nil : DeviceSensorChipGroup(channel: group.channel, title: group.title, chips: chips)
      }
  }

  // MARK: - Connections

  /// No radio linked: says so, and offers Connections, where a saved radio is connected or a new
  /// one added, as the toolbar does.
  private var noDevice: some View {
    ContentUnavailableView {
      Label(L10n.Settings.DeviceInfo.NoDevice.title, systemImage: "antenna.radiowaves.left.and.right.slash")
    } description: {
      Text(L10n.Settings.DeviceInfo.NoDevice.description)
    } actions: {
      Button(SettingsDetail.connections.title, systemImage: SettingsDetail.connections.systemImage) {
        openConnections()
      }
      .liquidGlassProminentButtonStyle()
      .accessibilityIdentifier("deviceInfo.noDevice.connections")
    }
  }

  /// Disconnect, on the bar's right while a radio is linked or linking (Back is on its left,
  /// pushed or as a sheet). It asks first, since the radio then stops syncing until it's
  /// connected again.
  @ToolbarContentBuilder
  private var disconnectToolbar: some ToolbarContent {
    // Share My Contact (the QR sheet): an action on the radio, not a section, so it sits in the bar
    // rather than taking a row of the page (user, 2026-11-07).
    if appState.connectedDevice != nil {
      ToolbarItem(placement: .topBarTrailing) {
        Button(L10n.Settings.DeviceInfo.shareContact, systemImage: "square.and.arrow.up") {
          showShareSheet = true
        }
        .accessibilityIdentifier("deviceInfo.share")
      }
    }
    if appState.connectionState != .disconnected {
      ToolbarItem(placement: .topBarTrailing) {
        Button(L10n.Settings.BleStatus.disconnect, systemImage: "antenna.radiowaves.left.and.right.slash") {
          confirmsDisconnect = true
        }
        .tint(.red)
        .accessibilityIdentifier("deviceInfo.disconnect")
        .confirmationDialog(
          L10n.Settings.DeviceInfo.DisconnectConfirm.title(appState.connectedDevice?.nodeName ?? ""),
          isPresented: $confirmsDisconnect,
          titleVisibility: .visible
        ) {
          Button(L10n.Settings.BleStatus.disconnect, role: .destructive) {
            Task { await appState.disconnect(reason: .userInitiated) }
          }
          .accessibilityIdentifier("deviceInfo.disconnect.confirm")
        } message: {
          Text(L10n.Settings.DeviceInfo.DisconnectConfirm.message)
        }
      }
    }
  }

  /// My Radios, from the disconnected page: the presenter's (the
  /// sheet hands it to Settings), else pushed in Settings' own stack.
  private func openConnections() {
    if let onOpenConnections {
      onOpenConnections()
    } else {
      let navigation = appState.navigation
      navigation.settingsPath = DeviceInfoConnections.settingsPath(openingConnectionsFrom: navigation.settingsPath)
    }
  }

  // MARK: - Cards

  /// The fixed facts, then the counters: firmware, storage, limits, since boot. The sensors sit in
  /// their own strip near the top.
  private func cards(_ device: DeviceDTO) -> [NodeDashboardCardItem] {
    var cards = [
      firmwareCard(device),
      storageCard(appState.batteryMonitor.deviceBattery),
      limitsCard(device),
    ]
    if let sinceBoot = readings.sinceBootCard {
      cards.append(sinceBoot)
    }
    return cards
  }

  /// The firmware with its build date. On Cairn firmware the reading is the Cairn build, and the
  /// MeshCore version it is based on moves into the details, and the card opens Firmware Update
  /// (which says so when this build can't be updated from the app).
  private func firmwareCard(_ device: DeviceDTO) -> NodeDashboardCardItem {
    let version = device.firmwareVersionString.isEmpty
      ? L10n.Settings.DeviceInfo.firmwareVersionFormat(device.firmwareVersion)
      : device.firmwareVersionString
    var details: [String] = []
    if device.isCairnFirmware {
      details.append(L10n.Settings.DeviceInfo.meshcoreBase(version))
    }
    if !device.buildDate.isEmpty {
      details.append(device.buildDate)
    }
    return NodeDashboardCardItem(
      id: "firmware",
      title: L10n.Settings.DeviceInfo.Firmware.header,
      systemImage: "memorychip",
      tint: device.isCairnFirmware ? .teal : .gray,
      value: device.cairnFirmwareName ?? version,
      details: details,
      destination: canUpdateFirmware(device)
        ? .action { openFirmwareUpdate() }
        : .none
    )
  }

  private func openFirmwareUpdate() {
    if let onOpenFirmwareUpdate {
      onOpenFirmwareUpdate()
    } else {
      appState.navigation.settingsPath.append(.firmwareUpdate)
    }
  }

  /// Only Cairn firmware can answer the app's update request; the demo radio has nothing to update.
  private func canUpdateFirmware(_ device: DeviceDTO) -> Bool {
    #if DEBUG
      // UI tests drive the card's hand-off on the demo radio: `-uiTestFirmwareCard YES`.
      if device.isCairnFirmware, UserDefaults.standard.bool(forKey: "uiTestFirmwareCard") { return true }
    #endif
    return device.isCairnFirmware && device.id != MockDataProvider.simulatorDeviceID
  }

  /// Storage. The radio reports it with the battery reading, so the page still asks for one; the
  /// battery itself has its own page. The percentage turns orange, then red, as it fills.
  private func storageCard(_ battery: BatteryInfo?) -> NodeDashboardCardItem {
    let used = battery?.usedStorageKB ?? 0
    let total = battery?.totalStorageKB ?? 0
    let ratio = total > 0 ? Double(used) / Double(total) : 0
    let color = Self.storageColor(ratio)
    return NodeDashboardCardItem(
      id: "storage",
      title: L10n.Settings.OfflineMaps.storage,
      systemImage: "internaldrive",
      tint: battery == nil ? .gray : color,
      value: battery == nil
        ? DeviceReadingsModel.placeholder
        : ratio.formatted(.percent.precision(.fractionLength(0))),
      valueTint: battery == nil ? .secondary : (ratio < Self.storageWarnRatio ? .primary : color),
      details: battery == nil ? [] : [formatStorage(used: used, total: total)],
      destination: .none
    )
  }

  /// What the radio can hold and send: nodes, channels and its maximum transmit power.
  private func limitsCard(_ device: DeviceDTO) -> NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "limits",
      title: L10n.Settings.DeviceInfo.Capabilities.header,
      systemImage: "slider.horizontal.3",
      tint: .orange,
      value: device.maxContacts.formatted(),
      note: L10n.Settings.DeviceInfo.maxNodes,
      details: [
        "\(L10n.Settings.DeviceInfo.maxChannels) \(device.maxChannels.formatted())",
        "\(L10n.Settings.DeviceInfo.maxTxPower) \(TxPowerText.reading(setting: Int(device.maxTxPower), model: device.manufacturerName))",
      ],
      destination: .none
    )
  }

  /// Below this share of storage used, the percentage stays in the primary colour.
  private static let storageWarnRatio = 0.7

  private static func storageColor(_ ratio: Double) -> Color {
    switch ratio {
    case 0..<storageWarnRatio: .green
    case storageWarnRatio..<0.9: .orange
    default: .red
    }
  }

  /// Firmware reports storage in binary kilobytes.
  private static let bytesPerKilobyte = 1024

  private func formatStorage(used: Int, total: Int) -> String {
    let style = ByteCountFormatStyle(style: .memory)
    let usedBytes = Int64(used) * Int64(Self.bytesPerKilobyte)
    let totalBytes = Int64(total) * Int64(Self.bytesPerKilobyte)
    return "\(usedBytes.formatted(style)) / \(totalBytes.formatted(style))"
  }

  // MARK: - Loading

  private func loadReadings() async {
    if appState.connectedDevice?.id == MockDataProvider.simulatorDeviceID {
      readings.loadSimulated(telemetry: MockDataProvider.selfTelemetryFrame)
      return
    }
    if let time = try? await appState.services?.settingsService.getTime() {
      radioClockDrift = time.timeIntervalSinceNow
    }
    await readings.load(
      settingsService: appState.services?.settingsService,
      binaryProtocolService: appState.services?.binaryProtocolService
    )
  }

  /// Pull-to-refresh and the refresh command both re-read everything.
  private func refreshAll() async {
    await appState.batteryMonitor.fetchDeviceBattery(services: appState.services, device: appState.connectedDevice)
    guard isReady else { return }
    await loadReadings()
  }

  // MARK: - Name

  private func saveNodeName() {
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
          let settingsService = appState.services?.settingsService else { return }

    isSaving = true
    Task {
      do {
        _ = try await settingsService.setNodeNameVerified(name)
        retryAlert.reset()
        isEditingName = false
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { saveNodeName() },
          onMaxRetriesExceeded: { dismiss() }
        )
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}

#Preview {
  NavigationStack {
    DeviceInfoView()
      .environment(\.appState, AppState())
  }
}

/// Icon then text, close together, so the GPS line's two values read as two compact pairs.
struct GPSLineLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
      configuration.title
    }
  }
}

/// The pickers, crop step and colour sheet for the connected radio's own avatar.
private struct RadioAvatarEditingModifier: ViewModifier {
  @Environment(\.appState) private var appState
  let editor: AvatarEditor

  func body(content: Content) -> some View {
    // Applied whatever the connection, so the page keeps one identity when the radio drops.
    let device = appState.connectedDevice
    let radioID = device?.radioID
    let photo = appState.radioAvatars.photo(for: radioID)
    content.avatarEditing(
      editor,
      name: device?.nodeName ?? "",
      category: .radio,
      hasPhoto: photo != nil,
      color: appState.radioAvatars.color(for: radioID),
      actions: radioID.map { Self.actions(appState: appState, radioID: $0) } ?? Self.noActions
    ) { color in
      ContactAvatar(name: device?.nodeName ?? "", size: 56, imageData: photo, color: color, category: .radio)
    }
  }

  private static let noActions = AvatarEditActions(savePhoto: { _ in }, removePhoto: {}, setColor: { _ in })

  static func actions(appState: AppState, radioID: UUID) -> AvatarEditActions {
    AvatarEditActions(
      savePhoto: { data in appState.setRadioAvatarPhoto(data, radioID: radioID) },
      removePhoto: { appState.setRadioAvatarPhoto(nil, radioID: radioID) },
      setColor: { color in appState.setRadioAvatarColor(color, radioID: radioID) }
    )
  }
}

/// A position to open full screen, as a sheet item (or on a Mac, a pushed one).
private struct FullMapTarget: Identifiable, Hashable {
  let id = UUID()
  let coordinate: CLLocationCoordinate2D

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Where Device Info's Connections button goes inside Settings. Kept apart from the view so the
/// path can be tested.
enum DeviceInfoConnections {
  /// Settings' path once Device Info's Connections is tapped there: Connections goes over Device
  /// Info, so Back returns to it (a disconnect leaves Device Info open,
  /// `SettingsDetail.popsWithoutRadio`; a connect or switch made there goes on to the Dashboard and
  /// closes Settings, as from any Connections, `ConnectionsModel`). When Device Info was opened
  /// from Connections, back to that Connections instead of a second one.
  static func settingsPath(openingConnectionsFrom path: [SettingsDetail]) -> [SettingsDetail] {
    guard let deviceInfo = path.lastIndex(of: .deviceInfo) else { return path + [.connections] }
    let below = path[..<deviceInfo]
    if let connections = below.lastIndex(of: .connections) {
      return Array(below[...connections])
    }
    return Array(path[...deviceInfo]) + [.connections]
  }
}
