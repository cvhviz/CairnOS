import CairnServices
import SwiftUI

/// The map half of Settings › Maps & GPS (`GNSSLocationSettingsSheet`): the basemap's light/dark
/// appearance, how long traffic lines and rings stay (`TrafficMapModel.activeLifetime`), and the
/// offline map downloads — what no map's own controls offer. Style, labels and clustering are set
/// from each map's options menu (`MapControlsToolbar`), which every map shows, so they aren't
/// repeated here.
struct MapsSettingsSections: View {
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  @AppStorage(AppStorageKey.trafficFadeSeconds.rawValue)
  private var trafficFadeSeconds = AppStorageKey.defaultTrafficFadeSeconds

  @State private var showingRegionPicker = false
  @State private var pendingDeletion: [OfflinePack] = []

  private var mapColorScheme: Binding<AppColorSchemePreference> {
    Binding(
      get: { AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system },
      set: { mapColorSchemeRaw = $0.rawValue }
    )
  }

  var body: some View {
    Group {
      CardFormSection(L10n.Settings.Maps.displayHeader, info: L10n.Settings.Maps.appearanceFooter) {
        PickerCard(
          L10n.Settings.Maps.appearance,
          systemImage: "circle.lefthalf.filled",
          color: .indigo,
          selection: mapColorScheme
        ) {
          Text(L10n.Settings.Appearance.Scheme.system).tag(AppColorSchemePreference.system)
          Text(L10n.Settings.Appearance.Scheme.light).tag(AppColorSchemePreference.light)
          Text(L10n.Settings.Appearance.Scheme.dark).tag(AppColorSchemePreference.dark)
        }
      }

      CardFormSection(L10n.Settings.Maps.trafficHeader, info: L10n.Settings.Maps.trafficFadeFooter) {
        PickerCard(
          L10n.Settings.Maps.trafficFade,
          systemImage: "point.3.filled.connected.trianglepath.dotted",
          color: .green,
          selection: $trafficFadeSeconds
        ) {
          ForEach(TrafficMapModel.fadeChoices, id: \.self) { seconds in
            Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
              .tag(seconds)
          }
        }
      }

      OfflineMapsSections(
        showingRegionPicker: $showingRegionPicker,
        pendingDeletion: $pendingDeletion
      )
    }
    .offlineMapsPresentations(
      showingRegionPicker: $showingRegionPicker,
      pendingDeletion: $pendingDeletion
    )
  }
}
