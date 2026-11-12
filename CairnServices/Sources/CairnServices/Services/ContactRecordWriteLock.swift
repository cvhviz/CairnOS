import Foundation
import MeshCore

/// Serializes read-modify-write cycles on one radio contact record, keyed by public key.
///
/// A flag or path change reads the radio's record, then writes the whole record back. Two of
/// them for the same contact that overlap across the read's `await` would both start from the
/// same record, and the later write would undo the earlier one: a favourite toggle could put back
/// a remote-commands bit (0x10) that was just revoked. Holding this lock across the read and the
/// write makes overlapping changes apply one after another, in the order they reached the lock.
///
/// One instance is shared by every service that writes full contact records, so a path-discovery
/// write and a permission toggle for the same contact cannot interleave either. Waiters resume
/// first-in, first-out. The lock is not reentrant: a body must not take it again for the same key.
public actor ContactRecordWriteLock {
  /// Holders and queued waiters per key. A key is present while its lock is held.
  private var waiters: [Data: [CheckedContinuation<Void, Never>]] = [:]

  public init() {}

  /// Runs `body` while holding the lock for `publicKey`.
  func withLock<T: Sendable>(
    _ publicKey: Data,
    _ body: @Sendable () async throws -> T
  ) async rethrows -> T {
    await acquire(publicKey)
    defer { release(publicKey) }
    return try await body()
  }

  /// Calls waiting for the lock on `publicKey` (not counting the holder). For tests.
  func waitingCount(for publicKey: Data) -> Int {
    waiters[publicKey]?.count ?? 0
  }

  private func acquire(_ publicKey: Data) async {
    guard waiters[publicKey] != nil else {
      waiters[publicKey] = []
      return
    }
    await withCheckedContinuation { continuation in
      waiters[publicKey, default: []].append(continuation)
    }
  }

  private func release(_ publicKey: Data) {
    guard var queue = waiters[publicKey] else { return }
    if queue.isEmpty {
      waiters[publicKey] = nil
    } else {
      // Ownership passes straight to the next waiter; the key stays held.
      let next = queue.removeFirst()
      waiters[publicKey] = queue
      next.resume()
    }
  }
}

/// The rule for the remote-commands bit (contact flag 0x10) in any full contact record the app
/// writes to the radio: it may only ever be what the radio itself holds.
///
/// A stored copy can be stale (revoked on the device since the last sync) and an imported config
/// or a QR card comes from outside, so neither may grant it. Only
/// ``ContactService/setRemoteCLIAllowed(_:allowed:)`` sets it, from the radio's own record.
enum RemoteCLIFlagGuard {
  /// `requested` with its remote-commands bit replaced by the radio's: kept only when `onRadio`
  /// (the radio's current record for the key) has it, cleared when the radio holds no record.
  static func flags(_ requested: UInt8, onRadio: MeshContact?) -> UInt8 {
    let bit = ContactFlags.remoteCLI.rawValue
    return (requested & ~bit) | ((onRadio?.flags.rawValue ?? 0) & bit)
  }

  /// `requested` with the remote-commands bit of the radio's record, as `readRadioRecord`
  /// returns it now. A read that fails clears the bit: the write may then revoke a grant, never
  /// add one.
  static func flags(
    _ requested: UInt8,
    readRadioRecord: @Sendable () async throws -> MeshContact?
  ) async -> UInt8 {
    do {
      return flags(requested, onRadio: try await readRadioRecord())
    } catch {
      return requested & ~ContactFlags.remoteCLI.rawValue
    }
  }
}
