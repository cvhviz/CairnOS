import SwiftUI

/// The Map tab: the map preview over the position readout; the preview opens the mesh map,
/// whose back button (top left) comes back to the readout. Which one shows lives on the
/// navigation coordinator so a chat coordinate tap can open the tab straight onto the map.
struct GPSView: View {
  var body: some View {
    NavigationStack {
      GPSRootContent()
    }
  }
}

private struct GPSRootContent: View {
  @Environment(\.appState) private var appState
  /// The phone's live fix and the radio's GPS side, shared by the Position page and the Location
  /// Settings sheet so a change in one shows in the other at once.
  @State private var live = GPSLiveLocation()
  @State private var model = GNSSDashboardModel()

  private var segment: Binding<GPSSegment> {
    Binding(
      get: { appState.navigation.gpsSegment },
      set: { appState.navigation.gpsSegment = $0 }
    )
  }

  var body: some View {
    Group {
      switch segment.wrappedValue {
      case .position:
        GPSPositionView(live: live, model: model)
          // The bar's backdrop always drawn, as the Nodes list's shows it, so every tab's top reads
          // alike (the user, 2026-11-08). Not over the map, which runs edge to edge.
          .tabTopBarBackdrop()
      case .map:
        // The map's own toolbar item joins this stack's bar, its back button coming back to the
        // readings; the title and the sliders come from here.
        MapView(isEmbedded: true, onShowData: { segment.wrappedValue = .position })
          // Lets this radio's map callout show the readings the Position page already took.
          .environment(model)
      }
    }
    // Not `floatsOverContent` on the map: that would change the title item between segments,
    // and the iOS 26 toolbar rebuilds (and can crash on) an item that changes shape. The map
    // turns the bar's own background on instead, which keeps the title readable over it.
    .deviceNameTitle(pageTitle: L10n.Localizable.Tabs.map)
    // Trips (the trips the radio recorded, and steps): one button in the bar on both segments, the same
    // shape always (the iOS 26 toolbar rebuilds an item that changes shape), red while the radio records.
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          TripsView()
        } label: {
          Label(L10n.Map.Map.Trips.title, systemImage: "figure.hiking")
            .foregroundStyle(appState.tripRecorder.isRecording ? Color.red : HomeStatusCards.cairnTeal)
        }
        .tint(appState.tripRecorder.isRecording ? Color.red : HomeStatusCards.cairnTeal)
        .accessibilityValue(appState.tripRecorder.recordingStartedAt.map {
          L10n.Map.Map.Trips.Record.since($0.formatted(date: .omitted, time: .shortened))
        } ?? "")
        .accessibilityIdentifier("gps.trips")
      }
    }
    // whether the radio is recording a trip (the button's red), read once per radio
    .task(id: appState.connectedDevice?.id) { await appState.tripRecorder.refreshState() }
    // The sliders (Settings › Maps & GPS, always present on both segments so the toolbar keeps
    // its identity).
    .tabSettingsToolbarItem(for: .gps)
    // Settings' Maps & GPS page reads and writes the radio through a model of its own: take what it
    // changed (the position source, Eco, a position set by hand) once Settings closes.
    .onChange(of: appState.navigation.isSettingsPresented) { _, isPresented in
      guard !isPresented else { return }
      model.loadPreferences(for: appState.connectedDevice)
      Task { await model.refresh(appState: appState, isActive: true) }
    }
    #if DEBUG
      // Screenshot runs start on the Map segment: `-uiTestGPSMap YES`, or `-uiTestMapCallout YES`
      // for the map with a contact's callout open.
      .onAppear {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "uiTestGPSMap") || defaults.bool(forKey: "uiTestMapCallout") {
          appState.navigation.gpsSegment = .map
        }
      }
    #endif
  }
}

#Preview {
  GPSView()
    .environment(\.appState, AppState())
}
