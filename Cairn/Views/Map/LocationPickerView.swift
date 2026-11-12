import CoreLocation
import MapKit
import CairnServices
import SwiftUI

/// What the picker's confirm button does, derived from what the map shows.
enum LocationPickerConfirmation {
  /// No pin and nothing stored to clear, so there is nothing to confirm.
  case unavailable
  /// The pin on the map, which the coordinate readout mirrors.
  case coordinate(CLLocationCoordinate2D)
  /// No pin where a node has a stored position: confirming removes that position.
  case clearStoredPosition

  /// The map centre under the crosshair is never a selection on its own. A pin at an
  /// invalid coordinate or at 0,0, the "no position" sentinel, counts as no pin.
  static func resolve(
    pin: CLLocationCoordinate2D?,
    storedCoordinate: CLLocationCoordinate2D?,
    purpose: LocationPickerView.Purpose
  ) -> LocationPickerConfirmation {
    if let pin, pin.isValidFix {
      return .coordinate(pin)
    }
    guard purpose == .nodePosition,
          let storedCoordinate,
          storedCoordinate.latitude != 0 || storedCoordinate.longitude != 0 else {
      return .unavailable
    }
    return .clearStoredPosition
  }
}

/// Map-based location picker for setting node position
struct LocationPickerView: View {
  /// What the picked point is for.
  enum Purpose {
    /// Stores a node's position over the radio. Saving after removing the pin of a stored
    /// position clears that position.
    case nodePosition
    /// Hands the point to the caller without touching the radio, such as a chat share.
    case share
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme

  // Configuration
  private let initialCoordinate: CLLocationCoordinate2D?
  private let purpose: Purpose
  private let onSave: (CLLocationCoordinate2D) async throws -> Void

  /// Stable marker identity
  private let markerID = UUID()

  // UI State
  @State private var cameraRegion: MKCoordinateRegion?
  @State private var cameraRegionVersion = 0
  @State private var selectedCoordinate: CLLocationCoordinate2D?
  @State private var isSaving = false
  @State private var errorMessage: String?
  /// The fix being fetched to move the map to the phone, on opening or from the locate button.
  @State private var locateTask: Task<Void, Never>?
  /// The locate button's failure: Location off for the app, or no fix yet.
  @State private var locateFeedback: MapLocateFeedback?

  /// Generic initializer for any location-setting context
  init(
    initialCoordinate: CLLocationCoordinate2D? = nil,
    purpose: Purpose = .nodePosition,
    onSave: @escaping (CLLocationCoordinate2D) async throws -> Void
  ) {
    self.initialCoordinate = initialCoordinate
    self.purpose = purpose
    self.onSave = onSave
  }

  private var confirmation: LocationPickerConfirmation {
    LocationPickerConfirmation.resolve(
      pin: selectedCoordinate,
      storedCoordinate: initialCoordinate,
      purpose: purpose
    )
  }

  var body: some View {
    NavigationStack {
      ZStack {
        CairnMapView(
          points: markerPoints,
          lines: [],
          mapStyle: .standard,
          isDarkMode: colorScheme == .dark,
          showLabels: false,
          showsUserLocation: true,
          isInteractive: true,
          showsScale: false,
          cameraRegion: $cameraRegion,
          cameraRegionVersion: cameraRegionVersion,
          onPointTap: nil,
          onMapTap: { coord in
            // A pin placed by hand keeps the map where it is.
            locateTask?.cancel()
            locateTask = nil
            placePin(at: coord)
          },
          onCameraRegionChange: { region in cameraRegion = region }
        )

        // Center crosshair for precise placement
        Image(systemName: "plus")
          .font(.title)
          .foregroundStyle(.secondary)

        locateButton
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding()

        // Coordinate display and actions
        VStack {
          Spacer()

          Group {
            switch confirmation {
            case let .coordinate(coord):
              VStack(spacing: 4) {
                CoordinateText(
                  label: L10n.Settings.LocationPicker.latitude,
                  value: coord.latitude
                )
                CoordinateText(
                  label: L10n.Settings.LocationPicker.longitude,
                  value: coord.longitude
                )
              }
              .font(.caption.monospacedDigit())
            case .clearStoredPosition:
              Text(L10n.Settings.LocationPicker.noLocation)
                .font(.caption)
            case .unavailable:
              Text(L10n.Settings.LocationPicker.noPinHint)
                .font(.caption)
                .multilineTextAlignment(.center)
            }
          }
          .padding()
          .background {
            if #available(iOS 26.0, *) {
              Color.clear
            } else {
              RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
            }
          }
          .modifier(CoordinateGlassModifier())
          .padding(.horizontal)

          Group {
            if #available(iOS 26.0, *) {
              GlassEffectContainer {
                makeButtonContent()
              }
            } else {
              makeButtonContent()
            }
          }
          .padding()
          .padding(.bottom, 16)
        }
      }
      .flashingNavigationTitle(
        purpose == .share ? L10n.Settings.LocationPicker.chooseTitle : L10n.Settings.LocationPicker.title
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          confirmButton
          .keyboardShortcut(.defaultAction)
        }
      }
      .onAppear {
        loadCurrentLocation()
        centerOnPhone()
      }
      .onDisappear {
        locateTask?.cancel()
      }
      .errorAlert($errorMessage)
    }
  }

  private var markerPoints: [MapPoint] {
    guard let coord = selectedCoordinate else { return [] }
    return [MapPoint(
      id: markerID,
      coordinate: coord,
      pinStyle: .pointA,
      label: nil,
      isClusterable: false,
      hopIndex: nil,
      badgeText: nil
    )]
  }

  private func loadCurrentLocation() {
    // Case 1: Existing saved location
    if let coord = initialCoordinate,
       CLLocationCoordinate2DIsValid(coord),
       coord.latitude != 0 || coord.longitude != 0 {
      selectedCoordinate = coord
      cameraRegion = MKCoordinateRegion(
        center: coord,
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
      )
      cameraRegionVersion += 1
      return
    }

    // Invalid coordinates (not nil, not zero, but out of range) — show default map
    if let coord = initialCoordinate,
       coord.latitude != 0 || coord.longitude != 0 {
      return
    }

    // Case 2: No saved location (nil or 0,0). Start from the phone's last position, or failing
    // that the radio's own, rather than a map of the whole world, until the fresh fix
    // (`centerOnPhone()`) arrives.
    if let nearby = appState.bestAvailableLocation, nearby.coordinate.isValidFix {
      cameraRegion = MKCoordinateRegion(
        center: nearby.coordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
      )
      cameraRegionVersion += 1
    }
  }

  /// Moves the map to where the phone is now: a fresh fix, asking for location permission first
  /// when it hasn't been decided, or the last known position when no fix comes. Runs on opening
  /// and from the locate button; the map tapped in the meantime cancels it.
  private func centerOnPhone() {
    locateTask?.cancel()
    locateTask = Task {
      let locationService = appState.locationService
      let location = (try? await locationService.requestCurrentLocation()) ?? locationService.currentLocation
      guard !Task.isCancelled else { return }
      locateTask = nil
      guard let location, location.coordinate.isValidFix else {
        // Nothing to move to: say why, rather than a tap that does nothing.
        locateFeedback = locationService.isLocationDenied ? .denied : .searching
        return
      }
      cameraRegion = MKCoordinateRegion(
        center: location.coordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
      )
      cameraRegionVersion += 1
    }
  }

  private var locateButton: some View {
    Button {
      centerOnPhone()
    } label: {
      if locateTask != nil {
        ProgressView()
      } else {
        Label(L10n.Map.Map.Controls.centerOnMyLocation, systemImage: "location")
      }
    }
    .mapControlButton(tint: .primary)
    .accessibilityLabel(L10n.Map.Map.Controls.centerOnMyLocation)
    .liquidGlass(in: .circle)
    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    // Stays on with Location denied: the tap then offers Settings instead of doing nothing.
    .disabled(locateTask != nil)
    .mapLocateFeedback($locateFeedback)
  }

  @ViewBuilder
  private var confirmButton: some View {
    let isBlocked: Bool = if case .unavailable = confirmation { true } else { isSaving }
    switch purpose {
    case .nodePosition:
      Button(L10n.Localizable.Common.save) { saveLocation() }
        .radioDisabled(for: appState.connectionState, or: isBlocked)
    case .share:
      Button(L10n.Settings.LocationPicker.share) { saveLocation() }
        .disabled(isBlocked)
    }
  }

  private func dropPinAtCenter() {
    if let region = cameraRegion {
      placePin(at: region.center)
    }
  }

  /// A pin only lands on a coordinate that can be confirmed, so the pin, the readout, and
  /// the saved value always agree.
  private func placePin(at coordinate: CLLocationCoordinate2D) {
    guard coordinate.isValidFix else { return }
    selectedCoordinate = coordinate
  }

  private func saveLocation() {
    let coord: CLLocationCoordinate2D
    switch confirmation {
    case .unavailable:
      return
    case let .coordinate(pin):
      coord = pin
    case .clearStoredPosition:
      // Nodes store "no position" as 0,0.
      coord = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    isSaving = true
    Task {
      do {
        try await onSave(coord)
        dismiss()
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }

  private func makeButtonContent() -> some View {
    ButtonContent(
      hasSelectedCoordinate: selectedCoordinate != nil,
      onClear: { selectedCoordinate = nil },
      onDropPin: { dropPinAtCenter() }
    )
  }
}

private struct ButtonContent: View {
  let hasSelectedCoordinate: Bool
  let onClear: () -> Void
  let onDropPin: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      if hasSelectedCoordinate {
        Button(L10n.Settings.LocationPicker.clearLocation, role: .destructive) {
          onClear()
        }
        .liquidGlassSecondaryButtonStyle()
        .controlSize(.regular)
      }

      Button(L10n.Settings.LocationPicker.dropPin) {
        onDropPin()
      }
      .liquidGlassProminentButtonStyle()
      .controlSize(.regular)
    }
  }
}

// MARK: - Local Device Convenience

extension LocationPickerView {
  /// Convenience initializer for local device location setting (Settings screen)
  /// Retry handling for SettingsServiceError is handled at the call site since it requires RetryAlertState
  static func forLocalDevice(appState: AppState) -> LocationPickerView {
    let device = appState.connectedDevice
    let initialCoord = device.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    let devicePreferenceStore = DevicePreferenceStore()

    return LocationPickerView(initialCoordinate: initialCoord) { coordinate in
      guard let settingsService = appState.services?.settingsService else {
        throw SettingsServiceError.notConnected
      }
      let previousDevice = appState.connectedDevice
      let verifiedInfo = try await settingsService.setManualLocationVerified(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      )

      guard let previousDevice else { return }

      let wasUsingDeviceGPSAutoUpdate =
        devicePreferenceStore.isAutoUpdateLocationEnabled(deviceID: previousDevice.id) &&
        devicePreferenceStore.gpsSource(deviceID: previousDevice.id) == .device

      if wasUsingDeviceGPSAutoUpdate {
        devicePreferenceStore.setAutoUpdateLocationEnabled(false, deviceID: previousDevice.id)
      }

      if previousDevice.sharesLocationPublicly,
         previousDevice.advertLocationPolicyMode == .share {
        let telemetryModes = TelemetryModes(
          base: verifiedInfo.telemetryModeBase,
          location: verifiedInfo.telemetryModeLocation,
          environment: verifiedInfo.telemetryModeEnvironment
        )
        _ = try await settingsService.setOtherParamsVerified(
          autoAddContacts: !verifiedInfo.manualAddContacts,
          telemetryModes: telemetryModes,
          advertLocationPolicy: .prefs,
          multiAcks: verifiedInfo.multiAcks
        )
      }
    }
  }
}

// MARK: - Liquid Glass Modifiers

private struct CoordinateGlassModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: 8))
    } else {
      content
    }
  }
}

private struct CoordinateText: View {
  let label: String
  let value: Double

  var body: some View {
    Text("\(label) \(value, format: .number.precision(.fractionLength(6)))")
  }
}
