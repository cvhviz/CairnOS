import MeshCore

public extension RxPacketFields {
  /// The fields of a stored RX log entry, so the neighbour table can be rebuilt from the log.
  init(_ entry: RxLogEntryDTO) {
    self.init(
      routeType: entry.routeType,
      payloadType: entry.payloadType,
      pathLength: entry.pathLength,
      pathNodes: entry.pathNodes,
      packetPayload: entry.packetPayload,
      packetHash: entry.packetHash,
      snr: entry.snr,
      rssi: entry.rssi
    )
  }
}
