import CairnServices
import SwiftUI

/// Connections, behind the radio button in every tab's leading corner: the saved radios and the
/// radio config profiles, a segment each so each gets the whole page. Built for many radios: the
/// connected one pinned on top, the rest split into heard nearby and saved, with search (name,
/// nickname, key), a sort and a transport filter in the toolbar.
///
/// Beside a list already (Settings' page next to its hub on the iPad and the Mac: `isBesideList`),
/// or narrower than two panes, it is the list alone: a tap connects (or opens a profile) and a
/// row's chevron pushes the radio's page in the same column, with Back to the list. Only on a page
/// of its own wide enough for two panes does the list sit beside the selected radio's or profile's
/// page.
///
/// Lives on Home's stack (`SettingsDetail.connections`) rather than in a sheet, so the connection
/// alerts and pairing sheets that `ContentView` presents can show over it. Not one of the radio's
/// pages: it stays open with no radio connected.
struct ConnectionsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.isBesideList) private var isBesideList

  enum Segment: Hashable {
    case radios
    case profiles
  }

  /// Two panes from this width: a list of about 340 points and a detail page that still fits its
  /// cards side by side.
  nonisolated private static let twoPaneMinimumWidth: CGFloat = 720

  @State private var model = ConnectionsModel()
  @State private var profiles = RadioProfilesModel()
  @State private var segment = Segment.radios
  @State private var query = ""
  @State private var sort = SavedRadioSort.recent
  @State private var transportFilter = SavedRadioTransportFilter.all
  @State private var width: CGFloat = 0
  @State private var selectedRadioID: String?
  @State private var selectedProfileID: UUID?
  /// The radio page pushed on a phone.
  @State private var pushedRadioID: String?
  @State private var showingWiFiConnection = false

  private var showsDetailPane: Bool {
    Self.showsDetailPane(width: width, isBesideList: isBesideList)
  }

  /// The list beside its detail only when the page has the width and isn't already beside a list,
  /// which would make three columns.
  nonisolated static func showsDetailPane(width: CGFloat, isBesideList: Bool) -> Bool {
    !isBesideList && width >= twoPaneMinimumWidth
  }

  private var sections: SavedRadioSections {
    SavedRadioListBuilder.sections(
      rows: model.rows,
      query: query,
      filter: transportFilter,
      sort: sort,
      isNearby: model.isHeard,
      signal: model.rssi
    )
  }

  var body: some View {
    Group {
      switch segment {
      case .radios:
        radios
      case .profiles:
        profilesPane
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .pageSegmentBar {
      Picker(L10n.Settings.Connections.title, selection: $segment) {
        Text(L10n.Settings.Connections.Segment.radios).tag(Segment.radios)
        Text(L10n.Settings.Connections.Segment.profiles).tag(Segment.profiles)
      }
      .pageSegmentStyle(isOverMap: false)
    }
    .searchable(
      text: $query,
      prompt: segment == .radios
        ? L10n.Settings.Connections.Search.radios
        : L10n.Settings.Connections.Search.profiles
    )
    .flashingNavigationTitle(L10n.Settings.Connections.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        addMenu
      }
      ToolbarItem(placement: .primaryAction) {
        optionsMenu
      }
    }
    .navigationDestination(item: $pushedRadioID) { id in
      SavedRadioDetailView(model: model, profiles: profiles, rowID: id)
        .connectionsPrompts(model, appState: appState)
    }
    .connectionsPrompts(model, appState: appState, isActive: pushedRadioID == nil)
    .radioProfilePrompts(profiles, appState: appState)
    .sheet(isPresented: $showingWiFiConnection) {
      WiFiConnectionSheet()
    }
    .task(id: reloadKey) {
      await model.reload(appState)
    }
    .task(id: model.isScanSuspended) {
      // Scanning only to mark which Bluetooth radios are heard and how well; the task's end
      // stops the scan.
      guard !model.isScanSuspended else { return }
      await model.tracker.consume(appState.connectionManager.startBLEScanning())
    }
    .task { profiles.load() }
    .onChange(of: appState.connectionManager.isPairingFlowActive) { _, isActive in
      if !isActive { model.isScanSuspended = false }
    }
  }

  /// A connect, switch, disconnect or pairing changes the list: reload when the radio changes or
  /// becomes ready (its saved record, last-connected date and transport are written by then).
  private var reloadKey: String {
    "\(appState.connectedDevice?.id.uuidString ?? "none")-\(appState.connectionState == .ready)"
  }

  // MARK: - Radios

  @ViewBuilder
  private var radios: some View {
    let sections = sections
    // Beside the pane the first radio stands selected until another is picked, and its row says so.
    let selected = model.row(id: selectedRadioID)?.id
      ?? sections.connected?.id ?? sections.nearby.first?.id ?? sections.saved.first?.id
    let list = SavedRadiosList(
      model: model,
      sections: sections,
      isSearching: !query.isEmpty,
      selection: Binding(get: { selected }, set: { selectedRadioID = $0 }),
      showsDetailPane: showsDetailPane,
      onOpenDetail: { pushedRadioID = $0 },
      onAddBluetooth: { model.addBluetoothRadio(appState) },
      onAddWiFi: { showingWiFiConnection = true }
    )
    if showsDetailPane {
      twoPanes {
        list
      } detail: {
        if let selected {
          SavedRadioDetailView(model: model, profiles: profiles, rowID: selected, isEmbedded: true)
            .id(selected)
        } else {
          placeholder(L10n.Settings.Connections.Detail.noSelection, systemImage: "antenna.radiowaves.left.and.right")
        }
      }
    } else {
      list
    }
  }

  // MARK: - Profiles

  @ViewBuilder
  private var profilesPane: some View {
    let selected = selectedProfileID.flatMap(profiles.profile(id:))?.id ?? profiles.filtered(by: query).first?.id
    let pane = RadioProfilesPane(
      model: profiles,
      query: query,
      showsDetailPane: showsDetailPane,
      selection: Binding(get: { selected }, set: { selectedProfileID = $0 })
    )
    if showsDetailPane {
      twoPanes {
        pane
      } detail: {
        if let selected {
          RadioProfileDetailView(model: profiles, profileID: selected, isEmbedded: true) {
            selectedProfileID = nil
          }
          .id(selected)
        } else {
          placeholder(L10n.Settings.Connections.Detail.noProfile, systemImage: "slider.horizontal.below.rectangle")
        }
      }
    } else {
      pane
    }
  }

  // MARK: - Layout

  /// The list beside the selected item's page: the list takes about two fifths, between 320 and
  /// 420 points.
  private func twoPanes(
    @ViewBuilder list: () -> some View,
    @ViewBuilder detail: () -> some View
  ) -> some View {
    HStack(spacing: 0) {
      list()
        .frame(width: min(max(width * 0.4, 320), 420))
      Divider()
        .ignoresSafeArea()
      detail()
        .frame(maxWidth: .infinity)
    }
  }

  private func placeholder(_ title: String, systemImage: String) -> some View {
    ContentUnavailableView(title, systemImage: systemImage)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .cardCanvas(theme)
  }

  // MARK: - Toolbar

  /// Add: a Bluetooth radio, a WiFi radio, or the connected radio as a profile, reachable
  /// however long the list.
  private var addMenu: some View {
    Menu {
      Button(L10n.Settings.DeviceSelection.scanBluetooth, systemImage: "antenna.radiowaves.left.and.right") {
        segment = .radios
        model.addBluetoothRadio(appState)
      }
      .disabled(appState.connectionUI.isBusy)
      Button(L10n.Settings.DeviceSelection.connectViaWifi, systemImage: "wifi.circle") {
        segment = .radios
        showingWiFiConnection = true
      }
      Divider()
      Button(L10n.Settings.Connections.Profiles.saveCurrent, systemImage: "square.and.arrow.down.on.square") {
        segment = .profiles
        profiles.beginSaving(radioName: appState.connectedDevice?.nodeName)
      }
      .disabled(!appState.isRadioReady || profiles.isSaving)
    } label: {
      Label(L10n.Settings.Connections.Add.header, systemImage: "plus")
        .labelStyle(.iconOnly)
    }
    .help(L10n.Settings.Connections.Add.header)
  }

  /// Sort and transport filter for the Radios list, as the Nodes list's options menu offers its
  /// sort.
  private var optionsMenu: some View {
    Menu {
      Picker(selection: $sort) {
        ForEach(SavedRadioSort.allCases) { Text($0.title).tag($0) }
      } label: {
        Label(L10n.Contacts.Contacts.List.sort, systemImage: "arrow.up.arrow.down")
      }
      .pickerStyle(.menu)
      Picker(selection: $transportFilter) {
        ForEach(SavedRadioTransportFilter.allCases) { Text($0.title).tag($0) }
      } label: {
        Label(L10n.Settings.Connections.Filter.title, systemImage: "line.3.horizontal.decrease")
      }
      .pickerStyle(.menu)
    } label: {
      Label(
        L10n.Settings.Connections.Filter.menu,
        systemImage: transportFilter == .all
          ? "line.3.horizontal.decrease.circle"
          : "line.3.horizontal.decrease.circle.fill"
      )
      .labelStyle(.iconOnly)
    }
    .disabled(segment != .radios)
    .help(L10n.Settings.Connections.Filter.menu)
  }
}

#Preview {
  NavigationStack {
    ConnectionsView()
  }
  .environment(\.appState, AppState())
}
