import SwiftUI

/// Device Info as a sheet, opened on an iPad by the radio's title on each section's bar
/// (`DeviceInfoButton`; a phone opens it in Settings' sheet): the same page as Settings › Device Info, over whatever page the
/// button was tapped on, with Back to come straight back. Its own stack, so it never touches
/// Settings' path or whether Settings shows. Back leads the bar, as a pushed page's would, and
/// the page's own Disconnect trails it. With no radio linked the page shows its "No Device
/// Connected" state, which
/// offers Connections too. Connections is handed to Settings rather than pushed in this stack: it
/// adds radios through pickers and alerts the app's root presents (the Mac's Bluetooth picker, the
/// pairing setup), which can't show over this sheet, and on Settings' stack they do.
struct DeviceInfoSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// The firmware card's Firmware Update: the presenter closes the sheet and opens it in Settings.
  let onOpenFirmwareUpdate: () -> Void
  /// The toolbar's Connections (or the disconnected page's): the presenter closes the sheet and
  /// opens it in Settings, as for Firmware Update.
  let onOpenConnections: () -> Void
  /// A Radio Settings row: the presenter closes the sheet and opens that page in Settings.
  let onOpenSetting: (SettingsDetail) -> Void

  var body: some View {
    NavigationStack {
      DeviceInfoView(
        onOpenFirmwareUpdate: onOpenFirmwareUpdate,
        onOpenConnections: onOpenConnections,
        onOpenSetting: onOpenSetting
      )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            NodePageBackButton { dismiss() }
              .accessibilityIdentifier("deviceInfoSheet.done")
          }
        }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }
}

#Preview {
  Text("Content")
    .sheet(isPresented: .constant(true)) {
      DeviceInfoSheet(onOpenFirmwareUpdate: {}, onOpenConnections: {}, onOpenSetting: { _ in })
    }
    .environment(\.appState, AppState())
}
