import CairnServices
import Network
import SwiftUI

// MARK: - Local Network Permission Trigger

/// Attempts to trigger the local network privacy alert.
///
/// This builds a list of link-local IPv6 addresses and then creates a connected
/// UDP socket to each in turn. Connecting a UDP socket triggers the local
/// network alert without actually sending any traffic.
///
/// Based on Apple's TN3179: Understanding local network privacy.
private func triggerLocalNetworkPrivacyAlert() {
  let addresses = selectedLinkLocalIPv6Addresses()
  for address in addresses {
    let sock6 = socket(AF_INET6, SOCK_DGRAM, 0)
    guard sock6 >= 0 else { return }
    defer { close(sock6) }

    withUnsafePointer(to: address) { sa6 in
      sa6.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        _ = connect(sock6, sa, socklen_t(sa.pointee.sa_len)) >= 0
      }
    }
  }
}

/// Returns a selection of IPv6 addresses to connect to.
private func selectedLinkLocalIPv6Addresses() -> [sockaddr_in6] {
  let r1 = (0..<8).map { _ in UInt8.random(in: 0...255) }
  let r2 = (0..<8).map { _ in UInt8.random(in: 0...255) }
  return Array(ipv6AddressesOfBroadcastCapableInterfaces()
    .filter { isIPv6AddressLinkLocal($0) }
    .map { var addr = $0; addr.sin6_port = UInt16(9).bigEndian; return addr }
    .map { [setIPv6LinkLocalAddressHostPart(of: $0, to: r1), setIPv6LinkLocalAddressHostPart(of: $0, to: r2)] }
    .joined())
}

private func setIPv6LinkLocalAddressHostPart(of address: sockaddr_in6, to hostPart: [UInt8]) -> sockaddr_in6 {
  precondition(hostPart.count == 8)
  var result = address
  withUnsafeMutableBytes(of: &result.sin6_addr) { buf in
    buf[8...].copyBytes(from: hostPart)
  }
  return result
}

private func isIPv6AddressLinkLocal(_ address: sockaddr_in6) -> Bool {
  address.sin6_addr.__u6_addr.__u6_addr8.0 == 0xFE
    && (address.sin6_addr.__u6_addr.__u6_addr8.1 & 0xC0) == 0x80
}

private func ipv6AddressesOfBroadcastCapableInterfaces() -> [sockaddr_in6] {
  var addrList: UnsafeMutablePointer<ifaddrs>?
  let err = getifaddrs(&addrList)
  guard err == 0, let start = addrList else { return [] }
  defer { freeifaddrs(start) }
  return sequence(first: start, next: { $0.pointee.ifa_next })
    .compactMap { i -> sockaddr_in6? in
      guard
        (i.pointee.ifa_flags & UInt32(bitPattern: IFF_BROADCAST)) != 0,
        let sa = i.pointee.ifa_addr,
        sa.pointee.sa_family == AF_INET6,
        sa.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size
      else { return nil }
      return UnsafeRawPointer(sa).load(as: sockaddr_in6.self)
    }
}

/// Sheet for entering WiFi connection details (hostname or IP address and port).
struct WiFiConnectionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var ipAddress = ""
  @State private var port = "5000"
  @State private var isConnecting = false
  /// A connect has waited long enough that the radio may be asking its owner to allow this phone.
  @State private var showsApprovalHint = false
  @State private var errorMessage: String?
  @State private var transportSwitch: TransportSwitchPrompt?

  @FocusState private var focusedField: WiFiField?

  private var isValidInput: Bool {
    WiFiAddressFields.isValidHost(ipAddress) && WiFiAddressFields.isValidPort(port)
  }

  private var usesFullKeyboardInput: Bool {
    horizontalSizeClass == .regular
  }

  var body: some View {
    NavigationStack {
      CardForm {
        WiFiAddressFields(
          ipAddress: $ipAddress,
          port: $port,
          focusedField: $focusedField,
          sectionHeader: L10n.Onboarding.WifiConnection.ConnectionDetails.header,
          sectionInfo: L10n.Onboarding.WifiConnection.ConnectionDetails.footer,
          onPortSubmit: { connect() }
        )

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }

        Button {
          connect()
        } label: {
          BusyActionCardLabel(
            title: isConnecting ? L10n.Onboarding.WifiConnection.connecting : L10n.Onboarding.WifiConnection.connect,
            systemImage: "wifi",
            color: .blue,
            isBusy: isConnecting
          )
        }
        .buttonStyle(.plain)
        .disabled(!isValidInput || isConnecting)

        // A radio that doesn't know this phone asks on its own screen before it answers, and the
        // connect waits for that (`ConnectionManager.radioApprovalWait`): say where to look.
        if isConnecting, showsApprovalHint {
          Label(L10n.Onboarding.WifiConnection.approveOnRadio, systemImage: "hand.tap")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .transition(.opacity)
        }
      }
      .animation(.snappy, value: showsApprovalHint)
      .task(id: isConnecting) {
        showsApprovalHint = false
        guard isConnecting else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, isConnecting else { return }
        showsApprovalHint = true
        AccessibilityNotification.Announcement(L10n.Onboarding.WifiConnection.approveOnRadio).post()
      }
      .flashingNavigationTitle(L10n.Onboarding.WifiConnection.title)
      .navigationBarTitleDisplayMode(.inline)
      .wifiSheetToolbar(focusedField: $focusedField, isProcessing: isConnecting)
      .interactiveDismissDisabled(isConnecting)
      .transportSwitchAlert($transportSwitch) { prompt in
        guard case let .wifi(host, port, _) = prompt.method else { return }
        Task { await connect(host: host, port: port) }
      }
      .onAppear {
        if !usesFullKeyboardInput {
          focusedField = .ipAddress
        }
        triggerLocalNetworkPrivacyAlert()
      }
    }
    .presentationSizing(.page)
  }

  private func connect() {
    focusedField = nil

    guard let portNumber = UInt16(port) else {
      errorMessage = L10n.Onboarding.WifiConnection.Error.invalidPort
      return
    }

    isConnecting = true
    errorMessage = nil

    Task {
      // An address already saved for the connected radio: the same radio over WiFi. Ask before
      // moving it off Bluetooth, and don't reconnect a link that is already this one.
      let host = WiFiAddressFields.normalizedHost(ipAddress)
      let method = ConnectionMethod.wifi(host: host, port: portNumber, displayName: nil)
      if let saved = try? await appState.connectionManager.fetchSavedDevices()
        .first(where: { $0.connectionMethods.contains { $0.id == method.id } }) {
        switch appState.connectPlan(for: saved, via: method) {
        case .alreadyConnected:
          dismiss()
          return
        case let .switchTransport(from, to):
          isConnecting = false
          transportSwitch = TransportSwitchPrompt(device: saved, method: method, radioName: saved.nodeName, from: from, to: to)
          return
        case .connect:
          break
        }
      }
      await connect(host: host, port: portNumber)
    }
  }

  private func connect(host: String, port portNumber: UInt16) async {
    isConnecting = true
    do {
      try await appState.connectViaWiFi(
        host: host,
        port: portNumber,
        forceFullSync: true
      )
      await appState.wireServicesIfConnected()
      dismiss()
      // Navigate directly to radio settings
      appState.onboarding.onboardingPath.append(.region)
    } catch {
      errorMessage = error.userFacingMessage
      isConnecting = false
    }
  }
}

#Preview {
  WiFiConnectionSheet()
    .environment(\.appState, AppState())
}
