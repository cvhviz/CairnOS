import SwiftUI

/// The empty state of a screen that needs a radio: says so, and offers the way out. Without the
/// button the only route to connecting is the status icon in the toolbar, which nothing here
/// points to.
struct RadioNotConnectedView: View {
  @Environment(\.appState) private var appState
  @State private var showingDeviceSelection = false

  var title = L10n.Tools.Tools.RxLog.notConnected
  var systemImage = "antenna.radiowaves.left.and.right.slash"
  let description: String

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(description)
    } actions: {
      Button(L10n.Settings.Device.connect, systemImage: "antenna.radiowaves.left.and.right") {
        showingDeviceSelection = true
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("radio.connect")
    }
    .sheet(isPresented: $showingDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
  }
}
