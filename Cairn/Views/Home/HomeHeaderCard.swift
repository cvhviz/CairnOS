import CoreLocation
import CairnServices
import MeshCore
import SwiftUI

/// The top of Home, after Cairn's header: the radio's name beside the date, its model and firmware,
/// a strip with today's sunrise and sunset beside how long the radio has been up, then the radio's own
/// sensors (temperature, and on Cairn firmware its heading, motion, tilt and steps) as an even grid,
/// each one's name above its value (`SensorReadingGrid`). Items with nothing to show (no position, no
/// sensor, no stats) are left out rather than dashed.
/// The card is the way into Device Info, as the radio header atop Settings was.
struct HomeHeaderCard: View {
  @Environment(\.appState) private var appState

  let readings: DeviceReadingsModel
  let now: Date
  /// Opens Device Info, or the radio picker while no radio is connected.
  let onOpen: () -> Void
  /// Opens the connection's settings, from the link badge (it was the Connection card's; the user,
  /// 2026-11-09).
  var onOpenConnection: (() -> Void)?

  /// Cairn's sun gold, for the sunrise and sunset glyphs.
  private static let sunGold = Color(red: 0.95, green: 0.76, blue: 0.31)
  /// Sensor readings outside this range are noise, as on the radio's own strip.
  private static let plausibleCelsius = -40.0...150.0

  var body: some View {
    // A tap on the card opens Device Info; the link badge is a button of its own, which wins over it.
    card
      .contentShape(.rect)
      .onTapGesture(perform: onOpen)
      .accessibilityAction(.default, onOpen)
      .accessibilityIdentifier("home.headerCard")
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(appState.connectedDevice?.nodeName ?? L10n.Localizable.Home.noRadio)
          .font(.title3.weight(.bold))
          // Green when ready, as the bar's device-name title on the other tabs: Dashboard's bar
          // shows the app's name, so this is where the radio's name and readiness are read.
          .foregroundStyle(nameTint)
          .lineLimit(1)
          // The only place on the tab that names the radio: shrink a long name at large text
          // sizes rather than cut it off beside the date.
          .minimumScaleFactor(0.75)
        Spacer(minLength: 8)
        Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .fixedSize()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }

      // the model and firmware, with how the radio is linked at the line's end (the Connection
      // card's, folded in here; the user, 2026-11-09)
      HStack(alignment: .center, spacing: 8) {
        if let modelLine {
          Text(modelLine)
            .font(.subheadline)
            .foregroundStyle(HomeCardDetail.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        Spacer(minLength: 4)
        if appState.connectedDevice != nil {
          linkBadge
        }
      }

      if hasStrip {
        strip
      }

      // Under the sun line, every reading the radio's sensors gave, as a strip of equal cells with
      // hairlines between, as every node's header has them (the user, 2026-11-09)
      if !sensorItems.isEmpty {
        NodeHeaderStrip(facts: sensorItems.map { NodeHeaderFact($0) })
      }
    }
    .cardSurface(padding: 12)
    .cardInteractionShape()
    .accessibilityElement(children: .contain)
    .accessibilityHint(appState.connectedDevice == nil
      ? L10n.Settings.Device.connect
      : L10n.Localizable.Home.Hint.deviceInfo)
  }

  // MARK: - Link

  private var isWiFi: Bool { appState.connectionManager.currentTransportType == .wifi }

  private var linkTint: Color {
    switch appState.connectionState {
    case .disconnected: .secondary
    case .connecting, .connected, .syncing: .orange
    case .ready: AppColors.Radio.readyText
    }
  }

  /// Only 0 is the radio's default PIN: 123456 is one someone chose, whatever it looks like.
  private var hasDefaultPin: Bool {
    !isWiFi && appState.connectedDevice?.blePin == 0
  }

  /// "● Bluetooth · Ready" on a capsule of the link's colour, with a lock warning beside it while the
  /// Bluetooth PIN is the default. A button: it opens the connection's settings.
  private var linkBadge: some View {
    Button {
      (onOpenConnection ?? onOpen)()
    } label: {
      HStack(spacing: 4) {
        if hasDefaultPin {
          Image(systemName: "lock.trianglebadge.exclamationmark.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: .capsule)
        }
        HStack(spacing: 4) {
          Image(systemName: isWiFi ? "wifi" : "antenna.radiowaves.left.and.right")
          Text(HomeStatusLines.linkTitle(appState.connectionState))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(linkTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(linkTint.opacity(0.12), in: .capsule)
      }
      .lineLimit(1)
      .fixedSize()
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Localizable.Home.Card.network)
    .accessibilityValue(NodeRouteFormat.joined([
      HomeStatusLines.transportName(isWiFi: isWiFi),
      HomeStatusLines.linkTitle(appState.connectionState),
      hasDefaultPin ? L10n.Localizable.Home.Network.defaultPin : nil,
    ]))
    .accessibilityHint(L10n.Localizable.Home.Hint.network)
    .accessibilityIdentifier("home.linkBadge")
  }

  private var nameTint: Color {
    guard appState.connectedDevice != nil else { return .secondary }
    return appState.isRadioReady ? AppColors.Radio.readyText : .primary
  }

  // MARK: - Model

  /// "Heltec V3 · v1.9.1": the radio's model and firmware, which the dashboard atop Settings used to
  /// show. The model falls back to a generic name when the radio doesn't report one.
  private var modelLine: String? {
    appState.connectedDevice.map(HomeStatusLines.modelLine)
  }

  // MARK: - Uptime

  /// "up 3h 12m": the uptime the radio reported, carried forward by the time since the reading,
  /// so it keeps counting without asking the radio again.
  private var uptimeText: String? {
    guard appState.isRadioReady, let core = readings.core, let readAt = readings.lastUpdated else { return nil }
    let seconds = TimeInterval(core.uptimeSeconds) + max(0, now.timeIntervalSince(readAt))
    return L10n.Localizable.Home.uptime(HomeFormat.uptime(seconds: seconds))
  }

  // MARK: - Strip

  private var hasStrip: Bool {
    sunResult != nil || uptimeText != nil
  }

  /// Sunrise and sunset on the left, the uptime at the right edge under the temperature: one row.
  private var strip: some View {
    HStack(spacing: 14) {
      sunItems
      Spacer(minLength: 8)
      uptimeItems
    }
    .font(.footnote.weight(.medium).monospacedDigit())
    .foregroundStyle(HomeCardDetail.ink)
  }

  /// "up 3h 12m".
  @ViewBuilder
  private var uptimeItems: some View {
    if let uptime = uptimeText {
      Label {
        Text(uptime)
      } icon: {
        Image(systemName: "clock")
      }
      .fixedSize()
    }
  }

  @ViewBuilder
  private var sunItems: some View {
    if let sunResult {
      sunItem(sunResult)
    }
  }

  @ViewBuilder
  private func sunItem(_ result: SolarCalculator.Result) -> some View {
    switch result {
    case let .times(sunrise, sunset):
      HStack(spacing: 10) {
        Label {
          Text(sunrise, format: .dateTime.hour().minute())
        } icon: {
          Image(systemName: "sunrise.fill").foregroundStyle(Self.sunGold)
        }
        Label {
          Text(sunset, format: .dateTime.hour().minute())
        } icon: {
          Image(systemName: "sunset.fill").foregroundStyle(.orange)
        }
      }
      .fixedSize()
    case .polarDay:
      Label(L10n.Localizable.Home.Sun.polarDay, systemImage: "sun.max.fill")
        .fixedSize()
    case .polarNight:
      Label(L10n.Localizable.Home.Sun.polarNight, systemImage: "moon.fill")
        .fixedSize()
    }
  }

  /// Today's sun at your position: the phone's fix, else the radio's advertised position.
  private var sunResult: SolarCalculator.Result? {
    guard let location = appState.bestAvailableLocation else { return nil }
    return SolarCalculator.sunTimes(
      on: now,
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      timeZone: .current
    )
  }

  /// The radio's own readings (not its battery voltage, which the Battery card shows, nor a GPS fix,
  /// which the GPS card shows), as Device Info lists them: a temperature in the user's units, and on
  /// Cairn firmware its IMU and compass as heading, motion, tilt and steps. A temperature outside what
  /// a sensor can read is noise and left out. Several channels name theirs.
  private var sensorItems: [SensorReadingItem] {
    guard appState.isRadioReady else { return [] }
    let noisy: Set<String> = Set(readings.sensors.enumerated().compactMap { _, point in
      guard point.type == .temperature, case let .float(celsius) = point.value,
            !Self.plausibleCelsius.contains(celsius) else { return nil }
      return point.formattedValue
    })
    let groups = readings.sensorChipGroups(cairnFirmware: appState.connectedDevice?.isCairnFirmware == true)
    return SensorReadingItem.items(from: groups, idPrefix: "home.").filter {
      !($0.systemImage == "thermometer.medium" && noisy.contains($0.value))
    }
  }
}

/// Shown at the top of Home while no radio is connected: says so and offers the radio picker,
/// the same way out as `RadioNotConnectedView` but sized as a card above the dashboard.
struct HomeConnectCard: View {
  let onConnect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        IconTile(systemImage: "antenna.radiowaves.left.and.right.slash", color: .gray)
          .accessibilityHidden(true)
        Text(L10n.Localizable.Home.Connect.title)
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
      }
      Text(L10n.Localizable.Home.Connect.message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(L10n.Settings.Device.connect, systemImage: "antenna.radiowaves.left.and.right", action: onConnect)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("home.connect")
    }
    .cardSurface(padding: 14)
  }
}
