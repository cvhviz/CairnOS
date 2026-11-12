import Foundation

/// A connection that turned out to reach a radio already saved over another transport: the same
/// public key, first heard over WiFi after Bluetooth or the other way round. The record is already
/// one radio by then (`buildServicesAndSaveDevice` resolves the radio by key and merges the
/// connection methods); this is what the app tells the user about it.
public struct LinkedRadioNotice: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let radioName: String
  public let newTransport: TransportType
  /// The transports the radio was saved with before this connection.
  public let savedTransports: [TransportType]

  public init(id: UUID = UUID(), radioName: String, newTransport: TransportType, savedTransports: [TransportType]) {
    self.id = id
    self.radioName = radioName
    self.newTransport = newTransport
    self.savedTransports = savedTransports
  }
}

/// Identity across transports: a radio is its public key. A Bluetooth record is keyed by the
/// peripheral's UUID and a WiFi one by a UUID derived from the key (`DeviceIdentity`), so the same
/// radio reached both ways is told apart only by comparing keys.
public enum SavedRadioLink {
  /// The notice for a connection just saved, or nil when it isn't news: the record was already
  /// known by this connection's ID, the key matched nothing, the match carried no transport (a
  /// backup shadow), or it already had this transport (a later switch between known transports).
  public static func notice(
    existingByID: DeviceDTO?,
    existingByKey: DeviceDTO?,
    newDeviceID: UUID,
    newMethods: [ConnectionMethod],
    radioName: String
  ) -> LinkedRadioNotice? {
    guard existingByID == nil, let saved = existingByKey, saved.id != newDeviceID,
          let newTransport = newMethods.first?.transportType else { return nil }
    let savedTransports = orderedTransports(saved.connectionMethods)
    guard !savedTransports.isEmpty, !savedTransports.contains(newTransport) else { return nil }
    return LinkedRadioNotice(radioName: radioName, newTransport: newTransport, savedTransports: savedTransports)
  }

  /// Each transport once, Bluetooth first.
  public static func orderedTransports(_ methods: [ConnectionMethod]) -> [TransportType] {
    let kinds = Set(methods.map(\.transportType))
    return [TransportType.bluetooth, .wifi].filter(kinds.contains)
  }
}
