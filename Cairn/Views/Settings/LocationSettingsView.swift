import SwiftUI

/// Settings → Location & Sharing: what the radio shares (its advert's position and telemetry),
/// under a map of it, with a link to GPS & Location for where the position comes from. Built by
/// `GNSSLocationSettingsSheet` with the GPS tab's model, so the two pages never disagree.
struct LocationSettingsView: View {
  @Environment(\.appState) private var appState
  @State private var model = GNSSDashboardModel()
  @State private var live = GPSLiveLocation(tracksHeading: false)
  /// The arrival read failed: the switches show the last known values (`RadioReadFootnote`).
  @State private var readFailed = false

  var body: some View {
    GNSSLocationSettingsSheet(model: model, live: live, context: .settings)
      .flashingNavigationTitle(L10n.Settings.LocationSharing.title)
      .navigationBarTitleDisplayMode(.inline)
      // The sheet owns the page's form, so the note sits under it, as a footer the form can't hold.
      .safeAreaInset(edge: .bottom) {
        if readFailed {
          RadioReadFootnote()
            .padding(.horizontal, CardStyle.pageInset)
            .padding(.vertical, 8)
            .background(.bar)
        }
      }
      .task(id: refreshTaskID) {
        await refresh()
      }
  }

  private var refreshTaskID: String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    let syncPhase = appState.connectionUI.currentSyncPhase.map { String(describing: $0) } ?? "none"
    return "\(deviceID)-\(String(describing: appState.connectionState))-\(syncPhase)"
  }

  /// The telemetry modes and advert policy come from self info, the receiver from the custom
  /// vars; read both fresh so the switches show what the radio holds, not a cache from before
  /// another client changed it.
  private func refresh() async {
    // Wait until contact/channel sync contention is over before sending startup reads.
    guard appState.canRunSettingsStartupReads,
          let settingsService = appState.services?.settingsService else { return }
    do {
      _ = try await settingsService.getSelfInfo()
      readFailed = false
    } catch {
      readFailed = true
    }
    await model.refresh(appState: appState, isActive: true)
  }
}
