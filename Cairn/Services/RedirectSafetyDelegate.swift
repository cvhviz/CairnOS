import Foundation
import os

/// Re-validates every HTTP redirect hop of the sessions that fetch
/// sender-supplied URLs (`LinkPreviewService`'s scrape session and
/// `InlineImageCache`'s) against the SSRF allow-list. A default `URLSession`
/// follows 3xx redirects automatically, so without this a URL that passes the
/// initial `isSafe` check could redirect to a private host and be fetched anyway.
final class RedirectSafetyDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url else {
      completionHandler(nil)
      return
    }
    Task {
      let isSafe = await URLSafetyChecker.isSafe(url)
      completionHandler(isSafe ? request : nil)
    }
  }
}

/// Per-request task delegate that checks the address each connection actually
/// reached. `URLSafetyChecker.isSafe` resolves the host itself and URLSession
/// resolves it again, so a DNS answer that flips to a private address between
/// the two lookups (rebinding) would pass the check and still be fetched. The
/// transaction metrics carry the peer address URLSession connected to; the
/// caller awaits `reachedOnlyPublicAddresses()` before accepting the body.
/// Redirect hops stay with the session's `RedirectSafetyDelegate`, since a task
/// delegate that does not implement a method defers to the session delegate.
final class RemoteAddressSafetyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  /// URLSession delivers metrics before the task completes, so the body stream
  /// ending first is not expected; this bounds the wait if it ever does.
  private static let metricsWait: Duration = .seconds(1)

  private struct State {
    var verdict: Bool?
    var waiter: CheckedContinuation<Bool, Never>?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    let connections = metrics.transactionMetrics.map {
      (remoteAddress: $0.remoteAddress, isProxyConnection: $0.isProxyConnection)
    }
    resolve(Self.reachedOnlyPublicAddresses(connections))
  }

  /// `true` when every connection the task made reached a public address.
  /// Fails closed when the metrics do not arrive within `metricsWait`.
  func reachedOnlyPublicAddresses() async -> Bool {
    await withCheckedContinuation { continuation in
      let verdict = state.withLock { state -> Bool? in
        if let verdict = state.verdict {
          return verdict
        }
        state.waiter = continuation
        return nil
      }
      if let verdict {
        continuation.resume(returning: verdict)
        return
      }
      Task {
        try? await Task.sleep(for: Self.metricsWait)
        self.resolve(false)
      }
    }
  }

  private func resolve(_ verdict: Bool) {
    let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard state.verdict == nil else { return nil }
      state.verdict = verdict
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(returning: verdict)
  }

  /// Judges the peer addresses of a task's transactions. A transaction with no
  /// address (served locally, or by a `URLProtocol`) or one made to a proxy
  /// (whose address says nothing about the target) is not judged; any other
  /// address must parse as an IP literal outside the private and reserved ranges.
  static func reachedOnlyPublicAddresses(
    _ connections: [(remoteAddress: String?, isProxyConnection: Bool)]
  ) -> Bool {
    connections.allSatisfy { connection in
      guard !connection.isProxyConnection, let address = connection.remoteAddress else { return true }
      // A link-local peer carries its interface as a `%zone` suffix, which `inet_pton` rejects.
      let literal = String(address.prefix { $0 != "%" })
      return URLSafetyChecker.isIPLiteral(literal) && !URLSafetyChecker.isPrivateOrReserved(literal)
    }
  }
}
