import CairnServices
import SwiftUI

/// WiFi connection settings - shown when connected via WiFi instead of Bluetooth.
struct WiFiSection: View {
  @Environment(\.appState) private var appState
  @Binding var showingEditSheet: Bool

  private var currentConnection: ConnectionMethod? {
    appState.connectedDevice?.connectionMethods.first { $0.isWiFi }
  }

  var body: some View {
    CardFormSection(L10n.Settings.Wifi.header, info: L10n.Settings.Wifi.footer) {
      if case let .wifi(host, port, _) = currentConnection {
        ValueCard(L10n.Settings.Wifi.address, systemImage: "network", color: .blue, value: host)
        ValueCard(L10n.Settings.Wifi.port, systemImage: "number", color: .gray, value: "\(port)")
      }

      ActionCard(L10n.Settings.Wifi.editConnection, systemImage: "pencil", color: .blue) {
        showingEditSheet = true
      }
    }
  }
}

#Preview {
  @Previewable @State var showingEditSheet = false
  CardForm {
    WiFiSection(showingEditSheet: $showingEditSheet)
  }
  .environment(\.appState, AppState())
}
