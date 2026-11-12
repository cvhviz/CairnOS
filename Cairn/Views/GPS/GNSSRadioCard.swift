import CoreLocation
import CairnServices
import SwiftUI

/// The radio's hero card on the GPS dashboard: its state badge, the position it holds, and where
/// that position comes from. Without a radio, Connect sits right here, since nothing else on the
/// card can show until one is connected.
struct GNSSRadioHero: View {
  let model: GNSSDashboardModel
  /// The phone's fix, for the radio's distance from it.
  var phone: CLLocation?
  var now: Date = .now
  /// False inside the shared GPS card (`GNSSDevicesCard`), which draws the surface for both.
  var drawsSurface = true
  /// The GPS page's full card (the user, 2026-11-09: each device's data on its own card): the badge
  /// beside the name, the pair on one line, then everything the radio says about its position (altitude,
  /// distance and bearing from the phone, grid square, and from a Cairn receiver its satellites, HDOP,
  /// speed and course), and its sensors (`sensors`) under their own label.
  var row = false
  /// The radio's sensor readings, for the full card's Sensors section.
  var sensors: [SensorReadingItem] = []

  @Environment(\.appState) private var appState
  @State private var showingDeviceSelection = false
  @State private var showingDetails = false

  private var device: DeviceDTO? { appState.connectedDevice }

  /// Microdegrees from the self info: finer than telemetry's 0.0001°, and what the adverts carry.
  private var position: CLLocationCoordinate2D? {
    guard let device, device.hasLocation else { return nil }
    return CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: row ? 10 : 12) {
      if row, device != nil {
        GNSSCompactHeader(
          kind: L10n.Map.Map.Gps.Dash.radio,
          systemImage: "antenna.radiowaves.left.and.right",
          color: .orange,
          name: device?.nodeName ?? L10n.Map.Map.Gps.Dash.radio,
          status: GNSSStatus.radio(isConnected: true, status: model.radio.status),
          coordinate: position,
          facts: [sourceText, GNSSReadings.updatedText(model.radio.readAt, now: now)].compactMap(\.self),
          onOpenDetails: { showingDetails = true }
        )
        // the position readings, then the sensors, as one strip of equal cells with hairlines
        // between, as a node page's header has them (the user, 2026-11-09)
        NodeHeaderStrip(facts: (rowReadings + sensors).map { NodeHeaderFact($0) })
      } else {
      GNSSCardHeader(
        title: L10n.Map.Map.Gps.Dash.radio,
        systemImage: "antenna.radiowaves.left.and.right",
        color: .orange,
        detail: device?.nodeName,
        updated: device == nil ? nil : GNSSReadings.updatedText(model.radio.readAt, now: now),
        status: GNSSStatus.radio(isConnected: device != nil, status: model.radio.status),
        trailingStatus: row
      )
      if device != nil {
        GNSSCoordinateReadout(
          coordinate: position,
          caption: RadioPositionSource.derive(
            status: model.radio.status,
            hasPosition: position != nil,
            sharesLocationPublicly: device?.sharesLocationPublicly ?? false,
            autoUpdate: model.autoUpdate,
            gpsSource: model.gpsSource
          ).text,
          lines: row ? [] : cardLines,
          reservedLines: row ? 0 : 2,
          onOpenDetails: { showingDetails = true },
          oneLine: row
        )
      } else {
        GNSSNote(L10n.Map.Map.Gps.notConnected)
        Button(L10n.Settings.Device.connect, systemImage: "antenna.radiowaves.left.and.right") {
          showingDeviceSelection = true
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityIdentifier("radio.connect")
      }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .modifier(OptionalCardSurface(isOn: drawsSurface))
    .accessibilityElement(children: .contain)
    .sheet(isPresented: $showingDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showingDetails) {
      GNSSRadioDetailsSheet(model: model, phone: phone)
    }
  }

  /// Where the radio's position comes from ("Saved position", "GPS"), for the compact header.
  private var sourceText: String? {
    RadioPositionSource.derive(
      status: model.radio.status,
      hasPosition: position != nil,
      sharesLocationPublicly: device?.sharesLocationPublicly ?? false,
      autoUpdate: model.autoUpdate,
      gpsSource: model.gpsSource
    ).text
  }

  /// Its altitude, and how far it is from the phone when both positions are known.
  private var cardLines: [GNSSReading] {
    GNSSReadings.radioCardLines(
      radio: model.radio,
      radioPosition: position.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) },
      phone: phone
    )
  }

  /// The row's position readings, each always in its place ("—" until it has something to say), so the
  /// card keeps its shape as the receiver comes and goes: its altitude, how far it is from the phone and
  /// which way, its grid square; then what a Cairn receiver reports (satellites, HDOP, its own speed and
  /// course) while it does. The sensors follow under their own label.
  private var rowReadings: [SensorReadingItem] {
    let lines = Dictionary(cardLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let details = model.radio.receiver?.details
    let distance = lines["both.distance"]
    var items = [
      SensorReadingItem(
        id: "gps.radio.altitude", label: L10n.Map.Map.Nav.altitude,
        value: lines["radio.altitude"]?.value ?? "—",
        systemImage: "mountain.2", tint: lines["radio.altitude"] == nil ? .secondary : .brown
      ),
      SensorReadingItem(
        id: "gps.radio.fromPhone", label: L10n.Map.Map.Gps.Reading.fromPhone,
        value: distance.map { [$0.value, $0.caption].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ") } ?? "—",
        systemImage: "point.topleft.down.to.point.bottomright.curvepath", tint: distance == nil ? .secondary : .orange
      ),
      SensorReadingItem(
        id: "gps.radio.grid", label: L10n.Map.Map.Gps.Details.gridSquare,
        value: position.map(GPSFormat.gridSquare) ?? "—",
        systemImage: "square.grid.3x3", tint: position == nil ? .secondary : .teal
      ),
    ]
    if let satellites = details?.satellites {
      items.append(SensorReadingItem(
        id: "gps.radio.satellites", label: L10n.Map.Map.Gps.Details.satellites,
        value: details?.satellitesInView.map { "\(satellites)/\($0)" } ?? "\(satellites)",
        systemImage: "dot.radiowaves.up.forward", tint: .green
      ))
    }
    if let hdop = details?.hdop {
      items.append(SensorReadingItem(
        id: "gps.radio.hdop", label: L10n.Map.Map.Gps.Details.hdop,
        value: hdop.formatted(.number.precision(.fractionLength(1))),
        systemImage: "scope", tint: hdop <= 2 ? .green : hdop <= 5 ? .orange : .red
      ))
    }
    if let speed = details?.metersPerSecond {
      items.append(SensorReadingItem(
        id: "gps.radio.speed", label: L10n.Map.Map.Gps.speed,
        value: GPSFormat.speedText(speed >= GNSSReadings.movingSpeed ? speed : 0),
        systemImage: "speedometer", tint: .green
      ))
    }
    if let course = details?.courseDegrees, (details?.metersPerSecond ?? 0) >= GNSSReadings.movingSpeed {
      items.append(SensorReadingItem(
        id: "gps.radio.course", label: L10n.Map.Map.Gps.course,
        value: GPSFormat.bearingText(course),
        systemImage: "location.north.fill", tint: .green
      ))
    }
    return items
  }
}
