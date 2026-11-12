import CoreLocation
import MapKit
import CairnServices
import SwiftUI

/// Map content displaying CairnMapView with contact/discovered points and their callouts
struct MapContentView: View {
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  /// The GPS tab's radio readings, when the map is shown there; nil on standalone maps.
  @Environment(GNSSDashboardModel.self) private var gnssModel: GNSSDashboardModel?
  @Bindable var viewModel: MapViewModel
  let mapStyleSelection: MapStyleSelection
  let showLabels: Bool
  let clusteringEnabled: Bool
  let isNorthLocked: Bool
  @Binding var selectedCallout: MapCalloutSelection?
  @Binding var selectedPointScreenPosition: CGPoint?
  @Binding var isStyleLoaded: Bool
  /// The location button's follow mode; MapLibre writes back a pan or rotate ending it.
  @Binding var trackingMode: MapTrackingMode
  /// The pin the navigation readout measures to. Set by selecting a pin, and kept when the
  /// callout closes so a pan doesn't lose it.
  @Binding var navigationTarget: MapNavigationTarget?
  /// A node's details go in the navigation panel under its name, not in a bubble on the pin (the
  /// canvas draws them there; the user, 2026-11-09: one section, as on the Traffic map).
  var nodeDetailsInPanel = false
  /// The phone's live position, while there is a target to draw the guide line to.
  let userCoordinate: CLLocationCoordinate2D?
  /// Bumped by the compass to turn the map back to north-up and flat.
  let resetOrientationVersion: Int
  let onCameraOrientationChange: (MapCameraOrientation) -> Void
  let isAddingDiscovered: Bool
  let onShowContactDetail: (ContactDTO) -> Void
  let onNavigateToChat: (ContactDTO) -> Void
  let onShowDiscoveredDetail: (DiscoveredNodeDTO) -> Void
  let onAddDiscovered: (DiscoveredNodeDTO) -> Void
  /// Opens the chat with the user's own position typed in (a contact callout's Send My Location).
  var onSendMyLocation: ((ContactDTO) -> Void)?
  let onPersistCamera: (MKCoordinateRegion) -> Void
  /// A pin to select as if tapped, fired once per bump of the version (see `CairnMapView`).
  var selectionRequestID: UUID?
  var selectionRequestVersion = 0
  /// The phone faces the target, which turns the guide line solid green.
  var isOnTarget = false
  /// Live traffic over the map, owned by the canvas, which shows its ticker.
  let traffic: TrafficLayer
  /// The traffic ticker's top edge (global y) while it shows, so MapLibre's logo and credits sit
  /// above it rather than under it.
  var legalOrnamentTopLimit: CGFloat?
  /// A tap on the bare map with nothing selected (no callout, no target), which has nothing to
  /// close: the canvas uses it to show or hide its controls.
  var onBareMapTap: (() -> Void)?

  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference
  /// Live traffic over the map, switched from its controls.
  @AppStorage(AppStorageKey.mapShowsTraffic.rawValue)
  private var showsTraffic = AppStorageKey.defaultMapShowsTraffic

  @State private var selectedDroppedPin: DroppedPinSelection?
  /// The tapped pin while its callout is open, so its name badge wins label collisions.
  @State private var tappedPointID: UUID?
  /// The traffic link whose callout is open (`MapLine.id`), as on the Traffic map.
  @State private var selectedLineID: String?

  /// A fixed id for this radio's own pin, so it never collides with a contact's.
  private static let radioPointID = MapCalloutSelection.thisRadioID

  /// This radio, where it says it is: its own GPS fix, the phone's position when the app keeps it
  /// updated, or the position set by hand. It moves whenever the radio reports a new one. Drawn
  /// as the radio's own avatar, as its Device Info header shows it.
  private var radioPoint: MapPoint? {
    guard let device = appState.connectedDevice, device.hasLocation else { return nil }
    return MapPoint(
      id: Self.radioPointID,
      coordinate: CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude),
      pinStyle: .contactChat,
      label: device.nodeName.isEmpty ? nil : device.nodeName,
      isClusterable: false,
      hopIndex: nil,
      badgeText: nil,
      isFavorite: true,
      avatar: MapPinAvatar(device: device, store: appState.radioAvatars)
    )
  }

  /// A dashed guide from the phone to the navigation target, like a straight-line route; solid
  /// green while the phone faces it.
  private var navigationLines: [MapLine] {
    guard let target = navigationTarget, let userCoordinate else { return [] }
    return [.aim(id: "navigation-target", from: userCoordinate, to: target.coordinate, isOnTarget: isOnTarget)]
  }

  /// A contact's or heard node's details are in the navigation panel rather than a bubble.
  private var detailsAreInPanel: Bool {
    guard nodeDetailsInPanel, navigationTarget != nil, selectedLineID == nil, selectedDroppedPin == nil else { return false }
    switch selectedCallout {
    case .contact, .discovered: return true
    default: return false
    }
  }

  /// A pin's (or a traffic link's) callout is showing.
  private var isCalloutOpen: Bool {
    selectedCallout != nil || selectedDroppedPin != nil || selectedLineID != nil
  }

  /// What the open callout shows: a contact, a heard node, this radio, a dropped pin, or a
  /// traffic link.
  @ViewBuilder
  private var calloutContent: some View {
    if let selectedLineID, let detail = traffic.model.linkDetail(forLineID: selectedLineID) {
      TrafficLinkCalloutContent(detail: detail, onClose: closeLineCallout)
    } else if let selectedDroppedPin {
      DroppedPinCallout(coordinate: selectedDroppedPin.coordinate) {
        viewModel.clearFocusedPin()
        self.selectedDroppedPin = nil
      }
    } else if let selectedCallout {
      switch selectedCallout {
      case let .contact(contact):
        withTraffic(for: contact.publicKey) {
          ContactCalloutContent(
            contact: contact,
            onDetail: { onShowContactDetail(contact) },
            onMessage: { onNavigateToChat(contact) },
            onSendMyLocation: onSendMyLocation.map { send -> () -> Void in { send(contact) } }
          )
        }
      case let .discovered(node):
        withTraffic(for: node.publicKey) {
          DiscoveredNodeCalloutContent(
            node: node,
            isAdding: isAddingDiscovered,
            onDetail: { onShowDiscoveredDetail(node) },
            onAdd: { onAddDiscovered(node) }
          )
        }
      case .thisRadio:
        if let device = appState.connectedDevice {
          RadioCalloutContent(device: device, model: gnssModel)
        }
      }
    }
  }

  /// A node's callout, with what it has carried lately under it while traffic is on.
  @ViewBuilder
  private func withTraffic(for key: Data, @ViewBuilder content: () -> some View) -> some View {
    if showsTraffic {
      VStack(alignment: .leading, spacing: 0) {
        content()
        Divider()
          .padding(.horizontal, 12)
        TrafficActivitySummary(activity: traffic.model.activity(for: key))
          .padding(12)
          .frame(maxWidth: 260, alignment: .leading)
      }
    } else {
      content()
    }
  }

  /// The nodes and this radio; with traffic on, repeaters passing it are ringed green, and the
  /// open link's callout rides on an invisible point at the link's middle.
  private var points: [MapPoint] {
    let points = viewModel.mapPoints + (radioPoint.map { [$0] } ?? [])
    guard showsTraffic else { return points }
    var ringed = traffic.ringing(points) { viewModel.pointID(forPublicKey: $0) }
    if let selectedLineID, let detail = traffic.model.linkDetail(forLineID: selectedLineID) {
      ringed.append(MapPoint(
        id: TrafficMapModel.lineAnchorID,
        coordinate: detail.midpoint,
        pinStyle: .badge,
        label: nil,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ))
    }
    return ringed
  }

  /// A traffic link opens its summary, as on the Traffic map; a second tap closes it. Lines are
  /// only tappable while traffic draws them.
  private var lineTapHandler: ((String) -> Void)? {
    guard showsTraffic else { return nil }
    return { id in
      if id == selectedLineID {
        closeLineCallout()
        return
      }
      selectedCallout = nil
      selectedDroppedPin = nil
      selectedLineID = id
      traffic.model.selectLine(id: id)
      tappedPointID = TrafficMapModel.lineAnchorID
      selectedPointScreenPosition = traffic.model.linkDetail(forLineID: id)
        .flatMap { traffic.projection.point(for: $0.midpoint) }
        .map { CGPoint(x: $0.x, y: $0.y - PinSpriteRenderer.calloutLift(for: .badge)) }
    }
  }

  /// Closes a traffic link's callout; the navigation target was never one.
  private func closeLineCallout() {
    selectedLineID = nil
    traffic.model.selectLine(id: nil)
    selectedPointScreenPosition = nil
  }

  /// A long press drops the pin there, with its callout open and the readout aiming at it, as a
  /// tap on the pin would; the camera stays where it is, since it's already looking there.
  private func dropPin(at coordinate: CLLocationCoordinate2D) {
    guard coordinate.isValidFix else { return }
    viewModel.dropPin(at: coordinate)
    selectedLineID = nil
    traffic.model.selectLine(id: nil)
    selectedCallout = nil
    tappedPointID = MapViewModel.focusedPinID
    navigationTarget = MapNavigationTarget(
      pointID: MapViewModel.focusedPinID,
      name: coordinate.formattedString,
      coordinate: coordinate
    )
    selectedDroppedPin = DroppedPinSelection(coordinate: coordinate)
    // Where the pin's callout hangs until the map reports the pin's own anchor.
    if let point = traffic.projection.point(for: coordinate) {
      selectedPointScreenPosition = CGPoint(x: point.x, y: point.y - PinSpriteRenderer.calloutLift(for: .droppedPin))
    }
  }

  private var mapIsDark: Bool {
    let preference = AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system
    return resolvedMapIsDark(preference: preference, colorScheme: colorScheme)
  }

  var body: some View {
    CairnMapView(
      points: points,
      lines: navigationLines + (showsTraffic ? traffic.lines : []),
      mapStyle: mapStyleSelection,
      isDarkMode: mapIsDark,
      isOffline: !appState.offlineMapService.isNetworkAvailable,
      showLabels: showLabels,
      clusteringEnabled: clusteringEnabled,
      showsUserLocation: true,
      isInteractive: true,
      showsScale: true,
      isNorthLocked: isNorthLocked,
      cameraRegion: $viewModel.cameraRegion,
      cameraRegionVersion: viewModel.cameraRegionVersion,
      legalOrnamentTopLimit: legalOrnamentTopLimit,
      selectionRequestID: selectionRequestID,
      selectionRequestVersion: selectionRequestVersion,
      selectedPointID: isCalloutOpen ? tappedPointID : nil,
      // The callout rides on its pin as the map is panned or zoomed.
      onSelectedPointMove: { selectedPointScreenPosition = $0 },
      onPointTap: { point, screenPosition in
        // A second tap on the pin whose callout is open closes it; the navigation target stays,
        // as it does whenever the callout closes.
        if isCalloutOpen, point.id == tappedPointID {
          selectedCallout = nil
          selectedDroppedPin = nil
          selectedPointScreenPosition = nil
          closeLineCallout()
          return
        }
        if selectedLineID != nil {
          selectedLineID = nil
          traffic.model.selectLine(id: nil)
        }
        tappedPointID = point.id
        // This radio's own pin has no contact behind it; its callout reads the connected device.
        // It sets no navigation target, and clears a previous pin's: the readout would measure to
        // where the phone already is.
        if point.id == Self.radioPointID {
          navigationTarget = nil
          selectedDroppedPin = nil
          selectedCallout = .thisRadio
          selectedPointScreenPosition = screenPosition
          return
        }
        navigationTarget = MapNavigationTarget(
          pointID: point.id,
          name: point.label ?? point.coordinate.formattedString,
          coordinate: point.coordinate
        )
        if point.pinStyle == .droppedPin {
          selectedCallout = nil
          selectedDroppedPin = DroppedPinSelection(coordinate: point.coordinate)
        } else if let contact = viewModel.contact(forPointID: point.id) {
          selectedDroppedPin = nil
          selectedCallout = .contact(contact)
        } else if let node = viewModel.discovered(forPointID: point.id) {
          selectedDroppedPin = nil
          selectedCallout = .discovered(node)
        } else {
          selectedCallout = nil
        }
        selectedPointScreenPosition = screenPosition
      },
      onMapTap: { _ in
        // Like Apple Maps, a tap on the bare map deselects, which ends the navigation target;
        // with nothing to deselect, it's the canvas's to use.
        if !isCalloutOpen, navigationTarget == nil {
          onBareMapTap?()
          return
        }
        navigationTarget = nil
        selectedCallout = nil
        selectedDroppedPin = nil
        selectedPointScreenPosition = nil
        closeLineCallout()
      },
      onMapLongPress: { coordinate in dropPin(at: coordinate) },
      onLineTap: lineTapHandler,
      onCameraRegionChange: { region in
        // Panning and zooming keep the callout open; it follows its pin. Only a tap closes it.
        viewModel.cameraRegion = region
        onPersistCamera(region)
      },
      isStyleLoaded: $isStyleLoaded,
      userTrackingMode: $trackingMode,
      showsUserHeadingIndicator: true,
      hidesCompassOrnament: true,
      scaleBarAtBottomTrailing: true,
      onCameraOrientationChange: onCameraOrientationChange,
      resetOrientationVersion: resetOrientationVersion,
      onFollowingCameraChange: { region in
        viewModel.cameraRegion = region
        onPersistCamera(region)
      },
      projection: traffic.projection
    )
    .trafficLasers(traffic, isOn: showsTraffic, isDark: mapIsDark)
    .trafficFeed(traffic, isOn: showsTraffic)
    // A target's pin can move (a new advert, the dropped pin reused for another coordinate) or go
    // (hidden, filtered out, the dropped pin cleared, another radio); follow it or drop it.
    .onChange(of: viewModel.mapPoints) { _, points in
      guard let target = navigationTarget else { return }
      guard let point = points.first(where: { $0.id == target.pointID }) else {
        navigationTarget = nil
        return
      }
      let moved = MapNavigationTarget(
        pointID: point.id,
        name: point.label ?? point.coordinate.formattedString,
        coordinate: point.coordinate
      )
      if moved != target { navigationTarget = moved }
    }
    // The callout as a bubble over the map rather than a popover: a popover closes at the first
    // touch outside it, so it could never stay up while the map is panned. Handed up to the
    // canvas, which draws it over the map but under its readout and controls (`mapCallout()`).
    .preference(
      key: MapCalloutPreferenceKey.self,
      value: selectedPointScreenPosition.flatMap { anchor in
        isCalloutOpen && !detailsAreInPanel
          ? MapCallout(anchor: anchor, content: AnyView(calloutContent), id: tappedPointID)
          : nil
      }
    )
    // Traffic off takes its links with it; so does the open link's callout.
    .onChange(of: showsTraffic) { _, isOn in
      if !isOn, selectedLineID != nil { closeLineCallout() }
    }
    // The radio's pin goes with its position or its connection; so does its callout.
    .onChange(of: radioPoint == nil) { _, isGone in
      if isGone, selectedCallout == .thisRadio {
        selectedCallout = nil
        selectedPointScreenPosition = nil
      }
    }
    .overlay {
      if !isStyleLoaded {
        ProgressView()
          .scaleEffect(1.5)
      } else if viewModel.isLoading {
        MapLoadingOverlay()
      }
    }
  }
}

// MARK: - Loading Overlay

private struct MapLoadingOverlay: View {
  var body: some View {
    ZStack {
      Color.black.opacity(0.1)
      ProgressView()
        .padding()
        .liquidGlass(in: .rect(cornerRadius: 12, style: .continuous))
    }
  }
}

// MARK: - Callout Bubble

/// The open callout and where its pin is, handed up from the map content to the canvas.
struct MapCallout {
  let anchor: CGPoint
  let content: AnyView
  /// The pin it belongs to, so a callout for another pin starts afresh (where it hangs, its
  /// entrance) rather than carrying on from the last.
  var id: AnyHashable?
}

struct MapCalloutPreferenceKey: PreferenceKey {
  static var defaultValue: MapCallout? { nil }

  static func reduce(value: inout MapCallout?, nextValue: () -> MapCallout?) {
    value = nextValue() ?? value
  }
}

extension View {
  /// Draws the map content's open callout over this view (the map), in the map's full-screen
  /// space, kept below the bars at the top and clear of `obstacles` (what floats over the map
  /// there, in global coordinates): it hangs under its pin when above would be covered. A map that
  /// stops at the bars instead (`fillsScreen: false`) gets the callout in its own space, kept
  /// inside it.
  @ViewBuilder
  func mapCallout(fillsScreen: Bool = true, avoiding obstacles: [CGRect] = []) -> some View {
    if fillsScreen {
      overlayPreferenceValue(MapCalloutPreferenceKey.self) { callout in
        GeometryReader { proxy in
          if let callout {
            let origin = proxy.frame(in: .global).origin
            MapCalloutBubble(
              anchor: callout.anchor,
              topLimit: proxy.safeAreaInsets.top + 8,
              bottomLimit: proxy.size.height - proxy.safeAreaInsets.bottom - 8,
              obstacles: obstacles.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ) {
              callout.content
            }
            .id(callout.id)
          }
        }
        .ignoresSafeArea()
      }
    } else {
      overlayPreferenceValue(MapCalloutPreferenceKey.self) { callout in
        if let callout {
          MapCalloutBubble(anchor: callout.anchor, topLimit: 8) {
            callout.content
          }
          .id(callout.id)
        }
      }
    }
  }
}

/// A callout hanging from `anchor` (the top of its pin), as a popover draws one: the content on a
/// rounded material card with an arrow at the pin; slid inside the map at the sides, the arrow
/// staying on the pin. Above the pin, or below it when there's no room under `topLimit` or
/// something floats over the map there (`obstacles`: the navigation readout, the controls) that
/// wouldn't cover it below. The side is chosen as it opens and kept while the map moves, changing
/// only once the side it's on runs out of room, so a pan doesn't flip it back and forth. Unlike a popover it isn't modal, so the map under it can still be panned and
/// zoomed while it's up.
private struct MapCalloutBubble<Content: View>: View {
  let anchor: CGPoint
  /// The highest the bubble may reach: below the bars over the map.
  let topLimit: CGFloat
  /// The lowest it may reach hanging below its pin; nil for no limit.
  var bottomLimit: CGFloat?
  /// What floats over the map, in the bubble's space, which it shouldn't sit under.
  var obstacles: [CGRect] = []
  @ViewBuilder let content: () -> Content

  @State private var size: CGSize = .zero
  @State private var isBelow = false
  /// Until then the side follows whatever is measured: what floats over the map (the readout opens
  /// with the callout) lands a frame or two after the callout does, while it's still fading in.
  @State private var settlesAt: Date?

  private static var arrowSize: CGSize { CGSize(width: 22, height: 11) }
  private static var edgeMargin: CGFloat { 10 }
  private static var cornerRadius: CGFloat { 14 }
  /// From the callout anchor (the top of the pin) to below the pin, for a bubble that hangs under it.
  private static var pinHeight: CGFloat { 44 }
  /// How far something may reach into the callout's space before it counts as covering it.
  private static var overlapSlack: CGFloat { 6 }
  private static var settleTime: TimeInterval { 0.3 }

  /// What the side depends on.
  private struct Placement: Equatable {
    var anchor: CGPoint
    var size: CGSize
    var mapWidth: CGFloat
    var obstacles: [CGRect]
  }

  var body: some View {
    GeometryReader { geometry in
      let halfWidth = size.width / 2
      let centreX = Self.centreX(anchor: anchor, halfWidth: halfWidth, mapWidth: geometry.size.width)
      let arrowOffset = min(
        max(anchor.x - centreX, -halfWidth + Self.cornerRadius + Self.arrowSize.width / 2),
        halfWidth - Self.cornerRadius - Self.arrowSize.width / 2
      )
      let arrow = CalloutArrow(pointsUp: isBelow)
        .fill(.regularMaterial)
        .frame(width: Self.arrowSize.width, height: Self.arrowSize.height)
        .offset(x: arrowOffset)
      VStack(spacing: 0) {
        if isBelow { arrow }
        content()
          .background(.regularMaterial, in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
        if !isBelow { arrow }
      }
      .compositingGroup()
      .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
      .fixedSize()
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
      // The arrow's tip on the anchor above the pin, or just under the pin.
      .position(
        x: centreX,
        y: isBelow ? anchor.y + Self.pinHeight + size.height / 2 : anchor.y - size.height / 2
      )
      .opacity(settlesAt == nil ? 0 : 1)
      .onChange(
        of: Placement(anchor: anchor, size: size, mapWidth: geometry.size.width, obstacles: obstacles),
        initial: true
      ) { _, placement in
        place(placement)
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
  }

  private static func centreX(anchor: CGPoint, halfWidth: CGFloat, mapWidth: CGFloat) -> CGFloat {
    // Centred on the pin, but slid back inside the map near its edges.
    min(max(anchor.x, halfWidth + edgeMargin), max(halfWidth + edgeMargin, mapWidth - halfWidth - edgeMargin))
  }

  /// Picks the side as the callout opens; after that, moves it only when its side runs out of
  /// room (or is covered) and the other side has it.
  private func place(_ placement: Placement) {
    guard placement.size != .zero else { return }
    let size = placement.size
    let left = Self.centreX(anchor: placement.anchor, halfWidth: size.width / 2, mapWidth: placement.mapWidth)
      - size.width / 2
    // `size` is the card and its arrow together.
    let above = CGRect(x: left, y: placement.anchor.y - size.height, width: size.width, height: size.height)
    let below = CGRect(x: left, y: placement.anchor.y + Self.pinHeight, width: size.width, height: size.height)
    let covering = placement.obstacles.map { $0.insetBy(dx: Self.overlapSlack, dy: Self.overlapSlack) }
    let aboveFree = above.minY >= topLimit && !covering.contains { $0.intersects(above) }
    let belowFree = below.maxY <= (bottomLimit ?? .infinity) && !covering.contains { $0.intersects(below) }

    let isOpening = settlesAt.map { Date.now < $0 } ?? true
    let next: Bool
    if isOpening {
      // Above unless it's blocked there and clear below (or simply has no room above).
      next = above.minY < topLimit || (!aboveFree && belowFree)
    } else if isBelow {
      // Stays under its pin until there's no room there and room above.
      next = !(aboveFree && !belowFree)
    } else {
      next = !aboveFree && (belowFree || above.minY < topLimit)
    }
    if settlesAt == nil {
      settlesAt = .now.addingTimeInterval(Self.settleTime)
    }
    if next != isBelow {
      isBelow = next
    }
  }
}

/// The callout's arrow: a triangle pointing down at the pin, or up when the callout hangs below it.
private struct CalloutArrow: Shape {
  var pointsUp = false

  func path(in rect: CGRect) -> Path {
    var path = Path()
    if pointsUp {
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
    } else {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    }
    path.closeSubpath()
    return path
  }
}

private struct DroppedPinSelection: Identifiable {
  let id = UUID()
  let coordinate: CLLocationCoordinate2D
}
