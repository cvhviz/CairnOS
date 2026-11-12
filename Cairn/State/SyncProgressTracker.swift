import CairnServices
import MeshCore
import Observation

/// Live item counts for the syncing pill, so a long sync reads as moving rather than stuck.
/// The sync coordinator reports only the phase; the counts come from the radio's own event
/// stream: the `contactsStart` header and each `contact` for contacts, each `channelInfo` reply for
/// channels, and each message pulled during the catch-up poll.
@Observable
@MainActor
final class SyncProgressTracker {
  private(set) var phase: SyncPhase?
  private(set) var received = 0
  /// Reported contact total from the `contactsStart` header; channels use the device's slot count.
  private(set) var contactTotal: Int?
  /// False when the radio sends only contacts changed since the last sync; its header still
  /// reports the full total, so that total would read as "0/150" and look stuck.
  private(set) var isFullContactFetch = true

  func phaseChanged(_ newPhase: SyncPhase?) {
    guard newPhase != phase else { return }
    phase = newPhase
    received = 0
    if newPhase != .contacts {
      contactTotal = nil
    }
  }

  func contactFetchModeChanged(isFullFetch: Bool) {
    isFullContactFetch = isFullFetch
  }

  func handle(_ event: MeshEvent) {
    switch (phase, event) {
    case let (.contacts, .contactsStart(count)):
      contactTotal = count
      received = 0
    case (.contacts, .contact):
      received += 1
    case (.channels, .channelInfo):
      received += 1
    case (.messages, .contactMessageReceived), (.messages, .channelMessageReceived):
      received += 1
    default:
      break
    }
  }

  func reset() {
    phase = nil
    received = 0
    contactTotal = nil
    isFullContactFetch = true
  }

  /// Short progress line such as "Contacts 42/150", or nil before there is anything to count.
  func detailText(maxChannels: Int?) -> String? {
    switch phase {
    case .contacts:
      guard isFullContactFetch else {
        return received > 0 ? L10n.Localizable.Common.Status.SyncProgress.contactUpdates(received) : nil
      }
      guard let contactTotal else { return nil }
      return L10n.Localizable.Common.Status.SyncProgress.contacts(min(received, contactTotal), contactTotal)
    case .channels:
      guard let maxChannels, maxChannels > 0 else {
        return received > 0 ? L10n.Localizable.Common.Status.SyncProgress.channelsCount(received) : nil
      }
      return L10n.Localizable.Common.Status.SyncProgress.channels(min(received, maxChannels), maxChannels)
    case .messages:
      return received > 0 ? L10n.Localizable.Common.Status.SyncProgress.messages(received) : nil
    case nil:
      return nil
    }
  }
}
