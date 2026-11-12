import CairnServices
import CoreLocation
import MapKit
import SwiftUI

/// The header card at the top of a node's page: who the node is, and where.
///
/// With a location, the card is a small map centered on the node's pin, with the identity laid over
/// its foot on a material band (a small avatar, the name, a subtitle such as the node type, and a
/// line of current facts like "5m ago · 1 hop · 2.3 km"). It replaces both the large avatar header
/// and the separate map section, so a node page starts with its content a screen sooner. Without a
/// location it's the same identity band on its own, as a plain card.
///
/// The avatar is a slot, so a page can make it a button (Contact Detail opens the photo picker
/// from it). Pass `onEditTitle` to put a rename button beside the name. Tapping the map calls
/// `onTapMap` (typically a full-screen map). VoiceOver reads the
/// identity as one element, with "View on Map" as its action when the map can be opened.
///
/// Usage, on a `CardForm` page:
/// ```swift
/// VStack(spacing: CardStyle.spacing) {
///   NodeMapHeader(coordinate: node.coordinate, marker: .contactRepeater, title: node.name,
///                 subtitle: "Repeater", infoLine: "5m ago · Direct", onTapMap: { showMap = true }) {
///     NodeAvatar(publicKey: node.publicKey, role: .repeater, size: NodeMapHeader<EmptyView>.avatarSize)
///   }
///   NodeActionTileRow(count: 2) { … }
/// }
/// ```
struct NodeMapHeader<Avatar: View>: View {
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  /// Settings > Maps > Appearance, which every map follows, this preview included.
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  /// Size for the avatar a caller passes in, so every node page uses the same one.
  static var avatarSize: CGFloat { 40 }

  let coordinate: CLLocationCoordinate2D?
  let marker: MapPoint.PinStyle
  /// The node's avatar for its pin (photo and picked colour), so the map pin matches the avatar
  /// beside the name. Nil looks the node up by `markerPublicKey`, else draws the name alone.
  let markerAvatar: MapPinAvatar?
  /// The node's key, to find its picked photo and colour when `markerAvatar` is nil.
  let markerPublicKey: Data?
  let title: String
  let subtitle: String?
  let infoLine: String?
  /// Drawn in place of `infoLine`'s text (icons with values); `infoLine` still gives VoiceOver its value.
  let infoView: AnyView?
  let onTapMap: (() -> Void)?
  /// Shows a pencil after the name that calls this, for a page where the name can be changed.
  let onEditTitle: (() -> Void)?
  /// A row under the info line, such as `NodeHeaderChips` (the key and groups).
  let footer: AnyView?
  /// Under the subtitle, in the name's column: the node's key and groups (`NodeHeaderChips`).
  let chips: AnyView?
  /// How far the node is from this phone, after the coordinates on the map; off for this radio.
  let showsDistance: Bool
  /// Laid over the map's bottom-right corner (how fresh a node's readings are); not shown without a map.
  let mapOverlay: AnyView?
  /// Facts set against the band's trailing edge, opposite the name (Device Info's link state). With
  /// one, the rename pencil sits small beside the name instead of at the trailing edge.
  let trailing: AnyView?
  @ViewBuilder let avatar: () -> Avatar

  /// Height of the map above the identity band's top edge.
  @ScaledMetric(relativeTo: .body) private var mapHeight: CGFloat = 120
  /// Map span around the node: a few blocks, enough to place it without losing the pin.
  private static var span: MKCoordinateSpan { MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02) }

  init(
    coordinate: CLLocationCoordinate2D?,
    marker: MapPoint.PinStyle,
    markerAvatar: MapPinAvatar? = nil,
    markerPublicKey: Data? = nil,
    title: String,
    subtitle: String? = nil,
    infoLine: String? = nil,
    infoView: AnyView? = nil,
    onTapMap: (() -> Void)? = nil,
    onEditTitle: (() -> Void)? = nil,
    footer: AnyView? = nil,
    chips: AnyView? = nil,
    showsDistance: Bool = true,
    mapOverlay: AnyView? = nil,
    trailing: AnyView? = nil,
    @ViewBuilder avatar: @escaping () -> Avatar
  ) {
    self.trailing = trailing
    self.footer = footer
    self.chips = chips
    self.showsDistance = showsDistance
    self.mapOverlay = mapOverlay
    self.coordinate = coordinate
    self.marker = marker
    self.markerAvatar = markerAvatar
    self.markerPublicKey = markerPublicKey
    self.title = title
    self.subtitle = subtitle
    self.infoLine = infoLine
    self.infoView = infoView
    self.onTapMap = onTapMap
    self.onEditTitle = onEditTitle
    self.avatar = avatar
  }

  var body: some View {
    Group {
      if let coordinate {
        VStack(spacing: 0) {
          map(at: coordinate)
            .frame(height: mapHeight)
          // On the card's own background (the user, 2026-11-09: the material read as mid grey).
          identityBand
        }
        .background { CardBackground() }
        .clipShape(CardStyle.shape)
      } else {
        identityBand
          .background { CardBackground() }
      }
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Map

  private func map(at coordinate: CLLocationCoordinate2D) -> some View {
    ZStack(alignment: .topTrailing) {
      CairnMapView(
        points: [MapPoint(
          id: Self.pointID,
          coordinate: coordinate,
          pinStyle: marker,
          label: nil,
          isClusterable: false,
          hopIndex: nil,
          badgeText: nil,
          // The title is the node's name, which picks a companion's avatar colour and emoji.
          avatar: markerAvatar
            ?? MapPinAvatar(name: title, appearance: appState.nodeAppearance.appearance(for: markerPublicKey))
        )],
        lines: [],
        mapStyle: .standard,
        isDarkMode: resolvedMapIsDark(
          preference: AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system,
          colorScheme: colorScheme
        ),
        isOffline: !appState.offlineMapService.isNetworkAvailable,
        showLabels: false,
        showsUserLocation: false,
        isInteractive: false,
        showsScale: false,
        hidesAttribution: true,
        isMuted: true,
        cameraRegion: .constant(MKCoordinateRegion(center: coordinate, span: Self.span)),
        cameraRegionVersion: coordinate.latitude.hashValue ^ coordinate.longitude.hashValue,
        onPointTap: onTapMap.map { action in { _, _ in action() } },
        onMapTap: onTapMap.map { action in { _ in action() } },
        onCameraRegionChange: nil
      )
      // The map is a picture of the location; the identity element carries the open action.
      .accessibilityHidden(true)

      if onTapMap != nil {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.caption.weight(.semibold))
          .padding(6)
          .background(.regularMaterial, in: .rect(cornerRadius: 6))
          .padding(8)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if let trailing {
        // the status capsule on a material backing, so its tint reads over the streets
        trailing
          .fixedSize()
          .background(.regularMaterial, in: .capsule)
          .padding(8)
          .allowsHitTesting(false)
      } else if let mapOverlay {
        mapOverlay
          .padding(8)
          .allowsHitTesting(false)
      }
    }
    // The coordinates and how far away, on the map they place (the user, 2026-11-09: rows of the band
    // for them made it tall); a long press on the header copies them.
    .overlay(alignment: .bottomLeading) {
      let distance = showsDistance
        ? NodeRouteFormat.distance(from: appState.bestAvailableLocation, latitude: coordinate.latitude, longitude: coordinate.longitude)
        : nil
      Label(NodeRouteFormat.joined([RemoteNodeHeaderFormat.coordinateText(coordinate), distance]), systemImage: "location.fill")
        .labelStyle(GPSLineLabelStyle())
        .font(.caption2.weight(.medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .padding(8)
        .allowsHitTesting(false)
    }
  }

  /// One fixed id: the header shows a single pin, and a stable id keeps the map from re-adding it.
  private static var pointID: UUID { UUID(uuidString: "6E6F6465-4D61-7048-6561-646572000000")! }

  // MARK: - Identity

  /// Two lines beside the avatar, each using the full width (the user, 2026-11-09): the name and its
  /// pencil with the status capsule (`trailing`) at the far end; then the subtitle ("Repeater · Direct")
  /// with the key and groups (`chips`) at the far end. Then the footer, its readings across the band.
  private var identityBand: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 10) {
        avatar()
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 2) {
              Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
                .modifier(MapOpenAccessibilityAction(onTapMap: coordinate == nil ? nil : onTapMap))
              if let onEditTitle {
                editButton(onEditTitle, compact: true)
              }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            // With a map, the status sits on its bottom-right corner so the name has the line (the
            // user, 2026-11-09); without one, here at the line's end.
            if let trailing, coordinate == nil {
              trailing
                .fixedSize()
            }
          }
          .frame(minHeight: 30)
          HStack(alignment: .center, spacing: 8) {
            identityLines
              .layoutPriority(1)
            Spacer(minLength: 0)
            if let chips {
              chips
                .fixedSize()
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.bottom, footer == nil ? 0 : 10)
      // Its own row, so its buttons stay reachable apart from the identity element above.
      if let footer {
        footer
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, footer == nil ? 10 : 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The subtitle and the info line under the name, read by VoiceOver as one element.
  @ViewBuilder
  private var identityLines: some View {
    let hasSubtitle = !(subtitle ?? "").isEmpty
    let hasInfo = infoView != nil || !(infoLine ?? "").isEmpty
    if hasSubtitle || hasInfo {
      VStack(alignment: .leading, spacing: 1) {
        if let subtitle, hasSubtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if let infoView {
          infoView
        } else if let infoLine, !infoLine.isEmpty {
          Text(infoLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(subtitle ?? "")
      .accessibilityValue(infoLine ?? "")
    }
  }

  /// The one place the name is edited: beside the name itself, not in a row further down. Compact,
  /// it's a small pencil right after the name, still with a full-size tap target.
  private func editButton(_ action: @escaping () -> Void, compact: Bool) -> some View {
    Button(action: action) {
      Image(systemName: compact ? "pencil" : "pencil.circle.fill")
        .font(compact ? .subheadline.weight(.semibold) : .title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
        .frame(minWidth: compact ? 30 : 44, minHeight: compact ? 30 : 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Contacts.Contacts.Detail.rename)
    .accessibilityValue(title)
  }
}

/// "View on Map" as a named action on the identity element, only when there's a map to open.
private struct MapOpenAccessibilityAction: ViewModifier {
  let onTapMap: (() -> Void)?

  func body(content: Content) -> some View {
    if let onTapMap {
      content
        .accessibilityAction(named: L10n.RemoteNodes.RemoteNodes.Status.viewOnMap, onTapMap)
        .accessibilityHint(L10n.Map.Map.Preview.accessibilityHint)
    } else {
      content
    }
  }
}
