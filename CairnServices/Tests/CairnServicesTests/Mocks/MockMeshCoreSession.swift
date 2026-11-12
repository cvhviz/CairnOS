import Foundation
import MeshCore

/// Mock implementation of MeshCoreSessionProtocol for testing.
///
/// Configure the mock by setting the stub properties before calling methods.
/// Track method calls by examining the recorded invocations.
///
/// Also conforms to ``AdvertisingSessionOps`` so services such as
/// `AdvertisementService` can be exercised without a second fake session type.
public actor MockMeshCoreSession: MeshCoreSessionProtocol, AdvertisingSessionOps {
  // MARK: - Connection State

  public var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { continuation in
      continuation.yield(stubbedConnectionState)
      continuation.finish()
    }
  }

  /// Self info to return from currentSelfInfo. Configure via `setCurrentSelfInfo(_:)`.
  public private(set) var currentSelfInfo: SelfInfo?

  // MARK: - Radio Channel

  /// The channel to return from currentChannelConfig. Configure via `setCurrentChannelConfig(_:since:)`.
  public private(set) var currentChannelConfig: RadioChannelConfig?

  /// When `currentChannelConfig` was set; `nil` with no config.
  public private(set) var channelConfigSince: Date?

  /// Sets the channel the radio reports (`nil` while it is unconfirmed, as during a retune).
  public func setCurrentChannelConfig(_ config: RadioChannelConfig?, since: Date? = Date()) {
    currentChannelConfig = config
    channelConfigSince = config == nil ? nil : since
  }

  // MARK: - Transmissions

  /// Active `transmissions()` listeners, keyed so a terminated stream can deregister itself.
  private var transmissionContinuations: [UUID: AsyncStream<TransmissionEvent>.Continuation] = [:]

  public func transmissions() -> AsyncStream<TransmissionEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<TransmissionEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    transmissionContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeTransmissionContinuation(id: id) }
    }
    return stream
  }

  private func removeTransmissionContinuation(id: UUID) {
    transmissionContinuations[id] = nil
  }

  /// Number of active `transmissions()` listeners; lets tests wait until a consumer has
  /// subscribed before emitting.
  public var transmissionSubscriptionCount: Int {
    transmissionContinuations.count
  }

  /// Emits a transmission event to every `transmissions()` listener.
  public func emitTransmission(_ event: TransmissionEvent) {
    for continuation in transmissionContinuations.values {
      continuation.yield(event)
    }
  }

  /// Finishes every `transmissions()` stream, as a stopped session does.
  public func finishTransmissionStreams() {
    for continuation in transmissionContinuations.values {
      continuation.finish()
    }
    transmissionContinuations.removeAll()
  }

  // MARK: - Event Streaming

  private struct EventSubscription {
    let filter: EventFilter?
    let continuation: AsyncStream<MeshEvent>.Continuation
  }

  /// Active `events()` subscriptions, keyed so a terminated stream can deregister itself.
  private var eventSubscriptions: [UUID: EventSubscription] = [:]

  public func events() async -> AsyncStream<MeshEvent> {
    makeEventStream(filter: nil)
  }

  public func events(filter: EventFilter) async -> AsyncStream<MeshEvent> {
    makeEventStream(filter: filter)
  }

  private func makeEventStream(filter: EventFilter?) -> AsyncStream<MeshEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<MeshEvent>.makeStream()
    eventSubscriptions[id] = EventSubscription(filter: filter, continuation: continuation)
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeEventSubscription(id: id) }
    }
    return stream
  }

  private func removeEventSubscription(id: UUID) {
    eventSubscriptions[id] = nil
  }

  /// Number of active `events()` subscriptions; lets tests wait until a
  /// consumer has subscribed before yielding events.
  public var eventSubscriptionCount: Int {
    eventSubscriptions.count
  }

  /// Yields an event to every active `events()` subscriber whose filter matches.
  public func yieldEvent(_ event: MeshEvent) {
    for subscription in eventSubscriptions.values where subscription.filter?.matches(event) != false {
      subscription.continuation.yield(event)
    }
  }

  /// Finishes every active `events()` stream, ending subscribers' for-await loops.
  public func finishEventStreams() {
    for subscription in eventSubscriptions.values {
      subscription.continuation.finish()
    }
    eventSubscriptions.removeAll()
  }

  // MARK: - Stubs

  /// The connection state to return from connectionState stream
  public var stubbedConnectionState: ConnectionState = .disconnected

  /// Result to return from sendMessage
  public var stubbedSendMessageResult: Result<MessageSentInfo, Error> = .success(
    MessageSentInfo(route: 0, expectedAck: Data([0x01, 0x02, 0x03, 0x04]), suggestedTimeoutMs: 5000)
  )

  /// Result to return from sendChannelMessage
  public var stubbedSendChannelMessageError: Error?

  /// Contacts to return from getContacts
  public var stubbedContacts: [MeshContact] = []

  /// Reported total for `getContactsReportingTotal`. `nil` returns
  /// `stubbedContacts.count` (a complete stream). Set it above the stubbed
  /// count to simulate a truncated stream.
  public var stubbedReportedTotal: Int?

  /// When `true`, `getContactsReportingTotal` returns a `nil` total, simulating a
  /// reply that carried no `contactsStart` header.
  public var stubbedReportsNoTotal = false

  /// Error to throw from getContacts
  public var stubbedGetContactsError: Error?

  /// Contact to return from getContact (by public key) when no per-key stub is set.
  public var stubbedContact: MeshContact?

  /// Error to throw from getContact when no per-key error is set.
  public var stubbedGetContactError: Error?

  /// Per-key contact results for `getContact`. Takes precedence over `stubbedContact`.
  public var stubbedContactsByKey: [Data: MeshContact?] = [:]

  /// When set, the nameless type 0 entries in `stubbedContactsByKey` go once this many more
  /// nameless entries are added, as a radio's reserved slots recycle.
  public var placeholdersRecycleAfterAdds: Int?

  /// Per-key errors for `getContact`. Takes precedence over `stubbedGetContactError`.
  public var stubbedGetContactErrorsByKey: [Data: Error] = [:]

  /// Per-key hold gates: when present, `getContact` suspends until the continuation is resumed.
  private var getContactHoldContinuations: [Data: CheckedContinuation<Void, Never>] = [:]
  private var getContactHoldRequested: Set<Data> = []

  /// When true, the next `getContacts` parks until `releaseGetContacts()`.
  private var getContactsHoldRequested = false
  private var getContactsHoldActive = false
  private var getContactsHoldContinuation: CheckedContinuation<Void, Never>?
  private var getContactsStartWaiters: [CheckedContinuation<Void, Never>] = []

  /// Error to throw from addContact
  public var stubbedAddContactError: Error?

  /// Error to throw from removeContact
  public var stubbedRemoveContactError: Error?

  /// Error to throw from resetPath
  public var stubbedResetPathError: Error?

  /// Result to return from sendPathDiscovery
  public var stubbedSendPathDiscoveryResult: Result<MessageSentInfo, Error> = .success(
    MessageSentInfo(route: 0, expectedAck: Data([0x01, 0x02, 0x03, 0x04]), suggestedTimeoutMs: 5000)
  )

  /// Channel info to return from getChannel, keyed by index
  public var stubbedChannels: [UInt8: ChannelInfo] = [:]

  public func setStubbedSendCommandResult(_ result: Result<MessageSentInfo, Error>) {
    stubbedSendCommandResult = result
  }

  public func setStubbedChannels(_ channels: [UInt8: ChannelInfo]) {
    stubbedChannels = channels
  }

  /// Error to throw from getChannel
  public var stubbedGetChannelError: Error?

  /// Errors to throw from getChannel for single slots, keyed by index (a slot that does not answer)
  public var stubbedGetChannelErrorsByIndex: [UInt8: Error] = [:]

  public func setStubbedGetChannelErrorsByIndex(_ errors: [UInt8: Error]) {
    stubbedGetChannelErrorsByIndex = errors
  }

  /// Error to throw from setChannel
  public var stubbedSetChannelError: Error?

  /// Event to return from waitForEvent (nil simulates a timeout)
  public var stubbedWaitForEventResult: MeshEvent?

  /// Result to return from getMessage
  public var stubbedGetMessageResult: Result<MessageResult, Error> = .success(.noMoreMessages)

  /// Results for successive `getMessage` calls, consumed FIFO before `stubbedGetMessageResult`.
  public var stubbedGetMessageResults: [Result<MessageResult, Error>] = []

  /// Runs inside each `getMessage` call (1-based call number) before it answers, e.g. to
  /// deliver an event as another fetch's answer would arrive mid-drain.
  public var getMessageHook: (@Sendable (_ call: Int) async -> Void)?

  /// Number of `requestMessageDrain()` calls.
  public private(set) var requestMessageDrainCallCount = 0

  public func setGetMessageResults(_ results: [Result<MessageResult, Error>]) {
    stubbedGetMessageResults = results
  }

  public func setGetMessageHook(_ hook: (@Sendable (_ call: Int) async -> Void)?) {
    getMessageHook = hook
  }

  /// Results to return from successive `sendLogin` calls, consumed FIFO.
  public var stubbedSendLoginResults: [Result<MessageSentInfo, Error>] = []

  /// Result to return from `sendCommand`. The short suggested timeout keeps
  /// CLI polling loops in tests brief.
  public var stubbedSendCommandResult: Result<MessageSentInfo, Error> = .success(
    MessageSentInfo(route: 0, expectedAck: Data(), suggestedTimeoutMs: 100)
  )

  /// Result to return from `requestStatus` when the FIFO list is empty.
  public var stubbedRequestStatusResult: Result<StatusResponse, Error> =
    .failure(NotStubbed.method("requestStatus"))

  /// Results consumed FIFO by successive `requestStatus` calls. When non-empty,
  /// takes precedence over `stubbedRequestStatusResult`.
  public var stubbedRequestStatusResults: [Result<StatusResponse, Error>] = []

  /// Result to return from `requestTelemetry` when the FIFO list is empty.
  public var stubbedRequestTelemetryResult: Result<TelemetryResponse, Error> =
    .failure(NotStubbed.method("requestTelemetry"))

  /// Results consumed FIFO by successive `requestTelemetry` calls.
  public var stubbedRequestTelemetryResults: [Result<TelemetryResponse, Error>] = []

  /// Result to return from `requestOwnerInfo`.
  public var stubbedRequestOwnerInfoResult: Result<OwnerInfoResponse, Error> =
    .failure(NotStubbed.method("requestOwnerInfo"))

  /// Results consumed FIFO by successive `requestOwnerInfo` calls.
  public var stubbedRequestOwnerInfoResults: [Result<OwnerInfoResponse, Error>] = []

  // MARK: - Recorded Invocations

  public struct SendMessageInvocation: Sendable, Equatable {
    public let destination: Data
    public let text: String
    public let timestamp: Date
    public let attempt: UInt8
  }

  public struct SendChannelMessageInvocation: Sendable, Equatable {
    public let channel: UInt8
    public let text: String
    public let timestamp: Date
  }

  public struct AddContactInvocation: Sendable, Equatable {
    public let contact: MeshContact
  }

  public struct SendLoginInvocation: Sendable, Equatable {
    public let destination: Data
    public let password: String
  }

  public struct SendCommandInvocation: Sendable, Equatable {
    public let destination: Data
    public let command: String
    /// The frame's text type: `.cliData` for `sendCommand`, `.cliCommand` for `sendCompanionCommand`.
    public var textType: MeshCore.TextType = .cliData
  }

  public struct ChangeContactFlagsInvocation: Sendable, Equatable {
    public let publicKey: Data
    public let flags: ContactFlags
    /// The rest of the record the write carried, so tests can see whose fields it used.
    public var outPathLength: UInt8 = 0xFF
    public var outPath = Data()
  }

  public struct SetChannelInvocation: Sendable, Equatable {
    public let index: UInt8
    public let name: String
    public let secret: Data
  }

  public struct WaitForEventInvocation: Sendable {
    public let filter: EventFilter
    public let timeout: TimeInterval?
  }

  public private(set) var sendMessageInvocations: [SendMessageInvocation] = []
  public private(set) var sendChannelMessageInvocations: [SendChannelMessageInvocation] = []
  public private(set) var getContactsInvocations: [Date?] = []
  public private(set) var getContactPublicKeys: [Data] = []
  public private(set) var addContactInvocations: [AddContactInvocation] = []
  public private(set) var sendLoginInvocations: [SendLoginInvocation] = []
  public private(set) var sendCommandInvocations: [SendCommandInvocation] = []
  public private(set) var changeContactFlagsInvocations: [ChangeContactFlagsInvocation] = []
  public private(set) var removeContactPublicKeys: [Data] = []
  public private(set) var resetPathPublicKeys: [Data] = []
  public private(set) var sendPathDiscoveryDestinations: [Data] = []
  public private(set) var getChannelIndices: [UInt8] = []
  public private(set) var setChannelInvocations: [SetChannelInvocation] = []
  public private(set) var waitForEventInvocations: [WaitForEventInvocation] = []
  public private(set) var getMessageTimeouts: [TimeInterval?] = []
  public private(set) var startAutoMessageFetchingCallCount = 0
  public private(set) var stopAutoMessageFetchingCallCount = 0

  // MARK: - Initialization

  public init() {}

  // MARK: - Test Configuration

  /// Sets the contacts returned by `getContacts(since:)`. Actor isolation forbids writing the
  /// stub property directly from a test, so configuration goes through this isolated setter.
  public func setStubbedContacts(_ contacts: [MeshContact]) {
    stubbedContacts = contacts
  }

  /// Sets the reported total for `getContactsReportingTotal` (isolated setter).
  /// Set it above the stubbed contact count to simulate a truncated stream.
  public func setStubbedReportedTotal(_ total: Int?) {
    stubbedReportedTotal = total
  }

  /// Makes `getContactsReportingTotal` return a `nil` total (no `contactsStart`
  /// header), through an isolated setter.
  public func setStubbedReportsNoTotal(_ reportsNoTotal: Bool) {
    stubbedReportsNoTotal = reportsNoTotal
  }

  /// Sets the self info returned by `currentSelfInfo`, through an isolated setter
  /// for the same actor-isolation reason as `setStubbedContacts`.
  public func setCurrentSelfInfo(_ selfInfo: SelfInfo?) {
    currentSelfInfo = selfInfo
  }

  /// Sets the results returned by successive `sendLogin` calls (isolated setter).
  public func setSendLoginResults(_ results: [Result<MessageSentInfo, Error>]) {
    stubbedSendLoginResults = results
  }

  /// Sets the result returned by `requestStatus` (isolated setter).
  public func setRequestStatusResult(_ result: Result<StatusResponse, Error>) {
    stubbedRequestStatusResult = result
    stubbedRequestStatusResults = []
  }

  /// Sets FIFO results for successive `requestStatus` calls (isolated setter).
  public func setRequestStatusResults(_ results: [Result<StatusResponse, Error>]) {
    stubbedRequestStatusResults = results
  }

  /// Sets FIFO results for successive `requestTelemetry` calls (isolated setter).
  public func setRequestTelemetryResults(_ results: [Result<TelemetryResponse, Error>]) {
    stubbedRequestTelemetryResults = results
  }

  /// Sets FIFO results for successive `requestOwnerInfo` calls (isolated setter).
  public func setRequestOwnerInfoResults(_ results: [Result<OwnerInfoResponse, Error>]) {
    stubbedRequestOwnerInfoResults = results
  }

  /// Sets the error thrown by `addContact` (isolated setter).
  public func setAddContactError(_ error: Error?) {
    stubbedAddContactError = error
  }

  /// Sets the contact returned by `getContact` for a specific public key.
  public func setPlaceholdersRecycleAfterAdds(_ count: Int?) {
    placeholdersRecycleAfterAdds = count
  }

  public func setStubbedContact(_ contact: MeshContact?, for publicKey: Data) {
    stubbedContactsByKey[publicKey] = contact
  }

  /// Sets the error thrown by `getContact` for a specific public key.
  public func setGetContactError(_ error: Error?, for publicKey: Data) {
    if let error {
      stubbedGetContactErrorsByKey[publicKey] = error
    } else {
      stubbedGetContactErrorsByKey.removeValue(forKey: publicKey)
    }
  }

  /// Causes the next `getContact` for `publicKey` to suspend until `releaseGetContact(for:)` is called.
  public func holdNextGetContact(for publicKey: Data) {
    getContactHoldRequested.insert(publicKey)
  }

  /// Releases a held `getContact` for `publicKey`.
  /// Does not clear a pending `holdNextGetContact` for a *future* call on the same key.
  public func releaseGetContact(for publicKey: Data) {
    if let continuation = getContactHoldContinuations.removeValue(forKey: publicKey) {
      continuation.resume()
    }
  }

  /// Whether a `getContact` for `publicKey` is currently suspended on a hold gate.
  public func isGetContactHeld(for publicKey: Data) -> Bool {
    getContactHoldContinuations[publicKey] != nil
  }

  /// Causes the next `getContacts` to suspend until `releaseGetContacts()` is called.
  public func holdNextGetContacts() {
    getContactsHoldRequested = true
  }

  /// Suspends until a held `getContacts` has entered its gate (claim + body in progress).
  public func waitForGetContactsStart() async {
    if getContactsHoldActive { return }
    await withCheckedContinuation { getContactsStartWaiters.append($0) }
  }

  /// Releases a held `getContacts` call.
  public func releaseGetContacts() {
    getContactsHoldContinuation?.resume()
    getContactsHoldContinuation = nil
  }

  /// Whether a `getContacts` call is currently suspended on the hold gate.
  public func isGetContactsHeld() -> Bool {
    getContactsHoldContinuation != nil
  }

  // MARK: - Protocol Methods

  public func sendMessage(to destination: Data, text: String, timestamp: Date, attempt: UInt8) async throws -> MessageSentInfo {
    sendMessageInvocations.append(SendMessageInvocation(destination: destination, text: text, timestamp: timestamp, attempt: attempt))
    switch stubbedSendMessageResult {
    case let .success(info):
      return info
    case let .failure(error):
      throw error
    }
  }

  public func sendChannelMessage(channel: UInt8, text: String, timestamp: Date) async throws {
    sendChannelMessageInvocations.append(SendChannelMessageInvocation(channel: channel, text: text, timestamp: timestamp))
    if let error = stubbedSendChannelMessageError {
      throw error
    }
  }

  public func getContacts(since lastModified: Date?) async throws -> [MeshContact] {
    try await getContactsReportingTotal(since: lastModified).contacts
  }

  public func getContactsReportingTotal(since lastModified: Date?) async throws -> ContactFetchResult {
    getContactsInvocations.append(lastModified)
    if getContactsHoldRequested {
      getContactsHoldRequested = false
      getContactsHoldActive = true
      while !getContactsStartWaiters.isEmpty {
        getContactsStartWaiters.removeFirst().resume()
      }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        getContactsHoldContinuation = continuation
      }
      getContactsHoldActive = false
    }
    if let error = stubbedGetContactsError {
      throw error
    }
    return ContactFetchResult(
      contacts: stubbedContacts,
      reportedTotal: stubbedReportsNoTotal ? nil : (stubbedReportedTotal ?? stubbedContacts.count)
    )
  }

  public func getContact(publicKey: Data) async throws -> MeshContact? {
    getContactPublicKeys.append(publicKey)

    if getContactHoldRequested.contains(publicKey) {
      getContactHoldRequested.remove(publicKey)
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        getContactHoldContinuations[publicKey] = continuation
      }
    }

    if let error = stubbedGetContactErrorsByKey[publicKey] {
      throw error
    }
    if let error = stubbedGetContactError {
      throw error
    }
    if let keyed = stubbedContactsByKey[publicKey] {
      return keyed
    }
    return stubbedContact
  }

  // MARK: - AdvertisingSessionOps

  public func sendAdvertisement(flood: Bool) async throws {}

  public func setName(_ name: String) async throws {}

  public func setCoordinates(latitude: Double, longitude: Double) async throws {}

  public func addContact(_ contact: MeshContact) async throws {
    addContactInvocations.append(AddContactInvocation(contact: contact))
    if let error = stubbedAddContactError {
      throw error
    }
    if contact.isTemporaryPlaceholder, let remaining = placeholdersRecycleAfterAdds {
      placeholdersRecycleAfterAdds = remaining - 1
      if remaining <= 1 {
        stubbedContactsByKey = stubbedContactsByKey.filter { $0.value?.isTemporaryPlaceholder != true }
      }
    }
  }

  public func removeContact(publicKey: Data) async throws {
    removeContactPublicKeys.append(publicKey)
    if let error = stubbedRemoveContactError {
      throw error
    }
  }

  public func resetPath(publicKey: Data) async throws {
    resetPathPublicKeys.append(publicKey)
    if let error = stubbedResetPathError {
      throw error
    }
  }

  public func sendPathDiscovery(to destination: Data) async throws -> MessageSentInfo {
    sendPathDiscoveryDestinations.append(destination)
    switch stubbedSendPathDiscoveryResult {
    case let .success(info):
      return info
    case let .failure(error):
      throw error
    }
  }

  public func getChannel(index: UInt8) async throws -> ChannelInfo {
    getChannelIndices.append(index)
    if let error = stubbedGetChannelError ?? stubbedGetChannelErrorsByIndex[index] {
      throw error
    }
    if let channel = stubbedChannels[index] {
      return channel
    }
    // Return a default empty channel
    return ChannelInfo(index: index, name: "", secret: Data(repeating: 0, count: 16))
  }

  public func getChannels(indices: [UInt8]) async throws -> (received: [ChannelInfo], missing: [UInt8]) {
    getChannelIndices.append(contentsOf: indices)
    if let error = stubbedGetChannelError {
      throw error
    }
    // The firmware answers every requested index, so the mock returns one per request.
    let received = indices.map { index in
      stubbedChannels[index] ?? ChannelInfo(index: index, name: "", secret: Data(repeating: 0, count: 16))
    }
    return (received: received, missing: [])
  }

  public func setChannel(index: UInt8, name: String, secret: Data) async throws {
    setChannelInvocations.append(SetChannelInvocation(index: index, name: name, secret: secret))
    if let error = stubbedSetChannelError {
      throw error
    }
  }

  public func shareContact(publicKey: Data) async throws {
    // Stub - not used in current tests
  }

  public func exportContact(publicKey: Data?) async throws -> String {
    // Stub - not used in current tests
    ""
  }

  public func importContact(cardData: Data) async throws {
    // Stub - not used in current tests
  }

  public func changeContactFlags(_ contact: MeshContact, flags: ContactFlags) async throws {
    changeContactFlagsInvocations.append(ChangeContactFlagsInvocation(
      publicKey: contact.publicKey,
      flags: flags,
      outPathLength: contact.outPathLength,
      outPath: contact.outPath
    ))
    // The radio now holds the new flags, as the firmware's record would.
    if stubbedContactsByKey[contact.publicKey] != nil {
      stubbedContactsByKey[contact.publicKey] = MeshContact(
        id: contact.id,
        publicKey: contact.publicKey,
        type: contact.type,
        typeRawValue: contact.typeRawValue,
        flags: flags,
        outPathLength: contact.outPathLength,
        outPath: contact.outPath,
        advertisedName: contact.advertisedName,
        lastAdvertisement: contact.lastAdvertisement,
        latitude: contact.latitude,
        longitude: contact.longitude,
        lastModified: contact.lastModified
      )
    }
  }

  public func waitForEvent(filter: EventFilter, timeout: TimeInterval?) async -> MeshEvent? {
    waitForEventInvocations.append(WaitForEventInvocation(filter: filter, timeout: timeout))
    return stubbedWaitForEventResult
  }

  // MARK: - Cairn chat history

  /// QUERY's answer; nil = answers as firmware without the feature.
  public var stubbedHistoryQuery: CairnHistoryPageReply?
  /// PAGE answers, one per call in order (an empty list: a reply with nothing past the cursor).
  public var stubbedHistoryPages: [CairnHistoryPage] = []
  public private(set) var historyPageRequests: [UInt32] = []
  public private(set) var historyQueryCount = 0

  public func setHistory(query: CairnHistoryPageReply?, pages: [CairnHistoryPage]) {
    stubbedHistoryQuery = query
    stubbedHistoryPages = pages
  }

  public func queryCairnHistory() async throws -> CairnHistoryPageReply {
    historyQueryCount += 1
    guard let stubbedHistoryQuery else {
      throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
    }
    return stubbedHistoryQuery
  }

  public func fetchCairnHistoryPage(sinceSeq: UInt32, max _: UInt8, inactivity _: TimeInterval) async throws -> CairnHistoryPage {
    historyPageRequests.append(sinceSeq)
    guard !stubbedHistoryPages.isEmpty else {
      let id = stubbedHistoryQuery?.storeID ?? 0
      return CairnHistoryPage(reply: CairnHistoryPageReply(status: .ok, storeID: id, total: 0, page: 0), records: [], end: nil)
    }
    return stubbedHistoryPages.removeFirst()
  }

  public func getMessage(timeout: TimeInterval?) async throws -> MessageResult {
    getMessageTimeouts.append(timeout)
    if let getMessageHook {
      await getMessageHook(getMessageTimeouts.count)
    }
    let stubbed = stubbedGetMessageResults.isEmpty ? stubbedGetMessageResult : stubbedGetMessageResults.removeFirst()
    switch stubbed {
    case let .success(result):
      return result
    case let .failure(error):
      throw error
    }
  }

  public func startAutoMessageFetching() async {
    startAutoMessageFetchingCallCount += 1
  }

  public func stopAutoMessageFetching() {
    stopAutoMessageFetchingCallCount += 1
  }

  public func requestMessageDrain() async {
    requestMessageDrainCallCount += 1
  }

  // MARK: - Test Helpers

  /// Error thrown by remote-access methods that a given test has not configured.
  enum NotStubbed: Error { case method(String) }

  /// Resets all recorded invocations
  public func reset() {
    sendMessageInvocations = []
    sendChannelMessageInvocations = []
    getContactsInvocations = []
    getContactPublicKeys = []
    addContactInvocations = []
    changeContactFlagsInvocations = []
    sendLoginInvocations = []
    sendCommandInvocations = []
    removeContactPublicKeys = []
    resetPathPublicKeys = []
    sendPathDiscoveryDestinations = []
    getChannelIndices = []
    setChannelInvocations = []
    waitForEventInvocations = []
    getMessageTimeouts = []
    startAutoMessageFetchingCallCount = 0
    stopAutoMessageFetchingCallCount = 0
  }
}

// MARK: - RemoteAccessSessionOps

extension MockMeshCoreSession: RemoteAccessSessionOps {
  public func sendLogin(to destination: Data, password: String) async throws -> MessageSentInfo {
    sendLoginInvocations.append(SendLoginInvocation(destination: destination, password: password))
    guard !stubbedSendLoginResults.isEmpty else { throw NotStubbed.method("sendLogin") }
    switch stubbedSendLoginResults.removeFirst() {
    case let .success(info): return info
    case let .failure(error): throw error
    }
  }

  public func sendLogout(to destination: Data) async throws {}

  public func sendCommand(to destination: Data, command: String, timestamp: Date) async throws -> MessageSentInfo {
    sendCommandInvocations.append(SendCommandInvocation(destination: destination, command: command))
    switch stubbedSendCommandResult {
    case let .success(info): return info
    case let .failure(error): throw error
    }
  }

  public func sendCompanionCommand(to destination: Data, command: String, timestamp: Date) async throws -> MessageSentInfo {
    sendCommandInvocations.append(
      SendCommandInvocation(destination: destination, command: command, textType: .cliCommand)
    )
    switch stubbedSendCommandResult {
    case let .success(info): return info
    case let .failure(error): throw error
    }
  }

  public func sendKeepAlive(to publicKey: Data, syncSince: UInt32) async throws -> MessageSentInfo {
    throw NotStubbed.method("sendKeepAlive")
  }

  public func requestOwnerInfo(from publicKey: Data) async throws -> OwnerInfoResponse {
    if !stubbedRequestOwnerInfoResults.isEmpty {
      switch stubbedRequestOwnerInfoResults.removeFirst() {
      case let .success(response): return response
      case let .failure(error): throw error
      }
    }
    switch stubbedRequestOwnerInfoResult {
    case let .success(response): return response
    case let .failure(error): throw error
    }
  }

  public func requestStatus(from publicKey: Data, type: ContactType) async throws -> StatusResponse {
    if !stubbedRequestStatusResults.isEmpty {
      switch stubbedRequestStatusResults.removeFirst() {
      case let .success(response): return response
      case let .failure(error): throw error
      }
    }
    switch stubbedRequestStatusResult {
    case let .success(response): return response
    case let .failure(error): throw error
    }
  }

  public func requestTelemetry(from publicKey: Data) async throws -> TelemetryResponse {
    if !stubbedRequestTelemetryResults.isEmpty {
      switch stubbedRequestTelemetryResults.removeFirst() {
      case let .success(response): return response
      case let .failure(error): throw error
      }
    }
    switch stubbedRequestTelemetryResult {
    case let .success(response): return response
    case let .failure(error): throw error
    }
  }

  public func requestNeighbours(
    from publicKey: Data,
    count: UInt8,
    offset: UInt16,
    orderBy: UInt8,
    pubkeyPrefixLength: UInt8
  ) async throws -> NeighboursResponse {
    throw NotStubbed.method("requestNeighbours")
  }

  public func sendMessageWithRetry(
    to destination: Data,
    text: String,
    timestamp: Date,
    maxAttempts: Int,
    floodAfter: Int,
    maxFloodAttempts: Int,
    timeout: TimeInterval?
  ) async throws -> MessageSentInfo? {
    throw NotStubbed.method("sendMessageWithRetry")
  }
}
