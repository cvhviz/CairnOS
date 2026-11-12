import CoreLocation
import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "Map")

/// Popover callout for this radio's own pin: who and where it is, where that position comes from,
/// and the radio's own actions. The GPS readings come from the GPS tab's model when the map is
/// shown there; the callout never polls the radio itself.
struct RadioCalloutContent: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  let device: DeviceDTO
  /// The GPS tab's radio side, when the map is embedded there; nil on standalone maps.
  let model: GNSSDashboardModel?

  /// Holds the position preferences when there is no GPS tab model to read.
  @State private var fallbackModel = GNSSDashboardModel()
  @State private var isSendingAdvert = false
  @State private var advertSucceeded = false
  @State private var advertFailed = false
  @State private var copied = false

  private var gps: GNSSDashboardModel { model ?? fallbackModel }

  private var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        RadioAvatar(device: device, size: 36)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(device.nodeName)
            .font(.headline)
          Text(L10n.Map.Map.Callout.thisRadio)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)

      Divider()

      positionDetails

      Divider()

      // Side by side, one size each (the user, 2026-11-07: three stacked buttons of three widths):
      // a glyph over a short title, as a node page's action tiles.
      HStack(spacing: 6) {
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
          MapCalloutTileLabel(L10n.Localizable.CarPlay.Action.advert, systemImage: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.bordered)
        .radioDisabled(for: appState.connectionState, or: isSendingAdvert)
        .accessibilityLabel(L10n.Map.Map.Callout.sendAdvert)

        Button {
          dismiss()
          appState.navigation.gpsSegment = .position
        } label: {
          MapCalloutTileLabel(L10n.Localizable.Tabs.gps, systemImage: "location.circle")
        }
        .buttonStyle(.bordered)

        Button {
          dismiss()
          appState.navigation.navigateToSettingOverHub(.deviceInfo)
        } label: {
          MapCalloutTileLabel(L10n.Settings.DeviceInfo.title, systemImage: "info.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(L10n.Settings.DeviceInfo.title)
      }
      .frame(maxWidth: .infinity)
    }
    .padding(12)
    .frame(minWidth: 200)
    .sensoryFeedback(.success, trigger: advertSucceeded)
    .sensoryFeedback(.error, trigger: advertFailed)
    .sensoryFeedback(.success, trigger: copied)
    .onAppear {
      // Location & Sharing may have changed the source since the GPS tab last read it.
      gps.loadPreferences(for: device)
    }
  }

  // MARK: - Position

  private var positionDetails: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        VStack(alignment: .leading, spacing: 0) {
          Text(GPSFormat.latitudeText(coordinate.latitude))
          Text(GPSFormat.longitudeText(coordinate.longitude))
        }
        .font(.subheadline.monospacedDigit())
        .accessibilityElement(children: .combine)

        Spacer(minLength: 8)

        ShareLink(item: GPSFormat.coordinatePairText(coordinate)) {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.Map.Map.Callout.shareLocation)

        Button {
          UIPasteboard.general.string = GPSFormat.coordinatePairText(coordinate)
          copied.toggle()
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.Map.Map.Callout.copyCoordinates)
      }

      Text(positionSource.text)
        .font(.caption)
        .foregroundStyle(.secondary)

      if let readingLine {
        Text(readingLine)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let phoneLine {
        Text(phoneLine.text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(phoneLine.accessibilityText)
      }
    }
  }

  private var positionSource: RadioPositionSource {
    RadioPositionSource.derive(
      status: gps.radio.status,
      hasPosition: device.hasLocation,
      sharesLocationPublicly: device.sharesLocationPublicly,
      autoUpdate: gps.autoUpdate,
      gpsSource: gps.gpsSource
    )
  }

  /// "Altitude 181 m · Updated 3m ago", only while the radio's GPS has a real fix.
  private var readingLine: String? {
    guard let altitude = gps.radio.altitude else { return nil }
    let updated = gps.radio.readAt.map {
      L10n.Map.Map.Callout.Radio.updated(GPSFormat.fixAgeText(Date().timeIntervalSince($0)))
    }
    return NodeRouteFormat.joined([
      "\(L10n.Map.Map.Nav.altitude) \(LocationReportFormat.altitude(altitude))",
      updated,
    ])
  }

  /// "2.3 km away · 47° NE" from the phone's own fix; nil without one.
  private var phoneLine: (text: String, accessibilityText: String)? {
    guard let phone = appState.locationService.currentLocation,
          let distance = NodeRouteFormat.distanceAway(
            from: phone,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
          )
    else { return nil }
    let bearing = GPSFormat.bearing(from: phone.coordinate, to: coordinate)
    return (
      NodeRouteFormat.joined([distance, GPSFormat.bearingText(bearing)]),
      NodeRouteFormat.joined([distance, GPSFormat.bearingAccessibilityText(bearing)])
    )
  }

  // MARK: - Actions

  /// The same advert the Home card and the status menu send.
  private func sendAdvert(flood: Bool) {
    guard !isSendingAdvert else { return }
    isSendingAdvert = true
    Task {
      do {
        try await appState.sendSelfAdvert(flood: flood)
        advertSucceeded.toggle()
      } catch {
        logger.error("Failed to send advert from the map (flood=\(flood)): \(error.localizedDescription)")
        advertFailed.toggle()
      }
      isSendingAdvert = false
    }
  }
}

/// A map callout action as a tile: the glyph over a short title, filling its share of the row, so
/// a row of them comes out one size whatever their titles.
struct MapCalloutTileLabel: View {
  let title: String
  let systemImage: String

  init(_ title: String, systemImage: String) {
    self.title = title
    self.systemImage = systemImage
  }

  var body: some View {
    VStack(spacing: 3) {
      Image(systemName: systemImage)
        .font(.body)
      Text(title)
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, minHeight: 40)
  }
}
