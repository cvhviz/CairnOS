import CoreBluetooth
import Foundation
import NordicDFU
import OSLog

/// One Nordic legacy DFU to a board, through NordicDFU's own Bluetooth central: it connects to the
/// running firmware, asks it into the bootloader, reconnects there and sends the package.
@MainActor
final class NordicDFURunner: NSObject {
  enum Event: Equatable, Sendable {
    case connecting
    case enablingBootloader
    case uploading(Double)
    case validating
    case completed
    case failed(String)
  }

  private nonisolated static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NordicDFU")
  /// Packets between receipt notifications: what the firmware FAQ asks the nRF DFU app for (8
  /// suits the T114 and the RAK alike).
  static let packetsPerReceipt: UInt16 = 8

  private var controller: DFUServiceController?
  private var initiator: DFUServiceInitiator?
  private var continuation: AsyncStream<Event>.Continuation?
  /// The library's own log of this run, newest last: what the update page shows when a step
  /// stalls or fails, so a stuck handoff can be read rather than guessed at.
  private(set) var transcript: [String] = []
  private static let transcriptLimit = 200

  /// Starts the update on the peripheral `identifier` (one this app has seen) and reports it, ending
  /// with `.completed` or `.failed`.
  func run(_ package: NordicFirmwarePackage, on identifier: UUID) -> AsyncStream<Event> {
    let (stream, continuation) = AsyncStream<Event>.makeStream()
    self.continuation = continuation
    transcript = []
    let firmware = DFUFirmware(binFile: package.application, datFile: package.initPacket, type: .application)
    let initiator = DFUServiceInitiator().with(firmware: firmware)
    initiator.delegate = self
    initiator.progressDelegate = self
    initiator.logger = self
    initiator.packetReceiptNotificationParameter = Self.packetsPerReceipt
    initiator.connectionTimeout = 20
    // After the board resets into its bootloader: try the same address for a moment (a bonded
    // companion, whose bootloader advertises directed at this phone), then scan for the DFU
    // service, which an unbonded board's bootloader advertises openly at address + 1. Without the
    // scan the library waits on the old address and, if nothing comes, falls silent.
    initiator.forceScanningForNewAddressInLegacyDfu = true
    self.initiator = initiator
    controller = initiator.start(targetWithIdentifier: identifier)
    if controller == nil { finish(.failed(L10n.Settings.FirmwareUpdate.Nordic.Error.couldNotStart)) }
    return stream
  }

  func abort() {
    _ = controller?.abort()
  }

  /// Ends the run as failed when the library has gone quiet (its connection attempt timed out
  /// without a word): `abort()` only reaches a transfer under way.
  func giveUp() {
    guard continuation != nil else { return }
    note("gave up waiting")
    finish(.failed(L10n.Settings.FirmwareUpdate.Nordic.Error.lostConnection))
  }

  private func emit(_ event: Event) {
    continuation?.yield(event)
  }

  private func finish(_ event: Event) {
    continuation?.yield(event)
    continuation?.finish()
    continuation = nil
    controller = nil
    initiator = nil
  }
}

// NordicDFU calls these on the main queue (the initiator's default delegate queues).
extension NordicDFURunner: @preconcurrency DFUServiceDelegate {
  func dfuStateDidChange(to state: DFUState) {
    Self.logger.info("DFU state: \(state.description)")
    note("state: \(state.description)")
    switch state {
    case .connecting, .starting: emit(.connecting)
    case .enablingDfuMode: emit(.enablingBootloader)
    case .uploading: emit(.uploading(0))
    case .validating: emit(.validating)
    case .disconnecting: break
    case .completed: finish(.completed)
    case .aborted: finish(.failed(L10n.Settings.FirmwareUpdate.Nordic.Error.aborted))
    @unknown default: break
    }
  }

  func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
    Self.logger.error("DFU error \(error.rawValue): \(message)")
    note("error \(error.rawValue): \(message)")
    finish(.failed(Self.message(for: error, detail: message)))
  }

  static func message(for error: DFUError, detail: String) -> String {
    switch error {
    case .bluetoothDisabled: L10n.Settings.FirmwareUpdate.Nordic.Error.bluetoothOff
    case .failedToConnect, .deviceDisconnected: L10n.Settings.FirmwareUpdate.Nordic.Error.lostConnection
    case .deviceNotSupported, .serviceDiscoveryFailed: L10n.Settings.FirmwareUpdate.Nordic.Error.notSupported
    case .crcError, .bytesLost, .remoteLegacyDFUCrcError: L10n.Settings.FirmwareUpdate.Nordic.Error.corrupted
    default: L10n.Settings.FirmwareUpdate.Nordic.Error.failed(detail)
    }
  }
}

extension NordicDFURunner: @preconcurrency DFUProgressDelegate {
  func dfuProgressDidChange(
    for part: Int, outOf totalParts: Int, to progress: Int,
    currentSpeedBytesPerSecond: Double, avgSpeedBytesPerSecond: Double
  ) {
    emit(.uploading(Double(progress) / 100))
  }
}

// The library logs on the initiator's logger queue (the main queue, its default).
extension NordicDFURunner: @preconcurrency LoggerDelegate {
  func logWith(_ level: LogLevel, message: String) {
    // Everything from debug up goes in the transcript: the handoff to the bootloader is
    // narrated at that level (the connect, the scan, the timeout).
    guard level.rawValue >= LogLevel.debug.rawValue else { return }
    Self.logger.debug("\(message)")
    note(message)
  }

  /// One line of the transcript, timestamped.
  private func note(_ message: String) {
    let stamp = Date.now.formatted(.dateTime.hour().minute().second())
    transcript.append("\(stamp)  \(message)")
    if transcript.count > Self.transcriptLimit { transcript.removeFirst(transcript.count - Self.transcriptLimit) }
  }
}

/// Finds a board advertising `name` over Bluetooth: a repeater after `start ota`, which has no
/// Bluetooth until then. Its own central, apart from the app's link to its radio.
@MainActor
final class NordicOTAScanner: NSObject, @preconcurrency CBCentralManagerDelegate {
  private var central: CBCentralManager?
  private var name = ""
  private var continuation: CheckedContinuation<UUID?, Never>?

  /// The advertising board's identifier, or nil when it doesn't show within `timeout` (or
  /// Bluetooth is off).
  func find(name: String, timeout: Duration) async -> UUID? {
    self.name = name
    let found: UUID? = await withCheckedContinuation { continuation in
      self.continuation = continuation
      central = CBCentralManager(delegate: self, queue: .main)
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        self?.resume(nil)
      }
    }
    central?.stopScan()
    central = nil
    return found
  }

  private func resume(_ identifier: UUID?) {
    continuation?.resume(returning: identifier)
    continuation = nil
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn: central.scanForPeripherals(withServices: nil)
    case .poweredOff, .unauthorized, .unsupported: resume(nil)
    default: break
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
    guard advertised == name else { return }
    resume(peripheral.identifier)
  }
}
