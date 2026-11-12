import CoreLocation
@testable import Cairn
@testable import CairnServices
import Testing

// MARK: - Mock Elevation Service

actor MockElevationService: ElevationServiceProtocol {
  var elevationToReturn: Double = 100
  var shouldFail = false
  var fetchCount = 0
  var profileToReturn: [ElevationSample]?

  /// Optional delay before each fetch resolves, used to keep a fetch in flight
  /// long enough for a test to cancel or supersede it.
  var fetchDelay: Duration = .zero

  func fetchElevation(at coordinate: CLLocationCoordinate2D) async throws -> Double {
    fetchCount += 1
    if fetchDelay != .zero {
      try await Task.sleep(for: fetchDelay)
    }
    if shouldFail {
      throw ElevationServiceError.noData
    }
    return elevationToReturn
  }

  func fetchElevations(along path: [CLLocationCoordinate2D]) async throws -> [ElevationSample] {
    fetchCount += 1
    if fetchDelay != .zero {
      try await Task.sleep(for: fetchDelay)
    }
    if shouldFail {
      throw ElevationServiceError.noData
    }

    if let profile = profileToReturn {
      return profile
    }

    // Generate default samples with flat terrain
    var samples: [ElevationSample] = []
    let startCoord = path.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)

    for (index, coord) in path.enumerated() {
      let distance = index == 0 ? 0 : RFCalculator.distance(from: startCoord, to: coord)
      samples.append(ElevationSample(
        coordinate: coord,
        elevation: elevationToReturn,
        distanceFromAMeters: distance
      ))
    }

    return samples
  }

  func reset() {
    elevationToReturn = 100
    shouldFail = false
    fetchCount = 0
    profileToReturn = nil
    fetchDelay = .zero
  }

  func setFailure(_ fail: Bool) {
    shouldFail = fail
  }

  func setFetchDelay(_ delay: Duration) {
    fetchDelay = delay
  }
}

// MARK: - Mock Persistence Store

actor MockPersistenceStore: PersistenceStoreProtocol {
  var contacts: [UUID: ContactDTO] = [:]
  var discoveredNodes: [UUID: DiscoveredNodeDTO] = [:]

  func fetchContacts(radioID: UUID) async throws -> [ContactDTO] {
    Array(contacts.values.filter { $0.radioID == radioID })
  }

  func addContact(_ contact: ContactDTO) {
    contacts[contact.id] = contact
  }

  func addDiscoveredNode(_ node: DiscoveredNodeDTO) {
    discoveredNodes[node.id] = node
  }

  func reset() {
    contacts = [:]
    discoveredNodes = [:]
  }

  // MARK: - Unused Protocol Requirements (stubs)

  func saveMessage(_ dto: MessageDTO) async throws {}
  func fetchMessage(id: UUID) async throws -> MessageDTO? {
    nil
  }

  func fetchMessages(contactID: UUID, limit: Int, offset: Int) async throws -> [MessageDTO] {
    []
  }

  func searchMessages(contactID: UUID, query: String, limit: Int) async throws -> [MessageDTO] {
    []
  }

  func searchMessages(radioID: UUID, channelIndex: UInt8, query: String, limit: Int) async throws -> [MessageDTO] {
    []
  }

  func fetchMessages(radioID: UUID, channelIndex: UInt8, limit: Int, offset: Int) async throws -> [MessageDTO] {
    []
  }

  func fetchMessageWindow(
    contactID: UUID,
    anchorSortDate: Date?,
    floorLimit: Int
  ) async throws -> (messages: [MessageDTO], hasMore: Bool) {
    ([], false)
  }

  func fetchMessageWindow(
    radioID: UUID,
    channelIndex: UInt8,
    anchorSortDate: Date?,
    floorLimit: Int
  ) async throws -> (messages: [MessageDTO], hasMore: Bool) {
    ([], false)
  }

  func fetchLastMessages(contactIDs: [UUID], limit: Int) throws -> [UUID: [MessageDTO]] {
    [:]
  }

  func fetchLastChannelMessages(channels: [(radioID: UUID, channelIndex: UInt8, id: UUID)], limit: Int) throws -> [UUID: [MessageDTO]] {
    [:]
  }

  func deleteMessagesForContact(contactID: UUID) async throws {}
  func updateMessageStatus(id: UUID, status: MessageStatus) async throws {}
  func updateMessageAck(id: UUID, ackCode: UInt32, status: MessageStatus, roundTripTime: UInt32?) async throws {}
  func updateMessageRetryStatus(id: UUID, status: MessageStatus, retryAttempt: Int, maxRetryAttempts: Int) async throws {}
  func updateMessageHeardRepeats(id: UUID, heardRepeats: Int) async throws {}
  func fetchConversations(radioID: UUID) async throws -> [ContactDTO] {
    []
  }

  func fetchContact(id: UUID) async throws -> ContactDTO? {
    nil
  }

  func fetchContact(radioID: UUID, publicKey: Data) async throws -> ContactDTO? {
    nil
  }

  func fetchContact(radioID: UUID, publicKeyPrefix: Data) async throws -> ContactDTO? {
    nil
  }

  @discardableResult func saveContact(radioID: UUID, from frame: ContactFrame) async throws -> (id: UUID, isNew: Bool) {
    (id: UUID(), isNew: true)
  }

  func saveContact(_ dto: ContactDTO) async throws {}
  func deleteContact(id: UUID) async throws {}
  @discardableResult
  func touchContactHeard(radioID: UUID, publicKey: Data, at date: Date) async throws -> Bool {
    false
  }

  func updateContactLastMessage(contactID: UUID, date: Date?) async throws {}
  func incrementUnreadCount(contactID: UUID) async throws {}
  func clearUnreadCount(contactID: UUID) async throws {}
  func markMentionSeen(messageID: UUID) async throws {}
  func incrementUnreadMentionCount(contactID: UUID) async throws {}
  func decrementUnreadMentionCount(contactID: UUID) async throws {}
  func clearUnreadMentionCount(contactID: UUID) async throws {}
  func incrementChannelUnreadMentionCount(channelID: UUID) async throws {}
  func decrementChannelUnreadMentionCount(channelID: UUID) async throws {}
  func clearChannelUnreadMentionCount(channelID: UUID) async throws {}
  func fetchUnseenMentionIDs(contactID: UUID) async throws -> [UUID] {
    []
  }

  func fetchUnseenChannelMentionIDs(radioID: UUID, channelIndex: UInt8) async throws -> [UUID] {
    []
  }

  func fetchBlockedContacts(radioID: UUID) async throws -> [ContactDTO] {
    []
  }

  func saveBlockedChannelSender(_ dto: BlockedChannelSenderDTO) async throws {}
  func deleteBlockedChannelSender(radioID: UUID, name: String) async throws {}
  func deleteChannelMessages(fromSender senderName: String, radioID: UUID) async throws {}
  func fetchBlockedChannelSenders(radioID: UUID) async throws -> [BlockedChannelSenderDTO] {
    []
  }

  func fetchChannels(radioID: UUID) async throws -> [ChannelDTO] {
    []
  }

  func fetchChannel(radioID: UUID, index: UInt8) async throws -> ChannelDTO? {
    nil
  }

  func fetchChannel(id: UUID) async throws -> ChannelDTO? {
    nil
  }

  @discardableResult func saveChannel(radioID: UUID, from info: ChannelInfo) async throws -> UUID {
    UUID()
  }

  func saveChannel(_ dto: ChannelDTO) async throws {}
  func deleteChannel(id: UUID) async throws {}
  func updateChannelLastMessage(channelID: UUID, date: Date?) async throws {}
  func incrementChannelUnreadCount(channelID: UUID) async throws {}
  func clearChannelUnreadCount(channelID: UUID) async throws {}
  func clearChannelUnreadCount(radioID: UUID, index: UInt8) async throws {}
  func fetchSavedTracePaths(radioID: UUID) async throws -> [SavedTracePathDTO] {
    []
  }

  func fetchSavedTracePath(id: UUID) async throws -> SavedTracePathDTO? {
    nil
  }

  func createSavedTracePath(radioID: UUID, name: String, pathBytes: Data, hashSize: Int, initialRun: TracePathRunDTO?) async throws -> SavedTracePathDTO {
    SavedTracePathDTO(id: UUID(), radioID: radioID, name: name, pathBytes: pathBytes, hashSize: hashSize, createdDate: Date(), runs: [])
  }

  func updateSavedTracePathName(id: UUID, name: String) async throws {}
  func deleteSavedTracePath(id: UUID) async throws {}
  func appendTracePathRun(pathID: UUID, run: TracePathRunDTO) async throws {}

  // MARK: - Heard Repeats (stubs)

  func findSentChannelMessage(radioID: UUID, channelIndex: UInt8, timestamp: UInt32, text: String) async throws -> MessageDTO? {
    nil
  }

  func saveMessageRepeat(_ dto: MessageRepeatDTO) async throws {}
  func fetchMessageRepeats(messageID: UUID) async throws -> [MessageRepeatDTO] {
    []
  }

  func messageRepeatExists(rxLogEntryID: UUID) async throws -> Bool {
    false
  }

  func incrementMessageHeardRepeats(id: UUID) async throws -> Int {
    0
  }

  func adoptIncomingPathIfUnknown(id: UUID, pathNodes: Data, pathLength: UInt8) async throws -> Bool {
    false
  }

  func deleteMessageRepeats(messageID: UUID) async throws {}
  func incrementMessageSendCount(id: UUID) async throws -> Int {
    0
  }

  func updateMessageTimestamp(id: UUID, timestamp: UInt32) async throws {}

  // MARK: - Debug Log (stubs)

  func saveDebugLogEntries(_ dtos: [DebugLogEntryDTO]) async throws {}
  func fetchDebugLogEntries(since date: Date, limit: Int) async throws -> [DebugLogEntryDTO] {
    []
  }

  func countDebugLogEntries() async throws -> Int {
    0
  }

  func pruneDebugLogEntries(olderThan cutoff: Date, keepCount: Int) async throws {}
  func clearDebugLogEntries() async throws {}

  // MARK: - Link Preview (stubs)

  func fetchLinkPreview(url: String) async throws -> LinkPreviewDataDTO? {
    nil
  }

  func saveLinkPreview(_ dto: LinkPreviewDataDTO) async throws {}

  // MARK: - Contact Public Keys (stubs)

  func fetchContactPublicKeysByPrefix(radioID: UUID) async throws -> [UInt8: [Data]] {
    [:]
  }

  // MARK: - RxLogEntry Lookup (stubs)

  func findRxLogEntry(radioID: UUID, channelIndex: UInt8?, senderTimestamp: UInt32) async throws -> RxLogEntryDTO? {
    nil
  }

  func fetchRxLogEntries(
    radioID: UUID,
    channelIndex: UInt8,
    senderTimestamp: UInt32
  ) async throws -> [RxLogEntryDTO] {
    []
  }

  func findRxLogEntryBySenderPrefix(radioID: UUID, senderPrefixByte: UInt8, receivedSince: Date) async throws -> RxLogEntryDTO? {
    nil
  }

  // MARK: - Room Message Operations (stubs)

  func saveRoomMessage(_ dto: RoomMessageDTO) async throws {}
  func fetchRoomMessage(id: UUID) async throws -> RoomMessageDTO? {
    nil
  }

  func fetchRoomMessages(sessionID: UUID, limit: Int?, offset: Int?) async throws -> [RoomMessageDTO] {
    []
  }

  func isDuplicateMessage(deduplicationKey: String, radioID: UUID) async throws -> Bool {
    false
  }

  func fetchMessage(deduplicationKey: String, radioID: UUID) async throws -> MessageDTO? {
    nil
  }

  func isDuplicateRoomMessage(sessionID: UUID, deduplicationKey: String) async throws -> Bool {
    false
  }

  func updateRoomMessageStatus(id: UUID, status: MessageStatus, ackCode: UInt32?, roundTripTime: UInt32?) async throws {}
  func updateRoomMessageRetryStatus(id: UUID, status: MessageStatus, retryAttempt: Int, maxRetryAttempts: Int) async throws {}
  func updateRoomActivity(_ sessionID: UUID, syncTimestamp: UInt32?) async throws {}

  // MARK: - Discovered Nodes (stubs)

  func upsertDiscoveredNode(radioID: UUID, from frame: ContactFrame) async throws -> (node: DiscoveredNodeDTO, isNew: Bool) {
    fatalError("Not implemented")
  }

  func setInboundHopCount(radioID: UUID, publicKey: Data, hopCount: Int, advertTimestamp: UInt32?) async throws {}
  func fetchDiscoveredNodes(radioID: UUID) async throws -> [DiscoveredNodeDTO] {
    Array(discoveredNodes.values.filter { $0.radioID == radioID })
  }

  func deleteDiscoveredNode(id: UUID) async throws {}
  func clearDiscoveredNodes(radioID: UUID) async throws {}
  func fetchContactPublicKeys(radioID: UUID) async throws -> Set<Data> {
    Set()
  }

  // MARK: - Reactions (stubs)

  func fetchReactions(for messageID: UUID, limit: Int) async throws -> [ReactionDTO] {
    []
  }

  func saveReaction(_ dto: ReactionDTO) async throws {}
  func reactionExists(messageID: UUID, senderName: String, emoji: String) async throws -> Bool {
    false
  }

  func updateMessageReactionSummary(messageID: UUID, summary: String?) async throws {}
  func deleteReactionsForMessage(messageID: UUID) async throws {}
  func findChannelMessageForReaction(radioID: UUID, channelIndex: UInt8, parsedReaction: ParsedReaction, localNodeName: String?, timestampWindow: ClosedRange<UInt32>, limit: Int) async throws -> MessageDTO? {
    nil
  }

  func fetchChannelMessageCandidates(radioID: UUID, channelIndex: UInt8, timestampWindow: ClosedRange<UInt32>, limit: Int) async throws -> [MessageDTO] {
    []
  }

  func fetchDMMessageCandidates(radioID: UUID, contactID: UUID, timestampWindow: ClosedRange<UInt32>, limit: Int) async throws -> [MessageDTO] {
    []
  }

  func findDMMessageForReaction(radioID: UUID, contactID: UUID, messageHash: String, timestampWindow: ClosedRange<UInt32>, limit: Int) async throws -> MessageDTO? {
    nil
  }

  // MARK: - Notification Level (stubs)

  func setChannelNotificationLevel(_ channelID: UUID, level: NotificationLevel) async throws {}
  func setAllChannelsNotificationLevel(radioID: UUID, level: NotificationLevel) async throws {}
  func setSessionNotificationLevel(_ sessionID: UUID, level: NotificationLevel) async throws {}
  func fetchDevice(id: UUID) async throws -> DeviceDTO? {
    nil
  }

  func fetchDevice(radioID: UUID) async throws -> DeviceDTO? {
    nil
  }

  func updateDeviceLastContactSync(radioID: UUID, timestamp: UInt32) async throws {}
  func fetchRemoteNodeSession(id: UUID) async throws -> RemoteNodeSessionDTO? {
    nil
  }

  func fetchRemoteNodeSession(publicKey: Data) async throws -> RemoteNodeSessionDTO? {
    nil
  }

  func markSessionDisconnected(_ sessionID: UUID) async throws {}
  func markRoomSessionConnected(_ sessionID: UUID) async throws -> Bool {
    false
  }

  func updateMessageStatusUnlessDelivered(id: UUID, status: MessageStatus) async throws -> Bool {
    false
  }

  func clearRetryingToSent(id: UUID) async throws -> Bool {
    false
  }

  func hasOutgoingSentDM(ackCode: UInt32) async throws -> Bool {
    false
  }

  func markMessageAsRead(id: UUID) async throws {}
  func incrementPendingSendAttemptCount(messageID: UUID) async throws -> Int? {
    nil
  }

  func saveDevice(_ dto: DeviceDTO) async throws {}
  func fetchRemoteNodeSessionByPrefix(_ prefix: Data) async throws -> RemoteNodeSessionDTO? {
    nil
  }

  func fetchRemoteNodeSessions(radioID: UUID) async throws -> [RemoteNodeSessionDTO] {
    []
  }

  func fetchConnectedRemoteNodeSessions() async throws -> [RemoteNodeSessionDTO] {
    []
  }

  func saveRemoteNodeSessionDTO(_ dto: RemoteNodeSessionDTO) async throws {}
  func updateRemoteNodeSessionConnection(id: UUID, isConnected: Bool, permissionLevel: RoomPermissionLevel) async throws {}
  func cleanupDuplicateRemoteNodeSessions(publicKey: Data, keepID: UUID) async throws {}
  func deleteRemoteNodeSession(id: UUID) async throws {}
  func incrementRoomUnreadCount(_ sessionID: UUID) async throws {}
  func resetRoomUnreadCount(_ sessionID: UUID) async throws {}
  func deleteRoomMessages(sessionID: UUID) async throws {}
  func findContactByPublicKey(_ publicKey: Data) async throws -> ContactDTO? {
    nil
  }

  func findContactNameByKeyPrefix(_ prefix: Data) async throws -> String? {
    nil
  }

  func saveRxLogEntry(_ dto: RxLogEntryDTO) async throws {}
  func fetchRxLogEntries(radioID: UUID, limit: Int) async throws -> [RxLogEntryDTO] {
    []
  }

  func clearRxLogEntries(radioID: UUID) async throws {}
  func pruneRxLogEntries(radioID: UUID, keepCount: Int, pruneThreshold: Int) async throws {}
  func fetchEntriesWithTransportCode(radioID: UUID, limit: Int) async throws -> [RxLogEntryDTO] {
    []
  }

  func fetchRecentEntriesByDecryptStatus(radioID: UUID, status: DecryptStatus, since: Date) async throws -> [RxLogEntryDTO] {
    []
  }

  func batchUpdateRxLogRegion(updates: [(id: UUID, regionScope: String?, regionScopeMatches: [String])]) async throws {}
  func batchUpdateRxLogDecryption(_ updates: [(id: UUID, channelIndex: UInt8?, channelName: String?, senderTimestamp: UInt32?)]) async throws {}
  @discardableResult
  func batchUpdateChannelMessageRegion(radioID: UUID, updates: [(channelIndex: UInt8, senderTimestamp: UInt32, regionScope: String?, regionScopeMatches: [String])]) async throws -> [UUID] {
    []
  }

  @discardableResult
  func batchUpdateDMMessageRegion(radioID: UUID, updates: [(senderPrefixByte: UInt8, senderTimestamp: UInt32, regionScope: String?, regionScopeMatches: [String])]) async throws -> [UUID] {
    []
  }

  // MARK: - Channel Message Deletion (stubs)

  func deleteMessagesForChannel(radioID: UUID, channelIndex: UInt8) async throws {}

  // MARK: - Node Status Snapshots (stubs)

  // swiftlint:disable:next function_parameter_count
  func saveNodeStatusSnapshot(
    nodePublicKey: Data,
    batteryMillivolts: UInt16?,
    lastSNR: Double?,
    lastRSSI: Int16?,
    noiseFloor: Int16?,
    uptimeSeconds: UInt32?,
    rxAirtimeSeconds: UInt32?,
    packetsSent: UInt32?,
    packetsReceived: UInt32?,
    receiveErrors: UInt32?,
    postedCount: UInt16?,
    postPushCount: UInt16?
  ) async throws -> UUID {
    UUID()
  }

  func fetchLatestNodeStatusSnapshot(nodePublicKey: Data) async throws -> NodeStatusSnapshotDTO? {
    nil
  }

  func fetchNodeStatusSnapshots(nodePublicKey: Data, since: Date?) async throws -> [NodeStatusSnapshotDTO] {
    []
  }

  func updateSnapshotNeighbors(id: UUID, neighbors: [NeighborSnapshotEntry]) async throws {}
  func updateSnapshotTelemetry(id: UUID, telemetry: [TelemetrySnapshotEntry]) async throws {}
  func recordNodeStatusSnapshot(nodePublicKey: Data, status: NodeStatusMetrics?, telemetry: [TelemetrySnapshotEntry]?, neighbors: [NeighborSnapshotEntry]?, location: NodeLocationFix?) async throws -> UUID {
    UUID()
  }

  func saveTelemetryOnlySnapshot(nodePublicKey: Data, telemetryEntries: [TelemetrySnapshotEntry]) async throws -> UUID {
    UUID()
  }

  func deleteOldNodeStatusSnapshots(olderThan date: Date) async throws {}

  // MARK: - Pending Sends (stubs)

  func upsertPendingSend(_ dto: PendingSendDTO) async throws {}
  func insertPendingSendAssigningSequence(_ dto: PendingSendDTO) async throws -> Int {
    0
  }

  func fetchPendingSends(radioID: UUID) async throws -> [PendingSendDTO] {
    []
  }

  func deletePendingSend(id: UUID) async throws {}
  func deletePendingSendsForMessage(messageID: UUID) async throws {}
  func hasPendingSend(messageID: UUID) async throws -> Bool {
    false
  }
}

// MARK: - Test Helpers

private let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
private let oakland = CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712)
private let berkeley = CLLocationCoordinate2D(latitude: 37.8716, longitude: -122.2727)

private func createTestContact(
  name: String = "Test Contact",
  latitude: Double = 37.7749,
  longitude: Double = -122.4194,
  type: ContactType = .chat,
  radioID: UUID = UUID(),
  publicKey: Data = Data([0xAB] + Array(repeating: UInt8(0x00), count: 31)),
  isFavorite: Bool = false
) -> ContactDTO {
  ContactDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: publicKey,
    name: name,
    typeRawValue: type.rawValue,
    flags: 0,
    outPathLength: 0,
    outPath: Data(),
    lastAdvertTimestamp: 0,
    latitude: latitude,
    longitude: longitude,
    lastModified: 0,
    lastHeardTimestamp: nil,
    nickname: nil,
    isBlocked: false,
    isMuted: false,
    isFavorite: isFavorite,
    lastMessageDate: nil,
    unreadCount: 0
  )
}

private func createTestDiscoveredNode(
  name: String = "Discovered Node",
  latitude: Double = 37.8044,
  longitude: Double = -122.2712,
  type: ContactType = .repeater,
  radioID: UUID = UUID(),
  publicKey: Data = Data([0xD1] + Array(repeating: UInt8(0x00), count: 31))
) -> DiscoveredNodeDTO {
  DiscoveredNodeDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: publicKey,
    name: name,
    typeRawValue: type.rawValue,
    lastHeard: Date(timeIntervalSince1970: 1_700_000_000),
    lastAdvertTimestamp: 0,
    latitude: latitude,
    longitude: longitude,
    outPathLength: 0,
    outPath: Data(),
    inboundHopCount: nil,
    inboundHopAdvertTimestamp: nil
  )
}

@MainActor
private func waitForPointAElevation(_ viewModel: LineOfSightViewModel) async throws {
  try await waitUntil("point A elevation should load") {
    guard let pointA = viewModel.pointA else { return false }
    return pointA.groundElevation != nil && pointA.isLoadingElevation == false
  }
}

@MainActor
private func waitForPointBElevation(_ viewModel: LineOfSightViewModel) async throws {
  try await waitUntil("point B elevation should load") {
    guard let pointB = viewModel.pointB else { return false }
    return pointB.groundElevation != nil && pointB.isLoadingElevation == false
  }
}

@MainActor
private func waitForBothPointElevations(_ viewModel: LineOfSightViewModel) async throws {
  try await waitUntil("both point elevations should load") {
    viewModel.canAnalyze
  }
}

@MainActor
private func waitForAnalysisResult(_ viewModel: LineOfSightViewModel) async throws {
  try await waitUntil(timeout: .seconds(5), "analysis should produce result") {
    if case .result = viewModel.analysisStatus {
      return true
    }
    return false
  }
}

// MARK: - Initial State Tests

@Suite("LineOfSightViewModel Initial State")
@MainActor
struct InitialStateTests {
  @Test
  func `Initial state has nil points`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.pointA == nil)
    #expect(viewModel.pointB == nil)
  }

  @Test
  func `Initial status is idle`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.analysisStatus == .idle)
  }

  @Test
  func `canAnalyze is false initially`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.canAnalyze == false)
  }

  @Test
  func `Initial elevation profile is empty`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.elevationProfile.isEmpty)
  }

  @Test
  func `Default frequency is 906 MHz`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.frequencyMHz == 906.0)
  }

  @Test
  func `Default refraction K is 1.0`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.refractionK == 1.0)
  }
}

// MARK: - Preselected Contact Initialization Tests

@Suite("Preselected Contact Initialization")
@MainActor
struct PreselectedContactTests {
  @Test
  func `Preselected contact sets point A`() async throws {
    let contact = createTestContact(name: "Preselected", latitude: 37.8, longitude: -122.4)
    let viewModel = LineOfSightViewModel(preselectedContact: contact)

    try await waitUntil("preselected contact elevation should load") {
      viewModel.pointA?.isLoadingElevation == false
    }

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointA?.contact?.name == "Preselected")
    #expect(viewModel.pointA?.coordinate.latitude == 37.8)
  }

  @Test
  func `Preselected contact with no location does not set point A`() {
    let contact = createTestContact(name: "No Location", latitude: 0, longitude: 0)
    let viewModel = LineOfSightViewModel(preselectedContact: contact)

    #expect(viewModel.pointA == nil)
  }

  @Test
  func `Nil preselected contact leaves point A nil`() {
    let viewModel = LineOfSightViewModel(preselectedContact: nil)

    #expect(viewModel.pointA == nil)
  }
}

// MARK: - Point Selection Tests

@Suite("Point Selection")
@MainActor
struct PointSelectionTests {
  @Test
  func `selectPoint sets point A when empty`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.selectPoint(at: sanFrancisco)

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointA?.coordinate.latitude == sanFrancisco.latitude)
    #expect(viewModel.pointB == nil)
  }

  @Test
  func `selectPoint sets point B when A exists`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.selectPoint(at: sanFrancisco)
    viewModel.selectPoint(at: oakland)

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointB != nil)
    #expect(viewModel.pointB?.coordinate.latitude == oakland.latitude)
  }

  @Test
  func `selectPoint replaces B when both exist`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.selectPoint(at: sanFrancisco)
    viewModel.selectPoint(at: oakland)
    viewModel.selectPoint(at: berkeley)

    #expect(viewModel.pointA?.coordinate.latitude == sanFrancisco.latitude)
    #expect(viewModel.pointB?.coordinate.latitude == berkeley.latitude)
  }

  @Test
  func `setPointA sets coordinate and contact`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact = createTestContact(name: "Point A Contact")

    viewModel.setPointA(coordinate: sanFrancisco, contact: contact)

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointA?.contact?.name == "Point A Contact")
    #expect(viewModel.pointA?.displayName == "Point A Contact")
  }

  @Test
  func `setPointB sets coordinate and contact`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact = createTestContact(name: "Point B Contact")

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland, contact: contact)

    #expect(viewModel.pointB != nil)
    #expect(viewModel.pointB?.contact?.name == "Point B Contact")
  }

  @Test
  func `Point without contact shows Dropped pin`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)

    #expect(viewModel.pointA?.displayName == "Dropped pin")
  }
}

// MARK: - Same Location Prevention Tests

@Suite("Same Location Prevention")
@MainActor
struct SameLocationTests {
  @Test
  func `Cannot set B to same location as A`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: sanFrancisco)

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointB == nil)
  }

  @Test
  func `Can set B to different location after same location rejected`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: sanFrancisco) // Rejected
    viewModel.setPointB(coordinate: oakland) // Should work

    #expect(viewModel.pointB != nil)
    #expect(viewModel.pointB?.coordinate.latitude == oakland.latitude)
  }
}

// MARK: - Elevation Fetching Tests

@Suite("Elevation Fetching")
@MainActor
struct ElevationFetchingTests {
  @Test
  func `Point starts with nil elevation`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)

    // Before async fetch completes
    #expect(viewModel.pointA?.isLoadingElevation == true)
  }

  @Test
  func `Elevation is fetched asynchronously`() async throws {
    let mockService = MockElevationService()
    await mockService.reset()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)

    try await waitUntil("point A elevation should be loaded") {
      guard let pointA = viewModel.pointA else { return false }
      return pointA.groundElevation == 100 && pointA.isLoadingElevation == false
    }

    #expect(viewModel.pointA?.groundElevation == 100)
    #expect(viewModel.pointA?.isLoadingElevation == false)
  }

  @Test
  func `canAnalyze is true when both elevations loaded`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)

    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    #expect(viewModel.canAnalyze == true)
  }

  @Test
  func `totalHeight includes additionalHeight`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    try await waitUntil("point A elevation should load") {
      viewModel.pointA?.isLoadingElevation == false
    }

    viewModel.updateAdditionalHeight(for: .pointA, meters: 10)

    #expect(viewModel.pointA?.groundElevation == 100)
    #expect(viewModel.pointA?.additionalHeight == 10)
    #expect(viewModel.pointA?.totalHeight == 110)
  }
}

// MARK: - Height Adjustment Tests

@Suite("Height Adjustment")
@MainActor
struct HeightAdjustmentTests {
  @Test
  func `Height adjustment clamps to zero`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    try await waitUntil("point A elevation should load") {
      viewModel.pointA?.isLoadingElevation == false
    }

    viewModel.updateAdditionalHeight(for: .pointA, meters: -10)

    #expect(viewModel.pointA?.additionalHeight == 0)
  }

  @Test
  func `Height adjustment accepts positive values`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    try await waitUntil("point A elevation should load") {
      viewModel.pointA?.isLoadingElevation == false
    }

    viewModel.updateAdditionalHeight(for: .pointA, meters: 15)

    #expect(viewModel.pointA?.additionalHeight == 15)
  }

  @Test
  func `Height adjustment for point B works`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    viewModel.updateAdditionalHeight(for: .pointB, meters: 20)

    #expect(viewModel.pointB?.additionalHeight == 20)
  }

  @Test
  func `Height adjustment on nil point does nothing`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    // Should not crash
    viewModel.updateAdditionalHeight(for: .pointA, meters: 10)
    viewModel.updateAdditionalHeight(for: .pointB, meters: 10)

    #expect(viewModel.pointA == nil)
    #expect(viewModel.pointB == nil)
  }

  @Test
  func `Height change invalidates analysis`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    viewModel.analyze()
    try await waitForAnalysisResult(viewModel)

    if case .result = viewModel.analysisStatus {
      viewModel.updateAdditionalHeight(for: .pointA, meters: 5)
      try await waitUntil("analysis should be invalidated after height change") {
        viewModel.analysisStatus == .idle
      }
      #expect(viewModel.analysisStatus == .idle)
      return
    }

    Issue.record("Expected analysis result before height change")
  }
}

// MARK: - Clear Tests

@Suite("Clear Methods")
@MainActor
struct ClearTests {
  @Test
  func `clear removes all state`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    viewModel.clear()

    #expect(viewModel.pointA == nil)
    #expect(viewModel.pointB == nil)
    #expect(viewModel.analysisStatus == .idle)
    #expect(viewModel.elevationProfile.isEmpty)
  }

  @Test
  func `clearPointA removes only point A`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    viewModel.clearPointA()

    #expect(viewModel.pointA == nil)
    #expect(viewModel.pointB != nil)
  }

  @Test
  func `clearPointB removes only point B`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    viewModel.clearPointB()

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointB == nil)
  }

  @Test
  func `clearPointA invalidates analysis`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    viewModel.analyze()
    try await waitUntil("analysis should complete") {
      !viewModel.isAnalyzing
    }

    viewModel.clearPointA()

    #expect(viewModel.analysisStatus == .idle)
  }
}

// MARK: - Analysis Tests

@Suite("Analysis")
@MainActor
struct AnalysisTests {
  @Test
  func `analyze sets loading status`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    // Start analysis but don't wait for it
    viewModel.analyze()

    // Should be analyzing (or already completed for mock)
    let isAnalyzingOrResult = viewModel.isAnalyzing
      || (viewModel.analysisStatus != .idle && viewModel.analysisStatus != .error(""))

    #expect(isAnalyzingOrResult)
  }

  @Test
  func `analyze produces result on success`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    viewModel.analyze()
    try await waitForAnalysisResult(viewModel)

    if case let .result(result) = viewModel.analysisStatus {
      #expect(result.distanceMeters > 0)
    } else {
      Issue.record("Expected result status, got: \(viewModel.analysisStatus)")
    }
  }

  @Test
  func `analyze populates elevation profile`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    viewModel.analyze()
    try await waitUntil("analysis should complete") {
      !viewModel.isAnalyzing
    }

    #expect(!viewModel.elevationProfile.isEmpty)
  }

  @Test
  func `analyze without elevations does nothing`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    // Points not set
    viewModel.analyze()

    #expect(viewModel.analysisStatus == .idle)
  }

  @Test
  func `analyze error sets error status`() async throws {
    let mockService = MockElevationService()
    await mockService.reset()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both point elevations should load before analyze") {
      viewModel.canAnalyze
    }

    // Now make the service fail for the analysis fetch
    await mockService.setFailure(true)

    viewModel.analyze()
    try await waitUntil("analysis should transition to error") {
      if case .error = viewModel.analysisStatus {
        return true
      }
      return false
    }

    if case .error = viewModel.analysisStatus {
      // Expected
    } else {
      Issue.record("Expected error status")
    }
  }

  @Test
  func `New analysis cancels previous`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    // Start analysis
    viewModel.analyze()

    // Start another immediately
    viewModel.analyze()

    try await waitUntil("analysis should complete") {
      !viewModel.isAnalyzing
    }

    if case .result = viewModel.analysisStatus {
      // Expected
    } else if viewModel.isAnalyzing {
      // Still analyzing is also acceptable
    } else {
      Issue.record("Unexpected status: \(viewModel.analysisStatus)")
    }
  }
}

// MARK: - Selected Point Tests

@Suite("SelectedPoint")
@MainActor
struct SelectedPointTests {
  @Test
  func `totalHeight is nil when groundElevation is nil`() {
    let point = SelectedPoint(
      coordinate: sanFrancisco,
      contact: nil,
      groundElevation: nil,
      additionalHeight: 10
    )

    #expect(point.totalHeight == nil)
  }

  @Test
  func `totalHeight includes both ground and additional`() {
    let point = SelectedPoint(
      coordinate: sanFrancisco,
      contact: nil,
      groundElevation: 100,
      additionalHeight: 10
    )

    #expect(point.totalHeight == 110)
  }

  @Test
  func `isLoadingElevation is true when groundElevation is nil`() {
    let point = SelectedPoint(
      coordinate: sanFrancisco,
      contact: nil,
      groundElevation: nil,
      additionalHeight: 0
    )

    #expect(point.isLoadingElevation == true)
  }

  @Test
  func `isLoadingElevation is false when groundElevation is set`() {
    let point = SelectedPoint(
      coordinate: sanFrancisco,
      contact: nil,
      groundElevation: 100,
      additionalHeight: 0
    )

    #expect(point.isLoadingElevation == false)
  }
}

// MARK: - AnalysisStatus Equatable Tests

@Suite("AnalysisStatus Equatable")
struct AnalysisStatusEquatableTests {
  @Test
  func `idle equals idle`() {
    #expect(AnalysisStatus.idle == AnalysisStatus.idle)
  }

  @Test
  func `error with same message equals`() {
    #expect(AnalysisStatus.error("test") == AnalysisStatus.error("test"))
  }

  @Test
  func `error with different message not equal`() {
    #expect(AnalysisStatus.error("test1") != AnalysisStatus.error("test2"))
  }

  @Test
  func `idle does not equal error`() {
    #expect(AnalysisStatus.idle != AnalysisStatus.error("test"))
  }
}

// MARK: - Load Repeaters Tests

@Suite("Load Repeaters")
@MainActor
struct LoadRepeatersTests {
  @Test
  func `loadRepeaters filters to only repeaters with location`() async {
    let mockService = MockElevationService()
    let mockDataStore = MockPersistenceStore()
    let radioID = UUID()

    // Add a repeater with location
    let repeaterWithLocation = createTestContact(
      name: "Repeater 1",
      latitude: 37.7749,
      longitude: -122.4194,
      type: .repeater,
      radioID: radioID
    )
    await mockDataStore.addContact(repeaterWithLocation)

    // Add a repeater without location
    let repeaterNoLocation = createTestContact(
      name: "Repeater 2",
      latitude: 0,
      longitude: 0,
      type: .repeater,
      radioID: radioID
    )
    await mockDataStore.addContact(repeaterNoLocation)

    // Add a chat contact with location (should be excluded)
    let chatWithLocation = createTestContact(
      name: "Chat User",
      latitude: 37.8044,
      longitude: -122.2712,
      type: .chat,
      radioID: radioID
    )
    await mockDataStore.addContact(chatWithLocation)

    // Add a room contact with location (should be excluded)
    let roomWithLocation = createTestContact(
      name: "Room Server",
      latitude: 37.8716,
      longitude: -122.2727,
      type: .room,
      radioID: radioID
    )
    await mockDataStore.addContact(roomWithLocation)

    let viewModel = LineOfSightViewModel(elevationService: mockService)
    viewModel.configure(dataStore: { mockDataStore }, radioID: { radioID })

    await viewModel.loadRepeaters()

    #expect(viewModel.repeatersWithLocation.count == 1)
    #expect(viewModel.repeatersWithLocation.first?.name == "Repeater 1")
  }

  @Test
  func `loadRepeaters returns empty when no repeaters have location`() async {
    let mockService = MockElevationService()
    let mockDataStore = MockPersistenceStore()
    let radioID = UUID()

    // Add repeaters without location
    let repeater1 = createTestContact(
      name: "Repeater 1",
      latitude: 0,
      longitude: 0,
      type: .repeater,
      radioID: radioID
    )
    await mockDataStore.addContact(repeater1)

    let repeater2 = createTestContact(
      name: "Repeater 2",
      latitude: 0,
      longitude: 0,
      type: .repeater,
      radioID: radioID
    )
    await mockDataStore.addContact(repeater2)

    let viewModel = LineOfSightViewModel(elevationService: mockService)
    viewModel.configure(dataStore: { mockDataStore }, radioID: { radioID })

    await viewModel.loadRepeaters()

    #expect(viewModel.repeatersWithLocation.isEmpty)
  }

  @Test
  func `loadRepeaters does nothing without configuration`() async {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    // Don't configure the viewModel - should do nothing
    await viewModel.loadRepeaters()

    #expect(viewModel.repeatersWithLocation.isEmpty)
  }

  @Test
  func `loadRepeaters only loads repeaters for configured device`() async {
    let mockService = MockElevationService()
    let mockDataStore = MockPersistenceStore()
    let radioID1 = UUID()
    let radioID2 = UUID()

    // Add repeater for device 1
    let repeaterDevice1 = createTestContact(
      name: "Repeater Device 1",
      latitude: 37.7749,
      longitude: -122.4194,
      type: .repeater,
      radioID: radioID1
    )
    await mockDataStore.addContact(repeaterDevice1)

    // Add repeater for device 2
    let repeaterDevice2 = createTestContact(
      name: "Repeater Device 2",
      latitude: 37.8044,
      longitude: -122.2712,
      type: .repeater,
      radioID: radioID2
    )
    await mockDataStore.addContact(repeaterDevice2)

    let viewModel = LineOfSightViewModel(elevationService: mockService)
    viewModel.configure(dataStore: { mockDataStore }, radioID: { radioID1 })

    await viewModel.loadRepeaters()

    #expect(viewModel.repeatersWithLocation.count == 1)
    #expect(viewModel.repeatersWithLocation.first?.name == "Repeater Device 1")
  }

  @Test
  func `Initial repeatersWithLocation is empty`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.repeatersWithLocation.isEmpty)
  }
}

// MARK: - Discovered Nodes Tests

@Suite("Line of Sight Discovered Nodes")
@MainActor
struct LineOfSightDiscoveredNodesTests {
  private static let discoveredOn = MapFilterState(showDiscovered: true)
  private static let discoveredOff = MapFilterState(showDiscovered: false)

  private static func key(_ byte: UInt8) -> Data {
    Data([byte] + Array(repeating: UInt8(0x00), count: 31))
  }

  private static func makeViewModel(
    contacts: [ContactDTO] = [],
    discovered: [DiscoveredNodeDTO] = [],
    radioID: UUID,
    filter: MapFilterState = discoveredOn
  ) async -> LineOfSightViewModel {
    let dataStore = MockPersistenceStore()
    for contact in contacts {
      await dataStore.addContact(contact)
    }
    for node in discovered {
      await dataStore.addDiscoveredNode(node)
    }
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())
    viewModel.configure(dataStore: { dataStore }, radioID: { radioID })
    viewModel.applyFilter(filter)
    await viewModel.loadRepeaters()
    return viewModel
  }

  // MARK: Loading

  @Test
  func `loadRepeaters keeps located discovered nodes of every type`() async {
    let radioID = UUID()
    let nodes = [
      createTestDiscoveredNode(name: "Walker", type: .chat, radioID: radioID, publicKey: Self.key(0xD1)),
      createTestDiscoveredNode(name: "Hilltop", type: .repeater, radioID: radioID, publicKey: Self.key(0xD2)),
      createTestDiscoveredNode(name: "Clubhouse", type: .room, radioID: radioID, publicKey: Self.key(0xD3))
    ]

    let viewModel = await Self.makeViewModel(discovered: nodes, radioID: radioID)

    #expect(Set(viewModel.discoveredWithLocation.map(\.name)) == ["Walker", "Hilltop", "Clubhouse"])
  }

  @Test
  func `loadRepeaters drops discovered nodes without a valid position`() async {
    let radioID = UUID()
    let nodes = [
      createTestDiscoveredNode(name: "No Fix", latitude: 0, longitude: 0, radioID: radioID, publicKey: Self.key(0xD1)),
      createTestDiscoveredNode(name: "Bad Fix", latitude: 999, longitude: 0, radioID: radioID, publicKey: Self.key(0xD2)),
      createTestDiscoveredNode(name: "Good Fix", radioID: radioID, publicKey: Self.key(0xD3))
    ]

    let viewModel = await Self.makeViewModel(discovered: nodes, radioID: radioID)

    #expect(viewModel.discoveredWithLocation.map(\.name) == ["Good Fix"])
    #expect(viewModel.mapPoints.map(\.label) == ["Good Fix"])
  }

  @Test
  func `loadRepeaters only loads discovered nodes for the configured radio`() async {
    let radioID = UUID()
    let nodes = [
      createTestDiscoveredNode(name: "Mine", radioID: radioID, publicKey: Self.key(0xD1)),
      createTestDiscoveredNode(name: "Other Radio", radioID: UUID(), publicKey: Self.key(0xD2))
    ]

    let viewModel = await Self.makeViewModel(discovered: nodes, radioID: radioID)

    #expect(viewModel.discoveredWithLocation.map(\.name) == ["Mine"])
  }

  @Test
  func `a discovered node that is also a contact is shown once, as the contact`() async {
    let radioID = UUID()
    let repeater = createTestContact(
      name: "Hilltop",
      type: .repeater,
      radioID: radioID,
      publicKey: Self.key(0xC1)
    )
    let sameNode = createTestDiscoveredNode(name: "Hilltop", radioID: radioID, publicKey: Self.key(0xC1))

    let viewModel = await Self.makeViewModel(contacts: [repeater], discovered: [sameNode], radioID: radioID)

    #expect(viewModel.discoveredWithLocation.isEmpty)
    #expect(viewModel.mapPoints.map(\.id) == [repeater.id])
    #expect(viewModel.mapPoints.map(\.pinStyle) == [.repeater])
  }

  @Test
  func `a discovered node whose contact has no position is not shown as discovered`() async {
    let radioID = UUID()
    let unlocated = createTestContact(
      name: "Hilltop",
      latitude: 0,
      longitude: 0,
      type: .repeater,
      radioID: radioID,
      publicKey: Self.key(0xC1)
    )
    let sameNode = createTestDiscoveredNode(name: "Hilltop", radioID: radioID, publicKey: Self.key(0xC1))

    let viewModel = await Self.makeViewModel(contacts: [unlocated], discovered: [sameNode], radioID: radioID)

    #expect(viewModel.mapPoints.isEmpty)
  }

  // MARK: Filter

  @Test
  func `line of sight has its own Favorites and Discovered filter`() {
    #expect(MapFilterHost.lineOfSight.capabilities == [.favorites, .discovered])
    #expect(MapFilterHost.lineOfSight.storageKey == AppStorageKey.mapFilterLineOfSight.rawValue)
    #expect(!MapFilterState.seed(for: .lineOfSight).differsFromSeed(for: .lineOfSight))
  }

  @Test
  func `discovered pins show by default until the filter turns them off`() async {
    let radioID = UUID()
    let repeater = createTestContact(name: "Relay", type: .repeater, radioID: radioID)
    let node = createTestDiscoveredNode(radioID: radioID)

    let viewModel = await Self.makeViewModel(
      contacts: [repeater],
      discovered: [node],
      radioID: radioID,
      filter: .seed(for: .lineOfSight)
    )
    #expect(viewModel.mapPoints.map(\.id) == [repeater.id, node.id])
    #expect(viewModel.visibleDiscovered.map(\.id) == [node.id])

    viewModel.applyFilter(Self.discoveredOff)

    #expect(viewModel.mapPoints.map(\.id) == [repeater.id])
    #expect(viewModel.visibleDiscovered.isEmpty)
  }

  @Test(arguments: [
    (ContactType.chat, MapPoint.PinStyle.discoveredChat),
    (ContactType.repeater, MapPoint.PinStyle.discoveredRepeater),
    (ContactType.room, MapPoint.PinStyle.discoveredRoom)
  ])
  func `discovered pins use the outlined style for their type`(
    type: ContactType,
    style: MapPoint.PinStyle
  ) async throws {
    let radioID = UUID()
    let node = createTestDiscoveredNode(name: "Node", type: type, radioID: radioID)

    let viewModel = await Self.makeViewModel(discovered: [node], radioID: radioID)

    let point = try #require(viewModel.mapPoints.first)
    #expect(point.pinStyle == style)
    #expect(point.label == "Node")
    #expect(point.isClusterable)
  }

  @Test
  func `discovered pin labels follow the labels setting`() async {
    let radioID = UUID()
    let viewModel = await Self.makeViewModel(
      discovered: [createTestDiscoveredNode(radioID: radioID)],
      radioID: radioID
    )

    viewModel.showLabels = false

    #expect(viewModel.mapPoints.map(\.label) == [nil])
  }

  @Test
  func `Favorites shows favorite repeaters only and no discovered pins`() async {
    let radioID = UUID()
    let favorite = createTestContact(
      name: "Favorite",
      type: .repeater,
      radioID: radioID,
      publicKey: Self.key(0xC1),
      isFavorite: true
    )
    let other = createTestContact(name: "Other", type: .repeater, radioID: radioID, publicKey: Self.key(0xC2))
    let node = createTestDiscoveredNode(radioID: radioID)
    var filter = Self.discoveredOn
    filter.setFavoritesOnly(true)

    let viewModel = await Self.makeViewModel(
      contacts: [favorite, other],
      discovered: [node],
      radioID: radioID,
      filter: filter
    )

    #expect(viewModel.mapPoints.map(\.id) == [favorite.id])
  }

  @Test
  func `Favorites keeps the pins of picked endpoints`() async {
    let radioID = UUID()
    let repeater = createTestContact(name: "Relay", type: .repeater, radioID: radioID)
    let node = createTestDiscoveredNode(radioID: radioID)
    let viewModel = await Self.makeViewModel(contacts: [repeater], discovered: [node], radioID: radioID)
    viewModel.toggleContact(repeater)
    viewModel.toggleDiscoveredNode(node)

    var filter = Self.discoveredOn
    filter.setFavoritesOnly(true)
    viewModel.applyFilter(filter)

    #expect(viewModel.mapPoints.map(\.id) == [repeater.id, node.id])
    #expect(viewModel.mapPoints.map(\.pinStyle) == [.repeaterRingBlue, .pointB])
  }

  @Test
  func `center on all frames the discovered pins that are shown`() async throws {
    let radioID = UUID()
    let repeater = createTestContact(name: "Relay", latitude: 37, longitude: -122, type: .repeater, radioID: radioID)
    let node = createTestDiscoveredNode(latitude: 45, longitude: -122, radioID: radioID)
    let viewModel = await Self.makeViewModel(contacts: [repeater], discovered: [node], radioID: radioID)

    viewModel.centerOnAllRepeaters()
    let withDiscovered = try #require(viewModel.cameraRegion)
    #expect(withDiscovered.center.latitude == 41)

    viewModel.applyFilter(Self.discoveredOff)
    viewModel.centerOnAllRepeaters()
    let repeatersOnly = try #require(viewModel.cameraRegion)
    #expect(repeatersOnly.center.latitude == 37)
  }

  // MARK: Picking

  @Test
  func `toggling discovered nodes picks A, then B, and clears on a second tap`() async {
    let radioID = UUID()
    let first = createTestDiscoveredNode(name: "First", latitude: 37, radioID: radioID, publicKey: Self.key(0xD1))
    let second = createTestDiscoveredNode(name: "Second", latitude: 38, radioID: radioID, publicKey: Self.key(0xD2))
    let viewModel = await Self.makeViewModel(discovered: [first, second], radioID: radioID)

    viewModel.toggleDiscoveredNode(first)
    viewModel.toggleDiscoveredNode(second)

    #expect(viewModel.pointA?.discoveredNode?.id == first.id)
    #expect(viewModel.pointA?.coordinate.latitude == 37)
    #expect(viewModel.pointB?.discoveredNode?.id == second.id)

    viewModel.toggleDiscoveredNode(first)

    #expect(viewModel.pointA == nil)
    #expect(viewModel.pointB?.discoveredNode?.id == second.id)
  }

  @Test
  func `a picked discovered node is drawn once, as its point`() async throws {
    let radioID = UUID()
    let node = createTestDiscoveredNode(name: "Hilltop", radioID: radioID)
    let viewModel = await Self.makeViewModel(discovered: [node], radioID: radioID)

    viewModel.toggleDiscoveredNode(node)

    #expect(viewModel.mapPoints.count == 1)
    let point = try #require(viewModel.mapPoints.first)
    #expect(point.id == node.id)
    #expect(point.pinStyle == .pointA)
    #expect(point.label == "Hilltop")
    #expect(!point.isClusterable)
    #expect(viewModel.discoveredNode(forPointID: node.id) == node)
  }

  @Test
  func `a picked discovered node keeps its pin when the discovered layer is turned off`() async {
    let radioID = UUID()
    let picked = createTestDiscoveredNode(name: "Picked", radioID: radioID, publicKey: Self.key(0xD1))
    let other = createTestDiscoveredNode(name: "Other", radioID: radioID, publicKey: Self.key(0xD2))
    let viewModel = await Self.makeViewModel(discovered: [picked, other], radioID: radioID)
    viewModel.toggleDiscoveredNode(picked)

    viewModel.applyFilter(MapFilterState(showDiscovered: false))

    #expect(viewModel.mapPoints.map(\.id) == [picked.id])
    #expect(viewModel.discoveredNode(forPointID: picked.id) == picked)
    #expect(viewModel.discoveredNode(forPointID: other.id) == nil)
  }

  @Test
  func `clearing a picked discovered node returns its outlined pin`() async {
    let radioID = UUID()
    let node = createTestDiscoveredNode(radioID: radioID)
    let viewModel = await Self.makeViewModel(discovered: [node], radioID: radioID)
    viewModel.toggleDiscoveredNode(node)

    viewModel.clearPointA()

    #expect(viewModel.mapPoints.map(\.pinStyle) == [.discoveredRepeater])
  }

  @Test
  func `dropped pins keep their own map ids`() async {
    let radioID = UUID()
    let viewModel = await Self.makeViewModel(radioID: radioID)

    viewModel.selectPoint(at: sanFrancisco)
    viewModel.selectPoint(at: oakland)

    #expect(viewModel.mapPoints.map(\.id) == [viewModel.pointAMapID, viewModel.pointBMapID])
    #expect(viewModel.mapPoints.map(\.label) == [nil, nil])
  }

  // MARK: Naming

  @Test
  func `a discovered point is named after the node and marked discovered`() {
    let node = createTestDiscoveredNode(name: "Hilltop")
    let point = SelectedPoint(
      coordinate: oakland,
      contact: nil,
      discoveredNode: node,
      groundElevation: nil
    )

    #expect(point.displayName == "Hilltop")
    #expect(point.isDiscovered)
  }

  @Test
  func `contacts and dropped pins are not marked discovered`() {
    let contact = SelectedPoint(
      coordinate: sanFrancisco,
      contact: createTestContact(name: "Relay"),
      groundElevation: nil
    )
    let dropped = SelectedPoint(coordinate: oakland, contact: nil, groundElevation: nil)

    #expect(!contact.isDiscovered)
    #expect(contact.displayName == "Relay")
    #expect(!dropped.isDiscovered)
  }

  // MARK: Pin decision

  @Test
  func `plottable discovered nodes need a valid position and a key that is not a contact`() {
    let plotted = createTestDiscoveredNode(name: "Plotted", publicKey: Self.key(0xD1))
    let contact = createTestDiscoveredNode(name: "Contact", publicKey: Self.key(0xC1))
    let noFix = createTestDiscoveredNode(name: "No Fix", latitude: 0, longitude: 0, publicKey: Self.key(0xD2))

    let plottable = LineOfSightViewModel.plottableDiscovered(
      [plotted, contact, noFix],
      contactKeys: [Self.key(0xC1)]
    )

    #expect(plottable.map(\.name) == ["Plotted"])
  }

  @Test
  func `visible discovered pins leave out picked nodes and follow the filter`() {
    let picked = createTestDiscoveredNode(name: "Picked", publicKey: Self.key(0xD1))
    let other = createTestDiscoveredNode(name: "Other", publicKey: Self.key(0xD2))
    var favorites = Self.discoveredOn
    favorites.setFavoritesOnly(true)

    let shown = LineOfSightViewModel.visibleDiscoveredPins(
      plottable: [picked, other],
      selectedIDs: [picked.id],
      filter: Self.discoveredOn
    )
    let layerOff = LineOfSightViewModel.visibleDiscoveredPins(
      plottable: [picked, other],
      selectedIDs: [],
      filter: MapFilterState(showDiscovered: false)
    )
    let favoritesOnly = LineOfSightViewModel.visibleDiscoveredPins(
      plottable: [picked, other],
      selectedIDs: [],
      filter: favorites
    )

    #expect(shown.map(\.name) == ["Other"])
    #expect(layerOff.isEmpty)
    #expect(favoritesOnly.isEmpty)
  }

  @Test
  func `visible repeater pins follow Favorites but keep picked repeaters`() {
    let favorite = createTestContact(name: "Favorite", type: .repeater, publicKey: Self.key(0xC1), isFavorite: true)
    let picked = createTestContact(name: "Picked", type: .repeater, publicKey: Self.key(0xC2))
    let other = createTestContact(name: "Other", type: .repeater, publicKey: Self.key(0xC3))
    var favorites = MapFilterState()
    favorites.setFavoritesOnly(true)

    let all = LineOfSightViewModel.visibleRepeaterPins(
      candidates: [favorite, picked, other],
      selectedIDs: [],
      filter: MapFilterState()
    )
    let favoritesOnly = LineOfSightViewModel.visibleRepeaterPins(
      candidates: [favorite, picked, other],
      selectedIDs: [picked.id],
      filter: favorites
    )

    #expect(all.map(\.name) == ["Favorite", "Picked", "Other"])
    #expect(favoritesOnly.map(\.name) == ["Favorite", "Picked"])
  }
}

// MARK: - Elevation Interpolation Tests

@Suite("Elevation Interpolation")
@MainActor
struct ElevationInterpolationTests {
  @Test
  func `elevationAt returns nil when profile is empty`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())
    #expect(viewModel.elevationAt(pathFraction: 0.5) == nil)
  }

  @Test
  func `elevationAt interpolates between samples`() throws {
    let mockService = MockElevationService()
    let profile = [
      ElevationSample(coordinate: sanFrancisco, elevation: 100, distanceFromAMeters: 0),
      ElevationSample(coordinate: oakland, elevation: 200, distanceFromAMeters: 1000)
    ]

    let viewModel = LineOfSightViewModel(elevationService: mockService)
    viewModel.setElevationProfileForTesting(profile)

    // Midpoint should interpolate to 150
    let midElevation = viewModel.elevationAt(pathFraction: 0.5)
    #expect(midElevation != nil)
    #expect(try abs(#require(midElevation) - 150) < 0.01)

    // At start
    let startElevation = viewModel.elevationAt(pathFraction: 0.0)
    #expect(startElevation != nil)
    #expect(try abs(#require(startElevation) - 100) < 0.01)

    // At end
    let endElevation = viewModel.elevationAt(pathFraction: 1.0)
    #expect(endElevation != nil)
    #expect(try abs(#require(endElevation) - 200) < 0.01)
  }

  @Test
  func `coordinateAt interpolates between samples`() throws {
    let mockService = MockElevationService()
    let profile = [
      ElevationSample(coordinate: sanFrancisco, elevation: 100, distanceFromAMeters: 0),
      ElevationSample(coordinate: oakland, elevation: 200, distanceFromAMeters: 1000)
    ]

    let viewModel = LineOfSightViewModel(elevationService: mockService)
    viewModel.setElevationProfileForTesting(profile)

    let midCoord = viewModel.coordinateAt(pathFraction: 0.5)
    #expect(midCoord != nil)

    // Should be roughly between SF and Oakland
    let expectedLat = (sanFrancisco.latitude + oakland.latitude) / 2
    let expectedLon = (sanFrancisco.longitude + oakland.longitude) / 2
    #expect(try abs(#require(midCoord?.latitude) - expectedLat) < 0.001)
    #expect(try abs(#require(midCoord?.longitude) - expectedLon) < 0.001)
  }

  @Test
  func `elevationAt returns nil when profile has single sample`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())
    viewModel.setElevationProfileForTesting([
      ElevationSample(coordinate: sanFrancisco, elevation: 100, distanceFromAMeters: 0)
    ])

    #expect(viewModel.elevationAt(pathFraction: 0.5) == nil)
  }

  @Test
  func `elevationAt clamps pathFraction outside valid range`() throws {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())
    viewModel.setElevationProfileForTesting([
      ElevationSample(coordinate: sanFrancisco, elevation: 100, distanceFromAMeters: 0),
      ElevationSample(coordinate: oakland, elevation: 200, distanceFromAMeters: 1000)
    ])

    // Negative should clamp to start (100)
    let belowStart = viewModel.elevationAt(pathFraction: -0.5)
    #expect(belowStart != nil)
    #expect(try abs(#require(belowStart) - 100) < 0.01)

    // Above 1.0 should clamp to end (200)
    let aboveEnd = viewModel.elevationAt(pathFraction: 1.5)
    #expect(aboveEnd != nil)
    #expect(try abs(#require(aboveEnd) - 200) < 0.01)
  }
}

// MARK: - Contact Toggle Selection Tests

@Suite("Contact Toggle Selection")
@MainActor
struct ContactToggleTests {
  @Test
  func `toggleContact sets point A for first contact`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact = createTestContact(name: "Repeater", latitude: 37.8, longitude: -122.4, type: .repeater)

    viewModel.toggleContact(contact)

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointA?.contact?.id == contact.id)
  }

  @Test
  func `toggleContact sets point B for second contact`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact1 = createTestContact(name: "Repeater 1", latitude: 37.8, longitude: -122.4, type: .repeater)
    let contact2 = createTestContact(name: "Repeater 2", latitude: 37.7, longitude: -122.3, type: .repeater)

    viewModel.toggleContact(contact1)
    viewModel.toggleContact(contact2)

    #expect(viewModel.pointA?.contact?.id == contact1.id)
    #expect(viewModel.pointB?.contact?.id == contact2.id)
  }

  @Test
  func `toggleContact clears point A when tapped again`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact = createTestContact(name: "Repeater", latitude: 37.8, longitude: -122.4, type: .repeater)

    viewModel.toggleContact(contact)
    viewModel.toggleContact(contact)

    #expect(viewModel.pointA == nil)
  }

  @Test
  func `toggleContact clears point B when tapped again`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact1 = createTestContact(name: "Repeater 1", latitude: 37.8, longitude: -122.4, type: .repeater)
    let contact2 = createTestContact(name: "Repeater 2", latitude: 37.7, longitude: -122.3, type: .repeater)

    viewModel.toggleContact(contact1)
    viewModel.toggleContact(contact2)
    viewModel.toggleContact(contact2)

    #expect(viewModel.pointA != nil)
    #expect(viewModel.pointB == nil)
  }

  @Test
  func `toggleContact assigns contact to point A when empty`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact = createTestContact(name: "Repeater", latitude: 37.8, longitude: -122.4, type: .repeater)

    #expect(viewModel.pointA?.contact?.id != contact.id)
    #expect(viewModel.pointB?.contact?.id != contact.id)

    viewModel.toggleContact(contact)
    #expect(viewModel.pointA?.contact?.id == contact.id)
  }

  @Test
  func `toggleContact assigns second contact to point B`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)
    let contact1 = createTestContact(name: "Repeater 1", latitude: 37.8, longitude: -122.4, type: .repeater)
    let contact2 = createTestContact(name: "Repeater 2", latitude: 37.7, longitude: -122.3, type: .repeater)

    viewModel.toggleContact(contact1)
    viewModel.toggleContact(contact2)

    #expect(viewModel.pointA?.contact?.id == contact1.id)
    #expect(viewModel.pointB?.contact?.id == contact2.id)
  }
}

// MARK: - Repeater Point Tests

private let testRepeaterCoordinate = CLLocationCoordinate2D(latitude: 37.8, longitude: -122.35)

@Suite("Repeater Point Model")
struct RepeaterPointTests {
  @Test
  func `RepeaterPoint clamps pathFraction to valid range`() {
    var point = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.02)
    #expect(point.pathFraction >= 0.05)

    point = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.98)
    #expect(point.pathFraction <= 0.95)

    point = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)
    #expect(point.pathFraction == 0.5)
  }

  @Test
  func `RepeaterPoint has default height of 10m`() {
    let point = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)
    #expect(point.additionalHeight == 10)
  }
}

// MARK: - Repeater ViewModel Properties Tests

@Suite("Repeater ViewModel Properties")
@MainActor
struct RepeaterViewModelTests {
  @Test
  func `Initial repeaterPoint is nil`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())
    #expect(viewModel.repeaterPoint == nil)
  }
}

// MARK: - Repeater Lifecycle Tests

@Suite("Repeater Lifecycle")
@MainActor
struct RepeaterLifecycleTests {
  @Test
  func `addRepeater places at worst obstruction point`() throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    // Create profile spanning 10km
    let profile = (0...100).map { i in
      ElevationSample(
        coordinate: CLLocationCoordinate2D(
          latitude: 37.7749 + Double(i) * 0.001,
          longitude: -122.4194
        ),
        elevation: 100,
        distanceFromAMeters: Double(i) * 100
      )
    }
    viewModel.setElevationProfileForTesting(profile)

    // Set obstructed result with worst point at 30% of path
    let obstructedResult = PathAnalysisResult(
      distanceMeters: 10000,
      freeSpacePathLoss: 110,
      peakDiffractionLoss: 15,
      totalPathLoss: 125,
      clearanceStatus: .partialObstruction,
      worstClearancePercent: 45,
      obstructionPoints: [
        ObstructionPoint(distanceFromAMeters: 3000, obstructionHeightMeters: 20, fresnelClearancePercent: 45),
        ObstructionPoint(distanceFromAMeters: 7000, obstructionHeightMeters: 10, fresnelClearancePercent: 55)
      ],
      frequencyMHz: 906,
      refractionK: 1.0
    )
    viewModel.setAnalysisStatusForTesting(obstructedResult)

    viewModel.addRepeater()

    #expect(viewModel.repeaterPoint != nil)
    // Worst obstruction is at 3000m out of 10000m = 0.3
    #expect(try abs(#require(viewModel.repeaterPoint?.pathFraction) - 0.3) < 0.01)
  }

  @Test
  func `clearRepeater removes repeater`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)
    #expect(viewModel.repeaterPoint != nil)

    viewModel.clearRepeater()

    #expect(viewModel.repeaterPoint == nil)
  }

  @Test
  func `updateRepeaterPosition updates pathFraction`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)
    viewModel.updateRepeaterPosition(pathFraction: 0.7)

    #expect(viewModel.repeaterPoint?.pathFraction == 0.7)
  }

  @Test
  func `updateRepeaterPosition clamps to valid range`() throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)

    viewModel.updateRepeaterPosition(pathFraction: 0.01)
    #expect(try #require(viewModel.repeaterPoint?.pathFraction) >= 0.05)

    viewModel.updateRepeaterPosition(pathFraction: 0.99)
    #expect(try #require(viewModel.repeaterPoint?.pathFraction) <= 0.95)
  }

  @Test
  func `updateRepeaterHeight updates additionalHeight`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, additionalHeight: 10, pathFraction: 0.5)
    viewModel.updateRepeaterHeight(meters: 25)

    #expect(viewModel.repeaterPoint?.additionalHeight == 25)
  }

  @Test
  func `updateRepeaterHeight clamps negative to zero`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, additionalHeight: 10, pathFraction: 0.5)
    viewModel.updateRepeaterHeight(meters: -5)

    #expect(viewModel.repeaterPoint?.additionalHeight == 0)
  }

  @Test
  func `clearPointA removes repeater`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)

    viewModel.clearPointA()

    #expect(viewModel.repeaterPoint == nil)
  }

  @Test
  func `clearPointB removes repeater`() {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, pathFraction: 0.5)

    viewModel.clearPointB()

    #expect(viewModel.repeaterPoint == nil)
  }
}

// MARK: - Relay Analysis Tests

@Suite("Relay Analysis")
@MainActor
struct RelayAnalysisTests {
  @Test
  func `analyzeWithRepeater produces relay result`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    // Set points first (this clears profile via invalidateAnalysis)
    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    // Create and set profile AFTER points are set
    let profile = (0...100).map { i in
      ElevationSample(
        coordinate: CLLocationCoordinate2D(
          latitude: 37.7749 + Double(i) * 0.001,
          longitude: -122.4194
        ),
        elevation: 100,
        distanceFromAMeters: Double(i) * 100
      )
    }
    viewModel.setElevationProfileForTesting(profile)

    // Add repeater at midpoint
    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, additionalHeight: 10, pathFraction: 0.5)

    viewModel.analyzeWithRepeater()

    if case let .relayResult(result) = viewModel.analysisStatus {
      #expect(result.segmentAR.startLabel == "A")
      #expect(result.segmentAR.endLabel == "R")
      #expect(result.segmentRB.startLabel == "R")
      #expect(result.segmentRB.endLabel == "B")
    } else {
      Issue.record("Expected relayResult status, got: \(viewModel.analysisStatus)")
    }
  }

  @Test
  func `analyzeWithRepeater updates when repeater position changes`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    // Set points first (this clears profile via invalidateAnalysis)
    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitUntil("both elevations should load") {
      viewModel.canAnalyze
    }

    // Create and set profile AFTER points are set
    let profile = (0...100).map { i in
      ElevationSample(
        coordinate: CLLocationCoordinate2D(
          latitude: 37.7749 + Double(i) * 0.001,
          longitude: -122.4194
        ),
        elevation: 100,
        distanceFromAMeters: Double(i) * 100
      )
    }
    viewModel.setElevationProfileForTesting(profile)

    viewModel.repeaterPoint = RepeaterPoint(coordinate: testRepeaterCoordinate, additionalHeight: 10, pathFraction: 0.5)
    viewModel.analyzeWithRepeater()

    // Get initial segment distances
    guard case let .relayResult(initialResult) = viewModel.analysisStatus else {
      Issue.record("Expected initial relayResult")
      return
    }
    let initialARDistance = initialResult.segmentAR.distanceMeters

    // Move repeater to 30%
    viewModel.updateRepeaterPosition(pathFraction: 0.3)
    viewModel.analyzeWithRepeater()

    guard case let .relayResult(updatedResult) = viewModel.analysisStatus else {
      Issue.record("Expected updated relayResult")
      return
    }

    // A→R segment should be shorter now
    #expect(updatedResult.segmentAR.distanceMeters < initialARDistance)
  }

  @Test
  func `Off-path height and RF changes reuse cached profiles without network fetch`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    let fetchCountAfterPoints = await mockService.fetchCount

    // Place repeater off-path and do initial analysis (triggers network fetch)
    let repeaterCoord = CLLocationCoordinate2D(latitude: 37.79, longitude: -122.35)
    viewModel.setRepeaterOffPath(coordinate: repeaterCoord)

    // Wait for repeater elevation fetch
    try await waitUntil("repeater elevation should load") {
      viewModel.repeaterPoint?.groundElevation != nil
    }

    viewModel.analyzeWithRepeater()
    try await waitUntil(timeout: .seconds(5), "off-path analysis should complete") {
      if case .relayResult = viewModel.analysisStatus { return true }
      return false
    }

    let fetchCountAfterAnalysis = await mockService.fetchCount
    #expect(fetchCountAfterAnalysis > fetchCountAfterPoints)

    // Change repeater height — should NOT trigger new fetches
    viewModel.updateRepeaterHeight(meters: 25)
    viewModel.analyzeWithRepeater()

    let fetchCountAfterHeight = await mockService.fetchCount
    #expect(fetchCountAfterHeight == fetchCountAfterAnalysis)

    // Verify we still have a relay result
    if case .relayResult = viewModel.analysisStatus {
      // expected
    } else {
      Issue.record("Expected relayResult after height change, got: \(viewModel.analysisStatus)")
    }

    // Change RF params — should NOT trigger new fetches
    viewModel.refractionK = 4.0 / 3.0

    let fetchCountAfterRF = await mockService.fetchCount
    #expect(fetchCountAfterRF == fetchCountAfterAnalysis)

    if case .relayResult = viewModel.analysisStatus {
      // expected
    } else {
      Issue.record("Expected relayResult after RF change, got: \(viewModel.analysisStatus)")
    }
  }
}

// MARK: - AnalysisStatus Relay Extension Tests

@Suite("AnalysisStatus Relay Extension")
struct AnalysisStatusRelayTests {
  @Test
  func `relayResult case stores RelayPathAnalysisResult`() {
    let segmentAR = SegmentAnalysisResult(
      startLabel: "A", endLabel: "R",
      clearanceStatus: .clear,
      distanceMeters: 5000,
      worstClearancePercent: 85
    )
    let segmentRB = SegmentAnalysisResult(
      startLabel: "R", endLabel: "B",
      clearanceStatus: .clear,
      distanceMeters: 3000,
      worstClearancePercent: 90
    )
    let relayResult = RelayPathAnalysisResult(segmentAR: segmentAR, segmentRB: segmentRB)

    let status = AnalysisStatus.relayResult(relayResult)

    if case let .relayResult(result) = status {
      #expect(result.totalDistanceMeters == 8000)
    } else {
      Issue.record("Expected relayResult case")
    }
  }

  @Test
  func `relayResult equals relayResult with same data`() {
    let segmentAR = SegmentAnalysisResult(
      startLabel: "A", endLabel: "R",
      clearanceStatus: .clear,
      distanceMeters: 5000,
      worstClearancePercent: 85
    )
    let segmentRB = SegmentAnalysisResult(
      startLabel: "R", endLabel: "B",
      clearanceStatus: .clear,
      distanceMeters: 3000,
      worstClearancePercent: 90
    )
    let relayResult = RelayPathAnalysisResult(segmentAR: segmentAR, segmentRB: segmentRB)

    let status1 = AnalysisStatus.relayResult(relayResult)
    let status2 = AnalysisStatus.relayResult(relayResult)

    #expect(status1 == status2)
  }
}

// MARK: - Frequency Parsing Tests

@Suite("Frequency Parsing")
@MainActor
struct FrequencyParsingTests {
  @Test
  func `Parses a plain dot-decimal value`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("868.5") == 868.5)
  }

  @Test
  func `Parses a comma-decimal value the same as dot-decimal`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("868,5") == 868.5)
  }

  @Test
  func `Parses an integer value`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("906") == 906.0)
  }

  @Test
  func `Rejects empty input`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("") == nil)
  }

  @Test
  func `Rejects non-numeric input`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("abc") == nil)
  }

  @Test
  func `Rejects zero`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("0") == nil)
  }

  @Test
  func `Rejects negative values`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    #expect(viewModel.parseFrequency("-906") == nil)
  }

  @Test
  func `Editing format round-trips an integer back through the parser`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    let formatted = viewModel.formatFrequencyForEditing(906.0)
    #expect(formatted == "906")
    #expect(viewModel.parseFrequency(formatted) == 906.0)
  }

  @Test
  func `Editing format uses a dot decimal separator and round-trips`() {
    let viewModel = LineOfSightViewModel(elevationService: MockElevationService())

    let formatted = viewModel.formatFrequencyForEditing(868.5)
    #expect(formatted == "868.5")
    #expect(viewModel.parseFrequency(formatted) == 868.5)
  }
}

// MARK: - Analysis Task Hygiene Tests

@Suite("Analysis Task Hygiene")
@MainActor
struct AnalysisTaskHygieneTests {
  @Test
  func `Re-analysis after an RF change clears isAnalyzing`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    viewModel.analyze()
    try await waitForAnalysisResult(viewModel)

    // Changing the k-factor re-runs analysis with the cached profile
    viewModel.refractionK = 4.0 / 3.0

    try await waitUntil("re-analysis should clear isAnalyzing") {
      !viewModel.isAnalyzing
    }
    #expect(viewModel.isAnalyzing == false)
    if case .result = viewModel.analysisStatus {
      // expected
    } else {
      Issue.record("Expected result status after re-analysis, got: \(viewModel.analysisStatus)")
    }
  }

  @Test
  func `Re-analysis that supersedes an in-flight analysis does not strand isAnalyzing`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    // Keep the analysis profile fetch in flight so the RF change cancels it
    await mockService.setFetchDelay(.milliseconds(300))

    viewModel.analyze()
    #expect(viewModel.isAnalyzing == true)

    // Seed a cached profile so the RF-change re-analysis path cancels the
    // still-running analyze task instead of bailing at its guard
    let profile = [
      ElevationSample(coordinate: sanFrancisco, elevation: 100, distanceFromAMeters: 0),
      ElevationSample(coordinate: oakland, elevation: 100, distanceFromAMeters: 1000)
    ]
    viewModel.setElevationProfileForTesting(profile)

    viewModel.refractionK = 4.0 / 3.0

    try await waitUntil("superseding re-analysis should clear isAnalyzing") {
      !viewModel.isAnalyzing
    }
    #expect(viewModel.isAnalyzing == false)
  }

  @Test
  func `clearRepeater cancels the in-flight off-path elevation fetch`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    // Hold the repeater elevation fetch open so we can cancel it mid-flight
    await mockService.setFetchDelay(.milliseconds(300))

    let originalCoord = CLLocationCoordinate2D(latitude: 37.79, longitude: -122.35)
    viewModel.setRepeaterOffPath(coordinate: originalCoord)
    #expect(viewModel.repeaterPoint?.groundElevation == nil)

    // Clearing the repeater must cancel the in-flight fetch
    viewModel.clearRepeater()
    #expect(viewModel.repeaterPoint == nil)

    // Re-add an off-path repeater directly (bypassing setRepeaterOffPath, which
    // would cancel on its own) so a surviving stale fetch would land here
    let newCoord = CLLocationCoordinate2D(latitude: 37.70, longitude: -122.30)
    viewModel.repeaterPoint = RepeaterPoint(
      coordinate: newCoord,
      groundElevation: nil,
      isOnPath: false,
      pathFraction: 0.5
    )

    // Wait past the original fetch's delay; a cancelled fetch never writes
    try await Task.sleep(for: .milliseconds(500))
    #expect(viewModel.repeaterPoint?.groundElevation == nil)
  }

  @Test
  func `Cancelled off-path analysis does not surface an error or strand isAnalyzing`() async throws {
    let mockService = MockElevationService()
    let viewModel = LineOfSightViewModel(elevationService: mockService)

    viewModel.setPointA(coordinate: sanFrancisco)
    viewModel.setPointB(coordinate: oakland)
    try await waitForBothPointElevations(viewModel)

    let repeaterCoord = CLLocationCoordinate2D(latitude: 37.79, longitude: -122.35)
    viewModel.setRepeaterOffPath(coordinate: repeaterCoord)
    try await waitUntil("repeater elevation should load") {
      viewModel.repeaterPoint?.groundElevation != nil
    }

    // Hold the off-path profile fetch open, start it, then cancel via clear().
    // The off-path task sets isAnalyzing asynchronously, so wait for the start.
    await mockService.setFetchDelay(.milliseconds(300))
    viewModel.analyzeWithRepeater()
    try await waitUntil("off-path analysis should start") {
      viewModel.isAnalyzing
    }

    viewModel.clear()

    try await waitUntil("cancelled off-path analysis should clear isAnalyzing") {
      !viewModel.isAnalyzing
    }
    #expect(viewModel.isAnalyzing == false)
    // clear() resets status to idle; a cancelled fetch must not flip it to error
    if case .error = viewModel.analysisStatus {
      Issue.record("Cancelled off-path analysis surfaced a user-visible error")
    }
  }
}


// MARK: - NameIdentityPersisting

extension MockPersistenceStore {
  func updateMessageSentAsNodeName(id _: UUID, name _: String) async throws {}
  func updateRemoteNodeSessionName(id _: UUID, name _: String) async throws {}
  func markOwnReactions(radioID _: UUID, selfNames _: Set<String>) async throws -> Int { 0 }
  func removeRoomPostsFiledAsDirectMessages(radioID _: UUID, roomContactIDs _: [UUID]) async throws -> [MessageDTO] { [] }
}
