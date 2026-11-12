import Foundation
@testable import CairnServices
import MeshCore

/// The observed nodes a ``MockPersistenceStore`` holds, by radio and channel key. Kept beside the
/// mock (an extension can't add stored properties) and only touched from the mock's isolation.
final class MockObservationStorage: @unchecked Sendable {
  var nodes: [UUID: [ChannelKey: [ObservedIdentity: ObservedNode]]] = [:]
  /// Every `saveObservedNodes` call, for assertion.
  var saveCalls: [(radioID: UUID, channelKey: ChannelKey, upserted: Int, removed: Int)] = []
}

/// Each live mock's storage. The store is held weakly, so a new mock that reuses a freed one's
/// address starts empty, and storage of freed mocks is dropped.
private final class MockObservationRegistry: @unchecked Sendable {
  static let shared = MockObservationRegistry()

  private struct Slot {
    weak var store: MockPersistenceStore?
    let storage: MockObservationStorage
  }

  private let lock = NSLock()
  private var slots: [ObjectIdentifier: Slot] = [:]

  func storage(for store: MockPersistenceStore) -> MockObservationStorage {
    lock.withLock {
      let id = ObjectIdentifier(store)
      if let slot = slots[id], slot.store === store {
        return slot.storage
      }
      slots = slots.filter { $0.value.store != nil }
      let storage = MockObservationStorage()
      slots[id] = Slot(store: store, storage: storage)
      return storage
    }
  }
}

extension MockPersistenceStore: ObservationPersisting {
  /// This store's observed nodes, created on first use.
  var observationStorage: MockObservationStorage {
    MockObservationRegistry.shared.storage(for: self)
  }

  /// Every stored node of one radio on one channel, most recently observed first.
  public func fetchObservedNodes(radioID: UUID, channelKey: ChannelKey) async throws -> [ObservedNode] {
    (observationStorage.nodes[radioID]?[channelKey] ?? [:]).values.sorted { $0.lastObservedAt > $1.lastObservedAt }
  }

  public func saveObservedNodes(
    radioID: UUID,
    channelKey: ChannelKey,
    upserting nodes: [ObservedNode],
    removing identities: [ObservedIdentity]
  ) async throws {
    let storage = observationStorage
    storage.saveCalls.append((radioID, channelKey, nodes.count, identities.count))
    var rows = storage.nodes[radioID]?[channelKey] ?? [:]
    for identity in identities {
      rows.removeValue(forKey: identity)
    }
    for node in nodes {
      rows[node.identity] = node
    }
    storage.nodes[radioID, default: [:]][channelKey] = rows
  }

  @discardableResult
  public func pruneObservedNodes(radioID: UUID, notObservedSince date: Date) async throws -> Int {
    let storage = observationStorage
    var deleted = 0
    for (channelKey, rows) in storage.nodes[radioID] ?? [:] {
      let kept = rows.filter { $0.value.lastObservedAt >= date }
      deleted += rows.count - kept.count
      storage.nodes[radioID]?[channelKey] = kept
    }
    return deleted
  }

  public func clearObservedNodes(radioID: UUID) async throws {
    observationStorage.nodes[radioID] = nil
  }

  /// The observed nodes stored for one radio on one channel, for assertion.
  func storedObservedNodes(radioID: UUID, channelKey: ChannelKey) -> [ObservedIdentity: ObservedNode] {
    observationStorage.nodes[radioID]?[channelKey] ?? [:]
  }

  /// How many times `saveObservedNodes` ran.
  var observedNodeSaveCount: Int {
    observationStorage.saveCalls.count
  }
}
