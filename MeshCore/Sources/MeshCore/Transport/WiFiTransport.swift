import Foundation
import Network
import os

/// Errors that can occur during WiFi transport operations.
public enum WiFiTransportError: Error, Sendable, Equatable {
  case connectionFailed(String)
  case connectionTimeout
  /// iOS kept the connection parked for Local Network access: the prompt went unanswered, or the
  /// access is off in Settings › Privacy & Security › Local Network.
  case localNetworkDenied
  case notConnected
  case sendFailed(String)
  case sendTimeout
  case invalidHost
  case invalidPort
  case notConfigured
}

/// TCP transport for connecting to MeshCore devices over WiFi.
///
/// Configure connection info before calling `connect()`:
/// ```swift
/// let transport = WiFiTransport()
/// await transport.setConnectionInfo(host: "192.168.1.50", port: 5000)
/// try await transport.connect()
/// ```
public actor WiFiTransport: MeshTransport {
  private let logger = Logger(subsystem: "MeshCore", category: "WiFiTransport")

  private var connection: NWConnection?
  private var frameDecoder = WiFiFrameDecoder()

  // AsyncStream created in init so receivedData is valid before connect()
  private let dataStream: AsyncStream<Data>
  private let dataContinuation: AsyncStream<Data>.Continuation

  private var _isConnected = false

  // Connection configuration (set before connect())
  private var configuredHost: String?
  private var configuredPort: UInt16?

  /// Thread-safe continuation state (protects against multiple resumes)
  private var connectContinuation: CheckedContinuation<Void, Error>?

  /// Set while iOS parks the connect waiting for Local Network access (`.waiting` with
  /// `.localNetworkDenied`); the connect timeout then stretches to `localNetworkTimeout`.
  private var awaitingLocalNetwork = false

  /// When set, a connect parked on Local Network access fails at once with
  /// `.localNetworkDenied` instead of waiting out `localNetworkTimeout`: no prompt can show
  /// while the app is in the background, and access already declined stays declined.
  private var failsFastOnLocalNetworkPrompt = false

  /// Running while the established connection's path is unviable; the link counts as lost
  /// if it does not recover within `viabilityGracePeriod`.
  private var viabilityLossTask: Task<Void, Never>?

  /// Disconnection notification
  private var disconnectionHandler: (@Sendable (Error?) -> Void)?

  // MARK: - Configuration

  /// Connection timeout duration
  public static let connectionTimeout: Duration = .seconds(10)

  /// How long a connect may wait on the Local Network prompt: the first connect after install
  /// brings it up, and the connection carries on by itself once the user taps Allow.
  public static let localNetworkTimeout: Duration = .seconds(60)

  /// Write timeout duration
  public static let writeTimeout: Duration = .seconds(5)

  /// How long an established connection's path may stay unviable (WiFi dropped, the phone
  /// left the network) before the link counts as lost. NWConnection keeps an unviable
  /// connection open and recovers it when the path returns, so a short gap is ridden out.
  public static let viabilityGracePeriod: Duration = .seconds(10)

  // MARK: - MeshTransport Protocol

  public var receivedData: AsyncStream<Data> {
    dataStream
  }

  public var isConnected: Bool {
    _isConnected
  }

  /// TCP streams pipeline natively: back-to-back sends queue in the socket buffer and the radio
  /// drains them at its loop cadence, so windowed channel reads avoid the per-round-trip stall
  /// that serial reads pay over WiFi. There is no ATT write characteristic, so
  /// `supportsWriteWithoutResponse` stays false and `sendWithoutResponse` routes to `send`.
  public var supportsPipelinedReads: Bool {
    true
  }

  public init() {
    // Create stream in init so receivedData is valid before connect()
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    dataStream = stream
    dataContinuation = continuation
  }

  /// Configures the connection target. Must be called before `connect()`.
  public func setConnectionInfo(host: String, port: UInt16) {
    configuredHost = host
    configuredPort = port
  }

  /// Makes the next `connect()` fail at once when iOS parks it on Local Network access,
  /// rather than wait for a prompt that cannot be answered (see `failsFastOnLocalNetworkPrompt`).
  public func setFailsFastOnLocalNetworkPrompt(_ failsFast: Bool) {
    failsFastOnLocalNetworkPrompt = failsFast
  }

  /// Sets a handler to be called when the connection is unexpectedly lost.
  public func setDisconnectionHandler(_ handler: @escaping @Sendable (Error?) -> Void) {
    disconnectionHandler = handler
  }

  /// Clears the disconnection handler (call before user-initiated disconnect)
  public func clearDisconnectionHandler() {
    disconnectionHandler = nil
  }

  /// Returns the configured connection info, if set.
  public var connectionInfo: (host: String, port: UInt16)? {
    guard let host = configuredHost, let port = configuredPort else { return nil }
    return (host, port)
  }

  /// Establishes a TCP connection to the configured host and port.
  /// Call `setConnectionInfo(host:port:)` first.
  public func connect() async throws {
    // Idempotent: skip if already connected. Without this guard,
    // session.start() orphans the TCP connection the caller already established.
    if _isConnected {
      logger.info("Already connected, skipping redundant connect()")
      return
    }

    guard let host = configuredHost, let port = configuredPort else {
      throw WiFiTransportError.notConfigured
    }

    logger.info("Connecting to \(host):\(port)")

    let hostEndpoint = NWEndpoint.Host(host)
    guard let portEndpoint = NWEndpoint.Port(rawValue: port) else {
      throw WiFiTransportError.invalidPort
    }

    let endpoint = NWEndpoint.hostPort(host: hostEndpoint, port: portEndpoint)

    // Disable Nagle's algorithm. The companion protocol is small-frame request-response
    // (each getChannel is one command and one reply), and Nagle interacting with the peer's
    // delayed-ACK injects a fixed per-round-trip stall that serial channel reads pay once per
    // channel. Streamed traffic such as contacts coalesces and hides it; ping-pong reads do not.
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    // Keepalives let the stack notice a radio that vanished (power cut, out of WiFi range)
    // while the link sits idle; the app's own heartbeat probes only every 30 s, and only
    // while the app runs. A TCP stack answers keepalive probes on its own, without the
    // firmware's involvement: about 40 s of silence marks the link dead.
    tcpOptions.enableKeepalive = true
    tcpOptions.keepaliveIdle = 20
    tcpOptions.keepaliveInterval = 5
    tcpOptions.keepaliveCount = 4
    let parameters = NWParameters(tls: nil, tcp: tcpOptions)

    let newConnection = NWConnection(to: endpoint, using: parameters)
    connection = newConnection
    awaitingLocalNetwork = false

    // Race connection against timeout
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.performConnection(newConnection)
      }

      group.addTask {
        try await Task.sleep(for: Self.connectionTimeout)
        // Parked on the Local Network prompt: give the user time to answer it.
        var waited = Self.connectionTimeout
        while await self.awaitingLocalNetwork {
          guard waited < Self.localNetworkTimeout else { throw WiFiTransportError.localNetworkDenied }
          try await Task.sleep(for: .seconds(1))
          waited += .seconds(1)
        }
        throw WiFiTransportError.connectionTimeout
      }

      // Wait for first task to complete or throw
      do {
        try await group.next()
        group.cancelAll()
      } catch {
        group.cancelAll()
        // Resume the parked connection continuation on every failure path,
        // including caller-task cancellation; the group cannot finish
        // tearing down while that child stays suspended.
        self.cancelPendingConnection(throwing: error)
        throw error
      }
    }

    startReceiving()
  }

  /// Performs the actual connection wait via continuation.
  ///
  /// Every callback carries the identity of the connection it came from: the handlers hop to
  /// the actor in unordered Tasks, so a late callback from a connection already failed,
  /// cancelled, or replaced must be told apart from the current one and ignored.
  private func performConnection(_ newConnection: NWConnection) async throws {
    let connectionID = ObjectIdentifier(newConnection)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.connectContinuation = continuation

      newConnection.stateUpdateHandler = { [weak self] state in
        Task { [weak self] in
          await self?.handleStateChange(state, for: connectionID)
        }
      }
      newConnection.viabilityUpdateHandler = { [weak self] isViable in
        Task { [weak self] in
          await self?.handleViabilityChange(isViable, for: connectionID)
        }
      }
      newConnection.betterPathUpdateHandler = { [weak self] hasBetterPath in
        guard hasBetterPath else { return }
        // The radio sits on the local network, so another interface rarely reaches it
        // better; noted for diagnostics, the connection stays where it is.
        self?.logger.info("A better network path is available; keeping the current connection")
      }

      newConnection.start(queue: .global(qos: .userInitiated))
    }
  }

  /// Identity of the live `NWConnection`, nil when none. Lets tests address state changes
  /// to the current connection or to a stale one.
  var currentConnectionID: ObjectIdentifier? {
    connection.map(ObjectIdentifier.init)
  }

  /// Drops every callback from `connection` and cancels it.
  private func releaseConnection() {
    viabilityLossTask?.cancel()
    viabilityLossTask = nil
    connection?.stateUpdateHandler = nil
    connection?.viabilityUpdateHandler = nil
    connection?.betterPathUpdateHandler = nil
    connection?.cancel()
    connection = nil
  }

  /// Cancels a pending connection attempt, resuming the parked
  /// continuation with the error that caused the failure.
  private func cancelPendingConnection(throwing error: Error) {
    releaseConnection()
    _isConnected = false

    if let continuation = connectContinuation {
      connectContinuation = nil
      continuation.resume(throwing: error)
    }
  }

  public func disconnect() async {
    logger.info("Disconnecting")
    disconnectionHandler = nil // Clear BEFORE cancel to prevent spurious callback
    releaseConnection()
    _isConnected = false
    frameDecoder.reset()
    dataContinuation.finish()

    // Clear any pending continuation
    if let continuation = connectContinuation {
      continuation.resume(throwing: WiFiTransportError.connectionFailed("Disconnected"))
      connectContinuation = nil
    }
  }

  public func send(_ data: Data) async throws {
    guard let connection, _isConnected else {
      throw WiFiTransportError.notConnected
    }

    let frame = WiFiFrameCodec.encode(data)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        // Lock-protected continuation prevents double-resume when both
        // contentProcessed and onCancel fire
        let state = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)

        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let alreadyCancelled = state.withLock { stored -> Bool in
              if Task.isCancelled {
                return true
              }
              stored = continuation
              return false
            }
            if alreadyCancelled {
              continuation.resume(throwing: WiFiTransportError.sendTimeout)
              return
            }

            connection.send(content: frame, completion: .contentProcessed { error in
              if let cont = state.withLock({ let cont = $0; $0 = nil; return cont }) {
                if let error {
                  cont.resume(throwing: WiFiTransportError.sendFailed(error.localizedDescription))
                } else {
                  cont.resume()
                }
              }
            })
          }
        } onCancel: {
          if let cont = state.withLock({ let cont = $0; $0 = nil; return cont }) {
            cont.resume(throwing: WiFiTransportError.sendTimeout)
          }
        }
      }

      group.addTask {
        try await Task.sleep(for: Self.writeTimeout)
        throw WiFiTransportError.sendTimeout
      }

      try await group.next()
      group.cancelAll()
    }
  }

  // MARK: - Private

  /// Handles NWConnection state changes with safe one-time continuation resume.
  ///
  /// `connectionID` names the connection the change came from; changes from any other
  /// connection (an earlier one, or one already failed or cancelled) are dropped, so a
  /// stale `.ready` can never mark this transport connected with no connection behind it.
  func handleStateChange(_ state: NWConnection.State, for connectionID: ObjectIdentifier) {
    guard let connection, ObjectIdentifier(connection) == connectionID else {
      logger.debug("Ignoring state change from a replaced connection: \(String(describing: state))")
      return
    }

    switch state {
    case .ready:
      guard let continuation = connectContinuation else {
        // Already reported: a second `.ready` for this connection changes nothing.
        return
      }
      logger.info("Connection ready")
      awaitingLocalNetwork = false
      _isConnected = true
      // Safe one-time resume: consume and nil the continuation
      connectContinuation = nil
      continuation.resume()

    case let .failed(error):
      logger.error("Connection failed: \(error.localizedDescription)")
      // Safe one-time resume: consume and nil the continuation
      if let continuation = connectContinuation {
        _isConnected = false
        connectContinuation = nil
        continuation.resume(throwing: WiFiTransportError.connectionFailed(error.localizedDescription))
      } else {
        // Connection was established then lost: end the stream and release the connection
        // exactly as a receive error does, then notify.
        handleLinkLoss(error)
      }

    case .cancelled:
      logger.info("Connection cancelled")
      // Only report if this wasn't during initial connection and wasn't user-initiated
      // (a user disconnect drops this connection's callbacks before cancelling it).
      if connectContinuation == nil {
        handleLinkLoss(nil)
      } else {
        _isConnected = false
      }

    case let .waiting(error):
      guard let continuation = connectContinuation else {
        // An established connection's path trouble is followed by the viability handler,
        // which gives it a grace period before the link counts as lost.
        logger.warning("Connection waiting after ready: \(error.localizedDescription)")
        return
      }
      logger.warning("Connection waiting: \(error.localizedDescription)")
      // Local Network access not granted (yet): the first connect after install brings up the
      // prompt and iOS parks the connection until it's answered, then carries on by itself.
      // Failing here, as for a bad address, failed every first-run connect, onboarding's included.
      if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
        guard failsFastOnLocalNetworkPrompt else {
          awaitingLocalNetwork = true
          return
        }
        // Nothing can answer the prompt now (the app is in the background, or access was
        // already declined): fail now rather than hold the caller for a minute.
        logger.warning("Local Network access not granted; failing fast")
        awaitingLocalNetwork = false
        _isConnected = false
        connectContinuation = nil
        continuation.resume(throwing: WiFiTransportError.localNetworkDenied)
        return
      }
      // For invalid addresses, the connection goes to waiting state with an error
      // Treat this as a connection failure
      _isConnected = false
      connectContinuation = nil
      continuation.resume(throwing: WiFiTransportError.connectionFailed(error.localizedDescription))

    default:
      break
    }
  }

  /// Follows an established connection's path: an unviable path that does not recover within
  /// `viabilityGracePeriod` is treated as a lost link, since nothing else would notice a
  /// radio that dropped off the network until the next write timed out.
  func handleViabilityChange(_ isViable: Bool, for connectionID: ObjectIdentifier) {
    guard let connection, ObjectIdentifier(connection) == connectionID, _isConnected else { return }
    if isViable {
      if viabilityLossTask != nil {
        logger.info("Connection path viable again")
      }
      viabilityLossTask?.cancel()
      viabilityLossTask = nil
      return
    }
    guard viabilityLossTask == nil else { return }
    logger.warning("Connection path not viable; waiting \(Self.viabilityGracePeriod) for it to recover")
    viabilityLossTask = Task { [weak self] in
      try? await Task.sleep(for: Self.viabilityGracePeriod)
      guard !Task.isCancelled else { return }
      await self?.handleViabilityTimeout(for: connectionID)
    }
  }

  private func handleViabilityTimeout(for connectionID: ObjectIdentifier) {
    viabilityLossTask = nil
    guard let connection, ObjectIdentifier(connection) == connectionID else { return }
    logger.error("Connection path stayed unviable; treating the link as lost")
    handleLinkLoss(WiFiTransportError.connectionFailed("Network path lost"))
  }

  private func startReceiving() {
    guard let connection else { return }
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    let connectionID = ObjectIdentifier(connection)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
      Task { [weak self] in
        await self?.handleReceive(content: content, isComplete: isComplete, error: error, for: connectionID)
      }
    }
  }

  private func handleReceive(content: Data?, isComplete: Bool, error: NWError?, for connectionID: ObjectIdentifier) {
    // A receive completing after its connection was released belongs to nobody now.
    guard let connection, ObjectIdentifier(connection) == connectionID else { return }

    if let content {
      processReceivedData(content)
    }

    if let error {
      logger.error("Receive error: \(error.localizedDescription)")
      handleLinkLoss(error)
      return
    }

    if isComplete {
      logger.info("Connection closed by peer")
      handleLinkLoss(nil)
      return
    }

    guard _isConnected else { return }
    receive(on: connection)
  }

  /// Tears down an established connection that was lost: the peer closed the stream, a
  /// receive failed, the connection reached `.failed`, or its path stayed unviable. The data
  /// stream finishes so the session's receive loop ends, the connection is released, and the
  /// disconnection handler fires. Guarded on `_isConnected` so two signals for the same loss
  /// notify exactly once.
  private func handleLinkLoss(_ error: Error?) {
    guard _isConnected else { return }
    _isConnected = false
    releaseConnection()
    frameDecoder.reset()
    dataContinuation.finish()
    disconnectionHandler?(error)
  }

  private func processReceivedData(_ data: Data) {
    let frames = frameDecoder.decode(data)
    for frame in frames {
      dataContinuation.yield(frame)
    }
  }
}
