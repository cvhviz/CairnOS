import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore

extension ObservationDirectory {
  /// The channel ``heard(contacts:discovered:labels:at:)`` hears on.
  static let heardChannel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)

  /// A directory whose current channel heard each of `contacts` and `discovered` advertise
  /// itself (its name, type and stored position, through one relay) at `date`, with `labels`
  /// (default `contacts`) as the saved contacts. For screens that name hops only by what this
  /// radio heard: a node left out of both lists was never heard, whatever the contacts say.
  @MainActor
  static func heard(
    contacts: [ContactDTO] = [],
    discovered: [DiscoveredNodeDTO] = [],
    labels: [ContactDTO]? = nil,
    at date: Date = .now
  ) -> ObservationDirectory {
    var ledger = ObservationLedger(radioID: UUID(), channel: heardChannel, selfKey: nil)
    let nodes = contacts.map { ($0.publicKey, $0.name, $0.typeRawValue, $0.latitude, $0.longitude) }
      + discovered.map { ($0.publicKey, $0.name, $0.typeRawValue, $0.latitude, $0.longitude) }
    for (key, name, type, latitude, longitude) in nodes {
      guard let identity = ObservedIdentity(bytes: key) else { continue }
      ledger.ingest(NodeObservation(
        identity: identity,
        kind: .advertRelayed,
        channelKey: heardChannel.key,
        at: date,
        hops: 1,
        name: name,
        nodeTypeRaw: type,
        latitude: latitude,
        longitude: longitude
      ))
    }
    let directory = ObservationDirectory()
    directory.setLabels(contacts: labels ?? contacts, discovered: discovered)
    directory.setLedger(ledger.snapshot(takenAt: date))
    return directory
  }
}
