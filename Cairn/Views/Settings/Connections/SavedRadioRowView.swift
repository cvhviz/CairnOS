import CairnServices
import SwiftUI

/// What a radio's row and page say about it: its state, transports and the default tag.
enum SavedRadioPresentation {
  /// "Ready · Bluetooth · Default", "Bluetooth · WiFi · Last connected yesterday".
  static func statusText(
    _ row: SavedRadioRow,
    status: SavedRadioStatus,
    activeTransport: TransportType?
  ) -> String {
    let defaultTag = row.isDefault ? L10n.Settings.Connections.Row.defaultRadio : nil
    let transports = transportsText(row)
    switch status {
    case let .connected(linkState):
      return NodeRouteFormat.joined([HomeStatusLines.linkTitle(linkState), activeTransport?.displayName ?? transports, defaultTag])
    case .connecting:
      return NodeRouteFormat.joined([L10n.Settings.BleStatus.Status.connecting, transports])
    case .connectedElsewhere:
      return L10n.Settings.DeviceSelection.connectedElsewhere
    case let .outOfRange(lastConnected):
      return NodeRouteFormat.joined([L10n.Settings.Connections.Row.notInRange, lastConnectedText(lastConnected), defaultTag])
    case let .available(lastConnected):
      return NodeRouteFormat.joined([transports, lastConnectedText(lastConnected), defaultTag])
    }
  }

  /// "Bluetooth · WiFi": every way this phone has reached the radio.
  static func transportsText(_ row: SavedRadioRow) -> String {
    row.transports.isEmpty
      ? L10n.Settings.DeviceSelection.bluetooth
      : NodeRouteFormat.joined(row.transports.map(\.displayName))
  }

  static func lastConnectedText(_ date: Date) -> String {
    L10n.Settings.Connections.Row.lastConnected(date.formatted(.relative(presentation: .named)))
  }

  static func tint(_ status: SavedRadioStatus) -> Color {
    if case .connected(.ready) = status { return AppColors.Radio.readyText }
    return .secondary
  }

  /// The row's tile: the link's ready green once in use, else the picker's transport colours, and
  /// a glyph for a radio reachable both ways.
  static func tile(_ row: SavedRadioRow, status: SavedRadioStatus) -> (symbol: String, color: Color) {
    let symbol = row.transports.count > 1
      ? "point.3.connected.trianglepath.dotted"
      : (row.transports.first ?? .bluetooth).symbol
    if case .connected(.ready) = status { return (symbol, AppColors.Radio.ready) }
    return (symbol, row.transports == [.wifi] ? .blue : .green)
  }
}

/// One radio in the Radios list: a compact card row (`cardListRow`) with its tile, name and a line
/// of state, the signal, and on a phone a chevron that opens its page. Rows stay one or two lines
/// so a long list scrolls like the Nodes list.
struct SavedRadioRowView: View {
  let row: SavedRadioRow
  let status: SavedRadioStatus
  let activeTransport: TransportType?
  let signalTier: RSSITuning.SignalTier?
  /// Opens the radio's page; nil where a tap on the row already does (the iPad and Mac list).
  var onOpenDetail: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      let tile = SavedRadioPresentation.tile(row, status: status)
      IconTile(systemImage: tile.symbol, color: tile.color)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(row.displayName)
          .font(.body.weight(.semibold))
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        statusLine
      }

      Spacer(minLength: 8)

      if status == .connecting {
        ProgressView()
      } else if let signalTier {
        SignalBars(tier: signalTier)
      }

      if let onOpenDetail {
        Button(action: onOpenDetail) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(.tertiaryLabel))
            .frame(width: 32, height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.Settings.Connections.Accessibility.details(row.displayName))
      }
    }
    // As in the picker: a radio that can't be reached now reads as such, not by colour alone.
    .opacity(status.isDimmed ? 0.4 : 1)
    .contentShape(.rect)
  }

  @ViewBuilder
  private var statusLine: some View {
    if status == .connectedElsewhere {
      Label(L10n.Settings.DeviceSelection.connectedElsewhere, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .lineLimit(1)
    } else {
      Text(SavedRadioPresentation.statusText(row, status: status, activeTransport: activeTransport))
        .font(.caption)
        .foregroundStyle(SavedRadioPresentation.tint(status))
        .lineLimit(1)
    }
  }

  /// The row read as one element: the name, then its state and signal.
  var accessibilityValue: String {
    NodeRouteFormat.joined([
      SavedRadioPresentation.statusText(row, status: status, activeTransport: activeTransport),
      row.advertisedName,
      signalTier.map { SignalBars.accessibilityDescription(forTier: $0) },
    ])
  }
}

/// The actions on a radio, for its context menu, swipe actions' long press and VoiceOver.
struct SavedRadioMenuItems: View {
  @Environment(\.appState) private var appState
  let model: ConnectionsModel
  let row: SavedRadioRow

  var body: some View {
    ForEach(row.methods) { method in
      let title = connectTitle(method)
      if let title, model.canConnect(row, via: method) {
        Button(title, systemImage: method.transportType.symbol) {
          model.connect(row, via: method, appState: appState)
        }
      }
    }
    if row.isConnected {
      Button(L10n.Settings.DeviceInfo.title, systemImage: "info.circle") {
        appState.navigation.settingsPath.append(.deviceInfo)
      }
      Button(L10n.Settings.BleStatus.disconnect, systemImage: "eject", role: .destructive) {
        model.disconnect(appState)
      }
    }
    Divider()
    Button(L10n.Settings.Connections.Action.rename, systemImage: "pencil") {
      model.beginRename(row)
    }
    // One address: change it here; several: each has its own menu on the radio's page.
    let wifiMethods = row.methods.filter(\.isWiFi)
    if wifiMethods.count == 1, let wifi = wifiMethods.first {
      Button(L10n.Settings.Connections.Action.editAddress, systemImage: "network") {
        model.editWiFiAddress(row, wifi)
      }
    }
    Button(L10n.Settings.Connections.Action.addAddress, systemImage: "network.badge.shield.half.filled") {
      model.addWiFiAddress(row)
    }
    Divider()
    Button(L10n.Settings.Connections.Action.forget, systemImage: "trash", role: .destructive) {
      model.forgetting = row
    }
  }

  /// "Connect over WiFi", "Switch to Bluetooth" (this radio, the other way), or nil for the link
  /// already up.
  private func connectTitle(_ method: ConnectionMethod) -> String? {
    if row.isConnected {
      guard appState.connectionManager.currentTransportType != method.transportType else { return nil }
      return L10n.Settings.Connections.Action.switchOver(method.transportType.displayName)
    }
    if row.methods.count == 1 {
      return appState.connectedDevice == nil
        ? L10n.Settings.Connections.Action.connect
        : L10n.Settings.Connections.Action.switchTo
    }
    return L10n.Settings.Connections.Action.connectOver(method.transportType.displayName)
  }
}
