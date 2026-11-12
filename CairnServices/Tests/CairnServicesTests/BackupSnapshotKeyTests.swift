import Foundation
@testable import CairnServices
import Testing

/// A backup file can carry any JSON number as a snapshot date, so building the
/// reconciliation key must not trap on one outside the `Int` millisecond range.
@Suite("Backup node status snapshot key")
struct BackupSnapshotKeyTests {
  private static let nodePublicKey = Data(repeating: 0xDD, count: 32)

  @Test(arguments: [1e300, -1e300, Double.greatestFiniteMagnitude, Double.infinity, -Double.infinity, Double.nan])
  func `an out-of-range date yields a key instead of trapping`(seconds: Double) async throws {
    let store = try await PersistenceStore.createTestDataStore(radioID: UUID())

    let key = await store.nodeStatusSnapshotKey(
      nodePublicKey: Self.nodePublicKey,
      timestamp: Date(timeIntervalSince1970: seconds)
    )

    #expect(key.hasPrefix(Self.nodePublicKey.base64EncodedString() + "-"))
  }

  @Test
  func `an in-range date keeps its truncated millisecond key`() async throws {
    let store = try await PersistenceStore.createTestDataStore(radioID: UUID())

    let key = await store.nodeStatusSnapshotKey(
      nodePublicKey: Self.nodePublicKey,
      timestamp: Date(timeIntervalSince1970: 1_700_000_000.5)
    )
    let beforeEpoch = await store.nodeStatusSnapshotKey(
      nodePublicKey: Self.nodePublicKey,
      timestamp: Date(timeIntervalSince1970: -1.5)
    )

    #expect(key == Self.nodePublicKey.base64EncodedString() + "-1700000000500")
    #expect(beforeEpoch == Self.nodePublicKey.base64EncodedString() + "--1500")
  }

  @Test
  func `importing a snapshot with an out-of-range date does not trap`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let snapshot = NodeStatusSnapshotDTO.testSnapshot(
      timestamp: Date(timeIntervalSince1970: 1e300),
      nodePublicKey: Self.nodePublicKey
    )
    let envelope = AppBackupEnvelope.test(
      devices: [DeviceDTO.testDevice(id: radioID, radioID: radioID)],
      nodeStatusSnapshots: [snapshot]
    )

    let result = try await AppBackupService().importBackup(envelope: envelope, into: store)

    #expect(result.nodeStatusSnapshotsInserted + result.nodeStatusSnapshotsSkipped == 1)
  }
}
