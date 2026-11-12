import CoreLocation
import CairnServices
import SwiftUI

/// The tab's Position page: a GNSS dashboard for both devices.
///
/// Information first, control on demand. The date, the sun (sunrise and sunset), the phone's
/// speed, course and altitude (`GPSMotionTile`) on one card; then each device on a card of its own with
/// all of its data (the user, 2026-11-09): the radio's position readings and sensors, the phone's
/// accuracy, grid square and the mesh around it; then the compass full width (the heading, the course,
/// which way the radio is) and the map preview full width (with the mesh nodes nearby, and
/// the way into the full map). The settings are the toolbar's slider button. Every
/// reading keeps its place as readings come and go, so the page never shifts under a finger. The
/// phone's updates run only while this page is on screen; the radio is re-read every 30 seconds
/// while it is.
///
/// On iPad at regular width the page fills the screen above the tab bar (`Arrangement`): upright,
/// Radio, Phone and the compass share the top row and the map preview takes the height left above
/// Maps & GPS; sideways, the readings in a column on the left and the map the full height on the right.
struct GPSPositionView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// Owned by the GPS tab, which shares them with the Location Settings sheet it presents.
  let live: GPSLiveLocation
  let model: GNSSDashboardModel

  @State private var showingCompass = false
  /// Screenshot runs open the Trips page on a sample walk: `-uiTestTrips YES` (DEBUG only).
  @State private var showsTrips = false
  /// The nodes for the map preview.
  @State private var nodes = MapViewModel()
  /// What the page shows above the tab bar, for the iPad's layouts that fill it.
  @State private var visibleSize: CGSize = .zero

  /// How often the radio is re-read while the page is visible: a few small commands, gentle on
  /// the link and on the radio's battery.
  private static let radioRefreshInterval: Duration = .seconds(30)

  private var locationService: LocationService { appState.locationService }

  /// The live fix, or the last one the app took elsewhere (the map, distance sorting) until the
  /// first live one lands, so the page isn't blank for the second the GPS takes to answer.
  private var phoneLocation: CLLocation? {
    guard locationService.isAuthorized else { return nil }
    return live.location ?? locationService.currentLocation
  }

  /// The position the radio holds and adverts.
  private var radioLocation: CLLocation? {
    guard let device = appState.connectedDevice, device.hasLocation else { return nil }
    return CLLocation(latitude: device.latitude, longitude: device.longitude)
  }

  /// Side by side on a wide screen; stacked on a phone and at accessibility sizes.
  private var isWide: Bool {
    horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
  }

  /// How the page fills the screen.
  private enum Arrangement {
    /// The phone's, and compact width: one scrolling column.
    case stacked
    /// Upright at regular width: Radio, Phone and the compass in one row, the map down to Maps & GPS.
    case tall
    /// Sideways at regular width: everything but the map on the left, the map full height on the right.
    case sideBySide
  }

  /// The phone's column, unless this is an iPad at regular width (not at accessibility text sizes,
  /// which keep the column); sideways once the window is clearly wider than tall.
  private var arrangement: Arrangement {
    guard TabSplitLayout.usesSplit(
      horizontalSizeClass: horizontalSizeClass,
      verticalSizeClass: verticalSizeClass,
      idiom: UIDevice.current.userInterfaceIdiom
    ), !dynamicTypeSize.isAccessibilitySize else { return .stacked }
    return visibleSize.width > visibleSize.height * 1.2 ? .sideBySide : .tall
  }

  var body: some View {
    page
    .onAppear {
      live.start()
      #if DEBUG
        // Screenshot runs open the full compass straight away: `-uiTestCompass YES`.
        if UserDefaults.standard.bool(forKey: "uiTestCompass") { showingCompass = true }
        if UserDefaults.standard.bool(forKey: "uiTestTrips") {
          Task {
            await TripsDemo.seed(store: appState.connectionManager.persistenceStore)
            showsTrips = true
          }
        }
      #endif
    }
    .onDisappear { live.stop() }
    .modifier(GNSSMapNodesLoader(nodes: nodes))
    .navigationDestination(isPresented: $showsTrips) { TripsView() }
    .fullScreenCover(isPresented: $showingCompass) {
      CompassFullScreenView(live: live)
    }
    .task(id: radioReadID) {
      // Read now, then gently while the page stays visible, connected and in the foreground.
      // The task ends with the page, so nothing polls behind the map or another tab.
      while !Task.isCancelled {
        await model.refresh(appState: appState, isActive: scenePhase == .active)
        try? await Task.sleep(for: Self.radioRefreshInterval)
      }
    }
    .refreshable {
      locationService.requestLocation()
      await model.refresh(appState: appState, isActive: scenePhase == .active)
    }
  }

  @ViewBuilder
  private var page: some View {
    let arrangement = arrangement
    if arrangement == .stacked {
      CardForm {
        // Ages ("3m ago") and the phone's fix freshness move on their own, so the page re-renders
        // every 15 s as well as on each new fix or radio read.
        TimelineView(.periodic(from: .now, by: 15)) { context in
          // a card's gap between them, as Home's cards have (was 20; the user, 2026-11-09: too tall)
          VStack(alignment: .leading, spacing: CardStyle.spacing) {
            // The sun first, then each device's fix and the phone's movement, then the compass and
            // the map (which opens the full map).
            sunCard(now: context.date)
            radioCard(now: context.date)
            phoneCard(now: context.date)
            mapAndCompass
          }
        }
      }
      #if DEBUG
      // Screenshot runs show the page's end (the compass and the map): `-uiTestScrollToEnd YES`.
      .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "uiTestScrollToEnd") ? .bottom : nil)
      #endif
      // CardForm's top inset is a form's; a tab's first section sits at `pageInset`, as Home's
      // and Spectrum's do, so switching tabs doesn't jump (the user, 2026-11-08).
      .contentMargins(.top, CardStyle.pageInset - CardStyle.formVerticalInset, for: .scrollContent)
    } else {
      // CardForm's scroll view and insets, its content stretched to the bottom of the screen.
      ScrollView {
        TimelineView(.periodic(from: .now, by: 15)) { context in
          Group {
            if arrangement == .sideBySide {
              sideBySideLayout(now: context.date)
            } else {
              tallLayout(now: context.date)
            }
          }
          .padding(.horizontal, CardStyle.pageInset)
          .padding(.top, CardStyle.pageInset)
          .padding(.bottom, CardStyle.formVerticalInset)
          .fillingScrollHeight(visibleSize.height)
        }
      }
      .measuringVisibleScrollSize($visibleSize)
      .cardCanvas(theme)
    }
  }

  // MARK: - iPad

  /// Upright: the sun, then Radio and Phone side by side, then the compass beside the map preview, which
  /// takes the rest of the height.
  private func tallLayout(now: Date) -> some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      sunCard(now: now)
        .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: CardStyle.spacing) {
        radioCard(now: now)
        phoneCard(now: now)
      }
      .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: CardStyle.spacing) {
        compassButton
          .frame(maxWidth: .infinity)
        wideMap
          .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
      }
      .frame(minHeight: 280, maxHeight: .infinity)
    }
  }

  /// Sideways: the sun, Radio, Phone and the compass in a column on the left; the map preview the full
  /// height on the right.
  private func sideBySideLayout(now: Date) -> some View {
    HStack(alignment: .top, spacing: CardStyle.spacing) {
      VStack(alignment: .leading, spacing: CardStyle.spacing) {
        sunCard(now: now)
          .fixedSize(horizontal: false, vertical: true)
        radioCard(now: now)
        phoneCard(now: now)
        compassButton
      }
      .frame(width: sideColumnWidth)
      wideMap
        .frame(maxHeight: .infinity)
    }
  }

  /// The left column sideways: a little under half the width, so the map gets the larger share.
  private var sideColumnWidth: CGFloat {
    max(0, (visibleSize.width - CardStyle.pageInset * 2 - CardStyle.spacing) * 0.45)
  }

  /// The map preview filling its place, or with no position to map, the plain Map card that opens
  /// the map, at the top of that place.
  @ViewBuilder
  private var wideMap: some View {
    if radioLocation != nil || phoneLocation != nil {
      mapPreview
    } else {
      Button(action: openMap) {
        NavigationTile(L10n.Localizable.Tabs.map, systemImage: "map.fill", color: .teal)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("gps.openMap")
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  // MARK: - Devices

  /// The radio's card: everything it says about where it is, then its sensors (`GNSSRadioHero`'s full
  /// card).
  private func radioCard(now: Date) -> some View {
    GNSSRadioHero(model: model, phone: phoneLocation, now: now, drawsSurface: false, row: true, sensors: sensorItems)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .cardSurface(padding: 12)
  }

  /// The phone's card: its fix, its accuracy with the grid square and the mesh nodes nearby beside it,
  /// then the nearest node (`GPSAroundCard`). Its speed, course and altitude are on the top
  /// card, with the sun.
  private func phoneCard(now: Date) -> some View {
    let around = GPSAroundCard(anchor: phoneLocation, points: nodes.mapPoints, onOpenMap: openMap)
    return VStack(alignment: .leading, spacing: 8) {
      GNSSPhoneHero(
        live: live, location: phoneLocation, now: now, drawsSurface: false, row: true,
        stripReadings: around.items
      )
      if phoneLocation != nil {
        Divider()
        around
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .cardSurface(padding: 12)
  }

  /// The top card: today's date, where the sun is, its arc of the day and sunrise and sunset (for
  /// where the devices are: the phone's fix, else the radio's position), and under them the
  /// phone's speed, course and altitude (the user, 2026-11-08). With no position yet, just the
  /// movement. The radio's sensors are on its card, below.
  private func sunCard(now: Date) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let origin = phoneLocation ?? radioLocation {
        let coordinate = origin.coordinate
        CompassSunCard(
          sun: SunPosition.at(now, latitude: coordinate.latitude, longitude: coordinate.longitude),
          times: SolarCalculator.sunTimes(
            on: now, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZone: .current
          ),
          now: now,
          showsDate: true,
          drawsSurface: false
        )
      }
      // its own hairline above it when it follows the sun
      GPSMotionTile(live: live, location: phoneLocation, now: now, drawsSurface: false,
                    topDivider: phoneLocation != nil || radioLocation != nil)
    }
    .cardSurface(padding: 12)
  }

  /// The radio's own readings from the page's radio read (`GNSSDashboardModel.sensors`), while it's ready.
  private var sensorItems: [SensorReadingItem] {
    guard appState.isRadioReady else { return [] }
    let groups = DeviceReadingsModel.sensorChipGroups(
      model.sensors, cairnFirmware: appState.connectedDevice?.isCairnFirmware == true
    )
    return SensorReadingItem.items(from: groups, idPrefix: "gps.")
  }

  // MARK: - Map and compass

  /// The compass and the map preview side by side as two equal squares, compass first (the user,
  /// 2026-11-09: back side by side), stacked at accessibility sizes. With no position to map, the
  /// compass and a plain Map card that opens the map.
  @ViewBuilder
  private var mapAndCompass: some View {
    let hasMap = radioLocation != nil || phoneLocation != nil
    if dynamicTypeSize.isAccessibilitySize {
      compassButton(wide: false).frame(height: 320)
      if hasMap {
        mapPreview.frame(height: 240)
      }
    } else if hasMap {
      HStack(spacing: CardStyle.spacing) {
        compassButton(wide: false)
          .frame(maxHeight: .infinity)
        mapPreview
          .frame(maxHeight: .infinity)
      }
      // one height for both, set by the compass with its strip under the rose (the user, 2026-11-09:
      // more on the compass card), so the map beside it matches
      .frame(height: 200)
    } else {
      compassButton(wide: false).frame(height: 240)
    }
    // With no position there's no preview to tap, and the map is still the way to the mesh.
    if !hasMap {
      Button(action: openMap) {
        NavigationTile(L10n.Localizable.Tabs.map, systemImage: "map.fill", color: .teal)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("gps.openMap")
    }
  }

  /// The map preview, with the mesh nodes near the radio and the phone; it opens the map.
  private var mapPreview: GNSSMapPreviewCard {
    GNSSMapPreviewCard(
      radio: radioLocation?.coordinate,
      phone: phoneLocation?.coordinate,
      nodes: nodes,
      onOpen: openMap
    )
  }

  /// The live compass, which opens the full compass: the full-width card (the heading, the course,
  /// which way and how far the radio is, which north it reads) where it has a row to itself (iPad
  /// sideways), the square rose beside the map on a phone (the user, 2026-11-09).
  private var compassButton: some View {
    compassButton(wide: arrangement == .sideBySide)
  }

  private func compassButton(wide: Bool) -> some View {
    Button { showingCompass = true } label: {
      GPSLiveCompassCard(live: live, phone: phoneLocation, radio: radioLocation, wide: wide)
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Map.Map.Gps.Compass.openHint)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("gps.compass")
  }

  private func openMap() {
    appState.navigation.gpsSegment = .map
  }

  /// Restarts the radio reads for a new radio, once the session is past its startup sync, and
  /// stops them while the app is in the background.
  private var radioReadID: String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    return "\(deviceID)-\(appState.canRunSettingsStartupReads)-\(scenePhase == .active)"
  }
}

/// What's around the phone, the Phone card's last section (the user, 2026-11-09), in the readings' look
/// (`SensorReadingGrid`): the grid square and the mapped nodes within 10 km on one line, then the
/// nearest mesh node on a line of its own (a tap opens the map). A reading with nothing to say yet keeps
/// its place with a dash.
private struct GPSAroundCard: View {
  let anchor: CLLocation?
  let points: [MapPoint]
  let onOpenMap: () -> Void

  /// How far counts as nearby.
  private static let nearbyRadius: CLLocationDistance = 10_000

  /// The mesh's nodes among the map's pins: contacts, repeaters, rooms, heard nodes.
  private static let nodeStyles: Set<MapPoint.PinStyle> = [
    .contactChat, .contactRepeater, .contactRoom, .repeater,
    .repeaterRingBlue, .repeaterRingGreen, .repeaterRingWhite,
    .discoveredChat, .discoveredRepeater, .discoveredRoom,
  ]

  private struct Nearby {
    var nearest: (point: MapPoint, distance: CLLocationDistance)?
    var count = 0
  }

  private var nearby: Nearby? {
    guard let anchor else { return nil }
    var result = Nearby()
    for point in points where Self.nodeStyles.contains(point.pinStyle) {
      let distance = anchor.distance(from: CLLocation(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude))
      if distance <= Self.nearbyRadius { result.count += 1 }
      if result.nearest.map({ distance < $0.distance }) ?? true { result.nearest = (point, distance) }
    }
    return result
  }

  /// The nearest node's line; the grid square and the count (`items`) sit beside the card's accuracy ring.
  var body: some View {
    nearestLine(nearby)
  }

  /// Grid square and the mapped nodes within 10 km.
  var items: [SensorReadingItem] {
    items(nearby)
  }

  /// The nearest mesh node on a line of its own (the user, 2026-11-09: beside the others its name and
  /// distance split them over two lines): the label and the name on the left, how far and which way on
  /// the right, and a chevron, since a tap opens the map.
  @ViewBuilder
  private func nearestLine(_ nearby: Nearby?) -> some View {
    // one line (the user, 2026-11-09: the page's cards were too tall)
    let label = HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "mappin.and.ellipse")
        .foregroundStyle(.red)
      Text(L10n.Map.Map.Gps.Reading.nearestNode)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(nearestName(nearby))
        .font(.footnote.weight(.medium))
        .foregroundStyle(HomeCardDetail.ink)
        .lineLimit(1)
    }
    if let anchor, let nearest = nearby?.nearest {
      let bearing = GPSFormat.bearing(from: anchor.coordinate, to: nearest.point.coordinate)
      let away = "\(GPSFormat.lengthText(nearest.distance)) \(CompassPoint(degrees: bearing).abbreviation)"
      Button(action: onOpenMap) {
        HStack(spacing: 8) {
          label
          Spacer(minLength: 8)
          Text(away)
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(HomeCardDetail.ink)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(.tertiaryLabel))
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(L10n.Map.Map.Gps.Reading.nearestNode)
      .accessibilityValue("\(nearestName(nearby)), \(away)")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("gps.nearestNode")
    } else {
      label
        .accessibilityElement(children: .combine)
    }
  }

  private func nearestName(_ nearby: Nearby?) -> String {
    guard anchor != nil else { return "—" }
    guard let nearest = nearby?.nearest else { return L10n.Map.Map.Gps.Reading.noNodesMapped }
    return nearest.point.label ?? "—"
  }

  /// Grid square and the mapped nodes within 10 km (the accuracy is on the card's ring: not again here).
  private func items(_ nearby: Nearby?) -> [SensorReadingItem] {
    [
      SensorReadingItem(id: "gps.grid", label: L10n.Map.Map.Gps.Details.gridSquare,
                        value: anchor.map { GPSFormat.gridSquare($0.coordinate) } ?? "—",
                        systemImage: "square.grid.3x3", tint: .teal),
      SensorReadingItem(id: "gps.nearby", label: L10n.Map.Map.Gps.Reading.nodesNearby,
                        value: nearby.map { $0.count.formatted() } ?? "—",
                        systemImage: "point.3.connected.trianglepath.dotted", tint: .blue),
    ]
  }
}

/// The compass card reading the live heading itself, so a heading change (up to one a degree)
/// re-renders only the compass rather than the whole page. Beside the rose: the course while moving,
/// which way and how far the radio is from the phone (an orange dot on the ring too), and which north the
/// heading is against. The sun is on the top card.
private struct GPSLiveCompassCard: View {
  let live: GPSLiveLocation
  let phone: CLLocation?
  let radio: CLLocation?
  var wide = true

  private var radioBearing: Double? {
    guard let phone, let radio, GPSFormat.positionsDiffer(phone, radio) else { return nil }
    return GPSFormat.bearing(from: phone.coordinate, to: radio.coordinate)
  }

  private var details: [SensorReadingItem] {
    let course = GNSSReadings.course(of: live.location)
    var items = [
      SensorReadingItem(
        id: "gps.compass.course", label: L10n.Map.Map.Gps.course,
        value: course.map(GPSFormat.bearingText) ?? "—",
        systemImage: "location.north.fill", tint: course == nil ? .secondary : .green
      ),
    ]
    if let radioBearing, let phone, let radio {
      items.append(SensorReadingItem(
        id: "gps.compass.radio", label: L10n.Map.Map.Gps.Dash.radio,
        value: "\(GPSFormat.bearingText(radioBearing)) · \(GPSFormat.lengthText(phone.distance(from: radio)))",
        systemImage: "antenna.radiowaves.left.and.right", tint: .orange
      ))
    }
    if live.heading != nil {
      // Which north the heading is against, and how far off the compass may be.
      let north = live.isTrueHeading ? L10n.Map.Map.Gps.Compass.trueNorth : L10n.Map.Map.Gps.Compass.magneticNorth
      let accuracy = live.headingAccuracy.map { " ±\(Int($0.rounded()))°" } ?? ""
      items.append(SensorReadingItem(
        id: "gps.compass.north", label: L10n.Map.Map.Gps.Compass.north,
        value: north + accuracy,
        systemImage: "location.north.line", tint: (live.headingAccuracy ?? 0) > 20 ? .orange : .teal
      ))
    }
    return items
  }

  /// The square card's strip: the course, and which way and how far the radio is.
  private var strip: [NodeHeaderFact] {
    let course = GNSSReadings.course(of: live.location)
    var facts = [
      NodeHeaderFact(
        id: "gps.compass.course", label: L10n.Map.Map.Gps.course,
        value: course.map { GPSFormat.bearingText($0) } ?? "—",
        systemImage: "location.north.fill", tint: course == nil ? .secondary : .green, isDim: course == nil
      ),
    ]
    if let radioBearing, let phone, let radio {
      facts.append(NodeHeaderFact(
        id: "gps.compass.radio", label: L10n.Map.Map.Gps.Dash.radio,
        value: GPSFormat.bearingText(radioBearing),
        systemImage: "antenna.radiowaves.left.and.right", tint: .orange,
        caption: GPSFormat.lengthText(phone.distance(from: radio))
      ))
    } else {
      facts.append(NodeHeaderFact(
        id: "gps.compass.radio", label: L10n.Map.Map.Gps.Dash.radio, value: "—",
        systemImage: "antenna.radiowaves.left.and.right", tint: .secondary, isDim: true
      ))
    }
    return facts
  }

  /// "True N" or "Mag N" while the compass reads.
  private var northTag: String? {
    guard live.heading != nil else { return nil }
    return live.isTrueHeading ? L10n.Map.Map.Gps.Compass.trueNorth : L10n.Map.Map.Gps.Compass.magneticNorth
  }

  var body: some View {
    GPSCompassCard(
      heading: live.isHeadingAvailable ? live.heading : nil,
      course: GNSSReadings.course(of: live.location),
      wide: wide,
      radioBearing: radioBearing,
      details: details,
      strip: wide ? [] : strip,
      northTag: wide ? nil : northTag
    )
  }
}

#Preview {
  NavigationStack {
    GPSPositionView(live: GPSLiveLocation(), model: GNSSDashboardModel())
  }
  .environment(\.appState, AppState())
}
