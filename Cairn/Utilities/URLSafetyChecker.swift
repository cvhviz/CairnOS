import Foundation
import os
import OSLog

/// Validates URLs before fetching to prevent SSRF attacks via private network access.
/// Rejects non-HTTP(S) schemes and private/reserved IPs.
enum URLSafetyChecker {
  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "URLSafetyChecker")

  /// Hosts that bypass safety checks (known-safe CDN domains)
  private static let allowedHosts: Set<String> = [
    "media.giphy.com",
    "i.giphy.com"
  ]

  private static let dnsTimeoutSeconds: Duration = .seconds(5)

  // MARK: - Public API

  /// Returns `true` if the URL is safe to fetch, `false` otherwise.
  /// Fails closed: DNS failure or timeout returns `false`.
  static func isSafe(_ url: URL) async -> Bool {
    // Only allow HTTP(S)
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      logger.warning("Rejected non-HTTP(S) scheme: \(url.scheme ?? "nil")")
      return false
    }

    // Must have a host
    guard let host = url.host() else {
      logger.warning("Rejected URL with no host")
      return false
    }

    // Allow-listed hosts bypass SSRF checks (known-safe CDN domains)
    if allowedHosts.contains(host) {
      return true
    }

    // If host is an IP literal, check directly
    if isPrivateOrReserved(host) {
      logger.warning("Rejected private/reserved IP: \(host)")
      return false
    }

    // Resolve DNS and check all addresses
    return await resolveAndCheck(host: host)
  }

  /// Whether the string parses as an IPv4 or IPv6 address literal.
  static func isIPLiteral(_ address: String) -> Bool {
    var addr4 = in_addr()
    var addr6 = in6_addr()
    return inet_pton(AF_INET, address, &addr4) == 1 || inet_pton(AF_INET6, address, &addr6) == 1
  }

  /// Checks whether an IP address string falls within private or reserved ranges.
  static func isPrivateOrReserved(_ address: String) -> Bool {
    var addr4 = in_addr()
    if inet_pton(AF_INET, address, &addr4) == 1 {
      return isPrivateIPv4(UInt32(bigEndian: addr4.s_addr))
    }

    var addr6 = in6_addr()
    if inet_pton(AF_INET6, address, &addr6) == 1 {
      let bytes = withUnsafeBytes(of: &addr6.__u6_addr.__u6_addr8) { Array($0) }
      return isPrivateIPv6(bytes)
    }

    // Not a valid IP literal — not private (will be resolved via DNS)
    return false
  }

  // MARK: - Private IP Range Checks

  /// Checks whether a parsed IPv4 address falls within private or reserved ranges.
  private static func isPrivateIPv4(_ ip: UInt32) -> Bool {
    if ip >> 24 == 0 { return true } // 0.0.0.0/8 ("this network")
    if ip >> 24 == 127 { return true } // 127.0.0.0/8
    if ip >> 24 == 10 { return true } // 10.0.0.0/8
    if ip >> 22 == 0x191 { return true } // 100.64.0.0/10 (carrier-grade NAT)
    if ip >> 20 == 0xAC1 { return true } // 172.16.0.0/12
    if ip >> 8 == 0xC00000 { return true } // 192.0.0.0/24 (IETF protocol assignments)
    if ip >> 16 == 0xC0A8 { return true } // 192.168.0.0/16
    if ip >> 17 == 0x6309 { return true } // 198.18.0.0/15 (benchmarking)
    if ip >> 16 == 0xA9FE { return true } // 169.254.0.0/16 (link-local)
    if ip >> 28 == 0xE { return true } // 224.0.0.0/4 (multicast)
    if ip >> 28 == 0xF { return true } // 240.0.0.0/4 (reserved)
    return false
  }

  /// Checks whether a parsed IPv6 address falls within private or reserved ranges.
  private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
    if bytes.allSatisfy({ $0 == 0 }) { return true } // ::
    if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return true } // ::1
    if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return true } // fe80::/10
    if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0xC0 { return true } // fec0::/10 (site-local)
    if (bytes[0] & 0xFE) == 0xFC { return true } // fc00::/7
    // IPv4-mapped (::ffff:0:0/96) and NAT64 (64:ff9b::/96): check the embedded IPv4 address
    if bytes[0...9].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
      return isPrivateIPv4(embeddedIPv4(bytes, at: 12))
    }
    if bytes[0...3] == [0x00, 0x64, 0xFF, 0x9B], bytes[4...11].allSatisfy({ $0 == 0 }) {
      return isPrivateIPv4(embeddedIPv4(bytes, at: 12))
    }
    // 6to4 (2002::/16) carries the relay's IPv4 address in bytes 2...5
    if bytes[0] == 0x20, bytes[1] == 0x02 {
      return isPrivateIPv4(embeddedIPv4(bytes, at: 2))
    }
    if bytes[0] == 0xFF { return true } // ff00::/8
    return false
  }

  private static func embeddedIPv4(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }

  // MARK: - DNS Resolution

  /// Resolves the host via DNS and checks all returned addresses.
  /// Returns `true` if all resolved addresses are public, `false` otherwise,
  /// including when the lookup outlasts the 5-second timeout.
  private static func resolveAndCheck(host: String) async -> Bool {
    let isPublic = await firstResult(within: dnsTimeoutSeconds) {
      resolveDNS(host: host)
    }
    guard let isPublic else {
      if !Task.isCancelled {
        logger.warning("DNS resolution timed out for \(host)")
      }
      return false
    }
    return isPublic
  }

  /// Runs a blocking `lookup` and returns its result, or `nil` once `timeout`
  /// passes or the caller is cancelled, whichever comes first. `getaddrinfo`
  /// cannot be interrupted, so the caller stops waiting rather than the
  /// lookup stopping: a task group would still await the blocked child on
  /// exit, and the timeout would bound the result but not the wait. The
  /// lookup runs on a dispatch queue because an abandoned one would
  /// otherwise pin a thread of the fixed-width cooperative pool.
  static func firstResult(
    within timeout: Duration,
    of lookup: @escaping @Sendable () -> Bool
  ) async -> Bool? {
    let waiter = OSAllocatedUnfairLock<CheckedContinuation<Bool?, Never>?>(initialState: nil)
    let finish: @Sendable (Bool?) -> Void = { result in
      let continuation = waiter.withLock { pending in
        defer { pending = nil }
        return pending
      }
      continuation?.resume(returning: result)
    }

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiter.withLock { $0 = continuation }
        guard !Task.isCancelled else {
          finish(nil)
          return
        }

        let timeoutTask = Task.detached {
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          finish(nil)
        }
        DispatchQueue.global(qos: .utility).async {
          let result = lookup()
          timeoutTask.cancel()
          finish(result)
        }
      }
    } onCancel: {
      finish(nil)
    }
  }

  /// Synchronous DNS resolution + private IP check (blocks; run off the cooperative pool).
  private static func resolveDNS(host: String) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0, let addrList = result else {
      return false
    }
    defer { freeaddrinfo(addrList) }

    var current: UnsafeMutablePointer<addrinfo>? = addrList
    while let info = current {
      let address = extractAddress(from: info.pointee)
      if let address, isPrivateOrReserved(address) {
        return false
      }
      current = info.pointee.ai_next
    }

    return true
  }

  /// Extracts a human-readable IP address string from an addrinfo struct.
  private static func extractAddress(from info: addrinfo) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

    switch info.ai_family {
    case AF_INET:
      var addr = info.ai_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
      inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
      return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

    case AF_INET6:
      var addr = info.ai_addr!.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
      inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
      return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

    default:
      return nil
    }
  }
}
