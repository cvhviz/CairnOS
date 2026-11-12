import CairnServices
import SwiftUI

/// Regions as cards: the default flood scope the radio applies to flood sends (firmware v11+),
/// picked in place, and the known regions, which open Manage Regions. Channels choose their own
/// scope from the same list in their info sheet. Settings → Radio shows it as its Default Scope
/// sheet without the known-regions tile, since the page's Regions control opens Manage Regions;
/// there the scope menu ends in Manage Regions, and with no regions yet the tile shows anyway, so
/// the sheet always has a way to add the region it's asking for.
struct RegionsCardSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  /// Whether to show the known-regions tile that opens Manage Regions.
  var showsKnownRegions = true
  /// Runs when the retry alert gives up, in place of dismissing this view.
  var onGiveUp: (() -> Void)?
  /// Reports a write in flight or its alert showing, so a hosting sheet can hold itself open
  /// until the outcome has been seen.
  var onBusyChange: ((Bool) -> Void)?
  @State private var isApplying = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var showingManageRegions = false

  private var supportsDefaultScope: Bool {
    appState.connectedDevice?.supportsDefaultFloodScope == true
  }

  private var currentScope: String? {
    appState.connectedDevice?.defaultFloodScopeName
  }

  private var sortedKnownRegions: [String] {
    Self.sortedKnownRegions(appState.connectedDevice)
  }

  /// What regions are for, plus the default scope when this radio has that tile.
  private var infoMessage: String {
    supportsDefaultScope
      ? L10n.Settings.Regions.footer + "\n\n" + L10n.Settings.DefaultFloodScope.footer
      : L10n.Settings.Regions.footer
  }

  var body: some View {
    // Hosted as the Radio page's Default Scope sheet, it's named for the one setting it holds.
    CardFormSection(
      showsKnownRegions ? L10n.Chats.Chats.ChannelInfo.Region.manage : L10n.Settings.Regions.defaultScope,
      info: infoMessage
    ) {
      MetricTileGrid {
        if supportsDefaultScope {
          defaultScopeTile
        }
        if showsKnownRegions || sortedKnownRegions.isEmpty {
          knownRegionsTile
        }
      }
    }
    // Pushed by the scope menu's Manage Regions: a NavigationLink inside a Menu doesn't push.
    .navigationDestination(isPresented: $showingManageRegions) {
      RegionManagementView()
    }
    .onChange(of: isBusy) { _, busy in
      onBusyChange?(busy)
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  private var isBusy: Bool {
    isApplying || errorMessage != nil || retryAlert.isPresented
  }

  // MARK: - Tiles

  private var defaultScopeTile: some View {
    Menu {
      Picker(L10n.Settings.Regions.defaultScope, selection: Binding(
        get: { currentScope },
        set: { name in
          guard name != currentScope else { return }
          apply(name: name)
        }
      )) {
        Text(L10n.Settings.DefaultFloodScope.disabled).tag(String?.none)
        ForEach(sortedKnownRegions, id: \.self) { region in
          Text(region).tag(String?.some(region))
        }
      }

      if !showsKnownRegions {
        Divider()
        Button(L10n.Chats.Chats.ChannelInfo.Region.manageRegions, systemImage: "list.bullet") {
          showingManageRegions = true
        }
      }
    } label: {
      RadioSettingTile(
        L10n.Settings.Regions.defaultScope,
        systemImage: "dot.radiowaves.left.and.right",
        value: currentScope ?? L10n.Settings.DefaultFloodScope.disabled,
        editStyle: .menu
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState, or: isApplying)
  }

  private var knownRegionsTile: some View {
    NavigationLink {
      RegionManagementView()
    } label: {
      RadioSettingTile(
        L10n.Settings.Regions.known,
        systemImage: "globe",
        value: sortedKnownRegions.count.formatted(),
        captions: [Self.knownRegionsSummary(appState.connectedDevice)],
        editStyle: .sheet,
        accessibilityHint: L10n.Chats.Chats.ChannelInfo.Region.manageRegions
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Actions

  private func apply(name: String?) {
    isApplying = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }
        _ = try await settingsService.setDefaultFloodScopeVerified(name: name)
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { apply(name: name) },
          onMaxRetriesExceeded: { onGiveUp?() ?? dismiss() }
        )
      } catch {
        errorMessage = error.userFacingMessage
      }
      isApplying = false
    }
  }
}

@MainActor
extension RegionsCardSection {
  /// The radio's known regions in name order.
  static func sortedKnownRegions(_ device: DeviceDTO?) -> [String] {
    (device?.knownRegions ?? [])
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// "Bay, East and North", or "No regions": the known-regions line for the tile and the Radio
  /// page's Default Scope card.
  static func knownRegionsSummary(_ device: DeviceDTO?) -> String {
    let regions = sortedKnownRegions(device)
    return regions.isEmpty
      ? L10n.Chats.Chats.ChannelInfo.Region.noRegions
      : regions.formatted(.list(type: .and, width: .narrow))
  }

  /// Re-read when the radio or its sync state changes, so the default scope shows what the radio
  /// holds. The page runs the read, so it happens on arrival rather than when the sheet opens.
  static func refreshTaskID(_ appState: AppState) -> String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    let syncPhase = appState.connectionUI.currentSyncPhase.map { String(describing: $0) } ?? "none"
    return "\(deviceID)-\(String(describing: appState.connectionState))-\(syncPhase)"
  }

  /// The default scope lives on the radio; read it so the card isn't showing a stale cache.
  static func refreshDefaultScope(_ appState: AppState) async {
    // Wait until contact/channel sync contention is over before sending startup reads.
    guard appState.connectedDevice?.supportsDefaultFloodScope == true,
          appState.canRunSettingsStartupReads,
          let settingsService = appState.services?.settingsService else { return }
    _ = try? await settingsService.getDefaultFloodScope()
  }
}
