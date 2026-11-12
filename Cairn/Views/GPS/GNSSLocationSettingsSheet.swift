import CoreLocation
import CairnServices
import SwiftUI
import UIKit

/// The location settings, in two Settings pages that each hold their own controls and link to the
/// other:
///
/// - Maps & GPS (`.gpsTab`, `GPSSettingsView`, also what the GPS tab's sliders open): where the
///   radio's position comes from (auto-update from the phone or the radio's GPS, with Eco on
///   firmware that has it, or set by hand), the phone's location permission, then the maps
///   (`MapsSettingsSections`).
/// - Location & Sharing (`.settings`, `LocationSettingsView`): the radio on a map, what its advert
///   shares, and telemetry.
///
/// Each page reads and writes through its own `GNSSDashboardModel`, read fresh when it opens; the
/// GPS tab reloads its own once Settings closes.
struct GNSSLocationSettingsSheet: View {
  /// Which of the two pages this is.
  enum Context {
    /// GPS & Location: the position's source, and Maps.
    case gpsTab
    /// Location & Sharing: what the radio shares.
    case settings
  }

  let model: GNSSDashboardModel
  let live: GPSLiveLocation
  var context: Context = .gpsTab

  @Environment(\.appState) private var appState
  @Environment(\.openURL) private var openURL
  @State private var showingLocationPicker = false
  @State private var showingDeviceSelection = false

  private var device: DeviceDTO? { appState.connectedDevice }
  private var hasReceiver: Bool { model.radio.receiver?.isSupported == true }

  var body: some View {
    CardForm {
      switch context {
      // The controls sit right on the page here, a tap away from the toolbar, rather than behind
      // summary cards: the settings people come to the GPS tab to change.
      case .gpsTab:
        positionSection
        phoneSection
        if let device {
          sharingLinkSection(device)
        }
        MapsSettingsSections()
      case .settings:
        if let device {
          header(device)
          sharingSection(device)
          LocationTelemetrySection(device: device)
          gpsLinkSection
        }
      }
    }
    .task(id: device?.id) {
      // The receiver's state decides which cards show; read it if the page hasn't yet (the
      // sheet can open from the Map segment).
      if model.radio.receiver == nil {
        await model.refresh(appState: appState, isActive: true)
      }
    }
    .sheet(isPresented: $showingLocationPicker, onDismiss: {
      model.loadPreferences(for: appState.connectedDevice)
    }) {
      LocationPickerView.forLocalDevice(appState: appState)
    }
    .sheet(isPresented: $showingDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    .errorAlert(errorBinding)
    .alert(L10n.Onboarding.Permissions.LocationAlert.title, isPresented: deniedAlertBinding) {
      Button(L10n.Onboarding.Permissions.LocationAlert.openSettings, action: openAppSettings)
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Onboarding.Permissions.LocationAlert.message)
    }
  }

  // MARK: - Position

  /// Where the radio's position comes from: kept current by the phone or the radio's own GPS
  /// (with Eco under it, on firmware that has it), or set by hand. What the advert carries is
  /// its own setting, under Sharing.
  private var positionSection: some View {
    CardFormSection(L10n.Settings.Location.Position.header, info: device == nil ? nil : positionInfo) {
      if device != nil {
        Group {
          PickerCard(
            L10n.Settings.Location.autoUpdate,
            systemImage: "location.circle.fill",
            color: .blue,
            selection: positionUpdatesBinding
          ) {
            Text(L10n.Localizable.Accessibility.off).tag(GNSSDashboardModel.PositionUpdates.off)
            Text(L10n.Settings.Location.GpsSource.phone).tag(GNSSDashboardModel.PositionUpdates.phone)
            if hasReceiver {
              Text(L10n.Settings.Location.GpsSource.device).tag(GNSSDashboardModel.PositionUpdates.radioGPS)
            }
          }
          if model.positionUpdates == .radioGPS, model.radio.receiver?.supportsEco == true {
            ToggleCard(
              L10n.Settings.Location.DeviceGps.eco,
              systemImage: "leaf.fill",
              color: .green,
              subtitle: L10n.Settings.Location.DeviceGps.ecoFooter,
              isOn: ecoBinding
            )
          }
          ActionCard(
            L10n.Map.Map.Gps.Control.setManually,
            systemImage: "mappin.and.ellipse",
            color: .red
          ) {
            showingLocationPicker = true
          }
          // A position set by hand would be overwritten by the next update.
          .disabled(model.positionUpdates != .off)
        }
        .radioDisabled(for: appState.connectionState, or: model.isSaving)
      } else {
        ActionCard(
          L10n.Settings.Device.connect,
          systemImage: "antenna.radiowaves.left.and.right",
          color: .orange
        ) {
          showingDeviceSelection = true
        }
      }
    }
  }

  /// What auto-update does, from each source.
  private var positionInfo: String {
    var lines = [L10n.Settings.Location.Position.footer, L10n.Map.Map.Gps.Control.UsePhone.footer]
    if hasReceiver {
      lines.append(L10n.Map.Map.Gps.Control.UsePhone.receiverNote)
      lines.append(L10n.Settings.Location.DeviceGps.footer)
    }
    return lines.joined(separator: "\n\n")
  }

  // MARK: - Phone

  /// The phone's location permission, while it stops the phone being a source: ask, open
  /// Settings, or ask for precise location.
  @ViewBuilder
  private var phoneSection: some View {
    let needsPermission = live.authorizationStatus != .authorizedWhenInUse
      && live.authorizationStatus != .authorizedAlways
    if needsPermission || live.isApproximate {
      CardFormSection(
        L10n.Map.Map.Gps.PhoneSection.header,
        info: live.isApproximate ? L10n.Map.Map.Gps.Precise.message : nil
      ) {
        switch live.authorizationStatus {
        case .notDetermined:
          ActionCard(L10n.Map.Map.Gps.allow, systemImage: "location.fill", color: .blue) {
            appState.locationService.requestPermissionIfNeeded()
          }
        case .denied, .restricted:
          ActionCard(
            L10n.Onboarding.Permissions.LocationAlert.openSettings,
            systemImage: "gear",
            color: .gray,
            subtitle: L10n.Map.Map.Gps.Status.notAllowed,
            action: openAppSettings
          )
        default:
          ActionCard(
            L10n.Map.Map.Gps.Precise.title,
            systemImage: "scope",
            color: .blue,
            subtitle: L10n.Map.Map.Gps.Accuracy.approximate,
            action: openAppSettings
          )
        }
      }
    }
  }

  // MARK: - Sharing

  private func sharingSection(_ device: DeviceDTO) -> some View {
    let policy = device.advertLocationPolicyMode
    let advertised = device.hasLocation ? CLLocation(latitude: device.latitude, longitude: device.longitude) : nil
    return CardFormSection(
      L10n.Settings.LocationSharing.title,
      info: L10n.Settings.Location.Advert.footer
    ) {
      PickerCard(
        L10n.Map.Map.Gps.Advert.title,
        systemImage: "dot.radiowaves.up.forward",
        color: .blue,
        subtitle: GNSSRelationship.advertVersusFix(policy: policy, advertised: advertised, fix: radioFix),
        selection: advertBinding
      ) {
        ForEach(advertOptions(current: policy), id: \.self) { option in
          Text(option.gnssText).tag(option)
        }
      }
      .radioDisabled(for: appState.connectionState, or: model.isSaving)
    }
  }

  // MARK: - Links

  /// From Maps & GPS to what the radio shares, pushed inside Settings.
  private func sharingLinkSection(_ device: DeviceDTO) -> some View {
    CardFormSection {
      NavigationLink(value: SettingsDetail.location) {
        NavigationTile(
          L10n.Settings.LocationSharing.title,
          systemImage: "dot.radiowaves.up.forward",
          color: .blue,
          detail: device.locationSharingSummary
        )
      }
      .buttonStyle(.plain)
    }
  }

  /// From Location & Sharing to where the position comes from (Maps & GPS), pushed inside
  /// Settings. Opened from Maps & GPS, Back is the way there, so the link is left out rather than
  /// letting the two pages open each other round and round.
  @ViewBuilder
  private var gpsLinkSection: some View {
    if !appState.navigation.settingsPath.contains(.gps) {
      CardFormSection {
        NavigationLink(value: SettingsDetail.gps) {
          NavigationTile(
            SettingsDetail.gps.title,
            systemImage: "location.circle.fill",
            color: .green,
            detail: positionUpdatesText
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// The auto-update source in a word, as its picker says it.
  private var positionUpdatesText: String {
    switch model.positionUpdates {
    case .off: L10n.Map.Map.Gps.Source.savedCaption
    case .phone: L10n.Settings.Location.GpsSource.phone
    case .radioGPS:
      model.radio.receiver?.isEco == true
        ? "\(L10n.Settings.Location.GpsSource.device) · \(L10n.Settings.Location.DeviceGps.eco)"
        : L10n.Settings.Location.GpsSource.device
    }
  }

  // MARK: - Header

  /// The radio on a map at the position it shares, with who can see it. Without a position it's
  /// the name and sharing line alone, as on any node page.
  private func header(_ device: DeviceDTO) -> some View {
    let coordinate = device.hasLocation
      ? CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
      : nil
    return NodeMapHeader(
      coordinate: coordinate,
      marker: .contactChat,
      markerAvatar: MapPinAvatar(device: device, store: appState.radioAvatars),
      title: device.nodeName,
      subtitle: device.locationSharingSummary,
      infoLine: coordinate.map { HomeFormat.coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    ) {
      RadioAvatar(device: device, size: NodeMapHeader<EmptyView>.avatarSize)
        .accessibilityHidden(true)
    }
  }

  /// The radio's live GPS point while it has a fix, to compare the advert with.
  private var radioFix: CLLocation? {
    guard model.radio.status == .fix, let point = model.radio.telemetry else { return nil }
    return CLLocation(latitude: point.latitude, longitude: point.longitude)
  }

  /// Live GPS only while the radio's own GPS keeps the position current; a radio already set to
  /// it keeps the choice listed.
  private func advertOptions(current: AdvertLocationPolicy) -> [AdvertLocationPolicy] {
    model.positionUpdates == .radioGPS || current == .share ? [.none, .prefs, .share] : [.none, .prefs]
  }

  // MARK: - Bindings

  private var positionUpdatesBinding: Binding<GNSSDashboardModel.PositionUpdates> {
    Binding(
      get: { model.positionUpdates },
      set: { model.setPositionUpdates($0, appState: appState) }
    )
  }

  private var ecoBinding: Binding<Bool> {
    Binding(
      get: { model.radio.receiver?.isEco ?? false },
      set: { model.setEco($0, appState: appState) }
    )
  }

  private var advertBinding: Binding<AdvertLocationPolicy> {
    Binding(
      get: { appState.connectedDevice?.advertLocationPolicyMode ?? .none },
      set: { model.setAdvertPolicy($0, appState: appState) }
    )
  }

  private var errorBinding: Binding<String?> {
    Binding(
      get: { model.errorMessage },
      set: { model.errorMessage = $0 }
    )
  }

  private var deniedAlertBinding: Binding<Bool> {
    Binding(
      get: { model.showLocationDeniedAlert },
      set: { model.showLocationDeniedAlert = $0 }
    )
  }

  private func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
      openURL(url)
    }
  }
}

/// Settings › Maps & GPS (`SettingsDetail.gps`), also what the GPS tab's sliders open.
struct GPSSettingsView: View {
  @State private var model = GNSSDashboardModel()
  @State private var live = GPSLiveLocation(tracksHeading: false)

  var body: some View {
    GNSSLocationSettingsSheet(model: model, live: live, context: .gpsTab)
      .flashingNavigationTitle(SettingsDetail.gps.title)
      .navigationBarTitleDisplayMode(.inline)
  }
}
