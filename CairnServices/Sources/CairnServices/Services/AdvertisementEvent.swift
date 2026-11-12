import Foundation
import MeshCore

/// Advertisement and discovery notifications broadcast by `AdvertisementService`.
///
/// Subscribe via `AdvertisementService.events()`. The stream is multicast:
/// every subscriber receives every event, so coexisting consumers
/// (`SyncCoordinator` for discovery notifications, `AppState` for version
/// bumps and deletion cleanup, `ConnectionUIState` for the storage-full flag,
/// path-discovery views) never steal each other's events.
public enum AdvertisementEvent: Sendable {
  /// A contact or discovered node was created or updated; observers should
  /// reload contact lists.
  case contactUpdated
  /// Adopted orphan DMs created or updated a conversation row; observers must
  /// refresh the conversation list (mirrors `SyncDataEvent.conversationsChanged`).
  case conversationsChanged
  /// Orphan DMs were linked to these contacts by a delta round. A DM that
  /// arrived before its sender's contact existed had no contact to notify at
  /// receipt; the owner of `NotificationService` posts the banner and refreshes
  /// the badge for each contact when adoption resolves the sender.
  case orphanDirectMessagesAdopted(contactIDs: [UUID])
  /// An advert arrived from any node (known or new): drives the app's "heard" badge and the
  /// Live Activity's count of nodes heard. `publicKey` is the sender's.
  case advertReceived(publicKey: Data)
  /// A new contact was discovered via advertisement.
  case newContactDiscovered(name: String, contactID: UUID, contactType: ContactType)
  /// The device's node storage full state changed (true = full, false = has space).
  case nodeStorageFullChanged(isFull: Bool)
  /// Overwrite-oldest deletions. Observers drop notifications and refresh the badge.
  case contactDeletedCleanup(contactIDs: [UUID])
  /// A path discovery response arrived for a contact.
  case pathDiscoveryResponse(PathInfo)
  /// The radio stored a new out-path for a contact on its own (`PATH_UPDATED`).
  /// The local copy catches up on the next contact delta sync.
  case contactPathUpdated(publicKey: Data)
  /// A trace response arrived; `traceInfo.tag` correlates it with the
  /// trace that requested it.
  case traceResponse(traceInfo: TraceInfo, radioID: UUID)
  /// The RX log reported reception of a trace packet, carrying the SNR the
  /// local radio measured and, when present, the far end's measured SNR.
  case traceSnrObserved(tag: UInt32, localSnr: Double, remoteSnr: Double?, radioID: UUID)
  /// The RX log overheard a trace on its way: the copy was passed on by its `hopsReached`-th hop.
  case traceProgress(tag: UInt32, hopsReached: Int, radioID: UUID)
}
