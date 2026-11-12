@testable import CairnServices
import CryptoKit
import Foundation
import MeshCore
import Testing

// MARK: - Stock Adverts

/// Adverts built byte for byte as official MeshCore firmware builds them, and their RX log copy.
private enum StockAdverts {
  /// The stored contact's last advert time; the adverts under test are newer unless a test says.
  static let storedTimestamp: UInt32 = 1_700_000_000

  /// AdvertDataBuilder::encodeTo (companion-v1.18.0 src/helpers/AdvertDataHelpers.cpp): the type
  /// in the low nibble, then the position if 0x10 and the name if 0x80.
  static func appData(type: UInt8 = 1, latLon: (Int32, Int32)? = nil, name: String?) -> [UInt8] {
    var flags = type
    var body: [UInt8] = []
    if let (lat, lon) = latLon {
      flags |= 0x10
      body += withUnsafeBytes(of: lat.littleEndian) { Array($0) }
      body += withUnsafeBytes(of: lon.littleEndian) { Array($0) }
    }
    if let name {
      flags |= 0x80
      body += Array(name.utf8)
    }
    return [flags] + body
  }

  /// Mesh::createAdvert (companion-v1.18.0 src/Mesh.cpp:404-434): public_key(32), timestamp(4),
  /// signature(64) over `public_key | timestamp | app_data`, then app_data.
  static func payload(signer: Curve25519.Signing.PrivateKey, timestamp: UInt32, appData: [UInt8]) throws -> [UInt8] {
    let key = Array(signer.publicKey.rawRepresentation)
    let time = withUnsafeBytes(of: timestamp.littleEndian) { Array($0) }
    let signature = try Array(signer.signature(for: Data(key + time + appData.prefix(32))))
    return key + time + signature + appData
  }

  /// The RX log frame (0x88) for a flood advert (PAYLOAD_TYPE_ADVERT 4) relayed over `path`.
  static func copy(_ payload: [UInt8], path: [UInt8] = [0x3A]) -> Data {
    StockCompanionFrames.logRx(raw: StockCompanionFrames.packet(
      payloadType: 0x04, route: StockCompanionFrames.routeFlood, path: path, payload: payload
    ))
  }

  /// The copy as the session dispatches it.
  static func event(_ payload: [UInt8], path: [UInt8] = [0x3A]) -> MeshEvent {
    PacketParser.parse(copy(payload, path: path))
  }
}

// MARK: - Test Doubles

/// Grace timers the test ends by hand.
private actor AdvertGraceTimers {
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  var waitingCount: Int {
    waiters.count
  }

  func sleep() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  private func cancel(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  func releaseAll() {
    let pending = waiters
    waiters.removeAll()
    for continuation in pending.values {
      continuation.resume()
    }
  }
}

private actor RoundCounter {
  private(set) var rounds = 0

  func run() -> AdvertContactSyncOutcome {
    rounds += 1
    return .synced
  }
}

private actor AdvertReceivedCounter {
  private(set) var keys: [Data] = []

  func note(_ event: AdvertisementEvent) {
    if case let .advertReceived(publicKey) = event {
      keys.append(publicKey)
    }
  }
}

private func waitUntil(
  timeout: Duration = .seconds(10),
  _ predicate: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await predicate() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await predicate()
}

// MARK: - Suite

@Suite("Advert push recovery from the RX log copy")
struct AdvertPushRecoveryTests {
  private let radioID = UUID()
  private let signer = Curve25519.Signing.PrivateKey()
  /// A second stored contact whose check marks that the copies before it have been handled.
  private let witness = Curve25519.Signing.PrivateKey()

  private var key: Data {
    signer.publicKey.rawRepresentation
  }

  private struct Harness {
    let session: MockMeshCoreSession
    let store: PersistenceStore
    let service: AdvertisementService
    let sleeper: AdvertGraceTimers
    let rounds: RoundCounter
    let received: AdvertReceivedCounter
  }

  private func makeHarness(
    deviceKey: Data = Data(repeating: 0x01, count: 32),
    storedKeys: [Data]? = nil
  ) async throws -> Harness {
    let store = PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
    try await store.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID, publicKey: deviceKey))
    for stored in storedKeys ?? [key, witness.publicKey.rawRepresentation] {
      _ = try await store.saveContact(radioID: radioID, from: ContactFrame(
        publicKey: stored, type: .chat, flags: 0, outPathLength: 0, outPath: Data(), name: "Stored",
        lastAdvertTimestamp: StockAdverts.storedTimestamp, latitude: 0, longitude: 0, lastModified: 1_700_000_100
      ))
    }
    let session = MockMeshCoreSession()
    let sleeper = AdvertGraceTimers()
    let service = AdvertisementService(
      session: session,
      dataStore: store,
      advertSyncDebounce: .zero,
      advertSyncMinInterval: .zero,
      advertSyncBusyBackoff: .zero,
      advertRecoverySleep: { _ in try await sleeper.sleep() }
    )
    let rounds = RoundCounter()
    await service.setDeltaSyncHandler { _ in await rounds.run() }
    let received = AdvertReceivedCounter()
    let events = service.events()
    Task {
      for await event in events {
        await received.note(event)
      }
    }
    await service.startEventMonitoring(radioID: radioID)
    #expect(await waitUntil { await session.eventSubscriptionCount >= 1 })
    return Harness(session: session, store: store, service: service, sleeper: sleeper, rounds: rounds, received: received)
  }

  private func advert(
    _ signer: Curve25519.Signing.PrivateKey? = nil,
    timestamp: UInt32 = StockAdverts.storedTimestamp + 600,
    name: String? = "Alpine"
  ) throws -> [UInt8] {
    try StockAdverts.payload(signer: signer ?? self.signer, timestamp: timestamp, appData: StockAdverts.appData(name: name))
  }

  /// Yields the witness's copy and waits for its check, so every copy yielded before it has been
  /// handled, then returns the keys with a pending check.
  private func checkedKeys(_ harness: Harness) async throws -> Set<Data> {
    let witnessKey = witness.publicKey.rawRepresentation
    await harness.session.yieldEvent(StockAdverts.event(try advert(witness)))
    #expect(await waitUntil { await harness.service.advertRecoveryTasks[witnessKey] != nil })
    return await Set(harness.service.advertRecoveryTasks.keys)
  }

  private var witnessOnly: Set<Data> {
    [witness.publicKey.rawRepresentation]
  }

  // MARK: Recovery

  @Test
  func `an advert whose 0x80 was dropped runs one contact round after the grace`() async throws {
    let harness = try await makeHarness()
    await harness.session.yieldEvent(StockAdverts.event(try advert()))
    #expect(await waitUntil { await harness.sleeper.waitingCount == 1 })
    #expect(await harness.rounds.rounds == 0, "nothing is done before the grace ends")

    await harness.sleeper.releaseAll()
    #expect(await waitUntil { await harness.rounds.rounds == 1 })
    #expect(await harness.service.recoveredAdvertPushes == 1)
    #expect(await waitUntil { await harness.received.keys == [key] })
    // The node shows as heard now, as the 0x80 would have made it
    let contact = try #require(try await harness.store.fetchContact(radioID: radioID, publicKey: key))
    #expect((contact.lastHeardTimestamp ?? 0) > 0)
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `a 0x80 within the grace means nothing is recovered`() async throws {
    let harness = try await makeHarness()
    await harness.session.yieldEvent(StockAdverts.event(try advert()))
    #expect(await waitUntil { await harness.sleeper.waitingCount == 1 })

    await harness.session.yieldEvent(.advertisement(publicKey: key))
    #expect(await waitUntil { await harness.rounds.rounds == 1 })
    await harness.sleeper.releaseAll()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await harness.service.recoveredAdvertPushes == 0)
    #expect(await harness.rounds.rounds == 1)
    #expect(await harness.received.keys == [key])
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `repeat copies of one advert give one recovery`() async throws {
    let harness = try await makeHarness()
    let payload = try advert()
    await harness.session.yieldEvent(StockAdverts.event(payload))
    // flood repeats of the same advert, relayed by other repeaters
    await harness.session.yieldEvent(StockAdverts.event(payload, path: [0x3A, 0x7F]))
    await harness.session.yieldEvent(StockAdverts.event(payload, path: [0x51]))
    #expect(try await checkedKeys(harness) == witnessOnly.union([key]), "one check for the advert, one for the witness")

    await harness.sleeper.releaseAll()
    #expect(await waitUntil { await harness.service.recoveredAdvertPushes == 2 })
    // A copy heard after the recovery is settled too
    await harness.session.yieldEvent(StockAdverts.event(payload, path: [0x22]))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await harness.sleeper.waitingCount == 0)
    #expect(await harness.service.recoveredAdvertPushes == 2)
    #expect(await harness.received.keys.filter { $0 == key }.count == 1)
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `a late 0x80 after a recovery is not announced again but reads the radio's record`() async throws {
    let harness = try await makeHarness()
    await harness.session.yieldEvent(StockAdverts.event(try advert()))
    #expect(await waitUntil { await harness.sleeper.waitingCount == 1 })
    await harness.sleeper.releaseAll()
    #expect(await waitUntil { await harness.rounds.rounds == 1 })
    let heard = try #require(try await harness.store.fetchContact(radioID: radioID, publicKey: key)?.lastHeardTimestamp)

    // rx_delay_base held the flood back, so the radio updated the contact (and pushed its 0x80)
    // only after that round had read it: the radio's record is read once more.
    await harness.session.yieldEvent(.advertisement(publicKey: key))
    #expect(await waitUntil { await harness.rounds.rounds == 2 })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await harness.rounds.rounds == 2)
    #expect(await harness.received.keys == [key], "the node is counted once")
    let after = try #require(try await harness.store.fetchContact(radioID: radioID, publicKey: key))
    #expect(after.lastHeardTimestamp == heard, "heard when its copy arrived, not when the late push did")
    await harness.service.stopEventMonitoring()
  }

  // MARK: Copies of an advert the radio already pushed

  /// The radio handles only the first copy of an advert (Mesh::onRecvPacket `hasSeen`, by a hash
  /// without the path). When that copy's 0x88 never reached the app (dropped from the full queue,
  /// too long to forward, or held by a Cairn radio for RX_SYNC and released after the 0x80), the
  /// 0x80 arrives with no check pending and a later copy belongs to an advert already handled.
  @Test(arguments: [[UInt8](), [0x3A, 0x7F], [0x51]])
  func `a copy after a 0x80 no check knew is not recovered`(path: [UInt8]) async throws {
    let harness = try await makeHarness()
    await harness.session.yieldEvent(.advertisement(publicKey: key))
    #expect(await waitUntil { await harness.received.keys == [key] })

    // A repeat copy, newer than the stored contact (the delta round hasn't stored it yet)
    await harness.session.yieldEvent(StockAdverts.event(try advert(), path: path))
    #expect(try await checkedKeys(harness) == witnessOnly)
    await harness.sleeper.releaseAll()
    #expect(await waitUntil { await harness.service.recoveredAdvertPushes == 1 }, "the witness only")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await harness.received.keys.filter { $0 == key }.count == 1, "the node is counted once")
    await harness.service.stopEventMonitoring()
  }

  // MARK: Copies the radio answers with no 0x80

  @Test(arguments: [UInt32(0), 1])
  func `a replayed advert is not recovered`(olderBy: UInt32) async throws {
    let harness = try await makeHarness()
    // BaseChatMesh::onAdvertRecv ignores `timestamp <= last_advert_timestamp`
    await harness.session.yieldEvent(StockAdverts.event(try advert(timestamp: StockAdverts.storedTimestamp - olderBy)))
    #expect(try await checkedKeys(harness) == witnessOnly)
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `an advert with a bad signature is not recovered`() async throws {
    let harness = try await makeHarness()
    var payload = try advert()
    payload[40] ^= 0x01 // inside the signature
    await harness.session.yieldEvent(StockAdverts.event(payload))
    #expect(try await checkedKeys(harness) == witnessOnly)
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `a nameless advert is not recovered`() async throws {
    let harness = try await makeHarness()
    await harness.session.yieldEvent(StockAdverts.event(try advert(name: nil)))
    #expect(try await checkedKeys(harness) == witnessOnly)
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `this radio's own advert is not recovered`() async throws {
    let harness = try await makeHarness(deviceKey: key)
    await harness.session.yieldEvent(StockAdverts.event(try advert()))
    #expect(try await checkedKeys(harness) == witnessOnly)
    await harness.service.stopEventMonitoring()
  }

  @Test
  func `an advert from a node that is not a stored contact is not recovered`() async throws {
    let harness = try await makeHarness(storedKeys: [witness.publicKey.rawRepresentation])
    await harness.session.yieldEvent(StockAdverts.event(try advert()))
    #expect(try await checkedKeys(harness) == witnessOnly)
    await harness.service.stopEventMonitoring()
  }

  // MARK: Reading an advert as the radio does

  @Test
  func `a signed advert reads as the radio reads it`() throws {
    let payload = try StockAdverts.payload(
      signer: signer,
      timestamp: 1_700_000_600,
      appData: StockAdverts.appData(type: 2, latLon: (47_123_456, -122_654_321), name: "Ridge")
    )
    let advert = try #require(AdvertPushRecovery.SignedAdvert(payload: Data(payload)))
    #expect(advert.publicKey == key)
    #expect(advert.timestamp == 1_700_000_600)
    #expect(advert.hasName)
    #expect(advert.isSignatureValid)
  }

  @Test
  func `only the first 32 bytes of app data are signed and read`() throws {
    // MAX_ADVERT_DATA_SIZE: a longer tail is neither signed nor read (src/Mesh.cpp onRecvPacket)
    let appData = StockAdverts.appData(name: "N") + [UInt8](repeating: 0x41, count: 40)
    let advert = try #require(AdvertPushRecovery.SignedAdvert(payload: Data(
      try StockAdverts.payload(signer: signer, timestamp: 1_700_000_600, appData: appData)
    )))
    #expect(advert.appData.count == 32)
    #expect(advert.isSignatureValid)
  }

  @Test
  func `a payload shorter than key, time and signature is not an advert`() throws {
    let payload = try StockAdverts.payload(signer: signer, timestamp: 1, appData: [])
    #expect(AdvertPushRecovery.SignedAdvert(payload: Data(payload.dropLast())) == nil)
    let bare = try #require(AdvertPushRecovery.SignedAdvert(payload: Data(payload)))
    // no app data at all: AdvertDataParser is not valid
    #expect(!bare.hasName)
  }

  @Test
  func `a name flag with the position missing is not a name`() throws {
    // flags say position and name, but the data ends inside the position
    let appData: [UInt8] = [0x91, 1, 2, 3]
    let advert = try #require(AdvertPushRecovery.SignedAdvert(payload: Data(
      try StockAdverts.payload(signer: signer, timestamp: 1, appData: appData)
    )))
    #expect(!advert.hasName)
  }

  // MARK: State machine

  @Test
  func `checks settle once and a late push is a duplicate only within the window`() {
    var recovery = AdvertPushRecovery()
    let key = Data(repeating: 0x42, count: 32)
    let start = Date(timeIntervalSince1970: 1_000_000)

    let began = recovery.beginCheck(key: key, timestamp: 10, storedTimestamp: 5, now: start)
    // a newer advert during the grace updates the same check
    let beganAgain = recovery.beginCheck(key: key, timestamp: 11, storedTimestamp: 5, now: start)
    let recovered = recovery.graceEnded(key: key, now: start)
    #expect(began && !beganAgain && recovered)
    #expect(!recovery.needsCheck(key: key, timestamp: 11, now: start))
    #expect(recovery.needsCheck(key: key, timestamp: 12, now: start))
    let late = recovery.notePush(key: key, now: start.addingTimeInterval(39))
    // only one late push is swallowed
    let later = recovery.notePush(key: key, now: start.addingTimeInterval(39))
    #expect(late == .duplicateOfRecovery)
    #expect(later == .unrelated)

    let other = Data(repeating: 0x43, count: 32)
    _ = recovery.beginCheck(key: other, timestamp: 20, storedTimestamp: 11, now: start)
    _ = recovery.graceEnded(key: other, now: start)
    let outsideWindow = recovery.notePush(key: other, now: start.addingTimeInterval(41))
    #expect(outsideWindow == .unrelated)

    let third = Data(repeating: 0x44, count: 32)
    _ = recovery.beginCheck(key: third, timestamp: 30, storedTimestamp: 20, now: start)
    let answered = recovery.notePush(key: third, now: start)
    let recoveredAfterAnswer = recovery.graceEnded(key: third, now: start)
    #expect(answered == .answeredCheck)
    #expect(!recoveredAfterAnswer)
    let stale = recovery.beginCheck(key: third, timestamp: 30, storedTimestamp: 20, now: start)
    #expect(!stale, "an answered advert is settled")
    let newer = recovery.beginCheck(key: third, timestamp: 31, storedTimestamp: 20, now: start)
    #expect(newer, "an answered push says nothing about a newer advert")
  }

  @Test
  func `a push no check knew settles the copies that follow it within the window`() {
    var recovery = AdvertPushRecovery()
    let key = Data(repeating: 0x45, count: 32)
    let start = Date(timeIntervalSince1970: 1_000_000)

    let push = recovery.notePush(key: key, now: start)
    #expect(push == .unrelated)
    #expect(!recovery.needsCheck(key: key, timestamp: 10, now: start.addingTimeInterval(1)))
    let began = recovery.beginCheck(key: key, timestamp: 10, storedTimestamp: 5, now: start.addingTimeInterval(39))
    #expect(!began, "a copy of the advert the radio already handled")

    // After the window the next copy is a new advert's
    #expect(recovery.needsCheck(key: key, timestamp: 10, now: start.addingTimeInterval(40)))
    let later = recovery.beginCheck(key: key, timestamp: 10, storedTimestamp: 5, now: start.addingTimeInterval(40))
    #expect(later)
    // Another node is not affected
    #expect(recovery.needsCheck(key: Data(repeating: 0x46, count: 32), timestamp: 10, now: start))
  }
}
