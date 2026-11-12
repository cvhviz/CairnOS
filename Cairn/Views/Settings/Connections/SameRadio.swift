import CairnServices
import SwiftUI

/// A radio is its public key, whatever carries it: a Bluetooth record is keyed by the peripheral
/// and a WiFi one by a UUID derived from the key, so the same radio reached both ways is found by
/// comparing keys (`SavedRadioLink` in the services does the same after a handshake).
enum SavedRadioConnectPlan: Equatable {
  /// Another radio, or none connected: connect (switching radios as before).
  case connect
  /// This radio over this transport is the link already up: nothing to do.
  case alreadyConnected
  /// This radio is connected over the other transport: ask before moving it.
  case switchTransport(from: TransportType, to: TransportType)

  static func plan(
    targetKey: Data?,
    targetTransport: TransportType,
    connectedKey: Data?,
    connectedTransport: TransportType?
  ) -> SavedRadioConnectPlan {
    guard let targetKey, !targetKey.isEmpty, let connectedKey, targetKey == connectedKey,
          let connectedTransport else { return .connect }
    return connectedTransport == targetTransport
      ? .alreadyConnected
      : .switchTransport(from: connectedTransport, to: targetTransport)
  }
}

extension TransportType {
  /// "Bluetooth" or "WiFi", as Home's status lines name the link.
  var displayName: String {
    HomeStatusLines.transportName(isWiFi: self == .wifi)
  }

  var symbol: String {
    switch self {
    case .bluetooth: "antenna.radiowaves.left.and.right"
    case .wifi: "wifi"
    }
  }
}

/// The question asked before moving a connected radio to its other transport.
struct TransportSwitchPrompt: Identifiable {
  let id = UUID()
  let device: DeviceDTO
  let method: ConnectionMethod?
  let radioName: String
  let from: TransportType
  let to: TransportType
}

extension View {
  /// "Basecamp is already connected over Bluetooth. Switch to WiFi?" with Switch and Cancel.
  /// Switch reconnects over the new transport; the manager tears the old link down first.
  func transportSwitchAlert(
    _ prompt: Binding<TransportSwitchPrompt?>,
    onSwitch: @escaping (TransportSwitchPrompt) -> Void
  ) -> some View {
    alert(
      L10n.Settings.Connections.SameRadio.title,
      isPresented: Binding(get: { prompt.wrappedValue != nil }, set: { if !$0 { prompt.wrappedValue = nil } }),
      presenting: prompt.wrappedValue
    ) { request in
      Button(L10n.Settings.Connections.SameRadio.switchButton(request.to.displayName)) {
        onSwitch(request)
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: { request in
      Text(L10n.Settings.Connections.SameRadio.message(request.radioName, request.from.displayName, request.to.displayName))
    }
  }
}
