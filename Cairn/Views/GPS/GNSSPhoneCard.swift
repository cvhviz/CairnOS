import CoreLocation
import SwiftUI

/// The phone's hero card on the GPS dashboard, half the width beside the radio's: its name, state badge,
/// the live coordinates and a small accuracy ring. Before location is allowed, Allow sits right
/// here (nothing else on the card can show without it); once refused, a short note says why the
/// card is empty, and Open Settings is in Location Settings.
struct GNSSPhoneHero: View {
  let live: GPSLiveLocation
  /// The live fix, or the last one the app took elsewhere until the first live one lands.
  let location: CLLocation?
  let now: Date
  /// False inside the shared GPS card (`GNSSDevicesCard`), which draws the surface for both.
  var drawsSurface = true
  /// A full-width row (the GPS page): the badge beside the name, the pair on one line.
  var row = false
  /// The full card's strip after the accuracy (the grid square, the nodes nearby), as a node page's
  /// header lays out its readings (the user, 2026-11-09).
  var stripReadings: [SensorReadingItem] = []

  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var showingDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: row ? 10 : 12) {
      if row, live.isAuthorized {
        GNSSCompactHeader(
          kind: L10n.Map.Map.Gps.Dash.phone,
          systemImage: "iphone",
          color: .blue,
          name: PhoneName.display,
          status: GNSSStatus.phone(authorization: live.authorizationStatus, location: location, now: now),
          coordinate: location?.coordinate,
          facts: [
            location?.sourceInformation?.isProducedByAccessory == true ? L10n.Map.Map.Gps.Source.accessory : nil,
            GNSSReadings.updatedText(location?.timestamp, now: now),
          ].compactMap(\.self),
          onOpenDetails: { showingDetails = true }
        )
        NodeHeaderStrip(facts: [accuracyFact(location.flatMap { $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil })]
          + stripReadings.map { NodeHeaderFact($0) })
      } else {
      GNSSCardHeader(
        title: L10n.Map.Map.Gps.Dash.phone,
        systemImage: "iphone",
        color: .blue,
        detail: PhoneName.display,
        updated: live.isAuthorized ? GNSSReadings.updatedText(location?.timestamp, now: now) : nil,
        status: GNSSStatus.phone(authorization: live.authorizationStatus, location: location, now: now),
        trailingStatus: row
      )
      switch live.authorizationStatus {
      case .notDetermined:
        Button(L10n.Map.Map.Gps.allow, systemImage: "location.fill") {
          appState.locationService.requestPermissionIfNeeded()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(theme.accentColor)
      case .denied, .restricted:
        GNSSNote(L10n.Map.Map.Gps.Denied.message)
      default:
        readout
      }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .modifier(OptionalCardSurface(isOn: drawsSurface))
    .accessibilityElement(children: .contain)
    .sheet(isPresented: $showingDetails) {
      GNSSPhoneDetailsSheet(live: live, fallback: location)
    }
  }

  private var readout: some View {
    let accuracy = location.flatMap { $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil }
    return VStack(alignment: .leading, spacing: 8) {
      GNSSCoordinateReadout(
        coordinate: location?.coordinate,
        caption: location?.sourceInformation?.isProducedByAccessory == true
          ? L10n.Map.Map.Gps.Source.accessory
          : nil,
        // The altitude is on the motion tile, with the speed and course.
        lines: [],
        onOpenDetails: { showingDetails = true },
        oneLine: row
      )
      if row {
        NodeHeaderStrip(facts: [accuracyFact(accuracy)] + stripReadings.map { NodeHeaderFact($0) })
      } else {
        GNSSAccuracyRing(accuracy: accuracy, isApproximate: live.isApproximate)
      }
    }
  }
}

extension GNSSPhoneHero {
  /// "±16 ft" with its grade under it ("Excellent"), in the grade's colour.
  fileprivate func accuracyFact(_ accuracy: CLLocationAccuracy?) -> NodeHeaderFact {
    let grade = accuracy.map(GNSSAccuracyGrade.init(meters:))
    return NodeHeaderFact(
      id: "gps.phone.accuracy",
      label: L10n.Map.Map.Gps.accuracy,
      value: accuracy.map(GPSFormat.accuracyText) ?? "—",
      systemImage: "scope",
      tint: grade?.tint ?? .secondary,
      isDim: accuracy == nil,
      // the grade in the glyph's colour; words only for approximate location, which the colour can't say
      caption: live.isApproximate ? L10n.Map.Map.Gps.Accuracy.approximate : nil
    )
  }
}

extension GPSLiveLocation {
  var isAuthorized: Bool {
    authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
  }

  /// Location is allowed, but only approximately.
  var isApproximate: Bool { isAuthorized && accuracyAuthorization == .reducedAccuracy }
}
