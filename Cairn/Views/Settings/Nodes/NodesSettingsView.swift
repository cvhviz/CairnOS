import CairnServices
import SwiftUI

/// Settings › Nodes & Auto-Add (`SettingsDetail.nodes`), also what the Nodes tab's sliders open: how
/// the node list looks (rows or cards, sort order), then everything that decides what is in it —
/// which heard nodes the radio adds by itself, which old ones the app removes, and clearing the list
/// by hand. Auto-add and removal are the radio's, so without one Auto-Add says so and Remove Nodes is
/// left out; the list, its sort and the cleanup are the app's own and stay editable offline. New-node
/// alerts are on the Notifications page with every other alert.
struct NodesSettingsView: View {
  @Environment(\.appState) private var appState
  @AppStorage(AppStorageKey.nodesDisplayMode.rawValue) private var displayMode: NodeDisplayMode = .list
  @AppStorage(AppStorageKey.nodesSortOrder.rawValue) private var sortOrder: NodeSortOrder = .lastHeard
  @State private var showLocationDeniedAlert = false

  var body: some View {
    CardForm {
      CardFormSection(L10n.Contacts.Contacts.TabSettings.listHeader) {
        PickerCard(
          L10n.Contacts.Contacts.TabSettings.layout,
          systemImage: displayMode.systemImage,
          color: .indigo,
          selection: $displayMode.animation(.snappy)
        ) {
          ForEach(NodeDisplayMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .accessibilityIdentifier("nodes.displayMode")

        PickerCard(
          L10n.Contacts.Contacts.List.sort,
          systemImage: "arrow.up.arrow.down",
          color: .blue,
          selection: $sortOrder
        ) {
          ForEach(NodeSortOrder.allCases, id: \.self) { order in
            Text(order.localizedTitle).tag(order)
          }
        }
      }

      NodesSettingsSections()
    }
    .flashingNavigationTitle(SettingsDetail.nodes.title)
    .navigationBarTitleDisplayMode(.inline)
    // The list asks for location itself; only the denial needs saying here, since an alert from the
    // list can't show over Settings.
    .onChange(of: sortOrder) { _, newOrder in
      if newOrder == .distance, appState.locationService.isLocationDenied {
        showLocationDeniedAlert = true
      }
    }
    .alert(L10n.Contacts.Contacts.List.locationUnavailable, isPresented: $showLocationDeniedAlert) {
      Button(L10n.Contacts.Contacts.List.openSettings) {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Contacts.Contacts.List.distanceRequiresLocation)
    }
  }
}

/// What decides what is in the node list, as sections on the page: the radio's auto-add (or a line
/// saying it needs a radio), the app's stale-node cleanup, and, with a radio, removing nodes by hand.
struct NodesSettingsSections: View {
  @Environment(\.appState) private var appState
  /// The arrival read failed: Auto-Add shows the last known values (`RadioReadFootnote`).
  @State private var readFailed = false

  var body: some View {
    Group {
      if appState.connectedDevice != nil {
        AutoAddSettingsSection()
        if readFailed {
          RadioReadFootnote()
        }
      } else {
        CardFormSection(L10n.Settings.Nodes.AutoAdd.header, footer: L10n.Contacts.Contacts.TabSettings.radioRequired) {
          EmptyView()
        }
      }

      StaleNodeCleanupSection()

      if appState.connectedDevice != nil {
        NodeRemovalSection()
      }
    }
    .task(id: refreshTaskID) {
      await refreshAutoAddSettings()
    }
  }

  private var refreshTaskID: String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    let syncPhase = appState.connectionUI.currentSyncPhase.map { String(describing: $0) } ?? "none"
    return "\(deviceID)-\(String(describing: appState.connectionState))-\(syncPhase)"
  }

  /// Reads the auto-add settings fresh so the page shows what the radio holds, not a cache from
  /// before another client changed it.
  private func refreshAutoAddSettings() async {
    // Wait until contact/channel sync contention is over before sending startup reads.
    guard appState.canRunSettingsStartupReads,
          let settingsService = appState.services?.settingsService else { return }
    var failed = false
    do {
      _ = try await settingsService.getSelfInfo()
    } catch {
      failed = true
    }

    // The auto-add config read exists from firmware v1.12.
    if appState.connectedDevice?.supportsAutoAddConfig == true {
      do {
        try await settingsService.refreshAutoAddConfig()
      } catch {
        failed = true
      }
    }
    readFailed = failed
  }
}

#Preview {
  NavigationStack {
    NodesSettingsView()
  }
  .environment(\.appState, AppState())
}
