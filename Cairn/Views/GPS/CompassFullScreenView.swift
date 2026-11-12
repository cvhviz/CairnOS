import CoreLocation
import MapKit
import CairnServices
import SwiftUI

/// A node with a position, as the full compass places it: which way it lies from you and how far.
struct CompassNode: Identifiable, Equatable {
  let contact: ContactDTO
  let bearing: Double
  let distance: CLLocationDistance
  var id: UUID { contact.id }

  /// The node's colour on the dial, by kind, from Cairn's avatar palette.
  var tint: Color {
    AvatarCategory(contact.type).color
  }

  /// "Repeater", "Chat", "Room".
  var kind: String {
    switch contact.type {
    case .chat: L10n.Contacts.Contacts.NodeKind.chat
    case .repeater: L10n.Contacts.Contacts.NodeKind.repeater
    case .room: L10n.Contacts.Contacts.NodeKind.room
    }
  }

  /// When it was last heard from, by advert or otherwise.
  var lastHeard: Date? {
    let seconds = max(contact.lastHeardTimestamp ?? 0, contact.lastAdvertTimestamp)
    return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
  }

  /// How it is reached: "Direct", "Flood", "2 hops".
  var route: String {
    NodeRouteFormat.routeLabel(isFloodRouted: contact.isFloodRouted, pathHopCount: contact.pathHopCount, displayedHopCount: nil)
  }

  /// The node's glyph on the dial, as its avatar draws it: the tower for a repeater, the
  /// walkie-talkie for a companion (both Cairn's own symbols), a door for a room.
  var symbol: (name: String, isCustom: Bool) {
    switch contact.type {
    case .chat: (AppTab.home.symbolName, true)
    case .repeater: ("cairn.repeater.fill", true)
    case .room: ("door.left.hand.closed", false)
    }
  }

  /// The nodes with a position, nearest first, as seen from `origin`.
  static func nearest(_ contacts: [ContactDTO], from origin: CLLocation, limit: Int) -> [CompassNode] {
    contacts
      .filter(\.hasLocation)
      .map { contact in
        let coordinate = CLLocationCoordinate2D(latitude: contact.latitude, longitude: contact.longitude)
        return CompassNode(
          contact: contact,
          bearing: GPSFormat.bearing(from: origin.coordinate, to: coordinate),
          distance: origin.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        )
      }
      .sorted { $0.distance < $1.distance }
      .prefix(limit)
      .map(\.self)
  }
}

/// The full-screen compass, opened from the GPS page's compass card: an instrument rather than a
/// card. The dial turns under a fixed pointer, over a faint map turning with it, carrying your
/// course, the sun and the mesh's nodes round its track; lock a bearing (or tap a node) and an
/// arc shows which way to turn, the map draws the GPS map's guide line, and the node's card gives
/// the distance and a way to check line of sight. With no node picked, the dashboard under the
/// dial gives everything else the phone knows about where it is and which way it faces; the
/// nearby nodes sit in a sheet behind the bottom button.
///
/// It reads the GPS page's `GPSLiveLocation` under its own client claim, rather than starting a
/// second GPS and magnetometer manager, so the page leaving underneath it can't stop its updates.
struct CompassFullScreenView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  /// Settings > Maps > Appearance, which the map behind the dial follows like every map.
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  let live: GPSLiveLocation
  /// The dial's rotation, unwrapped so it turns the short way round.
  @State private var rotation: Double = 0
  /// A locked bearing to steer by; a node target follows the node as you move.
  @State private var lockedBearing: Double?
  /// The node whose card is open, picked on the dial or in the list.
  @State private var selectedNodeID: UUID?
  /// The node the compass steers to, which its card's switch turns on and off.
  @State private var targetNodeID: UUID?
  @State private var contacts: [ContactDTO] = []
  @AppStorage(AppStorageKey.compassShowsNodes.rawValue) private var showsNodesOnDial = true
  @AppStorage(AppStorageKey.compassNorthUp.rawValue) private var northUp = false
  @AppStorage(AppStorageKey.compassUsesMagneticNorth.rawValue) private var usesMagneticNorth = false
  @AppStorage(AppStorageKey.compassShowsSun.rawValue) private var showsSun = true
  @AppStorage(AppStorageKey.compassShowsCourse.rawValue) private var showsCourse = true
  @AppStorage(AppStorageKey.compassShowsCompanions.rawValue) private var showsCompanions = true
  @AppStorage(AppStorageKey.compassShowsRepeaters.rawValue) private var showsRepeaters = true
  @AppStorage(AppStorageKey.compassShowsRooms.rawValue) private var showsRooms = true
  @AppStorage(AppStorageKey.compassNodeLimit.rawValue) private var nodeLimit = AppStorageKey.defaultCompassNodeLimit
  @AppStorage(AppStorageKey.compassHaptics.rawValue) private var haptics = true
  @AppStorage(AppStorageKey.compassKeepsScreenOn.rawValue) private var keepsScreenOn = false
  @State private var showingSettings = false
  /// The nearby nodes, in a sheet behind the bottom button.
  @State private var showingDetails = false
  /// The phone faces the target, with the GPS map's hysteresis so both agree and the haptic
  /// doesn't repeat at the edge.
  @State private var isOnTarget = false
  /// Line of Sight from here to the open node, pushed onto the compass's stack.
  @State private var lineOfSight: LineOfSightRequest?

  /// Screenshot runs open the nodes sheet: `-uiTestCompassCards YES`.
  private static var startsAtCards: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: "uiTestCompassCards")
    #else
      false
    #endif
  }

  /// Above this error the compass is worth recalibrating.
  private static let calibrationThreshold: Double = 25

  // MARK: - Derived

  /// The heading as the compass reads it: against magnetic north if set, else true north.
  private var heading: Double? {
    guard live.isHeadingAvailable else { return nil }
    return usesMagneticNorth ? live.magneticHeading : live.heading
  }

  /// The heading against true north, for the declination.
  private var trueHeading: Double? { live.isHeadingAvailable && live.isTrueHeading ? live.heading : nil }

  /// What to take off a true bearing to read it against magnetic north (the declination), when
  /// the compass reads magnetic and the phone knows it; zero otherwise.
  private var bearingCorrection: Double {
    guard usesMagneticNorth, let trueHeading, let magnetic = live.magneticHeading else { return 0 }
    return GPSFormat.normalizedDegrees(trueHeading - magnetic + 180) - 180
  }

  /// A true bearing (to a node, the sun, the course) as the dial reads it.
  private func shown(_ trueBearing: Double) -> Double {
    GPSFormat.normalizedDegrees(trueBearing - bearingCorrection)
  }

  /// The phone's fix, else the radio's position, so the nodes and sun still place without GPS.
  private var origin: CLLocation? {
    if let location = live.location ?? appState.locationService.currentLocation { return location }
    guard let device = appState.connectedDevice, device.hasLocation else { return nil }
    return CLLocation(latitude: device.latitude, longitude: device.longitude)
  }

  private var nodes: [CompassNode] {
    guard let origin else { return [] }
    let kinds = contacts.filter { contact in
      switch contact.type {
      case .chat: showsCompanions
      case .repeater: showsRepeaters
      case .room: showsRooms
      }
    }
    return CompassNode.nearest(kinds, from: origin, limit: nodeLimit).map { node in
      CompassNode(contact: node.contact, bearing: shown(node.bearing), distance: node.distance)
    }
  }

  private var targetNode: CompassNode? {
    nodes.first { $0.id == targetNodeID }
  }

  private var selectedNode: CompassNode? {
    nodes.first { $0.id == selectedNodeID }
  }

  /// Opens a node's card and steers to it; the same node again closes it.
  private func select(_ id: UUID) {
    withAnimation(reduceMotion ? nil : .snappy) {
      if selectedNodeID == id {
        selectedNodeID = nil
        if targetNodeID == id { targetNodeID = nil }
      } else {
        selectedNodeID = id
        targetNodeID = id
        lockedBearing = nil
      }
    }
  }

  private var steeringBinding: Binding<Bool> {
    Binding(
      get: { selectedNodeID != nil && targetNodeID == selectedNodeID },
      set: { isOn in
        targetNodeID = isOn ? selectedNodeID : nil
        if isOn { lockedBearing = nil }
      }
    )
  }

  private var target: Double? {
    targetNode?.bearing ?? lockedBearing
  }

  private var course: Double? { GNSSReadings.course(of: live.location).map(shown) }

  private func sun(at date: Date) -> SunPosition.Result? {
    guard let origin else { return nil }
    return SunPosition.at(date, latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude)
  }

  /// Which cardinal quarter the heading is in, for a haptic tick as you swing past N, E, S or W.
  private var cardinalQuarter: Int? {
    heading.map { Int(GPSFormat.normalizedDegrees($0 + 45) / 90) % 4 }
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        GeometryReader { geometry in
          let isWide = geometry.size.width > geometry.size.height * 1.1
          if isWide {
            HStack(alignment: .center, spacing: 24) {
              instrument(now: context.date)
                .frame(maxWidth: min(geometry.size.height * 0.9, geometry.size.width * 0.5))
              ScrollView {
                targetPanel(now: context.date)
                  .padding(.vertical, 16)
              }
              .scrollIndicators(.hidden)
              .frame(maxWidth: 440)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              VStack(spacing: 20) {
                instrument(now: context.date)
                targetPanel(now: context.date)
              }
              .padding(.horizontal, 16)
              .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
          }
        }
      }
      .navigationDestination(item: $lineOfSight) { request in
        LineOfSightView(from: request.origin, to: request.target, contact: request.contact)
          .flashingNavigationTitle(L10n.Tools.Tools.lineOfSight)
          .navigationBarTitleDisplayMode(.inline)
      }
      // The app's own canvas, the user's background included, as every other page has.
      .cardCanvas(theme)
      .markedNavigationTitle(L10n.Map.Map.Gps.Compass.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        // A button each side of the title: the one way out, and the settings. The heading lock sits
        // with the page's other control, under the dial.
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Label(L10n.Localizable.Common.back, systemImage: "chevron.left")
              .labelStyle(.iconOnly)
          }
          .accessibilityIdentifier("compass.back")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingSettings = true
          } label: {
            Label(L10n.Map.Map.Gps.Compass.settingsTitle, systemImage: "slider.horizontal.3")
              .labelStyle(.iconOnly)
          }
        }
        ToolbarItem(placement: .bottomBar) {
          lockButton
        }
        ToolbarItem(placement: .bottomBar) {
          Button {
            showingDetails = true
          } label: {
            Label(L10n.Map.Map.Gps.Compass.nearbyNodes, systemImage: "list.bullet.rectangle")
              .labelStyle(.titleAndIcon)
          }
        }
      }
    }
    // A full-screen cover sits outside the tab shell, so it takes the shell's bar styling itself.
    .themedChrome(theme)
    .onAppear {
      // Its own claim: the page under it may disappear after this appears, and must not stop it.
      live.start(for: .fullScreenCompass)
      UIApplication.shared.isIdleTimerDisabled = keepsScreenOn
      #if DEBUG
        // Screenshot runs open the settings sheet: `-uiTestCompassSettings YES`.
        if UserDefaults.standard.bool(forKey: "uiTestCompassSettings") { showingSettings = true }
      #endif
      if Self.startsAtCards { showingDetails = true }
    }
    .onChange(of: keepsScreenOn) { _, keepOn in UIApplication.shared.isIdleTimerDisabled = keepOn }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      live.stop(for: .fullScreenCompass)
    }
    // A rotation to or from landscape turns the screen against the compass; keep headings in step.
    .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
      live.syncHeadingOrientation()
    }
    .sheet(isPresented: $showingSettings) { CompassSettingsSheet() }
    .sheet(isPresented: $showingDetails) { detailsSheet }
    .onChange(of: heading, initial: true) { _, newHeading in
      guard let newHeading else { return }
      let delta = GPSFormat.normalizedDegrees(newHeading - rotation + 180) - 180
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
        rotation += delta
      }
    }
    .sensoryFeedback(.selection, trigger: haptics ? cardinalQuarter : nil)
    .onChange(of: aimAngle, initial: true) { _, angle in
      guard let angle else {
        isOnTarget = false
        return
      }
      isOnTarget = MapNavigationMath.isOnTarget(relativeAngle: angle, wasOnTarget: isOnTarget)
    }
    .sensoryFeedback(.success, trigger: isOnTarget) { _, now in haptics && now }
    .task(id: appState.contactsVersion) {
      await loadContacts()
    }
  }

  /// How far the target is off the way you face, -180..<180; nil without both.
  private var aimAngle: Double? {
    guard let heading, let target else { return nil }
    return MapNavigationMath.relativeAngle(bearing: target, heading: heading)
  }

  private func loadContacts() async {
    guard let store = appState.offlineDataStore, let radioID = appState.currentRadioID else { return }
    contacts = (try? await store.fetchContacts(radioID: radioID)) ?? []
    #if DEBUG
      // Screenshot runs open the nearest node's card: `-uiTestCompassNode YES`.
      if UserDefaults.standard.bool(forKey: "uiTestCompassNode"), selectedNodeID == nil, let first = nodes.first {
        select(first.id)
      }
    #endif
  }

  // MARK: - Instrument

  private func instrument(now: Date) -> some View {
    VStack(spacing: 14) {
      if let accuracy = live.headingAccuracy, accuracy > Self.calibrationThreshold {
        Label(L10n.Map.Map.Gps.Compass.calibrate, systemImage: "figure.walk.motion")
          .font(.footnote.weight(.medium))
          .foregroundStyle(.orange)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.orange.opacity(0.15), in: .capsule)
      }

      ZStack {
        CompassDial(
          rotation: northUp ? 0 : rotation,
          pointer: northUp ? rotation : 0,
          hasHeading: heading != nil,
          markers: markers(now: now),
          target: target,
          onSelectNode: { id in UUID(uuidString: id).map(select) },
          isFaceTranslucent: mapBackdrop != nil,
          isOnTarget: target == nil ? nil : isOnTarget
        )
        .background { dialBackdrop }
        headingReadout
          .allowsHitTesting(false)
      }
      // VoiceOver reads the heading here; the nodes are reached through the nodes sheet.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(L10n.Map.Map.Gps.heading)
      .accessibilityValue(heading.map(GPSFormat.bearingAccessibilityText) ?? L10n.Map.Map.Gps.noHeading)

    }
    .padding(.top, 8)
  }

  /// Under (or beside) the dial: the open node's card; with no node picked, the dashboard (which
  /// way to turn for a locked bearing, then the radio, heading, position and sun cards).
  @ViewBuilder
  private func targetPanel(now: Date) -> some View {
    if let selectedNode {
      CompassNodeCard(
        node: selectedNode,
        heading: heading,
        isSteering: steeringBinding,
        isOnTarget: targetNodeID == selectedNode.id ? isOnTarget : nil,
        onCheckLineOfSight: lineOfSightAction(to: selectedNode),
        onDetails: {
          appState.navigation.navigateToContactDetail(selectedNode.contact)
          dismiss()
        },
        onClose: { select(selectedNode.id) }
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    } else {
      VStack(spacing: 12) {
        steeringLine
        dashboard(now: now)
      }
      .transition(.opacity)
    }
  }

  /// Line of Sight from where you are to `node`, once there's a position to start from.
  private func lineOfSightAction(to node: CompassNode) -> (() -> Void)? {
    guard let origin, node.distance >= 1 else { return nil }
    return {
      lineOfSight = LineOfSightRequest(
        origin: origin.coordinate,
        target: node.contact.coordinate,
        contact: node.contact,
        discovered: nil
      )
    }
  }

  // MARK: - Map behind the dial

  private var mapIsDark: Bool {
    resolvedMapIsDark(
      preference: AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system,
      colorScheme: colorScheme
    )
  }

  /// The map behind the dial, once there's a position to centre it on.
  private var mapBackdrop: CompassMapBackdrop? {
    guard let origin else { return nil }
    let centre = origin.coordinate
    // The target's bearing is read on the dial's north; the map wants it against true north.
    let aimEnd = target.map { bearing in
      CompassMapBackdrop.destination(
        from: centre,
        bearing: bearing + bearingCorrection,
        distance: CompassMapBackdrop.sightLineLength
      )
    }
    return CompassMapBackdrop(
      centre: centre,
      aimEnd: aimEnd,
      isOnTarget: target != nil && isOnTarget,
      isDarkMode: mapIsDark,
      isOffline: !appState.offlineMapService.isNetworkAvailable
    )
  }

  /// The dial's footing: a soft shadow it casts on the page, and the map turning with the rose
  /// (north-up with a north-up dial) so north on both agrees.
  private var dialBackdrop: some View {
    ZStack {
      Circle()
        .fill(Color(.secondarySystemGroupedBackground))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
      if let mapBackdrop {
        mapBackdrop
          .equatable()
          .rotationEffect(.degrees(northUp ? 0 : -rotation))
          .clipShape(.circle)
      }
    }
  }

  // MARK: - Nodes sheet

  /// The nearby nodes, full height. Picking one closes it, to steer by the dial.
  private var detailsSheet: some View {
    NavigationStack {
      ScrollView {
        nodesSection
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
      }
      .scrollIndicators(.hidden)
      .cardCanvas(theme)
      .flashingNavigationTitle(L10n.Map.Map.Gps.Compass.nearbyNodes)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { showingDetails = false }
        }
      }
    }
    .themedChrome(theme)
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  private func markers(now: Date) -> [CompassDialMarker] {
    var markers: [CompassDialMarker] = (showsNodesOnDial ? nodes : []).map { node in
      CompassDialMarker(
        id: node.id.uuidString,
        bearing: node.bearing,
        kind: .node(symbol: node.symbol.name, isCustomSymbol: node.symbol.isCustom, tint: node.tint, isTarget: node.id == selectedNodeID || node.id == targetNodeID)
      )
    }
    if showsSun, let sun = sun(at: now) {
      markers.append(CompassDialMarker(id: "sun", bearing: shown(sun.azimuth), kind: .sun(isUp: sun.isUp)))
    }
    if showsCourse, let course {
      markers.append(CompassDialMarker(id: "course", bearing: course, kind: .course))
    }
    return markers
  }

  /// The heading in the middle of the dial: the number large, the point under it.
  private var headingReadout: some View {
    VStack(spacing: 0) {
      if let heading {
        Text("\(GPSFormat.wholeDegrees(heading))°")
          .font(.system(size: 54, weight: .bold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
        Text(CompassPoint(degrees: heading).name.localizedCapitalized)
          .font(.headline)
          .foregroundStyle(.secondary)
      } else {
        Text(L10n.Map.Map.Gps.noHeading)
          .font(.headline)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
    // A soft halo in the page colour, so the reading stays clear over the map and pins under it.
    .shadow(color: Color(.systemBackground).opacity(0.9), radius: 3)
    .shadow(color: Color(.systemBackground).opacity(0.6), radius: 8)
    .frame(maxWidth: 170)
  }

  /// Which way to turn for the locked bearing, under the dial.
  @ViewBuilder
  private var steeringLine: some View {
    if let target {
      let name = targetNode?.contact.displayName
      VStack(spacing: 2) {
        if let heading {
          let delta = GPSFormat.normalizedDegrees(target - heading + 180) - 180
          let amount = "\(GPSFormat.wholeDegrees(abs(delta)))°"
          Text(isOnTarget
            ? L10n.Map.Map.Gps.Compass.onTarget
            : delta > 0 ? L10n.Map.Map.Gps.Compass.turnRight(amount) : L10n.Map.Map.Gps.Compass.turnLeft(amount))
            .font(.title3.weight(.semibold))
            .foregroundStyle(isOnTarget ? .green : .red)
            .contentTransition(.numericText())
        }
        Text(name.map { "\($0) · \(GPSFormat.bearingText(target))" } ?? GPSFormat.bearingText(target))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var lockButton: some View {
    Button {
      if target != nil {
        lockedBearing = nil
        targetNodeID = nil
        selectedNodeID = nil
      } else if let heading {
        lockedBearing = GPSFormat.normalizedDegrees(heading)
      }
    } label: {
      Label(
        target == nil ? L10n.Map.Map.Gps.Compass.lock : L10n.Map.Map.Gps.Compass.clear,
        systemImage: target == nil ? "scope" : "xmark.circle"
      )
    }
    .disabled(target == nil && heading == nil)
  }

  // MARK: - Cards

  /// The readings as cards sized by what they hold: the radio as a thin header, heading and
  /// position as short cards side by side (sharing the line equally), and the sun as one slim line.
  private func dashboard(now: Date) -> some View {
    VStack(spacing: 12) {
      radioCard
      HStack(alignment: .top, spacing: 12) {
        CompassOrientationCard(
          heading: heading,
          trueHeading: trueHeading,
          magneticHeading: live.magneticHeading,
          isTrueHeading: live.isTrueHeading,
          headingAccuracy: live.headingAccuracy,
          course: course,
          speed: live.location.map(\.speed).flatMap { $0 >= 0 ? $0 : nil }
        )
        .frame(maxWidth: .infinity)
        CompassPositionCard(location: live.location)
          .frame(maxWidth: .infinity)
      }
      .fixedSize(horizontal: false, vertical: true)
      sunCard(now: now)
    }
  }

  /// Your radio's header card, while one is connected.
  @ViewBuilder
  private var radioCard: some View {
    if let device = appState.connectedDevice {
      CompassRadioCard(
        device: device,
        phone: live.location,
        batteryPercent: appState.radioBatteryPercent,
        txPower: appState.radioTxPower
      )
    }
  }

  @ViewBuilder
  private func sunCard(now: Date) -> some View {
    if let origin, let sun = sun(at: now) {
      CompassSunCard(
        sun: SunPosition.Result(azimuth: shown(sun.azimuth), elevation: sun.elevation),
        times: SolarCalculator.sunTimes(
          on: now,
          latitude: origin.coordinate.latitude,
          longitude: origin.coordinate.longitude,
          timeZone: .current
        ),
        now: now
      )
    }
  }

  // MARK: - Nodes

  private var nodesSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if nodes.isEmpty {
        Text(L10n.Map.Map.Gps.Compass.noNodes)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface(padding: 14)
      } else {
        VStack(spacing: 0) {
          ForEach(nodes) { node in
            nodeRow(node)
            if node.id != nodes.last?.id {
              Divider().padding(.leading, 60)
            }
          }
        }
        .cardSurface(padding: 0)
      }
    }
  }

  private func nodeRow(_ node: CompassNode) -> some View {
    let isTarget = node.id == targetNodeID
    let isSelected = node.id == selectedNodeID
    // Where the node is relative to the way you face: straight up means dead ahead.
    let relative = node.bearing - (heading ?? 0)
    return Button {
      select(node.id)
      // Opened: back to the dial to steer by it.
      if selectedNodeID == node.id { showingDetails = false }
    } label: {
      HStack(spacing: 12) {
        ContactTypeAvatar(contact: node.contact, size: 36)
        VStack(alignment: .leading, spacing: 2) {
          Text(node.contact.displayName)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          Text("\(GPSFormat.lengthText(node.distance)) · \(GPSFormat.bearingText(node.bearing))")
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
          // What it is, when it was last heard and how it is reached.
          Text([
            node.kind,
            node.lastHeard.map { "\(L10n.Contacts.Contacts.Detail.lastHeard) \(HomeFormat.age(Date().timeIntervalSince($0)))" },
            node.route,
          ].compactMap(\.self).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
          .foregroundStyle(isTarget ? .green : node.tint)
          .rotationEffect(.degrees(relative))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: relative)
          .opacity(heading == nil ? 0.4 : 1)
        if isTarget {
          Image(systemName: "scope")
            .foregroundStyle(.green)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(isSelected ? node.tint.opacity(0.15) : .clear)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview {
  CompassFullScreenView(live: GPSLiveLocation())
    .environment(\.appState, AppState())
}

// MARK: - Map backdrop

/// A still map under the dial, centred on you at a fixed scale, with, given a target, the GPS
/// map's guide line toward it (solid green on target). No pins: the dial already marks every
/// node on its ring, and a second set on the map would double them. The caller turns it with the
/// rose, so north on the map and on the dial agree. Equatable on its inputs, so the compass's
/// many heading updates turn it without redrawing the map.
struct CompassMapBackdrop: View, @MainActor Equatable {
  let centre: CLLocationCoordinate2D
  /// The guide's far end, well past the map's edge, so it runs from you right across the dial
  /// the way to go, like a sight line, at whatever scale the map draws.
  let aimEnd: CLLocationCoordinate2D?
  let isOnTarget: Bool
  let isDarkMode: Bool
  let isOffline: Bool

  /// How far the map reaches from the centre, in metres: the neighbourhood around you, the same
  /// whatever is picked so the map never jumps.
  static let reach: CLLocationDistance = 1_500
  /// Long enough to cross the dial at any zoom the map draws.
  static let sightLineLength: CLLocationDistance = 50_000

  private var region: MKCoordinateRegion {
    MKCoordinateRegion(center: centre, latitudinalMeters: Self.reach * 2, longitudinalMeters: Self.reach * 2)
  }

  /// Re-frames only when the centre moves about ten metres.
  private var regionVersion: Int {
    var hasher = Hasher()
    hasher.combine((centre.latitude * 10_000).rounded())
    hasher.combine((centre.longitude * 10_000).rounded())
    return hasher.finalize()
  }

  var body: some View {
    CairnMapView(
      points: [],
      lines: aimEnd.map { [.aim(id: "compass-aim", from: centre, to: $0, isOnTarget: isOnTarget)] } ?? [],
      mapStyle: .standard,
      isDarkMode: isDarkMode,
      isOffline: isOffline,
      showLabels: false,
      showsUserLocation: true,
      isInteractive: false,
      showsScale: false,
      hidesAttribution: true,
      // Full colour: the dial's glass face already softens it, and a wash on top greys it out.
      isMuted: false,
      // The dial carries the lettering; place and road names would fight it.
      hidesBasemapLabels: true,
      cameraRegion: .constant(region),
      cameraRegionVersion: regionVersion,
      onPointTap: nil,
      onMapTap: nil,
      onCameraRegionChange: nil,
      // The compass already runs the GPS at best accuracy; the dot rides on it.
      userLocationAccuracy: kCLLocationAccuracyHundredMeters
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.centre.latitude == rhs.centre.latitude && lhs.centre.longitude == rhs.centre.longitude
      && lhs.aimEnd?.latitude == rhs.aimEnd?.latitude && lhs.aimEnd?.longitude == rhs.aimEnd?.longitude
      && lhs.isOnTarget == rhs.isOnTarget
      && lhs.isDarkMode == rhs.isDarkMode
      && lhs.isOffline == rhs.isOffline
  }

  /// The point `distance` metres from `origin` along a true `bearing`.
  static func destination(
    from origin: CLLocationCoordinate2D,
    bearing: Double,
    distance: CLLocationDistance
  ) -> CLLocationCoordinate2D {
    let earthRadius = 6_371_000.0
    let angular = distance / earthRadius
    let theta = bearing * .pi / 180
    let lat1 = origin.latitude * .pi / 180
    let lon1 = origin.longitude * .pi / 180
    let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta))
    let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
    return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
  }
}
