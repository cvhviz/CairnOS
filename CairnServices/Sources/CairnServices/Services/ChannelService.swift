import CryptoKit
import Foundation
import MeshCore
import os

// MARK: - Channel Service Errors

public enum ChannelServiceError: Error, Sendable {
  case notConnected
  case channelNotFound
  case invalidChannelIndex
  case secretHashingFailed
  case saveFailed(String)
  case sendFailed(String)
  case sessionError(MeshCoreError)
  case syncAlreadyInProgress
  case circuitBreakerOpen(consecutiveFailures: Int)
  /// Every slot holds a channel: there is nowhere to put a new one.
  case noFreeSlot
}

extension ChannelServiceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConnected: "Not connected to device."
    case .channelNotFound: "Channel not found."
    case .invalidChannelIndex: "Invalid channel index."
    case .secretHashingFailed: "Failed to hash channel secret."
    case let .saveFailed(msg): "Failed to save channel: \(msg)"
    case let .sendFailed(msg): "Send failed: \(msg)"
    case let .sessionError(e): e.localizedDescription
    case .syncAlreadyInProgress: "Channel sync is already in progress."
    case let .circuitBreakerOpen(n): "Channel sync suspended after \(n) consecutive failures."
    case .noFreeSlot: "All channel slots are in use."
    }
  }
}

// MARK: - Channel Sync Error Details

/// Detailed error information for a failed channel sync
struct ChannelSyncError: Equatable {
  let index: UInt8
  let errorType: ErrorType
  let description: String

  enum ErrorType: Equatable {
    case timeout
    case sendTimeout
    case transportError
    case circuitBreaker
    case deviceError(code: UInt8)
    case databaseError
    case unknown
  }

  /// Whether this error type is potentially recoverable with retry
  var isRetryable: Bool {
    switch errorType {
    case .timeout, .sendTimeout:
      true
    case .transportError, .circuitBreaker, .deviceError, .databaseError, .unknown:
      false
    }
  }

  var countsTowardCircuitBreaker: Bool {
    switch errorType {
    case .timeout, .sendTimeout, .transportError:
      true
    case .circuitBreaker, .deviceError, .databaseError, .unknown:
      false
    }
  }
}

// MARK: - Channel Sync Result

struct ChannelSyncResult: Equatable {
  let channelsSynced: Int
  let errors: [ChannelSyncError]

  /// Whether the pass changed what `verifyChannels` compares in the stored table: which slots
  /// hold a channel, or a stored channel's name or secret. A pass that threw or persisted
  /// nothing leaves it `false`. A pass that does not finish cleanly and changed the table
  /// leaves a mix of fresh and old rows, which a later check could wrongly pass, so the caller
  /// stops trusting the stored copy.
  let changedStoredTable: Bool

  /// Whether sync completed without errors
  var isComplete: Bool {
    errors.isEmpty
  }

  var requestTimeoutCount: Int {
    errors.count(where: { $0.errorType == .timeout })
  }

  var sendTimeoutCount: Int {
    errors.count(where: { $0.errorType == .sendTimeout })
  }

  var circuitBreakerAborted: Bool {
    errors.contains { $0.errorType == .circuitBreaker }
  }

  /// Indices of channels that failed with retryable errors
  var retryableIndices: [UInt8] {
    errors.filter(\.isRetryable).map(\.index)
  }

  init(channelsSynced: Int, errors: [ChannelSyncError] = [], changedStoredTable: Bool = false) {
    self.channelsSynced = channelsSynced
    self.errors = errors
    self.changedStoredTable = changedStoredTable
  }
}

// MARK: - Channel Verification

/// The outcome of `verifyChannels`: whether the radio's channel table still matches the
/// app's copy, judged from the slots the app has a channel in plus the first empty one.
enum ChannelVerification: Equatable {
  /// Every slot read matched the stored row; `slotsRead` is how many reads that took.
  case unchanged(slotsRead: Int)
  /// Something differs (or cannot be judged); the caller reads every slot instead.
  case changed(reason: String)

  var isUnchanged: Bool {
    if case .unchanged = self { return true }
    return false
  }
}

// MARK: - Channel Service Actor

/// Actor-isolated service for channel (group) management.
/// Handles channel CRUD operations, secret hashing, and broadcast messaging.
public actor ChannelService {
  // MARK: - Properties

  private let session: any MeshCoreSessionProtocol
  private let dataStore: any ChannelPersisting
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "ChannelService")

  /// Decryption cache consumer: channel writes and syncs forward the fresh
  /// channel list so `RxLogService` can decode captured packets.
  /// Injected by `ServiceContainer` at construction.
  private let rxLogService: RxLogService?

  /// Fired when a slot's occupant changes so the main actor can drop per-slot
  /// drafts, cached timelines, and an open chat.
  private var slotOccupantChangedHandler: (@Sendable (UUID, Set<UInt8>) async -> Void)?

  /// Tracks whether a sync operation is in progress
  private var isSyncing = false

  // MARK: - Initialization

  init(
    session: any MeshCoreSessionProtocol,
    dataStore: any ChannelPersisting,
    rxLogService: RxLogService?
  ) {
    self.session = session
    self.dataStore = dataStore
    self.rxLogService = rxLogService
  }

  /// Whether an RX log service was injected at construction.
  var hasRxLogServiceWired: Bool {
    rxLogService != nil
  }

  // MARK: - Secret Hashing

  /// Hashes a passphrase into a 16-byte channel secret using SHA-256.
  /// The firmware uses the first 16 bytes of the SHA-256 hash.
  /// - Parameter passphrase: The passphrase to hash
  /// - Returns: 16-byte secret data
  public static func hashSecret(_ passphrase: String) -> Data {
    guard !passphrase.isEmpty else {
      return Data(repeating: 0, count: ProtocolLimits.channelSecretSize)
    }

    let data = passphrase.data(using: .utf8) ?? Data()
    let hash = SHA256.hash(data: data)
    return Data(hash.prefix(ProtocolLimits.channelSecretSize))
  }

  /// Validates that a secret has the correct size
  public static func validateSecret(_ secret: Data) -> Bool {
    secret.count == ProtocolLimits.channelSecretSize
  }

  /// Determines if a channel slot should be treated as configured.
  /// A slot is unconfigured only when both the name is empty and the secret is all zeros.
  static func isChannelConfigured(name: String, secret: Data) -> Bool {
    !name.isEmpty || !isZeroSecret(secret)
  }

  private static func isZeroSecret(_ secret: Data) -> Bool {
    secret.allSatisfy { $0 == 0 }
  }

  // MARK: - Export Channel URI

  private static let channelURIScheme = "meshcore"
  private static let channelURIHost = "channel"
  private static let channelURIPath = "/add"
  private static let channelURINameKey = "name"
  private static let channelURISecretKey = "secret"
  private static let channelURIRegionScopeKey = "region_scope"

  /// Builds a shareable `meshcore://channel/add` URI via `URLComponents`.
  /// Always includes `name` and `secret`. Adds `region_scope` only for `.region(name)`.
  /// - Parameters:
  ///   - name: Channel name (including leading `#` for hashtag channels).
  ///   - secret: 16-byte channel PSK.
  ///   - floodScope: App-side flood preference; only `.region` is encoded.
  /// - Returns: URI string, or empty string if components fail to encode.
  public static func exportChannelURI(
    name: String,
    secret: Data,
    floodScope: ChannelFloodScope = .inherit
  ) -> String {
    var components = URLComponents()
    components.scheme = channelURIScheme
    components.host = channelURIHost
    components.path = channelURIPath

    var queryItems = [
      URLQueryItem(name: channelURINameKey, value: name),
      URLQueryItem(name: channelURISecretKey, value: secret.uppercaseHexString())
    ]
    if case let .region(regionName) = floodScope, !regionName.isEmpty {
      queryItems.append(URLQueryItem(name: channelURIRegionScopeKey, value: regionName))
    }
    components.percentEncodedQueryItems = MeshCoreURIQuery.percentEncodedQueryItems(from: queryItems)
    return components.url?.absoluteString ?? ""
  }

  // MARK: - Channel CRUD Operations

  /// Fetches all channels for a device from the remote device.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - maxChannels: Maximum number of channels to fetch (from device capacity)
  /// - Returns: Sync result with number of channels synced
  /// - Throws: `syncAlreadyInProgress` if another sync is running,
  ///           `circuitBreakerOpen` if too many consecutive timeouts
  func syncChannels(
    radioID: UUID,
    maxChannels: UInt8,
    usePipelinedRead: Bool
  ) async throws -> ChannelSyncResult {
    // Concurrency guard
    guard !isSyncing else {
      logger.warning("Channel sync already in progress, rejecting concurrent request")
      throw ChannelServiceError.syncAlreadyInProgress
    }

    isSyncing = true
    defer { isSyncing = false }

    if usePipelinedRead {
      return try await syncChannelsPipelined(radioID: radioID, maxChannels: maxChannels)
    }

    var syncErrors: [ChannelSyncError] = []
    var configured: [ChannelInfo] = []
    var unconfiguredIndices: [UInt8] = []
    var emptyNameWithSecretIndices: [UInt8] = []

    // Circuit breaker state
    var consecutiveTimeouts = 0
    let circuitBreakerThreshold = 3

    for index: UInt8 in 0..<maxChannels {
      // Circuit breaker: fail fast if connection is clearly broken
      if consecutiveTimeouts >= circuitBreakerThreshold {
        logger.error("Circuit breaker open: \(consecutiveTimeouts) consecutive timeouts, aborting sync")
        // Mark remaining channels as failed
        for remaining in index..<maxChannels {
          syncErrors.append(ChannelSyncError(
            index: remaining,
            errorType: .circuitBreaker,
            description: "Skipped due to circuit breaker"
          ))
        }
        break
      }

      do {
        if let channelInfo = try await fetchChannel(index: index) {
          configured.append(channelInfo)
          consecutiveTimeouts = 0 // Reset on success
          if channelInfo.name.isEmpty {
            emptyNameWithSecretIndices.append(index)
          }
        } else {
          // Channel not configured on device - mark its slot for stale-entry cleanup
          consecutiveTimeouts = 0 // Not-found is not a timeout
          unconfiguredIndices.append(index)
        }
      } catch let error as ChannelServiceError {
        let syncError = classifyError(error, forIndex: index)
        consecutiveTimeouts = nextConsecutiveFailureCount(
          after: syncError,
          currentCount: consecutiveTimeouts
        )
        logger.warning("Failed to sync channel \(index): \(syncError.description)")
        syncErrors.append(syncError)
      } catch {
        let syncError = classifyError(error, forIndex: index)
        consecutiveTimeouts = nextConsecutiveFailureCount(
          after: syncError,
          currentCount: consecutiveTimeouts
        )
        logger.warning("Failed to sync channel \(index): \(syncError.description)")
        syncErrors.append(syncError)
      }
    }

    // Persist the whole pass in a single transaction. Indices skipped by the circuit breaker
    // are left in neither list, so they are untouched.
    return await finalizeChannelSync(
      radioID: radioID,
      maxChannels: maxChannels,
      configured: configured,
      unconfiguredIndices: unconfiguredIndices,
      emptyNameWithSecretIndices: emptyNameWithSecretIndices,
      syncErrors: syncErrors,
      pipelined: false
    )
  }

  /// Pipelined channel read for transports that support it (nRF52 over BLE, ESP32 over WiFi):
  /// one bounded-window `getChannels` exchange in place of N serial round-trips, then
  /// acknowledged reconciliation of any dropped requests. Classification and the
  /// single-transaction persist match the serial path so an index that could not be read lands
  /// in neither the configured nor the unconfigured list and is therefore never deleted.
  private func syncChannelsPipelined(radioID: UUID, maxChannels: UInt8) async throws -> ChannelSyncResult {
    var syncErrors: [ChannelSyncError] = []
    var configured: [ChannelInfo] = []
    var unconfiguredIndices: [UInt8] = []
    var emptyNameWithSecretIndices: [UInt8] = []

    // A hard send failure (e.g. disconnect mid-send) throws here, aborting the round with
    // nothing persisted; an idle stall returns a partial set to reconcile rather than throwing.
    let (received, missing) = try await session.getChannels(indices: Array(0..<maxChannels))

    for info in received {
      if Self.isChannelConfigured(name: info.name, secret: info.secret) {
        configured.append(info)
        if info.name.isEmpty {
          emptyNameWithSecretIndices.append(info.index)
        }
      } else {
        unconfiguredIndices.append(info.index)
      }
    }

    // Reconcile dropped Write Commands with acknowledged reads. "Consecutive" failures are
    // meaningful again on this serial sub-loop, so the circuit breaker applies here. An index
    // still unread after reconcile stays in neither list, so its row is never deleted.
    var consecutiveTimeouts = 0
    let circuitBreakerThreshold = 3
    for index in missing {
      if consecutiveTimeouts >= circuitBreakerThreshold {
        logger.error("Reconcile circuit breaker open: \(consecutiveTimeouts) consecutive timeouts, stopping reconcile")
        for remaining in missing.drop(while: { $0 != index }) {
          syncErrors.append(ChannelSyncError(
            index: remaining,
            errorType: .circuitBreaker,
            description: "Skipped due to circuit breaker"
          ))
        }
        break
      }

      do {
        if let channelInfo = try await fetchChannel(index: index) {
          configured.append(channelInfo)
          consecutiveTimeouts = 0
          if channelInfo.name.isEmpty {
            emptyNameWithSecretIndices.append(index)
          }
        } else {
          consecutiveTimeouts = 0
          unconfiguredIndices.append(index)
        }
      } catch {
        let syncError = classifyError(error, forIndex: index)
        consecutiveTimeouts = nextConsecutiveFailureCount(
          after: syncError,
          currentCount: consecutiveTimeouts
        )
        logger.warning("Reconcile failed for channel \(index): \(syncError.description)")
        syncErrors.append(syncError)
      }
    }

    return await finalizeChannelSync(
      radioID: radioID,
      maxChannels: maxChannels,
      configured: configured,
      unconfiguredIndices: unconfiguredIndices,
      emptyNameWithSecretIndices: emptyNameWithSecretIndices,
      syncErrors: syncErrors,
      pipelined: true
    )
  }

  /// Persists a completed channel-read pass in a single transaction and reports the result.
  /// Shared by the serial and pipelined paths so their classification-to-persist tail cannot
  /// drift: it upserts configured channels, deletes stale rows at unconfigured slots, prunes
  /// orphans beyond capacity, and never touches an index that landed in neither list.
  private func finalizeChannelSync(
    radioID: UUID,
    maxChannels: UInt8,
    configured: [ChannelInfo],
    unconfiguredIndices: [UInt8],
    emptyNameWithSecretIndices: [UInt8],
    syncErrors: [ChannelSyncError],
    pipelined: Bool
  ) async -> ChannelSyncResult {
    var syncErrors = syncErrors

    // Snapshot occupied slots before the persist so vacated slots (unconfigured on the
    // radio, or beyond capacity) can be diffed from the survivors and have their drafts
    // dropped. A failed fetch yields an empty baseline that skips clearing, so log it.
    let priorChannels = try? await dataStore.fetchChannels(radioID: radioID)
    if priorChannels == nil {
      logger.warning("Pre-sync channel snapshot failed for radio \(radioID.uuidString); skipping draft clear for any slots this prune vacates")
    }
    let occupiedBeforeSync = Set(priorChannels?.map(\.index) ?? [])

    let channels: [ChannelDTO]
    do {
      channels = try await dataStore.batchSaveChannels(
        radioID: radioID,
        configured: configured,
        unconfiguredIndices: unconfiguredIndices,
        pruneBeyond: maxChannels
      )
    } catch {
      logger.error("Channel batch persist failed: \(error.localizedDescription)")
      for info in configured {
        syncErrors.append(ChannelSyncError(
          index: info.index,
          errorType: .databaseError,
          description: "Batch persist failed: \(error.localizedDescription)"
        ))
      }
      return ChannelSyncResult(channelsSynced: 0, errors: syncErrors)
    }

    let diagnosticsLabel = pipelined ? "Channel sync diagnostics (pipelined)" : "Channel sync diagnostics"
    logger.info(
      "\(diagnosticsLabel): synced=\(configured.count), unconfigured=\(unconfiguredIndices.count), emptyNameWithSecret=\(emptyNameWithSecretIndices.count), errors=\(syncErrors.count)"
    )
    if !emptyNameWithSecretIndices.isEmpty {
      logger.warning(
        "Channel sync detected empty-name channels with non-zero secrets at indices: \(emptyNameWithSecretIndices)"
      )
    }

    let vacatedSlots = occupiedBeforeSync.subtracting(channels.map(\.index))
    let changedSlots = vacatedSlots.union(
      secretChangedIndices(prior: priorChannels ?? [], configured: configured)
    )
    if !changedSlots.isEmpty {
      await slotOccupantChangedHandler?(radioID, changedSlots)
    }

    await rxLogService?.updateChannels(from: channels)

    return ChannelSyncResult(
      channelsSynced: configured.count,
      errors: syncErrors,
      changedStoredTable: Self.storedTableChanged(prior: priorChannels, after: channels)
    )
  }

  /// Whether a persist changed what `verifyChannels` compares: the set of occupied slots, or a
  /// slot's name or secret. `true` when the snapshot before the persist could not be read.
  static func storedTableChanged(prior: [ChannelDTO]?, after: [ChannelDTO]) -> Bool {
    guard let prior else { return true }
    struct VerifiedFields: Equatable {
      let name: String
      let secret: Data
    }
    func fields(_ rows: [ChannelDTO]) -> [UInt8: VerifiedFields] {
      Dictionary(
        rows.map { ($0.index, VerifiedFields(name: $0.name, secret: $0.secret)) },
        uniquingKeysWith: { first, _ in first }
      )
    }
    return fields(prior) != fields(after)
  }

  /// The slots `verifyChannels` reads: every slot the app holds a channel in, then the
  /// first slot it holds none in (where the radio's own UI and other apps add a channel).
  /// `nil` when a stored slot is beyond the radio's capacity, which a full read must prune.
  static func verificationSlots(localIndices: [UInt8], maxChannels: UInt8) -> [UInt8]? {
    let occupied = Set(localIndices)
    guard occupied.allSatisfy({ $0 < maxChannels }) else { return nil }
    var slots = occupied.sorted()
    if let firstFree = (0..<maxChannels).first(where: { !occupied.contains($0) }) {
      slots.append(firstFree)
    }
    return slots
  }

  /// Checks, without persisting anything, that the radio's channels still match the stored
  /// rows: the slots the app has a channel in must hold the same name and secret, and the
  /// first empty slot must still be empty. A channel joined on the radio's own screen lands
  /// in that first empty slot, and an edit or a leave changes a stored slot, so a reconnect
  /// to the same radio can trust its channels after a handful of reads instead of reading
  /// every slot. Any difference returns `.changed`, and the caller then reads every slot.
  /// - Throws: `syncAlreadyInProgress`, or the read error of a slot that could not be read.
  func verifyChannels(radioID: UUID, maxChannels: UInt8) async throws -> ChannelVerification {
    guard !isSyncing else {
      throw ChannelServiceError.syncAlreadyInProgress
    }
    isSyncing = true
    defer { isSyncing = false }

    let stored = try await dataStore.fetchChannels(radioID: radioID)
    guard !stored.isEmpty else { return .changed(reason: "no stored channels") }
    guard maxChannels > 0,
          let slots = Self.verificationSlots(localIndices: stored.map(\.index), maxChannels: maxChannels) else {
      return .changed(reason: "stored channels do not fit capacity \(maxChannels)")
    }
    let storedByIndex = Dictionary(stored.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

    for index in slots {
      let onRadio = try await fetchChannel(index: index)
      switch (storedByIndex[index], onRadio) {
      case (nil, nil):
        continue
      case let (row?, info?) where row.name == info.name && row.secret == info.secret:
        continue
      case (nil, _?):
        return .changed(reason: "slot \(index) now holds a channel")
      case (_?, nil):
        return .changed(reason: "slot \(index) is now empty")
      case (_?, _?):
        return .changed(reason: "slot \(index) changed")
      }
    }
    logger.info("Channel verification: \(slots.count) slot(s) read, all match")
    return .unchanged(slotsRead: slots.count)
  }

  /// Retries syncing only the channels that previously failed.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - indices: Channel indices to retry
  /// - Returns: Sync result for the retried channels
  func retryFailedChannels(radioID: UUID, indices: [UInt8]) async throws -> ChannelSyncResult {
    guard !isSyncing else {
      throw ChannelServiceError.syncAlreadyInProgress
    }

    guard !indices.isEmpty else {
      return ChannelSyncResult(channelsSynced: 0, errors: [])
    }

    isSyncing = true
    defer { isSyncing = false }

    logger.info("Retrying \(indices.count) failed channels: \(indices)")

    // Brief delay before retry to allow transient issues to resolve
    try await Task.sleep(for: .milliseconds(500))

    var syncErrors: [ChannelSyncError] = []
    var configured: [ChannelInfo] = []

    // Circuit breaker for retry (stricter threshold than initial sync)
    var consecutiveTimeouts = 0
    let circuitBreakerThreshold = 2

    for index in indices {
      // Circuit breaker: stop retrying if connection is clearly broken
      if consecutiveTimeouts >= circuitBreakerThreshold {
        logger.warning("Retry circuit breaker open: \(consecutiveTimeouts) consecutive timeouts, stopping retry")
        // Mark remaining channels as failed
        let remainingIndices = indices.drop(while: { $0 != index })
        for remaining in remainingIndices {
          syncErrors.append(ChannelSyncError(
            index: remaining,
            errorType: .circuitBreaker,
            description: "Skipped due to retry circuit breaker"
          ))
        }
        break
      }

      do {
        if let channelInfo = try await fetchChannel(index: index) {
          configured.append(channelInfo)
          consecutiveTimeouts = 0 // Reset on success
          logger.info("Retry succeeded for channel \(index)")
        } else {
          consecutiveTimeouts = 0 // Not-found is not a timeout
        }
      } catch {
        let syncError = classifyError(error, forIndex: index)
        consecutiveTimeouts = nextConsecutiveFailureCount(
          after: syncError,
          currentCount: consecutiveTimeouts
        )
        logger.warning("Retry failed for channel \(index): \(syncError.description)")
        syncErrors.append(syncError)
      }
    }

    // Nothing recovered: skip the persist round-trip and the handler notification.
    guard !configured.isEmpty else {
      return ChannelSyncResult(channelsSynced: 0, errors: syncErrors)
    }

    // Upsert the recovered channels in one transaction. Retry only re-fetches previously
    // failed slots, so it never deletes unconfigured slots or prunes by capacity.
    let priorSnapshot = await (try? dataStore.fetchChannels(radioID: radioID))
    let priorChannels = priorSnapshot ?? []
    let allChannels: [ChannelDTO]
    do {
      allChannels = try await dataStore.batchSaveChannels(
        radioID: radioID,
        configured: configured,
        unconfiguredIndices: [],
        pruneBeyond: nil
      )
      let changedSlots = secretChangedIndices(prior: priorChannels, configured: configured)
      if !changedSlots.isEmpty {
        await slotOccupantChangedHandler?(radioID, changedSlots)
      }
      await rxLogService?.updateChannels(from: allChannels)
    } catch {
      logger.error("Retry batch persist failed: \(error.localizedDescription)")
      for info in configured {
        syncErrors.append(ChannelSyncError(
          index: info.index,
          errorType: .databaseError,
          description: "Retry persist failed: \(error.localizedDescription)"
        ))
      }
      return ChannelSyncResult(channelsSynced: 0, errors: syncErrors)
    }

    return ChannelSyncResult(
      channelsSynced: configured.count,
      errors: syncErrors,
      changedStoredTable: Self.storedTableChanged(prior: priorSnapshot, after: allChannels)
    )
  }

  /// Fetches a single channel from the device with retry logic for transient BLE failures.
  /// - Parameter index: The channel index
  /// - Returns: Channel info if found, nil if not configured
  public func fetchChannel(index: UInt8) async throws -> ChannelInfo? {
    // BLE operations can fail transiently due to RF interference or timing.
    // Retry with exponential backoff per industry best practices (BLE spec recommends 30s timeout,
    // but shorter retries with backoff are more responsive).
    let maxAttempts = 3
    var lastError: MeshCoreError = .timeout

    for attempt in 1...maxAttempts {
      do {
        let meshChannelInfo = try await session.getChannel(index: index)

        // Validate returned index matches requested
        guard meshChannelInfo.index == index else {
          logger.error("Channel index mismatch: requested \(index), received \(meshChannelInfo.index)")
          throw ChannelServiceError.invalidChannelIndex
        }

        // Treat channel as unconfigured only when both name and secret are empty.
        guard Self.isChannelConfigured(name: meshChannelInfo.name, secret: meshChannelInfo.secret) else {
          return nil
        }
        if meshChannelInfo.name.isEmpty {
          logger.warning(
            "Channel \(index) has empty name with non-zero secret; treating as configured"
          )
        }

        // Convert MeshCore.ChannelInfo to CairnServices.ChannelInfo
        return ChannelInfo(
          index: meshChannelInfo.index,
          name: meshChannelInfo.name,
          secret: meshChannelInfo.secret
        )
      } catch let error as MeshCoreError {
        // Non-retryable: channel not found on device (permanent error)
        if case let .deviceError(code) = error, code == ProtocolError.notFound.rawValue {
          return nil
        }

        // Retryable: timeout errors are transient BLE issues
        if case .timeout = error {
          lastError = error
          if attempt < maxAttempts {
            // Exponential backoff: 500ms, 1000ms, 2000ms with jitter
            let baseDelayMs = 500 * (1 << (attempt - 1))
            let jitterMs = Int.random(in: -100...100)
            let delayMs = baseDelayMs + jitterMs
            logger.info("Channel \(index) fetch timeout, retry \(attempt)/\(maxAttempts) in \(delayMs)ms")
            try await Task.sleep(for: .milliseconds(delayMs))
            continue
          }
        }

        // Non-retryable: other MeshCore errors (device errors, parse errors, etc.)
        throw ChannelServiceError.sessionError(error)
      }
    }

    // All retries exhausted
    throw ChannelServiceError.sessionError(lastError)
  }

  /// Sets (creates or updates) a channel on the device.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - index: The channel index
  ///   - name: The channel name
  ///   - passphrase: The passphrase to hash into a secret
  public func setChannel(
    radioID: UUID,
    index: UInt8,
    name: String,
    passphrase: String
  ) async throws {
    try await writeChannel(radioID: radioID, index: index, name: name, secret: Self.hashSecret(passphrase))
  }

  /// Sets a channel with a pre-computed secret (for advanced use cases).
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - index: The channel index
  ///   - name: The channel name
  ///   - secret: The 16-byte secret (must be exactly 16 bytes)
  public func setChannelWithSecret(
    radioID: UUID,
    index: UInt8,
    name: String,
    secret: Data
  ) async throws {
    guard Self.validateSecret(secret) else {
      throw ChannelServiceError.secretHashingFailed
    }
    try await writeChannel(radioID: radioID, index: index, name: name, secret: secret)
  }

  /// Writes the channel to the radio, mirrors it locally, and notifies the slot
  /// handler when an existing occupant's secret changed.
  private func writeChannel(radioID: UUID, index: UInt8, name: String, secret: Data) async throws {
    let truncatedName = name.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
    let prior = try await dataStore.fetchChannel(radioID: radioID, index: index)

    do {
      try await session.setChannel(index: index, name: truncatedName, secret: secret)

      let channelInfo = ChannelInfo(index: index, name: truncatedName, secret: secret)
      _ = try await dataStore.saveChannel(radioID: radioID, from: channelInfo)

      if let prior, prior.secret != secret {
        await slotOccupantChangedHandler?(radioID, [index])
      }

      // Refresh the decryption cache with the updated channel list
      let channels = try await dataStore.fetchChannels(radioID: radioID)
      await rxLogService?.updateChannels(from: channels)
    } catch let error as MeshCoreError {
      throw ChannelServiceError.sessionError(error)
    }
  }

  /// Clears a channel by setting it to empty name and zero secret.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - index: The channel index
  public func clearChannel(radioID: UUID, index: UInt8) async throws {
    // Get channel ID before clearing, so we can reliably delete it
    // (fetching after setChannelWithSecret may not find the empty-named channel)
    let channelToDelete = try await dataStore.fetchChannel(radioID: radioID, index: index)

    // Set empty name and zero secret to clear on device
    do {
      try await session.setChannel(
        index: index,
        name: "",
        secret: Data(repeating: 0, count: ProtocolLimits.channelSecretSize)
      )
    } catch let error as MeshCoreError {
      throw ChannelServiceError.sessionError(error)
    }

    // deleteChannel wipes the slot's messages with the row in one transaction; with
    // no row left to delete, wipe the messages directly.
    if let channel = channelToDelete {
      try await dataStore.deleteChannel(id: channel.id)
    } else {
      try await dataStore.deleteMessagesForChannel(radioID: radioID, channelIndex: index)
    }

    await slotOccupantChangedHandler?(radioID, [index])

    // Refresh the decryption cache with the updated channel list
    let channels = try await dataStore.fetchChannels(radioID: radioID)
    await rxLogService?.updateChannels(from: channels)
  }

  /// Clears all messages for a channel without deleting the channel itself.
  /// Use this for a "Clear Messages" feature that keeps the channel active.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - channelIndex: The channel index (0-7)
  public func clearChannelMessages(radioID: UUID, channelIndex: UInt8) async throws {
    try await dataStore.deleteMessagesForChannel(radioID: radioID, channelIndex: channelIndex)

    // Clear the last message date so the channel doesn't show a preview, and zero
    // both unread counters — leaving them set would inflate the badge for a channel
    // the user just emptied.
    if let channel = try await dataStore.fetchChannel(radioID: radioID, index: channelIndex) {
      try await dataStore.updateChannelLastMessage(channelID: channel.id, date: nil)
      try await dataStore.clearChannelUnreadCount(channelID: channel.id)
      try await dataStore.clearChannelUnreadMentionCount(channelID: channel.id)
    }
  }

  // MARK: - Local Database Operations

  /// Gets all channels from local database for a device.
  /// - Parameter radioID: The device UUID
  /// - Returns: Array of channel DTOs
  public func getChannels(radioID: UUID) async throws -> [ChannelDTO] {
    try await dataStore.fetchChannels(radioID: radioID)
  }

  /// Gets a specific channel from local database.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - index: The channel index
  /// - Returns: Channel DTO if found
  public func getChannel(radioID: UUID, index: UInt8) async throws -> ChannelDTO? {
    try await dataStore.fetchChannel(radioID: radioID, index: index)
  }

  /// Gets channels that have messages (for chat list).
  /// - Parameter radioID: The device UUID
  /// - Returns: Array of channel DTOs with lastMessageDate set
  public func getActiveChannels(radioID: UUID) async throws -> [ChannelDTO] {
    let channels = try await dataStore.fetchChannels(radioID: radioID)
    return channels.filter { $0.lastMessageDate != nil }
  }

  // MARK: - Public Channel

  /// Creates or resets the Public channel and returns the slot it is in.
  ///
  /// Public goes to slot 0 when that slot is free or already holds it. A slot is never taken on
  /// the local table's word alone: slot 0 is read from the radio first, because another app may
  /// have put a private channel there, and overwriting it would destroy that channel's key.
  /// Then it goes to the first slot that is free both locally and on the radio.
  /// - Parameters:
  ///   - radioID: The device UUID
  ///   - maxChannels: The radio's channel capacity
  /// - Throws: ``ChannelServiceError/noFreeSlot`` when every slot is taken.
  @discardableResult
  public func setupPublicChannel(radioID: UUID, maxChannels: UInt8) async throws -> UInt8 {
    let local = try await dataStore.fetchChannels(radioID: radioID)
    let index: UInt8
    if let existing = local.first(where: \.isPublicChannel) {
      index = existing.index
    } else {
      index = try await freeSlotForPublic(localSlots: Set(local.map(\.index)), maxChannels: maxChannels)
    }
    try await setChannelWithSecret(
      radioID: radioID,
      index: index,
      name: "Public",
      secret: PublicChannelKey.publicSecret
    )
    return index
  }

  private func freeSlotForPublic(localSlots: Set<UInt8>, maxChannels: UInt8) async throws -> UInt8 {
    for index in 0..<max(maxChannels, 1) {
      // slot 0 is always asked of the radio; a later slot only when the local table shows it free
      if index > 0, localSlots.contains(index) { continue }
      guard let onRadio = try await fetchChannel(index: index) else { return index }
      if PublicChannelKey.isPublic(onRadio.secret) { return index }
    }
    throw ChannelServiceError.noFreeSlot
  }

  /// Whether the Public channel (by its key) is in the local table.
  /// - Parameter radioID: The device UUID
  public func hasPublicChannel(radioID: UUID) async throws -> Bool {
    try await dataStore.fetchChannels(radioID: radioID).contains(where: \.isPublicChannel)
  }

  // MARK: - Handlers

  /// Sets the callback for slots whose occupant changed (vacated or rewritten
  /// with a different secret) so the main actor can drop per-slot state.
  public func setSlotOccupantChangedHandler(_ handler: @escaping @Sendable (UUID, Set<UInt8>) async -> Void) {
    slotOccupantChangedHandler = handler
  }

  /// Indices whose configured secret differs from the locally stored row. Slots with
  /// no prior row are first sightings, not occupant changes.
  private func secretChangedIndices(prior: [ChannelDTO], configured: [ChannelInfo]) -> Set<UInt8> {
    let priorSecrets = Dictionary(prior.map { ($0.index, $0.secret) }, uniquingKeysWith: { current, _ in current })
    return Set(configured.compactMap { info in
      guard let priorSecret = priorSecrets[info.index], priorSecret != info.secret else { return nil }
      return info.index
    })
  }

  // MARK: - Private Helpers

  /// Classifies an error into a ChannelSyncError for the given index
  private func classifyError(_ error: Error, forIndex index: UInt8) -> ChannelSyncError {
    if let channelError = error as? ChannelServiceError {
      switch channelError {
      case .circuitBreakerOpen:
        return ChannelSyncError(
          index: index,
          errorType: .circuitBreaker,
          description: channelError.localizedDescription
        )
      case let .sessionError(meshError):
        switch meshError {
        case .timeout:
          return ChannelSyncError(
            index: index,
            errorType: .timeout,
            description: "Request timed out"
          )
        case let .deviceError(code):
          return ChannelSyncError(
            index: index,
            errorType: .deviceError(code: code),
            description: meshError.localizedDescription
          )
        default:
          return ChannelSyncError(
            index: index,
            errorType: .unknown,
            description: meshError.localizedDescription
          )
        }
      case let .saveFailed(reason):
        return ChannelSyncError(
          index: index,
          errorType: .databaseError,
          description: "Save failed: \(reason)"
        )
      default:
        return ChannelSyncError(
          index: index,
          errorType: .unknown,
          description: channelError.localizedDescription
        )
      }
    }

    if let transportError = error as? WiFiTransportError {
      switch transportError {
      case .sendTimeout:
        return ChannelSyncError(
          index: index,
          errorType: .sendTimeout,
          description: "Send timed out"
        )
      case .notConnected, .connectionFailed, .connectionTimeout, .localNetworkDenied, .sendFailed:
        return ChannelSyncError(
          index: index,
          errorType: .transportError,
          description: transportError.localizedDescription
        )
      case .invalidHost, .invalidPort, .notConfigured:
        return ChannelSyncError(
          index: index,
          errorType: .unknown,
          description: transportError.localizedDescription
        )
      }
    }

    if let transportError = error as? MeshTransportError {
      switch transportError {
      case .sendFailed:
        return ChannelSyncError(
          index: index,
          errorType: .transportError,
          description: transportError.localizedDescription
        )
      case .notConnected, .connectionFailed, .deviceNotFound, .serviceNotFound, .characteristicNotFound:
        return ChannelSyncError(
          index: index,
          errorType: .transportError,
          description: transportError.localizedDescription
        )
      }
    }

    return ChannelSyncError(
      index: index,
      errorType: .unknown,
      description: error.localizedDescription
    )
  }

  private func nextConsecutiveFailureCount(
    after error: ChannelSyncError,
    currentCount: Int
  ) -> Int {
    error.countsTowardCircuitBreaker ? currentCount + 1 : 0
  }
}

// MARK: - ChannelServiceProtocol Conformance

extension ChannelService: ChannelServiceProtocol {
  // Already implements syncChannels(radioID:maxChannels:) -> ChannelSyncResult
}
