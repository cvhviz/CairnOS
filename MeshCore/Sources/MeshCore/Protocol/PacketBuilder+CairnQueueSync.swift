import Foundation

// MARK: - Cairn queue sync (firmware's examples/companion_radio/ui-l2/net/QUEUE_SYNC.md)

public extension PacketBuilder {
  /// Asks for the offline queue's state and loss counters: `[0xC0][0x08][0x00]`.
  ///
  /// Other firmware answers `RESP_CODE_ERR` with ``ErrorCode/unsupportedCommand``.
  static func cairnQueueSyncState() -> Data {
    Data([CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.queueSync, CairnQueueSyncOp.state.rawValue])
  }

  /// Turns the queueing of delivery confirmations for NEXT readers on or off: `[0xC0][0x08][0x01][on]`.
  static func cairnQueueSyncArm(on: Bool) -> Data {
    Data([
      CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.queueSync, CairnQueueSyncOp.arm.rawValue,
      on ? 1 : 0,
    ])
  }

  /// The two-step read: `[0xC0][0x08][0x02][ack_seq u32]`. The radio removes the frame `ackSeq`
  /// names (0 = none), then answers the next one and leaves it queued until a later NEXT names it.
  static func cairnQueueSyncNext(ackSeq: UInt32) -> Data {
    var data = Data([CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.queueSync, CairnQueueSyncOp.next.rawValue])
    data.appendLittleEndian(ackSeq)
    return data
  }

  /// Subtracts loss counts the app has read (so a loss counted since stays):
  /// `[0xC0][0x08][0x03][channel_evicted u32][refused u32][snapshot_lost u32][confirm_evicted u32]`.
  static func cairnQueueSyncClearLoss(_ loss: CairnQueueLoss) -> Data {
    var data = Data([
      CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.queueSync, CairnQueueSyncOp.clearLoss.rawValue,
    ])
    data.appendLittleEndian(loss.channelEvicted)
    data.appendLittleEndian(loss.refused)
    data.appendLittleEndian(loss.snapshotLost)
    data.appendLittleEndian(loss.confirmationsEvicted)
    return data
  }
}
