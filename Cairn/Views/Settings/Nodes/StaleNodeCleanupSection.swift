import CairnServices
import SwiftUI

/// Settings → Nodes → Auto-Remove Old Nodes: the app removes non-favorite nodes not modified
/// within the chosen number of days, checked on connection.
struct StaleNodeCleanupSection: View {
  @Environment(\.appState) private var appState
  @AppStorage(AppStorageKey.autoDeleteStaleNodesDays.rawValue)
  private var threshold: Int = AppStorageKey.defaultAutoDeleteStaleNodesDays
  @AppStorage(AppStorageKey.lastStaleCleanupDate.rawValue)
  private var lastCleanupTimestamp: Double = AppStorageKey.defaultLastStaleCleanupDate

  @State private var isEnabled = false

  var body: some View {
    // An app-side preference, so it stays editable without a radio; the cleanup itself waits for
    // a ready connection (see `onChange(of: threshold)` and the disconnected footer).
    CardFormSection(
      L10n.Settings.Nodes.StaleCleanup.header,
      info: L10n.Settings.Nodes.StaleCleanup.footerDisabled,
      footer: statusFooter
    ) {
      ToggleCard(
        L10n.Settings.Nodes.StaleCleanup.toggle,
        systemImage: "clock.arrow.circlepath",
        color: .orange,
        isOn: $isEnabled
      )

      if isEnabled {
        PickerCard(
          L10n.Settings.Nodes.StaleCleanup.threshold,
          systemImage: "calendar",
          color: .orange,
          subtitle: lastRunText,
          selection: $threshold
        ) {
          Text(L10n.Settings.Nodes.StaleCleanup.select).tag(0)
          Text(L10n.Settings.Nodes.StaleCleanup.days(7)).tag(7)
          Text(L10n.Settings.Nodes.StaleCleanup.days(14)).tag(14)
          Text(L10n.Settings.Nodes.StaleCleanup.days(30)).tag(30)
          Text(L10n.Settings.Nodes.StaleCleanup.days(90)).tag(90)
        }
      }
    }
    .onAppear {
      isEnabled = threshold > 0
    }
    .onChange(of: isEnabled) { _, newValue in
      if !newValue {
        threshold = 0
      }
    }
    .onChange(of: threshold) { _, newThreshold in
      guard newThreshold > 0, appState.connectionState == .ready else { return }
      appState.performStaleNodeCleanup(force: true)
    }
  }

  /// When the last automatic check ran, once a threshold is chosen.
  private var lastRunText: String? {
    guard lastCleanupTimestamp > 0, threshold > 0 else { return nil }
    return L10n.Settings.Nodes.StaleCleanup.lastRun(
      Date(timeIntervalSinceReferenceDate: lastCleanupTimestamp)
        .formatted(.relative(presentation: .named))
    )
  }

  /// Only the state of an enabled cleanup; what it does is behind the "i".
  private var statusFooter: String? {
    guard isEnabled else { return nil }
    if threshold == 0 {
      return L10n.Settings.Nodes.StaleCleanup.footerSelect
    } else if appState.connectionState == .ready {
      return L10n.Settings.Nodes.StaleCleanup.footerEnabled(threshold)
    } else {
      return L10n.Settings.Nodes.StaleCleanup.footerDisconnected
    }
  }
}

#Preview {
  CardForm {
    StaleNodeCleanupSection()
  }
}
