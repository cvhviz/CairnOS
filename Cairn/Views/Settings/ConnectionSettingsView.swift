import CairnServices
import SwiftUI

/// Settings → Connection: the hub for the link to the radio. Which radio and how it's connected
/// up top, then Connections (every saved radio, for switching), rebooting, or disconnecting it, the
/// transport's own settings
/// (Bluetooth PIN or WiFi address), the radio's key (import or regenerate), and forgetting or
/// factory resetting the radio last.
struct ConnectionSettingsView: View {
  @Environment(\.appState) private var appState
  @State private var showingWiFiEditSheet = false
  @State private var confirmsDisconnect = false

  private var isWiFi: Bool {
    appState.connectionManager.currentTransportType == .wifi
  }

  var body: some View {
    CardForm {
      if let device = appState.connectedDevice {
        // Which radio and its link state, then what can be done with it. The transport is not
        // repeated as a tile: the WiFi or Bluetooth section below is headed with it.
        CardFormSection(L10n.Settings.Device.header) {
          MetricTileGrid {
            MetricTile(
              L10n.Settings.Node.name,
              systemImage: "cpu",
              value: device.nodeName,
              caption: device.manufacturerName.isEmpty
                ? L10n.Settings.DeviceInfo.defaultManufacturer
                : device.manufacturerName
            )
            MetricTile(
              L10n.Settings.DeviceInfo.Connection.status,
              systemImage: statusSymbol(device),
              value: statusTitle
            )
          }

          // Switching radios is Connections' job. Hidden when this page was opened from there,
          // where Back already returns to it.
          if !isOpenedFromConnections {
            NavigationLink(value: SettingsDetail.connections) {
              NavigationTile(
                L10n.Settings.Connections.title,
                systemImage: "flipphone",
                color: .blue,
                detail: L10n.Settings.Connections.linkDetail
              )
            }
            .buttonStyle(.plain)
          }

          RebootDeviceButton()

          // Asks first, as Device Info's Disconnect does: the radio stops syncing until reconnected.
          ActionCard(L10n.Settings.BleStatus.disconnect, systemImage: "eject", role: .destructive) {
            confirmsDisconnect = true
          }
          .confirmationDialog(
            L10n.Settings.DeviceInfo.DisconnectConfirm.title(device.nodeName),
            isPresented: $confirmsDisconnect,
            titleVisibility: .visible
          ) {
            Button(L10n.Settings.BleStatus.disconnect, role: .destructive) {
              Task { await appState.disconnect(reason: .userInitiated) }
            }
            .accessibilityIdentifier("connection.disconnect.confirm")
          } message: {
            Text(L10n.Settings.DeviceInfo.DisconnectConfirm.message)
          }
        }

        if isWiFi {
          WiFiSection(showingEditSheet: $showingWiFiEditSheet)
        } else {
          BluetoothSection()
        }

        // The radio's key, before the reset section: replacing it is serious but not a reset.
        IdentityKeySection()

        DeviceResetSection()
      } else {
        ContentUnavailableView(
          L10n.Settings.DeviceInfo.NoDevice.title,
          systemImage: "antenna.radiowaves.left.and.right.slash",
          description: Text(L10n.Settings.DeviceInfo.NoDevice.description)
        )
        .emptyStateFrame(below: CardStyle.formVerticalInset * 2)
      }
    }
    .flashingNavigationTitle(L10n.Settings.DeviceInfo.Connection.header)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showingWiFiEditSheet) {
      WiFiEditSheet()
    }
  }

  private var isOpenedFromConnections: Bool {
    appState.navigation.settingsPath.contains(.connections)
  }

  private var statusTitle: String {
    switch appState.connectionState {
    case .disconnected: L10n.Settings.BleStatus.Status.disconnected
    case .connecting: L10n.Settings.BleStatus.Status.connecting
    case .connected: L10n.Settings.BleStatus.Status.connected
    case .syncing: L10n.Settings.BleStatus.Status.syncing
    case .ready: L10n.Settings.BleStatus.Status.ready
    }
  }

  /// A different glyph per state, so the state does not rest on color.
  private func statusSymbol(_ device: DeviceDTO) -> String {
    switch appState.connectionState {
    case .disconnected: "antenna.radiowaves.left.and.right.slash"
    case .connecting, .connected: "arrow.triangle.2.circlepath"
    case .syncing: "arrow.down.circle"
    case .ready: device.clientRepeat ? "repeat" : "checkmark.circle.fill"
    }
  }
}
