import CairnServices
import os
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodeAuthenticationSheet")

/// Which repeaters and rooms log in on their own when opened, by public key. A per-node choice
/// made on the login sheet; it needs the saved password, so it goes when that does.
enum NodeAutoLogin {
  private static let key = "nodeAutoLoginKeys"

  /// Nodes whose automatic login failed this launch (a changed password, say): opening them shows
  /// the sheet for a manual try rather than failing over and over.
  @MainActor static var failedThisLaunch: Set<Data> = []

  static func isEnabled(for publicKey: Data) -> Bool {
    stored.contains(publicKey.hexString)
  }

  static func set(_ enabled: Bool, for publicKey: Data) {
    var keys = stored
    if enabled { keys.insert(publicKey.hexString) } else { keys.remove(publicKey.hexString) }
    UserDefaults.standard.set(Array(keys), forKey: key)
  }

  private static var stored: Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }
}

/// Reusable password entry sheet for both room servers and repeaters
struct NodeAuthenticationSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let contact: ContactDTO
  let role: RemoteNodeRole
  /// When true, hides the Node Details section (used when re-joining known rooms from chat list)
  let hideNodeDetails: Bool
  /// Optional custom title. If nil, uses default based on role ("Join Room" or "Admin Access")
  let customTitle: String?
  let onSuccess: (RemoteNodeSessionDTO) -> Void

  @State private var password: String = ""
  @State private var rememberPassword = true
  @State private var autoLogin: Bool
  /// This attempt was started by automatic login, so a failure turns it off for this launch.
  @State private var isAutomaticAttempt = false
  @State private var useFloodRouting: Bool
  @State private var didResetPath = false
  @State private var isRetryingViaFlood = false
  @State private var showsPassword = false
  @State private var isAuthenticating = false
  @State private var errorMessage: String?
  @State private var hasSavedPassword = false
  @State private var pathViewModel = NodeAuthPathViewModel()

  // Countdown state
  @State private var authSecondsRemaining: Int?
  @State private var authStartTime: Date?
  @State private var authTimeoutSeconds: Int?
  @State private var countdownTask: Task<Void, Never>?
  @State private var authenticationTask: Task<Void, Never>?

  private let maxPasswordLength = 15

  init(
    contact: ContactDTO,
    role: RemoteNodeRole,
    hideNodeDetails: Bool = false,
    customTitle: String? = nil,
    onSuccess: @escaping (RemoteNodeSessionDTO) -> Void
  ) {
    self.contact = contact
    self.role = role
    self.hideNodeDetails = hideNodeDetails
    self.customTitle = customTitle
    self.onSuccess = onSuccess
    _useFloodRouting = State(initialValue: contact.isFloodRouted)
    _autoLogin = State(initialValue: NodeAutoLogin.isEnabled(for: contact.publicKey))
  }

  var body: some View {
    NavigationStack {
      CardForm {
        if !hideNodeDetails {
          makeNodeDetailsSection()
        }
        makeAuthenticationSection()
        makePathSection()
        makeConnectButton()
      }
      .flashingNavigationTitle(customTitle ?? (role == .roomServer ? L10n.RemoteNodes.RemoteNodes.Auth.joinRoom : L10n.RemoteNodes.RemoteNodes.Auth.management))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.RemoteNodes.RemoteNodes.Auth.cancel) {
            authenticationTask?.cancel()
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task {
        if let remoteNodeService = appState.services?.remoteNodeService,
           let saved = await remoteNodeService.retrievePassword(forContact: contact) {
          password = saved
          hasSavedPassword = true
          // Logs straight in when this node is set to; the sheet then shows only the progress.
          if autoLogin, !NodeAutoLogin.failedThisLaunch.contains(contact.publicKey) {
            isAutomaticAttempt = true
            authenticate()
          }
        }
      }
      .task {
        guard !contact.isFloodRouted, contact.pathHopCount > 0,
              let radioID = appState.connectedDevice?.radioID else { return }
        await pathViewModel.load(
          contact: contact,
          services: appState.services,
          radioID: radioID,
          userLocation: appState.bestAvailableLocation
        )
      }
      .sensoryFeedback(.error, trigger: errorMessage)
      // The choice holds as soon as it's made, not only after a successful login.
      .onChange(of: autoLogin) { _, enabled in
        NodeAutoLogin.set(enabled && rememberPassword, for: contact.publicKey)
      }
      .onChange(of: errorMessage) { _, message in
        if message != nil, isAutomaticAttempt {
          NodeAutoLogin.failedThisLaunch.insert(contact.publicKey)
          isAutomaticAttempt = false
        }
      }
      .onDisappear {
        authenticationTask?.cancel()
        cleanupCountdownState()
      }
    }
  }

  // MARK: - Sections

  private func makeNodeDetailsSection() -> some View {
    NodeDetailsSection(contact: contact, role: role)
  }

  private func makeAuthenticationSection() -> some View {
    AuthenticationSection(
      password: $password,
      showsPassword: $showsPassword,
      rememberPassword: $rememberPassword,
      autoLogin: $autoLogin,
      errorMessage: $errorMessage,
      authSecondsRemaining: $authSecondsRemaining,
      isRetryingViaFlood: isRetryingViaFlood,
      role: role,
      maxPasswordLength: maxPasswordLength
    )
  }

  /// How recently a node must have been heard directly for its route to be trusted: a login that
  /// then goes unanswered most likely had the wrong password, so no flood retry is sent.
  static let heardDirectlyWindow: TimeInterval = 10 * 60

  /// Whether this radio heard the node itself within `heardDirectlyWindow`.
  private var heardDirectlyRecently: Bool {
    guard let neighbour = appState.neighbourDirectory.neighbour(publicKey: contact.publicKey, now: .now) else {
      return false
    }
    return Date.now.timeIntervalSince(neighbour.record.lastHeard) <= Self.heardDirectlyWindow
  }

  private func makePathSection() -> some View {
    PathSection(
      contact: contact,
      useFloodRouting: $useFloodRouting,
      pathViewModel: pathViewModel
    )
  }

  private func makeConnectButton() -> some View {
    ConnectButton(
      role: role,
      isAuthenticating: isAuthenticating,
      onAuthenticate: { authenticate() }
    )
  }

  // MARK: - Authentication

  private func authenticate() {
    // Clear any previous error
    errorMessage = nil
    isAuthenticating = true
    isRetryingViaFlood = false
    authenticationTask?.cancel()
    cleanupCountdownState()

    authenticationTask = Task {
      do {
        guard let device = appState.connectedDevice else {
          throw RemoteNodeError.notConnected
        }

        guard let services = appState.services else {
          throw RemoteNodeError.notConnected
        }

        // Reset the firmware's stored path so the login packet is flood-routed.
        // Only needed once per session — subsequent retries skip the BLE round-trip.
        // Once any reset has run, the radio's path is gone regardless of what
        // this sheet's contact snapshot says, so later attempts are flood.
        let pathLength: UInt8
        if useFloodRouting && !contact.isFloodRouted && !didResetPath {
          do {
            try await services.contactService.resetPath(
              radioID: device.radioID,
              publicKey: contact.publicKey
            )
          } catch ContactServiceError.contactNotFound {
            // The repeater's contact is missing from the radio (#338). Login re-adds it
            // flood-routed and retries, which is what this reset was for, so carry on.
            logger.info("Path reset skipped: contact not on radio; login will re-add it")
          }
          didResetPath = true
          pathLength = PacketBuilder.floodPathSentinel
        } else if useFloodRouting || didResetPath {
          pathLength = PacketBuilder.floodPathSentinel
        } else {
          pathLength = contact.outPathLength
        }

        // MeshCore repeaters and rooms only support 15-character passwords, truncate if needed
        let passwordToUse = password.count > maxPasswordLength
          ? String(password.prefix(maxPasswordLength))
          : password

        let session: RemoteNodeSessionDTO
        do {
          session = try await performLogin(
            services: services,
            device: device,
            password: passwordToUse,
            pathLength: pathLength
          )
        } catch RemoteNodeError.timeout where pathLength != PacketBuilder.floodPathSentinel && !heardDirectlyRecently {
          // The stored route produced no reply; clear it and let the network
          // find a path, mirroring what the flood toggle would have done. A node this radio heard
          // directly a moment ago was in range: silence then means the password, not the route.
          await MainActor.run {
            isRetryingViaFlood = true
            cleanupCountdownState()
          }
          do {
            try await services.contactService.resetPath(
              radioID: device.radioID,
              publicKey: contact.publicKey
            )
          } catch ContactServiceError.contactNotFound {
            logger.info("Path reset skipped: contact not on radio; login will re-add it")
          }
          didResetPath = true
          session = try await performLogin(
            services: services,
            device: device,
            password: passwordToUse,
            pathLength: PacketBuilder.floodPathSentinel
          )
        }

        // Automatic login rides on the saved password.
        NodeAutoLogin.set(rememberPassword && autoLogin, for: contact.publicKey)
        NodeAutoLogin.failedThisLaunch.remove(contact.publicKey)

        // Delete saved password if user unchecked "Remember Password"
        if hasSavedPassword, !rememberPassword {
          do {
            try await services.remoteNodeService.deletePassword(forContact: contact)
          } catch {
            logger.warning("Failed to delete saved password: \(error)")
          }
        }

        await MainActor.run {
          authenticationTask = nil
          isRetryingViaFlood = false
          cleanupCountdownState()
          dismiss()
          onSuccess(session)
        }
      } catch is CancellationError {
        await MainActor.run {
          authenticationTask = nil
          isRetryingViaFlood = false
          cleanupCountdownState()
          isAuthenticating = false
        }
      } catch RemoteNodeError.timeout {
        await MainActor.run {
          authenticationTask = nil
          isRetryingViaFlood = false
          cleanupCountdownState()
          // Every route has been tried by now (or the node was in range): a wrong password
          // produces the same silence as a node out of reach, so say both.
          errorMessage = L10n.RemoteNodes.RemoteNodes.Auth.noReply
          isAuthenticating = false
        }
      } catch {
        await MainActor.run {
          authenticationTask = nil
          isRetryingViaFlood = false
          cleanupCountdownState()
          errorMessage = error.userFacingMessage
          isAuthenticating = false
        }
      }
    }
  }

  private func performLogin(
    services: ServiceContainer,
    device: DeviceDTO,
    password: String,
    pathLength: UInt8
  ) async throws -> RemoteNodeSessionDTO {
    // Callback to start countdown when firmware timeout is known
    let onTimeoutKnown: @Sendable (Int) async -> Void = { [self] seconds in
      await MainActor.run {
        authTimeoutSeconds = seconds
        authStartTime = Date.now
        authSecondsRemaining = seconds
        startCountdownTask()
      }
    }

    if role == .roomServer {
      return try await services.roomServerService.joinRoom(
        radioID: device.radioID,
        contact: contact,
        password: password,
        rememberPassword: rememberPassword,
        pathLength: pathLength,
        onTimeoutKnown: onTimeoutKnown
      )
    } else {
      return try await services.repeaterAdminService.connectAsAdmin(
        radioID: device.radioID,
        contact: contact,
        password: password,
        rememberPassword: rememberPassword,
        pathLength: pathLength,
        onTimeoutKnown: onTimeoutKnown
      )
    }
  }

  // MARK: - Countdown

  private static let countdownTickInterval: Duration = .seconds(1)

  private func startCountdownTask() {
    countdownTask = Task {
      while !Task.isCancelled, let timeout = authTimeoutSeconds, let startTime = authStartTime {
        do {
          try await Task.sleep(for: Self.countdownTickInterval)
        } catch {
          break
        }

        let elapsed = Date.now.timeIntervalSince(startTime)
        let remaining = max(0, timeout - Int(elapsed))
        authSecondsRemaining = remaining
        if remaining == 0 {
          break
        }
      }
    }
  }

  private func cleanupCountdownState() {
    countdownTask?.cancel()
    countdownTask = nil
    authSecondsRemaining = nil
    authStartTime = nil
    authTimeoutSeconds = nil
  }
}

// MARK: - Node Details Section

/// Which node this login is for, as one identity card (avatar, name, type) like a node page's
/// header, rather than separate Name and Type rows.
private struct NodeDetailsSection: View {
  @Environment(\.appState) private var appState
  let contact: ContactDTO
  let role: RemoteNodeRole

  private var typeLabel: String {
    role == .roomServer ? L10n.RemoteNodes.RemoteNodes.Auth.typeRoom : L10n.RemoteNodes.RemoteNodes.Auth.typeRepeater
  }

  /// "Direct", "2 hops" or "Flood": the route the login will take unless flooding is chosen.
  private var routeSummary: String {
    if contact.isFloodRouted { return L10n.Contacts.Contacts.Route.flood }
    if contact.pathHopCount == 0 { return L10n.Contacts.Contacts.Route.direct }
    return NodeRouteFormat.hopCount(contact.pathHopCount)
  }

  var body: some View {
    // The node's Dashboard header: its map, name, "Repeater · 2 hops", and how far.
    NodeMapHeader(
      coordinate: contact.hasLocation ? contact.coordinate : nil,
      marker: role == .roomServer ? .contactRoom : .contactRepeater,
      markerAvatar: MapPinAvatar(contact: contact),
      title: contact.displayName,
      subtitle: "\(typeLabel) · \(routeSummary)",
      infoLine: contact.hasLocation
        ? RemoteNodeHeaderFormat.infoLine(coordinate: contact.coordinate, userLocation: appState.bestAvailableLocation)
        : nil
    ) {
      NodeAvatar(publicKey: contact.publicKey, role: role, size: NodeMapHeader<EmptyView>.avatarSize)
        .accessibilityHidden(true)
    }
  }
}

// MARK: - Authentication Section

private struct AuthenticationSection: View {
  /// Countdown values at which VoiceOver gets a time-remaining announcement.
  private static let announcementThresholds = [30, 15, 10]
  /// Below this many seconds, every countdown tick is announced.
  private static let finalCountdownSeconds = 5

  @Binding var password: String
  @Binding var showsPassword: Bool
  @Binding var rememberPassword: Bool
  @Binding var autoLogin: Bool
  @Binding var errorMessage: String?
  @Binding var authSecondsRemaining: Int?
  let isRetryingViaFlood: Bool
  let role: RemoteNodeRole
  let maxPasswordLength: Int

  var body: some View {
    CardFormSection(L10n.RemoteNodes.RemoteNodes.Auth.authentication) {
      // The password and what to do with it, in one card.
      ContentCard {
        VStack(spacing: 10) {
          HStack(spacing: 8) {
            // Shown in the clear on request: a mistyped password reads as "no reply".
            Group {
              if showsPassword {
                TextField(L10n.RemoteNodes.RemoteNodes.Auth.password, text: $password)
              } else {
                SecureField(L10n.RemoteNodes.RemoteNodes.Auth.password, text: $password)
              }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 28)
            Button {
              showsPassword.toggle()
            } label: {
              Image(systemName: showsPassword ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
              showsPassword ? L10n.RemoteNodes.RemoteNodes.Auth.hidePassword : L10n.RemoteNodes.RemoteNodes.Auth.showPassword
            )
          }
          Divider()
          Toggle(L10n.RemoteNodes.RemoteNodes.Auth.rememberPassword, isOn: $rememberPassword)
          Divider()
          // Needs the saved password, so it goes off with Remember Password.
          Toggle(L10n.RemoteNodes.RemoteNodes.Auth.autoLogin, isOn: $autoLogin)
            .disabled(!rememberPassword)
            .accessibilityHint(L10n.RemoteNodes.RemoteNodes.Auth.AutoLogin.hint)
        }
      }

      status
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onChange(of: rememberPassword) { _, remember in
      if !remember { autoLogin = false }
    }
    .onChange(of: password) {
      if errorMessage != nil {
        errorMessage = nil
      }
    }
    .onChange(of: authSecondsRemaining) { oldValue, newValue in
      guard let remaining = newValue, remaining > 0 else { return }
      // Threshold-crossing rather than exact equality so a skipped tick
      // can't silently drop an announcement.
      let crossedThreshold = Self.announcementThresholds.contains { threshold in
        remaining <= threshold && (oldValue ?? Int.max) > threshold
      }
      let shouldAnnounce = oldValue == nil || crossedThreshold || remaining <= Self.finalCountdownSeconds
      if shouldAnnounce {
        AccessibilityNotification.Announcement(L10n.RemoteNodes.RemoteNodes.Auth.secondsRemainingAnnouncement(remaining)).post()
      }
    }
  }

  /// The error, the length limit, or the login's progress, under the fields. The blank line
  /// keeps the space so the page doesn't jump when a status appears.
  @ViewBuilder
  private var status: some View {
    if let errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
        .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Auth.errorPrefix(errorMessage))
    } else if password.count > maxPasswordLength {
      Text(role == .repeater ? L10n.RemoteNodes.RemoteNodes.Auth.passwordTooLongRepeaters(maxPasswordLength) : L10n.RemoteNodes.RemoteNodes.Auth.passwordTooLongRooms(maxPasswordLength))
    } else if isRetryingViaFlood {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.RemoteNodes.RemoteNodes.Auth.floodRetryStatus)
        if let remaining = authSecondsRemaining, remaining > 0 {
          Text(L10n.RemoteNodes.RemoteNodes.Auth.secondsRemaining(remaining))
        }
      }
    } else if let remaining = authSecondsRemaining, remaining > 0 {
      Text(L10n.RemoteNodes.RemoteNodes.Auth.secondsRemaining(remaining))
    } else {
      Text(" ")
        .accessibilityHidden(true)
    }
  }
}

// MARK: - Path Section

private struct PathSection: View {
  let contact: ContactDTO
  @Binding var useFloodRouting: Bool
  let pathViewModel: NodeAuthPathViewModel

  @State private var isPathExpanded = false

  private var hasStoredPath: Bool {
    !contact.isFloodRouted
  }

  private var routeInfo: String {
    if !hasStoredPath {
      L10n.RemoteNodes.RemoteNodes.Auth.noRouteFooter
    } else if useFloodRouting {
      L10n.RemoteNodes.RemoteNodes.Auth.floodFooter
    } else {
      L10n.RemoteNodes.RemoteNodes.Auth.pathFooter
    }
  }

  var body: some View {
    // What the toggle does, behind the "i", so the route and Connect stay close together.
    CardFormSection(L10n.RemoteNodes.RemoteNodes.Auth.path, info: routeInfo) {
      // The stored route and the switch that skips it, in one card.
      ContentCard {
        VStack(alignment: .leading, spacing: 10) {
          if hasStoredPath, !useFloodRouting {
            if !pathViewModel.hops.isEmpty {
              DisclosureGroup(isExpanded: $isPathExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                  ForEach(pathViewModel.hops) { hop in
                    Divider()
                    NodePathHopRow(hex: hop.hex, resolution: hop.resolution)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                }
                .padding(.top, 8)
              } label: {
                NodePathSummaryLabel(contact: contact)
              }
            } else {
              NodePathSummaryLabel(contact: contact)
            }
            Divider()
          } else if !hasStoredPath {
            Label {
              Text(L10n.RemoteNodes.RemoteNodes.Auth.noRouteSet)
                .foregroundStyle(.secondary)
            } icon: {
              Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .accessibilityHidden(true)
            Divider()
          }
          Toggle(L10n.RemoteNodes.RemoteNodes.Auth.floodRouting, isOn: $useFloodRouting)
            .disabled(!hasStoredPath)
            .accessibilityHint(hasStoredPath ? "" : L10n.RemoteNodes.RemoteNodes.Auth.noRouteFooter)
        }
      }
    }
    .animation(.default, value: useFloodRouting)
  }
}

// MARK: - Connect Button

/// The sheet's one primary action, as a full-width prominent button the shape of the cards.
private struct ConnectButton: View {
  let role: RemoteNodeRole
  let isAuthenticating: Bool
  let onAuthenticate: () -> Void

  private var buttonLabel: String {
    role == .roomServer ? L10n.RemoteNodes.RemoteNodes.Auth.joinRoom : L10n.RemoteNodes.RemoteNodes.Auth.connect
  }

  var body: some View {
    Button {
      onAuthenticate()
    } label: {
      Group {
        if isAuthenticating {
          ProgressView()
        } else {
          Text(buttonLabel)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 28)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.roundedRectangle(radius: CardStyle.cornerRadius))
    .controlSize(.large)
    .disabled(isAuthenticating)
    // While the login runs, VoiceOver still finds the button by its title, not an unnamed spinner.
    .accessibilityLabel(buttonLabel)
  }
}

#Preview {
  NodeAuthenticationSheet(
    contact: ContactDTO(from: Contact(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Room",
      typeRawValue: ContactType.room.rawValue,
      lastHeardTimestamp: 0
    )),
    role: .roomServer,
    onSuccess: { _ in }
  )
  .environment(\.appState, AppState())
}
