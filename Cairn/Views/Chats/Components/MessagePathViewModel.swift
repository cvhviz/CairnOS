import CoreLocation
import MapKit
import CairnServices
import OSLog
import SwiftUI
import UIKit

@Observable
@MainActor
final class MessagePathViewModel {
  /// Saved contacts: a message's sender by its key, and the page a hop opens when its resolved
  /// key is exactly a contact's. Never what a hop's hash names.
  var contacts: [ContactDTO] = []
  /// What this radio heard on its channel (`AppState.observationDirectory`): the only nodes a
  /// hop's hash can name, exactly as the RX Log list and the Traffic map name them. A saved
  /// contact or discovered node never heard here never names a hop, wherever it is.
  var observations: ObservationDirectory?
  var isLoading = true
  private(set) var lastPreviewImage: UIImage?

  typealias PathPreviewRenderer = @MainActor (
    _ points: [MapPoint],
    _ line: MapLine?,
    _ region: MKCoordinateRegion?,
    _ size: CGSize,
    _ isDark: Bool,
    _ isOffline: Bool,
    _ appearance: MapAvatarAppearance
  ) async -> UIImage?

  private var previewImages: [MessagePathPreviewSnapshot.Key: UIImage] = [:]
  private var failedPreviewKeys: Set<MessagePathPreviewSnapshot.Key> = []
  /// Bumped when prefetch or retry starts so an in-flight render cannot store a stale bitmap.
  private var previewGeneration = 0
  private let renderPreview: PathPreviewRenderer
  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "MessagePathViewModel")

  init(renderPreview: PathPreviewRenderer? = nil) {
    self.renderPreview = renderPreview ?? { points, line, region, size, isDark, isOffline, appearance in
      await MapSnapshotRenderer().render(
        points: points,
        line: line,
        region: region,
        size: size,
        isDark: isDark,
        isOffline: isOffline,
        appearance: appearance
      )
    }
  }

  func loadContacts(dataStore: PersistenceStore?, radioID: UUID) async {
    isLoading = true
    guard let dataStore else {
      contacts = []
      isLoading = false
      return
    }

    do {
      contacts = try await dataStore.fetchContacts(radioID: radioID)
    } catch {
      logger.error("Failed to load contacts: \(error.localizedDescription)")
      contacts = []
    }

    isLoading = false
  }

  func senderResolution(for message: MessageDTO, localDeviceName: String) -> NodeNameResolution {
    if message.isOutgoing {
      return NodeNameResolution(displayName: localDeviceName, matchKind: .exact)
    }

    if message.isChannelMessage, let nodeName = message.senderNodeName {
      return NodeNameResolution(displayName: nodeName, matchKind: .exact)
    }

    if let keyPrefix = message.senderKeyPrefix,
       let result = NeighborNameResolver.resolve(
         for: keyPrefix,
         contacts: contacts,
         discoveredNodes: [],
         userLocation: nil
       ) {
      return result
    }

    return NodeNameResolution(
      displayName: L10n.Chats.Chats.Path.Hop.unknown,
      matchKind: .unresolved
    )
  }

  func senderName(for message: MessageDTO, localDeviceName: String) -> String {
    senderResolution(for: message, localDeviceName: localDeviceName).displayName
  }

  func senderNodeID(for message: MessageDTO) -> String? {
    guard let keyPrefix = message.senderKeyPrefix,
          let firstByte = keyPrefix.first else { return nil }
    return String(format: "%02X", firstByte)
  }

  /// Pin A contact from a non-empty `senderKeyPrefix`, or a unique `senderNodeName` on a channel row.
  func locatedSender(for message: MessageDTO) -> ContactDTO? {
    if let keyPrefix = message.senderKeyPrefix, !keyPrefix.isEmpty {
      guard let sender = contacts.first(where: { $0.publicKeyPrefix == keyPrefix }),
            sender.hasLocation else {
        return nil
      }
      return sender
    }

    guard message.isChannelMessage,
          let senderName = message.senderNodeName, !senderName.isEmpty else {
      return nil
    }

    let matches = SenderContactMatcher.filter(contacts: contacts, senderName: senderName)
    guard matches.count == 1, let sender = matches.first, sender.hasLocation else {
      return nil
    }
    return sender
  }

  /// The index hops resolve against: the radio's current channel. A message keeps no record of
  /// the channel it was heard on, so its hops are named from the channel the radio is on now.
  var nodeIndex: PacketNodeIndex {
    observations?.nodeIndex ?? .empty
  }

  /// Each hop of `arrival`, oldest first, resolved against what this radio heard on its channel
  /// (`PacketNodeResolver`, as the RX Log list and the Traffic map resolve a path): one observed
  /// node with the hash names it, several are a guess, none leaves it unknown. The newest hop of
  /// a flood is the one this radio heard. No saved contact and no distance decides a hop.
  func relays(for arrival: MessagePathArrival) -> [PacketNodeMatch] {
    let hashes = arrival.pathHops.map(\.data)
    return PacketNodeResolver.resolvePath(
      hashes,
      newestFirst: !arrival.isDirectRoute,
      at: arrival.receivedAt,
      in: nodeIndex
    )
  }

  /// A hop's name: the observed node it resolved to (exact), the likeliest of several observed
  /// nodes sharing its hash (a guess), or Unknown when no node heard here has it.
  func repeaterResolution(for match: PacketNodeMatch) -> NodeNameResolution {
    switch match {
    case let .resolved(entry):
      NodeNameResolution(displayName: Self.name(of: entry), matchKind: .exact)
    case let .ambiguous(best, _, _):
      NodeNameResolution(displayName: Self.name(of: best), matchKind: .fallback)
    case .radio:
      NodeNameResolution(displayName: L10n.Tools.Tools.RxLog.pathYou, matchKind: .exact)
    case .unknown:
      NodeNameResolution(displayName: L10n.Chats.Chats.Path.Hop.unknown, matchKind: .unresolved)
    }
  }

  /// For a hop no node heard here resolves, the likeliest node sharing its hash that wasn't taken
  /// for it ("Not heard on this channel: Kona Hill shares this prefix"), as the RX log and the
  /// Traffic map say it; nil for a resolved hop or one nothing shares.
  func unknownHint(for match: PacketNodeMatch, receivedAt: Date) -> String? {
    guard case let .unknown(hash) = match,
          let sharer = nodeIndex.unobservedSharers(of: hash, at: receivedAt).first else { return nil }
    return TrafficNodeFormat.hint(sharer, now: .now)
  }

  /// The saved contact a hop opens: only one whose whole key is exactly the key the hop resolved
  /// to. Never for a guess or an unknown hop.
  func repeaterContact(for match: PacketNodeMatch) -> ContactDTO? {
    guard case let .resolved(entry) = match, entry.publicKey.count == ObservedIdentity.publicKeySize else { return nil }
    return contacts.first { $0.publicKey == entry.publicKey }
  }

  /// Where a hop's node advertised itself in a packet this radio received; nil for a guess, an
  /// unknown hop, or a node that never advertised a position. Never a saved contact's position.
  func relayCoordinate(for match: PacketNodeMatch) -> CLLocationCoordinate2D? {
    guard case let .resolved(entry) = match, let coordinate = entry.coordinate, coordinate.isValidFix else { return nil }
    return coordinate
  }

  /// Its name, or its key's first 3 bytes in hex when it has none, as the RX Log list shows it.
  private static func name(of entry: NeighbourKeyEntry) -> String {
    entry.name ?? Data(entry.publicKey.prefix(3)).uppercaseHexString()
  }

  func previewImage(for key: MessagePathPreviewSnapshot.Key) -> UIImage? {
    previewImages[key]
  }

  func previewFailed(for key: MessagePathPreviewSnapshot.Key) -> Bool {
    failedPreviewKeys.contains(key)
  }

  func prefetchPreviews(
    message: MessageDTO,
    arrivals: [MessagePathArrival],
    selectedID: UUID?,
    connectedDevice: DeviceDTO?,
    userLocation: CLLocation?,
    isDark: Bool,
    isOffline: Bool,
    containerWidth: CGFloat,
    appearance: MapAvatarAppearance? = nil
  ) async {
    let size = MessagePathPreviewSnapshot.previewSize(containerWidth: containerWidth)
    guard size.width >= 1, !isLoading else { return }

    previewGeneration += 1
    let generation = previewGeneration
    let ordered = Self.prefetchOrder(selectedID: selectedID, arrivals: arrivals)
    for arrival in ordered {
      guard generation == previewGeneration else { return }
      let key = MessagePathPreviewSnapshot.key(
        arrivalID: arrival.id,
        isDark: isDark,
        isOffline: isOffline,
        containerWidth: containerWidth,
        appearance: appearance
      )
      await renderPreviewIfNeeded(
        arrival: arrival,
        message: message,
        arrivals: arrivals,
        connectedDevice: connectedDevice,
        userLocation: userLocation,
        key: key,
        size: size,
        appearance: appearance ?? .standard(isDark: isDark),
        generation: generation,
        force: false
      )
    }
  }

  func retryPreview(
    arrivalID: UUID,
    message: MessageDTO,
    arrivals: [MessagePathArrival],
    connectedDevice: DeviceDTO?,
    userLocation: CLLocation?,
    isDark: Bool,
    isOffline: Bool,
    containerWidth: CGFloat,
    appearance: MapAvatarAppearance? = nil
  ) async {
    let key = MessagePathPreviewSnapshot.key(
      arrivalID: arrivalID,
      isDark: isDark,
      isOffline: isOffline,
      containerWidth: containerWidth,
      appearance: appearance
    )
    failedPreviewKeys.remove(key)
    let size = MessagePathPreviewSnapshot.previewSize(containerWidth: containerWidth)
    guard size.width >= 1, let arrival = arrivals.first(where: { $0.id == arrivalID }) else { return }
    previewGeneration += 1
    let generation = previewGeneration
    await renderPreviewIfNeeded(
      arrival: arrival,
      message: message,
      arrivals: arrivals,
      connectedDevice: connectedDevice,
      userLocation: userLocation,
      key: key,
      size: size,
      appearance: appearance ?? .standard(isDark: isDark),
      generation: generation,
      force: true
    )
  }

  private static func prefetchOrder(
    selectedID: UUID?,
    arrivals: [MessagePathArrival]
  ) -> [MessagePathArrival] {
    let selected = MessagePathArrivals.resolvedSelection(preferred: selectedID, arrivals: arrivals)
    guard let selected else { return arrivals }
    let first = arrivals.filter { $0.id == selected }
    let rest = arrivals.filter { $0.id != selected }
    return first + rest
  }

  private func renderPreviewIfNeeded(
    arrival: MessagePathArrival,
    message: MessageDTO,
    arrivals: [MessagePathArrival],
    connectedDevice: DeviceDTO?,
    userLocation: CLLocation?,
    key: MessagePathPreviewSnapshot.Key,
    size: CGSize,
    appearance: MapAvatarAppearance,
    generation: Int,
    force: Bool
  ) async {
    if !force, previewImages[key] != nil { return }

    let canvas = MessagePathMapView.canvasModel(
      message: message,
      arrivals: arrivals,
      selectedID: arrival.id,
      pathViewModel: self,
      connectedDevice: connectedDevice,
      userLocation: userLocation
    )
    guard canvas.showsPathMap else { return }

    let image = await renderPreview(
      canvas.points,
      canvas.lines.first,
      canvas.cameraRegion,
      size,
      key.isDark,
      key.isOffline,
      appearance
    )
    guard generation == previewGeneration else { return }
    if let image {
      previewImages[key] = image
      lastPreviewImage = image
      failedPreviewKeys.remove(key)
    } else {
      failedPreviewKeys.insert(key)
    }
  }
}
