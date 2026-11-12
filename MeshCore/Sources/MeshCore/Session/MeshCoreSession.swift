import Foundation
import os

/// Main session actor for MeshCore device communication.
///
/// `MeshCoreSession` coordinates all communication with a MeshCore mesh networking device
/// over a transport layer (typically Bluetooth LE). It provides high-level APIs for:
///
/// - **Connection management**: Start and stop device sessions
/// - **Contact discovery**: Query and manage the device's contact list
/// - **Messaging**: Send and receive messages to/from mesh contacts
/// - **Device configuration**: Set device name, coordinates, radio parameters
/// - **Telemetry**: Request sensor data and device statistics
///
/// ## Usage
///
/// ```swift
/// // Create a session with a transport
/// let transport = WiFiTransport()
/// await transport.setConnectionInfo(host: "192.168.1.100", port: 5000)
/// let session = MeshCoreSession(transport: transport)
///
/// // Connect and start the session
/// try await session.start()
///
/// // Get contacts from the device
/// let contacts = try await session.getContacts()
///
/// // Send a message to a contact
/// if let contact = contacts.first {
///     let result = try await session.sendMessage(
///         to: contact.publicKey,
///         text: "Hello from Swift!"
///     )
/// }
///
/// // Stop when done
/// await session.stop()
/// ```
///
/// ## Event Streaming
///
/// Subscribe to device events using the async event stream:
///
/// ```swift
/// Task {
///     for await event in await session.events() {
///         switch event {
///         case .contactMessageReceived(let msg):
///             print("Message: \(msg.text)")
///         case .advertisement(let publicKey):
///             print("Saw advertisement from \(publicKey.hexString)")
///         default:
///             break
///         }
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// `MeshCoreSession` is an actor, ensuring all operations are serialized and thread-safe.
/// All public methods are async and can be called safely from any context.
///
/// ## Testing
///
/// Inject a custom `Clock` to control timing in tests:
///
/// ```swift
/// let testClock = TestClock()
/// let session = MeshCoreSession(
///     transport: MockTransport(),
///     clock: testClock
/// )
/// ```
public actor MeshCoreSession: MeshCoreSessionProtocol {
  // MARK: - Properties

  let logger = Logger(subsystem: "MeshCore", category: "Session")

  let transport: any MeshTransport
  let configuration: SessionConfiguration
  let clock: any Clock<Duration>
  let dispatcher = EventDispatcher()
  let requestResponseSerializer = RequestResponseSerializer()

  /// The last tag ``runCLICommand(_:)`` put before a command line, as a number: each command gets
  /// the next of 1296 two-character tags ("01|" … "zz|"), echoed back in its reply.
  private var cliTagSequence = 0

  /// The next command-line tag: two base-36 characters and the companion's `|` separator.
  func nextCLITag() -> String {
    cliTagSequence = (cliTagSequence + 1) % 1296
    let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    return "\(digits[cliTagSequence / 36])\(digits[cliTagSequence % 36])|"
  }

  /// Serializes the read-modify-write of the granular "other params" setters. The
  /// inner wire exchanges already serialize on requestResponseSerializer, but a
  /// read-modify-write spans several of them, so without this outer guard two
  /// concurrent setters each write back the full config and silently revert each
  /// other's change. This is a distinct lock from requestResponseSerializer, which
  /// is not reentrant; nesting the two would deadlock.
  let otherParamsSerializer = RequestResponseSerializer()

  // State
  var contactManager = ContactManager()
  var selfInfo: SelfInfo?
  private var cachedTime: Date?

  /// Returns the device's self info after session start.
  ///
  /// This is populated after `start()` completes successfully.
  public var currentSelfInfo: SelfInfo? {
    selfInfo
  }

  /// The channel the radio reported in its last `SELF_INFO` (frequency, bandwidth, spreading
  /// factor, coding rate), or `nil` while nothing vouches for it: before the first `SELF_INFO`,
  /// and from a radio-parameters write (``setRadio(frequency:bandwidth:spreadingFactor:codingRate:clientRepeat:)``)
  /// until the radio confirms its new channel. Every ``MeshEvent/rxLogData(_:)`` is stamped with
  /// it (``ParsedRxLogData/channel``) as it arrives.
  public internal(set) var currentChannelConfig: RadioChannelConfig?

  /// When ``currentChannelConfig`` was first reported, on the wall clock; `nil` with no config.
  /// A later `SELF_INFO` for the same channel leaves it unchanged.
  public internal(set) var channelConfigSince: Date?

  /// ``channelConfigSince`` on ``uptime``, which stamping compares against (monotonic, unlike the
  /// wall clock).
  var channelConfigSinceUptime: Duration?

  /// The channel an RX_SYNC journal's records after a seq were heard on, from the app's own
  /// stored record at that seq (``trustRxBacklog(channel:epoch:afterSeq:)``); nil once the radio
  /// retunes in this session.
  var trustedRxBacklog: TrustedRxBacklog?

  struct TrustedRxBacklog: Equatable {
    let channel: ChannelKey
    let epoch: UInt32
    let afterSeq: UInt32
  }

  /// Returns the last known device time.
  ///
  /// This is updated when the device reports its current time. Returns `nil` if
  /// the time has not been queried. Use ``getTime()`` to explicitly request it.
  public var deviceTime: Date? {
    cachedTime
  }

  private var isRunning = false
  /// The listeners of ``transmissions()``, fed by `noteWritten(_:exchange:)` and
  /// `answerTransmission(_:outcome:)`.
  private var transmissionContinuations: [UUID: AsyncStream<TransmissionEvent>.Continuation] = [:]
  /// The id of the last transmitting command written (``TransmissionEvent/id``).
  private var transmissionSequence: UInt64 = 0
  /// The writes of each retransmitting exchange still waiting for the radio's answer.
  private var transmissionPairings: [UUID: TransmissionAnswerPairing] = [:]
  /// Events each ``transmissions()`` listener keeps while it lags.
  static let transmissionBufferLimit = 64
  private var receiveTask: Task<Void, Never>?
  private var autoMessageFetchTask: Task<Void, Never>?
  private var autoMessageDrainTask: Task<Void, Never>?
  /// Drains the queue every ``autoMessageCatchUpInterval`` while auto-fetch is on.
  private var autoMessageCatchUpTask: Task<Void, Never>?
  private var autoContactRefreshTask: Task<Void, Never>?
  private var isAutoFetchingMessages = false
  private var autoMessageDrainRequested = false
  /// The app's drain (``setAutoMessageDrainHandler(_:)``), run in place of the session's own
  /// fetch loop so each answer is stored before the next fetch.
  private var autoMessageDrainHandler: (@Sendable () async throws -> Void)?
  private var autoContactRefreshRequested = false
  var inFlightGetMessage: Task<MessageResult, Error>?
  /// This link opted in to the Cairn sent-message echo (``setCairnSyncSent(on:timeout:)``).
  /// The board drops the opt-in on every `APP_START`, so ``sendAppStart()`` renews it while set.
  var cairnSyncSentOptedIn = false
  /// Whether this radio sends its own Spectrum Channel view (firmware's `net/SPEC_SYNC.md`):
  /// nil until a spectrum request has been answered, `false` after `ERR_CODE_UNSUPPORTED_CMD` or
  /// an UNAVAILABLE reply, `true` after an OK. The Spectrum page probes once per session with it.
  public internal(set) var cairnSpectrumSupport: Bool?
  /// This connection's RX_SYNC delivery (``setCairnRxSync(on:resumeEpoch:resumeSeq:resumeMax:timeout:)``):
  /// the record sequencer, the opt-in renewed after `APP_START`, and the fetch loop.
  var rxSync = RxSyncLinkState()
  /// Whether this radio answers `CMD_GET_STATS` (official companion v1.11+): nil until a stats
  /// request has been answered, `false` after `ERR_CODE_UNSUPPORTED_CMD` (stats calls then throw
  /// without asking again), `true` after any stats reply. Reset for each connection.
  public internal(set) var statsSupport: Bool?
  /// `PUSH_CODE_LOG_RX_DATA` (0x88) frames received, counted before parsing; see
  /// ``receivedRxLogFrames``.
  private(set) var rxLogFrameCount: UInt64 = 0
  /// Live RX_SYNC records received (each once, by its first frame); see
  /// ``receivedLiveRxRecords``.
  private(set) var liveRxRecordCount: UInt64 = 0
  /// The transport's ``MeshTransport/droppedFrameCount`` when this connection started.
  var transportDropBaseline = 0
  /// Message fetches that timed out on a link without RX_SYNC. Official firmware takes a message
  /// off its queue before writing the answer, so each one may be a message the radio dropped for
  /// good (see ``getMessage(timeout:)``). For diagnostics; counted per session.
  public internal(set) var possiblyLostMessageFetches = 0
  /// Push frames seen, the last push's time and any hold, for ``waitForQuietLink(quiet:maxWait:)``.
  var linkPacing = LinkPacingState()
  /// Delivery confirmations recovered from the 0x88 copy of an ACK packet.
  var ackRecovery = AckRecoveryState()
  /// Time since this session was created, on ``clock``.
  let uptime: @Sendable () -> Duration
  /// Tags of the traces this session sent, oldest first (at most ``sentTraceTagLimit``).
  private var sentTraceTags: [UInt32] = []
  /// Trace tags remembered by ``sentTrace(tag:)``.
  static let sentTraceTagLimit = 32

  // MARK: - Connection State

  private var _connectionState: ConnectionState = .disconnected
  private var connectionStateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

  /// Provides an observable connection state stream for UI binding.
  ///
  /// The stream yields the current state immediately upon subscription,
  /// and then yields subsequent state changes as they occur.
  public var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { continuation in
      let id = UUID()
      // Yield current state immediately. The build closure runs on the actor,
      // so registering synchronously here means no transition can slip in
      // between the first yield and registration.
      continuation.yield(_connectionState)
      connectionStateContinuations[id] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeConnectionStateContinuation(id: id) }
      }
    }
  }

  private func removeConnectionStateContinuation(id: UUID) {
    connectionStateContinuations.removeValue(forKey: id)
  }

  private func updateConnectionState(_ state: ConnectionState) {
    logger.info("Session connection state -> \(String(describing: state))")
    _connectionState = state
    for continuation in connectionStateContinuations.values {
      continuation.yield(state)
    }
  }

  // MARK: - Lifecycle

  /// Creates a new MeshCore session.
  ///
  /// The session is created in a disconnected state. Call ``start()`` to connect
  /// to the device and begin communication.
  ///
  /// - Parameters:
  ///   - transport: The transport layer for device communication (e.g., ``WiFiTransport``).
  ///   - configuration: Session configuration options. Defaults to ``SessionConfiguration/default``.
  ///   - clock: The clock for timing operations. Defaults to `ContinuousClock` for production use.
  ///            Inject a test clock for deterministic testing of timeouts.
  public init(
    transport: any MeshTransport,
    configuration: SessionConfiguration = .default,
    clock: (any Clock<Duration>)? = nil
  ) {
    self.transport = transport
    self.configuration = configuration
    let clock = clock ?? ContinuousClock()
    self.clock = clock
    uptime = Self.makeUptime(clock)
  }

  /// Connects to the device and starts the session.
  ///
  /// This method performs the following steps:
  /// 1. Connects via the transport layer
  /// 2. Sends the `appStart` command to initialize communication
  /// 3. Receives device self-info (public key, name, capabilities)
  /// 4. Starts the background receive loop for incoming data
  ///
  /// The session becomes ready for use after this method returns successfully.
  /// Subscribe to events via ``events()`` to receive incoming messages and notifications.
  ///
  /// - Parameter reconnectingAttempt: When non-nil, publishes `.reconnecting(attempt:)`
  ///   instead of `.connecting` before establishing the transport/session.
  /// - Parameter disconnectTransportOnFailure: When `false`, a failed `appStart`
  ///   handshake unwinds the session without disconnecting the transport. Pass
  ///   `false` when the caller does not own the link — e.g. a session rebuild over
  ///   a transport that an OS-level reconnect is still recovering.
  /// - Throws: ``MeshTransportError`` if the transport connection fails.
  ///           ``MeshCoreError/timeout`` if the device doesn't respond to appStart.
  /// - Parameter appStartTimeout: How long the opening APP_START waits for the radio's self info;
  ///   nil waits the session's default. A first connect over WiFi waits long enough for the radio
  ///   to ask its owner to allow the phone, which it does before it reads anything the phone sent.
  public func start(
    reconnectingAttempt: Int? = nil,
    disconnectTransportOnFailure: Bool = true,
    appStartTimeout: TimeInterval? = nil
  ) async throws {
    // Guard against being called multiple times
    if isRunning {
      logger.warning("Session already running - skipping redundant start()")
      return
    }

    logger.info("Starting MeshCore session...")
    if let reconnectingAttempt {
      updateConnectionState(.reconnecting(attempt: max(1, reconnectingAttempt)))
    } else {
      updateConnectionState(.connecting)
    }
    logger.info("Connecting via transport...")
    do {
      try await transport.connect()
    } catch {
      logger.warning("Transport connection failed: \(error.localizedDescription)")
      updateConnectionState(.failed(error as? MeshTransportError ?? .connectionFailed(error.localizedDescription)))
      throw error
    }
    isRunning = true
    updateConnectionState(.connected)
    // Drops the transport counted before this connection belong to an earlier one.
    transportDropBaseline = await transport.droppedFrameCount

    // Start receiving data with weak self to prevent retain cycle
    receiveTask = Task { [weak self] in
      guard let self else { return }
      await receiveLoop()
    }

    // A new connection starts opted out of the sent-message echo (SENT_SYNC.md) and of RX_SYNC.
    cairnSyncSentOptedIn = false
    cairnSpectrumSupport = nil
    statsSupport = nil
    rxSync.cancelTasks()
    rxSync = RxSyncLinkState()

    // Send appstart
    logger.info("Sending appStart command...")
    do {
      selfInfo = try await sendAppStart(timeout: appStartTimeout)
    } catch {
      // Unwind the half-started session so a retry start() runs the full
      // handshake instead of hitting the isRunning guard and no-opping.
      logger.warning("appStart failed: \(error.localizedDescription)")
      isRunning = false
      receiveTask?.cancel()
      receiveTask = nil
      if disconnectTransportOnFailure {
        await transport.disconnect()
      }
      updateConnectionState(.failed(error as? MeshTransportError ?? .connectionFailed(error.localizedDescription)))
      throw error
    }
    logger.info("MeshCore session started")
  }

  /// Stops the session and disconnects from the device.
  ///
  /// This method is safe to call multiple times. It cancels all pending operations,
  /// stops the receive loop, and closes the transport connection unless
  /// `disconnectTransport` is `false`.
  ///
  /// After calling this method, the session cannot be reused. Create a new session
  /// to reconnect.
  ///
  /// - Parameter disconnectTransport: When `false`, the transport link is left
  ///   open. Pass `false` when the caller does not own the link — e.g. tearing
  ///   down a superseded session while a newer reconnect cycle (or an OS-level
  ///   pending connect) still rides on the same transport.
  public func stop(disconnectTransport: Bool = true) async {
    logger.info("Stopping MeshCore session...")
    isRunning = false
    cairnSyncSentOptedIn = false
    rxSync.cancelTasks()
    rxSync.wanted = false
    rxSync.isActive = false
    stopAutoMessageFetching()
    autoMessageDrainHandler = nil
    ackRecovery.cancelAll()
    autoContactRefreshTask?.cancel()
    autoContactRefreshTask = nil
    autoContactRefreshRequested = false
    receiveTask?.cancel()
    await dispatcher.finishAllSubscriptions()
    finishTransmissionStreams()
    if disconnectTransport {
      logger.info("Disconnecting transport...")
      await transport.disconnect()
    }
    updateConnectionState(.disconnected)
    logger.info("MeshCore session stopped")
  }

  // MARK: - Events

  /// Subscribes to all events from the device.
  ///
  /// Each subscriber receives all events independently. Supports bounded buffering of up to 100 events.
  ///
  /// - Returns: An async stream of mesh events that yields ``MeshEvent`` values as they are received.
  public func events() async -> AsyncStream<MeshEvent> {
    await dispatcher.subscribe()
  }

  /// Reports each command that makes the radio transmit over the air (`CommandCode
  /// .transmitsOverAir`: a message, an advert, a request, a trace…, and a telemetry request for
  /// another node) as it is written to it, including a request's retransmits, then the radio's
  /// answer to that write (``TransmissionOutcome``). The radio reports nothing it transmits, so
  /// these are all the app knows of what went out.
  ///
  /// Every call returns its own stream; each keeps the newest ``transmissionBufferLimit`` events
  /// while its listener lags. The streams end when the session stops.
  public func transmissions() -> AsyncStream<TransmissionEvent> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: TransmissionEvent.self,
      bufferingPolicy: .bufferingNewest(Self.transmissionBufferLimit)
    )
    let id = UUID()
    transmissionContinuations[id] = continuation
    continuation.onTermination = { _ in
      Task { await self.removeTransmissionContinuation(id: id) }
    }
    return stream
  }

  private func removeTransmissionContinuation(id: UUID) {
    transmissionContinuations.removeValue(forKey: id)
  }

  private func yieldTransmission(_ event: TransmissionEvent) {
    for continuation in transmissionContinuations.values {
      continuation.yield(event)
    }
  }

  private func finishTransmissionStreams() {
    for continuation in transmissionContinuations.values {
      continuation.finish()
    }
    transmissionContinuations.removeAll()
    transmissionPairings.removeAll()
  }

  /// Called with every command written to the radio; reports the ones that go out over the air
  /// to ``transmissions()``.
  ///
  /// - Parameters:
  ///   - command: The frame just written.
  ///   - exchange: The retransmitting exchange the write belongs to (see
  ///     `beginTransmissionPairing()`), whose answers are paired with its writes in order.
  /// - Returns: The write's ``TransmissionEvent/id`` when it transmits, otherwise `nil`.
  @discardableResult
  func noteWritten(_ command: Data, exchange: UUID? = nil) -> UInt64? {
    guard let code = command.first.flatMap(CommandCode.init(rawValue:)) else { return nil }
    // Its selfInfo answer renews RX_SYNC (the radio opts this link out); see `routeRxSync(_:)`
    if code == .appStart { rxSync.ownAppStarts += 1 }
    // A retune: from now on nothing vouches for the channel frames are heard on until the radio
    // reports it again (`setRadio` asks for that as soon as the radio answers).
    if code == .setRadio { clearChannelConfig() }
    if code == .sendTrace, command.count >= 5 {
      sentTraceTags.append(command.readUInt32LE(at: 1))
      if sentTraceTags.count > Self.sentTraceTagLimit { sentTraceTags.removeFirst() }
    }
    // A telemetry request with a recipient's key goes over the air; without one it reads this radio.
    let isRemoteTelemetry = code == .getSelfTelemetry && command.count > 4
    guard code.transmitsOverAir || isRemoteTelemetry else { return nil }
    transmissionSequence += 1
    let id = transmissionSequence
    yieldTransmission(.written(id: id, command: command, at: Date()))
    if let exchange, let outcome = transmissionPairings[exchange, default: TransmissionAnswerPairing()].wrote(id) {
      answerTransmission(id, outcome: outcome)
    }
    return id
  }

  /// Reports the radio's answer to the transmitting write `id`.
  func answerTransmission(_ id: UInt64, outcome: TransmissionOutcome) {
    yieldTransmission(.answered(id: id, outcome: outcome))
  }

  /// Starts pairing a retransmitting exchange's writes with the radio's answers; pass the id to
  /// `noteWritten(_:exchange:)` and `pairTransmissionAnswer(_:in:)`, then end it with
  /// `endTransmissionPairing(_:)`.
  func beginTransmissionPairing() -> UUID {
    let exchange = UUID()
    transmissionPairings[exchange] = TransmissionAnswerPairing()
    return exchange
  }

  /// Notes the radio's answer to the oldest unanswered write of `exchange`.
  func pairTransmissionAnswer(_ outcome: TransmissionOutcome, in exchange: UUID) {
    guard let id = transmissionPairings[exchange, default: TransmissionAnswerPairing()].answered(outcome) else { return }
    answerTransmission(id, outcome: outcome)
  }

  /// Ends `exchange`: its writes still without an answer are reported unconfirmed.
  func endTransmissionPairing(_ exchange: UUID) {
    guard var pairing = transmissionPairings.removeValue(forKey: exchange) else { return }
    for id in pairing.finish() {
      answerTransmission(id, outcome: .unconfirmed)
    }
  }

  /// Whether this session sent the trace tagged `tag` (one of its last ``sentTraceTagLimit``).
  ///
  /// The radio pushes a trace result (``MeshEvent/traceData(_:)``) for every trace whose last
  /// retransmission it hears, someone else's too; only one this session sent measures how the
  /// node it traced hears this radio.
  public func sentTrace(tag: UInt32) -> Bool {
    sentTraceTags.contains(tag)
  }

  /// Subscribes to events passing the given filter.
  ///
  /// Prefer this over ``events()`` when the consumer only cares about a
  /// narrow slice of events. The filter is evaluated at dispatch time,
  /// so non-matching events never enter the subscription's 100-slot
  /// bounded buffer (`.bufferingNewest`) — unrelated traffic cannot
  /// evict matching events even if the consumer is slow to drain the stream.
  ///
  /// - Parameter filter: The ``EventFilter`` that determines which events reach the stream.
  /// - Returns: An async stream yielding only events that pass `filter`.
  public func events(filter: EventFilter) async -> AsyncStream<MeshEvent> {
    await dispatcher.subscribe(filter: filter.matches)
  }

  /// Subscribes to events passing the given filter, with a buffer of the caller's choosing.
  ///
  /// A consumer that must not miss a burst (the RX log, the neighbour table) asks for a deeper
  /// buffer than the default 100 events (`.bufferingNewest(4096)`), and a label so its drops can be
  /// read back with ``eventDropCount(label:)``.
  ///
  /// - Parameters:
  ///   - filter: The ``EventFilter`` that determines which events reach the stream.
  ///   - buffering: What the stream keeps while the consumer lags.
  ///   - label: The name the subscription's drops are counted under, or `nil`.
  /// - Returns: An async stream yielding only events that pass `filter`.
  public func events(
    filter: EventFilter,
    buffering: AsyncStream<MeshEvent>.Continuation.BufferingPolicy,
    label: String? = nil
  ) async -> AsyncStream<MeshEvent> {
    await dispatcher.subscribe(filter: filter.matches, bufferingPolicy: buffering, label: label)
  }

  /// Events dropped so far by the subscriptions labelled `label`, because they lagged.
  public func eventDropCount(label: String) async -> Int {
    await dispatcher.droppedEventCount(label: label)
  }

  /// Events dropped so far per labelled subscription (see ``EventDispatcher/dropCounts``).
  public var eventDropCounts: [String: Int] {
    get async { await dispatcher.dropCounts }
  }

  /// Subscribes to all events with an explicit teardown handle.
  ///
  /// Use this when the listener has a bounded lifetime (e.g., a timed scan) and needs the
  /// `for await` loop to exit promptly when the work is done. Pair with ``finishEvents(id:)``.
  ///
  /// - Returns: A tuple of the subscription id (pass to ``finishEvents(id:)``) and the event stream.
  public func eventsTracked() async -> (id: UUID, stream: AsyncStream<MeshEvent>) {
    await dispatcher.subscribeTracked()
  }

  /// Subscribes to events passing `filter` with an explicit teardown handle and a buffer of the
  /// caller's choosing. Pair with ``finishEvents(id:)``.
  ///
  /// - Parameters:
  ///   - filter: The ``EventFilter`` that determines which events reach the stream; `nil` for all.
  ///   - buffering: What the stream keeps while the consumer lags.
  ///   - label: The name the subscription's drops are counted under, or `nil`.
  /// - Returns: A tuple of the subscription id (pass to ``finishEvents(id:)``) and the event stream.
  public func eventsTracked(
    filter: EventFilter?,
    buffering: AsyncStream<MeshEvent>.Continuation.BufferingPolicy,
    label: String? = nil
  ) async -> (id: UUID, stream: AsyncStream<MeshEvent>) {
    await dispatcher.subscribeTracked(filter: filter?.matches, bufferingPolicy: buffering, label: label)
  }

  /// Finishes a subscription created via ``eventsTracked()``.
  ///
  /// Causes the corresponding `for await` loop to exit. Safe to call with an unknown id.
  public func finishEvents(id: UUID) async {
    await dispatcher.finishSubscription(id: id)
  }

  // MARK: - Auto Message Fetching

  /// Starts automatic message fetching.
  ///
  /// When enabled, the session automatically fetches pending messages from the
  /// device whenever it receives a `messagesWaiting` notification.
  ///
  /// Call ``stopAutoMessageFetching()`` to disable.
  public func startAutoMessageFetching() async {
    guard !isAutoFetchingMessages else { return }
    isAutoFetchingMessages = true

    // Subscribe before spawning the loop so a messagesWaiting event
    // dispatched right after this method returns cannot be missed.
    let events = await dispatcher.subscribe()
    autoMessageFetchTask = Task { [weak self] in
      guard let self else { return }
      await autoMessageFetchLoop(events: events)
    }
    autoMessageCatchUpTask = Task { [weak self] in
      guard let self else { return }
      await autoMessageCatchUpLoop()
    }

    // The auto-fetch loop polls messages in response to messagesWaiting events.
    // For immediate polling, callers should use getMessage() or consume the events directly.
  }

  /// Stops automatic message fetching.
  ///
  /// Call this to disable the automatic fetching started by ``startAutoMessageFetching()``.
  public func stopAutoMessageFetching() {
    isAutoFetchingMessages = false
    autoMessageDrainRequested = false
    autoMessageFetchTask?.cancel()
    autoMessageFetchTask = nil
    autoMessageDrainTask?.cancel()
    autoMessageDrainTask = nil
    autoMessageCatchUpTask?.cancel()
    autoMessageCatchUpTask = nil
  }

  /// How often auto-fetch drains the queue without a `messagesWaiting` push.
  static let autoMessageCatchUpInterval: Duration = .seconds(120)

  /// Official firmware pushes `messagesWaiting` once per queued message through a send queue
  /// that drops frames when full, so a lost push leaves the message on the radio until the next
  /// one arrives. Draining every ``autoMessageCatchUpInterval`` bounds that wait; each run costs
  /// one `NO_MORE_MESSAGES` answer when nothing is queued, and is paced like every drain. Links
  /// with RX_SYNC report their losses and skip it.
  private func autoMessageCatchUpLoop() async {
    while isAutoFetchingMessages, !Task.isCancelled {
      do {
        try await clock.sleep(for: Self.autoMessageCatchUpInterval)
      } catch {
        return
      }
      guard isAutoFetchingMessages, !Task.isCancelled else { return }
      if !rxSync.isActive {
        requestAutoMessageDrain()
      }
    }
  }

  private func autoMessageFetchLoop(events: AsyncStream<MeshEvent>) async {
    for await event in events {
      guard isAutoFetchingMessages else { break }

      if case .messagesWaiting = event {
        requestAutoMessageDrain()
      }
    }
  }

  /// Drains the radio's message queue now, as a `messagesWaiting` push would. The radio only
  /// pushes when a message arrives, so anything left by a drain that failed (or that queued while
  /// auto-fetch was paused) would otherwise wait for the next message. No-op unless
  /// ``startAutoMessageFetching()`` is on; coalesces with a drain already running.
  public func requestMessageDrain() async {
    guard isAutoFetchingMessages else { return }
    requestAutoMessageDrain()
  }

  /// Retries after a failed auto-drain fetch before waiting for the next push.
  static let autoMessageDrainRetryLimit = 2

  public func setAutoMessageDrainHandler(_ handler: (@Sendable () async throws -> Void)?) {
    autoMessageDrainHandler = handler
  }

  private func requestAutoMessageDrain() {
    autoMessageDrainRequested = true

    guard autoMessageDrainTask == nil else { return }
    autoMessageDrainTask = Task { [weak self] in
      guard let self else { return }
      await runAutoMessageDrainLoop()
    }
  }

  private func runAutoMessageDrainLoop() async {
    defer { autoMessageDrainTask = nil }

    var failures = 0
    while isAutoFetchingMessages, autoMessageDrainRequested, !Task.isCancelled {
      autoMessageDrainRequested = false

      do {
        if let autoMessageDrainHandler {
          // The app drains and stores each answer before the next fetch: an answer the radio
          // has already dequeued must never wait in an event buffer that can overflow.
          try await autoMessageDrainHandler()
        } else {
          // Each fetch waits for a quiet link itself (see `getMessage(timeout:)`), which replaces
          // a fixed pause between fetches.
          while isAutoFetchingMessages, !Task.isCancelled {
            let result = try await getMessage()
            if case .noMoreMessages = result { break }
          }
        }
        failures = 0
      } catch is CancellationError {
        break
      } catch {
        // A lost answer (a busy link, or the app suspended mid-exchange) used to end the drain
        // with the rest of the queue still on the radio. Back off and ask again, a few times.
        failures += 1
        logger.warning("Auto message fetch error (\(failures)): \(error.localizedDescription)")
        guard failures <= Self.autoMessageDrainRetryLimit else {
          failures = 0
          continue
        }
        try? await clock.sleep(for: .seconds(failures))
        autoMessageDrainRequested = true
      }
    }
  }

  private func requestAutoContactRefresh() {
    autoContactRefreshRequested = true

    guard autoContactRefreshTask == nil else { return }
    autoContactRefreshTask = Task { [weak self] in
      guard let self else { return }
      await runAutoContactRefreshLoop()
    }
  }

  private func runAutoContactRefreshLoop() async {
    defer { autoContactRefreshTask = nil }

    while autoContactRefreshRequested, !Task.isCancelled {
      autoContactRefreshRequested = false

      do {
        _ = try await ensureContacts(force: true)
      } catch is CancellationError {
        break
      } catch {
        logger.warning("Auto contact refresh failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Receive Path

  /// The background loop for receiving data from the transport.
  private func receiveLoop() async {
    logger.info("Receive loop started")
    for await data in await transport.receivedData {
      await handleReceivedData(data)
    }
    // Stream ended - transport disconnected
    logger.info("Receive loop ended (stream exhausted)")
    // Publish the loss only when the stream ended unexpectedly. During stop() or a
    // failed-start unwind the session has already published its terminal state
    // (.disconnected or .failed); a late .disconnected here would overwrite it.
    guard isRunning else { return }
    await dispatcher.dispatch(.connectionStateChanged(.disconnected))
    updateConnectionState(.disconnected)
    isRunning = false
  }

  /// Handles raw data received from the device.
  ///
  /// Per the MeshCore Companion Radio Protocol, each BLE notification is a complete frame.
  /// No reassembly or buffering is needed - we parse each packet directly.
  private func handleReceivedData(_ data: Data) async {
    guard let code = data.first else { return }

    // Counted before parsing, so an unreadable or held 0x88 frame still counts as delivered:
    // the stats barrier compares this with the radio's own received-packet counter. Live RX_SYNC
    // records are counted apart: the radio sends them when its journal pacing allows, not in the
    // pass that counts their packets, so a stock link that gets them (the radio opted it in behind
    // a lost SUBSCRIBE reply) can't be measured that way.
    if code == ResponseCode.logData.rawValue {
      rxLogFrameCount += 1
    } else if Self.isLiveRxRecordHead(data) {
      liveRxRecordCount += 1
    }
    noteLinkFrame(code: code)

    var event = PacketParser.parse(data)

    if case let .parseFailure(_, reason) = event {
      logger.warning("Failed to parse packet: \(data.hexString) - \(reason)")
      // Leaf parsers report the payload alone; an unreadable answer to a message fetch keeps
      // its code byte so the waiting `getMessage` can tell it answered and move on.
      if let code = data.first, Self.answersMessageFetch(code) {
        event = .parseFailure(data: data, reason: reason)
      }
    } else {
      logger.debug("Received event: \(String(describing: event))")
    }

    // Re-parse push status responses with correct layout for room servers
    if case let .statusResponse(response) = event,
       response.layout == .repeater,
       let contact = contactManager.getByKeyPrefix(response.publicKeyPrefix),
       contact.type == .room {
      event = Parsers.StatusResponse.parse(Data(data.dropFirst()), layout: .roomServer)
    }

    // A 0x88 frame is stamped with the channel as it arrives, so one held while a SUBSCRIBE is
    // answered keeps the channel it was heard on (RX_SYNC records are stamped as they are joined).
    if case var .rxLogData(parsed) = event {
      parsed.channel = channelStamp(radioAge: parsed.radioAge)
      event = .rxLogData(parsed)
    }

    // Any stats reply shows the command exists; a packet-counter reply carries the 0x88 count it
    // pairs with, whichever request ends up consuming it.
    switch event {
    case let .statsPackets(stats):
      statsSupport = true
      event = .statsPackets(stats.stamped(appRxLogFrames: rxLogFrameCount, appLiveRxRecords: liveRxRecordCount))
    case .statsCore, .statsRadio:
      statsSupport = true
    default:
      break
    }

    // Confirmation recovery sees each frame as it arrives, before RX_SYNC routing: a 0x88 copy
    // held while a SUBSCRIBE is answered still starts its grace now, and when a failed setup
    // releases the held frames they are dispatched without coming back through here. A
    // delivery confirmation already recovered from its ACK packet's 0x88 copy is not dispatched
    // a second time.
    guard admitForAckRecovery(event) else { return }

    // RX_SYNC record frames become one rxLogData per record (or nothing yet); 0x88 frames may be
    // held while a SUBSCRIBE is answered. Everything else passes through unchanged.
    for routed in routeRxSync(event) {
      // A record's packet exists only now (a copy already heard as a 0x88 frame starts nothing)
      if case .cairnRxRecordFrame = event {
        guard admitForAckRecovery(routed) else { continue }
      }
      trackContactChanges(event: routed)
      await dispatcher.dispatch(routed)
    }
  }

  /// Tracks contact-related changes from received events.
  private func trackContactChanges(event: MeshEvent) {
    // Track contact-related events in ContactManager
    contactManager.trackChanges(from: event)

    // Auto-refresh contacts if enabled and contacts became dirty
    if contactManager.isAutoUpdateEnabled, contactManager.needsRefresh {
      switch event {
      case .advertisement, .pathUpdate, .newContact:
        requestAutoContactRefresh()
      default:
        break
      }
    }

    // Track non-contact state
    switch event {
    case let .currentTime(time):
      cachedTime = time
    case let .selfInfo(info):
      selfInfo = info
      noteChannelConfig(from: info)
    default:
      break
    }
  }

  // MARK: - Radio Channel

  /// Takes the channel a `SELF_INFO` reports (any link's `APP_START` is answered on every link).
  /// A new channel, or one reported after a retune cleared it, starts now; the same channel again
  /// (a coding-rate change included, which other radios still hear) keeps its start.
  func noteChannelConfig(from info: SelfInfo) {
    guard let config = RadioChannelConfig(selfInfo: info) else {
      clearChannelConfig()
      return
    }
    let isSameChannel = currentChannelConfig?.key == config.key && channelConfigSinceUptime != nil
    // Another channel than the one already confirmed is a retune: nothing held vouches past it.
    if let current = currentChannelConfig, current.key != config.key { trustedRxBacklog = nil }
    currentChannelConfig = config
    guard !isSameChannel else { return }
    channelConfigSince = Date()
    channelConfigSinceUptime = uptime()
  }

  /// Forgets the channel until the radio reports it again.
  func clearChannelConfig() {
    currentChannelConfig = nil
    channelConfigSince = nil
    channelConfigSinceUptime = nil
    trustedRxBacklog = nil
  }

  /// Vouches for the radio's held records: those of journal `epoch` after `afterSeq` were heard
  /// on `channel`, the channel the app's own stored record at `afterSeq` was stamped with. They
  /// are stamped with it while the radio still reports that channel, though heard before this
  /// connection confirmed it. The same epoch means the radio hasn't rebooted since; a radio
  /// retuned and kept there reports another channel, and a retune in this session ends it. Call
  /// it before the SUBSCRIBE whose backlog it covers.
  public func trustRxBacklog(channel: ChannelKey, epoch: UInt32, afterSeq: UInt32) {
    guard epoch != 0 else { return }
    trustedRxBacklog = TrustedRxBacklog(channel: channel, epoch: epoch, afterSeq: afterSeq)
  }

  /// The channel to stamp on a packet the radio received `radioAge` before now (`nil` for a live
  /// 0x88 frame): the current channel, when it was already confirmed at that moment.
  ///
  /// An RX_SYNC record from before the current channel was confirmed is left unstamped rather
  /// than guessed: the radio may have been on another channel then.
  ///
  /// A record of a journal the app vouched for (``trustRxBacklog(channel:epoch:afterSeq:)``),
  /// `epoch` and `seq` naming it, is stamped with that channel while the radio still reports it.
  func channelStamp(radioAge: Duration?, epoch: UInt32? = nil, seq: UInt32? = nil) -> RadioChannelConfig? {
    guard let config = currentChannelConfig, let since = channelConfigSinceUptime else { return nil }
    if since <= uptime() - (radioAge ?? .zero) { return config }
    guard let trusted = trustedRxBacklog, let epoch, let seq,
          trusted.epoch == epoch, seq > trusted.afterSeq, trusted.channel == config.key else { return nil }
    return config
  }

  // MARK: - Test Support

  /// Dispatches an event directly to subscribers, bypassing the transport and parser.
  ///
  /// For tests only — use to verify subscriber behavior without crafting wire bytes.
  func dispatchForTesting(_ event: MeshEvent) async {
    await dispatcher.dispatch(event)
  }

  /// Seeds `selfInfo` for tests so callers that depend on
  /// ``currentSelfInfo`` (e.g. ACK precompute) can run without simulating
  /// an `APP_START` round-trip.
  func installSelfInfoForTest(_ info: SelfInfo) {
    selfInfo = info
  }

  /// Returns the dispatcher's active subscription count. For tests only.
  ///
  /// Integration tests use this to synchronize with a listener task's
  /// subscribe call before dispatching events, avoiding the dispatch-vs-subscribe race.
  var subscriberCountForTest: Int {
    get async { await dispatcher.subscriberCountForTest }
  }
}

// MARK: - Session Role Conformances

/// The role methods are witnessed by the existing implementations in the
/// `MeshCoreSession+*` extension files; no additional members are needed.
extension MeshCoreSession: ConfigurationSessionOps, AdvertisingSessionOps,
  DiagnosticsSessionOps, RemoteAccessSessionOps {}
