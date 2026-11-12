import Foundation
import Network

/// Whether the phone can reach a board's WiFi address, checked before START takes the board's
/// Bluetooth down. Nothing listens on port 80 until Updater mode starts, so a quick refusal counts
/// as reachable; a timeout, or the Local Network permission being denied, doesn't. The first try
/// also brings up the Local Network prompt.
enum LocalNetworkProbe {
  /// Long enough to answer the Local Network prompt the first try brings up.
  static let timeout: TimeInterval = 8

  static func canReach(_ address: String, timeout: TimeInterval = timeout) async -> Bool {
    let probe = Probe(NWConnection(host: NWEndpoint.Host(address), port: 80, using: .tcp))
    return await withTaskCancellationHandler {
      await probe.run(timeout: timeout)
    } onCancel: {
      probe.finish(false)
    }
  }
}

/// One connection attempt. All state lives on `queue`.
private final class Probe: @unchecked Sendable {
  let connection: NWConnection
  let queue = DispatchQueue(label: "cvhvisuals.Cairn.LocalNetworkProbe")
  private var continuation: CheckedContinuation<Bool, Never>?
  private var result: Bool?

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  func run(timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        // Cancelled before it started.
        if let result {
          continuation.resume(returning: result)
          return
        }
        self.continuation = continuation
        connection.stateUpdateHandler = { [self] state in
          switch state {
          case .ready:
            finish(true)
          case let .waiting(error), let .failed(error):
            if case .posix(.ECONNREFUSED) = error {
              finish(true)
            } else if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
              finish(false)
            } else if case .failed = state {
              finish(false)
            }
          default:
            break
          }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(false) }
      }
    }
  }

  func finish(_ reachable: Bool) {
    queue.async { [self] in
      guard result == nil else { return }
      result = reachable
      connection.stateUpdateHandler = nil
      connection.cancel()
      continuation?.resume(returning: reachable)
      continuation = nil
    }
  }
}
