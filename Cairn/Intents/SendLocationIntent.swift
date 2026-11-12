import AppIntents
import CairnServices
import CoreLocation

/// Voice/Shortcuts intent that sends where you are to a contact (DM) or a channel as a plain
/// coordinate message, the text the chat's share menu inserts, so the other end's map tap works
/// on it. The position is the phone's fix when Location is allowed (asked for afresh, briefly),
/// else the radio's own; with neither there is nothing to send and the intent says so. The send
/// takes `SendMessageIntent`'s road: the durable queue, confirmed first, and never reported as
/// delivered.
struct SendLocationIntent: AppIntent {
  static let title = LocalizedStringResource("intent.location.title", table: "Tools")
  static let description = IntentDescription(
    LocalizedStringResource("intent.location.description", table: "Tools")
  )

  @available(iOS 26, *)
  static var supportedModes: IntentModes {
    [.background, .foreground(.dynamic)]
  }

  /// Where you are goes out under your identity: never from a locked phone.
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

  @Parameter(title: LocalizedStringResource("intent.send.param.target", table: "Tools"))
  var target: MessageTargetEntity

  @Dependency var bridge: IntentBridge

  static var parameterSummary: some ParameterSummary {
    Summary("Send my location to \(\.$target)", table: "Tools")
  }

  /// How long a fresh fix is waited for before the last one (or the radio's) is used.
  static let fixTimeout: Duration = .seconds(5)

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let appState = bridge.appState else {
      try await handOffToForeground()
      return .result(dialog: IntentDialog(stringLiteral: L10n.Tools.Intent.Send.foreground))
    }
    switch SendMessageIntent.route(for: appState.connectionManager.connectionState) {
    case .headlessQueue, .queueAfterSync:
      let recipient = try await resolveRecipient(in: appState)
      guard let coordinate = await Self.coordinate(in: appState) else { throw IntentError.noLocation }
      let message = ChatShareMenu.coordinateText(for: coordinate)
      let nodeNameByteCount = appState.connectedDevice?.nodeName.utf8.count ?? 0
      try SendMessageIntent.validate(message: message, for: recipient, nodeNameByteCount: nodeNameByteCount)
      try await requestConfirmation(dialog: IntentDialog(stringLiteral: SendMessageIntent.confirmText(for: recipient)))
      switch try await SendMessageIntent.performSend(message: message, recipient: recipient, in: appState) {
      case .queued:
        return .result(dialog: IntentDialog(stringLiteral: Self.successDialog(for: recipient)))
      case .mustForeground:
        try await handOffToForeground()
      }
    case .foregroundEscalate:
      try await handOffToForeground()
    case .notConnected:
      let hasRestorableRadio = appState.connectionManager.lastConnectedRadioID != nil
      switch SendMessageIntent.disconnectedRoute(hasRestorableRadio: hasRestorableRadio) {
      case .foregroundEscalate:
        try await handOffToForeground()
      default:
        throw IntentError.notConnected
      }
    }
    return .result(dialog: IntentDialog(stringLiteral: L10n.Tools.Intent.Send.foreground))
  }

  /// The phone's fix (fresh when it comes in time, the last one otherwise) while Location is
  /// allowed, else the radio's position; nil with neither. No permission prompt: Siri can't
  /// show one.
  @MainActor
  static func coordinate(in appState: AppState) async -> CLLocationCoordinate2D? {
    let location = appState.locationService
    if location.isAuthorized {
      if let fresh = try? await location.requestCurrentLocation(timeout: fixTimeout), fresh.coordinate.isValidFix {
        return fresh.coordinate
      }
    }
    guard let best = appState.bestAvailableLocation, best.coordinate.isValidFix else { return nil }
    return best.coordinate
  }

  /// The spoken line once the message is queued. Pure, for the tests.
  static func successDialog(for recipient: MessageRecipient) -> String {
    let name = switch recipient {
    case let .contact(dto): dto.displayName
    case let .channel(dto): dto.displayName
    }
    return L10n.Tools.Intent.Location.sent(name)
  }

  // MARK: - Recipient resolution

  /// As `SendMessageIntent` resolves its target: against the connected radio, by the id's kind.
  @MainActor
  private func resolveRecipient(in appState: AppState) async throws -> MessageRecipient {
    guard let scope = currentRadioScope(bridge) else { throw IntentError.invalidRecipient }
    switch parseCompositeID(target.id)?.kind {
    case .contact:
      let contacts = try await scope.store.fetchContacts(radioID: scope.radioID)
      guard let dto = contacts.first(where: { MessageTargetEntity(dto: $0).id == target.id }) else {
        throw IntentError.invalidRecipient
      }
      return .contact(dto)
    case .channel:
      let channels = try await scope.store.fetchChannels(radioID: scope.radioID)
      guard let dto = resolveUniqueChannels(matching: [target.id], in: channels).first else {
        throw IntentError.invalidRecipient
      }
      return .channel(dto)
    case nil:
      throw IntentError.invalidRecipient
    }
  }

  @MainActor
  private func handOffToForeground() async throws {
    let dialog = IntentDialog(stringLiteral: L10n.Tools.Intent.Send.foreground)
    if #available(iOS 26, *) {
      guard systemContext.currentMode.canContinueInForeground else {
        throw needsToContinueInForegroundError(dialog)
      }
      try await continueInForeground(dialog)
    } else {
      try await requestToContinueInForeground(dialog)
    }
  }
}

@available(iOSApplicationExtension, unavailable)
extension SendLocationIntent: ForegroundContinuableIntent {}
