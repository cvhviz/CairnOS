import CairnServices
import MapLibre
import SwiftUI

/// Single filter config for maps that expose the Filter menu.
struct MapFilterControl {
  let host: MapFilterHost
  var state: Binding<MapFilterState>
  /// Nodes hidden from this map. The menu offers their list while there are any.
  var hiddenNodeCount = 0
  var onShowHiddenNodes: () -> Void = {}
}

/// Shared liquid-glass toolbar hosting the controls every interactive map uses
/// (location, map options) plus a slot for one map-specific button.
/// The map options control is a native menu offering the north lock, map-style
/// picker, the labels toggle, and an optional clustering toggle.
struct MapControlsToolbar<AdditionalActions: View>: View {
  @Environment(\.appState) private var appState

  /// Centers the map on the user's location.
  var onLocationTap: () -> Void

  /// Whether the map is currently centered on the user; fills the location marker when true.
  var isCenteredOnUser: Bool = false

  /// The follow mode on a map whose location button cycles following (the GPS map). It
  /// replaces the centered marker with Apple Maps' three glyphs.
  var trackingMode: MapTrackingMode?

  @Binding var isNorthLocked: Bool
  @Binding var showLabels: Bool
  var clusteringEnabled: Binding<Bool>?
  @Binding var mapStyleSelection: MapStyleSelection

  /// Current viewport, used to gate styles that lack offline coverage for the visible area.
  var viewportBounds: MLNCoordinateBounds?

  var filter: MapFilterControl?

  /// Offers an advert, second after the location button wherever a map has it, so the maps
  /// share one order: location, advert, what's shown, traffic, framing, options.
  var showsAdvertButton = false

  /// Offers the live-traffic switch, one setting for every map that offers it.
  var showsTrafficToggle = false
  @AppStorage(AppStorageKey.mapShowsTraffic.rawValue)
  private var sharedShowsTraffic = AppStorageKey.defaultMapShowsTraffic
  /// A map with its own switch for the traffic; nil follows the one setting.
  var trafficSetting: Binding<Bool>?

  private var showsTraffic: Bool {
    get { trafficSetting?.wrappedValue ?? sharedShowsTraffic }
    nonmutating set {
      if let trafficSetting {
        trafficSetting.wrappedValue = newValue
      } else {
        sharedShowsTraffic = newValue
      }
    }
  }

  /// For a map whose overlay already keeps its cards off the screen edge (the GPS and Traffic
  /// maps): no padding of its own on that side, so its edge lines up with theirs.
  var hugsTrailingEdge = false

  /// Puts a short word under each standard control (the main and Traffic maps, where people land
  /// without knowing them); the map-specific buttons pass their own.
  var showsCaptions = false

  /// A map's own items at the top of the options menu, above its style and display settings (Scan
  /// & Traffic keeps its quiet nodes, replay and advert there, so its rail stays short).
  var optionsMenuItems: AnyView?

  /// One map-specific button shown below the standard controls.
  @ViewBuilder var additionalActions: () -> AdditionalActions

  var body: some View {
    VStack(spacing: 0) {
      locationButton

      if showsAdvertButton {
        Divider()
          .frame(width: MapToolbarLayout.dividerWidth)
        MapAdvertButton(caption: showsCaptions ? L10n.Map.Map.Controls.Caption.advert : nil)
      }

      if let filter {
        Divider()
          .frame(width: MapToolbarLayout.dividerWidth)
        filterMenu(filter)
      }

      if showsTrafficToggle {
        Divider()
          .frame(width: MapToolbarLayout.dividerWidth)
        trafficButton
      }

      CustomContentStack {
        additionalActions()
      }

      Divider()
        .frame(width: MapToolbarLayout.dividerWidth)

      mapOptionsMenu
    }
    // The buttons have fixed square frames, so accessibility text sizes push glyphs past the
    // glass. Cap the glyphs and let a long press show each control in the Large Content Viewer.
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .accessibilityShowsLargeContentViewer()
    .liquidGlass(in: .rect(cornerRadius: MapToolbarLayout.cornerRadius))
    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    .padding(hugsTrailingEdge ? [.top, .bottom, .leading] : .all)
  }

  // MARK: - Location Button

  private var locationButton: some View {
    // A cycling button doesn't only center, so it is named for what it controls, as in Apple Maps,
    // with the mode as its value.
    Button(
      trackingMode == nil ? L10n.Map.Map.Controls.centerOnMyLocation : L10n.Map.Map.Controls.Tracking.label,
      systemImage: trackingMode?.systemImage ?? (isCenteredOnUser ? "location.fill" : "location"),
      action: onLocationTap
    )
    .mapControlButton(tint: .primary, caption: showsCaptions ? L10n.Map.Map.Controls.Caption.location : nil)
    .contentTransition(trackingMode == nil ? .identity : .symbolEffect(.replace))
    .accessibilityValue(trackingMode?.accessibilityValue ?? "")
  }

  // MARK: - Traffic

  /// Draws the packets the radio hears across the map: the links they crossed lately, and a
  /// laser for each as it arrives. Cyan while on, the lasers' colour on the Home card.
  private var trafficButton: some View {
    Button(
      showsTraffic ? L10n.Map.Map.Controls.hideTraffic : L10n.Map.Map.Controls.showTraffic,
      systemImage: showsTraffic
        ? "point.topleft.down.to.point.bottomright.curvepath.fill"
        : "point.topleft.down.to.point.bottomright.curvepath"
    ) {
      showsTraffic.toggle()
    }
    .mapControlButton(tint: showsTraffic ? .cyan : .primary, caption: showsCaptions ? L10n.Map.Map.Controls.Caption.traffic : nil)
    .contentTransition(.symbolEffect(.replace))
    .sensoryFeedback(.selection, trigger: showsTraffic)
    .accessibilityIdentifier("map.traffic")
  }

  // MARK: - Filter Menu

  @ViewBuilder
  private func filterMenu(_ filter: MapFilterControl) -> some View {
    let state = filter.state
    let host = filter.host
    let capabilities = host.capabilities
    let active = state.wrappedValue.differsFromSeed(for: host)
    Menu {
      if capabilities.contains(.favorites) {
        Toggle(isOn: toggleBinding(state, \.favoritesOnly) { $0.setFavoritesOnly($1) }) {
          Label(L10n.Contacts.Contacts.Segment.favorites, systemImage: "star.fill")
        }
      }
      if capabilities.contains(.discovered) {
        Toggle(isOn: toggleBinding(state, \.showDiscovered) { $0.setShowDiscovered($1) }) {
          Label(L10n.Map.Map.Callout.discovered, systemImage: "antenna.radiowaves.left.and.right")
        }
        .disabled(state.wrappedValue.favoritesOnly)
      }
      if capabilities.contains(.recency) {
        Picker(selection: Binding(
          get: { state.wrappedValue.heardWithin },
          set: { newValue in
            var copy = state.wrappedValue
            copy.setHeardWithin(newValue)
            state.wrappedValue = copy
          }
        )) {
          ForEach(MapRecencyWindow.allCases, id: \.self) { window in
            Text(window.title).tag(window)
          }
        } label: {
          Label(L10n.Map.Map.Filter.heardWithin, systemImage: "clock")
        }
        .pickerStyle(.menu)
        .disabled(!state.wrappedValue.effectiveShowDiscovered)
      }
      if capabilities.includesTypes {
        Divider()
        Toggle(isOn: toggleBinding(state, \.showChat) {
          $0.setShowChat($1, host: host)
        }) {
          Text(L10n.Contacts.Contacts.Segment.contacts)
        }
        .disabled(state.wrappedValue.favoritesOnly)
        Toggle(isOn: toggleBinding(state, \.showRepeater) {
          $0.setShowRepeater($1, host: host)
        }) {
          Text(L10n.Contacts.Contacts.Segment.repeaters)
        }
        .disabled(state.wrappedValue.favoritesOnly)
        Toggle(isOn: toggleBinding(state, \.showRoom) {
          $0.setShowRoom($1, host: host)
        }) {
          Text(L10n.Contacts.Contacts.Segment.rooms)
        }
        .disabled(state.wrappedValue.favoritesOnly)
      }
      if filter.hiddenNodeCount > 0 {
        Divider()
        Button(
          L10n.Map.Map.Filter.hiddenNodes(filter.hiddenNodeCount),
          systemImage: "eye.slash",
          action: filter.onShowHiddenNodes
        )
      }
    } label: {
      Label(
        L10n.Map.Map.Controls.filter,
        systemImage: active
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle"
      )
    }
    .mapControlButton(tint: .primary, caption: showsCaptions ? L10n.Map.Map.Controls.Caption.filter : nil)
    .accessibilityLabel(L10n.Map.Map.Controls.filter)
    .accessibilityValue(active ? L10n.Map.Map.Controls.filterActive : "")
  }

  private func toggleBinding(
    _ state: Binding<MapFilterState>,
    _ keyPath: KeyPath<MapFilterState, Bool>,
    set: @escaping (inout MapFilterState, Bool) -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { state.wrappedValue[keyPath: keyPath] },
      set: { newValue in
        var copy = state.wrappedValue
        set(&copy, newValue)
        state.wrappedValue = copy
      }
    )
  }

  // MARK: - Map Options Menu

  private var mapOptionsMenu: some View {
    Menu {
      if let optionsMenuItems {
        optionsMenuItems
        Divider()
      }
      Picker(L10n.Map.Map.Style.accessibilityLabel, selection: $mapStyleSelection) {
        ForEach(MapStyleSelection.allCases.reversed(), id: \.self) { style in
          Text(style.label)
            .tag(style)
            .disabled(isDisabled(style))
            .accessibilityHint(disabledReason(for: style) ?? "")
        }
      }

      Divider()

      Toggle(L10n.Map.Map.Controls.showLabels, systemImage: "character.textbox", isOn: $showLabels)
      if let clusteringEnabled {
        Toggle(L10n.Map.Map.Controls.clusterNodes, systemImage: "circle.grid.2x2", isOn: clusteringEnabled)
      }
      Toggle(L10n.Map.Map.Controls.lockNorth, systemImage: "location.north.line", isOn: $isNorthLocked)
    } label: {
      Label(L10n.Map.Map.Controls.mapOptions, systemImage: "ellipsis.circle")
    }
    .mapControlButton(tint: .primary, caption: showsCaptions ? L10n.Map.Map.Controls.Caption.options : nil)
  }

  private func isDisabled(_ style: MapStyleSelection) -> Bool {
    !appState.offlineMapService.isNetworkAvailable
      && (style.requiresNetwork || !hasOfflineCoverage(for: style))
  }

  private func disabledReason(for style: MapStyleSelection) -> String? {
    guard isDisabled(style) else { return nil }
    return style.requiresNetwork
      ? L10n.Map.Map.Style.requiresNetwork
      : L10n.Map.Map.Style.noOfflineCoverage
  }

  private func hasOfflineCoverage(for style: MapStyleSelection) -> Bool {
    if let viewportBounds {
      appState.offlineMapService.hasCompletedPack(for: style.offlineMapLayer, overlapping: viewportBounds)
    } else {
      appState.offlineMapService.hasCompletedPack(for: style.offlineMapLayer)
    }
  }
}

// MARK: - Layout

private enum MapToolbarLayout {
  static var cornerRadius: CGFloat {
    if #available(iOS 26.0, *) { .infinity } else { 12 }
  }

  static var dividerWidth: CGFloat {
    if #available(iOS 26.0, *) { 0 } else { 24 }
  }
}

// MARK: - Custom Content Stack

// MARK: - Advert

/// Sends this radio's advert from a map's controls (the Traffic map and the GPS map): a tap asks
/// which, zero-hop to the nodes in range or flooded across the mesh, as Home's Send Advert does.
/// The glyph says sent or failed for a moment after.
private struct MapAdvertButton: View {
  var caption: String?

  @Environment(\.appState) private var appState
  @State private var isChoosing = false
  @State private var isSending = false
  @State private var result: Bool?

  private var systemImage: String {
    switch result {
    case true?: "checkmark"
    case false?: "exclamationmark.triangle.fill"
    case nil: "megaphone.fill"
    }
  }

  private var tint: Color {
    switch result {
    case true?: .green
    case false?: .orange
    case nil: HomeToolColors.lead
    }
  }

  var body: some View {
    Button {
      isChoosing = true
    } label: {
      VStack(spacing: 2) {
        Group {
          if isSending {
            ProgressView()
          } else {
            Image(systemName: systemImage)
              .contentTransition(.symbolEffect(.replace))
          }
        }
        if let caption {
          MapControlCaption(text: caption)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(L10n.Tools.Tools.advert)
    }
    .mapControlButton(tint: tint, caption: caption)
    .radioDisabled(for: appState.connectionState, or: isSending)
    .accessibilityValue(result.map { $0 ? L10n.Chats.Chats.Message.Status.sent : L10n.Chats.Chats.Message.Status.failed } ?? "")
    .accessibilityIdentifier("map.advert")
    .sheet(isPresented: $isChoosing) {
      AdvertChoiceSheet { flood in send(flood: flood) }
    }
    .sensoryFeedback(trigger: result) { _, result in
      result.map { $0 ? .success : .error }
    }
  }

  private func send(flood: Bool) {
    guard !isSending else { return }
    isSending = true
    Task {
      let succeeded: Bool
      do {
        try await appState.sendSelfAdvert(flood: flood)
        succeeded = true
      } catch {
        succeeded = false
      }
      isSending = false
      withAnimation { result = succeeded }
      try? await Task.sleep(for: .seconds(succeeded ? 2 : 3))
      withAnimation { result = nil }
    }
  }
}

/// Wraps trailing content and inserts a divider before each child view.
private struct CustomContentStack<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Group(subviews: content) { subviews in
      ForEach(subviews) { subview in
        Divider()
          .frame(width: MapToolbarLayout.dividerWidth)
        subview
      }
    }
  }
}
