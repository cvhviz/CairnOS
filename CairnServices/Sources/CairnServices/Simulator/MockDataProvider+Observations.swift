import Foundation
import MeshCore

public extension MockDataProvider {
  /// The channel the demo radio listens on (`simulatorDevice`: 915.000 MHz, 250 kHz, SF10), where
  /// its observations are stored.
  static var simulatorChannelKey: ChannelKey {
    let device = simulatorDevice
    return RadioChannelConfig(
      frequencyKHz: device.frequency,
      bandwidthHz: device.bandwidth,
      spreadingFactor: device.spreadingFactor,
      codingRate: device.codingRate
    ).key
  }

  /// What the demo radio has heard on its channel: each mock contact's advert, as a radio that
  /// received them over the air would hold it (``ObservationLedger``). The Traffic maps and the
  /// RX Log name and place nodes only from these (`PacketNodeIndex`), never from saved contacts,
  /// and the simulator radio sends no packets to learn them from, so without them demo mode has
  /// no observed node at all.
  ///
  /// A contact with no path (0 hops) was heard directly; one with a path, over that many relays;
  /// a flood-routed one over relays it doesn't know. Each is observed when its advert was
  /// (`lastAdvertTimestamp`, relative to now as the contacts are), at its advertised position
  /// when it has one.
  static var observedNodes: [ObservedNode] {
    contacts.compactMap { contact in
      guard let identity = ObservedIdentity(bytes: contact.publicKey) else { return nil }
      let heardAt = Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp))
      let hops: Int? = contact.outPathLength == PacketBuilder.floodPathSentinel ? nil : Int(contact.outPathLength)
      let isDirect = hops == 0
      let hasPosition = contact.latitude != 0 || contact.longitude != 0
      return ObservedNode(
        identity: identity,
        name: contact.name,
        nodeTypeRaw: contact.typeRawValue,
        latitude: hasPosition ? contact.latitude : nil,
        longitude: hasPosition ? contact.longitude : nil,
        positionAt: hasPosition ? heardAt : nil,
        firstObservedAt: heardAt,
        lastObservedAt: heardAt,
        lastDirectAt: isDirect ? heardAt : nil,
        minHops: hops,
        lastHops: hops,
        kinds: [isDirect ? .advertDirect : .advertRelayed: KindStat(count: 1, lastAt: heardAt)]
      )
    }
  }
}
