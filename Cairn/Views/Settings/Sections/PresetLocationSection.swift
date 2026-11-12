import CairnServices
import SwiftUI

/// Preset-location filter on Settings → Radio, always inline. It opens expanded when the
/// selection still needs the user (see `PresetLocationPolicy.startsExpandedOnRadio`) and collapsed
/// to its summary otherwise. Hidden by the parent when Repeat Mode is on.
struct PresetLocationSection: View {
  @Environment(\.appState) private var appState
  @Environment(PresetLocationSession.self) private var session
  @Binding var activeSheet: RegionPickerRows.Sheet?
  @State private var isExpanded = false
  @State private var hasSetInitialExpansion = false

  private var selection: RegionSelection? {
    appState.regionSelection
  }

  private var rowDetail: String {
    if let selection {
      return RegionalAreas.displayName(for: selection)
    }
    return L10n.Settings.Radio.PresetLocation.notSet
  }

  var body: some View {
    CardFormSection {
      ContentCard {
        DisclosureGroup(isExpanded: $isExpanded) {
          VStack(alignment: .leading, spacing: 12) {
            Divider()
            RegionPickerRows(
              selection: Bindable(appState).regionSelection,
              activeSheet: $activeSheet
            )
            presetLocationUseMyLocationButton(session: session, appState: appState)
          }
          .padding(.top, 8)
        } label: {
          HStack(spacing: 8) {
            SettingCardLabel(
              L10n.Settings.Radio.presetLocation,
              systemImage: "location.fill",
              color: .green,
              subtitle: rowDetail
            )
            InfoButton(L10n.Settings.Radio.PresetLocation.footer, title: L10n.Settings.Radio.presetLocation)
            Spacer(minLength: 0)
          }
        }
      }
    }
    .onAppear {
      // Decided once per visit, so the group doesn't snap shut mid-edit as the selection completes.
      guard !hasSetInitialExpansion else { return }
      hasSetInitialExpansion = true
      isExpanded = PresetLocationPolicy.startsExpandedOnRadio(
        authorized: appState.locationService.isAuthorized,
        selection: selection
      )
    }
  }
}

@MainActor
func presetLocationUseMyLocationButton(
  session: PresetLocationSession,
  appState: AppState
) -> some View {
  Button {
    session.useMyLocation(from: appState)
  } label: {
    if session.isResolving {
      HStack {
        ProgressView()
        Text(L10n.Settings.Radio.PresetLocation.UseMyLocation.locating)
      }
    } else {
      Text(L10n.Onboarding.Region.useMyLocation)
    }
  }
  .disabled(session.isResolving)
  .accessibilityLabel(L10n.Onboarding.Region.useMyLocation)
  .accessibilityValue(
    session.isResolving ? L10n.Settings.Radio.PresetLocation.UseMyLocation.locating : ""
  )
}
