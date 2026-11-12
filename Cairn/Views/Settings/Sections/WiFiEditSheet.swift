import CairnServices
import SwiftUI

/// The WiFi address sheet. Without `editing` it changes the live link's address (Settings ›
/// Connection), which drops the link and connects to the new address. With it, it adds or changes
/// one of a saved radio's addresses (Connections): the address is saved on this phone and the
/// radio's page connects to it, unless that address is the live link, which reconnects as above.
struct WiFiEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState

  /// A saved radio's address being added (no method) or changed; nil edits the live link.
  var editing: WiFiAddressEdit?

  init(editing: WiFiAddressEdit? = nil) {
    self.editing = editing
  }

  @State private var ipAddress = ""
  @State private var port = "5000"
  @State private var errorMessage: String?
  @State private var confirmingSave = false
  @State private var isProcessing = false
  /// Whether this sheet holds the radio's pages while the link is down on purpose.
  @State private var holdsDevicePages = false

  @FocusState private var focusedField: WiFiField?

  /// The address the live link is on: the one the transport connected to, which the record keeps first.
  private var currentConnection: ConnectionMethod? {
    appState.connectedDevice?.connectionMethods.first { $0.isWiFi }
  }

  /// The address being changed: the saved one, else the live link's.
  private var originalMethod: ConnectionMethod? {
    if let editing { return editing.method }
    return currentConnection
  }

  /// Whether saving changes the link in use (which drops it and reconnects): the live link's own
  /// sheet, or a saved address that is the live link.
  private var editsLiveLink: Bool {
    guard let editing else { return true }
    guard let method = editing.method, let current = currentConnection else { return false }
    return method == current && appState.connectedDevice?.id == editing.device.id
  }

  private var originalHost: String? {
    if case let .wifi(host, _, _) = originalMethod { return host }
    return nil
  }

  private var originalPort: UInt16? {
    if case let .wifi(_, port, _) = originalMethod { return port }
    return nil
  }

  private var title: String {
    guard let editing else { return L10n.Settings.WifiEdit.title }
    return editing.method == nil ? L10n.Settings.WifiEdit.addTitle : L10n.Settings.WifiEdit.editTitle
  }

  private var isValidInput: Bool {
    WiFiAddressFields.isValidHost(ipAddress) && WiFiAddressFields.isValidPort(port)
  }

  private var hasChanges: Bool {
    guard let host = originalHost, let currentPort = originalPort else { return true }
    return WiFiAddressFields.normalizedHost(ipAddress) != host || port != String(currentPort)
  }

  var body: some View {
    NavigationStack {
      CardForm {
        WiFiAddressFields(
          ipAddress: $ipAddress,
          port: $port,
          focusedField: $focusedField,
          sectionHeader: L10n.Settings.WifiEdit.connectionDetails,
          // Stays visible: saving the live link's address drops the current connection.
          sectionFooter: editsLiveLink ? L10n.Settings.WifiEdit.footer : L10n.Settings.WifiEdit.savedFooter,
          onPortSubmit: { saveChanges() }
        )

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }

        ActionCard(
          isProcessing
            ? (editsLiveLink ? L10n.Settings.WifiEdit.connecting : L10n.Settings.WifiEdit.saving)
            : (editsLiveLink ? L10n.Settings.WifiEdit.saveChanges : L10n.Settings.WifiEdit.saveAddress),
          systemImage: "wifi",
          color: .blue
        ) {
          saveChanges()
        }
        .overlay(alignment: .trailing) {
          if isProcessing {
            ProgressView()
              .padding(.trailing, 12)
          }
        }
        .dimmedWhenDisabled()
        .disabled(!isValidInput || !hasChanges || isProcessing)
      }
      .flashingNavigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .wifiSheetToolbar(focusedField: $focusedField, isProcessing: isProcessing)
      .interactiveDismissDisabled(isProcessing)
      // One line naming where the app will connect, since Save drops the current link.
      .confirmationDialog(
        L10n.Settings.WifiEdit.Confirm.title(pendingAddress),
        isPresented: $confirmingSave,
        titleVisibility: .visible
      ) {
        Button(L10n.Settings.WifiEdit.Confirm.connect) {
          reconnect()
        }
        .accessibilityIdentifier("wifiEdit.confirm")
      } message: {
        Text(L10n.Settings.WifiEdit.Confirm.message)
      }
      .onAppear {
        populateCurrentValues()
      }
      .onDisappear {
        releaseDevicePagesIfHeld()
      }
    }
    .presentationSizing(.page)
  }

  /// "host:port" as the confirmation names it.
  private var pendingAddress: String {
    "\(WiFiAddressFields.normalizedHost(ipAddress)):\(port)"
  }

  private func populateCurrentValues() {
    if let host = originalHost {
      ipAddress = host
    }
    if let currentPort = originalPort {
      port = String(currentPort)
    }
  }

  /// Save: checks the port, then asks before the current link is dropped; a saved radio's
  /// address that is not the live link is kept straight away.
  private func saveChanges() {
    focusedField = nil
    guard UInt16(port) != nil else {
      errorMessage = L10n.Settings.WifiEdit.Error.invalidPort
      return
    }
    errorMessage = nil
    if editsLiveLink {
      confirmingSave = true
    } else if let editing {
      saveAddress(editing)
    }
  }

  /// Keeps the address on the saved radio's record (in the changed one's place, or as one more),
  /// without connecting: the radio's page connects to any of its addresses.
  private func saveAddress(_ editing: WiFiAddressEdit) {
    guard let portNumber = UInt16(port) else { return }
    let method = ConnectionMethod.wifi(host: WiFiAddressFields.normalizedHost(ipAddress), port: portNumber, displayName: nil)
    isProcessing = true
    Task { @MainActor in
      defer { isProcessing = false }
      do {
        try await appState.connectionManager.updateSavedWiFiAddresses(
          deviceID: editing.device.id,
          adding: method,
          removing: editing.method
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Drops the link and connects to the new address, here in the sheet, so a failure shows in
  /// it with the fields still editable rather than through the app-level alert after it's gone.
  /// Dropping the link would clear the connected device, which pops every per-device settings
  /// page (this sheet's host, Settings → Connection, included): the pages are held meanwhile, as
  /// the firmware update holds them, and let go once the sheet closes.
  private func reconnect() {
    guard let portNumber = UInt16(port) else { return }
    let host = WiFiAddressFields.normalizedHost(ipAddress)
    isProcessing = true
    holdsDevicePages = true
    appState.navigation.holdsDevicePagesForUpdate = true
    Task { @MainActor in
      defer { isProcessing = false }
      // the address being changed leaves the record; the connect below saves the new one in front
      if let editing, let old = editing.method {
        _ = try? await appState.connectionManager.updateSavedWiFiAddresses(deviceID: editing.device.id, removing: old)
      }
      await appState.disconnect(reason: .wifiAddressChange)
      do {
        try await appState.connectViaWiFi(host: host, port: portNumber, forceFullSync: true)
        releaseDevicePagesIfHeld()
        dismiss()
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }

  /// Lets the radio's pages go again; without a radio back they pop as they would have.
  private func releaseDevicePagesIfHeld() {
    guard holdsDevicePages else { return }
    holdsDevicePages = false
    appState.navigation.holdsDevicePagesForUpdate = false
    if appState.connectedDevice == nil {
      appState.navigation.clearPerDeviceSelection()
    }
  }
}

#Preview {
  WiFiEditSheet()
    .environment(\.appState, AppState())
}
