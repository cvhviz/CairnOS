import Intents
import OSLog

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "SiriAuthorization")

/// Siri permission, which CarPlay messaging depends on: the Chats rows hand every conversation
/// to Siri, and Siri only routes messages to an app the person allowed. The system prompt shows
/// on the phone, so it belongs to setup on the phone, before driving: the end of onboarding asks,
/// and Settings → CarPlay & Siri shows the answer with a way to ask (or to iOS Settings once
/// declined). The car never asks; its screen says "Siri messaging is off" until Siri is allowed.
@MainActor
enum SiriAuthorization {
  static var status: INSiriAuthorizationStatus {
    INPreferences.siriAuthorizationStatus()
  }

  static var isAuthorized: Bool {
    status == .authorized
  }

  /// Asks once; a person who already answered is never asked again.
  static func requestIfNeeded() {
    guard status == .notDetermined else { return }
    askSystem()
  }

  /// Asks when the person hasn't answered yet and returns the answer, or the current status when
  /// they already have, so a settings card can show the result without polling.
  static func request() async -> INSiriAuthorizationStatus {
    guard status == .notDetermined else { return status }
    let result = await askSystemForAnswer()
    logger.info("Siri authorization: \(result.rawValue)")
    return result
  }

  // Intents answers on its own queue, not the main thread. A closure written inside this
  // main-actor type would be main-actor isolated under Swift 6 and trap on that queue, so the
  // handlers are built in nonisolated functions and only touch Sendable values.
  private nonisolated static func askSystem() {
    INPreferences.requestSiriAuthorization { @Sendable status in
      logger.info("Siri authorization: \(status.rawValue)")
    }
  }

  private nonisolated static func askSystemForAnswer() async -> INSiriAuthorizationStatus {
    await withCheckedContinuation { (continuation: CheckedContinuation<INSiriAuthorizationStatus, Never>) in
      INPreferences.requestSiriAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
  }
}
