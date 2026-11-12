import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// Proves the funnel invariants the leave-room `UICollectionView` assertion reduces
/// to: a stale reload suspended mid-fetch never commits after a fresher one, an
/// optimistically removed row stays hidden across a stale reload and self-heals, and
/// the cache→snapshot port preserves the filter/partition/sort semantics verbatim.
@Suite("ChatViewModel reload serialization")
@MainActor
struct ChatViewModelReloadSerializationTests {
  // MARK: - Fixtures

  private func makeContact(
    id: UUID = UUID(),
    radioID: UUID,
    name: String,
    type: ContactType = .chat,
    isFavorite: Bool = false,
    isBlocked: Bool = false,
    lastMessageDate: Date? = Date()
  ) -> ContactDTO {
    ContactDTO(
      id: id,
      radioID: radioID,
      publicKey: Data(repeating: UInt8(truncatingIfNeeded: id.hashValue), count: 32),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: isBlocked,
      isMuted: false,
      isFavorite: isFavorite,
      lastMessageDate: lastMessageDate,
      unreadCount: 0
    )
  }

  private func makeRoom(
    id: UUID = UUID(),
    radioID: UUID = UUID(),
    name: String = "Room",
    isFavorite: Bool = false,
    lastMessageDate: Date? = Date()
  ) -> RemoteNodeSessionDTO {
    RemoteNodeSessionDTO(
      id: id,
      radioID: radioID,
      publicKey: Data(repeating: UInt8(truncatingIfNeeded: id.hashValue), count: 32),
      name: name,
      role: .roomServer,
      isConnected: true,
      isFavorite: isFavorite,
      lastMessageDate: lastMessageDate
    )
  }

  private func makeChannel(
    id: UUID = UUID(),
    radioID: UUID = UUID(),
    index: UInt8 = 0,
    name: String,
    secret: Data = Data(),
    isFavorite: Bool = false,
    lastMessageDate: Date? = Date()
  ) -> ChannelDTO {
    ChannelDTO(
      id: id,
      radioID: radioID,
      index: index,
      name: name,
      secret: secret,
      isEnabled: true,
      lastMessageDate: lastMessageDate,
      unreadCount: 0,
      unreadMentionCount: 0,
      notificationLevel: .all,
      isFavorite: isFavorite
    )
  }

  // MARK: - Serialization

  /// Reload #1 suspends in the interleave hook; a request arriving meanwhile doesn't cancel it
  /// or start a racing pass: it marks #1 to run once more, and that pass commits the newer
  /// state. Passes never interleave, so a stale fetch can't commit after a fresher one.
  @Test func `reload requested mid-pass runs once more and commits the newer state`() async throws {
    let radioID = UUID()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)

    var contacts: [ContactDTO] = []
    for index in 0..<12 {
      let contact = makeContact(radioID: radioID, name: "C\(index)")
      contacts.append(contact)
      try await store.saveContact(contact)
    }
    let last = contacts[11]

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(
      dataStore: { store },
      currentRadioID: { radioID }
    ))

    let arrived = AsyncGate()
    let gate = AsyncGate()
    viewModel.reloadInterleaveHook = {
      await arrived.open() // signal reload #1 reached the hook
      await gate.wait() // then suspend until the test opens the gate
    }

    let task1 = viewModel.requestConversationReload()
    await arrived.wait() // reload #1 is now parked at the gate

    viewModel.reloadInterleaveHook = nil
    try await store.deleteContact(id: last.id)
    let task2 = viewModel.requestConversationReload()
    #expect(task2 == task1, "a request mid-pass joins the pass in flight")

    await gate.open() // #1 commits its 12-row fetch, then runs the pass #2 asked for
    await task2?.value

    #expect(viewModel.hasLoadedOnce)
    #expect(viewModel.conversationSnapshot.others.count == 11)
    #expect(viewModel.allConversations.allSatisfy { $0.id != last.id })
  }

  /// A storm of requests (every message and advert on a busy mesh) used to cancel each pass
  /// before it committed, so the list never loaded. Now the first pass commits and the storm
  /// folds into one more.
  @Test func `request storm commits and folds into one extra pass`() async throws {
    let radioID = UUID()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    try await store.saveContact(makeContact(radioID: radioID, name: "Bob"))

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(
      dataStore: { store },
      currentRadioID: { radioID }
    ))

    let passes = PassCounter()
    viewModel.reloadInterleaveHook = { [weak viewModel] in
      // The storm lands while the first pass is mid-fetch.
      if await passes.increment() == 1 {
        for _ in 0..<50 {
          viewModel?.requestConversationReload()
        }
      }
    }

    let first = viewModel.requestConversationReload()
    await first?.value

    #expect(viewModel.hasLoadedOnce)
    #expect(viewModel.conversationSnapshot.others.map(\.displayName) == ["Bob"])
    #expect(await passes.count == 2)
  }

  /// No radio paired: the list shows its empty state instead of a spinner forever.
  @Test func `no radio ends loading with an empty list`() {
    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(
      dataStore: { nil },
      currentRadioID: { nil }
    ))

    #expect(viewModel.requestConversationReload() == nil)
    #expect(viewModel.hasLoadedOnce)
    #expect(viewModel.allConversations.isEmpty)
  }

  /// A radio ID but no store yet (persisted radio, store not open): also not a spinner.
  @Test func `no store ends loading`() async {
    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(
      dataStore: { nil },
      currentRadioID: { UUID() }
    ))

    await viewModel.requestConversationReload()?.value
    #expect(viewModel.hasLoadedOnce)
  }

  // MARK: - Optimistic delete

  @Test func `deleted row does not reappear on stale reload`() {
    let room = makeRoom(name: "Room")
    let viewModel = ChatViewModel()
    viewModel.roomSessions = [room]
    viewModel.recomputeSnapshot()

    viewModel.removeConversation(.room(room))
    #expect(viewModel.allConversations.allSatisfy { $0.id != room.id })
    #expect(viewModel.pendingRemovalIDs.contains(room.id))

    // A stale reload still returns the room (pre-commit reconcile + recompute):
    viewModel.roomSessions = [room]
    viewModel.reconcilePendingRemovals()
    viewModel.recomputeSnapshot()
    #expect(viewModel.allConversations.allSatisfy { $0.id != room.id }) // still hidden
    #expect(viewModel.pendingRemovalIDs.contains(room.id)) // still pending

    // The confirming reload no longer returns the room → self-heal:
    viewModel.roomSessions = []
    viewModel.reconcilePendingRemovals()
    viewModel.recomputeSnapshot()
    #expect(viewModel.pendingRemovalIDs.isEmpty)
  }

  // MARK: - Filters / partition / sort

  @Test func `filters preserved and partitioned`() {
    let radioID = UUID()
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)

    let favNewer = makeContact(radioID: radioID, name: "FavNewer", isFavorite: true, lastMessageDate: newer)
    let favOlder = makeContact(radioID: radioID, name: "FavOlder", isFavorite: true, lastMessageDate: older)
    let plain = makeContact(radioID: radioID, name: "Plain", lastMessageDate: newer)
    let repeaterContact = makeContact(radioID: radioID, name: "Repeater", type: .repeater)
    let blockedContact = makeContact(radioID: radioID, name: "Blocked", isBlocked: true)

    let viewModel = ChatViewModel()
    viewModel.conversations = [favOlder, plain, repeaterContact, blockedContact, favNewer]
    viewModel.channels = [makeChannel(radioID: radioID, name: "")] // empty-name, secretless → excluded
    viewModel.recomputeSnapshot()

    // Repeater, blocked, and empty-name secretless channel excluded.
    let names = viewModel.allConversations.map(\.displayName)
    #expect(!names.contains("Repeater"))
    #expect(!names.contains("Blocked"))
    #expect(viewModel.allConversations.count == 3)

    // Favorites partitioned first, each partition sorted by lastMessageDate descending.
    #expect(viewModel.favoriteConversations.map(\.displayName) == ["FavNewer", "FavOlder"])
    #expect(viewModel.nonFavoriteConversations.map(\.displayName) == ["Plain"])
  }
}

/// Minimal continuation-backed gate. Used both as the reload-arrival signal and as
/// the suspend point that holds reload #1 until the fresher reload has committed.
private actor AsyncGate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var opened = false

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func open() {
    opened = true
    waiter?.resume()
    waiter = nil
  }
}

/// Counts reload passes from the interleave hook.
private actor PassCounter {
  private(set) var count = 0

  func increment() -> Int {
    count += 1
    return count
  }
}
