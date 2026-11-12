import Foundation

// MARK: - Cairn RX_SYNC (firmware's examples/companion_radio/ui-l2/net/RX_SYNC.md)

public extension PacketBuilder {
  /// Asks a Cairn companion for its receive journal's state: `[0xC0][0x07][0x00]`.
  ///
  /// Answered with a ``CairnRxSyncReply/state(_:)``; other firmware answers `RESP_CODE_ERR` with
  /// ``ErrorCode/unsupportedCommand``.
  static func cairnRxSyncState() -> Data {
    Data([CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.rxSync, CairnRxSyncOp.state.rawValue])
  }

  /// Turns RX_SYNC delivery on or off for this link, 14 bytes:
  /// `[0xC0][0x07][0x01][on][resume_epoch u32][resume_seq u32][resume_max u16]`.
  ///
  /// With `on` and a `resumeEpoch` that matches the radio's, delivery picks up after `resumeSeq`
  /// (at most `resumeMax` records back) when the journal still holds the record after it;
  /// otherwise it starts live. Off reverts the link to stock 0x88 frames.
  ///
  /// - Parameters:
  ///   - on: `true` to opt in, `false` to opt out.
  ///   - resumeEpoch: The epoch of the last record this app stored (0 for none).
  ///   - resumeSeq: The last record this app stored under `resumeEpoch` (0 for none).
  ///   - resumeMax: The most records to send again on resume.
  static func cairnRxSyncSubscribe(on: Bool, resumeEpoch: UInt32, resumeSeq: UInt32, resumeMax: UInt16) -> Data {
    var data = Data([
      CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.rxSync, CairnRxSyncOp.subscribe.rawValue,
      on ? 1 : 0,
    ])
    data.appendLittleEndian(resumeEpoch)
    data.appendLittleEndian(resumeSeq)
    data.append(UInt8(resumeMax & 0xFF))
    data.append(UInt8(resumeMax >> 8))
    return data
  }

  /// Asks for held records again, 8 bytes: `[0xC0][0x07][0x02][since_seq u32][max]`.
  ///
  /// The records numbered after `sinceSeq` come as ``ResponseCode/rxRecord`` frames marked
  /// ``CairnRxRecordFrame/Flags/backfill``, then one ``CairnRxFetchEnd``. One fetch per link at a
  /// time: another one is answered BUSY.
  ///
  /// - Parameters:
  ///   - sinceSeq: The record before the first one wanted.
  ///   - max: Records to send, 1...32 (the radio answers BAD_ARG otherwise).
  static func cairnRxSyncFetch(sinceSeq: UInt32, max: UInt8) -> Data {
    var data = Data([CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.rxSync, CairnRxSyncOp.fetch.rawValue])
    data.appendLittleEndian(sinceSeq)
    data.append(max)
    return data
  }
}
