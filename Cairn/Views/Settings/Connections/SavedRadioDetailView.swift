import CairnServices
import SwiftUI

/// One saved radio: its name, a card per transport with its own Connect, what the phone knows
/// about it, and the actions. The detail pane beside the list on iPad and Mac, and the page a
/// row's chevron pushes on iPhone.
struct SavedRadioDetailView: View {
  @Environment(\.appState) private var appState
  let model: ConnectionsModel
  let profiles: RadioProfilesModel
  let rowID: String
  /// In the iPad/Mac pane the Connections page keeps its own title.
  var isEmbedded = false
  @State private var confirmsDisconnect = false

  var body: some View {
    Group {
      if let row = model.row(id: rowID) {
        content(row)
      } else {
        // Forgotten from under the page.
        ContentUnavailableView(
          L10n.Settings.Connections.Detail.noSelection,
          systemImage: "antenna.radiowaves.left.and.right"
        )
      }
    }
    .flashingNavigationTitle(isEmbedded ? L10n.Settings.Connections.title : (model.row(id: rowID)?.displayName ?? ""))
    .navigationBarTitleDisplayMode(.inline)
  }

  private func content(_ row: SavedRadioRow) -> some View {
    let status = model.status(for: row, appState: appState)
    return CardForm {
      header(row, status: status)

      CardFormSection(L10n.Settings.Connections.Detail.transports) {
        ForEach(row.methods) { method in
          transportCard(row, method: method)
        }
      }

      CardFormSection {
        MetricTileGrid {
          MetricTile(
            L10n.Settings.Connections.Detail.lastConnected,
            systemImage: "clock",
            value: row.isConnected
              ? HomeStatusLines.linkTitle(appState.connectionState)
              : row.device.lastConnected.formatted(.relative(presentation: .named))
          )
          MetricTile(
            L10n.Settings.Connections.Detail.key,
            systemImage: "key",
            value: row.keyPrefix
          )
          if let tier = model.signalTier(row) {
            MetricTile(
              L10n.Settings.Connections.Detail.signal,
              systemImage: "cellularbars",
              value: SignalBars.accessibilityDescription(forTier: tier),
              caption: model.rssi(row).map { "\($0) dBm" }
            )
          }
        }
      }

      if row.isConnected {
        connectedSection
      }

      if row.isConnected, !profiles.profiles.isEmpty, appState.isRadioReady {
        CardFormSection(L10n.Settings.Connections.Detail.applyProfile) {
          ForEach(profiles.profiles) { profile in
            NavigationLink {
              NodeConfigImportView(preloadedConfig: profile.config, title: L10n.Settings.Connections.Profile.applyTitle)
            } label: {
              NavigationTile(
                profile.name,
                systemImage: "slider.horizontal.below.rectangle",
                color: .purple,
                detail: RadioProfileSummary.line(profile.config)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      CardFormSection {
        ActionCard(L10n.Settings.Connections.Action.rename, systemImage: "pencil", color: .orange) {
          model.beginRename(row)
        }
        // A radio can be reached at several addresses (its LAN address and a VPN one, say): each
        // is a card above with its own Connect, and this adds one. A card's menu changes or removes it.
        ActionCard(L10n.Settings.Connections.Action.addAddress, systemImage: "network.badge.shield.half.filled", color: .blue) {
          model.addWiFiAddress(row)
        }
        ActionCard(L10n.Settings.Connections.Action.forget, systemImage: "trash", role: .destructive) {
          model.forgetting = row
        }
      }
    }
  }

  /// The radio's name as Radio Settings heads its page, the radio's own name under a nickname,
  /// and its state.
  private func header(_ row: SavedRadioRow, status: SavedRadioStatus) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        let tile = SavedRadioPresentation.tile(row, status: status)
        IconTile(systemImage: tile.symbol, color: tile.color)
          .accessibilityHidden(true)
        Text(row.displayName)
          .font(.title3.weight(.bold))
          .lineLimit(2)
      }
      if let advertisedName = row.advertisedName {
        Text(advertisedName)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Text(SavedRadioPresentation.statusText(row, status: status, activeTransport: activeTransport(row)))
        .font(.footnote)
        .foregroundStyle(SavedRadioPresentation.tint(status))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  /// One transport: what it is (the WiFi address, or whether Bluetooth hears the radio) and its
  /// own Connect, Switch, or the mark of the link in use.
  private func transportCard(_ row: SavedRadioRow, method: ConnectionMethod) -> some View {
    let transport = method.transportType
    let isActive = row.isConnected && appState.connectionManager.currentTransportType == transport
    let detail: String = switch method {
    case .wifi: method.shortDescription
    case .bluetooth:
      model.isHeard(row) || isActive
        ? (model.signalTier(row).map { SignalBars.accessibilityDescription(forTier: $0) } ?? transport.displayName)
        : L10n.Settings.Connections.Row.notInRange
    }
    return HStack(spacing: 8) {
      SettingCardLabel(
        transport.displayName,
        systemImage: transport.symbol,
        color: transport == .wifi ? .blue : .green,
        subtitle: detail
      )
      Spacer(minLength: 8)
      if isActive {
        Label(HomeStatusLines.linkTitle(appState.connectionState), systemImage: "checkmark.circle.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(AppColors.Radio.ready)
          .accessibilityLabel(HomeStatusLines.linkTitle(appState.connectionState))
      } else if model.connectingRowID == row.id {
        ProgressView()
      } else {
        Button(row.isConnected || appState.connectedDevice != nil
          ? L10n.Settings.Connections.Action.switchShort
          : L10n.Settings.Connections.Action.connect) {
          model.connect(row, via: method, appState: appState)
        }
        .liquidGlassSecondaryButtonStyle()
        .disabled(!model.canConnect(row, via: method))
        .accessibilityHint(L10n.Settings.Connections.Action.connectOver(transport.displayName))
      }
      if transport == .wifi {
        Menu {
          Button(L10n.Settings.Connections.Action.editAddress, systemImage: "pencil") {
            model.editWiFiAddress(row, method)
          }
          // the last way in stays: a record with no address or peripheral could never connect
          if row.methods.count > 1 {
            Button(L10n.Settings.Connections.Action.removeAddress, systemImage: "trash", role: .destructive) {
              model.removeWiFiAddress(row, method, appState: appState)
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .imageScale(.large)
            .foregroundStyle(.secondary)
            .frame(minWidth: 32, minHeight: 32)
        }
        .accessibilityLabel(L10n.Settings.Connections.Action.addressOptions)
      }
    }
    .cardSurface(padding: 12)
  }

  private var connectedSection: some View {
    CardFormSection {
      NavigationLink(value: SettingsDetail.deviceInfo) {
        NavigationTile(L10n.Settings.DeviceInfo.title, systemImage: "info.circle", color: .blue)
      }
      .buttonStyle(.plain)
      NavigationLink(value: SettingsDetail.connection) {
        NavigationTile(L10n.Settings.BleStatus.connectionSettings, systemImage: "link", color: .blue)
      }
      .buttonStyle(.plain)
      // Asks first, as Device Info's Disconnect does: the radio stops syncing until reconnected.
      ActionCard(L10n.Settings.BleStatus.disconnect, systemImage: "eject", role: .destructive) {
        confirmsDisconnect = true
      }
      .confirmationDialog(
        L10n.Settings.DeviceInfo.DisconnectConfirm.title(appState.connectedDevice?.nodeName ?? ""),
        isPresented: $confirmsDisconnect,
        titleVisibility: .visible
      ) {
        Button(L10n.Settings.BleStatus.disconnect, role: .destructive) {
          model.disconnect(appState)
        }
        .accessibilityIdentifier("connections.disconnect.confirm")
      } message: {
        Text(L10n.Settings.DeviceInfo.DisconnectConfirm.message)
      }
    }
  }

  private func activeTransport(_ row: SavedRadioRow) -> TransportType? {
    row.isConnected ? appState.connectionManager.currentTransportType : nil
  }
}
