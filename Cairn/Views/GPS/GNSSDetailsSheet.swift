import CairnServices
import CoreLocation
import SwiftUI

/// One device's GPS in full, from a tap on its card on the Map tab: only what that device really reports,
/// so a radio without Cairn's `gps_info` and a phone without a course simply have fewer rows.
struct GNSSDetailsRow: Identifiable, Equatable {
  let title: String
  let value: String
  var id: String { title }
}

struct GNSSDetailsSection: Identifiable, Equatable {
  let title: String?
  let rows: [GNSSDetailsRow]
  var id: String { title ?? "" }
}

enum GNSSDetails {
  /// The position's own rows: its forms, then its height.
  static func position(_ coordinate: CLLocationCoordinate2D?, altitude: String?) -> [GNSSDetailsRow] {
    var rows: [GNSSDetailsRow] = []
    if let coordinate {
      rows.append(GNSSDetailsRow(title: L10n.Map.Map.Detail.latitude, value: GPSFormat.latitudeText(coordinate.latitude)))
      rows.append(GNSSDetailsRow(title: L10n.Map.Map.Detail.longitude, value: GPSFormat.longitudeText(coordinate.longitude)))
      rows.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.dms, value: GPSFormat.dmsText(coordinate)))
      rows.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.gridSquare, value: GPSFormat.gridSquare(coordinate)))
    }
    if let altitude {
      rows.append(GNSSDetailsRow(title: L10n.Map.Map.Nav.altitude, value: altitude))
    }
    return rows
  }

  /// What a radio's receiver says of itself: its signal, then its movement.
  static func radioSections(_ details: RadioGPSDetails?) -> [GNSSDetailsSection] {
    guard let details else { return [] }
    var signal = [GNSSDetailsRow(
      title: L10n.Map.Map.Gps.fix,
      value: details.hasFix ? L10n.Map.Map.Gps.Details.fixYes : L10n.Map.Map.Gps.Details.fixNo
    )]
    if let satellites = details.satellites {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.satellites, value: "\(satellites)"))
    }
    if let inView = details.satellitesInView {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.inView, value: "\(inView)"))
    }
    if let hdop = details.hdop {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.hdop, value: String(format: "%.1f", hdop)))
    }
    if let seconds = details.secondsSinceSignal {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.lastSignal, value: GPSFormat.fixAgeText(seconds)))
    }
    var movement: [GNSSDetailsRow] = []
    // Only a fix's speed and course mean anything.
    if details.hasFix, let speed = details.metersPerSecond {
      movement.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.speed, value: GPSFormat.speedText(speed)))
    }
    if details.hasFix, let course = details.courseDegrees {
      movement.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.course, value: GPSFormat.bearingText(course)))
    }
    return sections(signal: signal, movement: movement)
  }

  /// What the phone's fix and compass say.
  static func phoneSections(_ fix: CLLocation?, heading: Double?, headingAccuracy: Double?, now: Date) -> [GNSSDetailsSection] {
    guard let fix else { return [] }
    var signal: [GNSSDetailsRow] = []
    if fix.horizontalAccuracy >= 0 {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.accuracy, value: "± \(GPSFormat.lengthText(fix.horizontalAccuracy))"))
    }
    if fix.verticalAccuracy > 0 {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.altitudeAccuracy, value: "± \(GPSFormat.lengthText(fix.verticalAccuracy))"))
    }
    signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.lastSignal, value: GPSFormat.fixAgeText(max(now.timeIntervalSince(fix.timestamp), 0))))
    if fix.sourceInformation?.isProducedByAccessory == true {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.source, value: L10n.Map.Map.Gps.Source.accessory))
    } else if fix.sourceInformation?.isSimulatedBySoftware == true {
      signal.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.Details.source, value: L10n.Map.Map.Gps.Details.simulated))
    }
    var movement: [GNSSDetailsRow] = []
    if fix.speed >= 0 {
      let accuracy = fix.speedAccuracy > 0 ? " ± \(GPSFormat.speedText(fix.speedAccuracy))" : ""
      movement.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.speed, value: GPSFormat.speedText(fix.speed) + accuracy))
    }
    if fix.course >= 0 {
      let accuracy = fix.courseAccuracy > 0 ? " ± \(Int(fix.courseAccuracy.rounded()))°" : ""
      movement.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.course, value: GPSFormat.bearingText(fix.course) + accuracy))
    }
    if let heading {
      let accuracy = (headingAccuracy ?? -1) > 0 ? " ± \(Int((headingAccuracy ?? 0).rounded()))°" : ""
      movement.append(GNSSDetailsRow(title: L10n.Map.Map.Gps.heading, value: GPSFormat.bearingText(heading) + accuracy))
    }
    return sections(signal: signal, movement: movement)
  }

  private static func sections(signal: [GNSSDetailsRow], movement: [GNSSDetailsRow]) -> [GNSSDetailsSection] {
    [
      GNSSDetailsSection(title: L10n.Map.Map.Gps.Details.signal, rows: signal),
      GNSSDetailsSection(title: L10n.Map.Map.Gps.Details.movement, rows: movement),
    ].filter { !$0.rows.isEmpty }
  }
}

/// The sheet's page: the sections on cards, Copy, Share and Open in Maps under the position, and Done.
private struct GNSSDetailsPage: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  /// The place's name for Maps: the radio's or the phone's.
  let name: String
  let coordinate: CLLocationCoordinate2D?
  let sections: [GNSSDetailsSection]

  @State private var copyCount = 0

  var body: some View {
    NavigationStack {
      CardForm {
        ForEach(sections) { section in
          CardFormSection(section.title ?? "") {
            VStack(spacing: 0) {
              ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text(row.title)
                    .foregroundStyle(.secondary)
                  Spacer(minLength: 8)
                  Text(row.value)
                    .font(.body.weight(.medium).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
              }
            }
            .cardSurface()
          }
        }
        if let coordinate {
          CardFormSection {
            MetricTileGrid {
              actionTile(L10n.RemoteNodes.RemoteNodes.Status.copyCoordinates, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = GPSFormat.coordinatePairText(coordinate)
                copyCount += 1
              }
              ShareLink(item: GPSFormat.coordinatePairText(coordinate)) {
                tileLabel(L10n.Contacts.Contacts.Qr.share, systemImage: "square.and.arrow.up")
              }
              .buttonStyle(.plain)
            }
            actionTile(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map.fill") {
              NodeLocation.openInMaps(name: name, coordinate: coordinate)
            }
          }
        }
      }
      .flashingNavigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
            .accessibilityIdentifier("gpsDetails.done")
        }
      }
    }
    .sensoryFeedback(.success, trigger: copyCount)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func actionTile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      tileLabel(title, systemImage: systemImage)
    }
    .buttonStyle(.plain)
  }

  private func tileLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 10) {
      IconTile(systemImage: systemImage, color: .blue)
        .accessibilityHidden(true)
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .frame(maxHeight: .infinity)
    .cardSurface(padding: 10)
    .cardInteractionShape()
  }
}

/// The radio's GPS: its position, and on Cairn firmware what its receiver says.
struct GNSSRadioDetailsSheet: View {
  @Environment(\.appState) private var appState
  let model: GNSSDashboardModel
  var phone: CLLocation?

  var body: some View {
    let device = appState.connectedDevice
    let coordinate = device.flatMap { $0.hasLocation ? CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) : nil }
    var position = GNSSDetails.position(coordinate, altitude: model.radio.altitude.map { GPSFormat.lengthText($0) })
    if let coordinate, let phone {
      let radio = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
      position.append(GNSSDetailsRow(
        title: L10n.Map.Map.Nav.distance,
        value: "\(GPSFormat.lengthText(phone.distance(from: radio))) \(GPSFormat.bearingText(GPSFormat.bearing(from: phone.coordinate, to: coordinate)))"
      ))
    }
    return GNSSDetailsPage(
      title: L10n.Map.Map.Gps.Dash.radio,
      name: device?.nodeName ?? L10n.Map.Map.Gps.Dash.radio,
      coordinate: coordinate,
      sections: [GNSSDetailsSection(title: L10n.Map.Map.Gps.Details.position, rows: position)]
        .filter { !$0.rows.isEmpty } + GNSSDetails.radioSections(model.radio.receiver?.details)
    )
  }
}

/// The phone's GPS: everything Core Location gives. Live while it's open.
struct GNSSPhoneDetailsSheet: View {
  let live: GPSLiveLocation
  /// The last fix the app took elsewhere, until the first live one lands.
  let fallback: CLLocation?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let fix = live.location ?? fallback
      let altitude = fix.flatMap { $0.verticalAccuracy > 0 ? GPSFormat.lengthText($0.altitude) : nil }
      GNSSDetailsPage(
        title: L10n.Map.Map.Gps.Dash.phone,
        name: PhoneName.display,
        coordinate: fix?.coordinate,
        sections: [GNSSDetailsSection(title: L10n.Map.Map.Gps.Details.position, rows: GNSSDetails.position(fix?.coordinate, altitude: altitude))]
          .filter { !$0.rows.isEmpty }
          + GNSSDetails.phoneSections(
            fix,
            heading: live.isHeadingAvailable ? live.heading : nil,
            headingAccuracy: live.headingAccuracy,
            now: context.date
          )
      )
    }
  }
}
